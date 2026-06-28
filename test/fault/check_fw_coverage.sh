#!/usr/bin/env bash
#
# Firmware line-coverage gate for bypass_mcu_pic10f320.c, driven by the fault +
# happy-path harness (test/fault). Unlike the model coverage gate (a percentage
# floor), this asserts an EXACT property: every firmware line must be covered
# EXCEPT the watchdog-reset fault path, which is uncoverable on the host for two
# documented reasons --
#
#   - hw_force_wdt_reset()'s body deliberately never returns (for (;;) {}). gcov's
#     edge-flow solver cannot credit the lines of a function with no exit, so they
#     read as uncovered even though the harness DOES drive them (fw_fault_run
#     proves the path is taken: the firmware has to be timed out of the spin).
#   - the switch's `default:` case is unreachable while the sanity gate is intact
#     (the gate rejects any out-of-range program_state BEFORE the switch). It is
#     defense-in-depth; the model's equivalent default IS formally proven
#     (test/formal: prove_corrupt_state_faults / verify_corrupt_state_faults).
#
# So those specific lines are allow-listed by their SOURCE TEXT (robust to line
# renumbering). Any OTHER uncovered firmware line fails the gate -- that is the
# regression alarm: it means a real piece of firmware logic lost its test.
#
# Usage: check_fw_coverage.sh <bypass_mcu_pic10f320.c.gcov>

set -u

GCOV="${1:?usage: check_fw_coverage.sh <firmware.c.gcov>}"
if [ ! -f "$GCOV" ]; then
    echo "FAIL: firmware gcov annotation not found: $GCOV"
    echo "      (gcov must run where the #included firmware source resolves.)"
    exit 1
fi

allowed=0
bad=0

# Walk every uncovered (#####) executable line.
while IFS= read -r rec; do
    lineno=$(printf '%s' "$rec" | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}')
    src=$(printf '%s' "$rec" | cut -d: -f3- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$src" in
        *hw_force_wdt_reset*|"INTCONbits.GIE = 0;"|"default:")
            echo "  allow (fault path)   L${lineno}: ${src}"
            allowed=$((allowed + 1))
            ;;
        *)
            echo "  DISALLOWED uncovered L${lineno}: ${src}"
            bad=$((bad + 1))
            ;;
    esac
done < <(grep -E '^[[:space:]]*#####:' "$GCOV")

total=$(grep -cE '^[[:space:]]*([0-9]+|#####):[[:space:]]*[0-9]+:' "$GCOV")
uncov=$(grep -cE '^[[:space:]]*#####:' "$GCOV")
covered=$((total - uncov))

echo "firmware line coverage: ${covered}/${total} executable lines (${allowed} allowed-uncovered fault-path line(s), ${bad} disallowed)"

if [ "$bad" -ne 0 ]; then
    echo "FAIL: ${bad} firmware line(s) are uncovered and NOT on the fault-path allowlist."
    echo "      Add a test that exercises them, or -- if they are genuinely"
    echo "      unreachable defensive code -- extend the allowlist in"
    echo "      test/fault/check_fw_coverage.sh with a rationale."
    exit 1
fi

echo "OK: every firmware line is covered except the allowlisted watchdog-reset fault path."
exit 0
