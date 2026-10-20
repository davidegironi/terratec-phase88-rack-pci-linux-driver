# Files changed

## 1. The kernel patch itself (what goes to the mailing list)

Three files, all under `sound/pci/ice1712/`, 224 insertions / 3 deletions over
six commits - the numbers below are the **recommended** set, branch
`phase88-alt-single` (one `Line/Mic 7/8 Switch`):

```
sound/pci/ice1712/ews.c     | 163 +++++++++++++++++++++++++++++++++++++++++++-
sound/pci/ice1712/ews.h     |  26 ++++++
sound/pci/ice1712/ice1712.c |  38 ++++++++-
3 files changed, 224 insertions(+), 3 deletions(-)
```

The older four-control variant (branch `phase88`) is the same work at 253
insertions, patch 0005 registering `Line/Mic 1/2 ... 7/8 Switch` instead of one.

Per commit (`git log --stat 941c14e58..HEAD~1` on `phase88-alt-single`, in
`/root/terratec/kernel/linux-6.18.55`; "changed" is git's own count):

| patch | commit | file | lines | what it does there |
|---|---|---|---|---|
| 0001 | `a850b2460` | `sound/pci/ice1712/ews.c` | 61 | `snd_ice1712_phase88_chip_select()`: two-byte write `{0x01, flags \| cs_nibble}` to the expander the board really has, instead of the EWS88MT PCF8574 pair at 0x23/0x24 that does not exist here; keeps a shadow copy because the chip never returns what was written |
| | | `sound/pci/ice1712/ews.h` | 15 | `ICE1712_PHASE88_OUTPUT_ADDR (0x42>>1)`, `..._OUTPUT_PAGE 0x01`, `..._OUTPUT_INIT 0x20`, `struct ews_spec.pcf8575_data` |
| 0002 | `0ca487765` | `sound/pci/ice1712/ice1712.c` | 3 | `if (!ice->ac97) return -ENODEV;` in `snd_ice1712_capture_open()` - the consumer capture ops dereferenced `ice->ac97` unconditionally and oops'd when the codec was missing |
| 0003 | `e45d4efa2` | `sound/pci/ice1712/ice1712.c` | 16 | in the EEPROM fixup, set `ICE1712_CFG_NO_CON_AC97` in the CODEC byte for the PHASE 88 (board announces a consumer codec, the AC-Link reads `0xffff` even cold) |
| 0004 | `be5a2e0fe` | `sound/pci/ice1712/ews.c` | 53 | write the **second** expander register `{0x03, 0x00}` at init, before the codecs are set up; without it the AK4524 keep their serial outputs disabled and all eight analog inputs read zeros |
| | | `sound/pci/ice1712/ews.h` | 10 | `ICE1712_PHASE88_INPUT_PAGE 0x03`, `..._INPUT_INIT 0x00`, `struct ews_spec.pcf8575_input` |
| 0005 | `86adec099` | `sound/pci/ice1712/ews.c` | 71 | one `Line/Mic 7/8 Switch` (`snd_ice1712_phase88_linemic_ctl`, `private_value = 3` = bit `0x10`), PHASE 88 only; the EWS88MT/EWS88D keep their PCF8575 "Input Sensitivity" switches |
| | | `sound/pci/ice1712/ews.h` | 3 | (declaration) |
| 0006 | `b76e07070` | `sound/pci/ice1712/ice1712.c` | 19 | set `ICE1712_CFG_2xMPU401` for the PHASE 88 so the second MPU-401 UART - the rear MIDI socket - is registered |

**Not in the series:** the RFC commit `2e145dfc9` "RFC/DO-NOT-SUBMIT: ASoC:
ice1712: bring-up controls for the PHASE 88 expander" (+98 in `ews.c`), which
adds the three debug controls used to find the bits above (`iface=CARD`, so
`amixer cget name=...` will not find them - use `numid`). Its file is kept at
`/root/terratec/upstream/do-not-send/` for our own testing.

Canonical copies of the six patches:

| set | directory | patch 0005 |
|---|---|---|
| recommended | `/root/terratec/upstream/alt-single-switch/series/` | one switch |
| alternative | `/root/terratec/upstream/series/` | four switches |

Combined single patch for the recommended set:
`/root/terratec/upstream/phase88-fix.patch`.

## 2. Userspace this project installs (NOT part of the kernel patch)

Installed by `scripts/phase88-install-policy.sh` from `/root/terratec/install/`:

| installed path | from | purpose |
|---|---|---|
| `/etc/asound.conf` | `install/etc/asound.conf` | `phase88x2` / `phase88x2all`: the two cards as one ALSA device (16 in / 16 out). Only needed for two cards under one JACK server |
| `/etc/default/phase88` | `install/etc/default/phase88` | which card is clock master/slave, front mic input on/off |
| `/etc/systemd/system/phase88-audio.service` | `install/etc/systemd/system/phase88-audio.service` | runs `modprobe snd_ice1712` then the mixer script at boot |
| `/lib/modules/$(uname -r)/updates/snd-ice1712.ko` | built from `kernel/linux-6.18.55` (or `install/modules/`) | the patched driver |

`/etc/modprobe.d/phase88.conf` was used briefly for the `mpu401_2` experiment
and is **gone**: the second MIDI port is a quirk now, no module option.

## 3. Test and measurement tools (also not part of the patch)

`/root/terratec/scripts/` - see `scripts/README.md` for the full table. The ones
whose measurements are quoted in the commit messages:

* `phase88-verify.sh`, `phase88-cycle.sh` - probe, mixer, rates, capture sanity
* `phase88-linemic-probe.sh` - the +40.8 dB / +30.3 dB per-channel table behind
  patch 0005
* `phase88-midi-test.sh`, `phase88-midi-racks.sh` - the MIDI loopbacks behind
  patch 0006
* `phase88-midi-diag.py`, `phase88-midi-clocktest.sh` - the bit-error
  characterisation that localized the rack #2 front socket to hardware (not in
  any commit; it exonerates the driver rather than changing it)
* `phase88-clock-measure.sh`, `phase88-sync-follow.sh` - the word-clock proof
  (not in any commit: nothing in the driver was needed for it)
