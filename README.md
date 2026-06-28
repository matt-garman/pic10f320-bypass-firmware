# PIC10F320 Bypass Firmware

Scaled-down, single-file bypass/debounce firmware for the **PIC10F320**,
supporting the **CD4053-simple** output only. It responds to a footswitch,
debounces it, toggles effect bypass/engage, and drives a status LED.


## Project tier

This is intentionally the **lower-tier, best-effort, one-off**
sibling of the
[mcu-bypass-firmware](https://https://github.com/matt-garman/mcu-bypass-firmware)
project. Read that distinction literally:

- The parent is the textbook-grade, fully-validated reference firmware (AVR
  classic + ATtinyx5 + PIC10F322). Its design is built around a *pure*,
  host- and formally-verified debounce core (`bypass_pure.c`): the algorithm
  is written as side-effect-free functions returning result structs, which is
  what makes it unit- and model-checkable on a host.
- The PIC10F320 has only **256 words of program flash** — half the
  PIC10F322's 512. Fitting the parent's pure/result-struct architecture into
  that budget required too many compromises to its reliability goals, so this
  project deliberately trades that architecture away: the debounce logic is
  **inlined into `main()`**, mutating a file-global context and driving the
  hardware directly.
- Current footprint: **206 / 256 words flash (80.5%)**, 10 / 64 bytes RAM.

**Validation:** because the firmware inlines its logic, it is validated in
layers (see `test/README.md`): the parent's pure debounce core is vendored as a
**reference model** and run through the full host + formal suite (unit/property/
fuzz, exhaustive state-space, symbolic, and CBMC); the **real firmware** is then
proven behaviorally identical to that model — tick-for-tick over exhaustive +
random stimulus on the host, and on a simulated core in gpsim; and the real
firmware's **defensive layer** (the SEU/EMI sanity gate and watchdog-reset path,
which valid stimulus never reaches) is exercised by a host **fault-injection**
harness. Static analysis (cppcheck + MISRA-C:2012, zero deviations), CONFIG-word
verification, mutation testing, and model + firmware coverage gates round it out.
`make test` runs all of it.

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
merely re-packaged (inlined, global-mutating) to fit flash.

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

The pin map (RA3 footswitch, RA0 LED, RA1 CD4053) and the CONFIG word are
PIC-local and are *not* shared with the parent.


## Build

Requires Microchip XC8 v3.10 and the PIC10-12Fxxx DFP.

```sh
make          # build the .hex and check it against the 256-word flash budget
make size     # print XC8's full program/data memory summary
make clean    # remove the build directory
```

Override the toolchain paths on the command line if your install differs:

```sh
make PIC_CC=/path/to/xc8-cc PIC_DFP=/path/to/DFP/x.y.z/xc8
```

The build lands in `build_pic/bypass_mcu_pic10f320.hex`.
