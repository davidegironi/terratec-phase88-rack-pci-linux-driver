#!/bin/bash
# Build, (re)load and inspect the patched snd-ice1712 module.
#
#   usage: phase88-cycle.sh [module params...]
#
# Every ALSA userspace call is wrapped in timeout(1): on this machine a
# blocked ALSA call becomes an unreapable D-state task that holds a module
# reference forever (that is what wedged the sound core on 2026-10-12, see
# analysis/README.md).  `rmmod -f` is never used.
set -u
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_ROOT=$(dirname "$SCRIPT_DIR")
TREE=${TREE:-$REPO_ROOT/kernel/linux-6.18.58}
KO=$TREE/sound/pci/ice1712/snd-ice1712.ko
LOGDIR=${PHASE88_LOG_DIR:-$REPO_ROOT/logs}
LOG=$LOGDIR/$(date +%Y%m%d-%H%M%S).log
mkdir -p "$LOGDIR"

T() { timeout -s KILL "${TMO:-10}" "$@" 2>&1; }

echo "== build =="                                        | tee "$LOG"
make -C "$TREE" -j"$(nproc)" M=sound/pci/ice1712 modules 2>&1 |
	grep -Ei "warning|error|CC|LD" | tee -a "$LOG"
[ -e "$KO" ] || { echo "no module produced" | tee -a "$LOG"; exit 1; }

if lsmod | grep -q "^snd_ice1712 "; then
	echo "== unload =="                                 | tee -a "$LOG"
	# pipewire/wireplumber keep /dev/snd/controlC* open; they are restarted
	# by the session manager, so killing them is not destructive
	for i in $(seq 1 20); do
		for proc in pipewire pipewire-pulse pipewire-kwd wireplumber pulseaudio; do
			for pid in $(fuser /dev/snd/* 2>/dev/null); do
				[ "$(cat /proc/$pid/comm 2>/dev/null)" = "$proc" ] && kill -9 "$pid" 2>/dev/null
			done
		done
		if rmmod snd_ice1712 2>/dev/null; then
			echo "unloaded (attempt $i)"        | tee -a "$LOG"
			break
		fi
		sleep 0.3
	done
	lsmod | grep "^snd_ice1712 "                       | tee -a "$LOG"
fi
echo "module refcount: $(awk '/^snd_ice1712 /{print $3, $4}' /proc/modules)" | tee -a "$LOG"

# watermark: verify.sh only looks at dmesg from here on, so the messages of
# the module we just unloaded are not counted against the patched one
dmesg | tail -1 > "$LOGDIR/.dmesg-mark"
echo "== load $* =="                                      | tee -a "$LOG"
insmod "$KO" "$@" 2>&1                                    | tee -a "$LOG"
sleep 1

echo "== dmesg =="                                        | tee -a "$LOG"
dmesg | tail -30                                          | tee -a "$LOG"
echo "== cards =="                                        | tee -a "$LOG"
T cat /proc/asound/cards                                  | tee -a "$LOG"
echo "== playback =="                                     | tee -a "$LOG"
T aplay -l                                                | tee -a "$LOG"
echo "== capture =="                                      | tee -a "$LOG"
T arecord -l                                              | tee -a "$LOG"
CARD=$(T awk '/ICE1712/{print $1; exit}' /proc/asound/cards)
if [ -n "${CARD:-}" ]; then
	echo "== ice1712 regs (card $CARD) =="              | tee -a "$LOG"
	T cat "/proc/asound/card$CARD/ice1712"             | tee -a "$LOG"
	echo "== ak4524 (card $CARD) =="                   | tee -a "$LOG"
	T cat "/proc/asound/card$CARD/ak4524"              | tee -a "$LOG"
fi
echo "log: $LOG"
