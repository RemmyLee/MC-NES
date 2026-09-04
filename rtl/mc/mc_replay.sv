// mc_replay: play a recorded input log (a TAS movie) into the NES from DDR3,
// one entry per frame, with the frame timing held by the core itself.
//
// Buffer at byte 0x3C100000 (64 bit word 0x1820000 inside the 0x30000000
// window), written by MiSTer Control:
//   w0  magic "MC-RPLAY"
//   w1  [31:0] frames            [63:32] generation (changes on every arm)
//   w2  [0] armed  [1] abort  [2] poll-indexed  (the rest reserved)
//   w3  reserved
//   w8.. entries, 2 per word: frame i is bytes 4*(i&1) .. +3 of word 8 + i/2:
//        [7:0] pad 1  [15:8] pad 2  [23:16] command  [31:24] 0
//        pad byte order is the NES serial order, bit 7 first: R L D U Start
//        Select B A (the FM2 "RLDUTSBA" column, and NES.sv's nes_joy_A)
//
// Sequence: the app writes the entries, then the header with a new
// generation and armed = 1, then reloads the ROM. This module polls the header
// while idle; on a new generation it prefetches the first entries and waits
// for the core's reset to release after a ROM download (the end of the ROM
// load: that is power-on). A reset release with no download before it (the
// FPGA load itself; an MGL launch gives one of those about two seconds before
// the ROM upload) is not the start and is ignored.
// From then on entry N is presented at the rising edge of vblank of frame N
// (docs/TAS-semantics.md: FCEUX sets the frame's input just before the frame's
// vblank), entry 0 from the reset release itself.
//
// Poll-indexed mode (header w2 bit 2): the index advances at vblank only when
// the game read the controller during the finished frame. The app then writes
// the entries the emulator actually delivered (its lag frames stripped), so a
// frame where the core lags differently from the emulator no longer shifts
// every later input. This is how console verification rigs stay in sync. At `frames` it stops and
// hands the pads back to the HPS. An entry with a command bit set stops the
// replay with state UNSUPPORTED: reset and power inside a movie are not
// implemented in this version.
//
// State (also written into the telemetry slot): 0 idle, 1 armed, 2 running,
// 3 done, 4 aborted, 5 unsupported command, 6 bad header.
//
// Copyright (c) 2026 Remmy Lee. GPLv3, like the core it lives in.

module mc_replay
(
	input             clk,
	input             reset,       // the core's reset (high during a ROM load)
	input             downloading, // a game upload is in progress (NES.sv `downloading` for a nes/fds/nsf type; boot0.rom is not a game)
	input             vblank,
	input             joy_read,    // one pulse per $4016/$4017 read (the lag rule's poll)

	// DDR read channel (64 bit word address inside the 0x30000000 window)
	output reg [24:0] ddr_addr,
	output reg        ddr_req,
	input      [63:0] ddr_dout,
	input             ddr_ready,   // one clock, ddr_dout valid

	output reg        active = 0,  // pads come from the buffer
	output reg  [7:0] p1 = 0,
	output reg  [7:0] p2 = 0,
	output reg [31:0] index = 0,   // entry being presented
	output reg  [7:0] state = 0,
	output reg  [7:0] gen = 0      // generation of the last accepted arm; 0 = none yet
);

localparam [24:0] HDR_W = 25'h1820000;
localparam [63:0] MAGIC = 64'h59414C50_522D434D;   // "MC-RPLAY"

localparam [7:0] S_IDLE = 0, S_ARMED = 1, S_RUN = 2, S_DONE = 3, S_ABORT = 4, S_UNSUP = 5, S_BADHDR = 6;

// poll the header about 60 times a second while not running
localparam [18:0] POLL_CLKS = 19'd357954;   // 21477272 / 60

reg [18:0] poll_cnt = 0;
reg        vblank_d = 0;
wire       frame_start = vblank & ~vblank_d;
reg        reset_d = 1;
wire       reset_release = reset_d & ~reset;

reg [31:0] frames;
reg [63:0] cur, nxt;      // entries (2k, 2k+1) and (2k+2, 2k+3)
reg [63:0] hdr0, hdr1, hdr2;

// one read at a time
typedef enum logic [3:0] { IDLE, RD0, RD1, RD2, EVAL, PF0, PF1, WAIT_RESET, RUN, RD_FLAGS, RD_NEXT } st_t;
st_t st = IDLE;
reg        pending = 0;   // a read was issued, waiting for ready
// an edge that arrives while a header or entry read is in flight is kept
// until the main state can act on it (a read takes about a microsecond)
reg        frame_pend = 0, release_pend = 0;
wire       tick = frame_start | frame_pend;
wire       release_now = reset_release | release_pend;
reg        dl_seen = 0;   // a download happened since arming: the next release is power-on
reg        poll_mode = 0; // header w2 bit 2: advance per polled frame, not per frame
reg        polled = 0;    // the game read the controller since the last vblank

task automatic read_word(input [24:0] a, input st_t next);
	ddr_addr <= a;
	ddr_req  <= 1;
	pending  <= 1;
	st       <= next;
endtask

always @(posedge clk) begin
	ddr_req  <= 0;
	vblank_d <= vblank;
	reset_d  <= reset;
	if (ddr_ready) pending <= 0;
	poll_cnt <= (poll_cnt == POLL_CLKS) ? 19'd0 : poll_cnt + 19'd1;
	if (frame_start && st != RUN) frame_pend <= 1;
	if (reset_release && st != WAIT_RESET) release_pend <= 1;
	if (downloading) dl_seen <= 1;   // sticky; EVAL's assignment below wins on the arm clock
	if (joy_read) polled <= 1;

	case (st)

	// ---- idle: poll the header ------------------------------------------------
	IDLE: begin
		active <= 0;
		frame_pend   <= 0;
		release_pend <= 0;
		if (poll_cnt == 0) read_word(HDR_W + 25'd0, RD0);
	end
	RD0: if (ddr_ready) begin hdr0 <= ddr_dout; read_word(HDR_W + 25'd1, RD1); end
	RD1: if (ddr_ready) begin hdr1 <= ddr_dout; read_word(HDR_W + 25'd2, RD2); end
	RD2: if (ddr_ready) begin hdr2 <= ddr_dout; st <= EVAL; end
	EVAL: begin
		st <= IDLE;
		if (hdr0 == MAGIC && hdr2[0] && hdr1[39:32] != gen) begin
			gen    <= hdr1[39:32];
			frames <= hdr1[31:0];
			index  <= 0;
			if (hdr1[31:0] == 0) state <= S_BADHDR;
			else begin
				state     <= S_ARMED;
				dl_seen   <= downloading;
				poll_mode <= hdr2[2];
				read_word(HDR_W + 25'd8, PF0);
			end
		end
	end
	PF0: if (ddr_ready) begin cur <= ddr_dout; read_word(HDR_W + 25'd9, PF1); end
	PF1: if (ddr_ready) begin nxt <= ddr_dout; st <= WAIT_RESET; end

	// ---- armed: wait for the ROM load's reset to release (power-on) ---------------
	WAIT_RESET: begin
		release_pend <= 0;
		frame_pend   <= 0;
		if (poll_cnt == 0 && !pending && !(release_now && dl_seen)) read_word(HDR_W + 25'd2, RD_FLAGS);   // abort?
		if (release_now && dl_seen) begin
			active <= 1;
			state  <= S_RUN;
			index  <= 0;
			polled <= 0;
			p1     <= cur[7:0];
			p2     <= cur[15:8];
			st     <= RUN;
			if (cur[23:16] != 0) begin active <= 0; state <= S_UNSUP; st <= IDLE; end
		end
	end
	RD_FLAGS: if (ddr_ready) begin
		hdr2 <= ddr_dout;
		if (ddr_dout[1]) begin state <= S_ABORT; active <= 0; st <= IDLE; end
		else st <= st_t'((state == S_RUN) ? RUN : WAIT_RESET);
	end

	// ---- running: one entry per vblank --------------------------------------------
	RUN: begin
		frame_pend <= 0;
		if (reset) begin                      // a load or reset ends the run
			active <= 0; state <= S_ABORT; st <= IDLE;
		end
		else if (tick) begin
			polled <= 0;
			if (poll_mode && !polled) begin
				// the game never read this frame's entry; hold the stream
			end
			else if (index + 32'd1 >= frames) begin
				active <= 0; state <= S_DONE; st <= IDLE;
			end
			else begin
				index <= index + 32'd1;
				if (index[0]) begin           // moving to an even index: next word
					cur <= nxt;
					p1  <= nxt[7:0];
					p2  <= nxt[15:8];
					if (nxt[23:16] != 0) begin active <= 0; state <= S_UNSUP; st <= IDLE; end
					else read_word(HDR_W + 25'd8 + ((index[24:0] + 25'd3) >> 1), RD_NEXT);
				end
				else begin
					p1 <= cur[39:32];
					p2 <= cur[47:40];
					if (cur[55:48] != 0) begin active <= 0; state <= S_UNSUP; st <= IDLE; end
				end
			end
		end
		else if (poll_cnt == 0 && !pending) read_word(HDR_W + 25'd2, RD_FLAGS);
	end
	RD_NEXT: if (ddr_ready) begin nxt <= ddr_dout; st <= RUN; end

	default: st <= IDLE;
	endcase
end

endmodule
