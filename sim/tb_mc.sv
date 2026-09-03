// Testbench for rtl/mc: mc_shadow_ram + mc_telemetry with a DDR write sink.
// Run: sim/run.sh   (Icarus Verilog, -g2012)
//
// Checks, per frame:
//   header magic and frame word, slot frame head and tail, RAM bytes written
//   through the FIFO (held during the read-out), the written bitmap, the pad
//   latch and strobe count, the register bus words, and that a write during the
//   hold lands in the NEXT frame's image, not this one.
`timescale 1ns/1ps

module tb_mc;

reg clk = 0;
always #23.28 clk = ~clk;      // 21.477 MHz

reg reset = 1, enable = 1, vblank = 0;
reg [8:0] scanline = 9'd241, cycle = 9'd5;
reg [63:0] cpu_regs = 64'h8000_01FD_2411_2233;

// register bus model: word k reads as k repeated
wire [9:0] bus_adr;
wire [63:0] bus_dout = {8{bus_adr[7:0]}} ^ 64'hA5A5_0000_0000_0000;
reg bus_free = 1;

// shadow RAM
reg wr = 0; reg [10:0] wr_addr = 0; reg [7:0] wr_data = 0;
wire hold; wire [10:0] rd_addr; wire [7:0] rd_data; wire [7:0] bm_addr, bm_data; wire torn;
reg clear = 0;

mc_shadow_ram sh (.clk(clk), .clear(clear), .wr(wr), .wr_addr(wr_addr), .wr_data(wr_data),
	.hold(hold), .rd_addr(rd_addr), .rd_data(rd_data), .bm_addr(bm_addr), .bm_data(bm_data), .torn(torn));

integer errors = 0;
// DDR sink: records every word by address
wire [24:0] ddr_addr; wire [63:0] ddr_din; wire ddr_req; reg ddr_ready = 0;
// a 4096 word window starting at the header word (0x1800000)
reg [63:0] ddr [0:4095];
reg        ddr_seen [0:4095];
integer ddr_writes = 0;
integer i;
initial for (i = 0; i < 4096; i = i + 1) begin ddr[i] = 64'hx; ddr_seen[i] = 0; end
always @(posedge clk) begin
	ddr_ready <= 0;
	if (ddr_req) begin
		if (ddr_addr < 25'h1800000 || ddr_addr >= 25'h1801000) begin
			$display("FAIL: write outside the MC window: %h", ddr_addr);
			errors = errors + 1;
		end
		else begin
			ddr[ddr_addr - 25'h1800000] = ddr_din;
			ddr_seen[ddr_addr - 25'h1800000] = 1;
		end
		ddr_writes = ddr_writes + 1;
		ddr_ready <= 1;             // one clock later, like the arbiter when idle
	end
end

reg [7:0] j1 = 8'h12, j2 = 8'h34; reg strobe = 0;
wire [31:0] frame;

mc_telemetry dut (.clk(clk), .reset(reset), .enable(enable), .vblank(vblank), .scanline(scanline), .cycle(cycle),
	.clk_hz(32'd21477272), .sys_type(3'd0), .cpu_regs(cpu_regs),
	.bus_adr(bus_adr), .bus_dout(bus_dout), .bus_free(bus_free),
	.ram_hold(hold), .ram_rd_addr(rd_addr), .ram_rd_data(rd_data), .bm_addr(bm_addr), .bm_data(bm_data), .ram_torn(torn),
	.joy1_latched(j1), .joy2_latched(j2), .joy_strobe(strobe), .replay_active(1'b0),
	.ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_req(ddr_req), .ddr_ready(ddr_ready), .frame(frame));

localparam integer HDR  = 0;
localparam integer SLOT0 = 512;

task check(input string what, input longint got, input longint want);
	if (got !== want) begin
		$display("FAIL %s: got %h want %h", what, got, want);
		errors = errors + 1;
	end
endtask

// write one byte into the work RAM the way the CPU does: level held 12 clocks
task ram_write(input [10:0] a, input [7:0] d);
	@(posedge clk); wr <= 1; wr_addr <= a; wr_data <= d;
	repeat (12) @(posedge clk);
	wr <= 0; @(posedge clk);
endtask

task pulse_strobe;
	@(posedge clk); strobe <= 1; @(posedge clk); strobe <= 0;
endtask

task frame_tick;  // vblank rising edge, then wait for the snapshot to finish
	@(posedge clk); vblank <= 1;
	repeat (20) @(posedge clk);
	vblank <= 0;
	wait (dut.st == dut.IDLE);
	repeat (4) @(posedge clk);
endtask

longint slot;
initial begin
	repeat (5) @(posedge clk);
	reset = 0;
	// power-on style clear of the bitmap, then a few RAM writes
	clear = 1; repeat (3) @(posedge clk); clear = 0;
	repeat (300) @(posedge clk);
	ram_write(11'h000, 8'hAA);
	ram_write(11'h001, 8'hBB);
	ram_write(11'h7FF, 8'hCC);
	ram_write(11'h75A, 8'h03);   // "lives" in SMB
	pulse_strobe; pulse_strobe;   // two strobes this frame

	// ---- frame 1
	frame_tick;
	check("frame", frame, 1);
	slot = SLOT0 + 1*512;
	check("hdr magic", ddr[HDR+0], 64'h01005345_4E2D434D);
	check("hdr h1", ddr[HDR+1], {32'd4096, 32'd1});
	check("hdr h2", ddr[HDR+2], {32'd4, 32'd1});
	check("hdr h3", ddr[HDR+3], 64'd1);
	check("slot w0", ddr[slot+0], {7'd0, cycle, 7'd0, scanline, 32'd1});
	check("slot w1", ddr[slot+1], cpu_regs);
	check("slot w2 pads/strobes/flags", ddr[slot+2], {32'd0, 5'd0, 1'b0, 1'b0, 1'b1, 8'd2, j2, j1});
	check("regs word 0", ddr[slot+8+0], {8{8'd0}} ^ 64'hA5A5_0000_0000_0000);
	check("regs word 63", ddr[slot+8+63], {8{8'd63}} ^ 64'hA5A5_0000_0000_0000);
	check("ram word 0", ddr[slot+72+0][15:0], 16'hBBAA);
	check("ram word 255 top byte", ddr[slot+72+255][63:56], 8'hCC);
	check("ram $075A", ddr[slot+72+(11'h75A>>3)][(11'h75A%8)*8 +: 8], 8'h03);
	check("bitmap byte 0", ddr[slot+328+0][7:0], 8'b0000_0011);
	check("bitmap byte 255", ddr[slot+328+31][63:56], 8'b1000_0000);
	check("bitmap $075A", ddr[slot+328+((11'h75A>>3)>>3)][((11'h75A>>3)%8)*8 + (11'h75A%8)], 1'b1);
	check("tail", ddr[slot+360], {32'd1, 32'd1});

	// ---- frame 2: no strobes (lag frame); a write during the hold must not
	// appear in this image but in the next
	fork
		frame_tick;
		begin
			wait (hold);
			repeat (40) @(posedge clk);
			ram_write(11'h000, 8'h55);   // arrives while held
		end
	join
	check("frame", frame, 2);
	slot = SLOT0 + 2*512;
	check("lag frame strobes", ddr[slot+2][23:16], 8'd0);
	check("held write not in frame 2", ddr[slot+72+0][7:0], 8'hAA);
	check("torn flag clear", ddr[slot+2][25], 1'b0);

	// ---- frame 3: the held write has drained
	frame_tick;
	slot = SLOT0 + 3*512;
	check("drained write in frame 3", ddr[slot+72+0][7:0], 8'h55);
	check("hdr h2 frame 3", ddr[HDR+2][31:0], 32'd3);

	// ---- frame 4: telemetry off: header still written, slot 0 untouched
	enable = 0;
	for (i = 0; i < 4096; i = i + 1) ddr_seen[i] = 0;
	frame_tick;
	check("off: hdr h2", ddr[HDR+2][31:0], 32'd4);
	check("off: hdr h3 flags", ddr[HDR+3][31:0], 32'd0);
	check("off: slot untouched", ddr_seen[SLOT0 + 0*512], 0);

	// ---- frame 5: bus busy mid-read: flag clears, RAM still written
	enable = 1;
	fork
		frame_tick;
		begin
			wait (dut.st == dut.REGS_GET);
			repeat (30) @(posedge clk);
			bus_free = 0;
			repeat (200) @(posedge clk);
			bus_free = 1;
		end
	join
	slot = SLOT0 + 1*512;
	check("bus busy: regs flag clear", ddr[slot+2][24], 1'b0);
	check("bus busy: ram present", ddr[slot+72+0][7:0], 8'h55);
	check("bus busy: tail", ddr[slot+360][31:0], 32'd5);

	$display("%0d DDR writes over 5 frames", ddr_writes);
	if (errors == 0) $display("PASS"); else $display("%0d FAILURES", errors);
	$finish;
end

// measure one snapshot's length in clocks
integer t0, t1;
always @(posedge clk) begin
	if (dut.st == dut.IDLE && vblank && !dut.vblank_d) t0 = $time;
	if (dut.st == dut.WRITE && dut.after_write == dut.IDLE && dut.ddr_req) begin
		t1 = $time;
		$display("snapshot: %0d clocks (%0.1f us)", (t1 - t0) / 46.56, (t1 - t0) / 1000.0);
	end
end

endmodule
