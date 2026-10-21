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
| `kernel/linux-6.18.55/` | the kernel tree where the driver was fixed: branch `phase88-alt-single` (recommended) and `phase88` (four-switch variant), baseline `941c14e58`, 6 submission commits + 1 RFC. 25 G of build output that is **no longer needed** - `module-kit/`, `archive/` and `upstream/` hold the sources, the history and the binaries. Delete/prune recipe in `archive/README.md`. |
| `module-kit/` | the whole driver as 8 files + a 2-line Makefile (212 KB). Builds against `linux-headers-*` in ~10 s; used by `scripts/phase88-module-install.sh` and by the kernel-update hook. |
| `archive/` | `phase88-commits.bundle` (12 KB: the full branch history above the baseline) + the four-switch twin + the keep/delete list for the 25 G tree. |
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
