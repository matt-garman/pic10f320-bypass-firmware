# Validation suite — PIC10F320 bypass firmware

This project is the deliberately lower-tier, single-file sibling of
`mcu-bypass-firmware` (see the top-level `README.md` for why). The parent factors
its debounce logic into a *pure*, host- and formally-verified core
(`bypass_pure.c`); this firmware inlines that logic into `main()` to fit the
PIC10F320's 256-word flash, so there is no separable pure unit *inside the
firmware* to test directly. The firmware supports all three output variants
(`cd4053-simple`, `cd4053-mute`, `tq2-relay`) via one `OUTPUT_*` macro; pick the
one under test with `make PIC_VARIANT=...` (default `cd4053-simple`), or sweep
all three with `make test-variants`.

To get as close to the parent as possible anyway, validation here is built in
**two layers**:

1. **Reference model** (`model/`): a verbatim copy of the parent's verified pure
   core. We run the full host + formal suite against it.
2. **Equivalence**: we prove the *real firmware* behaves identically to that
   model, tick for tick, by running the actual compiled firmware logic on the
   host (`equiv/`) and in gpsim. So the model's host/formal guarantees transfer
   to the shipping code, and the firmware is never validated only "by assertion."
3. **Fault injection** (`fault/`): the model is hardware-free, so it has no
   notion of the firmware's *defensive* layer — the per-tick SEU/EMI sanity gate,
   the pull-up / output-pin checks, and `hw_force_wdt_reset()`. Valid stimulus
   never trips those, so the equivalence layer can't reach them. This layer runs
   the real firmware on the host and *injects* corrupted state to prove the fault
   path fires (and that valid states don't). It also backs the **firmware**
   coverage gate.

Everything runs from the top-level `Makefile`; each target skips cleanly
(exit 0) when its tool is absent.

## What runs (`make test`)

| Layer | Target | What it proves | Tool |
| --- | --- | --- | --- |
| Build + flash budget | `all` | Compiles the selected variant for the PIC10F320 and fits in 256 words (208 / 238 / 233 for cd4053-simple / -mute / tq2-relay). | XC8 |
| Bug-finding analysis | `analyze-cppcheck` | No cppcheck findings. | cppcheck (`pic8-enhanced`) |
| MISRA-C:2012 | `analyze-misra` | Zero MISRA deviations (`../MISRA_COMPLIANCE.md`). | cppcheck + MISRA addon |
| CONFIG word | `test-config` | The CONFIG word XC8 emitted matches design intent (`0x389E`). | host `gcc` |
| **Model: unit/property/fuzz** | `test-host` | The model satisfies the reliability properties over directed + fuzz + Monte-Carlo inputs. | host `gcc` |
| **Model: exhaustive state space** | `test-model-check` | All invariants hold over every reachable state (BFS) + the fault path. | host `gcc` |
| **Model: symbolic single-step** | `test-symbolic` | The per-step transition relation holds over the full input domain. | host `gcc` |
| **Model: bounded model checking** | `test-cbmc` | Same invariants via a SAT/SMT engine, plus freedom from UB (overflow/conversion/bounds). | cbmc |
| **Firmware ↔ model equivalence** | `test-equiv` | The *real firmware* reproduces the model's exact status-LED (RA0) trace over 262k exhaustive + thousands of random stimuli, and the stimulus visits every reachable model state. | host `gcc` |
| **Firmware actuation sequence** | `test-actuation` | The *real firmware*'s blocking mute/relay drivers assert the correct control pins (and pulse width) *during* each actuation — the transient that equiv (RA0-only) and gpsim (settled-state-only) cannot see. | host `gcc` |
| **Firmware fault injection** | `test-fault` | The *real firmware*'s defensive layer detects SEU/EMI state corruption and forces a watchdog reset (and valid states do not). | host `gcc` |
| **Firmware on a simulated core** | `test-gpsim` | The real built HEX behaves correctly on a simulated PIC10F320, including the variant's full ENGAGED control-pin pattern (two scenarios). | gpsim |
| Model coverage gate | `coverage-check` | Model line coverage ≥ 95% (host + formal combined; currently 100%). | gcov |
| Firmware coverage gate | `coverage-check-fw` | Every *firmware* line is covered on the host except the allow-listed watchdog-reset fault path. | gcov |

`make test` runs all of the above in order **for the selected variant**;
`make test-variants` repeats the whole suite for all three. `make test-formal`
runs just the three formal engines. Standalone (not in `make test`):
`make test-mutation` (below), `make test-soak` (a long-run libgpsim soak), and
`make test-symbolic-klee` (the symbolic step check under KLEE, if installed).

## The equivalence test (`equiv/`)

This is the centrepiece that ties the firmware to the verified model. A mock
`<xc.h>` (`equiv/xc.h`) replaces the device SFRs with host storage and turns
`CLRWDT()` into a per-tick hook, so the **actual** `bypass_mcu_pic10f320.c` runs
on the host one main-loop iteration per simulated tick. `fw_harness.c` captures
its status-LED bit (`LATA` RA0) per tick — the one output that means the same
thing for all three variants (high iff ENGAGED); `test_equiv.c` compares that
trace against the model for the same footswitch stimulus — exhaustively for all
length-18 patterns (both power-on states) and over thousands of randomized
longer sequences. It also **gates state coverage**: it BFS-enumerates the model's
reachable states and asserts the stimulus drove the model through every one (so
the random sampling leaves no reachable state unverified). The variant-specific
RA1/RA2 control pins are asserted separately on the simulated core by `test-gpsim`.

It also **auto-guards against threshold drift**: the firmware defines its
`PRESSED_THRESH`/`RELEASE_THRESH` inline and the model defines its own
(`model/bypass_config.h`); if they ever disagree, the traces diverge and this
test fails. (Verified with a deliberate-mismatch negative control.)

## The actuation-sequence test (`actuation/`)

The equivalence test compares only RA0 (the status LED), and the gpsim test only
samples *settled* register state. For the two **blocking** output variants —
`cd4053-mute` and `tq2-relay` — that leaves a blind spot: each actuation asserts
the mute / energises a relay coil, calls `__delay_ms()`, then releases it, and the
*transient* mid-pulse output is exactly what those layers cannot see. A swapped
relay set/reset coil (the relay latches backwards, inverting the audio path
relative to the LED) or a defeated mute window settles to the **same** pin state,
so it passes both. That is a real manual-porting hazard here, because the pin map
and the per-variant output stages are hand-written in this project (PIC-local, not
shared with the parent) — the same class of inlining bug `test-equiv` catches for
the debounce core. Mutation testing confirmed the gap before this layer existed.

`actuation/test_actuation.c` reuses the equivalence firmware harness, but the mock
`<xc.h>` now routes the firmware's `__delay_ms()` through a hook so `fw_harness.c`
snapshots `LATA` at the instant of every actuation. The test drives one full round
trip (power-on bypass → engage → bypass) and asserts, per variant, the exact
mid-actuation pin pattern **and** the pulse width:

- **cd4053-mute**: engage muted-mid `LATA=0x5` (LED+CTL2 high, CTL1 held low),
  bypass muted-mid `0x4`, 5 ms mute window;
- **tq2-relay**: engage pulses the SET coil (`0x5` = LED+RA2), bypass pulses the
  RESET coil (`0x2` = RA1), 12 ms coil pulse;
- **cd4053-simple**: no blocking actuation, so the test asserts *zero* snapshots.

RA0 (the LED) remains the equivalence test's job; this layer is purely the variant
control pins **during** the blocking pulse (the power-on init bypass pulse is
captured and asserted too).

## The fault-injection test (`fault/`)

The equivalence test only ever presents *valid* footswitch stimulus, so the
firmware's defensive layer — the per-tick SEU/EMI sanity gate in `main()`, the
`hw_footswitch_pullup_intact()` / `hw_is_sanity_check_failed()` checks, and
`hw_force_wdt_reset()` — is never reached by it (a check that only fires on
*corrupted* state is invisible to valid stimulus). Mutation testing confirmed the
gap: that whole layer could be disabled and the rest of the suite stayed green.

`fault/fw_fault_harness.c` reuses the equivalence mock `<xc.h>` and `#include`s
the real firmware, so it can drive `main()` and corrupt the firmware's live state
between ticks. `test_fault.c` then asserts:

- **predicate probes** — the static sanity predicates return the right verdict
  for both good and SEU-corrupted SFRs (e.g. a `TRISA` bit flipped from output to
  input, a cleared `WPUA` latch, `nWPUEN` set);
- **fault injection** — after one clean iteration, an out-of-range
  `program_state`/`effect_state` or a critical-SFR flip makes the next iteration
  force a watchdog reset, while valid states (including a valid ENGAGED state) do
  *not*.

Observing the reset is the trick: `hw_force_wdt_reset()` clears `GIE` and spins
forever (on silicon the watchdog then resets the MCU). The harness arms a short
real-time timer; if the firmware enters that spin, a `SIGALRM` handler
`siglongjmp()`s back out — so "the run had to be timed out" *is* the
reset-fired signal (robust at any optimisation level, since the firmware's only
spin point is that function). This layer also drives the firmware's normal
toggle lines, so it backs the `coverage-check-fw` gate.

## gpsim functional scenarios

The closest thing to real silicon: the actual instruction stream, asserting
register state at settled checkpoints. Pins: RA3 = footswitch (1=released,
0=pressed), RA0 = LED, RA1/RA2 = the variant's control output(s). The ENGAGED
`LATA` pattern the wrapper checks is variant-specific — cd4053-simple `0x3`,
cd4053-mute `0x7`, tq2-relay `0x1` — passed as `PIC_ENGAGED_LATA`; the universal
RA0 (LED) checks hold for every variant.

- **`pic/footswitch_toggle.stc`**: power-on BYPASS → momentary press toggles +
  latches ENGAGED → second press toggles back. (toggle-on-press, latching, re-arm.)
- **`pic/power_on_pressed.stc`**: a switch held CLOSED at power-on must come up
  BYPASS and not engage until a genuine release + fresh press.

## Mutation testing (`make test-mutation`)

Confirms the suite has teeth: it injects deliberate faults into the firmware and
the model on a throwaway copy and checks each is detected. Firmware logic mutants
are killed by `test-equiv` / `test-gpsim`; firmware *defensive*-layer mutants
(e.g. a neutered pull-up or output-pin check) by `test-fault`; firmware
blocking-actuation mutants (a swapped relay set/reset coil, a defeated mute
window) by `test-actuation`; model mutants by `test-host` / `test-model-check`.
Not part of `make test` (it rebuilds per mutant). Currently 22 mutants, all
killed.

## Why CONFIG-word verification matters

A wrong `#pragma config` bit is invisible to every other test and would only bite
on real silicon: WDTE=OFF defeats the fault-recovery watchdog; MCLRE=ON turns RA3
(the footswitch) into MCLR; BOREN=OFF removes brown-out protection.
`test-config` parses the exact CONFIG word out of the built HEX and asserts the
full design intent. The PIC10F320 and PIC10F322 CONFIG words are bit-for-bit
identical in layout, so this decoder is shared with the parent.

## Known gaps (vs. the parent)

- **WDT-timing / brown-out behaviour** is not simulated here (gpsim's WDT
  calibration differs from silicon and it has no analog BOR model). The CONFIG
  check proves WDTE/BOREN are *enabled*; their real-time behaviour is a
  hardware-bench concern. The `make test-soak` long-run gpsim soak (ported from
  the parent's `test_soak_pic.cc`) exercises WDT *liveness* and periodic
  responsiveness at scale, but still asserts nothing about WDT *timing* (it uses
  the WDT only as a qualitative liveness signal — see the note in
  `pic/test_soak_pic.cc`).
- **KLEE symbolic execution** is now wired as the optional, skip-clean
  `make test-symbolic-klee` target (`test_symbolic.c` supports `-DUSE_KLEE`); it
  is not part of `make test`, since the exhaustive host enumeration
  (`test-symbolic`) and CBMC already cover the same input domain.

## Toolchain

XC8 v3.10 + PIC10-12Fxxx DFP; cppcheck 2.13 + MISRA addon (`misra.py`) + python3;
gpsim 0.32.1 (native `p10f320` support); cbmc; host `gcc` + `gcov`. Override
paths via the `Makefile` variables (`PIC_CC`, `PIC_DFP`, `CPPCHECK`, `GPSIM`,
`CBMC`, `HOST_CC`).
