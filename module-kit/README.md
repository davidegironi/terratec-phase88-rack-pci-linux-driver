# The whole driver, as 8 files

`snd-ice1712` is built from exactly four objects (from `sound/pci/ice1712/Makefile`
in the kernel tree):

```
snd-ice1712-y := ice1712.o delta.o hoontech.o ews.o
```

so the driver, including every PHASE 88 fix, is these 8 files plus a 2-line
Makefile - **212 KB**.  Everything else in the 25 G kernel tree is needed only to
compile *some other* part of the kernel.

```
module-kit/
├── ice1712.c ice1712.h     Envy24 core: PCM, clocks, EEPROM fixup (3 PHASE 88 changes)
├── ews.c     ews.h         EWS88/PHASE 88 board code (chip select, expander, Line/Mic)
├── delta.c   delta.h       the other board file linked in (unmodified)
├── hoontech.c hoontech.h   ditto
└── Makefile                obj-m += snd-ice1712.o / snd-ice1712-y := ...
```

## Build it (10 seconds)

Needs the *build* tree of the kernel you want to run it on: Debian provides it
as `linux-headers-<version>`, a hand-built kernel has
`/lib/modules/<version>/build` pointing at its source tree.

Build in a copy, so this directory stays clean (`.o`, `.ko`, `Module.symvers`
litter the module directory):

```sh
mkdir -p /tmp/p88b && cp module-kit/* /tmp/p88b/
make -C /lib/modules/$(uname -r)/build M=/tmp/p88b modules -j$(nproc)
```

Or use the wrapper, which also installs, runs `depmod` and checks that
`modprobe` picks the result:

```sh
scripts/phase88-install-module.sh            # running kernel
scripts/phase88-install-module.sh --kver=6.12.113+deb13-amd64
scripts/phase88-install-module.sh --check    # status only
```

Measured on this box:

| kernel built against | result |
|---|---|
| `6.12.113+deb13-amd64` (stock Debian headers) | Clean build and reload; `phase88-verify.sh 1` (clock slave, 48 kHz) and `phase88-verify.sh 2` (master, 44.1/48/96 kHz) passed playback/capture DMA checks; no AC'97 errors, oops, or debug controls |

The Linux 6.18.58 source files were also compiled as an external module against
these running 6.12.113 headers.

## Provenance - this directory is the source now

Copied from branch `phase88-alt-single` at commit `2e145dfc9`.  The 25 G kernel
tree they came from was **deleted on 2026-10-21** (option A in `../archive/README.md`),
so the kit is no longer a copy of something else: it is where the driver source
lives day to day, with the history in `../archive/` and the mail-form patches in
`../upstream/`.  Get a full tree back with either
`git clone /root/terratec-phase88-rack-pci-linux-driver/archive/phase88-full-history.bundle -b phase88-alt-single`
or the tarball + `git am` (recipe in `../archive/README.md`).

### Installable kit and diagnostic controls

This kit is the installable PHASE 88 driver source. The RFC write-only
expander/codec-init controls have been removed: they can modify hardware state
and are not appropriate for a normal installation. A previously loaded module
continues to expose them until the driver is safely reloaded or the machine is
rebooted.

Check a built module for the debug controls and the user-facing switch:

```sh
strings snd-ice1712.ko | grep -c 'Phase88 Debug'       # should be 0
strings snd-ice1712.ko | grep -c 'Line/Mic 7/8 Switch' # should be 1
```

`module-kit/ice1712.c` uses `snd_card_unref` for compatibility with the running
6.12 headers; the corresponding 6.18.58 source uses the newer `snd_card_free`
cleanup annotation. The PHASE 88 EEPROM callback, capture safety check, and EWS
controls otherwise match the revised source. The complete v2 patch series is in
`../submission/v2/`.
