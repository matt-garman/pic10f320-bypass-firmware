// Firmware actuation-sequence test.
//
// WHY THIS EXISTS
//   The cd4053-mute and tq2-relay output drivers are BLOCKING: each actuation
//   asserts the mute / energises a relay coil, calls __delay_ms(), then releases
//   it. The firmware<->model equivalence test only watches RA0 (the LED), and the
//   gpsim functional test only samples the SETTLED register state -- so NEITHER
//   can observe that transient. A swapped relay set/reset coil (the relay latches
//   the wrong way, inverting the audio path relative to the LED) or a defeated
//   mute settles to the SAME pin state and passes both tests. This was confirmed
//   by mutation: such a fault survived the entire suite. The pin map and the
//   per-variant output stages are hand-written here (PIC-local, NOT shared with
//   the parent), so a transcription error in them is exactly the manual-porting
//   bug the equivalence test catches for the debounce core -- but, before this
//   test, was uncaught for the output stages.
//
// HOW IT WORKS
//   The mock <xc.h> routes __delay_ms() through bypass_on_delay_ms(), which
//   fw_harness.c uses to snapshot LATA at the instant of each actuation (after the
//   mute/coil is asserted, before it is released). We drive one full round trip
//   (power-on bypass, engage, bypass) and assert, per variant, the exact
//   mid-actuation pin pattern AND the pulse width -- the part the other layers
//   cannot see. The shared RA0 (LED) behaviour remains the equivalence test's job;
//   this is purely about the variant control pins DURING the blocking pulse.
//
// PIN MAP (bypass_mcu_pic10f320.c): RA0=LED=0x1, RA1=0x2, RA2=0x4.
//   cd4053-mute : CTL1=RA1, CTL2=RA2. The mute drops the not-yet-switched control,
//                 waits, then switches. engage mid: LED|CTL2 = 0x5; bypass mid: CTL2 = 0x4.
//   tq2-relay   : RESET=RA1, SET=RA2. engage pulses SET (LED|SET = 0x5); bypass
//                 pulses RESET (RESET = 0x2). Coils settle low, so the settled
//                 ENGAGED LATA is 0x1 -- all gpsim/equiv can confirm.
//   cd4053-simple: no blocking actuation -> zero snapshots.

#include <stdint.h>
#include <stdio.h>

// Provided by test/equiv/fw_harness.c (the REAL firmware on the host).
extern void     fw_run(const uint8_t *fsw, int n, uint8_t *trace);
extern int      fw_actuation_count(void);
extern uint8_t  fw_actuation_lata(int i);
extern unsigned fw_actuation_ms(int i);
extern int      fw_tick_count(void);   // settled per-tick LATA samples available
extern uint8_t  fw_tick_lata(int i);   // full SETTLED LATA at end of tick i

// Per-variant SETTLED LATA pattern (full byte, sampled at end-of-tick). These
// match the gpsim functional test's PIC_ENGAGED_LATA (cd4053-simple 0x3,
// cd4053-mute 0x7, tq2-relay 0x1); BYPASS settles to 0x0 for every variant (mute
// released / coils low, LED off, and the cd4053-simple spare RA2 held low).
#if defined(OUTPUT_CD4053_SIMPLE)
#  define EXP_ENGAGED_LATA 0x3u   // LED(RA0) + CD4053(RA1); RA2 spare low
#  define EXP_BYPASS_LATA  0x0u
#elif defined(OUTPUT_CD4053_WITH_MUTE)
#  define EXP_ENGAGED_LATA 0x7u   // LED(RA0) + CTL1(RA1) + CTL2(RA2)
#  define EXP_BYPASS_LATA  0x0u
#elif defined(OUTPUT_TQ2_RELAY)
#  define EXP_ENGAGED_LATA 0x1u   // LED(RA0); both coils settle low
#  define EXP_BYPASS_LATA  0x0u
#else
#  error "no OUTPUT_* variant defined"
#endif

static int g_checks = 0, g_failures = 0;

#define CHECK(cond, ...) do {                                  \
    g_checks++;                                                \
    if (!(cond)) {                                             \
        g_failures++;                                          \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);   \
        fprintf(stderr, __VA_ARGS__);                          \
        fprintf(stderr, "\n");                                 \
    }                                                          \
} while (0)

int main(void) {
    // One full round trip. Long constant runs so the exact debounce thresholds do
    // not matter: released power-on, a press (ENGAGE), release past the lock-out,
    // a second press (BYPASS), release. 1 = pressed (RA3 low), 0 = released.
    uint8_t fsw[128];
    int n = 0;
    for (int i = 0; i < 5;  ++i) { fsw[n++] = 0; } // released power-on
    for (int i = 0; i < 15; ++i) { fsw[n++] = 1; } // press  -> ENGAGE actuation
    for (int i = 0; i < 35; ++i) { fsw[n++] = 0; } // release, drain the lock-out
    for (int i = 0; i < 15; ++i) { fsw[n++] = 1; } // press  -> BYPASS actuation
    for (int i = 0; i < 35; ++i) { fsw[n++] = 0; } // release

    uint8_t trace[128];
    fw_run(fsw, n, trace);

    int const count = fw_actuation_count();

    // Settled control-pin check (host-side, every variant). The CLRWDT hook samples
    // LATA at the END of each main-loop iteration -- after hw_set_*_state() and any
    // blocking __delay_ms pulse have completed -- so LATA is fully SETTLED there.
    // Assert the FULL per-variant pin pattern, not just RA0: the control pins
    // (RA1/RA2) must agree with the LED at every tick. This is the host-side
    // analogue of the gpsim full-LATA check and, crucially, it covers the
    // cd4053-simple CD4053 control pin (RA1) -- which has no blocking actuation for
    // the snapshot path below to catch, and so was otherwise verified only on the
    // simulated core (a mis-routed RA1 there survived the whole host suite; see the
    // mutation table). Mid-pulse transients remain the actuation-snapshot checks.
    {
        int const ticks = fw_tick_count();
        CHECK(ticks == n, "expected %d settled per-tick LATA samples, got %d", n, ticks);
        for (int i = 0; i < ticks; ++i) {
            uint8_t const want = trace[i] ? (uint8_t)EXP_ENGAGED_LATA
                                          : (uint8_t)EXP_BYPASS_LATA;
            CHECK(fw_tick_lata(i) == want,
                  "tick %d: settled LATA 0x%X != expected 0x%X (LED RA0=%u)",
                  i, (unsigned)fw_tick_lata(i), (unsigned)want, (unsigned)trace[i]);
        }
    }

#if defined(OUTPUT_CD4053_SIMPLE)
    printf("actuation-sequence (cd4053-simple): expect no blocking actuation\n");
    CHECK(count == 0,
          "cd4053-simple must not call __delay_ms (no blocking actuation), got %d snapshot(s)",
          count);

#elif defined(OUTPUT_CD4053_WITH_MUTE)
    printf("actuation-sequence (cd4053-mute): mid-mute LATA snapshots\n");
    // Snapshot order: [0] power-on init-bypass, [1] engage, [2] bypass.
    CHECK(count == 3,
          "expected 3 actuations (init-bypass, engage, bypass), got %d", count);
    if (count == 3) {
        CHECK(fw_actuation_ms(1) == 5u,
              "engage mute width should be 5 ms, got %u", fw_actuation_ms(1));
        CHECK(fw_actuation_ms(2) == 5u,
              "bypass mute width should be 5 ms, got %u", fw_actuation_ms(2));
        CHECK(fw_actuation_lata(1) == 0x5u,
              "engage mid-mute LATA should be 0x5 (LED+CTL2 high, CTL1 muted low), got 0x%X",
              (unsigned)fw_actuation_lata(1));
        CHECK(fw_actuation_lata(2) == 0x4u,
              "bypass mid-mute LATA should be 0x4 (CTL2 high, CTL1 muted low, LED off), got 0x%X",
              (unsigned)fw_actuation_lata(2));
        CHECK(fw_actuation_lata(0) == 0x4u,
              "power-on init-bypass mid-mute LATA should be 0x4, got 0x%X",
              (unsigned)fw_actuation_lata(0));
    }

#elif defined(OUTPUT_TQ2_RELAY)
    printf("actuation-sequence (tq2-relay): coil-pulse LATA snapshots\n");
    // Snapshot order: [0] power-on init-bypass, [1] engage, [2] bypass.
    CHECK(count == 3,
          "expected 3 actuations (init-bypass, engage, bypass), got %d", count);
    if (count == 3) {
        CHECK(fw_actuation_ms(1) == 12u,
              "engage coil pulse should be 12 ms, got %u", fw_actuation_ms(1));
        CHECK(fw_actuation_ms(2) == 12u,
              "bypass coil pulse should be 12 ms, got %u", fw_actuation_ms(2));
        CHECK(fw_actuation_lata(1) == 0x5u,
              "engage must pulse the SET coil (RA2): LATA 0x5 (LED+SET), got 0x%X "
              "(0x3 == RESET pulsed instead -> relay latched backwards)",
              (unsigned)fw_actuation_lata(1));
        CHECK(fw_actuation_lata(2) == 0x2u,
              "bypass must pulse the RESET coil (RA1): LATA 0x2, got 0x%X "
              "(0x4 == SET pulsed instead -> relay latched backwards)",
              (unsigned)fw_actuation_lata(2));
        CHECK(fw_actuation_lata(0) == 0x2u,
              "power-on init-bypass must pulse the RESET coil (RA1): LATA 0x2, got 0x%X",
              (unsigned)fw_actuation_lata(0));
    }

#else
#  error "no OUTPUT_* variant defined"
#endif

    printf("actuation-sequence: %d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
