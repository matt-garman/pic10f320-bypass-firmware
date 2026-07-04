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

### Added
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
- `make test-fault-gpsim` (`test/pic/test_fault_pic.cc`): silicon-level
  fault injection on the real built HEX in libgpsim — corrupts every
  gate-guarded SFR and `ctx_` SRAM field and asserts recovery via exactly one
  real watchdog reset (real reset-vectoring through `0x000`; a no-injection
  control asserts none). Closes the last parent/child validation-parity gap.
- Firmware↔model equivalence test compares internal state (`program_state`,
  `effect_state`, `debounce_counter`) against the reference model across the
  full stimulus horizon (previously LED-only past tick 256), with a capacity
  self-check that fails loudly if the capture buffer is ever undersized.
- SPDX (`SPDX-License-Identifier: MIT`) headers on the first-party test sources.
- `CHANGELOG.md`; a README "Design Documentation" pointer to the parent
  project's `DESIGN_DOCUMENTATION.adoc` for shared hardware/design details.

### Fixed
- Comment/documentation accuracy in the firmware: removed a reference to a
  function that does not exist in this project, corrected two `static_assert`
  messages, restored the `1:16` prescaler in the tick-period derivation, and
  fixed the worst-case pet-to-pet window figure (`~13 ms`).

### Changed
- Release/CI "trust narrative" enumerations now list the actuation-sequence
  gate (and the CONFIG-word check where it was omitted).
- `make clean` removes `gpsim.log`; `test-fault-variants` is now `.PHONY` and
  documented in `make help`.

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

[Unreleased]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/pic10f320-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/pic10f320-bypass-firmware/releases/tag/v0.9.0
