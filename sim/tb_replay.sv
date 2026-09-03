// Testbench for rtl/mc/mc_replay.sv with a DDR read model.
// Run: sim/run.sh (both benches)
`timescale 1ns/1ps

module tb_replay;

reg clk = 0;
always #23.28 clk = ~clk;

reg reset = 1, vblank = 0;
integer errors = 0;

// DDR model: 64 words from the replay header word
localparam [24:0] HDR_W = 25'h1820000;
reg [63:0] mem [0:63];
integer i;
initial for (i = 0; i < 64; i = i + 1) mem[i] = 0;

wire [24:0] ddr_addr; wire ddr_req; reg [63:0] ddr_dout; reg ddr_ready = 0;
reg [24:0] rq_addr; reg [2:0] lat = 0;
always @(posedge clk) begin
	ddr_ready <= 0;
	if (ddr_req) begin rq_addr <= ddr_addr; lat <= 3'd5; end        // ~20 clock latency scaled down
	else if (lat > 1) lat <= lat - 3'd1;
	else if (lat == 1) begin
		lat <= 0;
		if (rq_addr < HDR_W || rq_addr >= HDR_W + 64) begin $display("FAIL read outside buffer %h", rq_addr); errors = errors + 1; end
		else ddr_dout <= mem[rq_addr - HDR_W];
		ddr_ready <= 1;
	end
end

wire active; wire [7:0] p1, p2, state, gen; wire [31:0] index;
mc_replay dut (.clk(clk), .reset(reset), .vblank(vblank), .ddr_addr(ddr_addr), .ddr_req(ddr_req), .ddr_dout(ddr_dout), .ddr_ready(ddr_ready),
	.active(active), .p1(p1), .p2(p2), .index(index), .state(state), .gen(gen));

task check(input string what, input longint got, input longint want);
	if (got !== want) begin $display("FAIL %s: got %0d want %0d", what, got, want); errors = errors + 1; end
endtask

task frame;   // one vblank edge
	@(posedge clk); vblank <= 1; repeat (10) @(posedge clk); vblank <= 0; repeat (30) @(posedge clk);
endtask

// let the poll timer fire: force it near the wrap
task poll;
	@(negedge clk) dut.poll_cnt = dut.POLL_CLKS - 2;
	repeat (60) @(posedge clk);   // three header reads and the evaluation
endtask

task arm(input [31:0] frames, input [7:0] g);
	mem[0] = 64'h59414C50_522D434D;
	mem[1] = {24'd0, g, frames};
	mem[2] = 64'd1;
endtask


initial begin
	// entries: frame i has p1 = i+1, p2 = 0x80+i
	for (i = 0; i < 10; i = i + 1) begin
		if (i % 2 == 0) mem[8 + i/2][31:0]  = {8'd0, 8'd0, 8'h80 + i[7:0], i[7:0] + 8'd1};
		else            mem[8 + i/2][63:32] = {8'd0, 8'd0, 8'h80 + i[7:0], i[7:0] + 8'd1};
	end
	repeat (5) @(posedge clk);

	// nothing armed: stays idle, no pads
	poll; check("idle state", state, 0); check("idle active", active, 0);

	// arm 10 frames while the core is in reset (a ROM load)
	arm(10, 8'd7); poll;
	check("armed", state, 1); check("gen", gen, 7); check("still inactive", active, 0);

	// reset releases: entry 0 presented at once
	@(posedge clk); reset <= 0; repeat (3) @(posedge clk);
	check("run", state, 2); check("active", active, 1); check("p1 e0", p1, 1); check("p2 e0", p2, 8'h80); check("index 0", index, 0);

	// frames 1..9
	for (i = 1; i < 10; i = i + 1) begin
		frame;
		check($sformatf("index %0d", i), index, i);
		check($sformatf("p1 e%0d", i), p1, i + 1);
		check($sformatf("p2 e%0d", i), p2, 8'h80 + i);
		check("active during run", active, 1);
	end
	frame;   // the 11th vblank: past the end
	check("done", state, 3); check("inactive after done", active, 0);

	// re-arm with the same generation: ignored; new generation: armed again
	arm(10, 8'd7); poll; check("same gen ignored", state, 3);
	arm(4, 8'd8); poll; check("new gen armed", state, 1);
	// abort while armed
	mem[2] = 64'd3; poll; check("abort while armed", state, 4);

	// unsupported command inside a movie: stops at that entry
	mem[8][63:32] = {8'd0, 8'd1, 8'h81, 8'd2};   // entry 1 (high half of word 8) carries the reset command
	mem[2] = 64'd1; arm(10, 8'd9); poll; check("armed again", state, 1);
	reset <= 1; repeat (3) @(posedge clk); reset <= 0; repeat (3) @(posedge clk);
	check("run again", state, 2);
	frame; check("unsupported cmd", state, 5); check("inactive after unsupported", active, 0);
	mem[8][63:32] = {8'd0, 8'd0, 8'h81, 8'd2};

	// a reset during a run aborts it
	arm(10, 8'd10); poll; reset <= 1; repeat (3) @(posedge clk); reset <= 0; repeat (3) @(posedge clk);
	frame; check("running", state, 2);
	reset <= 1; repeat (3) @(posedge clk); check("reset aborts", state, 4); reset <= 0;

	// a frame edge that lands during a header poll is not lost
	arm(10, 8'd11); poll; reset <= 1; repeat (3) @(posedge clk); reset <= 0; repeat (3) @(posedge clk);
	@(negedge clk) dut.poll_cnt = dut.POLL_CLKS - 1; @(posedge clk); @(posedge clk); @(posedge clk);   // poll read in flight
	vblank <= 1; repeat (10) @(posedge clk); vblank <= 0; repeat (40) @(posedge clk);
	check("edge kept during poll", index, 1);

	if (errors == 0) $display("PASS"); else $display("%0d FAILURES", errors);
	$finish;
end

endmodule
