#!/bin/bash
# Post-reload functional check of the patched TerraTec PHASE 88 driver.
#
#   usage: phase88-verify.sh [card-number]        (default: auto-detect)
#
# Only read-only inspection plus short, time-boxed playback/capture runs.
# Every call that touches ALSA is wrapped in timeout(1) - a blocked ALSA
# call turns into an unreapable D-state task on this box.
set -u
TREE=/root/terratec/kernel/linux-6.18.55
KO=$TREE/sound/pci/ice1712/snd-ice1712.ko
LOGDIR=/root/terratec/logs
LOG=$LOGDIR/verify-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

T() { timeout -s KILL "${TMO:-15}" "$@"; }
ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILED=$((FAILED+1)); }
FAILED=0

echo "### PHASE 88 verification $(date)"

# ---------------------------------------------------------------- card
CARD=${1:-$(T awk '/ICE1712/{print $1; exit}' /proc/asound/cards)}
[ -n "${CARD:-}" ] || { bad "no ICE1712 card found"; exit 1; }
DEV=$(T cat "/proc/asound/card$CARD/id" 2>/dev/null)
ok "card $CARD ($DEV)"
T grep -A3 "\[$DEV" /proc/asound/cards | sed 's/^/         /'

# ------------------------------------------------- patched module live?
# this kernel has no CONFIG_MODULE_SRCVERSION_ALL, so identify the
# insmod'ed out-of-tree build by its taint flags (the module installed in
# /lib/modules is in-tree and does not get the 'O' flag)
TAINT=$(cat /sys/module/snd_ice1712/taint 2>/dev/null)
if [ -n "$TAINT" ] && echo "$TAINT" | grep -q O; then
	ok "out-of-tree module loaded (taint $TAINT)"
elif [ -n "$TAINT" ]; then
	bad "loaded module is in-tree (taint '$TAINT'); run phase88-cycle.sh"
else
	bad "snd_ice1712 is not loaded; run phase88-cycle.sh"
fi

# ------------------------------------------------------------ dmesg
# only look at dmesg from the point where the patched module was loaded on
# (see the .dmesg-mark written by phase88-cycle.sh), the messages before it
# belong to the module we unloaded
MARK=$(cat /root/terratec/logs/.dmesg-mark 2>/dev/null)
if [ -n "$MARK" ]; then
	DM=$(T dmesg | awk -v m="$MARK" 'index($0,m){f=1} f')
else
	DM=$(T dmesg)
fi
echo "--- probe messages (after module load) ---"
printf '%s\n' "$DM" | grep -i "ice1712\|0000:03:02.0" | tail -25 | sed 's/^/         /'
errs=$(printf '%s\n' "$DM" | grep -iE "chip select failed|AC'97 [0-9] (does not respond|access is not valid)|cannot initialize ac97|Consumer PCM code")
if [ -n "$errs" ]; then
	bad "AC97/chip-select errors still present"
	printf '%s\n' "$errs" | sed 's/^/         /'
else
	ok "no chip-select / AC97 errors"
fi
oops=$(printf '%s\n' "$DM" | grep -iE "BUG:|Oops|general protection|null pointer")
if [ -n "$oops" ]; then bad "kernel oops in dmesg"; else ok "no oops"; fi

# ------------------------------------------------------- pcm devices
echo "--- PCM devices ---"
T aplay -l | sed 's/^/         /'
T arecord -l | sed 's/^/         /'
if T aplay -l | grep -q "ICE1712 multi"; then ok "pro (multi) playback device present"; else bad "pro playback device missing"; fi
if T aplay -l | grep -q "ICE1712 consumer"; then
	bad "consumer PCM still present (NO_CON_AC97 quirk not in effect)"
else
	ok "no consumer PCM devices (no AC'97 codec on this board)"
fi

# ----------------------------------------------------------- mixers
echo "--- mixer ---"
T amixer -c "$CARD" controls | wc -l | sed 's/^/         controls: /'
if T amixer -c "$CARD" controls | grep -qi "sensitivity"; then
	bad "sensitivity controls still created (no 0x23/0x24 backend)"
else
	ok "no EWS88MT sensitivity controls"
fi

# ---------------------------------------------------------- registers
echo "--- ice1712 registers ---"
T cat "/proc/asound/card$CARD/ice1712" | sed 's/^/         /'
echo "--- ak4524 (first 20 lines) ---"
T cat "/proc/asound/card$CARD/ak4524" 2>/dev/null | head -20 | sed 's/^/         /'

# ---------------------------------------------------------- playback
PCMC="hw:$CARD,0"
for rate in 44100 48000 96000; do
	echo "--- playback $rate Hz, 10 ch S32_LE ---"
	( T speaker-test -D "$PCMC" -c 10 -r "$rate" --format S32_LE -t sinc -l 0 -p 2048 >/tmp/phase88-play.log 2>&1 & )
	sleep 2
	st=$(T awk '/state/ {print $2; exit}' "/proc/asound/card$CARD/pcm0p/sub0/status" 2>/dev/null)
	p1=$(T awk '/hw_ptr/ {print $3; exit}' "/proc/asound/card$CARD/pcm0p/sub0/status" 2>/dev/null)
	sleep 1
	p2=$(T awk '/hw_ptr/ {print $3; exit}' "/proc/asound/card$CARD/pcm0p/sub0/status" 2>/dev/null)
	hw=$(T cat "/proc/asound/card$CARD/pcm0p/sub0/hw_params" 2>/dev/null | tr '\n' ' ')
	pkill -f "speaker-test -D $PCMC" 2>/dev/null
	sleep 0.5
	if [ "$st" = "RUNNING" ] && [ "${p2:-0}" -gt "${p1:-0}" ] 2>/dev/null; then
		ok "playback RUNNING @ $rate, DMA advanced ${p1}->${p2} ($hw)"
	else
		bad "playback state '$st', hw_ptr ${p1}->${p2} @ $rate"
		sed 's/^/           /' /tmp/phase88-play.log
	fi
done

# ----------------------------------------------------------- capture
echo "--- capture 48 kHz, 12 ch S32_LE, 2 s ---"
( T arecord -D "$PCMC" -c 12 -r 48000 -f S32_LE -d 3 -t raw /tmp/phase88-cap.raw >/dev/null 2>&1 & )
sleep 1.5
cs=$(T awk '/state/ {print $2; exit}' "/proc/asound/card$CARD/pcm0c/sub0/status" 2>/dev/null)
c1=$(T awk '/hw_ptr/ {print $3; exit}' "/proc/asound/card$CARD/pcm0c/sub0/status" 2>/dev/null)
sleep 1
c2=$(T awk '/hw_ptr/ {print $3; exit}' "/proc/asound/card$CARD/pcm0c/sub0/status" 2>/dev/null)
# let arecord finish (3 s) and flush the file
for i in $(seq 1 20); do pgrep -x arecord >/dev/null || break; sleep 0.3; done
if [ "$cs" = "RUNNING" ] && [ "${c2:-0}" -gt "${c1:-0}" ] 2>/dev/null; then
	ok "capture RUNNING, DMA advanced ${c1}->${c2}"
else
	bad "capture state '$cs', hw_ptr ${c1}->${c2}"
fi
if [ -s /tmp/phase88-cap.raw ]; then
	nonz=$(python3 - <<'EOF'
data = open('/tmp/phase88-cap.raw','rb').read()
nz = sum(1 for b in data if b)
print(f"{nz} nonzero bytes of {len(data)}")
EOF
)
	echo "         $nonz"
	case "$nonz" in
	"0 nonzero"*) echo "  [note] capture data is all zero - expected when nothing is connected to the inputs" ;;
	*) ok "capture delivered non-zero data" ;;
	esac
else
	bad "capture produced no data"
fi

echo
echo "log: $LOG"
[ $FAILED -eq 0 ] && echo "### RESULT: all checks passed" || echo "### RESULT: $FAILED check(s) FAILED"
exit $FAILED
