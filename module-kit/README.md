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
mkdir -p /tmp/p88b && cp /root/terratec/module-kit/* /tmp/p88b/
make -C /lib/modules/$(uname -r)/build M=/tmp/p88b modules -j$(nproc)
```

Or use the wrapper, which also installs, runs `depmod` and checks that
`modprobe` picks the result:

```sh
/root/terratec/scripts/phase88-module-install.sh            # running kernel
/root/terratec/scripts/phase88-module-install.sh --kver=6.12.111+deb13-amd64
/root/terratec/scripts/phase88-module-install.sh --check    # status only
```

Measured on this box:

| kernel built against | result |
|---|---|
| `6.18.55` (custom, `/lib/modules/6.18.55/build` = the source tree) | 10 s, `md5 8dcc5dac196de1b6ebf319cbe6bf5209`, then **installed and verified**: `phase88-verify.sh` passes on card 0 (clock slave, 48 kHz) and card 1 (master, 44.1/48/96 kHz all RUNNING) |
| `6.12.111+deb13-amd64` (stock Debian headers) | 10 s, 0 warnings, vermagic matches |

`md5` differs from a build made inside the kernel tree (`6cf98eec...`) because the
build directory is baked into the object; the source is identical.

## Provenance - this directory is the source now

Copied from branch `phase88-alt-single` at commit `2e145dfc9`.  The 25 G kernel
tree they came from was **deleted on 2026-10-21** (option A in `../archive/README.md`),
so the kit is no longer a copy of something else: it is where the driver source
lives day to day, with the history in `../archive/` and the mail-form patches in
`../upstream/`.  Get a full tree back with either
`git clone /root/terratec/archive/phase88-full-history.bundle -b phase88-alt-single`
or the tarball + `git am` (recipe in `../archive/README.md`).

### This kit is the diagnostic build, not the submission build

`2e145dfc9` is the RFC commit **on top of** the six submission commits, so the kit
carries the bring-up debug controls: +99 lines, all in `ews.c` (`ews.h` and
`ice1712.c` are byte-identical to the submission set, diffed 2026-10-21).  Tell
the two builds apart without opening the source:

```sh
strings snd-ice1712.ko | grep -c 'Phase88 Debug Expander'   # 2 = this kit, 0 = submission set
strings snd-ice1712.ko | grep -c 'Line/Mic 7/8 Switch'      # 1 in both
amixer -c 0 contents | grep -c '^numid'                     # 84 = this kit, 81 = submission set
```

The prebuilt modules in `../install/modules/` are the same diagnostic build: the
clock work and the expander measurements needed the two raw register controls, and
on this machine the sound core must not be reloaded casually (an oops inside
`snd_pcm_open()` once wedged `register_mutex` until reboot).  Those three extra
controls are `iface=CARD`, do not touch audio and are not part of what gets sent
to the list.

To build **exactly** the submission set (e.g. to double-check that the patch
applies and compiles on its own):

```sh
tar -xf /root/terratec/kernel/linux-6.18.55.tar.xz
cd linux-6.18.55 && git init -q . && git add -A && git commit -qm base
git am /root/terratec/upstream/alt-single-switch/series/000[1-6]-*.patch    # verified clean 2026-10-21
make -C /lib/modules/$(uname -r)/build M=$PWD/sound/pci/ice1712 modules
```
