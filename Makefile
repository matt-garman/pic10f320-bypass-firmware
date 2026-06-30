# Makefile -- PIC10F320 bypass firmware (single-file, five output variants)
#
# The firmware is tiny; this Makefile carries the validation. The PIC10F320 has
# 256 words of program memory and 64 bytes of RAM -- HALF the flash of the
# PIC10F322 the parent project targets -- so the default build also gates the
# program-word count against that budget.
#
# Targets:
#   make / make all     build the .hex and check it against the 256-word budget
#   make size           print XC8's full program/data memory summary
#   make analyze        cppcheck bug-finding + MISRA-C:2012 (static analysis)
#   make analyze-cppcheck   cppcheck bug-finding pass only
#   make analyze-misra      MISRA-C:2012 conformance pass only
#   make test-config    verify the CONFIG word emitted into the built HEX
#   make test-gpsim     register-level functional test of the HEX in gpsim
#   make test           everything above (the full validation suite)
#   make test-variants  run `make test` for ALL five output variants
#   make release        VERSION=vX.Y.Z: build+validate+stage a prebuilt release
#   make help           print the full annotated target list
#   make clean          remove the build directory
#
# `make help` prints the complete target list; the above is just the core set.
#
# Each analysis/test target SKIPS CLEANLY (exit 0) when its tool is absent, so a
# partial toolchain still runs whatever it can.
#
# Toolchain: Microchip XC8 v3.10 + the PIC10-12Fxxx DFP, plus cppcheck (+ the
# MISRA addon + python3), gpsim, and a host C compiler. Override any of the
# variables below on the command line if your install paths differ, e.g.:
#   make PIC_CC=/path/to/xc8-cc PIC_DFP=/path/to/DFP/x.y.z/xc8

# --- toolchain + device ------------------------------------------------------
PIC_CC          ?= /opt/microchip/xc8/v3.10/bin/xc8-cc
PIC_DFP         ?= /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
PIC_CHIP        ?= 10F320
PIC_TAG         ?= pic10f320
PIC_XTAL        ?= 16000000UL

# PIC10F320 device budget: 256 words flash / 64 B RAM.
PIC_FLASH_WORDS ?= 256

# --- output variant ----------------------------------------------------------
# The firmware (bypass_mcu_pic10f320.c) supports three hardware output STAGES,
# selected at compile time by exactly one OUTPUT_* macro. Two of them (the analog
# switch stages) additionally come in two CONTROL-PIN DRIVE POLARITIES, giving
# five build variants in total:
#   - CD4053 at 9-18 V is driven through a MOSFET inverter (MCU high == switch
#     sees LOW), so its control pins are driven inverted (the default polarity);
#   - the pin-compatible TMUX4053 runs at logic level and is driven DIRECTLY
#     (-DBYPASS_X4053_DIRECT_DRIVE), so the SAME driver source emits the opposite
#     control-pin levels. Only the analog-switch control pins flip; the LED (RA0),
#     the debounce/switching logic, and the relay stage are unchanged.
# PIC_VARIANT picks one; the resulting -DOUTPUT_* [+ -DBYPASS_X4053_DIRECT_DRIVE]
# is threaded (via PIC_OUTPUT_DEF) through EVERY target that compiles or #includes
# the firmware (build, static analysis, equivalence, actuation, fault, gpsim,
# coverage). PIC_ENGAGED_LATA / PIC_BYPASS_LATA are the full RA0..RA2 LATA the
# variant drives when ENGAGED / in BYPASS (asserted by the gpsim test). RA0 (the
# LED) is bit 0 in all five, which is why the host equivalence/fault tests are
# polarity-independent -- but the direct-drive variants invert the CONTROL pins,
# so BYPASS no longer settles to 0x0 (hence the per-variant PIC_BYPASS_LATA).
#   cd4053-simple   : LED(RA0)+CD4053(RA1)   inverted   BYPASS 0x0  ENGAGED 0x3
#   tmux4053-simple : LED(RA0)+TMUX(RA1)     direct     BYPASS 0x2  ENGAGED 0x1
#   cd4053-mute     : LED(RA0)+CTL1+CTL2      inverted   BYPASS 0x0  ENGAGED 0x7
#   tmux4053-mute   : LED(RA0)+CTL1+CTL2      direct     BYPASS 0x6  ENGAGED 0x1
#   tq2-relay       : LED(RA0)+RESET+SET      n/a        BYPASS 0x0  ENGAGED 0x1 (coils pulse, settle low)
PIC_VARIANT     ?= cd4053-simple

# PIC_POLARITY_DEF is empty for the inverting (CD4053 / relay) variants and adds
# -DBYPASS_X4053_DIRECT_DRIVE for the direct-drive (TMUX4053) variants; it is
# folded into PIC_OUTPUT_DEF below so it reaches every firmware-compiling site.
PIC_POLARITY_DEF :=
ifeq ($(PIC_VARIANT),cd4053-simple)
  PIC_OUTPUT_MACRO := OUTPUT_CD4053_SIMPLE
  PIC_ENGAGED_LATA := 0x3
  PIC_BYPASS_LATA  := 0x0
else ifeq ($(PIC_VARIANT),tmux4053-simple)
  PIC_OUTPUT_MACRO := OUTPUT_CD4053_SIMPLE
  PIC_POLARITY_DEF := -DBYPASS_X4053_DIRECT_DRIVE
  PIC_ENGAGED_LATA := 0x1
  PIC_BYPASS_LATA  := 0x2
else ifeq ($(PIC_VARIANT),cd4053-mute)
  PIC_OUTPUT_MACRO := OUTPUT_CD4053_WITH_MUTE
  PIC_ENGAGED_LATA := 0x7
  PIC_BYPASS_LATA  := 0x0
else ifeq ($(PIC_VARIANT),tmux4053-mute)
  PIC_OUTPUT_MACRO := OUTPUT_CD4053_WITH_MUTE
  PIC_POLARITY_DEF := -DBYPASS_X4053_DIRECT_DRIVE
  PIC_ENGAGED_LATA := 0x1
  PIC_BYPASS_LATA  := 0x6
else ifeq ($(PIC_VARIANT),tq2-relay)
  PIC_OUTPUT_MACRO := OUTPUT_TQ2_RELAY
  PIC_ENGAGED_LATA := 0x1
  PIC_BYPASS_LATA  := 0x0
else
  $(error PIC_VARIANT must be one of: cd4053-simple tmux4053-simple cd4053-mute tmux4053-mute tq2-relay (got '$(PIC_VARIANT)'))
endif
PIC_OUTPUT_DEF  := -D$(PIC_OUTPUT_MACRO) $(PIC_POLARITY_DEF)

# --- sources + outputs -------------------------------------------------------
SRC             := bypass_mcu_pic10f320.c
FW_BASE         := bypass_mcu
BUILD_DIR       ?= build_pic
HEX             := $(BUILD_DIR)/$(FW_BASE)_$(PIC_VARIANT)_$(PIC_TAG).hex

# XC8 compile flags: select the PIC10F320 + its DFP, C99 (XC8 has no C11, so
# static_assert is aliased to _Static_assert in the source), -O2, and
# _XTAL_FREQ for __delay_ms / the 16 MHz HFINTOSC compile-time assert.
PIC_CFLAGS      := -mcpu=$(PIC_CHIP) -mdfp=$(PIC_DFP) -std=c99 -O2 \
                   -D_XTAL_FREQ=$(PIC_XTAL) $(PIC_OUTPUT_DEF)

# --- analysis + test tooling -------------------------------------------------
CPPCHECK        ?= cppcheck
GPSIM           ?= gpsim
HOST_CC         ?= gcc

# gpsim processor name for the register-level functional test. The per-variant
# settled ENGAGED / BYPASS LATA the test asserts come from PIC_ENGAGED_LATA /
# PIC_BYPASS_LATA above (e.g. cd4053-simple ENGAGED LED(RA0)|CD4053(RA1) = 0x3).
PIC_GPSIM_PROC  ?= p10f320

# XC8 + DFP header search paths: XC8's base include supplies xc.h; the DFP
# supplies pic.h + proc/pic10f320.h (selected by the chip macro -D_10F320). The
# pic8-enhanced cppcheck platform models the enhanced-midrange core (16-bit int).
PIC_XC8_INCLUDE ?= /opt/microchip/xc8/v3.10/pic/include
PIC_DFP_INCLUDE ?= $(PIC_DFP)/pic/include
PIC_CHIP_MACRO  ?= _$(PIC_CHIP)

# MISRA addon config (cppcheck): the addon wrapper, the rule-text file it points
# at, and this project's documented deviations (currently none).
MISRA_ADDON     ?= test/misra.json
MISRA_RULES     ?= test/misra_rules.txt
MISRA_SUPPRESS  ?= test/misra_suppressions.txt

# Defines/includes shared by both cppcheck passes: select the device header and
# add the XC8 + DFP header search paths.
PIC_CPPCHECK_CPPFLAGS = -D__XC8 -D$(PIC_CHIP_MACRO) -D_XTAL_FREQ=$(PIC_XTAL) $(PIC_OUTPUT_DEF) \
                        -I$(PIC_DFP_INCLUDE) -I$(PIC_DFP_INCLUDE)/proc -I$(PIC_XC8_INCLUDE)

# cppcheck bug-finding pass.
PIC_CPPCHECK_FLAGS ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=pic8-enhanced --error-exitcode=2 \
                      --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC_DFP_INCLUDE)/*' \
                      $(PIC_CPPCHECK_CPPFLAGS)

# MISRA-C:2012 conformance pass. --suppress=misra-config: cppcheck cannot
# value-flow-model the volatile SFR bitfield unions from the Microchip headers
# (e.g. PIR1bits.TMR2IF in the tick poll); that is a modeling limitation on
# adopted toolchain headers, NOT a code defect.
PIC_MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 --platform=pic8-enhanced \
                      --enable=style --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=misra-config \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC_DFP_INCLUDE)/*' \
                      $(PIC_CPPCHECK_CPPFLAGS)

# --- host model / formal / equivalence tooling -------------------------------
# Host C compiler + strict flags for OUR test code (the vendored model and the
# test drivers). The firmware harness (test/equiv/fw_harness.c) is compiled with
# relaxed flags because it pulls in the XC8-targeted firmware verbatim.
HOST_CC      ?= gcc
HOST_CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Werror
# Include dirs: -Itest finds model_step.h; -Itest/model finds the vendored
# bypass_pure.h / bypass_types.h / bypass_config.h.
HOST_INC     := -Itest -Itest/model
MODEL_SRC    := test/model/bypass_pure.c

# CBMC formal proofs (bounded model checking of the vendored model).
CBMC         ?= cbmc
CBMC_CHECKS  ?= --bounds-check --pointer-check --div-by-zero-check \
                --signed-overflow-check --unsigned-overflow-check \
                --conversion-check --undefined-shift-check
CBMC_PROOFS_STRAIGHT := prove_integrate prove_debounce_step prove_corrupt_state_faults \
                        prove_init_context prove_step_transition prove_oor_recovery_step
CBMC_PROOFS_LOOP     := prove_press_liveness prove_release_liveness
CBMC_PROOF_DEEP      := prove_oor_recovery_bounded
CBMC_DEEP_UNWIND     := 257

# Coverage (gcov) of the vendored model, driven by the host unit tests.
COVERAGE_DIR ?= coverage
COVERAGE_MIN ?= 95

# Firmware fault-injection harness (test/fault): runs the REAL firmware on the
# host and exercises its defensive / fault-detection paths -- the per-tick SEU/EMI
# sanity gate, the pull-up / output-pin checks, and hw_force_wdt_reset() -- which
# the equivalence test (valid stimulus only) never reaches. The harness #includes
# the firmware (-Dmain=fw_main) and uses the same mock <xc.h> as test/equiv.
FAULT_HARNESS  := test/fault/fw_fault_harness.c
FAULT_DRIVER   := test/fault/test_fault.c
FAULT_FW_DEFS  := -Wno-unknown-pragmas -Dmain=fw_main -D_XTAL_FREQ=$(PIC_XTAL) $(PIC_OUTPUT_DEF)
FAULT_INC      := -Itest/equiv -Itest/fault

.PHONY: all size analyze analyze-cppcheck analyze-misra \
        test test-variants test-config test-gpsim \
        test-host test-formal test-model-check test-symbolic test-symbolic-klee \
        test-cbmc test-equiv test-actuation test-soak \
        test-fault test-mutation coverage coverage-check coverage-check-fw \
        coverage-clean clean

# Build + enforce the flash-word budget. XC8 scatters intermediates
# (startup.*, *.p1, *.d, .elf/.cmf/.hxl/.sym/.sdb) into its working directory,
# so the compile runs with its cwd inside BUILD_DIR to keep the repo root clean
# and the source path is made absolute. The program-word count is parsed from
# XC8's "Program space used ... ( N )" line and compared to PIC_FLASH_WORDS.
all: $(SRC)
	@if [ ! -x "$(PIC_CC)" ] && ! command -v $(PIC_CC) >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC_CC) (override with PIC_CC=...)"; exit 1; \
	fi
	@mkdir -p $(BUILD_DIR)
	@echo "=== PIC10F320 build + flash-budget ($(PIC_FLASH_WORDS) words, variant $(PIC_VARIANT)) ==="
	@out=`cd $(BUILD_DIR) && $(PIC_CC) $(PIC_CFLAGS) $(CURDIR)/$(SRC) \
		-o $(notdir $(HEX)) 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: did not compile for PIC10F320"; exit 1; }; \
	dec=`printf '%s\n' "$$out" | grep -E 'Program space' \
		| grep -oE '\( *[0-9]+ *\)' | head -1 | tr -d '() '`; \
	if [ -z "$$dec" ]; then \
		echo "WARN: could not parse program-word count from XC8 output:"; \
		printf '%s\n' "$$out"; exit 0; \
	fi; \
	pct=`awk -v u=$$dec -v t=$(PIC_FLASH_WORDS) 'BEGIN{printf "%.1f", u*100/t}'`; \
	if [ $$dec -gt $(PIC_FLASH_WORDS) ]; then \
		echo "FAIL: uses $$dec words ($${pct}%) -- exceeds $(PIC_FLASH_WORDS)"; exit 1; \
	else \
		echo "OK:   $(HEX) : $$dec words ($${pct}%) of $(PIC_FLASH_WORDS)"; \
	fi

# Print XC8's full memory-usage summary (program + data space).
size: $(SRC)
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && $(PIC_CC) $(PIC_CFLAGS) $(CURDIR)/$(SRC) \
		-o $(notdir $(HEX)) 2>&1 | grep -iE 'space|memory summary' || true

# --- static analysis ---------------------------------------------------------
analyze: analyze-cppcheck analyze-misra
	@echo "=== static analysis (cppcheck + MISRA) complete ==="

# cppcheck bug-finding pass on the single firmware TU.
analyze-cppcheck: $(SRC)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping cppcheck analysis"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC_DFP_INCLUDE)/proc/pic10f320.h" ]; then \
		echo "XC8/DFP headers not found; skipping cppcheck analysis"; exit 0; \
	fi; \
	echo "cppcheck (pic8-enhanced): $(SRC)"; \
	$(CPPCHECK) $(PIC_CPPCHECK_FLAGS) $(SRC)

# MISRA-C:2012 conformance pass. Findings not covered by a documented deviation
# (MISRA_SUPPRESS) fail the build. PYTHONWARNINGS=ignore silences a
# DeprecationWarning from misra.py that cppcheck would otherwise treat as an
# addon execution failure.
analyze-misra: $(SRC) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping MISRA analysis"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC_DFP_INCLUDE)/proc/pic10f320.h" ]; then \
		echo "XC8/DFP headers not found; skipping MISRA analysis"; exit 0; \
	fi; \
	echo "MISRA-C:2012 analysis (cppcheck + misra addon, pic8-enhanced)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(PIC_MISRA_CPPCHECK_FLAGS) \
		--suppressions-list=$(MISRA_SUPPRESS) --error-exitcode=2 \
		$(SRC) 2>>$$out || rc=1; \
	if [ $$rc -ne 0 ]; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
		grep -E "misra-c2012" $$out || cat $$out; \
		echo ""; \
		echo "Fix it, or (if genuinely unavoidable) add a per-file entry to"; \
		echo "$(MISRA_SUPPRESS) with a matching record in MISRA_COMPLIANCE.md."; \
		rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
		exit 1; \
	fi; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
	echo "MISRA-C:2012: clean (no deviations)"

# --- functional / device tests -----------------------------------------------
# Verify the EXACT CONFIG word XC8 emitted into the built HEX from the firmware's
# #pragma config block matches the documented design intent (FOSC=INTOSC,
# WDTE=ON, MCLRE=OFF, BOREN=ON, ...). A bad pragma is invisible to every other
# test and would only bite on real silicon.
# Verify the CONFIG word in the built HEX(es). `all` always builds the selected
# variant's $(HEX); we additionally pass any sibling variant HEXes already present
# in the build dir (e.g. from a `test-variants` sweep) so a single invocation
# cross-checks every built image at once -- realising test_config_pic's documented
# multi-HEX divergence check. (`sort` dedupes; $(HEX) is guaranteed present here.)
test-config: all
	@if ! command -v $(HOST_CC) >/dev/null 2>&1; then \
		echo "$(HOST_CC) not installed; skipping CONFIG-word check"; exit 0; \
	fi
	@$(HOST_CC) -std=c11 -Wall -Wextra -O2 -o $(BUILD_DIR)/test_config_pic test/pic/test_config_pic.c
	@$(BUILD_DIR)/test_config_pic $(sort $(HEX) $(wildcard $(BUILD_DIR)/$(FW_BASE)_*_$(PIC_TAG).hex))

# Run the real built HEX inside gpsim and assert observable register state at
# settled checkpoints: (1) two-press toggle -- power-on BYPASS, press toggles +
# latches ENGAGED, second press toggles back; (2) power-on-pressed -- a switch
# held at boot must come up BYPASS and not engage until a genuine release + fresh
# press. This is the closest thing to running on real silicon.
test-gpsim: all
	@if ! command -v $(GPSIM) >/dev/null 2>&1; then \
		echo "gpsim not installed; skipping gpsim register-level test"; exit 0; \
	fi
	@PIC_GPSIM_PROC=$(PIC_GPSIM_PROC) GPSIM=$(GPSIM) \
		test/pic/run_gpsim_test.sh $(HEX) $(PIC_ENGAGED_LATA) $(PIC_BYPASS_LATA)
	@PIC_GPSIM_PROC=$(PIC_GPSIM_PROC) GPSIM=$(GPSIM) \
		test/pic/run_gpsim_power_on_pressed.sh $(HEX)

# --- host model tests (the vendored reference model) -------------------------
# Unit / property / fuzz / Monte-Carlo tests of the vendored reference model
# (test/model/bypass_pure.c), which the firmware inlines. See test/README.md.
test-host:
	@mkdir -p $(BUILD_DIR)
	@$(HOST_CC) $(HOST_CFLAGS) $(HOST_INC) \
		test/host/test_logic_host.c $(MODEL_SRC) -o $(BUILD_DIR)/test_logic_host
	@$(BUILD_DIR)/test_logic_host

# Exhaustive small-model state-space verification (BFS over all reachable states).
test-model-check:
	@mkdir -p $(BUILD_DIR)
	@$(HOST_CC) $(HOST_CFLAGS) $(HOST_INC) \
		test/formal/test_model_check.c $(MODEL_SRC) -o $(BUILD_DIR)/test_model_check
	@$(BUILD_DIR)/test_model_check

# Exhaustive single-step property check over the full input domain.
test-symbolic:
	@mkdir -p $(BUILD_DIR)
	@$(HOST_CC) $(HOST_CFLAGS) $(HOST_INC) \
		test/formal/test_symbolic.c $(MODEL_SRC) -o $(BUILD_DIR)/test_symbolic
	@$(BUILD_DIR)/test_symbolic

# Optional: run the SAME single-step properties under KLEE symbolic execution
# (only if KLEE + its matching clang/llvm-link are installed). KLEE explores the
# symbolic input domain with an SMT solver instead of enumerating it; the
# exhaustive 'test-symbolic' target already covers the same domain, so this is a
# bonus -- NOT part of `make test`, and skips cleanly when KLEE is absent.
#
# test_symbolic.c's step() delegates to the vendored model's debounce_integrate()
# / debounce_step() (test/model/bypass_pure.c), so BOTH are compiled to bitcode
# and llvm-link'd before KLEE runs -- otherwise the model functions would be
# undefined externals and the proof unsound. Override the tool paths if your KLEE
# install uses a versioned clang/llvm-link (KLEE needs a matching LLVM).
KLEE          ?= klee
KLEE_CLANG    ?= clang
KLEE_LLVMLINK ?= llvm-link
KLEE_INC      ?= /usr/include
.PHONY: test-symbolic-klee
test-symbolic-klee:
	@if command -v $(KLEE) >/dev/null 2>&1 && command -v $(KLEE_CLANG) >/dev/null 2>&1 \
	   && command -v $(KLEE_LLVMLINK) >/dev/null 2>&1; then \
		mkdir -p $(BUILD_DIR); \
		echo "KLEE symbolic execution of the single-step property bundle:"; \
		$(KLEE_CLANG) -DUSE_KLEE -I$(KLEE_INC) $(HOST_INC) -emit-llvm -c -g -O0 \
			test/formal/test_symbolic.c -o $(BUILD_DIR)/test_symbolic.bc && \
		$(KLEE_CLANG) -DUSE_KLEE -I$(KLEE_INC) $(HOST_INC) -emit-llvm -c -g -O0 \
			$(MODEL_SRC) -o $(BUILD_DIR)/bypass_pure_klee.bc && \
		$(KLEE_LLVMLINK) $(BUILD_DIR)/test_symbolic.bc $(BUILD_DIR)/bypass_pure_klee.bc \
			-o $(BUILD_DIR)/test_symbolic_klee.bc && \
		$(KLEE) --exit-on-error $(BUILD_DIR)/test_symbolic_klee.bc; \
	else \
		echo "KLEE (or its matching clang/llvm-link) not installed; the exhaustive"; \
		echo "'test-symbolic' target covers the same input domain. Install klee +"; \
		echo "a matching llvm to enable SMT-backed symbolic execution."; \
	fi

# CBMC bounded model checking of the vendored model (SAT/SMT backend), proving the
# same invariants over the symbolic domain plus freedom from UB. Skips if absent.
test-cbmc:
	@if ! command -v $(CBMC) >/dev/null 2>&1; then \
		echo "cbmc not installed; skipping (test-model-check/test-symbolic cover the same properties)"; \
		exit 0; \
	fi
	@for p in $(CBMC_PROOFS_STRAIGHT); do \
		echo "cbmc: $$p"; \
		$(CBMC) test/formal/test_cbmc.c $(MODEL_SRC) $(HOST_INC) --function $$p \
			$(CBMC_CHECKS) >/dev/null 2>$(BUILD_DIR)/cbmc.err \
			|| { echo "  FAIL"; cat $(BUILD_DIR)/cbmc.err; exit 1; }; \
	done
	@for p in $(CBMC_PROOFS_LOOP); do \
		echo "cbmc: $$p (--unwind 50)"; \
		$(CBMC) test/formal/test_cbmc.c $(MODEL_SRC) $(HOST_INC) --function $$p \
			--unwind 50 --unwinding-assertions $(CBMC_CHECKS) >/dev/null 2>$(BUILD_DIR)/cbmc.err \
			|| { echo "  FAIL"; cat $(BUILD_DIR)/cbmc.err; exit 1; }; \
	done
	@echo "cbmc: $(CBMC_PROOF_DEEP) (--unwind $(CBMC_DEEP_UNWIND))"
	@$(CBMC) test/formal/test_cbmc.c $(MODEL_SRC) $(HOST_INC) --function $(CBMC_PROOF_DEEP) \
		--unwind $(CBMC_DEEP_UNWIND) --unwinding-assertions $(CBMC_CHECKS) \
		>/dev/null 2>$(BUILD_DIR)/cbmc.err \
		|| { echo "  FAIL"; cat $(BUILD_DIR)/cbmc.err; exit 1; }
	@echo "CBMC: all debounce-model proofs SUCCESSFUL"

# All formal proofs.
test-formal: test-model-check test-symbolic test-cbmc
	@echo "=== formal verification (model-check + symbolic + cbmc) complete ==="

# --- firmware <-> model equivalence ------------------------------------------
# Run the REAL firmware on the host (fw_harness.c + mock xc.h) over exhaustive +
# random footswitch stimulus, and assert its LED/CD4053 output trace matches the
# vendored model tick-for-tick. This is what ties the firmware to the host- and
# formally-verified model, and auto-guards against debounce-threshold drift.
# Two translation units: the firmware harness (relaxed flags, -Dmain=fw_main,
# the firmware is XC8-targeted C) and our strict driver + model.
test-equiv:
	@mkdir -p $(BUILD_DIR)
	@$(HOST_CC) -std=c11 -O2 -Wno-unknown-pragmas -Dmain=fw_main -D_XTAL_FREQ=$(PIC_XTAL) $(PIC_OUTPUT_DEF) \
		-Itest/equiv -c test/equiv/fw_harness.c -o $(BUILD_DIR)/fw_harness.o
	@$(HOST_CC) $(HOST_CFLAGS) $(HOST_INC) -c test/equiv/test_equiv.c -o $(BUILD_DIR)/test_equiv_drv.o
	@$(HOST_CC) $(HOST_CFLAGS) $(HOST_INC) -c $(MODEL_SRC) -o $(BUILD_DIR)/bypass_pure_equiv.o
	@$(HOST_CC) $(BUILD_DIR)/fw_harness.o $(BUILD_DIR)/test_equiv_drv.o $(BUILD_DIR)/bypass_pure_equiv.o \
		-o $(BUILD_DIR)/test_equiv
	@$(BUILD_DIR)/test_equiv

# --- firmware actuation-sequence test ----------------------------------------
# The cd4053-mute and tq2-relay drivers BLOCK on __delay_ms() mid-actuation -- after
# asserting the mute / energising a relay coil, before releasing it. test-equiv
# only watches RA0 and test-gpsim only samples the SETTLED register state, so
# neither can see the transient: a swapped relay set/reset coil (relay latches
# backwards) or a defeated mute settles to the same state and passes both. This
# routes the firmware's __delay_ms() through the mock's hook (test/equiv/xc.h) so
# fw_harness.c snapshots LATA at each actuation, then asserts the per-variant
# mid-actuation pin pattern + pulse width. Reuses the equiv firmware harness
# (fw_harness.o); cd4053-simple has no blocking actuation, so the test asserts it
# produces zero snapshots.
test-actuation:
	@mkdir -p $(BUILD_DIR)
	@$(HOST_CC) -std=c11 -O2 -Wno-unknown-pragmas -Dmain=fw_main -D_XTAL_FREQ=$(PIC_XTAL) $(PIC_OUTPUT_DEF) \
		-Itest/equiv -c test/equiv/fw_harness.c -o $(BUILD_DIR)/fw_harness.o
	@$(HOST_CC) $(HOST_CFLAGS) $(PIC_OUTPUT_DEF) -c test/actuation/test_actuation.c -o $(BUILD_DIR)/test_actuation_drv.o
	@$(HOST_CC) $(BUILD_DIR)/fw_harness.o $(BUILD_DIR)/test_actuation_drv.o -o $(BUILD_DIR)/test_actuation
	@$(BUILD_DIR)/test_actuation

# --- firmware fault-injection / defensive-path tests -------------------------
# Run the REAL firmware on the host and prove its fault-detection layer works:
# the per-tick SEU/EMI sanity gate forces a watchdog reset on a corrupted state
# or critical-SFR flip (and valid states do NOT), and the static sanity
# predicates return the right verdict for good and corrupted SFRs. This reaches
# the code the equivalence test (valid stimulus only) cannot. Two TUs, mirroring
# test-equiv: the harness (relaxed flags, -Dmain=fw_main, includes the firmware)
# and our strict driver.
test-fault:
	@mkdir -p $(BUILD_DIR)
	@$(HOST_CC) -std=c11 -O2 $(FAULT_FW_DEFS) $(FAULT_INC) \
		-c $(FAULT_HARNESS) -o $(BUILD_DIR)/fw_fault_harness.o
	@$(HOST_CC) $(HOST_CFLAGS) $(FAULT_INC) -c $(FAULT_DRIVER) -o $(BUILD_DIR)/test_fault_drv.o
	@$(HOST_CC) $(BUILD_DIR)/fw_fault_harness.o $(BUILD_DIR)/test_fault_drv.o -o $(BUILD_DIR)/test_fault
	@$(BUILD_DIR)/test_fault

# --- coverage (of the vendored model) ----------------------------------------
# Coverage is accumulated ACROSS the host unit tests AND the two exhaustive
# formal tests: the model is compiled once into a single instrumented object
# (model_cov.o) that all three test binaries link, so each run appends to the
# same gcov data and the report reflects the whole logic suite (the host tests
# exercise the valid-state behaviour; the formal tests additionally drive the
# corrupt-state fault path). The list is intentionally shared by both targets.
COVERAGE_TESTS := host/test_logic_host formal/test_model_check formal/test_symbolic

define RUN_MODEL_COVERAGE
	mkdir -p $(COVERAGE_DIR); \
	$(HOST_CC) -std=c11 -O0 $(HOST_INC) --coverage -c $(MODEL_SRC) \
		-o $(COVERAGE_DIR)/model_cov.o || exit 1; \
	for t in $(COVERAGE_TESTS); do \
		b=$(COVERAGE_DIR)/`basename $$t`_cov; \
		$(HOST_CC) -std=c11 -O0 $(HOST_INC) --coverage test/$$t.c \
			$(COVERAGE_DIR)/model_cov.o -o $$b || exit 1; \
		$$b >/dev/null || exit 1; \
	done
endef

coverage:
	@$(RUN_MODEL_COVERAGE)
	@cd $(COVERAGE_DIR) && gcov -b model_cov >/dev/null 2>&1 || true
	@echo "Coverage report: $(COVERAGE_DIR)/bypass_pure.c.gcov"

# Coverage GATE (wired into `make test`): fail if model line coverage drops below
# COVERAGE_MIN. The debounce model is small and the suite exercises it fully.
coverage-check:
	@$(RUN_MODEL_COVERAGE)
	@pct=`cd $(COVERAGE_DIR) && gcov model_cov 2>/dev/null \
		| awk -F'[:%]' '/Lines executed/{print $$2; exit}'`; \
	echo "model line coverage (host + formal): $${pct:-unknown}% (floor $(COVERAGE_MIN)%)"; \
	if [ -z "$$pct" ]; then \
		echo "WARNING: could not parse gcov coverage; not gating."; \
	else \
		awk -v p="$$pct" -v m="$(COVERAGE_MIN)" 'BEGIN{exit !(p+0>=m+0)}' \
			|| { echo "FAIL: coverage $$pct% below floor $(COVERAGE_MIN)%"; exit 1; }; \
	fi

# Firmware coverage GATE (wired into `make test`): unlike the model gate above
# (a percentage floor), this asserts every line of the SHIPPING firmware
# (bypass_mcu_pic10f320.c) is exercised on the host EXCEPT the allow-listed
# watchdog-reset fault path -- see test/fault/check_fw_coverage.sh for why those
# lines are uncoverable here. The fault harness #includes the firmware, so
# instrumenting it measures the real TU. gcov runs from the repo root so the
# #included firmware source resolves for line annotation.
coverage-check-fw:
	@mkdir -p $(COVERAGE_DIR)
	@# Clear stale gcov artifacts first: different output variants compile a
	@# different-sized firmware into the same coverage objects, so a leftover
	@# .gcda/.gcno from a prior variant (e.g. during `make test-variants`) trips
	@# libgcov's "overwriting an existing profile data with a different checksum".
	@rm -f $(COVERAGE_DIR)/fw_fault_cov.gcda $(COVERAGE_DIR)/fw_fault_cov.gcno \
		$(COVERAGE_DIR)/test_fault_cov_drv.gcda $(COVERAGE_DIR)/test_fault_cov_drv.gcno
	@$(HOST_CC) -std=c11 -O0 --coverage $(FAULT_FW_DEFS) $(FAULT_INC) \
		-c $(FAULT_HARNESS) -o $(COVERAGE_DIR)/fw_fault_cov.o
	@$(HOST_CC) -std=c11 -O0 --coverage $(FAULT_INC) \
		-c $(FAULT_DRIVER) -o $(COVERAGE_DIR)/test_fault_cov_drv.o
	@$(HOST_CC) --coverage $(COVERAGE_DIR)/fw_fault_cov.o $(COVERAGE_DIR)/test_fault_cov_drv.o \
		-o $(COVERAGE_DIR)/test_fault_cov
	@$(COVERAGE_DIR)/test_fault_cov >/dev/null
	@gcov -o $(COVERAGE_DIR) $(COVERAGE_DIR)/fw_fault_cov.o >/dev/null 2>&1 || true
	@echo "firmware line coverage (fault + happy-path harness):"
	@test/fault/check_fw_coverage.sh bypass_mcu_pic10f320.c.gcov; rc=$$?; \
		rm -f *.gcov; exit $$rc

coverage-clean:
	rm -rf $(COVERAGE_DIR)
	rm -f *.gcov
	find . -name '*.gcda' -o -name '*.gcno' | xargs rm -f 2>/dev/null || true

# --- long-duration gpsim soak (libgpsim) -------------------------------------
# Drive the real built HEX in gpsim -- via libgpsim, NOT the gpsim CLI -- for
# PIC_SOAK_DURATION_MS of simulated time, asserting WDT liveness + a periodic
# 2-press responsiveness round-trip. Failures are non-fatal and logged; the run
# continues the full duration. Variant-agnostic (the LED is RA0 on every
# variant); PIC_VARIANT selects which HEX is soaked. See test/pic/test_soak_pic.cc.
#
# STANDALONE -- deliberately NOT in `make test`: it runs for minutes and links
# libgpsim, which needs the gpsim-dev + libglib2.0-dev headers (CI may lack
# them). Skips cleanly (exit 0) when the compiler, those headers, glib, or the
# built HEX are absent -- exactly as `test-gpsim` skips without gpsim. Phony +
# always recompiles so PIC_SOAK_* command-line overrides are always applied.
#
# Overrides: PIC_VARIANT, PIC_SOAK_DURATION_MS (default 1 h; pass 86400000 for
# 24 h), PIC_SOAK_LIVENESS_INTERVAL_MS, PIC_SOAK_PROGRESS_INTERVAL_MS.
PIC_SOAK_CXX         ?= c++
PIC_SOAK_GPSIM_INC   ?= /usr/include/gpsim
PIC_SOAK_DURATION_MS ?= 3600000
PIC_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC_SOAK_SRC = test/pic/test_soak_pic.cc
PIC_SOAK_BIN = $(BUILD_DIR)/test_soak_pic

# The single compile recipe, shared by the build-only rule and the run target
# below. FW_PATH is baked as an ABSOLUTE path ($(CURDIR)/$(HEX)) so the resulting
# binary does not depend on the cwd it is launched from. That matters for the
# release pipeline: scripts/make-release.sh builds one soak binary per variant
# (under unique PIC_SOAK_BIN names) and runs them in PARALLEL, each in its own
# working directory, so the gpsim.log files (gpsim always drops one in the cwd)
# never collide. Running from the repo root (as test-soak does) is unaffected --
# an absolute FW_PATH resolves either way.
PIC_SOAK_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest/model \
		-DFW_PATH='"$(CURDIR)/$(HEX)"' -DPROC_NAME='"$(PIC_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC_XTAL) \
		-DSOAK_DURATION_MS=$(PIC_SOAK_DURATION_MS) \
		-DSOAK_LIVENESS_INTERVAL_MS=$(PIC_SOAK_LIVENESS_INTERVAL_MS) \
		-DSOAK_PROGRESS_INTERVAL_MS=$(PIC_SOAK_PROGRESS_INTERVAL_MS) \
		$(PIC_SOAK_SRC) -o $(PIC_SOAK_BIN) -lgpsim

# Build-only convenience rule: compile the soak driver for the selected
# PIC_VARIANT to PIC_SOAK_BIN WITHOUT running it. Used by scripts/make-release.sh,
# which builds one binary per variant under unique PIC_SOAK_BIN names and then
# runs them concurrently. The HEX it embeds is produced by `make all`, which the
# release script runs first; this rule will not rebuild on a PIC_SOAK_DURATION_MS
# change alone, so the release script always `make clean`s before a fresh build.
$(PIC_SOAK_BIN): $(PIC_SOAK_SRC)
	$(PIC_SOAK_COMPILE)

.PHONY: test-soak
test-soak: all
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping gpsim soak"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping soak (install gpsim-dev)"; exit 0; \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping soak (install libglib2.0-dev)"; exit 0; \
	fi; \
	if [ ! -f "$(HEX)" ]; then \
		echo "no $(HEX) (XC8 absent?); skipping soak"; exit 0; \
	fi; \
	echo "--- gpsim soak: variant=$(PIC_VARIANT) proc=$(PIC_GPSIM_PROC) duration=$(PIC_SOAK_DURATION_MS) ms ---"; \
	$(PIC_SOAK_COMPILE); \
	./$(PIC_SOAK_BIN)

# --- mutation testing --------------------------------------------------------
# Inject deliberate faults into the firmware and the model, and confirm the suite
# detects each one. NOT part of `make test` (it rebuilds per mutant).
test-mutation:
	./test/run_mutation_tests.sh

# The full validation suite (everything that gates; mutation is separate).
test: all analyze test-config test-host test-formal test-equiv test-actuation test-fault test-gpsim \
      coverage-check coverage-check-fw
	@echo "=== all PIC10F320 validation complete (variant $(PIC_VARIANT)) ==="

# Run the full validation suite for EVERY output variant in turn. `make test`
# alone covers just the default PIC_VARIANT; this sweeps all five. The debounce
# logic is identical across variants, but each pairs a distinct output driver /
# control-pin drive polarity with its own sanity-check pin mask, flash budget,
# and gpsim BYPASS/ENGAGED LATA pattern, so each is built and validated
# independently (the parent project validates all variants the same way). The two
# tmux4053-* variants reuse their cd4053-* sibling's driver source with the
# direct-drive polarity, so the switching logic can never drift between them.
PIC_VARIANTS_ALL ?= cd4053-simple tmux4053-simple cd4053-mute tmux4053-mute tq2-relay
test-variants:
	@for v in $(PIC_VARIANTS_ALL); do \
		echo "===================== VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC_VARIANT=$$v test || exit 1; \
	done
	@echo "=== all output variants validated ==="

clean:
	rm -rf $(BUILD_DIR) $(COVERAGE_DIR)
	rm -f *.dump *.ctu-info cppcheck-addon-ctu-file-list* *.gcov
	find . -name '*.gcda' -o -name '*.gcno' | xargs rm -f 2>/dev/null || true

# ============================================================================
# INTROSPECTION -- expose one Makefile variable's value to scripts
# ============================================================================
# `make print-PIC_VARIANTS_ALL` echoes "$(PIC_VARIANTS_ALL)", `make print-PIC_CC`
# echoes the XC8 path, and so on. scripts/make-release.sh reads the variant list,
# device names, build dir, and toolchain paths through this target so they come
# from THIS Makefile (the single source of truth) rather than a hand-maintained
# copy that could silently drift.
print-%:
	@echo '$($*)'

# ============================================================================
# RELEASE -- reproducible, fully-validated prebuilt firmware images
# ============================================================================
# Thin wrapper around scripts/make-release.sh. The script is a deliberate,
# long-running (~24 h, because of the parallel 24-h soaks) pre-tag gate that:
#   1. refuses to run unless the working tree is clean and EVERY required tool
#      is present (the inverse of the dev-time "skip cleanly" behaviour -- a
#      release must never green-light on a tool that silently did nothing);
#   2. clean-builds all five output-variant images;
#   3. runs `make test-variants` and ALL soak combos (one per variant) in parallel;
#   4. stages release/<VERSION>/ with the .hex images, SHA256SUMS, a provenance
#      MANIFEST (toolchain versions, per-image flash usage / CONFIG word, flashing
#      command, soak evidence) and a README;
#   5. STOPS and prints the exact `git add` / `git commit` / `git tag -s` and
#      checksum-signing commands for you to run by hand (it never commits or tags).
# The pushed tag then triggers .github/workflows/release.yml, which rebuilds from
# the tag on a clean runner, verifies the committed image hashes reproduce
# bit-for-bit, and publishes the GitHub Release.
#
#   make release VERSION=v1.0.0
#   make release VERSION=v1.0.0 RELEASE_ARGS='--dry-run'   # short soak rehearsal
.PHONY: release
release:
	@if [ -z "$(VERSION)" ]; then \
		echo "usage: make release VERSION=vX.Y.Z [RELEASE_ARGS='--dry-run']"; \
		exit 2; \
	fi
	./scripts/make-release.sh $(RELEASE_ARGS) $(VERSION)

# ============================================================================
# HELP
# ============================================================================
.PHONY: help
help:
	@echo "PIC10F320 bypass firmware -- annotated target list."
	@echo "Variants: $(PIC_VARIANTS_ALL)  (select with PIC_VARIANT=<name>; default $(PIC_VARIANT))"
	@echo "MCU: PIC10F320 ($(PIC_FLASH_WORDS)-word flash / 64 B RAM), 16 MHz INTOSC"
	@echo "Build:"
	@echo "  all (default)   build the selected variant's .hex + $(PIC_FLASH_WORDS)-word flash-budget gate"
	@echo "  size            print XC8's full program/data memory summary"
	@echo "Test (act on PIC_VARIANT=$(PIC_VARIANT) unless noted):"
	@echo "  test            FULL validation suite for the selected variant"
	@echo "  test-variants   run \`make test\` for ALL variants ($(PIC_VARIANTS_ALL))"
	@echo "  test-config     verify the CONFIG word emitted into the built HEX"
	@echo "  test-gpsim      register-level functional test of the HEX in gpsim"
	@echo "  test-host       reference-model algorithm tests (host, variant-agnostic)"
	@echo "  test-model-check exhaustive state-space proof of invariants"
	@echo "  test-symbolic   exhaustive single-step property proof of step()"
	@echo "  test-symbolic-klee  same properties under KLEE (if installed)"
	@echo "  test-cbmc       CBMC SAT/SMT proof of the vendored model (if installed)"
	@echo "  test-formal     model-check + symbolic + cbmc"
	@echo "  test-equiv      prove the real firmware == model, tick-for-tick"
	@echo "  test-actuation  verify per-variant control pins (RA1/RA2): settled pattern every"
	@echo "                  tick (all variants), plus mute/relay mid-actuation transient + width"
	@echo "  test-fault      corrupt state/SFRs, verify the WDT-reset defensive path"
	@echo "  test-soak       libgpsim soak: WDT liveness + responsiveness (standalone;"
	@echo "                  needs gpsim-dev+libglib2.0-dev; PIC_VARIANT, PIC_SOAK_DURATION_MS)"
	@echo "  test-mutation   inject firmware/model faults, verify the suite kills them"
	@echo "Analysis:"
	@echo "  analyze         cppcheck bug-finding + MISRA-C:2012 (static analysis)"
	@echo "  analyze-cppcheck / analyze-misra  individual analysis passes"
	@echo "  coverage        human-readable reference-model coverage report"
	@echo "  coverage-check  fail if model coverage < COVERAGE_MIN ($(COVERAGE_MIN)%)"
	@echo "  coverage-check-fw  fail unless every shipping firmware line is exercised"
	@echo "Release:"
	@echo "  release         VERSION=vX.Y.Z: build+validate (incl. soak) + stage release/<ver>/"
	@echo "                  (RELEASE_ARGS='--dry-run' shortens the soak; see scripts/make-release.sh)"
	@echo "Clean:"
	@echo "  clean           remove build + coverage artifacts"
	@echo "  coverage-clean  remove only coverage artifacts"
	@echo "Overrides: PIC_VARIANT=, PIC_CC=, PIC_DFP=, COVERAGE_MIN=, BUILD_DIR=,"
	@echo "           PIC_SOAK_DURATION_MS=, HOST_CC=, CPPCHECK=, GPSIM="
