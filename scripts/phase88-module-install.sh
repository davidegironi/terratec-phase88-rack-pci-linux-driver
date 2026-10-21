#!/bin/bash
# phase88-module-install.sh - build the patched snd_ice1712 and install it.
#
# The driver needs only 8 source files (module-kit/, ~210 KB), not a kernel
# tree: it builds against /lib/modules/<kver>/build, about 10 seconds.
#
#   phase88-module-install.sh --check                 what is installed now
#   phase88-module-install.sh                         build + install for the running kernel
#   phase88-module-install.sh --kver=6.12.111+deb13-amd64
#   phase88-module-install.sh --reload                also load it now (frees /dev/snd first)
#   phase88-module-install.sh --dry-run               build only, install nothing
#
# Install location matters: /lib/modules/<kver>/updates/ shadows the stock
# kernel/sound/pci/ice1712/snd-ice1712.ko for that kernel version, and depmod
# then does not even list the stock file. Nothing here touches other kernels.
set -u

# Default kit = the module-kit/ next to this script, so the repo can live
# anywhere; /root/terratec stays as a fallback.
HERE_SCRIPT=$(dirname "$(readlink -f "$0")")
KIT=${KIT:-$(dirname "$HERE_SCRIPT")/module-kit}
[ -f "$KIT/ice1712.c" ] || KIT=${KIT:-/root/terratec/module-kit}
KVER=$(uname -r)
RELOAD=0 DRY=0 CHECK=0 CONTROL='Line/Mic 7/8 Switch'
LOGTAG=phase88-module-install

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    --kver=*)   KVER=${a#*=} ;;
    --kit=*)    KIT=${a#*=} ;;
    --reload)   RELOAD=1 ;;
    --dry-run)  DRY=1 ;;
    --check)    CHECK=1 ;;
    -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

TARGET=/lib/modules/$KVER/updates/snd-ice1712.ko
BUILD=/lib/modules/$KVER/build
[ -e "$BUILD" ] || BUILD=/usr/src/linux-headers-$KVER
MODS=/sys/module/snd_ice1712

if [ $CHECK = 1 ]; then
  say "== kernel $KVER =="
  if [ -f "$TARGET" ]; then
    say "installed : $TARGET"
    say "            md5 $(md5sum "$TARGET" | cut -d' ' -f1)"
    say "            vermagic $(modinfo -F vermagic "$TARGET")"
    say "            has '$CONTROL': $(strings "$TARGET" | grep -c "$CONTROL")"
  else
    say "installed : nothing in $TARGET"
  fi
  if [ -d "$MODS" ]; then
    say "loaded    : yes (taint OE expected: $(cat /proc/sys/kernel/tainted))"
    say "            from: $(cat /sys/module/snd_ice1712/holders 2>/dev/null || echo n/a)"
  else
    say "loaded    : no"
  fi
  say "modprobe picks: $(modprobe --show-depends snd_ice1712 2>/dev/null | grep -m1 'snd-ice1712.ko' || echo '(not resolvable)')"
  say "build dir   : $([ -e "$BUILD" ] && echo "$BUILD" || echo 'MISSING - apt install linux-headers-<version>, or restore the source tree')"
  say "kit         : $([ -f "$KIT/ice1712.c" ] && echo "$KIT" || echo 'MISSING')"
  exit 0
fi

[ -f "$KIT/ice1712.c" ] || die "no kit at $KIT (module-kit/ holds the 8 source files)"
[ -e "$BUILD" ] || die "no build directory for kernel $KVER.
  tried /lib/modules/$KVER/build and /usr/src/linux-headers-$KVER
  For a Debian kernel:  apt install linux-headers-$(uname -r)   (or the matching version)
  For the custom 6.18.55 kernel the build dir is the source tree itself."

WORK=$(mktemp -d /tmp/phase88-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/ice1712"
cp "$KIT"/*.c "$KIT"/*.h "$KIT"/Makefile "$WORK/ice1712/"

say "building snd-ice1712 for $KVER against $BUILD"
make -C "$BUILD" M="$WORK/ice1712" modules -j"$(nproc)" >"$WORK/build.log" 2>&1 || {
  tail -25 "$WORK/build.log"; die "build failed (log above)"; }
KO=$WORK/ice1712/snd-ice1712.ko
[ -f "$KO" ] || die "build produced no .ko"

VM=$(modinfo -F vermagic "$KO")
NCTL=$(strings "$KO" | grep -c "$CONTROL")
say "built ok: $VM, '$CONTROL' present: $NCTL"
[ $NCTL -ge 1 ] || die "the built module does not contain '$CONTROL' - that is not the PHASE 88 patched source"
[ $DRY = 1 ] && { say "--dry-run: not installing"; exit 0; }

mkdir -p "/lib/modules/$KVER/updates"
if [ -f "$TARGET" ]; then
  BK=$TARGET.bak-$(date +%Y%m%d-%H%M%S)
  cp -a "$TARGET" "$BK" && say "previous module kept at $BK"
fi
install -m 0644 "$KO" "$TARGET" || die "install to $TARGET failed"
say "installed $TARGET"

say "running depmod for $KVER (this takes a couple of minutes on this box)"
depmod -a "$KVER" || die "depmod failed"
PICK=$(modprobe --show-depends snd_ice1712 2>/dev/null | grep -m1 'snd-ice1712.ko' || true)
if [ "$KVER" = "$(uname -r)" ]; then
  case "$PICK" in
    *"$TARGET"*) say "modprobe now picks the patched module: $PICK" ;;
    *) say "WARNING: modprobe still picks $PICK" ; exit 1 ;;
  esac
fi

if [ $RELOAD = 1 ]; then
  [ "$KVER" = "$(uname -r)" ] || die "--reload only applies to the running kernel"
  # A stream that is running would be killed; refuse instead of surprising anyone.
  for st in /proc/asound/card*/pcm*p/sub*/status /proc/asound/card*/pcm*c/sub*/status; do
    [ -f "$st" ] || continue
    if grep -q '^status:RUNNING' "$st"; then
      die "a PCM stream is RUNNING ($(dirname "$st")); stop jackd/Reaper/pipewire streams first"
    fi
  done
  STOPPED=""
  for d in /run/user/*; do
    u=$(stat -c %U "$d" 2>/dev/null) || continue
    [ -S "$d/bus" ] || continue
    if sudo -u "$u" XDG_RUNTIME_DIR=$d DBUS_SESSION_BUS_ADDRESS=unix:path=$d/bus \
         systemctl --user is-active --quiet pipewire.service 2>/dev/null; then
      sudo -u "$u" XDG_RUNTIME_DIR=$d DBUS_SESSION_BUS_ADDRESS=unix:path=$d/bus \
           systemctl --user stop pipewire.socket pipewire.service wireplumber.service 2>/dev/null
      STOPPED="$STOPPED $u"; say "stopped pipewire/wireplumber of user $u (they hold /dev/snd)"
    fi
  done
  rmmod snd_ice1712 || {
    say "rmmod failed. holders:"; fuser -v /dev/snd/* 2>&1 | sed 's/^/  /'
    die "close whatever holds /dev/snd and re-run with --reload"
  }
  modprobe snd_ice1712 || die "modprobe failed after rmmod"
  sleep 1
  [ -x /root/terratec/scripts/phase88-mixer.sh ] && /root/terratec/scripts/phase88-mixer.sh >/dev/null 2>&1
  for u in $STOPPED; do
    d=/run/user/$(id -u "$u")
    sudo -u "$u" XDG_RUNTIME_DIR=$d DBUS_SESSION_BUS_ADDRESS=unix:path=$d/bus \
         systemctl --user start pipewire.socket pipewire.service wireplumber.service 2>/dev/null
  done
  say "reloaded: $(grep -c ICE1712 /proc/asound/cards) PHASE 88 card(s) present"
fi

say "done. verify with: /root/terratec/scripts/phase88-verify.sh"
