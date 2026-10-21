# TerraTec PHASE 88 on Linux

The PHASE 88 (`1412:1712`, subsystem `153b:1151`) does not work with a stock
Linux driver: it probes, fails with `AK4524 chip select failed, check cable to
the front module` and disappears.  This folder holds the whole job: the driver
fix, the evidence for it, the userspace policy, the test tools and the vendor
drivers that were reverse-engineered to get there.

**Start here:** [`install/PHASE88-GUIDE.md`](install/PHASE88-GUIDE.md) - quick
start, what the patch fixes, one card versus two, JACK/Reaper setup, MIDI,
troubleshooting.

## Folder map

| path | what it is |
|---|---|
| `install/` | **everything needed to put this on a machine**: the guide, the `/etc` files (mixer service, `asound.conf`, defaults, kernel-update hook), prebuilt modules, the stock-kernel recipe. Read `install/README.md`. |
| `scripts/` | every test and setup tool (`phase88-verify.sh`, `phase88-mixer.sh`, `phase88-sync-setup.sh`, `phase88-midi-racks.sh`, ...). Path `scripts/` is referenced by the systemd unit - do not rename. |
| `kernel/` | **deleted 2026-10-21** (25 G of kernel tree, option A in `archive/README.md`). Only `linux-6.18.55.tar.xz` (148 MB) remains. The work that was in that tree lives in `module-kit/` (sources), `archive/` (git history as bundles) and `upstream/` (patches). Note `/lib/modules/6.18.55/build` is now a dangling symlink - restore recipe in `archive/README.md`. |
| `module-kit/` | the whole driver as 8 files + a 2-line Makefile (212 KB). Builds against `linux-headers-*` in ~10 s; used by `scripts/phase88-module-install.sh` and by the kernel-update hook. |
| `archive/` | the git history as bundles: two 12 KB ones (commits above the baseline, tracked in git) plus `phase88-full-history.bundle` (280 MB, self-contained, deliberately not in git), and the keep/delete + restore recipes. |
| `analysis/` | the investigation log (`README.md`, dated entries), the disassembly (`ews32.dis`, `text.dis`, `mac.dis`), and `baseline/` (the original failure capture). |
| `upstream/` | the submission package: `alt-single-switch/series/0001..0006` (recommended, one Line/Mic switch), `series/` (same six with four switches), `cover-letter.txt`, `CHANGED-FILES.md`, `HOWTO-send-the-patches.md`, `msg/` (commit messages + the rebase helper), `do-not-send/` (the RFC debug commit). **Nothing has been sent yet.** |
| `driver/` | the vendor drivers used as the reference: `win/` (Windows 5.51b + control panel) and `os/` (Mac OS 9). `driver/README.md` says which file proved what. Binaries not in this repo (9 M), the notes are. |
| `scripts/README.md` | every tool in one table, with which ones need JACK stopped and which need the RFC debug module. |
| `logs/` | run logs from the scripts (verify, cycle, postboot, clock sweeps). Referenced by the scripts - do not rename. |
| `phase88_driver_agent_handoff.md` | the original brief, kept as-is. |

## State of this machine

Two PHASE 88 racks, both on the patched module, clock-locked through the sync
cable, 16 analog in and 16 out under one JACK server:

```sh
grep ICE1712 /proc/asound/cards                  # card 0 = slave, card 1 = master
scripts/phase88-sync-setup.sh --show             # clock roles straight from the registers
scripts/phase88-midi-racks.sh --list             # the four MIDI sockets
jackd -d alsa -d phase88x2 -r 48000 -p 1024      # 16 in / 16 out
```

## Submission state

Six clean, checkpatch-clean commits are ready (`analysis/series/`), and one
RFC commit with the bring-up debug controls stays out of the series.  Nothing
has been sent to alsa-devel/kernel-dev yet - see the guide, section 10.
