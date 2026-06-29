// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.


//
// PIC10F320 DIP-8 Pinout
//                                                     +----+
//                                            N/C pin1-|    |-pin8 RA3 (~MCLR/V_PP)
//                                           V_DD pin2-|    |-pin7 V_SS (GND)
// (INT/T0CKI/NCO1/CLC1IN1/CLKR/AN2/~CWG1FLT) RA2 pin3-|    |-pin6 N/C
//(PWM2/CLC1/CWG1B/AN1/CLKIN/ICSPCLK/NCO1CLK) RA1 pin4-|    |-pin5 RA0 (PWM1/CLC1IN0/CWG1A/AN0/ICSPDAT)
//                                                     +----+
//

#include <xc.h> // device SFRs, CLRWDT(), __delay_ms()

#include <assert.h>
#include <stdint.h>


// number of HIGH footswitch pin reads to be considered release-debounced,
// i.e. the "lock-out" period
#define RELEASE_THRESH  (25U)

// number of LOW footswitch pin reads to be considered press-debounced
#define PRESSED_THRESH  (8U)


// PIC10F320 pin map: PORTA/TRISA/LATA bit positions. The PIC10F320 has four
// GPIO pins: RA0, RA1, RA2 are bidirectional, and RA3 is INPUT-ONLY (it
// shares MCLR/VPP; with MCLRE=OFF it is a plain digital input). So the
// footswitch (an input) goes on RA3, freeing RA0-RA2 as the three outputs.
//
// footswitch and status LED pins are common across all output variants
#define FOOTSW_PIN      (3U) // RA3 (input-only) + weak pull-up
#define LED_PIN         (0U) // RA0

#define CD4053_PIN      (1U) // RA1

#if defined(OUTPUT_CD4053_SIMPLE)
#elif defined(OUTPUT_CD4053_WITH_MUTE)
#  define CD4053_CTL1     (1U) // RA1
#  define CD4053_CTL2     (2U) // RA2
#elif defined(OUTPUT_TQ2_RELAY)
#  define RELAY_RESET_PIN (1U) // RA1
#  define RELAY_SET_PIN   (2U) // RA2
#else
#  error "output scheme not defined: define one of OUTPUT_CD4053_SIMPLE, OUTPUT_CD4053_WITH_MUTE, or OUTPUT_TQ2_RELAY"
#endif



// Bits that must be OUTPUTS (RA0|RA1|RA2). Same macro NAME as the AVR map (the
// shared drivers consume it); the value is the output-bit set, interpreted by
// the per-MCU hw_configure_output_pins() (PIC: TRISA bit 0 = output). ("DDR" is
// legacy AVR wording, kept for a single cross-MCU macro name.)
//
// All three variants use RA0..RA2: relay = LED(RA0)/RESET(RA1)/SET(RA2);
// mute = LED(RA0)/CTL1(RA1)/CTL2(RA2); cd4053-simple = LED(RA0)/CD4053(RA1),
// leaving RA2 a spare driven low. Mask 0x07 for all.
#define BYPASS_OUTPUT_DDR_MASK (0x07U)  // RA0|RA1|RA2



// Upper bound for values stored in the uint8_t debounce counter, as an
// UNSIGNED constant. We deliberately do NOT use <stdint.h>'s UINT8_MAX: by C
// integer-promotion rules a uint8_t promotes to (signed) int, so UINT8_MAX
// itself has type int. Comparing it to our unsigned thresholds is an
// essential-type-category mix (MISRA 10.4), and its expansion (0x7f*2+1) also
// trips MISRA 12.1. A plain unsigned literal means the same thing and avoids
// both -- see MISRA_COMPLIANCE.md.
//
// Loosely speaking: MISRA-C compliant UINT8_MAX
#define DEBOUNCE_COUNTER_MAX (255U)



// CONFIG (configuration word)
#pragma config FOSC  = INTOSC
#pragma config BOREN = ON
#pragma config WDTE  = ON
#pragma config PWRTE = ON
#pragma config MCLRE = OFF
#pragma config CP    = OFF
#pragma config LVP   = OFF
#pragma config LPBOR = OFF
#pragma config BORV  = HI
#pragma config WRT   = OFF



// static_assert() shim for xc8-cc
//   - XC8 v3.10 does not support C11, only C99, which does not have
//     static_assert() in <assert.h>
//   - this firmware makes extensive use of static_assert() compile-time
//     checks
//   - so here we alias static_assert() to _Static_assert(), which xc8 does
//     provide
#if !defined(static_assert)
#  define static_assert _Static_assert
#endif

// MCU-neutral threshold invariants -- identical across all shells, so defined
// once here. Evaluated at file scope (zero runtime cost); a violation fails the
// build of every shell that includes this header.
static_assert(RELEASE_THRESH < DEBOUNCE_COUNTER_MAX, "RELEASE_THRESH >= UINT8_MAX");
static_assert(RELEASE_THRESH > 0U,                   "RELEASE_THRESH <= 0");
static_assert(RELEASE_THRESH > PRESSED_THRESH,       "RELEASE_THRESH <= PRESSED_THRESH");
static_assert(PRESSED_THRESH < DEBOUNCE_COUNTER_MAX, "PRESSED_THRESH >= UINT8_MAX");
static_assert(PRESSED_THRESH > 0U,                   "PRESSED_THRESH <= 0");

// pin-map sanity: the PIC pin map hard-codes PORTA bit positions as literals
// (0U,1U,2U,3U). Pin them at compile time against the DFP's _PORTA_RAx_POSN
// so a typo in the map or a DFP change can never silently misroute a pin
static_assert(FOOTSW_PIN  == _PORTA_RA3_POSN, "FOOTSW_PIN must be RA3");
static_assert(LED_PIN     == _PORTA_RA0_POSN, "LED_PIN must be RA0");
static_assert(CD4053_PIN  == _PORTA_RA1_POSN, "CD4053_PIN must be RA1");

// _XTAL_FREQ (a build flag, used by the drivers' __delay_ms) must match the
// 16MHz HFINTOSC selected in init(), or the coil/mute pulse widths
// would be wrong.
static_assert(_XTAL_FREQ == 16000000UL, "_XTAL_FREQ must be 16 MHz (matches OSCCON IRCF)");



//////////////////////////////////////////////////////////////////////////////
// TYPES
//////////////////////////////////////////////////////////////////////////////

// possible high-level states of the debounce/bypass scheme
typedef enum {
    // 1ms footswitch pin sampling, waiting for footswitch to be
    // press-debounced (i.e. footswitch considered open/released in this
    // state)
    PRESS_DEBOUNCE_WAIT = 0,

    // 1ms footswitch pin sampling, footswitch was previously confirmed
    // debounce-pressed, now waiting for footswitch to be release-debounced
    // (i.e. footswitch considered closed/pressed in this state)
    RELEASE_DEBOUNCE_WAIT,
} program_state_t;


// a flag to keep track of the effect/bypass state
typedef enum {
    BYPASS = 0,
    ENGAGED,
} effect_state_t;


typedef enum {
    PIN_STATE_LOW = 0,
    PIN_STATE_HIGH
} pin_state_t;


// wrap up the three global variables that comprise the runtime context of the
// debounce-bypass algorithm
typedef struct {
    program_state_t program_state;
    effect_state_t  effect_state;
    uint8_t         debounce_counter;
} debounce_context_t;






//////////////////////////////////////////////////////////////////////////////
// CROSS-BOUNDARY HW OPS (implement bypass_hw_iface.h)
//////////////////////////////////////////////////////////////////////////////

// LED_PIN high = status LED lit; low = dark. Outputs are written via LATA.
static void hw_led_pin_set_high(void) { LATA |=  (uint8_t)(1U << LED_PIN); }
static void hw_led_pin_set_low(void)  { LATA &= (uint8_t)~(1U << LED_PIN); }


// - set a GPIO pin high or low
// - assumes pin was previously configured as output
static void hw_pin_set_high(uint8_t const pin) { LATA |=  (uint8_t)(1U << pin); }
static void hw_pin_set_low(uint8_t const pin)  { LATA &= (uint8_t)~(1U << pin); }


// sanity-check utility: return non-zero IFF every pin in expected_mask is still
// configured as an output (its TRISA direction bit is still 0).
static uint8_t hw_output_pins_intact(uint8_t const expected_mask) {
    return (0U == (TRISA & expected_mask));
}


//#define OUTPUT_CD4053_SIMPLE (1)
//#define OUTPUT_CD4053_WITH_MUTE (1)
//#define OUTPUT_TQ2_RELAY (1)


//////////////////////////////////////////////////////////////////////////////
// OUTPUT VARIANT: CD4053 SIMPLE
#if defined(OUTPUT_CD4053_SIMPLE)

// assert critical pin directions hold: LED & CD4053 outputs, footswitch input
static uint8_t hw_is_sanity_check_failed(void) {
    return (hw_output_pins_intact((1U << LED_PIN) | (1U << CD4053_PIN)) == 0U);
}

// CD4053_PIN high -> mosfet on  -> 4053 control pins low
// CD4053_PIN low  -> mosfet off -> 4053 control pins high
static void hw_set_bypass_state(void) {
    hw_led_pin_set_low();        // dark status LED
    hw_pin_set_low(CD4053_PIN);  // set CD4053 pin low
}

static void hw_set_engaged_state(void) {
    hw_led_pin_set_high();       // light status LED
    hw_pin_set_high(CD4053_PIN); // set CD4053 pin high
}

//////////////////////////////////////////////////////////////////////////////
// OUTPUT VARIANT: CD4053 WITH MUTING
#elif defined(OUTPUT_CD4053_WITH_MUTE)

// how long to mute the effect before switching between effect/bypass
#  define CD4053_MUTE_DELAY_MS (5U)

static uint8_t hw_is_sanity_check_failed(void) {

    static_assert(CD4053_MUTE_DELAY_MS < RELEASE_THRESH,
            "CD4053 mute delay must be shorter than the release-lockout window, "
            "or the re-arm point can be missed during the blocking actuation");

    return (0U == hw_output_pins_intact((1U << LED_PIN) | (1U << CD4053_CTL1) | (1U << CD4053_CTL2)));
}

// See "Improved Scheme With Muting" in parent project (mcu-bypass-firmware)
// DESIGN_DOCUMENTATION.adoc
//
// NOTE: both set_bypass and set_engaged claim a re-assertion of the state
//       from which we're switching.  Note that "re-assertion" is not
//       technically true for the set_bypass function at startup (or after a
//       RESET) - this is because the hardware design intent is to default to
//       bypass state at power-on.  In effect, at power-on, the following
//       happens:
//          - the effect state is bypass due to hardware wiring
//          - the MCU boots, and immediately calls hw_set_bypass_state()
//          - the engaged state is "re-asserted": in this specific case, it
//            actually flips to engaged, then...
//          - immediately flips to bypass
//
static void hw_set_bypass_state(void) {
    hw_pin_set_high(CD4053_CTL1); // re-assert previous ENGAGED state
    hw_pin_set_high(CD4053_CTL2);

    hw_led_pin_set_low(); // dark status LED

    hw_pin_set_low(CD4053_CTL1); // MUTE
    __delay_ms(CD4053_MUTE_DELAY_MS); // busy sleep for pre-switch mute time

    hw_pin_set_low(CD4053_CTL2); // un-mute in BYPASS state
}

static void hw_set_engaged_state(void) {
    hw_pin_set_low(CD4053_CTL1); // re-assert previous BYPASS state
    hw_pin_set_low(CD4053_CTL2);

    hw_led_pin_set_high(); // light status LED

    hw_pin_set_high(CD4053_CTL2); // MUTE
    __delay_ms(CD4053_MUTE_DELAY_MS); // busy sleep for pre-switch mute time

    hw_pin_set_high(CD4053_CTL1); // un-mute in ENGAGED state
}

//////////////////////////////////////////////////////////////////////////////
// OUTPUT VARIANT: TQ2-L2-5V MECHANICAL RELAY
#elif defined(OUTPUT_TQ2_RELAY)

// Panasonic TQ-L2-5V specifies a 4ms minimum current pulse for the set/reset
// coils; multiple by a factor of three for a safety margin
#  define TQ2_L2_5V_PULSE_MS (12U) 

static uint8_t hw_is_sanity_check_failed(void) {

    static_assert(TQ2_L2_5V_PULSE_MS < RELEASE_THRESH,
            "relay coil pulse must be shorter than the release-lockout window, "
            "or the re-arm point can be missed during the blocking actuation");

    return (0U == hw_output_pins_intact((1U << LED_PIN) | (1U << RELAY_SET_PIN) | (1U << RELAY_RESET_PIN)));
}

// force both coils low
static void set_relay_coils_low(void) {
    hw_pin_set_low(RELAY_RESET_PIN);
    hw_pin_set_low(RELAY_SET_PIN);
}

static void hw_set_bypass_state(void) {
    set_relay_coils_low();

    hw_led_pin_set_low();        // dark status LED

    hw_pin_set_high(RELAY_RESET_PIN); // pulse reset coil
    __delay_ms(TQ2_L2_5V_PULSE_MS); // busy sleep for coil pulse time

    set_relay_coils_low();
}

static void hw_set_engaged_state(void) {
    set_relay_coils_low();

    hw_led_pin_set_high();       // light status LED

    hw_pin_set_high(RELAY_SET_PIN);   // pulse set coil
    __delay_ms(TQ2_L2_5V_PULSE_MS); // busy sleep for coil pulse time

    set_relay_coils_low();
}

#else
#  error "output scheme not defined: define one of OUTPUT_CD4053_SIMPLE, OUTPUT_CD4053_WITH_MUTE, or OUTPUT_TQ2_RELAY"
#endif





// infinite-loop function to force a watchdog reset, for critical, unrecoverable
// errors (presumably ultra-rare events: cosmic rays, extreme EMI). Disables
// interrupts first so nothing can pet the dog.
//
// IMPORTANT: relies on the watchdog being active (WDTE=ON in CONFIG); without
// it this would lock up the MCU.
__attribute__((noreturn)) static void hw_force_wdt_reset(void) {
    INTCONbits.GIE = 0;
    for (;;) { }
}


// read FOOTSW_PIN (RA3) to determine if it's high or low
//   FOOTSW_PIN high = switch open/released
//   FOOTSW_PIN low  = switch closed/pressed
// returns: PIN_STATE_HIGH or PIN_STATE_LOW
static pin_state_t hw_read_footswitch(void) {
    return (0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN))) ?
        PIN_STATE_LOW :
        PIN_STATE_HIGH;
}


// non-zero IFF the footswitch weak pull-up is genuinely active. The PIC weak
// pull-up has a TWO-part enable: the per-pin WPUA latch AND the global,
// active-low OPTION_REG.nWPUEN. An SEU/EMI flip of EITHER silently disables the
// pull-up, so both are checked.
//
// The two volatile SFRs are read into locals first so the && combines two plain
// (non-volatile) booleans: this keeps MISRA Rule 13.5 clean (no persistent side
// effect on the right operand of &&), which the project does not deviate.
static uint8_t hw_footswitch_pullup_intact(void) {
    uint8_t pin_latched = (uint8_t)(WPUA & (1U << FOOTSW_PIN));
    uint8_t wpu_global  = (uint8_t)OPTION_REGbits.nWPUEN; // 0 = enabled
    return (0U != pin_latched) && (0U == wpu_global);
}




//////////////////////////////////////////////////////////////////////////////
// PROGRAM GLOBALS
//////////////////////////////////////////////////////////////////////////////

// Overall debounce context.
static debounce_context_t ctx_;


//////////////////////////////////////////////////////////////////////////////
// INIT + MAIN
//////////////////////////////////////////////////////////////////////////////

// high-level initialization
// called at power-on, and after a reset (e.g. brown-out or watchdog timeout)
static void init(void) {

    // Pet the WDT first thing, mirroring the AVR shell's "re-arm first". Unlike
    // the AVR -- whose WDTCR collapses to the ~16ms minimum after a WDRF,
    // creating a short post-reset reset-loop hazard -- the PIC has no such
    // window: WDTE=ON runs the WDT from reset at its ~2s POR-default prescale
    // (1:65536 on the 31kHz LFINTOSC; confirm WDTCON's reset value in
    // DS40001585), which dwarfs init() + the <=12ms bypass pulse. init()
    // narrows the period to ~256ms afterward (WDTPS=0x08). This early pet is
    // therefore belt-and-suspenders, not required -- it documents why no early
    // arming is needed and costs one instruction.

    CLRWDT(); // reset the WDT countdown ("pet the dog")


    // configure exactly the pins in output_mask as outputs (TRISA bit = 0); all
    // other pins are left as inputs (TRISA bit = 1). The selected pins are made
    // digital (ANSELA bit = 0) and driven low (LATA bit = 0). RA3 is input-only and
    // always remains an input (its TRISA bit reads 1).
    LATA   &= (uint8_t)~BYPASS_OUTPUT_DDR_MASK;                     // selected pins -> low
    TRISA   = (uint8_t)((uint8_t)~BYPASS_OUTPUT_DDR_MASK & 0x0FU);  // mask pins = output, rest = input



    // core MCU bring-up: 16MHz HFINTOSC, all-digital port, the footswitch weak
    // pull-up, the global weak-pull-up enable, and the ~256ms watchdog period.
    // Does NOT start the tick timer (see below).
    //
    // Ordering: call AFTER output pins are configured (above) so the
    // ANSELA/pull-up writes here do not disturb the output-pin direction
    // setup.
    //
    // HFINTOSC = 16 MHz (IRCF = 0b111). Must match _XTAL_FREQ (asserted below),
    // which the relay/mute drivers' __delay_ms() relies on.
    OSCCONbits.IRCF = 0x07U;

    // entire port digital -- the I/O pins power up as analog inputs.
    ANSELA = 0x00U;

    // enable the footswitch (RA3) input pull-up; FOOTSW_PIN high = released,
    // low = pressed. (Belt-and-suspenders alongside any external pull-up.)
    WPUA  |= (uint8_t)(1U << FOOTSW_PIN);
    OPTION_REGbits.nWPUEN = 0; // enable weak pull-ups globally (active-low)

    // ~256ms (WDTPS = 0b01000 = 1:8192 on the ~31kHz LFINTOSC), mirroring the
    // AVR shell's 250ms. The LFINTOSC has ±25% tolerance (datasheet OS09) and
    // the WDT period is characterized at -37%/+69% (param 31), so worst-case
    // it is still ~160ms -- comfortably > the ~14ms worst-case pet-to-pet
    // window (1ms tick + 12ms relay coil pulse), unlike the prior 32ms (~1.4x
    // margin).
    WDTCONbits.WDTPS = 0x08U;



    // driver: default to bypass (may block on the relay/mute pulse, which is
    // shorter than one WDT period)
    hw_set_bypass_state();

    // initialize global switch state from the current footswitch level
    // typical startup case: assume switch is not pressed
    ctx_.program_state    = PRESS_DEBOUNCE_WAIT;
    ctx_.effect_state     = BYPASS;
    ctx_.debounce_counter = 0U;

    // special case: footswitch pressed during power-on: keep in bypass state,
    // but use timer + footswitch polling to wait for release
    if (PIN_STATE_LOW == hw_read_footswitch()) {
        ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
        ctx_.debounce_counter = RELEASE_THRESH;
    }



    // LAST: start + clear the tick, immediately before the loop, so no compare
    // match accumulated during init is mistaken for the first real tick.
    //
    // configure + start the 1ms tick on TMR2, polled (no interrupt). At FOSC=16MHz
    // the timer clock is FOSC/4 = 4MHz; the 1:16 PREscaler (T2CKPS) -> 250kHz, and
    // PR2=249 -> (249+1) = 250 counts = 1ms per period. The output POSTscaler
    // (T2OUTPS) is set to 1:1, so TMR2IF asserts on every PR2 match (once per 1ms),
    // not once per N matches. MUST run AFTER any blocking output actuation so a
    // TMR2IF that set during init is not mistaken for the first real tick.
    PR2   = 249U;        // 1ms period
    T2CON = 0x07U;       // T2CKPS = 0b11 (1:16 prescale), TMR2ON = 1
    PIR1bits.TMR2IF = 0; // start clean
}


// program entry point. Model B: a single polled 1ms loop. Each tick we sample +
// integrate the footswitch and advance the debounce state machine; CLRWDT at
// the end of every iteration is the main-loop liveness proof.
void main(void) {

    init(); // note: initializes ctx_

    for (;;) {

        // pause until the next 1ms tick, then clear the flag. The AVR sleeps
        // here; the PIC polls TMR2IF (Model B, no sleep) -- same contract,
        // hence the shared name.
        while (0U == PIR1bits.TMR2IF) { }
        PIR1bits.TMR2IF = 0;



        // basic sanity checks against outlier events (cosmic rays, extreme EMI);
        // always checked, regardless of state; force a WDT reset on any
        // violation. (No timer_isr_called_ guard as on AVR -- the PIC has no
        // ISR; main-loop liveness is proven by reaching CLRWDT() below.)
        if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                (ctx_.effect_state > ENGAGED) ||
                // assert footswitch pull-up still enabled
                (0U == hw_footswitch_pullup_intact()) ||
                (ctx_.debounce_counter > RELEASE_THRESH) ||
                // config-specific runtime sanity checks
                hw_is_sanity_check_failed()
           ) {
            hw_force_wdt_reset();
        }



        // debounce_integrate()
        //
        // sample + integrate this tick (in the main loop, not an ISR)
        //
        // saturating integrator update
        // footswitch pin zero (low) == switch closed
        // footswitch pin one (high) == switch open
        //
        // NOTE: ideally we'd make the debounce_counter const, since it is not
        // modified; however, making it cost makes both parameters const, and that
        // triggers clang-tidy errors about too-easily-swappable parameters.  MISRA-C
        // doesn't allow modifying parameters anyway, hence why we immediately make a
        // local copy of the parameter.  So the parameter is essentially const in
        // practice, though not explicitly enforced by the compiler.
        if (PIN_STATE_LOW == hw_read_footswitch()) { // switch closed
            if (ctx_.debounce_counter < RELEASE_THRESH) { ++ctx_.debounce_counter; }
        }
        else { // footswitch pin is high -> switch open
            if (ctx_.debounce_counter > 0U) { --ctx_.debounce_counter; }
        }




        // debounce_step()
        //
        // advance the debounce state machine.
        // NOTE: NOT const-qualified (unlike the AVR shell). XC8 places
        // const-qualified objects in program ROM, so a const local initialized
        // from a runtime call is rejected ("initializer element is not a
        // compile-time constant"). A required PIC/XC8 deviation.
        switch (ctx_.program_state) {

            // waiting for the footswitch to be press-debounced
            case PRESS_DEBOUNCE_WAIT:
                {
                    // check for press-debounced condition
                    if (ctx_.debounce_counter >= PRESSED_THRESH) {
                        ctx_.debounce_counter = RELEASE_THRESH;
                        ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
                        if (BYPASS == ctx_.effect_state)
                        { 
                            ctx_.effect_state = ENGAGED;
                            hw_set_engaged_state();
                        } else { // ENGAGED == ctx_.effect_state
                            ctx_.effect_state = BYPASS;
                            hw_set_bypass_state();
                        }
                    }
                }
                break;

            // waiting for the footswitch to be release-debounced
            // note: holding the switch closed, or mechanical
            //       failure (e.g. switch welded shut) causes this
            //       state to exist indefinitely: this is the design
            //       intent (software is "helpless", need physical
            //       human resolution)
            case RELEASE_DEBOUNCE_WAIT:
                {
                    if (0U == ctx_.debounce_counter) {
                        ctx_.program_state = PRESS_DEBOUNCE_WAIT;
                    }
                }
                break;

            // technically impossible to reach (sanity checks above would
            // catch this); but left for defense-in-depth/belt-and-suspenders
            // idiom of the overall project
            default:
                hw_force_wdt_reset();
                break;
        }


        // completing the loop body proves main() is alive
        CLRWDT(); // reset the WDT countdown ("pet the dog")
    }
}

