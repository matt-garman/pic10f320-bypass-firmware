# PIC10F320 Bypass Firmware

[![CI](https://github.com/matt-garman/pic10f320-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/pic10f320-bypass-firmware/actions/workflows/ci.yml)

Scaled-down, single-file bypass/debounce firmware for the
**PIC10F320**, supporting all three of the parent project's output
stages: **CD4053-simple**, **CD4053-with-mute**, and the **TQ2
latching relay**.  Output scheme is selected at compile time with
one `OUTPUT_*` macro (see the Build section). It responds to a
footswitch, debounces it, toggles effect bypass/engage, and drives a
status LED.


## Project tier

This is intentionally a separate child project of
[mcu-bypass-firmware](https://github.com/matt-garman/mcu-bypass-firmware)
project.

- The parent is the textbook-grade, fully-validated reference firmware (AVR
  Classic and PIC10F322). Its design is built around a *pure*,
  host- and formally-verified debounce core (`bypass_pure.c`): the algorithm
  is written as side-effect-free functions returning result structs, which is
  what makes it unit- and model-checkable on a host.
- The PIC10F320 is a smaller device with only **256 words of program flash** (half the
  PIC10F322's 512). Fitting the parent's pure/result-struct architecture into
  that budget required too many compromises to its reliability goals, so this
  project deliberately trades that architecture away: the debounce logic is
  **inlined into `main()`**, mutating a file-global context and driving the
  hardware directly.
- Current footprint, per output variant (all fit the 256-word budget):
  **cd4053-simple 208 (81.2%)**, **cd4053-with-mute 238 (93.0%)**,
  **tq2-relay 233 (91.0%)**; 10–11 / 64 bytes RAM.

**Validation:** because the firmware inlines its logic, it is
validated in layers (see `test/README.md`): the parent's pure
debounce core is vendored as a **reference model** and run through
the full host + formal suite (unit/property/ fuzz, exhaustive
state-space, symbolic, and CBMC); the **real firmware** is then
proven behaviorally identical to that model — tick-for-tick over
exhaustive + random stimulus on the host (comparing the status-LED
bit RA0, the one output that means the same thing for every variant,
with a gate that the stimulus visits *every* reachable model state),
and on a simulated core in gpsim (which also asserts each variant's
full ENGAGED control-pin pattern), with the mute/relay drivers'
*mid-actuation* control-pin sequencing and pulse width — the
transient neither the RA0 trace nor gpsim's settled snapshots can
see — pinned separately by a host **actuation-sequence** test; and
the real firmware's **defensive layer** (the SEU/EMI sanity gate and
watchdog-reset path, which valid stimulus never reaches) is
exercised by a host **fault-injection** harness. Static analysis
(cppcheck + MISRA-C:2012, zero deviations), CONFIG-word
verification, mutation testing, and model + firmware coverage gates
round it out. `make test` runs all of it for the selected variant;
`make test-variants` sweeps all three. A long-run `make test-soak`
(libgpsim) and an optional KLEE pass (`make test-symbolic-klee`) are
available as standalone targets.

**Still lower-tier:** the gaps that remain are real — WDT-timing / brown-out
*behaviour* is not simulated (gpsim's WDT calibration differs from silicon and it
has no analog BOR model); the CONFIG check proves those features are enabled, not
their real-time timing.

**When to use which:** use this firmware when the PIC10F320 is a hard
requirement. When you can choose the part, prefer the parent project's
PIC10F322 or AVR Classic build for maximum assurance.


## Provenance

The debounce algorithm here is a **manual instantiation** of the parent's
verified pure core — byte-for-byte identical arithmetic and state transitions,
merely re-packaged (inlined, global-mutating) to fit flash. The three output
drivers are likewise instantiations of the parent's per-variant output stages
(`bypass_output_*.c`), inlined into the firmware's `#if defined(OUTPUT_*)` blocks.

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
make PIC_VARIANT=cd4053-simple   # LED(RA0) + CD4053(RA1)
make PIC_VARIANT=cd4053-mute     # LED(RA0) + CTL1(RA1) + CTL2(RA2), pre-switch mute
make PIC_VARIANT=tq2-relay       # LED(RA0) + RESET(RA1) + SET(RA2), latching relay
```

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
