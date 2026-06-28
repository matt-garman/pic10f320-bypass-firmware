# Makefile -- PIC10F320 bypass firmware (single-file, CD4053-simple only)
#
# Minimal build to answer one question: does the firmware fit in the
# PIC10F320's flash?  The PIC10F320 has 256 words of program memory and 64
# bytes of RAM -- HALF the flash of the PIC10F322 the parent project targets.
# Fitting in 256 words is the whole point of this scaled-down project, so the
# default build compiles the firmware and then checks the program-word count
# against that budget.
#
# Targets:
#   make            build the .hex and report flash usage vs. the 256-word budget
#   make size       build (if needed) and print XC8's memory-usage summary
#   make clean      remove the build directory
#
# Toolchain: Microchip XC8 v3.10 + the PIC10-12Fxxx DFP. Override any of the
# PIC_* variables on the command line if your install paths differ, e.g.:
#   make PIC_CC=/path/to/xc8-cc PIC_DFP=/path/to/DFP/x.y.z/xc8

# --- toolchain + device ------------------------------------------------------
PIC_CC          ?= /opt/microchip/xc8/v3.10/bin/xc8-cc
PIC_DFP         ?= /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
PIC_CHIP        ?= 10F320
PIC_TAG         ?= pic10f320
PIC_XTAL        ?= 16000000UL

# PIC10F320 device budget: 256 words flash / 64 B RAM.
PIC_FLASH_WORDS ?= 256

# --- sources + outputs -------------------------------------------------------
SRC             := bypass_mcu_pic10f320.c
FW_BASE         := bypass_mcu
BUILD_DIR       ?= build_pic
HEX             := $(BUILD_DIR)/$(FW_BASE)_$(PIC_TAG).hex

# XC8 compile flags: select the PIC10F320 + its DFP, C99 (XC8 has no C11, so
# static_assert is aliased to _Static_assert in the source), -O2, and
# _XTAL_FREQ for __delay_ms / the 16 MHz HFINTOSC compile-time assert.
PIC_CFLAGS      := -mcpu=$(PIC_CHIP) -mdfp=$(PIC_DFP) -std=c99 -O2 \
                   -D_XTAL_FREQ=$(PIC_XTAL)

.PHONY: all size clean

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
	@echo "=== PIC10F320 build + flash-budget ($(PIC_FLASH_WORDS) words) ==="
	@out=`cd $(BUILD_DIR) && $(PIC_CC) $(PIC_CFLAGS) $(CURDIR)/$(SRC) \
		-o $(FW_BASE)_$(PIC_TAG).hex 2>&1` \
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
		-o $(FW_BASE)_$(PIC_TAG).hex 2>&1 | grep -iE 'space|memory summary' || true

clean:
	rm -rf $(BUILD_DIR)
