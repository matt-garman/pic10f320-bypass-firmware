# Prebuilt firmware images

This directory holds **prebuilt, ready-to-flash PIC10F320 firmware images** so you
can use this firmware without installing the XC8 cross-compiler or building
anything. Each release lives in its own `vX.Y.Z/` subdirectory and is also
published as a [GitHub Release](../../releases).

If you would rather build from source, ignore this directory and see the
top-level [README](../README.md) and [TOOLCHAIN.adoc](../TOOLCHAIN.adoc).

## Why you can trust these binaries

The same philosophy that backs the source — a layered, multi-engine test and
validation suite — backs these binaries, through two mechanisms:

1. **Provenance.** Every release carries a `MANIFEST.md` recording the exact
   source commit, the pinned toolchain versions, the per-image flash usage /
   CONFIG word, and the validation evidence: `make test-variants` (the full
   per-variant gate — static analysis + the reference-model host/formal suite +
   the firmware↔model equivalence trace + the fault-injection harness +
   CONFIG-word + gpsim functional + coverage), `make test-mutation` (inject
   firmware/model faults and confirm the suite kills them), and a **24-hour
   libgpsim soak of every output variant** — 24 h of *simulated* MCU operation
   per variant (gpsim runs the core faster than real time, so the wall-clock
   cost is correspondingly shorter); logs under `evidence/`.

2. **Reproducibility.** The Intel-HEX images are byte-deterministic for a fixed
   toolchain — XC8's ihex output contains only the program's code/config bytes,
   with no embedded timestamps or build paths. `SHA256SUMS` pins those bytes.
   When the release tag is pushed, CI
   ([`.github/workflows/release.yml`](../.github/workflows/release.yml)) rebuilds
   the images from the tagged source on a clean runner and **fails the release
   unless they reproduce these exact hashes**. That check is the public
   attestation that *these binaries are exactly what the tested source compiles
   to* — you do not have to take the maintainer's word for it, and you can run
   the same check yourself (see "Reproduce" below).

`SHA256SUMS` is also signed (`SHA256SUMS.asc`), and the release tag is a signed
git tag, so you can additionally verify the maintainer vouched for the bytes.

## Which image do I want?

Images are named `bypass_mcu_<variant>_pic10f320.hex`. There are **five**: the
three output stages below, with each analog-switch stage built in two control-pin
drive polarities — an inverting **CD4053** (driven through a MOSFET inverter, as
used for a 9–18 V switch rail) and a direct-drive **TMUX4053** (driven at logic
level):

| variant           | switching hardware                                          |
|-------------------|-------------------------------------------------------------|
| `cd4053-simple`   | CD4053 analog switch, simple — 2 sections (inverting drive) |
| `tmux4053-simple` | TMUX4053 analog switch, simple — 2 sections (direct drive)  |
| `cd4053-mute`     | CD4053 with mute-before-switch — 3 sections (inverting)     |
| `tmux4053-mute`   | TMUX4053 with mute-before-switch — 3 sections (direct)      |
| `tq2-relay`       | Panasonic TQ2-L2-5V latching relay                          |

The `cd4053-*` and `tmux4053-*` images differ only in control-pin drive polarity:
pick **CD4053** when the analog switch is driven through a MOSFET inverter, or
**TMUX4053** when it is driven directly at logic level. All five target the
**PIC10F320** at 16 MHz (INTOSC). The per-release `MANIFEST.md` lists every image
with its flash-word usage and exact flashing command.

## Verify a download

```sh
cd release/vX.Y.Z

# (recommended) verify the maintainer's signature over the checksums
gpg --verify SHA256SUMS.asc SHA256SUMS

# verify the image bytes
sha256sum -c SHA256SUMS
```

## Flash a chip

The PIC10F320 CONFIG word is embedded in the HEX, so writing the HEX configures
the device — there is no separate fuse step. With a PICkit and `pk2cmd`:

```sh
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-simple_pic10f320.hex -M -Y -R   # PICkit 2
```

(or use MPLAB X / `ipecmd` with a PICkit 3/4/5).

## Reproduce the images bit-for-bit

```sh
git checkout vX.Y.Z
# install the pinned toolchain (see TOOLCHAIN.adoc), then build every variant:
make clean
make all PIC_VARIANT=cd4053-simple
make all PIC_VARIANT=tmux4053-simple
make all PIC_VARIANT=cd4053-mute
make all PIC_VARIANT=tmux4053-mute
make all PIC_VARIANT=tq2-relay
sha256sum -c release/vX.Y.Z/SHA256SUMS
```

A matching `sha256sum -c` proves your locally built images are identical to the
published ones. (Byte-exact reproduction requires the *same* XC8 **and** DFP
versions recorded in the manifest; a different toolchain may produce functionally
identical but not byte-identical images.)
