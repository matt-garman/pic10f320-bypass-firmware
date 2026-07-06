# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses a `0.9.x` pre-1.0 series while the firmware and its
validation suite settle; `1.0.0` is intended once the API/behaviour and the
release process are considered stable.

Per-release provenance (source commit, pinned toolchain, image hashes, flash
usage, and validation evidence) lives in `release/<version>/MANIFEST.md`; this
file is the human-readable summary of *what changed*.

## [Unreleased]

## [0.9.3] - 2026-07-06

### Added
- `make test-lockstep-gpsim` (`test/pic/test_lockstep_pic.cc`): cycle-accurate
  HEX↔model co-simulation — steps the *real built HEX* in libgpsim against the
  reference model at **every main-loop iteration**, pinning the XC8 codegen
  (not just the firmware C that `test-equiv` exercises on the host). Directed +
  random stimulus visits every reachable model state. Run in both halves of the
  release gate.
- `make test-fault-gpsim` (`test/pic/test_fault_pic.cc`): silicon-level
  fault injection on the real built HEX in libgpsim — corrupts every
  gate-guarded SFR and `ctx_` SRAM field and asserts recovery via exactly one
  real watchdog reset (real reset-vectoring through `0x000`; a no-injection
  control asserts none). Closes the last parent/child validation-parity gap.
- Per-tick sanity gate now checks `ANSELA`: an SEU/EMI flip that re-selects an
  output pin as analog (dark LED / dead control pin, with the `TRISA` direction
  bit unchanged) now forces a watchdog reset.
- `hw_critical_sfrs_intact()` groups the five critical configuration-SFR checks
  (clock select, watchdog period, `PR2`/`T2CON` tick timer, digital-port
  select) behind one helper.
- Fault-injection and mutation coverage for every configuration-SFR gate
  invariant (`OSCCON.IRCF`, `WDTCON.WDTPS`, `PR2`, `T2CON`, `ANSELA`); each
  guard is now independently proven to force a reset and to be killed if
  weakened.
- Firmware↔model equivalence test compares internal state (`program_state`,
  `effect_state`, `debounce_counter`) against the reference model across the
  full stimulus horizon (previously LED-only past tick 256), with a capacity
  self-check that fails loudly if the capture buffer is ever undersized.
- SPDX (`SPDX-License-Identifier: MIT`) headers on the first-party test sources.
- A README "Power / current draw" section documenting the polled-loop power
  rationale and the 2 MHz current figures, and a "Design Documentation" pointer
  to the parent project's `DESIGN_DOCUMENTATION.adoc` for shared hardware/design
  details.
- `CHANGELOG.md`.

### Changed
- **Core clock reduced from 16 MHz to 2 MHz** (HFINTOSC), roughly halving MCU
  supply current (~0.85 mA → ~0.43 mA at 5 V) for no change to the reliability
  architecture — the busy-wait tick, per-tick SEU/EMI sanity gate, and
  LFINTOSC-based watchdog are untouched. The 1 ms tick is re-derived on the 1:4
  Timer2 prescaler (`T2CON = 0x05`, `PR2 = 124`) to stay exactly 1 ms; the
  `__delay_ms` pulse widths (which track `_XTAL_FREQ`) and the FOSC-independent
  watchdog margin are unchanged. Low power is not a project goal — this simply
  avoids spending ~4 mW where ~2 mW does the same job, and emits less
  high-frequency switching noise into the analog path.
- Documented the gpsim TMR2 prescaler-clamp gap (gpsim clamps `T2CKPS = 0b11`
  to 1:16 instead of the datasheet's 1:64) in `test/README.md` "Known gaps", and
  narrowed the `PRESS1_EARLY` / tick-mutant claims from "pins the 1 ms cadence"
  to "pins that the tick gates the loop" — the absolute tick *period* is a
  hardware-bench guarantee.
- The release gate now runs `test-fault-gpsim` and `test-lockstep-gpsim` in
  both halves.
- Re-vendored the reference model from the parent project (clearing stale
  typos), and retargeted two mutation cases to `test-equiv` so a gpsim-less run
  can no longer silently skip them.
- Release/CI "trust narrative" enumerations now list the actuation-sequence
  gate (and the CONFIG-word check where it was omitted).
- `make clean` removes `gpsim.log`; `test-fault-variants` is now `.PHONY` and
  documented in `make help`.

### Fixed
- **1 ms system tick ran ~4× slow (~4 ms) on real silicon.** `init()`
  programmed Timer2 with `T2CON = 0x07` (`T2CKPS = 0b11` = 1:64) while intending
  the 1:16 prescale, stretching every debounce interval 4× (press-confirm
  ~8 ms → ~32 ms, release-lockout ~25 ms → ~100 ms). Every simulation-based test
  masked it because gpsim mis-models the `0b11` code as 1:16; the defect was
  caught by cross-checking the programmed register against the datasheet. Now a
  true 1 ms tick. The behaviour was still serviceable — and not a safety
  regression, the watchdog margin was unaffected — but off-spec in the
  v0.9.0–v0.9.2 prebuilt images.
- Comment/documentation accuracy in the firmware: removed a reference to a
  function that does not exist in this project, corrected two `static_assert`
  messages, and fixed the worst-case pet-to-pet window figure (`~13 ms`).
- Resolved a contradictory license statement: the firmware header read "All
  rights reserved." directly above an MIT grant. The header is now the same
  self-describing `SPDX-License-Identifier: MIT` form used by the test sources,
  and the copyright name is canonical (`Matthew Garman`) across the header and
  `LICENSE`.
- Documentation corrections: the firmware's parent-derivation commit reference
  (→ `bf6a6c1`), the `test-equiv` scope wording (it compares RA0 + internal
  state), and assorted comment typos.

## [0.9.2] - 2026-07-01

### Changed
- Hardened the main-loop sanity gate against SFR corruption.
- Replaced the parametric pin-set helper with per-pin constant-bit functions,
  reclaiming flash on the size-constrained PIC10F320.

### Fixed
- `coverage-check-fw` now passes `PIC_OUTPUT_DEF` to the fault driver.

### Added
- `scripts/ci-local.sh` to reproduce the CI gate locally before pushing.

## [0.9.1] - 2026-06-30

### Fixed
- Release tooling and docs: corrected the five-variant list, fixed a
  `commit_msg` leak in the release flow, and clarified the soak wording.

## [0.9.0] - 2026-06-30

### Added
- Initial release: PIC10F320 bypass firmware as a standalone, size-constrained
  child of the parent `mcu-bypass-firmware` project, with the debounce
  algorithm inlined into `main()` to fit the 256-word flash.
- Five output variants: `cd4053-simple`, `tmux4053-simple`, `cd4053-mute`,
  `tmux4053-mute`, `tq2-relay`.
- Two-layer validation: a vendored reference model plus a firmware↔model
  equivalence test that pins the shipping binary to the model tick-for-tick.
- Formal verification (bounded model check, symbolic single-step, CBMC),
  fault-injection harness with a firmware line-coverage gate, per-variant
  actuation-sequence checks, gpsim functional and libgpsim soak tests, a
  CONFIG-word check, mutation testing, and a clean MISRA-C:2012 posture.

[Unreleased]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.3...HEAD
[0.9.3]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/pic10f320-bypass-firmware/releases/tag/v0.9.0
