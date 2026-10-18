#!/bin/bash
# Map the PHASE 88 Line/Mic switches onto the capture channels by measuring
# what each switch does to the noise level of every channel.
#
#   usage: phase88-linemic-probe.sh [seconds per state]      (default 2)
#
# A microphone produces audible hiss even when nobody talks, and engaging the
# preamp lifts that hiss by ~28 dB, so the mapping can be measured without
# anybody speaking.  A real source on the input makes the result much clearer.
#
# jackd/QJackCtl must NOT be running (the ALSA device is taken exclusively).
set -u
CARD=$(awk '/ICE1712/{print $1; exit}' /proc/asound/cards)
[ -n "${CARD:-}" ] || { echo "no PHASE 88 card found"; exit 1; }
SECS=${1:-2}
DEV=hw:$CARD,0

if timeout 5 pgrep -x jackd >/dev/null 2>&1; then
	echo "jackd is running and owns $DEV - stop QJackCtl / jack_control stop first"
	exit 1
fi

T() { timeout -s KILL "${TMO:-25}" "$@"; }
SWITCHES=("Line/Mic 1/2 Switch" "Line/Mic 3/4 Switch" "Line/Mic 5/6 Switch" "Line/Mic 7/8 Switch")

reset_all() {
	local s
	for s in "${SWITCHES[@]}"; do T amixer -q -c "$CARD" cset name="$s" off 2>/dev/null; done
}

peaks() {	# $1 = wav file; prints 12 peak values over the trailing part
	python3 - "$1" <<'EOF'
import sys, wave, array
w = wave.open(sys.argv[1], 'rb')
ch = w.getnchannels()
data = w.readframes(w.getnframes())
skip = int(0.6 * w.getframerate())          # ignore the relay click
data = data[skip * ch * 4:]
a = array.array('i')
a.frombytes(data[:len(data) // (ch * 4) * (ch * 4)])
peaks = [max((abs(x) for x in a[k::ch]), default=0) for k in range(ch)]
print(" ".join(str(p) for p in peaks))
EOF
}

capture() {	# $1 = file
	T arecord -D "$DEV" -f S32_LE -c 12 -r 48000 -d "$SECS" -q "$1" 2>/dev/null
}

FS=186.2	# 20*log10(2**31)
db() { python3 -c "import math,sys; v=float(sys.argv[1]); print(f'{20*math.log10(v)-186.2:10.1f}' if v>0 else '      -inf')" "$1"; }

echo "### PHASE 88 Line/Mic mapping probe  (card $CARD, ${SECS}s per state)"
echo "    every channel must stay quiet when nothing is connected; a channel that"
echo "    jumps ~28 dB when a switch is on belongs to that switch"
echo

reset_all; sleep 0.7
capture /tmp/lm-base.wav
read -r -a BASE < <(peaks /tmp/lm-base.wav)
printf '%-22s' "baseline(all off)"
for i in ${!BASE[@]}; do [ $i -lt 8 ] || continue; printf ' %10s' "$(db "${BASE[$i]}")"; done; echo " dBFS"
echo "                       ch1        ch2        ch3        ch4        ch5        ch6        ch7        ch8"

for s in "${SWITCHES[@]}"; do
	reset_all; sleep 0.5
	T amixer -q -c "$CARD" cset name="$s" on 2>/dev/null || { echo "cannot set $s"; continue; }
	sleep 0.7
	capture /tmp/lm-on.wav
	read -r -a ON < <(peaks /tmp/lm-on.wav)
	printf '%-22s' "$s"
	for i in ${!ON[@]}; do
		[ $i -lt 8 ] || continue
		printf ' %10s' "$(db "${ON[$i]}")"
	done
	echo " dBFS"
	printf '%-22s' "  delta"
	for i in ${!ON[@]}; do
		[ $i -lt 8 ] || continue
		printf ' %10s' "$(python3 -c "
import math,sys
a,b=float(sys.argv[1]),float(sys.argv[2])
if a<=0 and b<=0: print('     -')
elif a<=0: print('     +inf')
elif b<=0: print('     -inf')
else: print(f'{20*math.log10(b/a):+10.1f}')
" "${BASE[$i]}" "${ON[$i]}")"
	done
	echo " dB"
done
reset_all
echo
echo "all switches are back to off (line)"
