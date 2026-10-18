# TerraTec PHASE 88 Linux Driver Investigation — Agent Handoff

## Mission

Diagnose and, if feasible, fix Linux support for a **TerraTec PHASE 88 PCI audio card** based on the VIA/ICE1712 (Envy24) controller. Work incrementally on this machine, using the Linux kernel source and the original Windows and OS/9 driver code available locally as behavioral references.

The immediate goal is to understand why the in-tree `snd_ice1712` driver fails during card initialization. Do not assume the AK4524 codec itself is defective: the current failure appears to occur earlier, during an I²C transaction to a GPIO-connected I/O expander.

## Working environment

- OS: Debian GNU/Linux 13 (trixie), version reported as 13.7.
- Kernel source tree: `/root/terratec/kernel/linux-6.18.55`
- Running kernel was verified as: `6.18.55`
- PCI device: `03:02.0`
- PCI ID: `1412:1712`, revision 02 — VIA ICE1712 / Envy24.
- `lspci -vv -s 03:02.0` identifies the subsystem by name as **TERRATEC Electronic GmbH PHASE88**.
- Kernel module: `snd_ice1712`, built for/running on kernel 6.18.55.
- The module can be unloaded and reloaded without rebooting; this has already been tested.
- The card is detected on PCI, but it does not currently appear as a usable ALSA sound card.
- Available reference material: a decompressed/decompiled OS/9 `.pax` driver and decompilable Windows 2000/XP/Vista driver DLLs. Locate and inspect these local files; do not assume their paths until discovered.

## Confirmed baseline

Commands and observations:

```text
uname -r
6.18.55
```

```text
lspci -nn -s 03:02.0
03:02.0 Multimedia audio controller [0401]: VIA Technologies Inc. ICE1712 [Envy24] PCI Multi-Channel I/O Controller [1412:1712] (rev 02)
```

`lspci -vv -s 03:02.0` reports:

```text
Subsystem: TERRATEC Electronic GmbH PHASE88
Kernel driver in use: snd_ice1712
Kernel modules: snd_ice1712
```

The relevant kernel log is:

```text
snd_ice1712 0000:03:02.0: AK4524 chip select failed, check cable to the front module
snd_ice1712 0000:03:02.0: probe with driver snd_ice1712 failed with error -5
```

`aplay -l` only showed the AMD HDMI audio device, and `arecord -l` was empty. `lsmod` showed `snd_ice1712` and related modules, including `snd_i2c`, `snd_ak4xxx_adda`, `snd_ice17xx_ak4xxx`, and `snd_cs8427`.

## Relevant source findings

Primary files:

- `sound/pci/ice1712/ews.c`
- `sound/pci/ice1712/ews.h`
- `sound/pci/ice1712/ak4xxx.c`

Searches found `phase88` in `ews.c`; the board table includes a Phase88 entry with `.name = "TerraTec Phase88"`, `.model = "phase88"`, and `.chip_init = snd_ice1712_ews_init`.

In `snd_ice1712_ews_init()`:

- The `ICE1712_SUBDEVICE_PHASE88` case configures eight DACs and eight ADCs.
- It creates a bit-banged I²C bus named `ICE1712 GPIO 1`, using `snd_ice1712_ewx_cs8427_bit_ops`.
- For the Phase88 path, it creates I²C devices for:
  - `CS8404`
  - `PCF8574 (1st)` / input
  - `PCF8574 (2nd)` / output
- It then calls `snd_ice1712_ews88mt_chip_select(ice, 0x0f)` as an initialization/front-module check.
- The later AKM initialization is not reached if this check fails.

The function `snd_ice1712_ews88mt_chip_select()` uses `spec->i2cdevs[EWS_I2C_PCF2]`. It attempts an I²C read, then potentially a write. If the read or write does not transfer exactly one byte, it emits:

```text
AK4524 chip select failed, check cable to the front module
```

The source comment describes the PCF2 low nibble as the AK4524 chip-select bits (four codec selects). PCF2 is also used for output sensitivity control. Thus the present error points first to communication with the PCF8574 output expander, not necessarily to direct communication with the AK4524 codec.

Address definitions in `sound/pci/ice1712/ews.h`:

```c
#define ICE1712_EWS88MT_CS8404_ADDR  (0x40>>1)
#define ICE1712_EWS88MT_INPUT_ADDR   (0x46>>1)
#define ICE1712_EWS88MT_OUTPUT_ADDR  (0x48>>1)
```

These expressions evaluate to Linux I²C 7-bit addresses:

| Device | Expression | Value |
|---|---:|---:|
| CS8404 | `0x40 >> 1` | `0x20` |
| PCF8574 input | `0x46 >> 1` | `0x23` |
| PCF8574 output / `EWS_I2C_PCF2` | `0x48 >> 1` | `0x24` |

Treat these as the current Linux source configuration, **not yet as independently verified physical addresses**. Compare them with the proprietary driver implementations and determine whether those drivers represent I²C addresses in 7-bit or 8-bit form before comparing constants.


## User's preliminary hardware reverse-engineering notes — UNCONFIRMED

The user performed a preliminary analysis of the physical codec-control wiring before this investigation. These observations are useful leads, but **the cable tracing and inferred circuit topology are not guaranteed to be 100% correct**. Treat them as hypotheses to verify against PCB markings/photos, continuity measurements, and the original Windows/OS/9 drivers. Do not implement them as established facts.

### Preliminary proposed topology

The user suspects that the PHASE 88 Producer may differ from the standard EWS88MT wiring and that codec chip-select signals may pass through circuitry resembling:

```text
ICE1712 / driver-controlled signals
        |
        v
74AHCT594 serial shift register
        |
        v
PCA9554-like GPIO/output stage (actual PCA9554 presence is uncertain)
        |
        v
74HC157 multiplexer
        |
        v
AK4524 chip-select inputs
```

The exact ordering, electrical connections, and functional role of these components have not yet been conclusively established.

### Preliminary observations from the user

- The user traced a signal described as SDA from the logical “PCA9554” block to DS on a 74AHCT594.
- The signal described as SCL appears to connect to SRCLK.
- RCLK (latch clock) appeared permanently high or may be handled differently than expected; this observation is also unconfirmed.
- The user suspects that the board may not contain a physical PCA9554 despite the signals resembling a PCA9554-controlled interface.
- The original Windows driver appears to initialize the card successfully, according to the user's experience.
- These observations led to the hypothesis that Linux may be using an incorrect GPIO sequence, shift-register update, latch sequence, chip-select routing/polarity, or initialization order.

### How to use these notes

1. Keep this physical-wiring hypothesis separate from facts established by the Linux source.
2. Do not assume the Linux error proves the AK4524 is defective or that the proposed shift-register topology is correct.
3. The currently established Linux failure occurs in `snd_ice1712_ews88mt_chip_select()` while attempting an I²C read/write through the device registered as `EWS_I2C_PCF2` at the configured 7-bit address `0x24`. This happens during initialization before the later AKM codec initialization.
4. Therefore, first reconcile the observed board wiring with the actual Linux bit-banged I²C implementation and with the proprietary drivers. In particular, determine whether the Linux PCF8574 abstraction/address corresponds to a real device, a compatible logical interface, or an incorrect assumption for this board revision.
5. Do not directly replace the standard EWS88MT mechanism with the proposed shift-register sequence until the original driver behavior or further measurements support that change.

The desired end result remains a correct, minimal, evidence-backed driver fix—not suppressing the error. Preserve compatibility with existing EWS88MT hardware, and explain any board-specific dispatch or compatibility strategy before coding.

## Current diagnostic hypothesis

The first failure to investigate is the I²C transaction to the output expander configured at address `0x24` (from `0x48 >> 1`). Possible explanations remain open, including address/protocol mismatch, I²C GPIO timing or line handling, hardware/connection/power issues, or a board-revision difference. No cause has been established yet.

Do not jump to changing AK4524 serial protocol, chip-select GPIO bits, or `phase.c`. Keep the investigation focused on the confirmed Phase88 dispatch path in `ews.c` until evidence indicates otherwise.

## Immediate next steps

1. **Preserve the baseline before editing.**
   - Check `git status`, whether the source tree is already a Git repository, and whether there are existing local modifications.
   - Do not overwrite or discard any existing changes.
   - If no repository/baseline exists, create a safe version-control baseline or make a clearly named backup before editing.

2. **Record numeric PCI subsystem IDs** (the textual subsystem name is already confirmed):
   ```bash
   cat /sys/bus/pci/devices/0000:03:02.0/subsystem_vendor
   cat /sys/bus/pci/devices/0000:03:02.0/subsystem_device
   ```
   Compare the result with the Phase88 subsystem constant in `ews.h`; do not assume they match without checking.

3. **Inspect the I²C bit-banging implementation** in `ews.c`, including `snd_ice1712_ewx_cs8427_bit_ops` and its read/write/clock/data handling. Follow the code far enough to understand how the ICE1712 GPIO lines implement START, STOP, ACK, and byte transfers.

4. **Use the Windows and OS/9 driver sources as independent evidence.**
   - Locate the available decompiled files.
   - Search for the Phase88 initialization path, ICE1712 GPIO/I²C operations, PCF8574, CS8404, and address constants.
   - Compare behavior and address representation, not just raw hexadecimal literals.
   - Keep source-derived facts separate from hypotheses.

5. **If static analysis does not resolve it, add minimal diagnostic logging only.**
   - Log the I²C device address and the return value from the failing read/write operation.
   - Prefer instrumentation that does not alter bus transactions or GPIO values.
   - Rebuild/reload and capture `dmesg` after each experiment.
   - Do not begin by changing hardware behavior.

6. After the cause is supported by evidence, propose one minimal change, explain the expected result, and test it in isolation.

## Build/test constraints and safety rules

- Do not reboot, change GRUB, install a new kernel, or run shutdown commands as part of experiments unless the user explicitly approves.
- The goal is iterative **module-only** work while running kernel 6.18.55. Verify the correct module build/install/reload procedure for this source tree before using it; do not assume a build artifact path or compression format.
- Before each test, save the diff and record the hypothesis.
- After each test, record build output, module load/probe result, relevant `dmesg`, and ALSA enumeration.
- Do not use `git clean`, reset, or destructive cleanup commands without explicit approval.
- Do not run blind I²C scans or arbitrary GPIO/I²C writes. Any experiment that changes hardware state must have a clear rationale and a reversible plan.
- Do not claim that the hardware is defective based only on the current log.
- Keep each step small. Ask the user for confirmation before risky actions or broad changes.

## Communication style

Work in short, evidence-based iterations. First report what the evidence establishes, then list the next small command set. Do not repeat investigations already completed. Do not edit the driver until the baseline and relevant code paths are understood.
