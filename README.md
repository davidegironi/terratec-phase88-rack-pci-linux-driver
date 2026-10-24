# TerraTec PHASE 88 on Linux

The PHASE 88 (`1412:1712`, subsystem `153b:1151`) does not work with a stock
Linux driver: it probes, fails with `AK4524 chip select failed, check cable to
the front module` and disappears. This repository contains the driver fix, the
hardware investigation and evidence, installation policy, test tools, and the
vendor drivers used as references.

**Start here:** [`install/PHASE88-GUIDE.md`](install/PHASE88-GUIDE.md) — quick
start, what the patch fixes, one card versus two, JACK/Reaper setup, MIDI, and
troubleshooting.

## Folder map

| path | contents |
|---|---|
| `install/` | Deployment material: [`PHASE88-GUIDE.md`](install/PHASE88-GUIDE.md), [`README.md`](install/README.md), `debian-stock-kernel.md`, `/etc` configuration and service files, the Debian kernel-update hook, and prebuilt modules with their `modinfo` records. |
| `module-kit/` | The out-of-tree `snd-ice1712` source: `ice1712.c/.h`, `ews.c/.h`, `delta.c/.h`, `hoontech.c/.h`, and `Makefile`. [`README.md`](module-kit/README.md) explains the source, build, and diagnostic-versus-submission versions. |
| `scripts/` | Setup, install, verification, PCM/JACK, clock-sync, MIDI, and hardware diagnostic tools. [`README.md`](scripts/README.md) documents each tool and its requirements. Paths under `scripts/` are referenced by service configuration; do not rename the directory. |
| `analysis/` | Investigation notes and evidence: [`README.md`](analysis/README.md), original-failure captures in `baseline/`, Windows/Mac disassemblies, the RFC debug-controls patch, and work-in-progress patch material. |
| `upstream/` | Patch submission materials: `alt-single-switch/series/` (recommended six-patch series with one Line/Mic switch), `series/` (six-patch four-switch alternative), cover letters, `phase88-fix.patch` (combined diff), `CHANGED-FILES.md`, `HOWTO-send-the-patches.md`, and commit-message files in `msg/`. |
| `archive/` | Git bundle backups and restore/retention instructions in [`README.md`](archive/README.md). The full-history bundle is a separate backup; the smaller bundles contain the development commits. |
| `driver/` | Windows and Mac OS 9 vendor driver and control-panel references used during reverse engineering. [`README.md`](driver/README.md) describes the relevant files and findings. These are reference materials, not Linux driver code. |
| `kernel/` | `linux-6.18.55.tar.xz`, the kernel source tarball used by the custom-kernel work. The extracted 25 GB build tree was removed; see [`archive/README.md`](archive/README.md) for restoration instructions. |
| `logs/` | Captured verification, boot, clock, and synchronization test logs referenced by the scripts and investigation notes. Keep this directory in place. |

## Key files

| file | contents |
|---|---|
| `install/etc/asound.conf` | Optional ALSA device definitions for using two PHASE 88 cards under one JACK server. |
| `install/etc/default/phase88` | Card clock-master/slave roles and front-input policy for the mixer service. |
| `install/etc/systemd/system/phase88-audio.service` | Boot-time module and mixer policy service. |
| `install/etc/kernel/postinst.d/phase88-oot` | Debian kernel post-install hook that rebuilds and installs the out-of-tree module when headers are available. |
| `install/modules/` | Compressed module builds for the custom 6.18.55 kernel and Debian 6.12.111, plus module metadata and an out-of-tree Makefile example. |
| `scripts/phase88-module-install.sh` | Builds and installs `module-kit/` for a selected kernel version, then verifies module resolution. |
| `scripts/phase88-install-policy.sh` | Installs the policy files from `install/etc/` and can install a supplied module. |
| `scripts/phase88-verify.sh` | Runs the hardware/driver verification checks; see `scripts/README.md` for invocation and prerequisites. |
| `upstream/alt-single-switch/series/` | Recommended mail-form patch series. The alternative `upstream/series/` has four Line/Mic controls instead of one. |
| `analysis/0001-RFC-DO-NOT-SUBMIT-ASoC-ice1712-bring-up-controls-for.patch` | Bring-up/debug-controls patch; it is diagnostic material, not part of either six-patch series. |
