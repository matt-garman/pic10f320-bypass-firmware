# Validation suite — PIC10F320 bypass firmware

This project is the deliberately lower-tier, single-file sibling of
`mcu-bypass-firmware` (see the top-level `README.md` for why). The parent factors
its debounce logic into a *pure*, host- and formally-verified core
(`bypass_pure.c`); this firmware inlines that logic into `main()` to fit the
PIC10F320's 256-word flash, so there is no separable pure unit *inside the
firmware* to test directly.

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
| Build + flash budget | `all` | Compiles for the PIC10F320 and fits in 256 words (currently 206, 80.5%). | XC8 |
| Bug-finding analysis | `analyze-cppcheck` | No cppcheck findings. | cppcheck (`pic8-enhanced`) |
| MISRA-C:2012 | `analyze-misra` | Zero MISRA deviations (`../MISRA_COMPLIANCE.md`). | cppcheck + MISRA addon |
| CONFIG word | `test-config` | The CONFIG word XC8 emitted matches design intent (`0x389E`). | host `gcc` |
| **Model: unit/property/fuzz** | `test-host` | The model satisfies the reliability properties over directed + fuzz + Monte-Carlo inputs. | host `gcc` |
| **Model: exhaustive state space** | `test-model-check` | All invariants hold over every reachable state (BFS) + the fault path. | host `gcc` |
| **Model: symbolic single-step** | `test-symbolic` | The per-step transition relation holds over the full input domain. | host `gcc` |
| **Model: bounded model checking** | `test-cbmc` | Same invariants via a SAT/SMT engine, plus freedom from UB (overflow/conversion/bounds). | cbmc |
| **Firmware ↔ model equivalence** | `test-equiv` | The *real firmware* produces the model's exact LED/CD4053 trace over 262k exhaustive + thousands of random stimuli. | host `gcc` |
| **Firmware fault injection** | `test-fault` | The *real firmware*'s defensive layer detects SEU/EMI state corruption and forces a watchdog reset (and valid states do not). | host `gcc` |
| **Firmware on a simulated core** | `test-gpsim` | The real built HEX behaves correctly on a simulated PIC10F320 (two scenarios). | gpsim |
| Model coverage gate | `coverage-check` | Model line coverage ≥ 95% (host + formal combined; currently 100%). | gcov |
| Firmware coverage gate | `coverage-check-fw` | Every *firmware* line is covered on the host except the allow-listed watchdog-reset fault path. | gcov |

`make test` runs all of the above in order. `make test-formal` runs just the
three formal engines; `make test-mutation` (below) is separate.

## The equivalence test (`equiv/`)

This is the centrepiece that ties the firmware to the verified model. A mock
`<xc.h>` (`equiv/xc.h`) replaces the device SFRs with host storage and turns
`CLRWDT()` into a per-tick hook, so the **actual** `bypass_mcu_pic10f320.c` runs
on the host one main-loop iteration per simulated tick. `fw_harness.c` captures
its `LATA` (LED RA0 + CD4053 RA1) output per tick; `test_equiv.c` compares that
trace against the model for the same footswitch stimulus — exhaustively for all
length-18 patterns (both power-on states) and over thousands of randomized
longer sequences.

It also **auto-guards against threshold drift**: the firmware defines its
`PRESSED_THRESH`/`RELEASE_THRESH` inline and the model defines its own
(`model/bypass_config.h`); if they ever disagree, the traces diverge and this
test fails. (Verified with a deliberate-mismatch negative control.)

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
0=pressed), RA0 = LED, RA1 = CD4053; ENGAGED → `LATA = 0x3`.

- **`pic/footswitch_toggle.stc`**: power-on BYPASS → momentary press toggles +
  latches ENGAGED → second press toggles back. (toggle-on-press, latching, re-arm.)
- **`pic/power_on_pressed.stc`**: a switch held CLOSED at power-on must come up
  BYPASS and not engage until a genuine release + fresh press.

## Mutation testing (`make test-mutation`)

Confirms the suite has teeth: it injects deliberate faults into the firmware and
the model on a throwaway copy and checks each is detected. Firmware logic mutants
are killed by `test-equiv` / `test-gpsim`; firmware *defensive*-layer mutants
(e.g. a neutered pull-up or output-pin check) by `test-fault`; model mutants by
`test-host` / `test-model-check`. Not part of `make test` (it rebuilds per
mutant). Currently 18 mutants, all killed.

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
  hardware-bench concern. A long-run gpsim soak (portable from the parent's
  `test_soak_pic.cc`) could be added later.
- **KLEE symbolic execution** is optional (`test_symbolic.c` supports `-DUSE_KLEE`)
  and not wired into a Make target; the exhaustive host enumeration covers the
  same domain.

## Toolchain

XC8 v3.10 + PIC10-12Fxxx DFP; cppcheck 2.13 + MISRA addon (`misra.py`) + python3;
gpsim 0.32.1 (native `p10f320` support); cbmc; host `gcc` + `gcov`. Override
paths via the `Makefile` variables (`PIC_CC`, `PIC_DFP`, `CPPCHECK`, `GPSIM`,
`CBMC`, `HOST_CC`).
