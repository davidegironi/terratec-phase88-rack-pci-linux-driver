# PHASE 88 driver on a **stock** Debian kernel — no full kernel rebuild

Short answer: **you do not recompile the kernel.**  The patch touches only
`sound/pci/ice1712/{ice1712.c,ews.c,ews.h}` — no exported headers, no Kbuild
plumbing — so the driver can be rebuilt out-of-tree against the `linux-headers`
package of whatever kernel you boot, dropped into
`/lib/modules/$(uname -r)/updates/` and picked up by depmod/udev.

## Proof, run on this machine on 2026-10-18

Target was Debian's own stock kernel that is installed next to our 6.18.55:
`6.12.111+deb13-amd64` (`/boot/vmlinuz-6.12.111+deb13-amd64` exists, and its
stock `snd-ice1712.ko.xz` is the *unpatched* driver).

| check | result |
|---|---|
| patch series vs Debian 6.12.111 source | applied with **no rejects**, only line offsets: `ews.c` hunks `+5`, `ice1712.c` hunks `+7` and `+26` |
| build | `0` warnings, `0` errors, ~20 s with `-j8` |
| resulting module | `vermagic: 6.12.111+deb13-amd64 SMP preempt mod_unload modversions` |
| patched feature really inside | `strings snd-ice1712.ko \| grep -c 'Line/Mic 7/8 Switch'` → **1** (Debian's stock module: **0**) |
| module dependencies | `snd,snd-i2c,snd-ice17xx-ak4xxx,snd-mpu401-uart,snd-pcm,snd-ak4xxx-adda,snd-ac97-codec,snd-cs8427` — identical to the 6.18 build, all shipped by Debian |
| compiler | Debian's kernel says `CONFIG_CC_VERSION_TEXT="x86_64-linux-gnu-gcc-14 (Debian 14.2.0-19) 14.2.0"`; our `gcc` is exactly 14.2.0, so no compiler mismatch |

Everything below is what actually ran (as root).  The build products are in
`/root/terratec/build-oot/`; nothing of this touched the live sound setup.

## 1. Get headers and source

```sh
uname -r                                   # e.g. 6.12.111+deb13-amd64
apt-get update
apt-get install -y build-essential "linux-headers-$(uname -r)"
apt-cache policy linux-source-6.12         # 6.12 = first two numbers of uname -r
apt-get install -y linux-source-6.12       # unpacks /usr/src/linux-source-6.12.tar.xz
```

Notes from the real run:

* The kernel-source *metapackage* is `linux-source`, the real one is
  `linux-source-6.12`.  `apt-get install linux-source=6.12.111-1` fails with
  `unmet dependencies ... but 6.12.113-1 is to be installed`; pin the versioned
  package instead (`linux-source-6.12=6.12.111-1`) or do not pin at all.
* The source does **not** have to be the same patch level as the running kernel
  for an out-of-tree build; the headers provide the build system and
  `Module.symvers`.  I used `6.12.111-1` to match exactly.
* `linux-headers-$(uname -r)` is what creates `/lib/modules/$(uname -r)/build`.

## 2. Apply the patch

```sh
mkdir -p ~/p88 && cd ~/p88
tar -xf /usr/src/linux-source-6.12.tar.xz
cd linux-source-6.12
patch -p1 --dry-run < /path/to/phase88-fix.patch    # look at the offsets first
patch -p1           < /path/to/phase88-fix.patch
```

`phase88-fix.patch` is the combined clean series (5 commits, 313 lines, files
`sound/pci/ice1712/{ice1712.c,ews.c,ews.h}`).  On this box it printed:

```
patching file sound/pci/ice1712/ews.c
Hunk #3 succeeded at 609 (offset 5 lines).
Hunk #4 succeeded at 1161 (offset 5 lines).
patching file sound/pci/ice1712/ews.h
patching file sound/pci/ice1712/ice1712.c
Hunk #1 succeeded at 775 (offset 7 lines).
Hunk #2 succeeded at 2319 (offset 26 lines).
```

If you prefer the individual commits (`git am`, `git format-patch` order):
`0001` chip-select expander address, `0002` capture_open NULL guard,
`0003` no consumer AC'97, `0004` second expander register,
`0005` Line/Mic switches.  The `RFC/DO-NOT-SUBMIT` bring-up controls commit is
not part of it and is only useful for reverse-engineering the expander.

If a future kernel moves that code, the two hunks most likely to reject are the
quirk inside `snd_ice1712_get_eeprom()` (the `ICE1712_CFG_NO_CON_AC97` line) and
the `if (!ice->ac97) return -ENODEV;` guard in `snd_ice1712_capture_open()`.
Both are small and mechanical.

## 3. Build just that directory

Copy the patched directory out and give it a Makefile (the in-tree one keys on
`obj-$(CONFIG_...)` and would also build the ICE1724 family):

```sh
mkdir -p ~/p88/ice1712-oot
cp -a ~/p88/linux-source-6.12/sound/pci/ice1712/. ~/p88/ice1712-oot/
cat > ~/p88/ice1712-oot/Makefile <<'EOF'
# SPDX-License-Identifier: GPL-2.0
# Out-of-tree build of the PHASE 88 driver for a stock kernel.
# Trimmed from sound/pci/ice1712/Makefile: ICE1712 only, obj-m directly.
snd-ice17xx-ak4xxx-y := ak4xxx.o
snd-ice1712-y := ice1712.o delta.o hoontech.o ews.o
obj-m += snd-ice1712.o snd-ice17xx-ak4xxx.o
EOF

make -C "/lib/modules/$(uname -r)/build" M="$HOME/p88/ice1712-oot" modules -j"$(nproc)"
```

Output ends with `snd-ice1712.ko` and `snd-ice17xx-ak4xxx.ko`, `BTF` step
included, no diagnostics.

## 4. Install so it wins over the distro module

```sh
install -D -m 0644 ~/p88/ice1712-oot/snd-ice1712.ko \
        "/lib/modules/$(uname -r)/updates/snd-ice1712.ko"
depmod -a "$(uname -r)"
modprobe --show-depends snd_ice1712        # must print insmod .../updates/snd-ice1712.ko
```

Only `snd-ice1712.ko` needs installing — `ak4xxx.c` is not part of the patch, so
Debian's own `snd-ice17xx-ak4xxx.ko` is still correct.  `updates/` beats
`kernel/...` in depmod's search order, which is what makes this stick without
blacklisting.

Reload without a reboot (this is exactly the cycle
`/root/terratec/scripts/phase88-cycle.sh` automates):

```sh
# anything holding the card must go first: jackd, and PipeWire/wireplumber
systemctl --user stop pipewire pipewire-pulse wireplumber 2>/dev/null
pkill -x jackd
rmmod snd_ice1712 && modprobe snd_ice1712
amixer -c 0 cget name='Line/Mic 7/8 Switch'      # proves the new module is in
```

Never `rmmod -f`.  If an oops happened inside a sound-core path, the core
`register_mutex` can stay held and the module is unloadable until reboot; that
has happened on this machine (a stuck `aplay` in `D` state in
`snd_pcm_control_ioctl+0x19c`).

## 5. Surviving kernel upgrades

Every kernel update needs a rebuild, because `vermagic` must equal `uname -r`.
Two options:

* **DKMS** (automates the rebuild on every `linux-image-*` install):

  ```
  /usr/local/src/p88-ice1712/
      dkms.conf
      src/            <- the patched sound/pci/ice1712 directory + the Makefile above
      patch-<ver>.patch
  ```
  with a `dkms.conf` like:

  ```
  PACKAGE_NAME=p88-ice1712
  PACKAGE_VERSION=1.0
  BUILT_MODULE_NAME[0]=snd-ice1712
  DEST_MODULE_LOCATION[0]=/updates
  AUTOINSTALL="yes"
  MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
  CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
  ```
  then `dkms install p88-ice1712/1.0`.  Not installed on this box; the patch was
  written against one kernel and each new stable may need the two hunks above
  re-checked, which is the honest argument against blind `AUTOINSTALL`.

* **A rebuild script** you run after a kernel update — the commands in sections
  1-4 are already idempotent; wrap them and check `patch --dry-run` output
  before building.

## 6. When you *would* rebuild the whole kernel

Almost never for this: only if you need the driver built-in (audio before the
root filesystem/initramfs), or if module loading is locked down and you would
rather build the fix in than sign a module.  In Debian that path is
`apt-get build-dep linux` + `apt-get source linux` + `debian/rules` (or
`make bindeb-pkg` on a plain clone) and takes much, much longer than section 3.

## 7. Caveats worth knowing before you tell someone it works

* **Secure Boot.**  This box boots legacy BIOS (`/sys/firmware/efi` absent), so
  the unsigned module loads with the `OE` taint and nothing else.  On an EFI
  machine with Secure Boot on, `insmod` fails with `Required key not available`
  unless you sign the module (MOK, `mokutil --import`) or turn Secure Boot off.
* Do not copy a `.ko` between kernels: `vermagic` mismatch is a hard refusal,
  and `modprobe --force-vermagic` on a sound driver is how you get the oops that
  wedges the machine.
* The driver patch is what makes the card exist at all; the *usability* part is
  userspace (unmute, front mic input, clock slave for a second card).  See
  `/root/terratec/PHASE88-GUIDE.md`: "Do I need a custom service?", "Is any of this
  different with one card versus two?" and "Two-card clocking".
* Verified working on 6.18.55 (built from source, two cards, JACK) — and *built
  but not booted* on Debian stock `6.12.111+deb13-amd64`, because this machine
  is running 6.18.55 and the point of the exercise was the build recipe, not a
  reboot into a second kernel.  If you want, boot the Debian kernel and we test
  it for real.
