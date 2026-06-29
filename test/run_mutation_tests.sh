#!/usr/bin/env bash
#
# Mutation testing for the PIC10F320 bypass firmware + its reference model.
#
# WHY THIS EXISTS
#   A passing suite proves the tests pass on correct code; it does not prove they
#   FAIL on broken code. Mutation testing closes that gap: it injects a small,
#   deliberate fault ("mutant") into a production source, rebuilds, and runs a
#   fast test target. An adequate suite must DETECT the fault -- the target must
#   FAIL (the mutant is "killed"). A surviving mutant marks a real hole.
#
# WHAT IS MUTATED, AND WHAT KILLS IT
#   - The firmware (bypass_mcu_pic10f320.c): killed by `make test-equiv` (the
#     firmware<->model trace comparison) and/or `make test-gpsim` (the real HEX in
#     gpsim). These are the oracles that watch the SHIPPING code.
#   - The reference model (test/model/bypass_pure.c) and the model thresholds:
#     killed by `make test-host` / `make test-model-check` (logic), or by
#     `make test-equiv` (a model-threshold change diverges from the firmware).
#
# This runs on a throwaway COPY of the tree; it never modifies the real sources.
# Wired into `make test-mutation`; intentionally NOT part of `make test` (it
# rebuilds per mutant). Each mutant lists the fast target expected to kill it.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# Each entry: file<TAB>sed-expression<TAB>make-target<TAB>description.
# The sed expression uses '@' as the delimiter to avoid clashing with C operators.
MUTATIONS=(
# --- firmware: debounce logic (killed by the firmware<->model equivalence test) ---
"bypass_mcu_pic10f320.c	s@++ctx_.debounce_counter@--ctx_.debounce_counter@	test-equiv	FW integrator: increment-on-press becomes decrement (never reaches threshold)"
"bypass_mcu_pic10f320.c	s@ctx_.debounce_counter >= PRESSED_THRESH@ctx_.debounce_counter > PRESSED_THRESH@	test-equiv	FW press threshold off-by-one (>= becomes >): 1-tick latency divergence"
"bypass_mcu_pic10f320.c	s@if (0U == ctx_.debounce_counter)@if (0U != ctx_.debounce_counter)@	test-equiv	FW release re-arm condition inverted (lock-out never clears / clears wrongly)"
"bypass_mcu_pic10f320.c	s@#define PRESSED_THRESH  (8U)@#define PRESSED_THRESH  (4U)@	test-equiv	FW press threshold shortened 8->4 (diverges from the model's 8)"
"bypass_mcu_pic10f320.c	s@#define RELEASE_THRESH  (25U)@#define RELEASE_THRESH  (15U)@	test-equiv	FW release lock-out shortened 25->15 (diverges from the model)"
# --- firmware: power-on init (killed by equivalence: power-on-pressed sequences) ---
"bypass_mcu_pic10f320.c	s@ctx_.program_state = RELEASE_DEBOUNCE_WAIT;@ctx_.program_state = PRESS_DEBOUNCE_WAIT;@	test-equiv	FW power-on-pressed: wrong program_state (held switch could spuriously engage)"
# --- firmware: defensive / fault-detection layer (killed by the fault harness) -----
# These mutants WEAKEN a runtime sanity check so a real fault would go undetected.
# They are invisible to test-equiv/test-gpsim (valid stimulus never trips the
# check); only test-fault, which injects corrupted state, kills them.
"bypass_mcu_pic10f320.c	s@return (hw_output_pins_intact((1U << LED_PIN) | (1U << CD4053_PIN)) == 0U);@return 0U;@	test-fault	FW output-pin SEU check neutered (lost LED/CD4053 output never detected)"
"bypass_mcu_pic10f320.c	s@return (0U != pin_latched) \&\& (0U == wpu_global);@return 1U;@	test-fault	FW footswitch pull-up SEU check neutered (disabled pull-up never detected)"
"bypass_mcu_pic10f320.c	s@(ctx_.effect_state > ENGAGED)@(ctx_.effect_state > 99U)@	test-fault	FW effect_state range guard defeated (corrupt effect_state never forces reset)"
"bypass_mcu_pic10f320.c	s@(ctx_.debounce_counter > RELEASE_THRESH)@(ctx_.debounce_counter > 255U)@	test-fault	FW counter range guard defeated (corrupt debounce_counter never forces reset)"
# --- firmware: GPIO / footswitch wiring -------------------------------------------
# LED-invert and footswitch-polarity ALSO diverge on RA0, so test-equiv kills them
# too; they are listed under gpsim as the register-level oracle. The CD4053 control
# mis-route does NOT move RA0 (it is on RA1), so it is the one wiring fault the
# RA0-only equivalence test cannot see -- now killed host-only by test-actuation's
# settled-LATA check (it was gpsim-only before that check existed).
"bypass_mcu_pic10f320.c	s@LATA |=  (uint8_t)(1U << LED_PIN)@LATA \&= (uint8_t)~(1U << LED_PIN)@	test-gpsim	FW set_engaged LED output inverted (RA0 stays dark when ENGAGED)"
"bypass_mcu_pic10f320.c	s@hw_pin_set_high(CD4053_PIN)@hw_pin_set_low(CD4053_PIN)@	PIC_VARIANT=cd4053-simple test-actuation	FW CD4053 control routed the wrong way (RA1 stuck low); settled ENGAGED LATA 0x1 not 0x3 (RA0 unaffected, so equiv/gpsim-RA0 miss it; killed by the actuation settled-LATA check)"
"bypass_mcu_pic10f320.c	s@(0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA \& (uint8_t)(1U << FOOTSW_PIN)))@	test-gpsim	FW footswitch read polarity inverted (toggles on release, not press)"
# --- firmware: blocking-actuation sequencing (killed by the actuation test) --------
# These corrupt the mid-actuation output of the BLOCKING variants (relay coil
# routing / the mute window). They settle to the SAME pin state, so test-equiv
# (RA0 only) and test-gpsim (settled state only) miss them entirely; only
# test-actuation, which snapshots LATA DURING the pulse, kills them. The target
# field carries the variant (the gap exists only for mute/relay, not cd4053-simple).
"bypass_mcu_pic10f320.c	s@hw_pin_set_high(RELAY_SET_PIN);   // pulse set coil@hw_pin_set_high(RELAY_RESET_PIN); // MUTANT@	PIC_VARIANT=tq2-relay test-actuation	FW relay ENGAGE pulses the RESET coil instead of SET (relay latches backwards; settles to same LATA, so equiv/gpsim miss it)"
"bypass_mcu_pic10f320.c	s@hw_pin_set_high(RELAY_RESET_PIN); // pulse reset coil@hw_pin_set_high(RELAY_SET_PIN); // MUTANT@	PIC_VARIANT=tq2-relay test-actuation	FW relay BYPASS pulses the SET coil instead of RESET (relay latches backwards)"
"bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (0U)@	PIC_VARIANT=cd4053-mute test-actuation	FW cd4053-mute pre-switch mute window defeated (5->0 ms): audible click on every switch"
# --- model: debounce logic (killed by the host / state-space tests) ---------------
"test/model/bypass_pure.c	s@{ ++counter; }@{ --counter; }@	test-host	MODEL integrator increment becomes decrement"
"test/model/bypass_pure.c	s@ctx.debounce_counter >= PRESSED_THRESH@ctx.debounce_counter > PRESSED_THRESH@	test-host	MODEL press threshold off-by-one (>= becomes >)"
"test/model/bypass_pure.c	s@res.lockout_value = RELEASE_THRESH;@res.lockout_value = 0U;@	test-host	MODEL toggle lock-out reload 0 instead of RELEASE_THRESH"
"test/model/bypass_pure.c	s@res.program_state = RELEASE_DEBOUNCE_WAIT;@res.program_state = PRESS_DEBOUNCE_WAIT;@	test-model-check	MODEL stays in PRESS_DEBOUNCE_WAIT after toggle (re-toggle cascade)"
"test/model/bypass_pure.c	s@ctx.program_state = RELEASE_DEBOUNCE_WAIT;@ctx.program_state = PRESS_DEBOUNCE_WAIT;@	test-model-check	MODEL power-on-pressed: wrong program_state (verify_init_context catches it)"
"test/model/bypass_pure.c	s@res.fault = true;@res.fault = false;@	test-model-check	MODEL corrupt-state fault suppressed (verify_corrupt_state_faults catches it)"
)

# Copy the whole project tree into a sandbox; the relative-path Makefile targets
# resolve unchanged there.
copy_tree() {
    local dst="$1"
    mkdir -p "$dst"
    cp "$PROJ_DIR/Makefile" "$PROJ_DIR/bypass_mcu_pic10f320.c" "$dst/"
    cp -r "$PROJ_DIR/test" "$dst/"
}

# Baseline sanity: the unmutated tree must PASS the kill targets, otherwise a
# "killed" result would be meaningless. Run the fast logic + equivalence targets.
echo "=== mutation testing: baseline sanity check ==="
BASE="$(mktemp -d)"; copy_tree "$BASE"
base_fail=0
for t in test-host test-model-check test-equiv test-actuation test-fault; do
    if make -C "$BASE" "$t" >/dev/null 2>&1; then
        echo "baseline $t: PASS"
    else
        echo "ERROR: baseline $t FAILS on the unmutated tree; aborting." >&2
        base_fail=1
    fi
done
# The actuation mutants target the BLOCKING variants (mute/relay), so confirm the
# unmutated tree also passes test-actuation for those (it is pure host gcc -- always
# available, never skipped). Unquoted on purpose: the "PIC_VARIANT=... target" form
# word-splits into separate make arguments.
for vt in "PIC_VARIANT=tq2-relay test-actuation" "PIC_VARIANT=cd4053-mute test-actuation"; do
    if make -C "$BASE" $vt >/dev/null 2>&1; then
        echo "baseline $vt: PASS"
    else
        echo "ERROR: baseline $vt FAILS on the unmutated tree; aborting." >&2
        base_fail=1
    fi
done
# gpsim baseline (skip cleanly if gpsim/XC8 absent -> gpsim mutants are skipped).
GPSIM_OK=0
if make -C "$BASE" test-gpsim >/dev/null 2>&1 && command -v gpsim >/dev/null 2>&1 \
   && { [ -x /opt/microchip/xc8/v3.10/bin/xc8-cc ] || command -v xc8-cc >/dev/null 2>&1; }; then
    GPSIM_OK=1; echo "baseline test-gpsim: PASS (gpsim mutants ENABLED)"
else
    echo "test-gpsim baseline unavailable -> gpsim-killed mutants will be SKIPPED"
fi
rm -rf "$BASE"
[ "$base_fail" -eq 0 ] || exit 2
echo

killed=0; survived=0; errored=0; skipped=0; idx=0
SURVIVORS=()

for entry in "${MUTATIONS[@]}"; do
    IFS=$'\t' read -r file sed_expr target desc <<< "$entry"
    idx=$((idx + 1))

    if [ "$target" = "test-gpsim" ] && [ "$GPSIM_OK" -eq 0 ]; then
        echo "[$idx] SKIP   ($target unavailable): $desc"; skipped=$((skipped + 1)); continue
    fi

    work="$(mktemp -d)"; copy_tree "$work"
    if ! sed -i "$sed_expr" "$work/$file"; then
        echo "[$idx] ERROR  applying sed to $file: $desc"; errored=$((errored + 1)); rm -rf "$work"; continue
    fi
    if cmp -s "$work/$file" "$PROJ_DIR/$file"; then
        echo "[$idx] ERROR  mutation did not change $file (stale pattern?): $desc"
        errored=$((errored + 1)); rm -rf "$work"; continue
    fi

    # $target is unquoted on purpose: a mutant may carry a variant in its target
    # field (e.g. "PIC_VARIANT=tq2-relay test-actuation"), which must word-split
    # into separate make arguments. Target fields never contain globs.
    if make -C "$work" $target >/dev/null 2>&1; then
        echo "[$idx] SURVIVED ($target): $desc"; survived=$((survived + 1)); SURVIVORS+=("$file :: $desc")
    else
        echo "[$idx] killed   ($target): $desc"; killed=$((killed + 1))
    fi
    rm -rf "$work"
done

echo
echo "=== mutation summary: $killed killed, $survived survived, $errored errored, $skipped skipped ==="
if [ "$survived" -ne 0 ]; then
    echo "SURVIVING MUTANTS (a real fault went undetected -- suite gap):"
    for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
fi
if [ "$survived" -ne 0 ] || [ "$errored" -ne 0 ]; then exit 1; fi
echo "all evaluated mutants killed: the suite detects every injected fault."
exit 0
