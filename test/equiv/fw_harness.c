// Firmware harness for the equivalence test: runs the REAL PIC10F320 firmware
// on the host and captures its status-LED (RA0) output trace, one sample per
// tick. RA0 is the variant-independent witness of effect state -- it is high iff
// the effect is ENGAGED for every output variant (cd4053-simple, cd4053-with-
// mute, tq2-relay), whereas the RA1/RA2 control pins differ per variant (their
// per-variant LATA pattern is asserted on real silicon by the gpsim test).
//
// HOW IT WORKS
//   - The mock <xc.h> (test/equiv/xc.h) turns the firmware's SFR accesses into
//     plain host storage (defined here) and CLRWDT() into bypass_equiv_on_clrwdt().
//   - This file #includes the firmware verbatim, compiled with -Dmain=fw_main so
//     the firmware's main() becomes a callable fw_main().
//   - fw_run() seeds the footswitch level, longjmp-protects the call, and runs
//     fw_main(). The firmware's main loop runs free; the CLRWDT hook fires once
//     per loop iteration and (a) records the LATA output for the tick just
//     finished, (b) advances the stimulus, (c) longjmps back out when the
//     stimulus is exhausted.
//
// One firmware loop iteration == one simulated 1ms tick (the mock makes the
// TMR2 tick always-ready). init()'s own initial CLRWDT() is the only pre-loop
// hook call and is skipped.

#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "xc.h" // the mock; brings in the SFR/type declarations defined below

// --- SFR storage (declared extern in the mock xc.h) --------------------------
uint8_t LATA, PORTA, TRISA, ANSELA, WPUA, PR2, T2CON;
OPTION_REGbits_t OPTION_REGbits;
OSCCONbits_t     OSCCONbits;
WDTCONbits_t     WDTCONbits;
INTCONbits_t     INTCONbits;

static PIR1bits_t g_pir1;
PIR1bits_t *bypass_pir1(void) {
    g_pir1.TMR2IF = 1u; // tick always ready (see xc.h)
    return &g_pir1;
}

// --- harness state ----------------------------------------------------------
static jmp_buf       g_done;
static const uint8_t *g_fsw;   // stimulus: 1 = pressed (RA3 low), 0 = released
static int            g_n;     // stimulus length (number of ticks)
static int            g_tick;  // current tick index
static uint8_t       *g_trace; // out: LATA & 0x03 captured per tick
static int            g_clrwdt_calls;

// --- actuation-sequence capture ----------------------------------------------
// The mute/relay drivers call __delay_ms() once per actuation, AFTER asserting the
// mute / energising the coil and BEFORE releasing it -- so LATA at that instant is
// the firmware's transient (mid-pulse) output. The mock routes __delay_ms() here
// (test/equiv/xc.h); we record LATA + the requested delay for each call so
// test/actuation can assert the per-variant mid-actuation pin pattern -- the part
// the equivalence (RA0-only) and gpsim (settled-state-only) tests cannot see.
// The equivalence run itself ignores these; cd4053-simple never calls __delay_ms.
#define FW_ACTUATION_MAX 64
static uint8_t  g_act_lata[FW_ACTUATION_MAX];
static unsigned g_act_ms[FW_ACTUATION_MAX];
static int      g_act_count;

void bypass_on_delay_ms(unsigned ms) {
    if (g_act_count < FW_ACTUATION_MAX) {
        g_act_lata[g_act_count] = LATA;
        g_act_ms[g_act_count]   = ms;
        g_act_count++;
    }
}

int      fw_actuation_count(void) { return g_act_count; }
uint8_t  fw_actuation_lata(int i) { return (i >= 0 && i < g_act_count) ? g_act_lata[i] : 0xFFu; }
unsigned fw_actuation_ms(int i)   { return (i >= 0 && i < g_act_count) ? g_act_ms[i]   : 0u; }

// Present the footswitch level for tick i on RA3 (pressed => RA3 low).
static void present_footswitch(int i) {
    if (g_fsw[i]) { PORTA &= (uint8_t)~0x08u; } // pressed -> low
    else          { PORTA |=  (uint8_t) 0x08u; } // released -> high
}

// CLRWDT() hook: fires once per firmware loop iteration (plus once inside init).
void bypass_equiv_on_clrwdt(void) {
    g_clrwdt_calls++;
    if (g_clrwdt_calls == 1) {
        return; // init()'s initial "pet the dog", before the main loop starts
    }
    // A main-loop iteration just completed: capture the status-LED (RA0) output
    // for this tick -- the variant-independent witness of effect state.
    g_trace[g_tick] = (uint8_t)(LATA & 0x01u);
    g_tick++;
    if (g_tick >= g_n) {
        longjmp(g_done, 1); // stimulus exhausted -> unwind out of fw_main()
    }
    present_footswitch(g_tick); // set the level the next iteration will read
}

// Safety net: a real firmware fault (sanity-check failure) would enter
// hw_force_wdt_reset()'s infinite loop with no CLRWDT inside, hanging the host.
// With a faithful mock that cannot happen for valid stimulus, but guard anyway.
static void on_alarm(int sig) {
    (void)sig;
    const char msg[] = "test-equiv: firmware appears stuck (fault path reached?)\n";
    ssize_t w = write(STDERR_FILENO, msg, sizeof msg - 1u);
    (void)w;
    _exit(3);
}

// Bring in the real firmware. -Dmain=fw_main renames its entry point.
#include "../../bypass_mcu_pic10f320.c"

// Run the firmware over `fsw[0..n-1]`, filling trace[i] with the LED bit
// (LATA & 0x01) at the end of the tick that consumed fsw[i]. init() samples
// fsw[0] (power-on level).
void fw_run(const uint8_t *fsw, int n, uint8_t *trace) {
    g_fsw = fsw; g_n = n; g_tick = 0; g_trace = trace; g_clrwdt_calls = 0;
    g_act_count = 0; // reset the per-run actuation-snapshot log

    // Reset SFR storage so each run starts from a clean power-on.
    LATA = PORTA = TRISA = ANSELA = WPUA = PR2 = T2CON = 0u;
    OPTION_REGbits.nWPUEN = 1u; OSCCONbits.IRCF = 0u;
    WDTCONbits.WDTPS = 0u; INTCONbits.GIE = 1u; g_pir1.TMR2IF = 0u;

    present_footswitch(0); // power-on footswitch level for init()'s sample

    signal(SIGALRM, on_alarm);
    alarm(20);
    if (setjmp(g_done) == 0) {
        fw_main(); // runs init() then the main loop; hook longjmps back here
    }
    alarm(0);
}
