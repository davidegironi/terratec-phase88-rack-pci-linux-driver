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

## Where these files came from

Copied from branch `phase88-alt-single` of `/root/terratec/kernel/linux-6.18.55`
at commit `2e145dfc9` (the 6 submission commits + the RFC commit on top).  To
refresh them after working in the tree:

```sh
git -C /root/terratec/kernel/linux-6.18.55 checkout phase88-alt-single
cp /root/terratec/kernel/linux-6.18.55/sound/pci/ice1712/{ice1712,ews,delta,hoontech}.{c,h} \
   /root/terratec/module-kit/
```

If you start from a **pristine** tree instead (kernel.org tarball, `linux-source`),
apply the series first: `git am /root/terratec/upstream/alt-single-switch/series/000[1-6]-*.patch`.
