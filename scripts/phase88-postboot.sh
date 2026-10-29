#!/bin/bash
# Optional one-shot check of the patched PHASE 88 driver. The installed
# phase88-postboot.service is disabled and masked; this script writes no files.
#
#   manual:  scripts/phase88-postboot.sh
#
# Everything that touches ALSA is wrapped in timeout(1). Analog inputs 1..8
# can only be judged with a real source attached, so this script checks that
# the Line/Mic switches exist and are writable, and proves the digital path
# (playback -> Envy24 monitor -> capture 11/12) through JACK.
set -u
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

T() { timeout -s KILL "${TMO:-20}" "$@"; }
ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILED=$((FAILED+1)); }
FAILED=0

echo "### PHASE 88 post-boot check $(date)"

# ------------------------------------------------------------ card present
for i in $(seq 30); do
	grep -qi ICE1712 /proc/asound/cards && break
	sleep 1
done
CARD=$(awk '/ICE1712/{print $1; exit}' /proc/asound/cards)
if [ -n "${CARD:-}" ]; then
	ok "card $CARD up: $(T cat /proc/asound/card$CARD/id)"
else
	bad "no ICE1712 card in /proc/asound/cards"
fi

# no error messages from the module that is loaded right now
if dmesg | grep -qE "AK4524 chip select failed|AC'97 0 does not respond"; then
	echo "  [warn] stale AK4524/AC97 lines in dmesg (pre-fix distro module?)"
fi
if dmesg | tail -200 | grep -qE "BUG:|oops|Oops|call trace|WARNING:"; then
	bad "kernel taint/oops text in recent dmesg"
else
	ok "no oops/trace in recent dmesg"
fi

# ------------------------------------------------------------ module
if PHASE88_NO_FILE_LOG=1 "$SCRIPT_DIR/phase88-verify.sh" "${CARD:-0}"; then
	ok "phase88-verify.sh passed"
else
	bad "phase88-verify.sh reported failures"
fi

# ------------------------------------------------------------ Line/Mic switches
echo
echo "### Line/Mic switches"
for p in "1/2" "3/4" "5/6" "7/8"; do
	name="Line/Mic $p Switch"
	before=$(T amixer -c "$CARD" cget name="$name" 2>/dev/null | grep -m1 ': values=')
	if [ -z "$before" ]; then
		bad "control '$name' missing"
		continue
	fi
	T amixer -q -c "$CARD" cset name="$name" on  >/dev/null 2>&1 || bad "cannot set '$name' on"
	T amixer -q -c "$CARD" cset name="$name" off >/dev/null 2>&1 || bad "cannot set '$name' off"
	ok "$name present and writable ($before)"
done

# ------------------------------------------------------------ JACK path
echo
echo "### JACK"
if T pgrep -x jackd >/dev/null 2>&1; then
	echo "  [info] jackd already running - using it"
	JACK_OWN=0
else
	# no session bus in a system unit: without this jackd refuses the device
	# ("Audio device hw:Phase88 cannot be acquired...")
	export JACK_NO_AUDIO_RESERVATION=1
	/usr/bin/jackd -dalsa -dhw:Phase88 -r 48000 -p 1024 -n 2 \
		> /dev/null 2>&1 &
	JACK_OWN=1
	sleep 5
fi
if T timeout 25 "$SCRIPT_DIR/phase88-jack-meter.sh" --selftest 4; then
	ok "jack meter selftest ran"
else
	bad "jack meter selftest failed"
fi
[ "$JACK_OWN" = 1 ] && { pkill -x jackd; sleep 2; }

echo
echo "### RESULT: $([ $FAILED -eq 0 ] && echo 'all checks passed' || echo "$FAILED problem(s)")"
# ------------------------------------------------------------ disarm
systemctl disable phase88-postboot.service >/dev/null 2>&1
systemctl mask --force phase88-postboot.service >/dev/null 2>&1
echo "phase88-postboot.service disabled and masked"
