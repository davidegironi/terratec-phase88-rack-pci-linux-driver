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
└── modules/                          prebuilt modules + modinfo proof
    ├── snd-ice1712-6.18.55.ko.xz
    ├── snd-ice1712-6.12.111+deb13-amd64.ko.xz   (stock Debian kernel, see modinfo file)
    ├── snd-ice17xx-ak4xxx-6.12.111+deb13-amd64.ko.xz
    ├── MODINFO-stock-debian-6.12.111.txt
    └── Makefile.oot-example          the 5-line out-of-tree Makefile
```

## Fastest path: script

```sh
/root/terratec/scripts/phase88-install-policy.sh                 # policy only
/root/terratec/scripts/phase88-install-policy.sh path/to/snd-ice1712.ko   # + module
```

It copies `install/etc/*` to `/etc`, installs the module into
`/lib/modules/$(uname -r)/updates/` (which depmod prefers over the distro copy),
runs `depmod -a`, rewrites the service's mixer path to wherever this repo
actually lives, and enables `phase88-audio.service`.  It refuses a module whose
`vermagic` does not match the running kernel - that check is there because
loading a mismatched sound module is how you wedge the box.  Run it with JACK
stopped; it does not start or stop audio.

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

## Uninstall

```sh
rm /lib/modules/$(uname -r)/updates/snd-ice1712.ko && depmod -a
systemctl disable --now phase88-audio.service
rm /etc/systemd/system/phase88-audio.service /etc/asound.conf /etc/default/phase88
```
You are back to the stock driver, which for this card means: probe fails, no
device.
