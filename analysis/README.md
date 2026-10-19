# PHASE 88 (PCI, 1412:1712, subsys 153b:1151) — investigation log

## Environment
- Running kernel 6.18.55, tree `/root/terratec/kernel/linux-6.18.55` (git baseline
  `941c14e58`, working branch `phase88`).
- Card: `0000:03:02.0`, `1412:1712` rev 02, subsystem `0x153b:0x1151`
  (= `ICE1712_SUBDEVICE_PHASE88` 0x3b155111 in `ews.h`, so the Linux Phase88
  dispatch in `ews.c` is confirmed to be the code path taken).
- Baseline failure: `AK4524 chip select failed, check cable to the front module`
  → `probe ... failed with error -5`.

## Evidence from the original Windows driver (ews88wdm.sys v5.51.3.142, PE32)

Disassembly: `/root/terratec/analysis/ews32.dis` (objdump, intel syntax).

I/O primitives: the driver uses the ICE1712 *indirect* register access exactly
like Linux — `WRITE_PORT_UCHAR(bar0+3 /*INDEX*/, n)` /
`READ|WRITE_PORT_UCHAR(bar0+4 /*DATA*/, v)`. Confirms `bar0` == Linux `ice->port`
and registers 0x20/0x21/0x22 = GPIO_DATA / GPIO_WRITE_MASK / GPIO_DIRECTION.

Bit-banging primitives:
- `0x1b916(io, sda, scl, delay)` = setlines: DIRECTION |= 0x30, WRITE_MASK &= 0xcf,
  then GPIO_DATA = (sda?0x10) + (scl?0x20) `delay` times.
- `0x1b99e(io, delay)` = read one bit: WRITE_MASK = 0xf7, GPIO_DATA = 0,
  DIRECTION = (DIRECTION & ~0x10) | 0x20  (SDA in, SCL out), read GPIO_DATA & 0x10.
- `0x1b514/0x1b548` = start/stop, `0x1b57c` = write byte + ACK check,
  `0x1b67e` = read byte, `0x1b728(a,b,io,addr,delay)` = **probe**: start + address(W)
  + stop, up to 5 retries.
- `0x1b82a(a,b,io,addr,buf,count,delay)` = write `count` bytes to `addr`.

Card type detection, `0x18010`:
```
if (probe(8bit 0x44)) type = 4;
else if (probe(8bit 0x48)) type = 1;
else if (probe(8bit 0x42)) type = 8;
else type = 4;
```

AK4524 chip select, `0x16630(dev, assert_mask /*0..0xf*/)`:
- subsystem 0x1130 (EWX 24/96): chip select directly on GPIO bit 0x01.
- subsystem 0x1138 (DMX 6Fire): chip select directly on GPIO bits 0x00..0x02.
- type 1 (EWS88MT family): **write 1 byte to 8-bit 0x48**,
  value = (~assert_mask & 0x0f) | (out_sense ? 0x40 : 0).
- type 8: **write 2 bytes to 8-bit 0x42**: `{0x01, (~assert_mask & 0x0f) |
  (flag185 ? 0x10 : 0) | (flag184 ? 0x20 : 0)}`.

**The chip select byte is always composed from driver-side shadow state; the
Windows driver never reads the chip-select expander over I2C.**

PHASE 88 dispatch, `0x185f4` (and the equivalent path at `0x18c8c`):
```
if (subsystem == 0x1151 || subsystem == 0xf151)   /* PHASE 88 / PHASE 88 (M) */
    if (type == 8) { flag184 = 1; apply_flags(); } /* -> {0x01,0x20} to 8-bit 0x42 */
```
i.e. the original driver *expects* a PHASE 88 to be a "type 8" board whose
chip-select expander answers at 8-bit 0x42 (7-bit 0x21), with bit 0x20 of the
data byte permanently asserted.

Input sensitivity (`0x17b2a`): for 0x1115/0x1125/0x1151/0xf151 it writes the
8-bit 0x46 expander — **but returns immediately without doing anything when
type == 8**. Consistent with the Phase88 having no 0x46 device.

## Hardware probe (measured, non-destructive)

`diag=1` instrumentation in `ews.c`: reads GPIO registers and runs
`snd_i2c_probeaddr()` (= START + address(W) + STOP, no data phase, exactly what
the Windows driver's `0x18010` does) plus one read byte from every device that
ACKed. Log `/root/terratec/logs/20261012-141355.log`:

```
diag: GPIO data=f8 wmask=c7 dir=38 (eeprom mask=c7 state=38 dir=38)
diag: addr 7bit 0x10 (8bit 0x20): NACK
diag: addr 7bit 0x20 (8bit 0x40): ACK      <- CS8404, matches Linux
diag:   readbyte 7bit 0x20 -> 1 (0xff)
diag: addr 7bit 0x21 (8bit 0x42): ACK      <- Windows "type 8" chip select expander
diag:   readbyte 7bit 0x21 -> 1 (0xff)
diag: addr 7bit 0x22 (8bit 0x44): NACK
diag: addr 7bit 0x23 (8bit 0x46): NACK     <- EWS88MT input expander absent
diag: addr 0x24 (8bit 0x48): NACK          <- EWS88MT output expander absent
diag: addr 7bit 0x25 (8bit 0x4a): NACK
diag: addr 7bit 0x27 (8bit 0x4e): NACK
AK4524 chip select failed ... (addr 0x24, err -5)
```

## Conclusion

The Linux failure is an **address/board-model mismatch, not a broken bus and not a
defective codec/front module**:

- The bit-banged I2C bus works (0x40 and 0x42 ACK, reads complete).
- The PHASE 88 does *not* carry the EWS88MT pair of PCF8574 expanders at 0x23/0x24.
- Its chip-select/output expander is at 7-bit **0x21** (8-bit 0x42) and is
  addressed with a **two byte** transfer `{0x01, flags|cs_nibble}` — exactly the
  "type 8" path of the Windows driver, which is the path the Windows driver
  selects for subsystem 0x1151 (PHASE 88).
- `snd_ice1712_ews88mt_chip_select()` therefore reads/writes a non-existent
  device at 0x24, gets a NACK on the address byte (`snd_i2c_readbytes()` -> -EIO)
  and aborts the whole probe.

## Fix (board dispatched, EWS88MT untouched)

1. `ews.h`: add `ICE1712_PHASE88_OUTPUT_ADDR (0x42>>1)` and the byte-0 selector
   `ICE1712_PHASE88_OUTPUT_PAGE 0x01`, plus the power-on flag byte
   `ICE1712_PHASE88_OUTPUT_INIT 0x20`.
2. `ews.c`: `snd_ice1712_phase88_chip_select()` composes `{0x01, shadow|nibble}`
   from a driver-side shadow (write-only, like Windows);
   `snd_ice1712_ews88mt_chip_select()` dispatches to it for
   `ICE1712_SUBDEVICE_PHASE88`.
3. `ews_init()`: for PHASE 88 create only CS8404 (0x20) and the output expander
   (0x21); the 0x23/0x24 devices are not created.
4. `ews_add_controls()`: do not add the "Input/Output Sensitivity Switch"
   controls for PHASE 88 (their 0x46/0x24 backends do not exist on this board;
   the Windows driver no-ops the input sense for type 8 as well).

## Second symptom: the phantom consumer AC'97 codec

After the chip-select fix the card probes and registers:

```
snd_ice1712 0000:03:02.0: card 3: TerraTec Phase88 at 0xdc00, irq 23
```

but the probe also spends ~2 s in an AC'97 reset and then reports:

```
Consumer PCM code does not work well at the moment --jk
AC'97 0 does not respond - RESET
AC'97 0 access is not valid [0xffffffff], removing mixer.
cannot initialize ac97 for consumer, skipped
```

The EEPROM CODEC byte (offset 06) is `0x0f`: four ADCs + four DACs and
**bit 4 clear**, i.e. "a consumer AC'97 codec is present".  Measured on this
board the AC-Link never answers - register 0x00 reads 0xffff even after a
cold reset (`socket`/`cold_reset` in the driver), and the Terratec Windows
driver never touches the AC-Link of a PHASE 88 either: every converter on
the board (4x AK4524) hangs off the multi-track I2S interface, which is what
`ACLink = 0x80` (`ICE1712_CFG_PRO_I2S`) selects.

This is exactly the situation of the DMX 6Fire, which is handled the same way
a few lines above in `snd_ice1712_chip_init()`.  The quirk sets
`ICE1712_CFG_NO_CON_AC97` in the CODEC byte before it is written to PCI
config 0x60, so the consumer AC-Link stays in reset, the consumer IRQs stay
masked, and no consumer/DS PCM or AC'97 mixer is created.  The PHASE 88 keeps
its single 10 out / 12 in `ICE1712 multi` device (that is what the Windows
driver exposes as well).

Consequence found while auditing this path: `snd_ice1712_capture_open()` and
`snd_ice1712_capture_prepare()` dereference `ice->ac97` unconditionally.  A
card whose AC'97 mixer creation *fails* (which is what happened here before
the quirk) therefore oopses on `open()` of the consumer capture stream
(`ice->ac97 == NULL`).  A `!ice->ac97 -> -ENODEV` guard was added; the same
bug is reachable on every ICE1712 board with a dead/disaudio AC'97 codec.

## Incident: the sound core got wedged (do not repeat)

While testing, an `open()` of the consumer capture stream oopsed (the NULL
dereference above).  Because `snd_pcm_open()` holds the sound-core global
`register_mutex` across `ops->open`, the oops left that mutex held forever:

- `aplay -l` (PID 637446) has been stuck in `D` inside
  `snd_pcm_control_ioctl+0x19c` (takes `register_mutex`) since then and is
  unreapable; it holds `/dev/snd/controlC3` and therefore a module reference.
- reads of `/proc/asound/card*/pcm*/sub0/status` stuck in `D` as well
  (wireplumber).
- `rmmod snd_ice1712` fails with "Module is in use" and would block forever
  if forced, because `snd_card_free()` waits for that file to be released -
  so **never** use `rmmod -f` here.
- `amixer`, `/proc/asound/cards` and `/proc/asound/card3/*` still work, which
  is a good quick test whether the core is wedged.

Both helper scripts now wrap every ALSA call in `timeout(1)` for this reason.
**Module reload - and therefore any further on-hardware testing - requires a
reboot.**

## Verification on hardware (after the reboot of 2026-10-14)

`scripts/phase88-cycle.sh` + `scripts/phase88-verify.sh` -> **all checks pass**
(`/root/terratec/logs/verify-20261014-094145.log`).

- probe clean: `card 2: TerraTec Phase88 at 0xdc00, irq 23`, no
  `chip select failed`, no AC'97 messages, no oops.
- `/proc/asound/card2/ice1712` shows `Codec: 0x1f` (the NO_CON_AC97 quirk is
  applied) and `ACLink: 0x80` (PRO_I2S) - the consumer AC-Link stays in reset.
- exactly one PCM, playback *and* capture on device 0 `ICE1712 multi`
  (10 out / 12 in), no consumer and no consumer (DS) devices.
- 80 mixer controls, no EWS88MT "Sensitivity Switch".
- playback reaches `RUNNING` at 44100/48000/96000 with 10 ch S32_LE and the
  DMA pointer advances, no xruns.
- capture reaches `RUNNING` with 12 ch and the DMA pointer advances.
- all four AK4524 answer on the control interface and their register shadow
  matches `inits_ak4524[]` exactly (`R0=0x07 R1=0x03 R2=0x60 R3=0x19`), and
  mixer writes land in the codec (`/proc/asound/card2/ak4524` changes after
  `amixer cset`) - so the new two-byte chip-select write works for all four
  codecs, not only for the probe.

### Practical mixer facts (measured, useful for anyone using the card)

- The driver starts every ICE1712 muted; nothing is audible until these are
  raised: `Multi Playback Switch` (monitor mixer, one per output pair),
  `Multi Playback Volume` (**96 = unity**, below that it attenuates, 127 =
  mute), `DAC Volume` (**127 = 0 dB**, 0 = mute), and for record
  `H/W Multi Capture Switch` / `H/W Multi Capture Volume` (96 = unity) and
  `ADC Volume` (127 = 0 dB).
- Capture channel layout of the "multi" device: 1..8 = the eight AK4524 ADCs,
  9..10 = AC'97 capture (silent, there is no codec), 11..12 = the ICE1712
  digital **monitor mix**. Measured with `scripts/phase88-loopback.sh`: with a
  sine on any single playback channel, channels 11 and 12 carry that sine at
  the monitor-mixer level - a built-in digital loopback that proves the whole
  Envy24 data path without any cable.

### Still open (needs the user / physical access)

- Analog in and out: channels 1..8 are exactly zero because nothing is
  connected. `scripts/phase88-loopback.sh` reports the level per input; with
  `Out 1 -> In 1` jumpered it must show the 1 kHz tone, and with speakers on
  outputs 1/2 the tone must be audible.
- S/PDIF: the EEPROM claims `S/PDIF: 0x3` (in and out present) and a CS8404
  transmitter answers on 7-bit 0x20, but nothing on the board was measured
  against a real digital cable. Someone with the bracket in front of them
  should say whether the card actually has digital connectors.
- MIDI: `/dev/midiC2D0` exists (MPU401), no loop test done.

## How to continue after a reboot

```
# 1. build + unload the distro module + load the patched one + dump everything
/root/terratec/scripts/phase88-cycle.sh

# 2. functional checks (PASS/FAIL + log in /root/terratec/logs)
/root/terratec/scripts/phase88-verify.sh
```

Optional - make the patched module the one that loads at boot (it overwrites
the packaged `snd-ice1712.ko.xz`, `CONFIG_MODULE_COMPRESS_XZ=y`):

```
make -C /root/terratec/kernel/linux-6.18.55 M=sound/pci/ice1712 modules_install
depmod -a $(uname -r)
```

Note: the lightdm greeter runs pipewire/wireplumber which keep
`/dev/snd/controlC*` open; `phase88-cycle.sh` kills them (they respawn) so
`rmmod` can succeed.  Never use `rmmod -f`.

## JACK verification (2026-10-14)

`jackd -dalsa -dhw:Phase88` (jackdmp 1.9.22) negotiates exactly what the card
offers - `/proc/asound/card2/pcm0{p,c}/sub0/hw_params`:

```
playback: MMAP_INTERLEAVED S32_LE 10 ch 48000 Hz period 1024 buffer 2048
capture : MMAP_INTERLEAVED S32_LE 12 ch 48000 Hz period 1024 buffer 2048
```

12 `system:capture_*` and 10 `system:playback_*` ports appear, no xruns.
End-to-end proof inside JACK: `jack_simple_client` (sine) -> `system:playback_1`
and `jack_rec` on `system:capture_11/12` recorded the sine back at
-9.6 dBFS. So playback, capture and the internal monitor loop all work through
JACK; inputs 1..8 only need an analog signal and the (still missing) Line/Mic
select, see below.

## Next work item: Line/Mic input select (front mic vs rear aux)

`driver/os9/Applications/Phase88 Control Panel.app` resource strings reveal the
feature set of the original mixer:

```
"Line/Mic 1/2"  "Line/Mic 3/4"  "Line/Mic 5/6"  "Line/Mic 7/8"   <- per input pair
"Gain Levels", "Mic 2/8 Settings", "Connected:   Mic2/8"
"DAC Output12 Sources", "DAC Output34 Sources", ...               <- already in Linux
"Clock Source", "Mic28SetSPDIFSrc/ADATSrc/EWSLinkSrc/LineOutSrc"
```
Symbols in the same binary: `SetInputLevelSwitch(h,i)`, `SetCodecInputVolume(h,l)`,
`GetSourceIdFromSourceIndex`, `Mic28Set*Src`.

So the PHASE 88 has a mic preamp / line-mic select per input pair (input pair
1/2 = rear aux *or* front microphone), which Linux does not expose. Plan:

1. find which hardware bit the switch drives. Candidates: the flag bits of the
   chip-select expander at 7-bit 0x21 (bit 0x10 = "flag185" in the WDM
   disassembly is not yet attributed; 0x20 is what the driver keeps asserted)
   or free ICE1712 GPIO bits. Route: trace the Windows ControlPanel
   (`driver/win/EWS88-ControlPanel-5.51b.exe`, path as of the 2026-10-19 cleanup)
   ioctl -> `ews88wdm.sys` handler already disassembled in `analysis/ews32.dis`.
2. implement it as real ALSA controls in `ews.c` (e.g. an enumerated
   "Input Source Select" per pair, or "Line/Mic n Switch"), *not* as a separate
   user-space app: a control is visible in alsamixer/pavucontrol/QJackCtl, can
   be saved with alsactl and cannot race with the driver's own expander writes
   (the shadow byte in `struct ews_spec` is the single owner of that register).

## Boot setup on this machine (as of 2026-10-14)

- patched module installed as `/lib/modules/6.18.55/updates/snd-ice1712.ko`
  (`depmod -a` run; `modprobe --show-depends snd_ice1712` resolves to
  `updates/`, so udev loads the patched build at boot; the packaged
  `kernel/sound/pci/ice1712/snd-ice1712.ko.xz` is untouched but shadowed).
- `/etc/systemd/system/phase88-audio.service` (enabled): `modprobe snd_ice1712`
  + `/root/terratec/scripts/phase88-mixer.sh`, which unmutes the monitor mixer
  and sets the AK4524 to 0 dB (the driver starts muted). `systemctl disable
  phase88-audio.service` hands the mixer back to `alsactl`/the desktop.
- `phase88-verify-boot.service` was removed (it killed pipewire at boot).
- After a kernel rebuild/reinstall the module has to be installed into the new
  `/lib/modules/<kver>/updates/` again (`make modules_install` equivalent:
  `install -D -m 0644 sound/pci/ice1712/snd-ice1712.ko
  /lib/modules/$(uname -r)/updates/ && depmod -a`).

### Line/Mic reverse engineering (in progress, 2026-10-14)

`ews88wdm.sys` contains the mixer node names as UTF-16 strings:

```
"Codec input level"  "Mic InputSel"  "Codec input switches"  "Clock Source"
"Source for Digital Out"  "Source for Record"  "Source for 3/4"  "Source for 5/6"
"LineOut12" "LineOut34" "LineOut56" "LineOut78"  "MIC28"  "EWS HD Config\MIC28"
```

Device-extension fields (from `analysis/ews32.dis`):
- `[dev+0x180]` = board type (4 / 1 / 8), detected at `0x18010` by probing 0x44, 0x48, 0x42.
- `[dev+0x184]` -> expander byte bit **0x20**; set to 1 by the PHASE 88 / PHASE 88(M)
  code paths at `0x18610` and `0x18cc5` (this is our `ICE1712_PHASE88_OUTPUT_INIT`).
- `[dev+0x185]` -> expander byte bit **0x10**; *only* written by the mixer property
  dispatch (cases at `0x19000`/`0x1901f`, setter at `0x19dc9`) -> user switchable,
  prime candidate for the mic/line (or mic preamp) switch.
- Only three write sites exist for the 0x42 device:
  * `0x16730` (from the chip select routine `0x16630`): `{0x01, flags|~mask&0x0f}`
  * `0x17a5d` (`apply_flags`): `{0x01, flags}` - flags only, no CS nibble
  * `0x16add` (init, only when `type == 8`): **`{0x03, 0x00}`** - a second,
    never-otherwise-touched 8-bit register that is initialised to 0 on type 8
    boards. Second candidate for the 4x Line/Mic + gain field (the Mac panel
    has 4 Line/Mic switches + "Gain Levels", which do not fit into one flag bit).
- The AK4524 itself has no mic preamp (registers 0-7 are power/format/DZF/attenuation
  only); `0x16872` -> `0x16738(dev, reg 4/5, ...)` writes are the *ADC attenuation*
  = "Codec input level" of the mixer, not a source switch.
- The "ControlPanel 5.51b.exe" in `driver/` is only a self-extracting installer
  stub (no mixer strings); everything needed is already in `ews88wdm.sys`.

Next: map the KsProperty table entries (node id -> handler -> the two cases above)
to the UTF-16 names to learn which of flag185 / register 0x03 is the Line/Mic
select, then implement one enumerated ALSA control per input pair.

---

## 2026-10-15 — analog inputs fixed (register 0x03) and Line/Mic switches

### Answer to the open question above
The candidate wins: **register page 0x03 of the 0x42 expander** is the field the
Terratec mixer drives, and `{0x03, 0x00}` at init is *required* for capture at all.
`[dev+0x185]`/flag bit 0x10 of page 0x01 is not it (no measurable audio effect).

### Root cause of "all inputs silent"
The page 0x03 latch of the expander is undefined after power on.  Left alone, the
four AK4524 keep their serial transmit drivers disabled: `arecord` returned exact
zeros on capture 1..8 although the codecs were programmed, unmuted and running
(R0=0x07 R1=0x03 R2=0x60 R3=0x19 read back OK).  Writing page 0x03 = 0x00 during
`snd_ice1712_ews_init()` - before the codec init, exactly where the Windows driver
does it - made inputs 1, 2 and 7 produce signal immediately.
Commit: `eb9089386 ASoC: ice1712: initialise the second PHASE 88 expander register`.

### Measured semantics (peaks over the trailing 1.4 s of a 2 s capture)
| write | effect |
|---|---|
| page 0x03 = 0x00 | baseline: mic pair audible (ch7 -74 dBFS with the mic unamplified) |
| page 0x03 = 0x10 | mic pair +28 dB: ch7 -74 -> **-29.7**, ch8 -71 -> **-32.7** |
| page 0x03 = 0x01/0x02/0x04/0x08 | only the switch click (~-44 dBFS), no steady change |
| page 0x01 bit 0x20 cleared (0x00/0x10/0x40/0x80) | AK4524 data path dies, capture stays -inf **permanently**, even after 0x20 is restored; needs a codec re-init |
| page 0x01 bits 0x10 / 0x40 / 0x80 | nothing measurable |

So: page 0x01 bit 0x20 = codec power/reset enable (the `OUTPUT_INIT` 0x20 is
load-bearing, do not "clean it up"), and page 0x03 bit 0x10 = mic gain of one input
pair.  Which of the remaining bits belongs to which pair could not be measured
(no source attached), so `f15b12d5a` assumes last pair first: pair 4 (in 7/8) = bit
0x10, pair 3 (5/6) = 0x20, pair 2 (3/4) = 0x40, pair 1 (1/2) = 0x80.  **Assumption,
needs one confirmation run with the user.**

### Locking lesson (cost a reboot)
The bit-banged I2C front end of the EWS boards takes `ice->gpio_mutex` itself inside
`ewx_i2c_start()`, and that mutex is not recursive.  Wrapping an expander write in
`snd_ice1712_save_gpio_status()/restore_gpio_status()` therefore deadlocks the
writer and then the whole control layer:

```
amixer  D  ewx_i2c_start+0x23/0x90 [snd_ice1712]
         snd_i2c_bit_start -> snd_i2c_bit_sendbytes
         snd_ice1712_phase88_write -> snd_ice1712_phase88_linemic_put
         snd_ctl_elem_write
wireplumber/amixer D snd_ctl_release+0x90/0x150 [snd]   (controls_rwsem behind it)
```

No recovery but a reboot (module refcount stays >0).  Rule now documented above
`snd_ice1712_phase88_write()`: never hold `ice->gpio_mutex` around the i2c layer;
serialise with `snd_i2c_lock()` only.  Same for `snd_akm4xxx_init()`, which handles
chip select and GPIO itself.

### Test-tool gotchas learned
* Register writes make a click that dominates any peak detector -> measure steady
  state only (skip the first 0.6 s), and keep the sources actually playing (the line
  source went silent mid-sweep and every channel fell to the -61 dBFS floor).
* The Envy24 pro stream refuses `S16_LE` ("Sample format non available"); use S32_LE.
* `pgrep -f pattern` inside `bash -c` matches the wrapper itself - use `[p]attern`.
* `qjackctl` segfaults (`segfault at 3`) when the jackd it owns is killed.

### Commits now on `phase88` (baseline 941c14e58)
```
ad0f14e94 ASoC: ice1712: fix PHASE 88 chip select expander address
0cfa29122 ASoC: ice1712: guard consumer capture against a missing AC'97 codec
8dc8649b3 ASoC: ice1712: PHASE 88 has no consumer AC'97 codec
eb9089386 ASoC: ice1712: initialise the second PHASE 88 expander register
f15b12d5a ASoC: ice1712: add the PHASE 88 Line/Mic input switches
c021a09f3 RFC/DO-NOT-SUBMIT: ASoC: ice1712: bring-up controls for the PHASE 88 expander
```
Submission set = first five, in `analysis/series/` (rebuilt from
`941c14e58..HEAD~1`), combined diff in `analysis/phase88-fix.patch`;
checkpatch clean apart from the missing `Signed-off-by:` on every commit.
The RFC commit adds three CARD-level byte controls (expander page 1, page 3, codec
re-init) and must be dropped before sending anything anywhere.

### Still open
1. Reboot (deadlock above) and re-run `scripts/phase88-cycle.sh`, `phase88-verify.sh`,
   `phase88-loopback.sh`, `phase88-jack-meter.sh --selftest`.
2. User to confirm: with the mic on input 7, `amixer cset name='Line/Mic 7/8 Switch' on`
   makes it ~+30 dB and the other three switches do nothing to it.  If a different
   pair lights up instead, fix the bit order in `snd_ice1712_phase88_linemic_ctls[]`.
3. User to confirm audible playback on outputs 1/2 (never yet confirmed by ear).

## 2026-10-16 — post-reboot verification (all green) + Line/Mic mapping measured

`phase88-postboot.service` (one-shot, masks itself after running; log
`logs/postboot-20261016-105619.log`) with the deadlock-free module:

* card up as **card 0** now (`hw:Phase88`, index is not fixed), OE taint, **no**
  `AK4524 chip select failed`, **no** AC'97 errors, **no** oops/trace.
* 87 controls (80 + 4 Line/Mic + 3 RFC debug), no EWS88MT sensitivity controls.
* playback RUNNING at 44100/48000/96000 (10 ch S32_LE), DMA advancing; capture
  RUNNING at 48000/12 ch with 3.45 MB of non-zero data in 2 s -> the page 0x03
  init still does its job after a cold boot.
* all four `Line/Mic x Switch` present and writable (the deadlock is gone: writes
  go through and return).
* JACK through the card: monitor loop sine = **-10.1 dBFS** on capture 11/12, analog
  inputs alive at -47..-74 dBFS (nothing playing, so that is noise/hiss).
* only failure: jackd started from a *system* unit dies with
  `Audio device hw:Phase88 cannot be acquired...` because it asks the session bus
  for device reservation (`Unable to autolaunch a dbus-daemon without a $DISPLAY`).
  Fixed in the script with `export JACK_NO_AUDIO_RESERVATION=1`; a QJackCtl session
  on the desktop is not affected.

### `scripts/phase88-linemic-probe.sh` - what each switch really does
Measures per-channel peaks with all switches off, then with each switch on
(2 s captures, first 0.6 s dropped because of the relay click, mic still on input 7,
nothing else connected):

| switch | ch1 | ch2 | ch3 | ch4 | ch5 | ch6 | ch7 | ch8 |
|---|---|---|---|---|---|---|---|---|
| Line/Mic 1/2 | +0.6 | -1.1 | +0.0 | -0.1 | +0.8 | -0.6 | +0.2 | +0.3 |
| Line/Mic 3/4 | +0.1 | -1.4 | -0.1 | -0.9 | +0.9 | -0.9 | +0.3 | +1.1 |
| Line/Mic 5/6 | -0.2 | -0.3 | -0.3 | -0.6 | +0.1 | +0.3 | -0.5 | +1.4 |
| **Line/Mic 7/8** | +0.1 | -1.2 | -1.9 | -3.5 | +0.6 | +0.5 | **+40.8** | **+30.3** |

So `f15b12d5a` behaves as intended for the pair the microphone is on, through the
ALSA control.  The other three bits cannot be pinned down from this table: a floating
input shows no level change when its preamp is engaged, so "bit belongs to pair N"
and "bit 0x10 is a global mic enable" are still both possible.  Decisive test: put
the microphone on **input 1** and repeat the probe - if `Line/Mic 1/2 Switch` lifts
ch1 by ~+35 dB the per-pair order in `snd_ice1712_phase88_linemic_ctls[]` is right;
if only `7/8` ever reacts, the control has to become a single global switch.

Script gotchas: Python 3.13 dropped `audioop` (PEP 594) - peaks are computed with
`array('i')` + strided max instead; and `reset_all()` must keep its loop variable
`local`, otherwise it clobbers the caller's `$s` and every row of the table is
measured with the last switch engaged (that is how the first run looked).

## 2026-10-16 — what the original Windows driver really switches (user: front XLR = ch 7/8, selectable front/back)

User (m00227): the mic XLR is on the **front** and serves channels **7/8**; the
Windows Control Mixer can enable 7/8 **on the front or on the back**.

### Extra page-0x03 bits do nothing (measured, mic on front 7/8)
`for v in 0x00 0x10 0x11 0x12 0x14 0x18 0x30 0x50 0x90` via the RFC debug control:
ch7 = -74 dBFS with 0x00 and -34..-36 dBFS with **every** value that has bit 0x10;
no value changes any other channel (ch8 wanders -45..-57, source-side).  So only
bit 0x10 is in play and bits 0x01/0x02/0x04/0x08/0x20/0x40/0x80 are not audio-path
selects we can see from here.

### Windows driver strings (`strings -el driver/win/ews88wdm.sys`; was `driver/windows2000_vista_xp/` before the 2026-10-19 cleanup)
```
MIC28   EWS HD Config\MIC28   Mic28ClkSource   Mic InputSel
Codec input level   Codec input switches
Source for 3/4   Source for 5/6   Source for Digital In   Source for Digital Out
Source for Record   LineOut12 LineOut34 LineOut56 LineOut78   Clock Source
```
`Mic InputSel` is the front/back select the user remembers; there is no per-pair
"Line/Mic 1/2 ... 7/8" set in the Windows driver (those OS9 strings belong to the
EWS88 family panel), and no "Source for 1/2"/"Source for 7/8" at all.

### [dev+0x185] is ONE boolean, and Windows ORs it into page 0x01, not page 0x03
`analysis/ews32.dis` (ews88wdm.sys), chip select routine, only for board type 8:
```
166f9: cmp edx,0x8                     ; type 8 == PHASE 88
166fe: cmp BYTE PTR [eax+0x185],0x0
16707: or  cl,0x10
1670a: cmp BYTE PTR [eax+0x184],0x0
16713: or  cl,0x20
16726: mov BYTE PTR [ebp+0x8],0x1      ; page 0x01
16730: call 0x1b82a                    ; write {0x01, cl} to 8-bit 0x42
```
Writes of that byte come from exactly two places, both single-value property
handlers: `1901f` (route/mux dispatch, `cl = [node+8]`) and `19dc9` (KS handler for
the GUID at 0x1c7ea, `al = *(BYTE*)data`).  It is compared as a boolean
(`cmp ...,0x0`) everywhere -> one switch, not a per-pair mask.

The register-based expander at 0x42 therefore looks like a PCA9555-class device
(reg 0x01 = port 0 output with chip select + flags, reg 0x03 = port 1 output,
outputs come up 0xFF after power on, which is why leaving reg 0x03 alone muted all
capture).  Windows drives its mic select on **port 0 bit 4**, which is a no-op on
our hardware; the bit that actually changes the audio is **port 1 (page 0x03)
bit 4**.  Design consequence: Linux should expose ONE input-source control for the
7/8 pair, not four speculative per-pair booleans - the four booleans in `f15b12d5a`
were built from OS9 strings of the wrong product family.

Open: whether that bit is a mux (front XLR vs rear DB25 aux) or a preamp enable -
`scripts/phase88-mic-talk-test.sh` decides it by talking into the mic with the
switch off and on (faint speech while off = preamp, dead silence = mux).

## 2026-10-16 (later): front mic at boot, and the two-card word-clock plan

User confirmed the front XLR pair works ("it works!") after `Line/Mic 7/8 Switch`
was turned on, and asked for it to be the boot default.

`/root/terratec/scripts/phase88-mixer.sh` now:
* sets `Line/Mic 7/8 Switch on` after the existing unity-gain defaults
  (override per run with `PHASE88_FRONT_MIC=off`, or edit the `FRONT=` default);
* applies **every** default to **every** ICE1712 card found instead of only the
  first one, so a second PHASE 88 is configured automatically.
Verified: `phase88-mixer.sh` -> "card 0 unmuted (monitor mixer unity, AK4524 0 dB,
front input on)" and `amixer cget` reads `on`.
Old note: with the switch off the mic on the front XLR measured -84 dBFS, with it
on -50 dBFS; rear aux 1..8 all work per user, so the pair really is switched,
which points at a mux rather than a preamp enable.  A rear-7 signal + toggle still
has to confirm it before the control is renamed to an enumerated
`Input Source 7/8` = `Rear Aux`/`Front Mic` (Windows calls it "Mic InputSel").

### Second PHASE 88, sync out (master) -> sync in (slave)

What the driver already offers (no patch needed for the slave side):
`Multi Track Internal Clock` is an enumerated control whose item 13 is
**`IEC958 Input`**; `snd_ice1712_pro_internal_clock_put()` (ice1712.c:1781, the
`item[0] == 13` branch at :1795) sets `ICE1712_SPDIF_MASTER` in
`ICEMT(ice, RATE)` and calls `snd_ice1712_set_input_clock_source()`, i.e. the
Envy24 stops free-running and locks to the clock recovered from its IEC958
receiver.  Everything else in that enum is an internal rate.

What is still unknown / likely needs work:
* which physical connector carries "sync" on this board - IEC958/ADAT or a
  dedicated word-clock line.  The OS9 panel has `CEWS88MTApp::GetSysClockSource`,
  `SetSysClockSource(m)`, `SetOpticalInClockSource(long,void*)`,
  `GetSysClockSourceSampleRate`, so a source select exists on the board.
* whether the master must enable its sync *output* somewhere - the two
  unmeasured flag bits of expander page 0x01 (0x40, 0x80) and the unmeasured
  low bits of page 0x03 (0x01, 0x02, 0x04, 0x08) had no effect on the analog
  path, which makes them the prime suspects for sync/loop-through enables.
  Windows exposes a "Clock Source" and "Mic28ClkSource" per the driver strings.
* JACK topology: with both cards locked either two jackd instances, or one
  server over an ALSA `multi` device.  To be decided once both cards probe.

Test planned for after the install: set the slave to `IEC958 Input`, confirm it
locks, then feed master output 1 into slave input 1 and record a click train for
a few minutes - a free-running slave slips its phase and eventually xruns, a
locked one does not.

---

## 2026-10-16 (night): two PHASE 88 cards, and the sync cable really does work

### What is in the machine now

```
lspci -nn -d 1412:   0000:03:01.0 and 0000:03:02.0  VIA ICE1712 [1412:1712] rev 02
/proc/asound/cards:  0 [Phase88]   io 0xd400 irq 22   = 03:01.0   (new card, SYNC IN)
                     1 [Phase88_1] io 0xdc00 irq 23   = 03:02.0   (original card, SYNC OUT)
```

Both cards take the patched module (OE taint), 87 controls each, `Line/Mic 7/8
Switch` on both, no probe errors.  The original card ended up as card 1 because
the new one enumerates first, so everything scripted here addresses cards by
role, not by number.  `phase88-mixer.sh` loops over all ICE1712 cards.

Note `irq 23` is shared with `ehci_hcd:usb1, uhci_hcd:usb2` on the original
card; card 0 has irq 22 to itself.  Nothing pathological observed.

### Why JACK showed 12 inputs

`jackd -d alsa -dhw:Phase88` opens exactly one card, so the 12 ports are that
one card's channels: 8 analog inputs of the rack, 2 phantom AC'97 capture
channels (silent, there is no consumer AC'97 codec on this board), and the 2
Envy24 digital monitor-mix channels.  Nothing of the second card appears,
because a JACK server binds a single ALSA device.

Two ways to run both cards:
1. one server over an ALSA `multi` device - needs the two cards on one clock,
   which is exactly what the sync cable is for;
2. two servers and route between them - works without sync, adds a hop of
   latency and two graphs.  Not what a multitrack rig wants.

`/etc/asound.conf` was created with option 1 (only named devices,
`pcm.!default` untouched so the desktop is unaffected):

| device | in | out | mapping |
|---|---|---|---|
| `phase88x2` | 16 | 16 | 1..8 card A analog in, 9..16 card B; same for out |
| `phase88x2all` | 24 | 20 | everything including the 2 silent AC'97 slots and 2 monitor mixes per card |

`jackd -d alsa -d phase88x2 -r 48000 -p 1024` therefore yields
`system:capture_1..16` / `system:playback_1..16`.  In QJackCtl the value goes in
the 'ALSA Device Name' field.

Gotcha while writing it: a `multi` slave block rejects `format` and `rate`
(`ALSA lib pcm.c:7907:(snd_pcm_slave_conf) Unknown field format`); only `pcm`
and `channels` are allowed there - the application supplies the parameters.

### The clock question, and how it was answered

Tools added:

* `scripts/phase88-pcm-run.c` - opens capture on N cards with
  `SND_PCM_TSTAMP_ENABLE`, because ALSA leaves the timestamp mode off for plain
  `arecord` and `/proc` then prints `tstamp : 0.000000000`, which makes a rate
  measurement impossible.  jackd enables the mode, so a card that already
  streams is measured as it is.  Build line (no alsa headers installed):
  `cc -O2 -Wall -o phase88-pcm-run phase88-pcm-run.c -L/usr/lib/x86_64-linux-gnu -l:libasound.so.2`
* `scripts/phase88-clock-measure.sh` + `phase88-clock-report.py` - rate from
  `(hw_ptr, tstamp)` pairs of `/proc/asound/cardN/pcm0c/sub0/status`, least
  squares fit, ppm against nominal, per-card and card-to-card.
* `scripts/phase88-sync-probe.sh` - tries the two reachable clock inputs of the
  slave and reports what each one does.
* `scripts/phase88-sync-follow.sh` - the decisive experiment, see below.
* `scripts/phase88-sync-setup.sh` - sets the roles (`--show`, `--off`), refuses
  while a stream is running.

Free-running baseline, both cards on their own oscillator: card 0 +59.7 ppm,
card 1 +58.9 ppm, i.e. only **0.8 ppm apart**.  Two identical boards from the
same batch land within a few ppm of each other, and the resolution of the DMA
timestamp method is about 2 ppm over 40 s (the timestamp only updates once per
period, which is where the 5..20 ms fit residuals come from).  Conclusion:
*comparing two free crystals cannot prove a lock on this hardware.*

`ICE1712_CFG_EXT`, bit `0x80` of PCI config `0x60` (`ice1712.h:180`, written
once from the EEPROM byte at `ice1712.c:2316` and never touched by the driver
afterwards), turned out to be an oscillator-family select rather than a
word-clock input: with the bit set, a card programmed for 48000 runs at
**44101.0 Hz** (-81228 ppm) - on *both* cards, including the one whose sync
input has nothing connected to it, and with a clean stable clock, so that input
is an on-board 22.5792 MHz oscillator, not the sync header.  Dead end for sync,
useful as a measuring stick.

That gave the decisive test, `phase88-sync-follow.sh`: instead of comparing
ppm, make the master jump by 8 % and see whether the slave moves with it.

```
                              slave (card 0,          master (card 1,
                              'IEC958 Input')         own oscillator)
PHASE A  master internal      48003.810 f/s           48003.515 f/s
PHASE B  master EXT bit set   44101.360 f/s           44101.206 f/s
PHASE C  (not restored)       44101.464 f/s           44100.988 f/s

master moved -81292 ppm, slave moved -81295 ppm
```

Only the master's config byte was written in phase B; the slave's capture DMA
slowed by the identical amount.  **The sync cable carries the master's clock
into the Envy24 clock input selected by 'Multi Track Internal Clock' =
'IEC958 Input', and the slave locks to it.**

Corollaries measured along the way:

* the master drives SYNC OUT even when it is idle: with the cable attached and
  the master streaming nothing, the slave on 'IEC958 Input' reads a clean
  48003 f/s;
* with the clock input *empty*, 'IEC958 Input' does not stall the card - it
  free runs at about **33168 frames/s**.  So an unplugged cable does not
  produce an obvious error, it produces a card running 31 % slow.  Unplug = run
  `phase88-sync-setup.sh --off` first.

### Two driver behaviours that shape any sync recipe

1. **`'Multi Track Internal Clock' item numbers are not register values.**
   `snd_ice1712_pro_internal_clock_info()` (ice1712.c:1736): item 8 = "44100",
   item **9** = "48000", item 13 = "IEC958 Input"; the register value for 48 kHz
   is 0.  An earlier note here said item 8 was 48000 - that was wrong, and it
   quietly made "restore to 48000" restore 44100.  Fixed in the scripts
   (`INT_ITEM=9`).
2. **A clock change while a stream runs is silently ignored.**
   `snd_ice1712_set_pro_rate()` (ice1712.c:976-981) returns as soon as
   `PLAYBACK_CONTROL` shows a started/paused stream, so `outb(val, RATE)` never
   happens.  `amixer` reports success and nothing changed.  The clock source
   must be programmed **before** anything opens the card - which is why
   `phase88-sync-setup.sh` refuses while a stream is RUNNING, and why it is
   called from `phase88-mixer.sh` at boot.
   Once the slave is on 'IEC958 Input', `is_pro_rate_locked()`
   (ice1712.c:113 `is_spdif_master(ice) || PRO_RATE_LOCKED`) is true, so jackd
   opening the slave at 48 kHz no longer reprograms its clock - the desired
   behaviour for a slaved card.
   Both look like upstream conversation material, not PHASE 88 specific bugs.

### Configuration that is live on this machine now

* card 0 = slave on 'IEC958 Input' (item 13), card 1 = master on item 9 (48000).
* `/etc/default/phase88`:
  ```
  PHASE88_SYNC_MASTER=1
  PHASE88_SYNC_SLAVE=0
  PHASE88_FRONT_MIC=on
  ```
* `phase88-mixer.sh` (run by `phase88-audio.service` at boot, before any audio
  application) now ends with a call to `phase88-sync-setup.sh` when
  `PHASE88_SYNC_SLAVE` is set and two cards are present; it prints
  `word clock setup refused (streams running, or one card)` rather than
  pretending to succeed.
* PCI config `0x60` is `0x1f` on both cards: the EXT experiment was reverted,
  and the scripts restore it through `base_cfg()` which clears only bit 7.

### Still open

* validate `jackd -d alsa -d phase88x2` with both cards streaming (needs the
  user's jackd stopped for a couple of minutes): 16+16 ports, no xruns over a
  few minutes, and the clock follow test re-run under that load.
* measure the *fixed* sample offset between the two cards with a click train
  (master output 1 into slave input 1).  Frequency lock is proven; a constant
  offset is harmless and compensable, drift would not be.
* audible confirmation of outputs 1/2 (user).
* mux versus preamp for 'Line/Mic 7/8 Switch' (needs a signal on rear input 7
  while toggling).
* whether 'Multi Track Rate Locking'/'Rate Reset' need touching for the slaved
  card; not needed in the tests so far.
* the RFC debug controls (commit `c021a09f3`) stay out of any upstream series.

## 2026-10-17: the two cards validated together under one JACK server

User stopped QJackCtl so the card was free, and reported that QJackCtl does not
offer `phase88x2` in its device list and that starting JACK from the command
line prints

```
ALSA lib control.c:1575:(snd_ctl_open_noupdate) Invalid CTL phase88x2
control open "phase88x2" (No such file or directory)
```

QJackCtl's device list is a probe of the `default` device plus its own list of
`hw:` cards, so a named `pcm.` definition never shows up there - it has to be
typed into 'ALSA Device Name'.  The control message is explained and fixed
below.

### Combined device works, both cards at once, no xruns

* `arecord -D phase88x2 -f S32_LE -c 16 -r 48000 -d 3` produced exactly
  9216000 bytes (3 x 48000 x 16 x 4) and **all 16 channels carried signal**
  (peaks -59.8 to -85.6 dBFS of analog noise floor: ch1..8 the clock slave,
  ch9..16 the clock master).  So the `multi` plugin drives both cards in one
  stream.
* `jackd -d alsa -d phase88x2 -r 48000 -p 1024 -n 2`: 16 capture + 16 playback
  ports, **0 xruns**, and `/proc/asound/card{0,1}/pcm0c/sub0/status` showed both
  cards `RUNNING` with the same `owner_pid`.
* `jackd -d alsa -d phase88x2all` (24 capture / 20 playback) plus a 997 Hz
  tone at -6 dBFS into `system:playback_1` (analog out 1 of the slave card) and
  into `system:playback_11` (analog out 1 of the master card): the Envy24
  monitor mix of each card came back on `system:capture_11` and
  `system:capture_23` both at **-6.0 dBFS peak / -10.1 dBFS rms**.  Full duplex
  on both cards, through one server, 0 xruns.
* While jackd owned both cards the DMA rate measurement gave
  card 0 +61.71 ppm, card 1 +59.03 ppm (difference 2.69 ppm, fit residual
  10-17 ms).  That is *not* a drift figure: the same instrument measured
  0.78 ppm between the two cards while both were free running, so a few ppm is
  its resolution floor.  The lock itself is proven by the 8 % master
  perturbation test of 2026-10-16 (master -81292 ppm, slave -81295 ppm).

### 'Invalid CTL phase88x2' silenced, and it was worth silencing

A `multi`/`asym` PCM is a PCM-only construct: it has no control element, and
jackd always tries `snd_ctl_open()` with the same name it was given for the
PCM, hence the message.  Harmless - only the optional mixer access fails - but
it looked like a fault.  `/etc/asound.conf` now also defines

```
ctl.phase88x2    { type hw  card "Phase88" }
ctl.phase88x2all { type hw  card "Phase88" }
```

jackd then starts with no control error at all (verified, same signal test,
still 0 xruns), and it gets a real mixer handle plus the D-Bus reservation for
that one card.  The second card stays unreserved - the reservation API is
per-device, so a combined device can only reserve one of them.

### Two JACK environment traps hit while testing (both cost me a detour)

* **A client that dies without closing makes jackd xrun forever.**  Running
  `jack_simple_client --help` created a client literally named `--help`
  (the client name comes from argv[0] when the tool passes it straight
  through), the process exited
  without `jack_client_close()`, and the engine then blamed it for an xrun on
  every single cycle: `JackEngine::XRun: client = --help was not finished,
  state = Triggered`, 12103 of them, jackd at 35 % CPU.  Nothing was wrong with
  the audio path.  Only a server restart clears it.  Same symptom to look for
  if QJackCtl's xrun counter ever runs away: a dead client, not the hardware.
* **`jack_connect()` from a client fails before `jack_activate()`.**  With
  jackdmp 1.9.22 the call returns failure, while the identical connection made
  from the `jack_connect` command line tool works.  Register ports, activate,
  *then* connect.  That is what `phase88-jack-io` now does.
* Also: `jack_rec` is transport driven (it waits for a rolling transport that a
  plain `jackd` start does not give it) and `jack_metro` refuses to run without
  `--bpm`; libjack auto-spawns a *new* server on `hw:Phase88` when it cannot
  reach one, which is how I briefly had a single-card server answering my
  two-card questions.  Export `JACK_NO_START_SERVER=1` when scripting.

New tool for this and later tests: `scripts/phase88-jack-io.c` (+ binary),
`--sine <port>...` feeds a 997 Hz / -6 dBFS tone into the named ports,
`--record <sec> <port>...` prints per-channel peak and rms in dBFS over the
last 60 % of the take.  Needs `<jack/jack.h>`, so `libjack-jackd2-dev` is now
installed on this box (only -dev package installed so far, nothing else).

### Unrelated hardware noise found in dmesg

`ata4: link is slow to respond` / `ata4: device not ready (errno=-16), forcing
hardreset` - 799 occurrences since the morning, roughly every minute.  That is
the built-in 4-slot card reader (its four logical devices are the 0 B `sdb`..
`sde`), not the audio cards.  Each reset costs the box ~5 s of an unresponsive
ATA link, which is exactly the kind of stall that can cause an xrun, so it is
worth disabling that port - kernel command line `libata.force=4:nonexistent`
would do it.  Not done: the user may want that reader slot.

### Live configuration right now

* card 0 `hw:Phase88` = PCI 03:01.0 = new board = clock **slave**
  (`Multi Track Internal Clock` = 13 'IEC958 Input')
* card 1 `hw:Phase88_1` = PCI 03:02.0 = original board and rack = clock
  **master** (item 9 = internal 48000)
* `/etc/default/phase88`: `PHASE88_SYNC_MASTER=1`, `PHASE88_SYNC_SLAVE=0`,
  `PHASE88_FRONT_MIC=on`; applied at boot by `phase88-mixer.sh` through
  `phase88-sync-setup.sh` (which refuses, with a message, rather than pretending
  when a stream is open).
* jackd was left stopped at the end of the session so QJackCtl can start its
  own server.

### Still open

* User to start QJackCtl with 'ALSA Device Name' = `phase88x2` and confirm in
  Reaper that both racks record (1..8 new board, 9..16 original rack).
* Sample-accurate offset between the two cards has never been measured - needs
  one patch cable (master output 1 into slave input 1, or both inputs of one
  card fed from the same source) and a click: `phase88-jack-io --sine
  system:playback_1` plus `--record` on the two inputs.
* User to confirm outputs 1/2 audibly (m00267).
* Mux or preamp: `Line/Mic 7/8 Switch` still needs the rear-input-7 test
  (m00261/m00275) before it gets its final name.
* Whether the board-level 'sync out enable' needs anything on the expander
  (page 0x01 bits 0x40/0x80 measured inert for audio; sync out appears to be
  always driven).
* Drop the RFC debug commit `c021a09f3` before any upstream submission; nothing
  goes upstream until the user says so.

## 2026-10-18: guide, stock-kernel proof, and the MIDI question

Written for the user's "how do I actually use this" question:

* `/root/terratec/install/PHASE88-GUIDE.md` - quick start, what the patch fixes,
  the asound.conf question, the service question, one card versus two, the
  clocking evidence, JACK/Reaper settings, MIDI, troubleshooting table, known
  gaps.  (Moved out of the repo root on 2026-10-19.)
* `/root/terratec/install/debian-stock-kernel.md` - the out-of-tree build recipe.
* `/root/terratec/install/etc/` - the three system files this machine uses, so a
  fresh box can be rebuilt from the repo.
* `scripts/phase88-install-policy.sh` - installs them (and optionally the
  module), rewriting the unit's mixer path to wherever the repo lives.
* `scripts/phase88-midi-test.sh` - MIDI loopback / cross-card tester.

### The patch does NOT need a custom kernel (measured, not assumed)

Against Debian's stock `6.12.111+deb13-amd64`:

```
apt-get install -y build-essential linux-headers-6.12.111+deb13-amd64 \
                   linux-source-6.12=6.12.111-1
tar -xf /usr/src/linux-source-6.12.tar.xz
patch -p1 < phase88-fix.patch     # applied, offsets +5/+7/+26, no rejects
make -C /lib/modules/6.12.111+deb13-amd64/build M=<ice1712 dir> modules -j8
```

0 warnings, 0 errors; `vermagic: 6.12.111+deb13-amd64 SMP preempt mod_unload
modversions`; dependency list identical to the 6.18.55 build; `strings` shows
1 x `Line/Mic 7/8 Switch` in ours and 0 in Debian's own module.  Debian built
that kernel with gcc 14.2.0, which is the gcc on this box, so there is no
compiler mismatch either.  Secure Boot is not in play here: this machine boots
legacy BIOS (`/sys/firmware/efi` absent, `mokutil` not installed), so the
unsigned module loads with the usual `OE` taint.  Nothing from that build was
installed - the running system is still the 6.18.55 module.

### MIDI: one port per card today, two on Windows

`/dev/snd/midiC0D0` + `midiC1D0` exist and the sequencer shows both cards
(clients 16 and 20, `TerraTec Phase88 MIDI`), so the driver side is alive;
`amidi -s` accepts a SysEx payload.  But the Linux PHASE 88 path registers
**one** UART per card: `ice1712.c:2618` registers UART 0 unless `c->no_mpu401`,
and UART 1 only `if (ice->eeprom.data[ICE_EEP1_CODEC] & ICE1712_CFG_2xMPU401)`
(`0x20`, `ice1712.h:181`); this EEPROM byte is `0x0f`, so the bit is clear.
Terratec's own `ews88wdm.inf` installs `PHASE88 MIDI Port 1` **and**
`Port 2`, and its changelog line 10 says `17-Sep-02 (Cl) - Mic28 Extensions
(Midi 2)` - the second port belongs to the same Mic28 front subsystem that
carries the front mic input, and the OS9 kext has
`IceAPIGetNumMIDIDevice`/`IceAPISetMidiCallback`/`TerratecServeMidiIRQ`.  So a
second DIN may well be wired to the MPU2 registers (`MPU2_CTRL 0x1c`,
`MPU2_DATA 0x1d`, IRQ `ICE1712_IRQ_MPU2 0x20`) and Linux simply never maps them.

Untested until a cable is in: which DIN is IN, which is OUT, and whether they
are even isolated.  `amidi -p hw:Phase88 -s` wrote successfully and the other
card received 0 bytes, which is the expected result with nothing connected.
Test it with `scripts/phase88-midi-test.sh` (loopback, single card, or
`--cross hw:Phase88 hw:Phase88_1`).  For JACK MIDI, `jackd` needs `-X seq` (or
`-X raw`) - without it JACK is audio only.

If the test shows a DIN that no Linux port can reach, the next experiment is a
quirk that sets `ICE1712_CFG_2xMPU401` for `ICE1712_SUBDEVICE_PHASE88` and
registers the second UART; that needs a physical cable test to justify it.

### Boot policy re-verified

`systemctl restart phase88-audio.service` (no streams running) left card 0 on
`IEC958 Input` (clock slave, new board, PCI `03:01.0`), card 1 on `48000`
(master, original rack, PCI `03:02.0`), and both cards with `Line/Mic 7/8
Switch=on`, `Multi Playback Switch=on,on`, `Multi Playback Volume=96,96`,
`ADC Volume=127`.

### Working note

Two `acp_delegate` worker runs died with exit 143 (`timed out: no output for
5m`) while running silent `apt`/`tar`/`make` steps, and the resumed run produced
an empty activity log.  Long quiet commands belong in the main session with
background + short polls; that is what finished the Debian build.

## 2026-10-19: two-card confirmation, and the second MIDI UART

User confirmed (m00951): "Ok, repaer test on all 8+8 port worked" - the
combined `phase88x2` device is working in Reaper with both racks, which also
closes the "are the outputs audible" question from m00267.

Then the MIDI question (m00777 item 3).  Inventory:

```
$ amidi -l                          # before
IO  hw:0,0  TerraTec Phase88 MIDI
IO  hw:1,0  TerraTec Phase88 MIDI
```

Only one UART per card because the EEPROM `Codec` byte reads `0x0f`, i.e.
`ICE1712_CFG_2xMPU401` (bit `0x20` of `ICE_EEP1_CODEC`) is clear, and
`snd_ice1712_midi_init()` is only called a second time when it is set
(`ice1712.c:2632`); the second UART lives at MMIO `0x1c/0x1d`
(`ICE1712_REG_MPU2_CTRL/DATA`) and signals on `ICE1712_IRQ_MPU2` (`0x20`).
The Terratec Windows driver installs two ports (`ews88wdm.inf`
`[PHASE88.Interface.Midi1]`, `[PHASE88.Interface.Midi2]`, "PHASE88 MIDI Port
1/2"), and the INF changelog line 10 says `17-Sep-02 (Cl) - Mic28 Extensions
(Midi 2)`, which is the same Mic28 block that owns the mic input - so the
second UART is probably the mic-panel MIDI, not a rack connector.  Unresolved
without looking at the rack.

Experiment committed as a second RFC commit, `9b45794e6 "RFC/DO-NOT-SUBMIT:
ASoC: ice1712: add a mpu401_2 parameter for the PHASE 88"`: sets
`ICE1712_CFG_2xMPU401` when the parameter is on, default off.  Installed via
`/etc/modprobe.d/phase88.conf` (`options snd_ice1712 mpu401_2=1`) so the user
can test without remembering anything:

```
$ amidi -l                          # after
IO  hw:0,0  TerraTec Phase88 MIDI
IO  hw:0,1  TerraTec Phase88 MIDI
IO  hw:1,0  TerraTec Phase88 MIDI
IO  hw:1,1  TerraTec Phase88 MIDI
```

Measured with it on: no oops, no `WARNING`, both cards still capture
(958 104 and 958 240 nonzero words of 1 152 000 in 2 s at 48 k/12 ch S32_LE),
and **no interrupt storm** - 0 interrupts on irq 22 and irq 23 over 10 s of
idle, which was the risk of enabling a floating UART on a line shared with
`ehci_hcd:usb1, uhci_hcd:usb2`.

`scripts/phase88-midi-test.sh` gained a `--watch [hw:X,Y] [secs]` listener mode
and the guide has a 6-row test matrix (loopback on port 0, then the same cable
against port 1, so the four cases "both DINs on UART 1 / IN on UART 2 / OUT on
UART 2 / both on UART 2" are distinguished with a single cable move).

Scripts fixed on the way, all of them bugs in *my* helpers, not in the driver:
- `phase88-loopback.sh` asked `speaker-test` for `-p 1024`, but `-p` is
  `--period-time` in **microseconds**: a 196-frame buffer that underruns as
  soon as the box is busy (rustdesk sits at ~57 % CPU here) and printed
  `Write error: -32, Broken pipe`.  Now `-p 21000` (period 1008 / buffer 4032);
  `speaker-test` 1.2.14 has no `-B` option at all.
- the same script's `arecord` had no `-d`, so the safety `timeout` reaped it
  with 124 and the `if !` branch called that a capture failure.  Now
  `arecord -d $SECS` inside the timeout, and the verdict needs a real signal
  (-40 dBFS) before claiming an analog loopback - the noise floor of an idle
  AK4524 is about -56 dBFS and used to be reported as "works".  Current honest
  result with nothing connected: monitor mix carries the 1 kHz tone
  (ch11/12 at 0.0/-1.9 dBFS), inputs 1-8 at -56..-85 dBFS, `exit 2`.
- `depmod -a 6.18.55` on this box takes **2 m 24 s**, which is what made an
  `install && depmod && rmmod && modprobe` chain look stuck: the 120 s tool
  timeout fired inside depmod and the module was never reloaded.  Run depmod on
  its own here.

Commit layout now: five submission commits `941c14e58..HEAD~2`, then two
`RFC/DO-NOT-SUBMIT` ones (`c021a09f3` expander bring-up controls, `9b45794e6`
mpu401_2).  Nothing is submitted yet.

## 2026-10-19 (afternoon): the rear MIDI socket is real - second UART made permanent

User reported (m01141): *"i set the loopback cable on the front
of rack MIDI of first board, phase88-midi-test.sh reyutn data send and received,
RESULT: MIDI WORKS. There is a MIDI 2 interface on the back of the rack to be
tested. Also prepare sh to test midi on rack #2 ... If you want you can run test
rack #1 MIDI 2 cause I've plugged the loopback on the MIDI 2 of rack #1."*

So the FRONT socket of rack #1 is confirmed working by the user (`hw:0,0`, the
UART the stock driver registers too).  With the cable moved to the REAR socket I
probed every combination on both cards:

```
card 0 send hw:0,0 -> listen hw:0,0 : NO DATA
card 0 send hw:0,0 -> listen hw:0,1 : received '00'          <- see below
card 0 send hw:0,1 -> listen hw:0,0 : NO DATA
card 0 send hw:0,1 -> listen hw:0,1 : MIDI WORKS (3 frames, byte-exact)
card 1 (all four)                   : NO DATA (no cable in rack #2)
```

**The rear connector is the second MPU-401 UART.**  That settles the question
that the `mpu401_2` parameter was written for, so the parameter is gone and the
EEPROM bit is now set unconditionally for this board:

* new submission commit `b854c1887 "ASoC: ice1712: claim the second MIDI port of
  the PHASE 88"` (sets `ICE1712_CFG_2xMPU401` in the same fixup that sets
  `ICE1712_CFG_NO_CON_AC97`);
* `/etc/modprobe.d/phase88.conf` deleted again, and verified: after
  `rmmod snd_ice1712 && modprobe snd_ice1712` the parameter list under
  `/sys/module/snd_ice1712/parameters/` no longer contains `mpu401_2` while
  `amidi -l` still shows four ports (hw:0,0 hw:0,1 hw:1,0 hw:1,1) and the rear
  loopback still passes;
* the history was reordered so the submission commits stay contiguous - the RFC
  expander commit was re-created by cherry-pick and is now `d2db56036` (was
  `c021a09f3`).  Submission set = `941c14e58..HEAD~1`, **six** patches,
  regenerated `analysis/series/0001..0006-*.patch` and `analysis/phase88-fix.patch`
  (332 lines).  checkpatch `--strict`: 0 errors, 0 warnings, 4 checks (two
  continuation-line alignments in the Line/Mic hunk, `(0x42>>1)` spacing kept to
  match the surrounding EWS code, and `Avoid CamelCase` on the pre-existing
  `ICE1712_CFG_2xMPU401` macro name).

The single stray `00` byte seen on the rear RX while transmitting on the front
UART is not explained.  A break condition reads as `0x00`, so it is most likely
a line glitch when the other UART is opened, not data; it never arrived as a
frame and did not disturb the pass/fail verdict.

Socket map, measured:

| rack socket | ALSA | sequencer |
|---|---|---|
| front "MIDI 1" | `hw:<card>,0` | `<client>:0` |
| rear "MIDI 2"  | `hw:<card>,1` | `<client>:32` |

Both keep the same name (`TerraTec Phase88 MIDI`), so only the number tells them
apart; under `jackd -X seq` the log shows `TerraTec-Phase88:midi/{playback,
capture}_1` and `_33` per card, and both cards share that base name too.

New `scripts/phase88-midi-racks.sh` walks the four sockets the user asked about
(rack 1 front/rear, rack 2 front/rear) with ONE cable, prompting between
sockets: `--list` prints the map with PCI address and clock role, `--probe
<card>` tries all four send/listen combinations, `--identify <card>` plays
440 Hz on outputs 1/2 so you can see which rack answers, `--yes` runs all four
without prompting.  Rack numbering defaults to rack 1 = clock slave = card 0,
rack 2 = master = card 1, overridable with `PHASE88_RACK1` / `PHASE88_RACK2` in
`/etc/default/phase88`.  Measured with the cable left in rack #1 rear:

```
PASS    rack #1 MIDI 2 (rear)  hw:0,1
FAIL    rack #1 MIDI 1 (front)  hw:0,0     (correct: cable is in the rear)
FAIL    rack #2 MIDI 1 (front)  hw:1,0     (correct: no cable in rack #2)
FAIL    rack #2 MIDI 2 (rear)   hw:1,1     (correct: no cable in rack #2)
```

`phase88-midi-test.sh` also got a `PORT BUSY` verdict (exit 3): `jackd -X raw`
(and Reaper's own ALSA MIDI backend) hold `/dev/snd/midiCxDy`, rawmidi allows
one client, and `amidi: cannot open port "hw:0,1": Device or resource busy`
otherwise looks like a hardware fault.  Measured both ways: jackd up -> exit 3
with the explanation, jackd stopped -> `MIDI WORKS`.

Open question left by this session: sending with `aplaymidi -p 16:32` while
jackd ran produced nothing in `jack_midi_dump`, so the ALSA-seq -> JACK relay is
unverified (the loopback itself is proven at the rawmidi level).  Needs another
look, probably it is the same exclusivity, or jackd's seq client not subscribing
to the hardware ports.

Machine left: jackd stopped, no stale `/dev/shm/jack_*`, card 0 = clock slave
(item 13), card 1 = master (item 9), both cards unmuted with the front input on,
four MIDI ports each, both git trees clean.

## 2026-10-19 (evening): the verdict bug, and the folder sorted out

User said (m01259): *"1) the phase88-midi-racks.sh output show FAIL on single
test and then PASS on summary, maybe a typo error on single test? 2) this folder
contains subfolder analysis, baseline, build-oot, docs, driver, kernel, logs,
scripts, and the phase88_driver_agent_handoff.md, We can cleanup the things no
more needed. ... and build a folder named install where to put the install files
(i suppose the one in etc), and the documents needed, so the GUIDE you have
created. In other word, let's sort it out"*

### the per-socket verdict was wrong (script bug, not hardware)

`RESULTS="$RESULTS\nPASS    ..."` builds **one** string holding literal `\n`
escapes, so `echo "$RESULTS" | tail -1` returned the whole accumulated string
and `awk '{print $1}'` printed the **first** socket's verdict on every line -
socket 1 said FAIL, so every later socket echoed FAIL while the summary
(`printf "%b"`, which does expand the escapes) was right.

Fix: compute a `verdict` variable per socket, print that, and record it; added a
`BUSY` verdict for test exit 3.  Measured again with the cable in rack #1 rear:
`FAIL / PASS / FAIL / FAIL` inline, identical to the summary.

### new layout

| moved | to |
|---|---|
| `etc/` | `install/etc/` (mirrors `/etc`, so the copy targets are obvious) |
| `PHASE88-GUIDE.md`, `docs/debian-stock-kernel.md` | `install/` (all docs for a new box in one place) |
| `baseline/` | `analysis/baseline/` (it is evidence, not a top-level thing) |
| `driver/windows2000_vista_xp/` | `driver/win/` |
| `driver/os9/` + the loose `.pax` | `driver/os/` |
| new | `README.md` (folder map), `install/README.md` (install steps), `driver/README.md` (which vendor file proved what), `scripts/README.md` (tool table) |

`scripts/`, `logs/` and `kernel/` stayed put on purpose: the systemd unit
execs `scripts/phase88-mixer.sh` and the scripts write into `logs/`.

### deleted

* `build-oot/` (1.7 G) - the extracted Debian source tree, reproducible with
  `apt + tar`. Its proof survives as `install/modules/MODINFO-stock-debian-6.12.111.txt`,
  the trimmed `Makefile.oot-example` and the three `.ko` files, xz'd (740 K).
* `driver/os9_decompiled/` (7.5 M) - a Ghidra project built from the kext; the
  kext binary itself is kept (`md5 d3cecb1fbf18756bb57d754832a66d71`, recorded
  in `driver/README.md`), so it can be regenerated.
* `V549Remove.exe` (a Windows uninstaller) and the empty `Driver 5.51b` folder.
* `scripts/test-phase88.sh` - a 20-line `lspci`/`lsmod` dump from day one,
  superseded by `phase88-verify.sh`; the original captures are in
  `analysis/baseline/`.
* `scripts/phase88-expander-sweep.sh` was a **python** file with a `.sh` name
  (`bash -n`: `syntax error near unexpected token '('` at line 25
  `def sh(cmd):`) - renamed to `.py`.

### a landmine the cleanup surfaced

`etc/modprobe.d/phase88.conf` was still in the repo containing
`options snd_ice1712 mpu401_2=1`, even though that parameter was replaced by
the permanent quirk in `b854c1887`.  Restoring the snapshot on a machine would
have made modprobe fail on an unknown parameter and the card would not load at
all.  The live file was correctly absent (`modprobe --show-depends snd_ice1712`
ends in a clean `insmod .../updates/snd-ice1712.ko`); the snapshot is deleted.

### re-verified after the move

`bash -n` on every shell script and `ast.parse` on the python one;
`phase88-install-policy.sh` re-run from `install/etc` (idempotent, unit
regenerated with the right mixer path, cards 0 1 detected);
`phase88-mixer.sh` (both cards unmuted + `word clock set (slave card 0)`);
`phase88-sync-setup.sh --show` (card 0 = 13 IEC958 Input, card 1 = 9 = 48000);
`amidi -l` (four ports); `phase88-midi-racks.sh --yes` (verdicts now match).

### the clock lock also decides the sample rate (found by the verify run)

The post-cleanup `phase88-verify.sh` run failed two checks on card 0 -
`Rate 44100Hz not available for playback` and the same for 96000 - although the
same script had passed all three rates a day earlier.  Not a regression: card 0
had become the clock **slave** when the second card arrived, and while
`is_pro_rate_locked()` is true (`is_spdif_master() || PRO_RATE_LOCKED`,
`ice1712.c:112-114`) the driver clamps `rate_min = rate_max = PRO_RATE_DEFAULT`
in `snd_ice1712_playback_pro_open()` (`ice1712.c:1122`) and its capture twin at
`:1143`.  A locked card exposes exactly one rate.

Proved by moving the master instead of the card under test:

| master (card 1) clock | slave (card 0) @48000 | slave @96000 |
|---|---|---|
| item 9 = 48000 | works | refused |
| item 12 = 96000 | refused (arecord relaxed it to 96000, 4608000 bytes) | works: 1 s x 96000 x 12 ch x 4 B = 4608000 bytes |
| back to item 9 | works (2304000 bytes) | refused |

Practical rule for the user: to run the pair at 96 kHz, set the **master**'s
`Multi Track Internal Clock` to 96000 first (JACK stopped), then start JACK at
96000.  A slave asked for a rate the master is not sending will not open.

Two tool consequences:

* alsa-utils 1.2.14 `arecord`/`aplay` **relax the rate silently and exit 0**:
  `Warning: rate is not accurate (requested = 96000Hz, got = 48000Hz)` /
  `please, try the plug plugin`.  There is no `-e`/`--nofallback` in this build,
  so the real rate must be read from `/proc/asound/cardN/pcm0[pc]/sub0/hw_params`
  (which `phase88-verify.sh` already prints in its `[ok]` line).
* `phase88-verify.sh` now reads the clock item first and prints
  `[skip] 96000 Hz refused while clock-locked to the master - expected on a
  slave, not a fault`, instead of a FAIL, plus a `clock:` line naming the role.
  Measured after the change: card 0 (slave) = `all checks passed` with two
  skips; card 1 (master, own oscillator) = all three rates RUNNING.  Parsing
  detail: the value line from `amixer cget` is `  : values=13` **with leading
  spaces**, so the sed needs `s/^ *: values=\([0-9]*\).*/\1/p`.
* `phase88-sync-setup.sh --show` gained the same note, printing the master's
  current rate via a new `rate_label_of()` helper (it greps the `Item #N 'x'`
  lines of the control).
