# PIC10F320 Bypass Firmware

[![CI](https://github.com/matt-garman/pic10f320-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/pic10f320-bypass-firmware/actions/workflows/ci.yml)

Scaled-down, single-file bypass/debounce firmware for the
**PIC10F320**, supporting all three of the parent project's output
stages — **analog-switch simple**, **analog-switch with mute**, and
the **TQ2 latching relay** — in **five build variants**: each
analog-switch stage comes in two control-pin drive polarities, an
inverting **CD4053** (driven through a MOSFET inverter at 9–18 V) and
a direct-drive **TMUX4053** (driven at logic level), giving
**cd4053-simple / tmux4053-simple / cd4053-mute / tmux4053-mute /
tq2-relay**.  The output scheme is selected at compile time with one
`OUTPUT_*` macro plus an optional polarity flag (see the Build
section). It responds to a footswitch, debounces it, toggles effect
bypass/engage, and drives a status LED.


## Design Documentation

Except for the necessary structural differences noted here, the overall design
and hardware implementation of the PIC10F320 is the same as it is for the
parent PIC10F322.  See the parent's
[DESIGN_DOCUMENTATION.adoc](https://github.com/matt-garman/mcu-bypass-firmware/blob/main/DESIGN_DOCUMENTATION.adoc) for details.


## Relationship to the parent project

This is intentionally a separate child project of
[mcu-bypass-firmware](https://github.com/matt-garman/mcu-bypass-firmware).

- The parent is the textbook-grade, fully-validated reference firmware (AVR
  Classic and PIC10F322). Its design is built around a *pure*,
  host- and formally-verified debounce core (`bypass_pure.c`): the algorithm
  is written as side-effect-free functions returning result structs, which is
  what makes it unit- and model-checkable on a host.
- The PIC10F320 is a smaller device with only **256 words of program flash** (half the
  PIC10F322's 512). The parent's pure/result-struct architecture does not fit that
  budget, so this project takes a different route: the debounce logic is **inlined
  into `main()`**, mutating a file-global context and driving the hardware directly.
  The assurance the parent gets *for free* by compiling its verified core straight
  into the firmware is instead **recovered here by proving the inlined firmware
  behaviourally identical to that same verified core** (see Validation).
- Current footprint, per output stage (all fit the 256-word budget):
  **cd4053-simple 202 (78.9%)**, **cd4053-with-mute 225 (87.9%)**,
  **tq2-relay 225 (87.9%)**; 10 / 64 bytes RAM. The direct-drive
  **tmux4053-\*** variants build the same driver source with the
  control-pin polarity flipped — only `bsf`↔`bcf` (both single-word)
  swap — so each matches its `cd4053-*` sibling's word count.

**Validation:** because the firmware inlines its logic, it is
validated in layers (see `test/README.md`): the parent's pure
debounce core is vendored as a **reference model** and run through
the full host + formal suite (unit/property/ fuzz, exhaustive
state-space, symbolic, and CBMC); the **real firmware** is then
proven behaviorally identical to that model: tick-for-tick over
exhaustive + random stimulus on the host (comparing the status-LED
bit RA0, the one output that means the same thing for every variant,
with a gate that the stimulus visits *every* reachable model state).
The per-variant control pins (RA1/RA2) are pinned by a host
**actuation-sequence** test that asserts each variant's full *settled*
`LATA` at every tick; so even cd4053-simple's lone control pin, which
has no blocking pulse for a snapshot to catch, is verified on the host;
plus the mute/relay drivers' *mid-actuation* sequencing and pulse width
that neither the RA0 trace nor a settled snapshot can see. Because the
direct-drive (TMUX4053) variants *invert* those control pins — so
BYPASS no longer settles to `0x0` — both the host actuation check and
the gpsim test assert each variant's full BYPASS *and* ENGAGED
control-pin pattern, catching a wrong drive polarity. The real HEX is
independently re-checked on a simulated core in gpsim; and
the real firmware's **defensive layer** (the SEU/EMI sanity gate and
watchdog-reset path, which valid stimulus never reaches) is
exercised by a host **fault-injection** harness — and re-verified on a
simulated core (`test-fault-gpsim`), where corrupting every guarded
SFR/`ctx_`-SRAM location in the real HEX forces exactly one real
watchdog reset. Static analysis
(cppcheck + MISRA-C:2012, zero deviations), CONFIG-word
verification, mutation testing, and model + firmware coverage gates
round it out. `make test` runs all of it for the selected variant;
`make test-variants` sweeps all five. A long-run `make test-soak`
(libgpsim), silicon-level fault injection (`make test-fault-gpsim`), and
an optional KLEE pass (`make test-symbolic-klee`) are available as
standalone targets.

**The one structural difference:** the parent compiles its formally-verified pure
core *directly into* the shipping firmware: the tested code and the flashed code
are the same translation unit. The 10F320's flash can't fit that, so this project
vendors that exact core as a reference model, runs the full host and formal suite
against it, and proves the hand-inlined firmware behaviourally identical to it
(every output pin checked at every settled tick, the mute/relay mid-actuation
sequencing pinned separately, and the real HEX re-checked in gpsim). That
*bridges* the inlining seam rather than *eliminating* it: a single,
heavily-mitigated trust assumption the parent doesn't carry. On the remaining
axes the two are at parity, including the hardware-bench gaps, since WDT timing
and brown-out *behaviour* are equally unsimulable in gpsim for the parent's
PIC10F322 build (gpsim's WDT calibration differs from silicon and it has no analog
BOR model; the CONFIG check proves those features are *enabled*, not their
real-time timing; see *Known gaps* in `test/README.md`).

**When to use which:** the parent remains the authoritative,
preferred project: it is the canonical home of the verified core and
supports more parts (AVR Classic and PIC10F322), so prefer it
whenever you can choose the part. Use this firmware when the
PIC10F320 is a hard requirement (it targets the same robustness
level by a different (but not lesser) validation strategy).


## Provenance

The debounce algorithm here is a **manual instantiation** of the parent's
verified pure core — byte-for-byte identical arithmetic and state transitions,
merely re-packaged (inlined, global-mutating) to fit flash. The three output
drivers are likewise instantiations of the parent's per-variant output stages
(`bypass_output_*.c`), inlined into the firmware's `#if defined(OUTPUT_*)` blocks;
the two analog-switch stages also carry the parent's CD4053-vs-TMUX4053 control-pin
drive polarity (`BYPASS_X4053_DIRECT_DRIVE`), which is what turns three stages into
five build variants.

- **Derived from:** `mcu-bypass-firmware` @ commit
  `7384215` (`73842153b3764c0c9e8771a40502d15edd3386c4`).
- **Correctness is inherited by derivation** from that core's host + formal
  verification; it is *not* independently re-proven in this repository.
- This is a **frozen one-off**. It is *not* automatically kept in sync with
  the parent; the parent may advance without this project following.


## Manual-sync contract

If the parent's debounce behavior ever changes, it must be mirrored here **by
hand**. The shared surface is small, finite, and auditable — nothing else is
shared at the source level:

| Item                      | Parent source                              | Here                              |
| ------------------------- | ------------------------------------------ | -------------------------------- |
| Press threshold           | `PRESSED_THRESH` (8) in `bypass_config.h`  | `PRESSED_THRESH`                 |
| Release/lockout threshold | `RELEASE_THRESH` (25) in `bypass_config.h` | `RELEASE_THRESH`                 |
| Saturating integrator     | `debounce_integrate()` in `bypass_pure.c`  | inlined in the `main()` loop     |
| State machine             | `debounce_step()` in `bypass_pure.c`       | inlined `switch` in `main()`     |
| Power-on init             | `debounce_init_context()` in `bypass_pure.c` | inlined in `init()`            |
| Output stages             | `bypass_output_{cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay}.c` | inlined `#if defined(OUTPUT_*)` blocks |
| Analog-switch polarity    | `bypass_output_x4053_polarity.h` (`BYPASS_X4053_DIRECT_DRIVE`) | inlined `hw_x4053_ctl_high/low` macros |

The pin map (RA3 footswitch, RA0 LED, RA1/RA2 control) and the CONFIG word are
PIC-local and are *not* shared with the parent.


## Build

Requires Microchip XC8 v3.10 and the PIC10-12Fxxx DFP (see
[TOOLCHAIN.adoc](TOOLCHAIN.adoc) for the full pinned toolchain).

```sh
make          # build the .hex (default variant) and check the 256-word budget
make size     # print XC8's full program/data memory summary
make help     # the full annotated target list (build / test / release / clean)
make clean    # remove the build directory
```

Select the output variant with `PIC_VARIANT` (default `cd4053-simple`):

```sh
make PIC_VARIANT=cd4053-simple    # LED(RA0) + CD4053(RA1), inverting (MOSFET) drive
make PIC_VARIANT=tmux4053-simple  # as above but direct-drive TMUX4053 (control pins inverted)
make PIC_VARIANT=cd4053-mute      # LED(RA0) + CTL1(RA1) + CTL2(RA2), pre-switch mute
make PIC_VARIANT=tmux4053-mute    # as above but direct-drive TMUX4053 (control pins inverted)
make PIC_VARIANT=tq2-relay        # LED(RA0) + RESET(RA1) + SET(RA2), latching relay
```

The `tmux4053-*` variants add `-DBYPASS_X4053_DIRECT_DRIVE`; they share their
`cd4053-*` sibling's driver source and switching logic, differing only in the
analog-switch control-pin drive polarity.

Override the toolchain paths on the command line if your install differs:

```sh
make PIC_CC=/path/to/xc8-cc PIC_DFP=/path/to/DFP/x.y.z/xc8
```

The build lands in `build_pic/bypass_mcu_<variant>_pic10f320.hex` (e.g.
`build_pic/bypass_mcu_cd4053-simple_pic10f320.hex`).


## Prebuilt releases

If you just want to flash a chip without installing XC8, prebuilt, fully
validated images are published under [`release/`](release/) and as
[GitHub Releases](https://github.com/matt-garman/pic10f320-bypass-firmware/releases).
Each release pins the image bytes with a `SHA256SUMS` manifest, and the
tag-triggered CI rebuilds from source on a clean runner and **fails the release
unless the images reproduce those hashes bit-for-bit** — so a published binary is
provably what the tested source compiles to. See
[`release/README.md`](release/README.md) for the trust model and verification
steps. Maintainers stage a release with `make release VERSION=vX.Y.Z` (see
`scripts/make-release.sh`).
