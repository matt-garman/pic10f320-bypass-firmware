// Firmware fault-injection + defensive-path test driver.
//
// Proves the PIC10F320 firmware's fault-detection layer -- which the
// firmware<->model equivalence test deliberately never reaches -- actually
// works on the SHIPPING code:
//
//   A. Predicate probes: the static sanity predicates (output-pin direction,
//      footswitch pull-up, footswitch read) return the right verdict for both
//      good and SEU-corrupted SFR state.
//   B. Fault injection: after one clean main-loop iteration, an SEU/EMI flip of
//      the firmware's runtime state or a critical SFR makes the next iteration's
//      sanity gate force a watchdog reset (and valid states do NOT) -- end to
//      end, through the real main() loop and hw_force_wdt_reset().
//   C. Happy path: a few presses/releases drive the firmware's normal toggle
//      lines (so this harness, combined with A+B, covers the whole firmware TU
//      for the coverage gate). The equivalence test remains the behavioural
//      oracle; the checks here are a light cross-check.
//
// All firmware interaction goes through fw_fault_harness.c (which #includes the
// real firmware). SFRs are the extern mock symbols from <xc.h>.

#include <stdint.h>
#include <stdio.h>

#include "xc.h"               // mock: extern SFR declarations + types
#include "fw_fault_harness.h"

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond, ...) do {                                  \
    g_checks++;                                                \
    if (!(cond)) {                                             \
        g_failures++;                                          \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);   \
        fprintf(stderr, __VA_ARGS__);                          \
        fprintf(stderr, "\n");                                 \
    }                                                          \
} while (0)

// Set a known-good post-init SFR state for the predicate probes.
static void sfr_clean(void) {
    TRISA = 0x08u;              // RA0..RA2 outputs, RA3 input (matches init())
    WPUA  = (uint8_t)(1u << 3); // footswitch pull-up latch on
    OPTION_REGbits.nWPUEN = 0u; // global pull-ups enabled (active-low)
    PORTA = (uint8_t)(1u << 3); // footswitch released
    INTCONbits.GIE = 1u;
}

//////////////////////////////////////////////////////////////////////////////
// A. Predicate probes
//////////////////////////////////////////////////////////////////////////////
static void test_predicates(void) {
    sfr_clean();
    CHECK(fwp_output_pins_intact((uint8_t)((1u << 0) | (1u << 1))) != 0,
          "clean: LED+CD4053 should read as outputs");
    CHECK(fwp_output_pins_intact(0x07u) != 0, "clean: RA0..RA2 should all be outputs");
    CHECK(fwp_sanity_failed() == 0, "clean: no sanity failure expected");
    CHECK(fwp_pullup_intact() != 0, "clean: pull-up should read intact");
    CHECK(fwp_footswitch_is_high() == 1, "clean: released footswitch reads HIGH");

    // footswitch pressed
    sfr_clean(); PORTA &= (uint8_t)~(1u << 3);
    CHECK(fwp_footswitch_is_high() == 0, "pressed footswitch reads LOW");

    // LED pin (RA0) flipped to input -- SEU on TRISA bit 0
    sfr_clean(); TRISA |= (uint8_t)(1u << 0);
    CHECK(fwp_output_pins_intact(0x01u) == 0, "RA0 as input must read NOT intact");
    CHECK(fwp_sanity_failed() != 0, "lost LED output must flag sanity failure");

    // CD4053 pin (RA1) flipped to input -- SEU on TRISA bit 1
    sfr_clean(); TRISA |= (uint8_t)(1u << 1);
    CHECK(fwp_sanity_failed() != 0, "lost CD4053 output must flag sanity failure");

    // pull-up latch cleared -- SEU on WPUA
    sfr_clean(); WPUA &= (uint8_t)~(1u << 3);
    CHECK(fwp_pullup_intact() == 0, "cleared WPUA latch must read pull-up NOT intact");

    // global pull-up disable -- SEU on OPTION_REG nWPUEN
    sfr_clean(); OPTION_REGbits.nWPUEN = 1u;
    CHECK(fwp_pullup_intact() == 0, "global nWPUEN=1 must read pull-up NOT intact");
}

//////////////////////////////////////////////////////////////////////////////
// B. Fault injection through the real main() loop
//////////////////////////////////////////////////////////////////////////////
// A forced reset is detected by fw_fault_run returning 1: the firmware's ONLY
// spin point is hw_force_wdt_reset() (the mock makes the TMR2IF tick always
// ready, so the poll loop never hangs), so "the run had to be timed out" means
// the sanity gate fired and entered the reset path. This signal is robust at any
// optimisation level. (We deliberately do NOT also assert the GIE=0 store the
// reset path makes: the mock SFRs are non-volatile, so at -O2 that store -- dead,
// since it is followed by a non-returning loop that never reads it -- can be
// optimised away. The reset-fired signal already proves the path was taken.)
static void expect_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 1, "corruption [%s] must force a watchdog reset (got r=%d)", what, r);
}
static void expect_no_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 0, "valid state [%s] must NOT force a reset (got r=%d)", what, r);
}
static void test_fault_injection(void) {
    // Negative controls: a valid state must run on without a reset.
    expect_no_reset(FWI_NONE,          "no corruption");
    expect_no_reset(FWI_VALID_ENGAGED, "valid ENGAGED/RELEASE-wait state");

    // Positive: each SEU/EMI corruption must be caught by the sanity gate.
    expect_reset(FWI_PROGRAM_STATE_OOR,    "program_state=2 (out of range)");
    expect_reset(FWI_PROGRAM_STATE_MAX,    "program_state=255");
    expect_reset(FWI_EFFECT_STATE_OOR,     "effect_state=2 (out of range)");
    expect_reset(FWI_PULLUP_LATCH_CLEARED, "WPUA pull-up latch cleared");
    expect_reset(FWI_PULLUP_GLOBAL_OFF,    "OPTION_REG nWPUEN=1 (global pull-up off)");
    expect_reset(FWI_LED_PIN_TO_INPUT,     "TRISA RA0 (LED) flipped to input");
    expect_reset(FWI_CD4053_PIN_TO_INPUT,  "TRISA RA1 (CD4053) flipped to input");
}

//////////////////////////////////////////////////////////////////////////////
// C. Happy path (covers the firmware's normal toggle lines)
//////////////////////////////////////////////////////////////////////////////
static void test_happy_path(void) {
    uint8_t a[96];
    int n;

    // Released power-on, then a clean press -> ENGAGED.
    n = 0;
    for (int i = 0; i < 3;  ++i) { a[n++] = 0; } // released
    for (int i = 0; i < 20; ++i) { a[n++] = 1; } // press well past PRESSED_THRESH
    CHECK(fw_drive(a, n) == 0x03u, "clean press should drive ENGAGED (LATA&3=0x3)");

    // Full round trip: engage, release past the lock-out, engage again -> BYPASS.
    // (Released preamble so this is a clean power-on, not a power-on-pressed.)
    n = 0;
    for (int i = 0; i < 3;  ++i) { a[n++] = 0; } // released power-on
    for (int i = 0; i < 20; ++i) { a[n++] = 1; } // engage
    for (int i = 0; i < 30; ++i) { a[n++] = 0; } // release + drain lock-out (>=25)
    for (int i = 0; i < 20; ++i) { a[n++] = 1; } // engage again -> toggles back
    CHECK(fw_drive(a, n) == 0x00u, "second press should toggle back to BYPASS");

    // Power-on with the switch HELD: stay BYPASS, never engage while held.
    uint8_t b[96];
    int m = 0;
    for (int i = 0; i < 30; ++i) { b[m++] = 1; } // held pressed from power-on
    CHECK(fw_drive(b, m) == 0x00u, "power-on-pressed must stay BYPASS while held");

    // ...then a genuine release + fresh press engages.
    m = 0;
    for (int i = 0; i < 30; ++i) { b[m++] = 1; } // held at boot
    for (int i = 0; i < 30; ++i) { b[m++] = 0; } // release, drain lock-out
    for (int i = 0; i < 20; ++i) { b[m++] = 1; } // fresh press -> ENGAGED
    CHECK(fw_drive(b, m) == 0x03u, "fresh press after power-on-hold engages");
}

int main(void) {
    printf("firmware fault-injection + defensive-path tests:\n");
    test_predicates();
    test_fault_injection();
    test_happy_path();
    printf("firmware fault harness: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
