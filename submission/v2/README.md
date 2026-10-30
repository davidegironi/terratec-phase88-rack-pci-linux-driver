# PHASE 88 v2 patch set

`0001-*.patch` is the preliminary ICE1712 `eeprom_init` callback/refactor;
`0002-*.patch` applies the PHASE 88-specific changes on top. The
`phase88-v2-combined.patch` is the same result as one combined diff. The
cover letter is `0000-cover-letter.txt`.

The patches were generated against the four ICE1712 files from Linux
6.18.58 and verified to apply in order with `git am`.

## Local verification

- Before the source changes, `scripts/phase88-verify.sh 0` and `1` both
  passed on the already-loaded driver (at that point HDMI was not enumerated
  before the PHASE 88 cards).
- After the changes, `scripts/phase88-install-module.sh --dry-run` built the
  module for `6.12.113+deb13-amd64`; `scripts/phase88-install-module.sh
  --reload` installed and loaded it; `scripts/phase88-verify.sh 1` and `2`
  both passed again (card 0 is now HDMI).
- The exact non-diagnostic source files from the 6.18.58 tree also compiled
  as an external module against the running 6.12.113 kernel headers.
- The full verification found no AC'97/chip-select errors or kernel oops;
  the expected multitrack PCM devices appeared without consumer PCM devices,
  and both cards passed playback/capture DMA checks. The slave card's 44.1
  and 96 kHz playback skips are expected under external clock lock.
- The installable `module-kit` excludes the RFC write-only expander and
  codec-init controls; those can change hardware state and are not for normal
  use. Systems still running an older diagnostic module need a safe reload
  before those controls disappear. The module currently loaded on the test PC
  was reloaded and no longer exposes them.
- `checkpatch.pl --no-tree --strict` reports the missing contributor's own
  `Signed-off-by` trailer on each patch and one CamelCase check for the
  existing `ICE1712_CFG_2xMPU401` macro. Add your own sign-off before sending;
  it is deliberately not supplied here.

The MIDI loopback test was not rerun in this pass. The PHASE 88 MIDI EEPROM
bit is unchanged; its handling was relocated to the early EWS callback.

A review pass found a generic null-codec failure path for boards whose EEPROM
advertises consumer AC'97 but whose codec initialization fails. The revised
series keeps a defensive `-ENODEV` check in consumer capture open while the
early PHASE 88 EEPROM fixup prevents its consumer PCM from being created.
