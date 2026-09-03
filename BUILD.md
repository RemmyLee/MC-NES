# Building MC-NES

MC-NES is the MiSTer NES core plus a telemetry and input replay interface for
MiSTer Control. It is an additional core. It does not replace `NES_<date>.rbf`.

## Toolchain

Quartus Prime Lite 17.0.2 Build 602, Linux x86-64. This is the version the
MiSTer cores use (MiSTer docs, developer/mistercompile.md).

Download (8,764,528,640 bytes, SHA1 `02aebab728d54e3ca8660d2646fdf93bc669b0ac`):

    https://downloads.intel.com/akdlm/software/acdsinst/17.0std.2/602/ib_tar/Quartus-lite-17.0.2.602-linux.tar

The `download.altera.com` link in the MiSTer docs answers 403. The same path on
`downloads.intel.com` works.

Install, unattended, Quartus + Cyclone V only:

    tar -xf Quartus-lite-17.0.2.602-linux.tar -C q17
    q17/setup.sh --mode unattended --unattendedmodeui none \
      --installdir $HOME/intelFPGA_lite/17.0 \
      --disable-components arria_lite,cyclone,cyclone10lp,max,max10,modelsim_ase,modelsim_ae,quartus_help

The installer does not accept `--accept_eula`. The two installer processes stay
alive after "Installation completed" in the log and must be ended by hand.
Installed size: 11 GB.

Verified host: Arch Linux, kernel 7.1, Ryzen Threadripper 3960X, 94 GB RAM.
No extra libraries were needed for the command line flow (`quartus_sh`,
`quartus_map`, `quartus_fit`, `quartus_asm`, `quartus_sta`).

## Build

    scripts/build.sh            # full compile, output in out/MC-NES_<date>.rbf
    scripts/build.sh 20260903   # fixed datecode
    SEED=2 scripts/build.sh 20260903   # another fitter seed when a marginal clock misses timing

The script runs `quartus_sh --flow compile NES`, then copies
`output_files/NES.rbf` to `out/MC-NES_<date>.rbf` and writes `out/MC-NES_<date>.txt`
with the fit summary, the timing summary and the upstream commit.

Quartus rewrites `NES.qsf` on every run (version stamp, ordering). The script
restores it with `git checkout NES.qsf` afterwards so the diff stays clean.

## Reference numbers

Unmodified upstream `9a63821` (Release 20260823), first build, 2026-09-03:

| Item | Value |
|---|---|
| Wall time | 1686 s (28 min 6 s) on the 3960X |
| Logic (ALMs) | 30,344 / 41,910 (72%) |
| Registers | 35,259 |
| Block memory | 606,768 / 5,662,720 bits (11%), 104 / 553 blocks |
| DSP blocks | 51 / 112 |
| Setup slack, core clock | 2.023 ns (TNS 0) |
| Setup slack, tightest | 0.468 ns, HDMI PLL (TNS 0) |
| Critical warnings | 0 |
| `NES.rbf` | 3,304,192 bytes |

First telemetry build, `MC-NES_20260903b.rbf` (commit `ee6a0d4`, rtl/mc added):

| Item | Value |
|---|---|
| Wall time | 1676 s (27 min 56 s) |
| Logic (ALMs) | 31,034 / 41,910 (74%), +690 |
| Registers | 35,634, +375 |
| RAM blocks | 109 / 553, +5 (shadow RAM, write FIFO, bitmap) |
| Setup slack, core clock | 2.264 ns (TNS 0) |
| Setup slack, tightest | 0.323 ns, HDMI PLL (TNS 0) |
| Critical warnings | 0 |

Replay build, `MC-NES_20260903g.rbf` (commit `f4a675a`, rtl/mc/mc_replay.sv, ddram
read channel, joypad data owned by the replay while it runs; seed 2):

| Item | Value |
|---|---|
| Wall time | 1688 s (28 min 8 s) |
| Logic (ALMs) | 31,108 / 41,910 (74%) |
| Setup slack, tightest | HDMI PLL, seed dependent: 0.305 / 0.007 / 0.186 ns across three seed-2 builds of near-identical logic (TNS 0) |
| Critical warnings | 0 |
| Verified | TASVideos 1715M (Super Mario Bros. "warps", 17868 frames) plays to the ending on the box; per-frame RAM matches FCEUX |

Every later build is compared against these rows. A negative slack on any
clock is a failed build. The tightest slack sits on the HDMI PLL and moves
between builds whose difference is unrelated logic (0.468 to 0.323 ns here);
judge by "all slack positive", not by matching the previous number.

## Simulation

    sim/run.sh    # Icarus Verilog (brew install icarus-verilog); checks the DDR layout

The testbench writes frames the way the core does and checks every field the
app reads (see `rtl/mc/mc_telemetry.sv` for the layout). One snapshot takes
3741 clocks, 174 us of the 1.27 ms vblank.

## Upstream tracking

Remote `upstream` = `https://github.com/MiSTer-devel/NES_MiSTer.git`. Branch `mc`
carries our changes. On an upstream release: `git fetch upstream`,
`git rebase upstream/master`, build, run the regression in
`mister-control/docs/PLAN-mc-cores.md`, release.

Last upstream commit built: `9a63821` (Release 20260823).
