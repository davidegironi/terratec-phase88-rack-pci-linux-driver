# TerraTec PHASE 88 on Linux — running guide

Everything a PHASE 88 (Envy24 / ICE1712, PCI id `1412:1712`, subsystem
`153b:1151`, i.e. `ICE1712_SUBDEVICE_PHASE88 = 0x3b155111`) needs on Linux:
which driver to use, what to set at boot, how to run one or two cards in
JACK/QJackCtl/Reaper, and how to test the parts that need a cable.

This machine: two PHASE 88 racks, kernel 6.18.55 built from
`/root/terratec/kernel/linux-6.18.55`, branch `phase88`, both cards working
(8 analog in + 8 analog out each, front mic input, clock slave locked to the
master through the sync cable).  Card 0 = PCI `0000:03:01.0` = new board =
clock **slave**; card 1 = PCI `0000:03:02.0` = original board and rack =
clock **master**.

---

## Quick start

**One card, today, nothing to configure.**  QJackCtl -> *ALSA Device Name*
`hw:Phase88` -> Start.  `system:capture_1..8` are the eight analog inputs,
`system:playback_1..10` the analog and digital outputs.  Boot already unmutes,
sets unity gain and turns the front input on, so a mic or a line source works
without touching a mixer.

**Two cards on the sync cable** (this machine): type
*ALSA Device Name* `phase88x2`, Sample rate 48000, Period 1024 -> Start, and one
JACK server drives both racks: `capture_1..8` on one card, `capture_9..16` on
the other.  If QJackCtl was open before, press *Refresh*.

**Is it actually working?**  `scripts/phase88-jack-meter.sh` (with JACK up) or
`scripts/phase88-verify.sh` (with JACK down) answer in about a minute.

## 1. What the driver patch actually fixes

The stock `snd_ice1712` driver treats the PHASE 88 as an EWS88 and gets four
things wrong.  Symptoms and fixes, in the order they were found:

| symptom | cause | commit |
|---|---|---|
| probe fails, `AK4524 chip select failed, check cable to the front module`, `probe with driver snd_ice1712 failed with error -5` | the EWS88 code looks for the PCF8574 pair at I2C 7-bit `0x23`/`0x24`.  The PHASE 88 has no such chips: its chip-select/output expander is a single write-only device at 7-bit `0x21` (8-bit `0x42`), programmed with a two-byte write `{ 0x01, flags \| active-low AK4524 chip-select nibble }`, flags starting at `0x20` | `ad0f14e94` |
| kernel oops `BUG: kernel NULL pointer dereference, address: 00000000000000ac`, `RIP: snd_ice1712_capture_open+0x98/0xd0` | `snd_ice1712_capture_open()` dereferenced `ice->ac97->rates[AC97_RATES_ADC]` unconditionally, and on this card `ice->ac97` is NULL | `0cfa29122` |
| 2 s boot stall plus `AC'97 0 does not respond - RESET`, `AC'97 0 access is not valid [0xffffffff], removing mixer.`, `cannot initialize ac97 for consumer, skipped`, and phantom consumer PCM devices | the EEPROM advertises a consumer AC'97 codec (`Codec` byte `0x0f`); the AC-Link does not answer even after a cold reset.  All converters are AKM chips on the multitrack I2S bus | `8dc8649b3` |
| **every one of the 8 analog inputs reads exact zeros**, even though the codecs are programmed, unmuted, and capture reaches `RUNNING` | a *second* register of the same expander (page `0x03`, i.e. PCA9555-style port 1) was never written.  Its latch comes up `0xFF` at power-on and while it is undefined the four AK4524 leave their serial output drivers disabled.  The Windows driver initialises it as `{0x03, 0x00}` | `eb9089386` |
| front microphone input (channels 7/8) silent, rear aux inputs fine | no control for the input select; bit `0x10` of page `0x03` is the mic select and gives about **+28 to +33 dB** | `f15b12d5a` |

Five commits make the card work; the sixth is RFC debug-only and must not go
anywhere near a submission:

```
ad0f14e94 ASoC: ice1712: fix PHASE 88 chip select expander address
0cfa29122 ASoC: ice1712: guard consumer capture against a missing AC'97 codec
8dc8649b3 ASoC: ice1712: PHASE 88 has no consumer AC'97 codec
eb9089386 ASoC: ice1712: initialise the second PHASE 88 expander register
f15b12d5a ASoC: ice1712: add the PHASE 88 Line/Mic input switches
c021a09f3 RFC/DO-NOT-SUBMIT: bring-up controls for the PHASE 88 expander   <- drop this one
```

Patch files: `/root/terratec/analysis/series/0001..0005-*.patch` (the clean
set), combined `/root/terratec/analysis/phase88-fix.patch` (313 lines),
`/root/terratec/analysis/0001-RFC-DO-NOT-SUBMIT-*.patch`.  Only three files are
touched: `sound/pci/ice1712/{ice1712.c,ews.c,ews.h}`.  `checkpatch.pl` is clean
(0 errors, 0 warnings); the only thing missing for `alsa-devel` is a
`Signed-off-by:` line, which is deliberate until the work is finished.

## 2. Does this need a custom kernel?

**No.**  The patch touches only `sound/pci/ice1712/{ice1712.c,ews.c,ews.h}`, no
exported headers and no Kbuild plumbing, so the module can be rebuilt
out-of-tree against the `linux-headers` package of whatever kernel you boot and
dropped into `/lib/modules/$(uname -r)/updates/`, where depmod prefers it over
the distro copy.  Full details, and the run that proves it, are in
`/root/terratec/docs/debian-stock-kernel.md`.  The short version, measured here
on 2026-10-18 against Debian's stock `6.12.111+deb13-amd64`:

```
# note the versioned package name: plain 'apt-get install linux-source' fails
# with 'Depends: linux-source-6.12 (= 6.12.111-1) but 6.12.113-1 is to be
# installed' whenever the running kernel is not the newest in the archive.
apt-get install -y build-essential linux-headers-$(uname -r) linux-source-6.12
tar -xf /usr/src/linux-source-6.12.tar.xz && cd linux-source-6.12
patch -p1 < phase88-fix.patch          # applied with offsets only, no rejects
# copy sound/pci/ice1712 out, add a 5-line Makefile, then:
make -C /lib/modules/$(uname -r)/build M=<that dir> modules -j$(nproc)
# 0 warnings, 0 errors; vermagic: 6.12.111+deb13-amd64 SMP preempt mod_unload modversions
```

Debian's own module contains 0 occurrences of `Line/Mic 7/8 Switch`, ours
contains 1, so the built module is genuinely the patched driver.  Kernel
upgrades mean a rebuild (`DKMS` automates it; the doc gives a `dkms.conf`).  The
two caveats: Secure Boot (this box boots legacy BIOS so an unsigned module loads
with the `OE` taint; on an EFI machine you must sign it or disable Secure Boot),
and the patch hunks in `snd_ice1712_get_eeprom()` / `snd_ice1712_capture_open()`
may need re-anchoring on a future stable release.

## 3. Do I need a custom `/etc/asound.conf`?

**One card: no.**  Pick `hw:Phase88` in QJackCtl (or `plughw:0,0` for anything
else) and there is nothing to configure.  The file exists here only to merge
two cards into one stream.

**Two cards, one JACK server: yes.**  jackd's ALSA backend opens exactly one
device (`-d`, with `-P`/`-C` to split playback and capture), so a single server
cannot span two sound cards on its own.  Two ways around it:

* the ALSA `multi` plugin (what is installed), or
* two jackd servers plus netjack (more moving parts, useful if you want the two
  racks at different sample rates — which you don't).

`/etc/asound.conf` on this box defines, and `pcm.!default` is deliberately
untouched so the desktop keeps working:

| name | shape | what it is |
|---|---|---|
| `phase88x2` | 16 capture / 16 playback | the 8 analog inputs and outputs of both cards. **This is what you want.** |
| `phase88x2all` | 24 capture / 20 playback | the above plus the 2 phantom AC'97 slots and the 2 Envy24 monitor-mix channels of each card |
| `p88x2_in`, `p88x2_out`, `p88x2all_in`, `p88x2all_out` | halves | the capture/playback legs, usable directly with `arecord`/`aplay` |

and

```
jackd -d alsa -d phase88x2 -r 48000 -p 1024 -n 2
```

Two things about that file worth knowing:

* A `multi` slave block accepts only `pcm` and `channels` — putting `rate` or
  `format` in it fails with
  `ALSA lib pcm.c:7907:(snd_pcm_slave_conf) Unknown field format`.  The
  application asks for rate and format and the plugin passes them to both cards.
* A combined device has no mixer of its own, and jackd always tries to open a
  control handle with the same name as the PCM, which produces
  `ALSA lib control.c:1575:(snd_ctl_open_noupdate) Invalid CTL phase88x2` and
  `control open "phase88x2" (No such file or directory)`.  Harmless (only the
  optional mixer access fails) but it looks like a fault, so the file also has
  `ctl.phase88x2 { type hw card "Phase88" }` and the same for
  `phase88x2all`.  With one card only, `phase88x2` cannot open at all (it
  references `hw:Phase88_1`) — delete the file or just never select it.

## 4. Do I need a custom service?

For loading the module: **no**.  `depmod -a` plus the file in
`/lib/modules/$(uname -r)/updates/` is enough, udev/modprobe pick it up:

```
modprobe --show-depends snd_ice1712
  ... insmod /lib/modules/6.18.55/updates/snd-ice1712.ko
```

What you *do* want at boot is three small policies, and the driver cannot
provide them (the card always comes up muted, like every ICE1712):

* unmute + unity gain,
* front mic input enabled,
* the second card programmed to take the external clock (two-card setups).

Here that is one oneshot unit:

```
/etc/systemd/system/phase88-audio.service
  ExecStart=/usr/sbin/modprobe snd_ice1712
  ExecStart=/root/terratec/scripts/phase88-mixer.sh
```

`phase88-mixer.sh` (the actual policy) does, for **every** ICE1712 card it
finds in `/proc/asound/cards`:

```
Multi Playback Switch    on          Multi Playback Volume   96   (unity)
H/W Multi Capture Switch on          H/W Multi Capture Volume 96  (unity)
DAC Volume               127 (0 dB)  ADC Volume              127  (0 dB)
Line/Mic 7/8 Switch      on          <- front mic input, override with PHASE88_FRONT_MIC=off
```

and then, only if `/etc/default/phase88` asks for it and two cards exist, calls
`phase88-sync-setup.sh` to set the clock.

Worth knowing:

* It deliberately does **not** use `/var/lib/alsa/asound.state`.  The distro's
  `alsa-restore` runs earlier, so this script wins; a state file is the other
  option, but both cards report the same card id `Phase88` (the second becomes
  `Phase88_1`), which makes saved state depend on probe order.
* If you prefer no systemd unit: the same commands work from a udev `RUN+=`
  rule on `snd-card-*` add, or by hand after boot.  With one card you can skip
  all of it and unmute in `alsamixer` when you need it.

## 5. Is any of this different with one card versus two?

| piece | one card | two cards |
|---|---|---|
| patched module | required | required, both cards are the same subsystem id so the same module binds both |
| `/etc/asound.conf` | not needed | needed to run both racks in **one** JACK server |
| boot service | optional (mute + front mic) | recommended, it is what sets the clock slave every boot |
| `phase88-mixer.sh` | same code — it loops over all ICE1712 cards | same code |
| clock / sync cable | nothing to do, card runs on its own oscillator (`Multi Track Internal Clock` = 9 = 48000) | master stays on 9, slave goes to 13 = `IEC958 Input`, which is what the cable feeds |
| JACK device name | `hw:Phase88` | `phase88x2` |

`/etc/default/phase88` is the single place where the difference is expressed:

```
PHASE88_SYNC_MASTER=1      # card that puts its clock on the cable
PHASE88_SYNC_SLAVE=0       # card that takes it; leave empty with one card
PHASE88_FRONT_MIC=on
```

`phase88-sync-setup.sh --show` prints the current state, `--off` puts any card
found on `IEC958 Input` back on its own oscillator.  It **refuses** to change a
clock while a stream is running, and says so, because
`snd_ice1712_set_pro_rate()` (ice1712.c:976-981) silently drops the write while
playback or capture is active — `amixer` still reports success, which is a
nasty way to find out.

## 6. Two-card clocking: what was measured, and the one trap

The 2-pin sync header *does* carry the clock.  Proving it needed more than a
frequency comparison: two cards of the same model sit within a few ppm of each
other (0.78 ppm measured while free running) and the measurement resolution
itself is a few ppm, so "same rate" proves nothing.  The decisive test perturbs
only the master by 8 % (its `Multi Track Internal Clock` is a divider select,
44100 versus 48000):

```
phase A  master internal 48000 : master 48003.515 Hz   slave 48003.810 Hz
phase B  master 44100          : master 44101.206 Hz   slave 44101.360 Hz
         master moved -81292 ppm, slave moved -81295 ppm
```

The slave followed a clock it does not generate.  Tools:
`scripts/phase88-clock-measure.sh` (least-squares fit of `hw_ptr` vs DMA
timestamp from `/proc/asound/cardN/pcm0c/sub0/status`),
`scripts/phase88-sync-follow.sh` (the perturbation test),
`scripts/phase88-sync-probe.sh`.

Two facts that cost hours:

* `PCI` config byte `0x60` bit `0x80` (`ICE1712_CFG_EXT`) is **not** a word-clock
  input.  Setting it makes a card programmed for 48000 run at 44101 Hz on both
  cards, even one whose sync input is unconnected: it selects an on-board
  22.5792 MHz oscillator family.  Do not use it for sync (it is however a handy
  way to deliberately move a card's clock by 8 % for tests).
* A card set to `IEC958 Input` with an **empty** clock input does not stall: it
  free-runs at about 33168 frames/s (0.69x).  So if you unplug the sync cable,
  run `phase88-sync-setup.sh --off` (or clear `PHASE88_SYNC_SLAVE`) — otherwise
  everything looks alive while the sample clock is a lie.

## 7. JACK, QJackCtl and Reaper

QJackCtl settings for two cards:

```
Settings -> Driver:     alsa
          Device Name:  phase88x2          <- type it, the list only offers hw: cards
          Sample rate:  48000
          Period size:  1024   (512 works too; 1024 measured 0 xruns)
          Periods:      2
          Realtime:     on
          Options:      -n 2
```

Verified on this box: 16 capture + 16 playback ports, 0 xruns, both cards
`RUNNING` under one `owner_pid`, and a full-duplex signal test where a 997 Hz
tone at -6 dBFS into `playback_1` (slave card) and `playback_11` (master card)
came back on each card's monitor mix at -6.0 dBFS peak / -10.1 dBFS rms.

Port map for `phase88x2`:

| JACK ports | card | which rack |
|---|---|---|
| `capture_1..8`, `playback_1..8` | `hw:Phase88` (card 0, PCI 03:01.0) | the newer board, clock slave |
| `capture_9..16`, `playback_9..16` | `hw:Phase88_1` (card 1, PCI 03:02.0) | the original board + rack, clock master |

For one card, or with `phase88x2all`, the per-card channel layout is:

```
capture 1..8    the eight analog inputs   <- your real sources
capture 9/10    phantom AC'97 capture, silent (no AC'97 codec on this board)
capture 11/12   Envy24 digital monitor mix (useful, but feeding it back into a
                record channel makes a feedback loop)
playback 1..8   eight analog outputs, 9/10 digital
```

Reaper: `Options -> Preferences -> Audio -> Device`: JACK / `system`, then per
track `Input: JACK In 1..16`, arm the track and turn on input monitoring.  Do
not pick input 9/10 per card (silent) and be deliberate about 11/12 (monitor
mix).

MIDI in JACK needs a backend: jackd's `-X seq|raw` option.  `-X seq` gives one
JACK MIDI port per ALSA sequencer client (so one per card here), `-X raw` one
per raw ALSA device.  Without `-X` you get audio only.

Handy scripts (all in `/root/terratec/scripts/`):

| script | what it does |
|---|---|
| `phase88-jack-meter.sh` | levels of the card's capture ports **through JACK**, so you can test inputs while your session keeps running; `--selftest` injects a sine into the monitor loop |
| `phase88-jack-io` | `--sine <port>...` injects 997 Hz / -6 dBFS, `--record <sec> <port>...` prints peak/rms in dBFS |
| `phase88-loopback.sh` | raw ALSA loopback test; refuses and tells you to stop JACK first, because the card is busy |
| `phase88-mixer.sh` | the boot defaults, runnable any time |
| `phase88-verify.sh`, `phase88-cycle.sh` | full driver verification / unload-reload cycle |
| `phase88-clock-measure.sh`, `phase88-sync-setup.sh`, `phase88-sync-follow.sh`, `phase88-sync-probe.sh` | clock and sync |
| `phase88-midi-test.sh` | MIDI loopback / cross-card test (needs a cable) |
| `phase88-linemic-probe.sh`, `phase88-mic-talk-test.sh` | which input pair the mic switch really moves |

## 8. MIDI

What Linux sees today, one port per card:

```
$ amidi -l
Dir Device    Name
IO  hw:0,0    TerraTec Phase88 MIDI
IO  hw:1,0    TerraTec Phase88 MIDI
```

(`ICE1712_CFG_2xMPU401` is bit `0x20` of the EEPROM `Codec` byte, which reads
`0x0f` raw on this card, so the driver creates only the first UART.  The
Terratec Windows driver installs **two**: `[PHASE88.Interface.Midi1]` and
`[PHASE88.Interface.Midi2]`, "PHASE88 MIDI Port 1/2", in
`driver/windows2000_vista_xp/ews88wdm.inf`, whose history says
`17-Sep-02 - Mic28 Extensions (Midi 2)`.)

Both UARTs are inside the Envy24, so the second one can be registered by hand
with a driver parameter (an experiment of ours, off by default, see the
`RFC/DO-NOT-SUBMIT` commit "add a mpu401_2 parameter"):

```
# /etc/modprobe.d/phase88.conf
options snd_ice1712 mpu401_2=1
```

After a reboot (or `rmmod snd_ice1712 && modprobe snd_ice1712`) `amidi -l`
then lists four ports on a two-card box - `hw:0,0 hw:0,1 hw:1,0 hw:1,1`.
Whether the extra DIN connector on the rack is wired to that second UART is a
hardware question the table below answers.  If it is not wired, delete
`/etc/modprobe.d/phase88.conf` again: an unconnected input on a shared
interrupt line is only noise.

What is proven: the rawmidi devices open, a `SysEx` payload written with
`amidi -s` is accepted by the driver (no error, correct byte count), the
sequencer shows `TerraTec Phase88 MIDI` on both cards (clients 16 and 20).

What is **not** proven without a cable: that the DIN connectors are wired to
those UARTs.  The driver happily accepts writes into an unconnected port.  To
test, loop a cable and run:

It sends a byte-exact `SysEx` frame three times and compares what came back,
and it warns when jackd or PipeWire hold the port (exclusive use gives `EBUSY`,
which is not a hardware fault).  JACK is not needed for ALSA MIDI apps
(`aconnect`, `aplaymidi`, `arecordmidi`, hydrogen, ...).

### the test matrix

One cable is enough for all of it, as long as you move it.  `hw:X,0` is the
UART Linux registers by default, `hw:X,1` the one that appears with
`mpu401_2=1`:

| # | cable | command | what a PASS proves |
|---|-------|---------|--------------------|
| 1 | rack A `OUT` -> rack A `IN` | `phase88-midi-test.sh hw:0,0` | the DIN pair of that rack is wired, port 1 works |
| 2 | same cable, unchanged | `phase88-midi-test.sh hw:0,0 hw:0,1` | the rack's `IN` is really UART 2 (so the two DINs are swapped vs Linux) |
| 3 | same cable, unchanged | `phase88-midi-test.sh hw:0,1 hw:0,0` | the rack's `OUT` is really UART 2 |
| 4 | same cable, unchanged | `phase88-midi-test.sh hw:0,1` | both connectors are on UART 2, port 1 is dead |
| 5 | rack A `OUT` -> rack B `IN` | `phase88-midi-test.sh --cross hw:0,0 hw:1,0` | the two racks talk to each other |
| 6 | keyboard/synth -> any rack `IN` | `phase88-midi-test.sh --watch hw:0,0 15` | "does Linux see my keyboard", and on which port |

Run 1 is the one that matters: if it passes, MIDI works and the rest is only
about which of the two UARTs each socket uses.  A `NO DATA RECEIVED` after run
1 with a known-good cable means that DIN is not wired to the Envy24 at all -
the driver side is already proven by the fact that `amidi` reports no error
while sending.

For JACK MIDI (Reaper, ...), jackd needs a MIDI backend, which it does not
enable by default:

```
jackd -d alsa -d phase88x2 -r 48000 -p 1024 -X seq     # one JACK MIDI port per sequencer port
jackd -d alsa -d phase88x2 -r 48000 -p 1024 -X raw     # one per raw ALSA MIDI device
```

In QJackCtl that is the "Enable ALSA MIDI" option (it maps to `-X seq`).  With
`-X seq` you get one `system:Midi` port per card, with `-X raw` two per card
once `mpu401_2=1` is set.  `aconnect -l` shows what the sequencer sees.

## 9. Troubleshooting

| what you see | what it means |
|---|---|
| `AK4524 chip select failed` in `dmesg` even though the card works | stale messages from the distro module, which is tried before the patched one wins.  Check the timestamps (`journalctl -k -b`) — what matters is the state after `TerraTec Phase88 at 0x..., irq ...` |
| QJackCtl does not offer `phase88x2` | its device list is a probe of `hw:` cards; type the name into 'ALSA Device Name' |
| `Invalid CTL phase88x2` | fixed by the `ctl.` alias in `/etc/asound.conf`; harmless either way |
| xrun counter runs away, CPU high, audio still fine | a **dead client** still registered (any tool that exits without `jack_client_close()`).  One of my test clients did this 12103 times at 35 % CPU.  Restart the server; the hardware has nothing to do with it |
| `Failed to connect to session bus for device reservation ... Audio device hw:... cannot be acquired` | jackd started from systemd/ssh with no dbus session.  `export JACK_NO_AUDIO_RESERVATION=1` (QJackCtl on the desktop is unaffected) |
| clock change had no effect | a stream was running (`snd_ice1712_set_pro_rate()` returns early while playback/capture is active).  Stop JACK first; `phase88-sync-setup.sh` refuses loudly for exactly this reason |
| card alive but everything 0.69x too slow | it is on `IEC958 Input` with no clock present: cable unplugged or master not driving SYNC OUT |
| a client stuck in `D` state, module will not unload | usually an oops taken while holding the sound core `register_mutex`.  Never `rmmod -f` here (it can block inside `snd_card_free()`); reboot is the only clean exit.  All test scripts therefore wrap ALSA calls in `timeout` |
| capture is exact zeros on all 8 inputs | the page `0x03` bug, i.e. an unpatched or older module |
| front mic silent, rear fine | `Line/Mic 7/8 Switch` off (the boot script turns it on; `PHASE88_FRONT_MIC=off` disables that) |
| qjackctl crashes when you kill its jackd | observed (`segfault at 3`); close QJackCtl before killing the server |

Unrelated noise in `dmesg` that can still cost you an xrun: the built-in 4-slot
card reader spams `ata4: device not ready (errno=-16), forcing hardreset` about
once a minute (799 times since boot at the time of writing), each costing ~5 s
of dead ATA link.  Kernel command line `libata.force=4:nonexistent` would
silence it; not applied because that is the user's card-reader slot.

## 10. Known gaps / open work

* `Line/Mic 7/8 Switch` is measured but not fully understood: bit `0x10` of
  expander page `0x03` gives +28 to +33 dB on channels 7/8 and nothing
  measurable on the other pairs.  Whether it is a **mux** (front versus rear) or
  a **preamp enable** decides its final name: if a signal on REAR input 7
  disappears when the switch is on it should become an enumerated
  `Input Source 7/8` = `Rear Aux` / `Front Mic` (the Windows control is called
  "Mic InputSel").  Test: feed rear input 7 and toggle.
* Only bit `0x10` of page `0x03` is known.  Bits `0x01/0x02/0x04/0x08` are
  untested; the OS9 control panel (`driver/os9/Applications/Phase88 Control
  Panel.app`) exposes `Line/Mic 1/2 ... 7/8`, `Mic 2/8 Settings`,
  `SetInputLevelSwitch`, `GainLevels` and a system clock source select
  (`Get/SetSysClockSource`, `Mic28ClockSourceChanged`) for the EWS88 family, and
  the PHASE 88 has no per-pair equivalents in Linux.
* Page `0x01` bit `0x20` is load-bearing: clearing it kills the AK4524 data path
  permanently until the codecs are re-initialised (it is the codec
  power/reset enable).  Bits `0x10`, `0x40`, `0x80` of page `0x01` have no
  measurable audio effect, including as candidates for a 'sync out enable'.
* Sample-accurate offset between the two cards has never been measured (needs
  one patch cable for a click test).
* Second MIDI port (see above).
* Nothing is submitted upstream yet: the 5-commit series plus
  `/root/terratec/analysis/README.md` are kept submission-ready (checkpatch
  clean) and the RFC debug commit stays out.
