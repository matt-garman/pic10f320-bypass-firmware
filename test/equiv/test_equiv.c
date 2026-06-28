// Firmware<->model equivalence test.
//
// Proves that the REAL PIC10F320 firmware (run on the host via fw_harness.c)
// produces the EXACT same LED/CD4053 output, tick for tick, as the vendored
// reference model (test/model/bypass_pure.c) for the same footswitch stimulus.
// This is what licenses the project's "correctness inherited by derivation"
// claim concretely: the firmware inlines the model's algorithm to fit flash, and
// this test pins that the inlining did not change behaviour. It also
// AUTOMATICALLY guards against the firmware and model debounce thresholds
// drifting apart -- a mismatch makes the traces diverge and fails here.
//
// Coverage:
//   - exhaustive: every footswitch bit-pattern of length EQUIV_EXHAUSTIVE_LEN
//     (so every bounce/spike pattern up to that horizon, from both power-on
//     states, is checked);
//   - randomized: many pseudo-random sequences of varied length and duty cycle,
//     long enough to exercise multiple toggles, the full release lock-out drain,
//     and re-arm.
//
// Output convention (both sides): BYPASS -> LATA & 0x03 == 0x00, ENGAGED -> 0x03
// (RA0 LED + RA1 CD4053). Stimulus convention: 1 = pressed (RA3 low), 0 = released.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bypass_config.h" // RELEASE_THRESH, PRESSED_THRESH (model side)
#include "model_step.h"    // step(), state_t, debounce_init_context(), enums

// Provided by fw_harness.c (the real firmware on the host).
extern void fw_run(const uint8_t *fsw, int n, uint8_t *trace);

#ifndef EQUIV_EXHAUSTIVE_LEN
#define EQUIV_EXHAUSTIVE_LEN 18   // 2^18 = 262144 sequences
#endif
#ifndef EQUIV_RANDOM_SEQS
#define EQUIV_RANDOM_SEQS 4000
#endif
#ifndef EQUIV_RANDOM_MAXLEN
#define EQUIV_RANDOM_MAXLEN 1200  // > PRESSED_THRESH + RELEASE_THRESH for full cycles
#endif

static long g_compared = 0; // number of (stimulus) sequences compared
static long g_failures = 0;

// The reference-model oracle: the same per-tick output trace the firmware should
// produce. init from fsw[0] (power-on level), then one step() per tick.
static void model_run(const uint8_t *fsw, int n, uint8_t *trace) {
    pin_state_t const p0 = fsw[0] ? PIN_STATE_LOW : PIN_STATE_HIGH;
    debounce_context_t const c = debounce_init_context(p0);
    state_t s = { (uint8_t)c.program_state, (uint8_t)c.effect_state, c.debounce_counter };
    for (int i = 0; i < n; ++i) {
        step_result_t const r = step(s, fsw[i]);
        s = r.next;
        trace[i] = (uint8_t)((s.effect_state == ENGAGED) ? 0x03u : 0x00u);
    }
}

// Compare one stimulus; report the first diverging tick on mismatch.
static int compare_one(const uint8_t *fsw, int n) {
    static uint8_t fw_trace[EQUIV_RANDOM_MAXLEN];
    static uint8_t md_trace[EQUIV_RANDOM_MAXLEN];
    fw_run(fsw, n, fw_trace);
    model_run(fsw, n, md_trace);
    g_compared++;
    for (int i = 0; i < n; ++i) {
        if (fw_trace[i] != md_trace[i]) {
            g_failures++;
            fprintf(stderr,
                "FAIL: divergence at tick %d/%d: firmware LATA&3=0x%X, model=0x%X\n",
                i, n, fw_trace[i], md_trace[i]);
            // dump a short window of the stimulus around the divergence
            int lo = i - 6; if (lo < 0) { lo = 0; }
            fprintf(stderr, "  stimulus[%d..%d] (1=pressed): ", lo, i);
            for (int k = lo; k <= i; ++k) { fprintf(stderr, "%d", fsw[k]); }
            fprintf(stderr, "\n");
            return 1;
        }
    }
    return 0;
}

// xorshift32: small reproducible PRNG.
static uint32_t xorshift32(uint32_t *st) {
    uint32_t x = *st; x ^= x << 13; x ^= x >> 17; x ^= x << 5; *st = x; return x;
}

static void run_exhaustive(void) {
    enum { L = EQUIV_EXHAUSTIVE_LEN };
    static uint8_t fsw[L];
    unsigned long const combos = 1UL << L;
    for (unsigned long pat = 0; pat < combos; ++pat) {
        for (int b = 0; b < L; ++b) { fsw[b] = (uint8_t)((pat >> b) & 1UL); }
        if (compare_one(fsw, L)) { return; } // stop at first divergence
    }
    printf("  exhaustive: %lu sequences of length %d : OK\n", combos, L);
}

static void run_random(void) {
    static uint8_t fsw[EQUIV_RANDOM_MAXLEN];
    uint32_t rng = 0xC0FFEEu;
    for (long s = 0; s < EQUIV_RANDOM_SEQS; ++s) {
        int n = (int)(1u + (xorshift32(&rng) % (EQUIV_RANDOM_MAXLEN)));
        // Vary the duty cycle so some seqs hold long (toggles), others chatter.
        uint32_t thresh = (xorshift32(&rng) % 256u);
        for (int i = 0; i < n; ++i) {
            fsw[i] = (uint8_t)((xorshift32(&rng) & 0xFFu) < thresh);
        }
        if (compare_one(fsw, n)) { return; }
    }
    printf("  randomized: %d sequences (len<=%d, varied duty) : OK\n",
           EQUIV_RANDOM_SEQS, EQUIV_RANDOM_MAXLEN);
}

int main(void) {
    printf("firmware<->model equivalence (PRESSED_THRESH=%u, RELEASE_THRESH=%u):\n",
           (unsigned)PRESSED_THRESH, (unsigned)RELEASE_THRESH);
    run_exhaustive();
    if (g_failures == 0) { run_random(); }
    printf("equivalence: %ld sequences compared, %ld divergence(s)\n",
           g_compared, g_failures);
    return g_failures ? 1 : 0;
}
