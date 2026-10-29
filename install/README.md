# Installing the PHASE 88 fix

This directory is the part you copy to another machine.

```
install/
├── PHASE88-GUIDE.md                  the guide - read this first
├── debian-stock-kernel.md            build recipe for a distro kernel (+ the proof run)
├── etc/                              the three system files, mirroring /etc
│   ├── asound.conf                   -> /etc/asound.conf
│   ├── default/phase88               -> /etc/default/phase88
│   └── systemd/system/phase88-audio.service -> /etc/systemd/system/
├── etc/kernel/postinst.d/phase88-oot  -> /etc/kernel/postinst.d/ (rebuild on kernel update)
└── modules/                          prebuilt modules + modinfo proof
    ├── snd-ice1712-6.18.55.ko.xz     the module this box runs (md5 8dcc5dac... after the kit rebuild)
    ├── snd-ice1712-6.12.111+deb13-amd64.ko.xz   (stock Debian kernel, see modinfo file)
    ├── snd-ice17xx-ak4xxx-6.12.111+deb13-amd64.ko.xz
    ├── MODINFO-stock-debian-6.12.111.txt
    ├── MODINFO-6.18.55.txt
    └── Makefile.oot-example          the 5-line out-of-tree Makefile
```

## Fastest path: script

```sh
sudo scripts/phase88-install-policy.sh                 # policy only
sudo scripts/phase88-install-policy.sh path/to/snd-ice1712.ko   # + module
```

It copies `install/etc/*` to `/etc`, installs the module into
`/lib/modules/$(uname -r)/updates/` (which depmod prefers over the distro copy),
runs `depmod -a`, rewrites the service's mixer path to wherever this repo
actually lives, and enables `phase88-audio.service`.  It refuses a module whose
`vermagic` does not match the running kernel - that check is there because
loading a mismatched sound module is how you wedge the box.  Run it with JACK
stopped; it does not start or stop audio.

To additionally start JACK automatically at desktop login, run:

```sh
sudo scripts/phase88-install-jackservice.sh
```

This installs a per-user systemd unit (not a system service): it starts JACK
with `phase88x2` when two PHASE 88 cards are detected, or `hw:Phase88` when
only one is present. It starts immediately if the target user is already logged
in, otherwise at their next login. Disable QJackCtl's own JACK auto-start to
avoid competing servers. Stop/disable it from that user's session with `systemctl --user disable --now phase88-jack.service`.

For JACK plus PulseAudio bridging, use the combined installer from the repository
root:

```sh
sudo scripts/phase88-install-jackpulse.sh
```

Run it from the non-root desktop user's session, or pass that username when
invoking it as root: `scripts/phase88-install-jackpulse.sh USER`. It installs
JACK/PulseAudio packages and per-user services, then sets the stereo
`phase88_jack_out` and `phase88_jack_in` PulseAudio defaults. It refuses root,
PipeWire-Pulse, and an enabled root JACK service; disable any old root JACK unit
first. If PulseAudio is restarted, reload the bridge with
`systemctl --user restart phase88-pulse-jack.service` as the desktop user.

## By hand

```sh
# 1. module (uncompressed first)
xz -dc install/modules/snd-ice1712-$(uname -r).ko.xz > /tmp/snd-ice1712.ko
modinfo /tmp/snd-ice1712.ko | grep vermagic          # must match 'uname -r'
install -D -m 0644 /tmp/snd-ice1712.ko /lib/modules/$(uname -r)/updates/snd-ice1712.ko
depmod -a                                            # takes ~2 min on this box

# 2. policy
install -m 0644 install/etc/asound.conf              /etc/asound.conf
install -D -m 0644 install/etc/default/phase88       /etc/default/phase88
install -D -m 0644 install/etc/systemd/system/phase88-audio.service \
        /etc/systemd/system/phase88-audio.service
systemctl daemon-reload && systemctl enable phase88-audio.service

# 3. boot into it, then check
reboot
scripts/phase88-verify.sh                            # "all checks passed"
```

If `uname -r` does not match any prebuilt module, build it: that is
`debian-stock-kernel.md` (about five minutes once the headers are installed),
and the guide's section 2 has the short version.

## What the three files are for

| file | needed? | what it does |
|---|---|---|
| `/etc/asound.conf` | **only for two cards under one JACK server** | `phase88x2` = 16 in / 16 out (8 analog per card), `phase88x2all` adds the phantom and monitor channels. Harmless with one card; `pcm.!default` is untouched. |
| `/etc/default/phase88` | yes, but check it | which card is clock master/slave (`PHASE88_SYNC_MASTER` / `PHASE88_SYNC_SLAVE`), front mic input on/off. |
| `phase88-audio.service` | recommended | module auto-loads anyway; this runs `scripts/phase88-mixer.sh` at boot: unmute, unity gains, 0 dB codecs, front input on, and the word-clock roles. Without it the card boots muted and free-running. |

One card versus two, and the empty-clock-input trap, are in the guide (sections
5 and 6).

## After a kernel update

A new kernel brings its own, unpatched `snd-ice1712`, and the copy in
`/lib/modules/<old-version>/updates/` belongs to the *old* version - so after
`apt upgrade linux-image-*` the card falls back to the broken driver.

`etc/kernel/postinst.d/phase88-oot` fixes that automatically: Debian runs it for
every freshly installed kernel, and it rebuilds the module from
`../module-kit/` (8 files, 10 s) against `/lib/modules/<new-version>/build`,
installs it into `updates/` and runs `depmod`.  It never fails a kernel install;
if headers are missing it writes a warning and the exact command to fix it to
`/var/log/phase88-kernel-hook.log`.  `scripts/phase88-install-policy.sh` installs it for you, or by hand:

```sh
install -m 0755 install/etc/kernel/postinst.d/phase88-oot /etc/kernel/postinst.d/
```

On this box it is installed and pointed at this checkout:
`/etc/kernel/postinst.d/phase88-oot`, `SCRIPT` resolves to this checkout's `scripts/phase88-install-module.sh`.

### Does a fresh machine get it automatically?

Not by itself - nothing in an `install/` copy lands in `/etc` on its own.  It is
applied when you run `scripts/phase88-install-policy.sh`, which copies every file
under `install/etc/`, including the hook, and rewrites its `SCRIPT=` line to the
path the repo actually lives at.  So on a new machine:

```sh
apt install build-essential linux-headers-$(uname -r)     # to build (or skip: use the prebuilt .ko)
cp -a install /opt/phase88 && cp -a module-kit scripts /opt/phase8/   # or wherever
/opt/phase8/scripts/phase88-install-policy.sh /tmp/snd-ice1712.ko      # policy + module + hook
```

Three things to know:

* The hook only fires for kernels installed **after** it is in place.  The kernel
  you are booted into still needs the module once - via the `.ko` argument above,
  or `phase88-install-module.sh`.
* Rebuilding on that machine needs `module-kit/` **and** `scripts/phase88-install-module.sh`
  to stay present (the hook calls the script, the script reads the kit).  Keep the
  212 KB kit; it is not a temporary build directory.
* `/etc/kernel/postinst.d/` is the **Debian** mechanism (dpkg `linux-image-*`
  postinst runs everything in it).  Arch uses a pacman hook
  (`/etc/pacman.d/hooks/*.hook`, `After = transaction`, same script inside);
  Fedora/RHEL runs nothing there, so use DKMS or call the script from a
  `dnf` plugin/post-transaction action.  On any of them the manual one-liner
  always works: `phase88-install-module.sh --kver=$(uname -r)`.

Do it by hand, any time:

```sh
scripts/phase88-install-module.sh --check      # what is installed
scripts/phase88-install-module.sh              # rebuild + install + depmod
scripts/phase88-install-module.sh --reload     # also load it now
```

Why `updates/` wins: depmod orders directories by priority, and for a given
kernel version a module in `updates/` shadows the stock one in `kernel/` -
measured on this box, `modules.dep` contains exactly one `snd-ice1712` entry
(`updates/snd-ice1712.ko`) even though `kernel/sound/pci/ice1712/snd-ice1712.ko.xz`
is still on disk.  Check any machine with:

```sh
grep -c snd-ice1712 /lib/modules/$(uname -r)/modules.dep     # 1 = ours shadows the stock one
modprobe --show-depends snd_ice1712 | grep snd-ice1712.ko
```

Our file is owned by no package (`dpkg -S` finds nothing), so `apt` never
overwrites or removes it - the only way to lose the fix is a kernel version that
has no rebuilt module.  DKMS does the same job as the hook if you prefer it; the
kit is a normal out-of-tree module directory, so a `dkms.conf` with
`make -C ${kernel_source_dir} M=${dkms_tree}/${pkgname}/${pkgver} modules` works.

## Uninstall

```sh
rm /lib/modules/$(uname -r)/updates/snd-ice1712.ko && depmod -a
systemctl disable --now phase88-audio.service
rm /etc/systemd/system/phase88-audio.service /etc/asound.conf /etc/default/phase88
```
You are back to the stock driver, which for this card means: probe fails, no
device.
