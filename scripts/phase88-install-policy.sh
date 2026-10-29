#!/bin/bash
# phase88-install-policy.sh - put this machine's PHASE 88 userspace policy on
# another box (or restore it after a reinstall).
#
# It installs the three policy files under install/etc/ in this checkout and,
# if you point it at a built snd-ice1712.ko, the module itself:
#
#   phase88-install-policy.sh                        policy only
#   phase88-install-policy.sh path/to/snd-ice1712.ko  policy + module
#
# What the policy is, and why each bit is needed, is in
# install/PHASE88-GUIDE.md ("Do I need a custom asound.conf?", "Do I need a
# custom service?").  Nothing here starts or stops audio; run it with
# JACK stopped and it will not touch a running card.

set -eu

HERE=$(dirname "$(readlink -f "$0")")
SRC=$(dirname "$HERE")/install/etc
KO=${1:-}

[ -d "$SRC" ] || { echo "no policy directory at $SRC" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run me as root" >&2; exit 1; }

if [ -n "$KO" ]; then
	[ -f "$KO" ] || { echo "no such module: $KO" >&2; exit 1; }
	kver=$(uname -r)
	# vermagic has to match or the load will be refused; say so up front rather
	# than leaving a module installed that can never load.
	vm=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
	if [ "$vm" != "$kver" ]; then
		echo "$KO is built for $vm, this kernel is $kver - build it against" >&2
		echo "  /lib/modules/$kver/build  (see docs/debian-stock-kernel.md)" >&2
		exit 1
	fi
	install -D -m 0644 "$KO" "/lib/modules/$kver/updates/$(basename "$KO")"
	depmod -a "$kver"
	echo "installed $(basename "$KO") for $kver"
	modprobe --show-depends snd_ice1712 | tail -1
fi

install -D -m 0644 "$SRC/asound.conf" /etc/asound.conf
echo "installed /etc/asound.conf (combined phase88x2 devices; harmless with one card)"

# PHASE88_SYNC_SLAVE must be edited to match the wiring before the first boot,
# or left empty with a single card: a card left on 'IEC958 Input' with an empty
# clock input free-runs at about 33168 frames/s instead of stalling.
if [ ! -e /etc/default/phase88 ]; then
	install -D -m 0644 "$SRC/default/phase88" /etc/default/phase88
	echo "installed /etc/default/phase88 - CHECK PHASE88_SYNC_MASTER/SLAVE against your cable"
else
	echo "/etc/default/phase88 already exists, leaving it alone"
fi

# Rewrite the shipped unit paths to this checkout, so the repo can sit anywhere.
REPO_ROOT=$(dirname "$HERE")
MIXER=$REPO_ROOT/scripts/phase88-mixer.sh
[ -x "$MIXER" ] || { echo "no runnable phase88-mixer.sh next to me ($MIXER)" >&2; exit 1; }
sed -e "s|^ExecStart=.*/phase88-mixer.sh|ExecStart=$MIXER|" \
	-e "s|^Documentation=file:.*/analysis/README.md|Documentation=file:$REPO_ROOT/analysis/README.md|" \
	"$SRC/systemd/system/phase88-audio.service" > /etc/systemd/system/phase88-audio.service
chmod 0644 /etc/systemd/system/phase88-audio.service
echo "installed phase88-audio.service (mixer: $MIXER)"
systemctl daemon-reload
systemctl enable phase88-audio.service
echo "enabled phase88-audio.service (mixer defaults + front mic input + clock)"

# Keep the fix alive when the kernel package is updated: Debian runs
# /etc/kernel/postinst.d/* for every kernel it installs.
if [ -f "$SRC/kernel/postinst.d/phase88-oot" ]; then
	install -D -m 0755 "$SRC/kernel/postinst.d/phase88-oot" /etc/kernel/postinst.d/phase88-oot
	INSTALLER=$(dirname "$HERE")/scripts/phase88-install-module.sh
	sed -i "s|^SCRIPT=.*|SCRIPT=$INSTALLER|" /etc/kernel/postinst.d/phase88-oot
	echo "installed /etc/kernel/postinst.d/phase88-oot (rebuilds the module for new kernels: $INSTALLER)"
fi

cards=$(awk '/ICE1712/{print $1}' /proc/asound/cards | tr '\n' ' ')
if [ -n "$cards" ]; then
	echo "cards present: $cards"
	echo "apply the mixer now with: systemctl restart phase88-audio.service"
else
	echo "no ICE1712 card found in /proc/asound/cards - is the module loaded?"
fi
