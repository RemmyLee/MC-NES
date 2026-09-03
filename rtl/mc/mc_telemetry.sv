// mc_telemetry: once per frame, write a snapshot of the machine state to DDR3
// where MiSTer Control reads it over /dev/mem.
//
// DDR map (byte addresses; the ddram module adds the 0x30000000 window):
//   0x3C000000  header, 40 bytes used
//   0x3C001000  slot ring, 4 slots x 4096 bytes, slot = frame & 3
//
// Header (little endian 64 bit words):
//   h0  magic  "MC-NES\0\1"
//   h1  [31:0] layout version = 1     [63:32] slot size = 4096
//   h2  [31:0] frame (written last)   [63:32] slot count = 4
//   h3  [31:0] flags: bit0 enabled    [63:32] replay state (0 in this version)
//   h4  [31:0] core clock Hz          [63:32] system type (status[72:70])
// The header is written every frame, also while telemetry is off, so a reader
// can tell "off" (frame advances, bit0 clear) from "no MC core" (no magic).
//
// Slot (byte offsets):
//   0x000  [31:0] frame  [40:32] scanline  [56:48] cycle at snapshot
//   0x008  CPU registers as T65 packs them: [63:48] PC [47:32] S [31:24] P
//          [23:16] Y [15:8] X [7:0] A
//   0x010  [7:0] pad 1 latched at the last $4016 strobe  [15:8] pad 2
//          [23:16] strobes this frame (0 = lag frame, saturates at 255)
//          [24] register words valid  [25] RAM torn  [26] replay active
//   0x018  reserved (0)
//   0x040  64 x 64 bit: the save state register bus, words 0..63
//          (index map: rtl/regs_savestates.sv; same encoding as the .ss file)
//   0x240  2048 bytes CPU work RAM
//   0xA40  256 bytes written-bitmap (bit i of byte n = RAM byte n*8+i written
//          since the ROM was loaded)
//   0xB40  [31:0] frame again (a reader accepts the slot only if both match)
//
// Order of writes: words 0, 1, 3, registers, RAM, bitmap, word 2 (its flags
// are only known after the RAM read-out), tail, header constants, header frame.
//
// The snapshot starts on the rising edge of vblank. The shadow RAM is held for
// the whole RAM read-out, so the RAM image is the state at that instant; the
// register words are read live from the bus a few clocks later, while the CPU
// is already inside its NMI handler. Each word is what it says at the clock
// it was read.
//
// Copyright (c) 2026 Remmy Lee. GPLv3, like the core it lives in.

module mc_telemetry
(
	input             clk,
	input             reset,
	input             enable,

	input             vblank,
	input       [8:0] scanline,
	input       [8:0] cycle,
	input      [31:0] clk_hz,
	input       [2:0] sys_type,

	input      [63:0] cpu_regs,

	// save state register bus, read live
	output reg  [9:0] bus_adr,
	input      [63:0] bus_dout,
	input             bus_free,

	// shadow RAM
	output reg        ram_hold,
	output reg [10:0] ram_rd_addr,
	input       [7:0] ram_rd_data,     // valid the clock after ram_rd_addr
	output reg  [7:0] bm_addr,
	input       [7:0] bm_data,         // valid the clock after bm_addr
	input             ram_torn,

	// pads latched by the game (from NES.sv)
	input       [7:0] joy1_latched,
	input       [7:0] joy2_latched,
	input             joy_strobe,      // one clock per $4016 strobe rising edge

	input             replay_active,

	// DDR write channel (64 bit word address inside the 0x30000000 window)
	output reg [24:0] ddr_addr,
	output reg [63:0] ddr_din,
	output reg        ddr_req,
	input             ddr_ready,

	output reg [31:0] frame
);

localparam [24:0] HEADER_WORD = 25'h1800000;     // (0x3C000000 - 0x30000000) >> 3
localparam [24:0] SLOT0_WORD  = 25'h1800200;     // (0x3C001000 - 0x30000000) >> 3
localparam [63:0] MAGIC       = 64'h01005345_4E2D434D;   // "MC-NES\0\1"

// slot word offsets
localparam [24:0] W_REGS = 25'd8;     // 0x040
localparam [24:0] W_RAM  = 25'd72;    // 0x240
localparam [24:0] W_BM   = 25'd328;   // 0xA40
localparam [24:0] W_TAIL = 25'd360;   // 0xB40

// ---- per-frame inputs --------------------------------------------------------
reg vblank_d = 0;
wire frame_start = vblank & ~vblank_d;

reg [7:0] strobes = 0;
always @(posedge clk) begin
	vblank_d <= vblank;
	if (frame_start) strobes <= 0;
	else if (joy_strobe && strobes != 8'hFF) strobes <= strobes + 8'd1;
end

wire [1:0] next_slot = frame[1:0] + 2'd1;   // 2 bit wire: wraps

// ---- snapshot state machine --------------------------------------------------
typedef enum logic [3:0] {
	IDLE, HEAD, REGS_SET, REGS_GET, RAM_RUN, RAM_W1, RAM_W2, BM_RUN, BM_W1, BM_W2,
	FLAGS, TAIL, HDR, WRITE
} st_t;

st_t st = IDLE, after_write = IDLE;

reg [63:0] snap_regs;
reg  [8:0] snap_scanline, snap_cycle;
reg  [7:0] snap_strobes, snap_j1, snap_j2;
reg        snap_bus_ok, snap_torn;
reg [24:0] slot_base;
reg  [7:0] idx;          // word index within the current section
reg  [2:0] byte_idx;     // byte being addressed
reg [63:0] acc;

// read pipeline: an address set at clock k is registered at k, the RAM
// registers its data at k+1, so the byte is on the input during clock k+2.
reg  [2:0] p1_b, p2_b;
reg        p1_v = 0, p2_v = 0, p1_src, p2_src;   // src 0 = RAM, 1 = bitmap
reg  [2:0] hdr_idx;

task automatic write_word(input [24:0] a, input [63:0] d, input st_t next);
	ddr_addr    <= a;
	ddr_din     <= d;
	ddr_req     <= 1;
	after_write <= next;
	st          <= WRITE;
endtask

always @(posedge clk) begin
	ddr_req <= 0;
	p1_v    <= 0;
	p2_v    <= p1_v;  p2_b <= p1_b;  p2_src <= p1_src;
	if (p2_v) acc[p2_b*8 +: 8] <= p2_src ? bm_data : ram_rd_data;

	if (reset) begin
		st       <= IDLE;
		ram_hold <= 0;
		frame    <= 0;
	end
	else case (st)

	IDLE: if (frame_start) begin
		frame     <= frame + 32'd1;
		slot_base <= SLOT0_WORD + {14'd0, next_slot, 9'd0};   // 512 words per slot
		idx       <= 0;
		byte_idx  <= 0;
		hdr_idx   <= 0;
		if (enable) begin
			ram_hold      <= 1;
			snap_regs     <= cpu_regs;
			snap_scanline <= scanline;
			snap_cycle    <= cycle;
			snap_strobes  <= strobes;
			snap_j1       <= joy1_latched;
			snap_j2       <= joy2_latched;
			snap_bus_ok   <= bus_free;
			st            <= HEAD;
		end
		else st <= HDR;
	end

	// slot words 0, 1, 3 (word 2 carries flags known only at the end)
	HEAD: begin
		idx <= idx + 8'd1;
		case (idx[1:0])
		2'd0: write_word(slot_base + 25'd0, {7'd0, snap_cycle, 7'd0, snap_scanline, frame}, HEAD);
		2'd1: write_word(slot_base + 25'd1, snap_regs, HEAD);
		default: begin
			idx <= 0;
			write_word(slot_base + 25'd3, 64'd0, st_t'(snap_bus_ok ? REGS_SET : RAM_RUN));
		end
		endcase
	end

	// register bus: the read is combinational from bus_adr; present, then take
	REGS_SET: begin
		bus_adr <= {4'd0, idx[5:0]};
		st      <= REGS_GET;
	end
	REGS_GET: begin
		if (!bus_free) begin
			snap_bus_ok <= 0;           // a save or load took the bus mid-read
			idx         <= 0;
			st          <= RAM_RUN;
		end
		else begin
			idx <= (idx[5:0] == 6'd63) ? 8'd0 : idx + 8'd1;
			write_word(slot_base + W_REGS + {19'd0, idx[5:0]}, bus_dout, st_t'((idx[5:0] == 6'd63) ? RAM_RUN : REGS_SET));
		end
	end

	// RAM: address one byte per clock; the pipeline above captures each byte
	// two clocks later. Bytes 0..6 land during RAM_RUN and RAM_W1; byte 7 is
	// on the input during RAM_W2 and goes straight into the word.
	RAM_RUN: begin
		ram_rd_addr <= {idx, byte_idx};
		p1_v <= 1;  p1_b <= byte_idx;  p1_src <= 0;
		byte_idx <= byte_idx + 3'd1;
		if (byte_idx == 3'd7) st <= RAM_W1;
	end
	RAM_W1: st <= RAM_W2;
	RAM_W2: begin
		idx <= idx + 8'd1;
		write_word(slot_base + W_RAM + {17'd0, idx}, {ram_rd_data, acc[55:0]}, st_t'((idx == 8'd255) ? BM_RUN : RAM_RUN));
	end

	// written bitmap: 32 words, same pipeline
	BM_RUN: begin
		bm_addr <= {idx[4:0], byte_idx};
		p1_v <= 1;  p1_b <= byte_idx;  p1_src <= 1;
		byte_idx <= byte_idx + 3'd1;
		if (byte_idx == 3'd7) st <= BM_W1;
	end
	BM_W1: st <= BM_W2;
	BM_W2: begin
		idx <= idx + 8'd1;
		write_word(slot_base + W_BM + {20'd0, idx[4:0]}, {bm_data, acc[55:0]}, st_t'((idx[4:0] == 5'd31) ? FLAGS : BM_RUN));
	end

	FLAGS: begin
		snap_torn <= ram_torn;
		ram_hold  <= 0;                      // RAM image complete; the FIFO drains
		write_word(slot_base + 25'd2,
			{32'd0, 5'd0, replay_active, ram_torn, snap_bus_ok, snap_strobes, snap_j2, snap_j1}, TAIL);
	end

	TAIL: write_word(slot_base + W_TAIL, {frame, frame}, HDR);

	HDR: begin
		hdr_idx <= hdr_idx + 3'd1;
		case (hdr_idx)
		3'd0: write_word(HEADER_WORD + 25'd0, MAGIC, HDR);
		3'd1: write_word(HEADER_WORD + 25'd1, {32'd4096, 32'd1}, HDR);
		3'd2: write_word(HEADER_WORD + 25'd3, {32'd0, 31'd0, enable}, HDR);
		3'd3: write_word(HEADER_WORD + 25'd4, {29'd0, sys_type, clk_hz}, HDR);
		default: write_word(HEADER_WORD + 25'd2, {32'd4, frame}, IDLE);
		endcase
	end

	WRITE: if (ddr_ready) st <= after_write;

	default: st <= IDLE;
	endcase
end

endmodule
