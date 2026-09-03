#!/bin/sh
# Simulate rtl/mc with Icarus Verilog (brew install icarus-verilog).
set -e
cd "$(dirname "$0")/.."
iverilog -g2012 -o sim/tb_mc.vvp sim/tb_mc.sv rtl/mc/mc_shadow_ram.sv rtl/mc/mc_telemetry.sv
vvp -n sim/tb_mc.vvp | tail -3
iverilog -g2012 -o sim/tb_replay.vvp sim/tb_replay.sv rtl/mc/mc_replay.sv
vvp -n sim/tb_replay.vvp | tail -12
