#!/bin/bash
# Analog loopback / output test for the TerraTec PHASE 88.
#
#   usage: phase88-loopback.sh [seconds]
#
# Plays a 1 kHz sine on all ten playback channels while capturing all twelve
# capture channels, then reports the peak level per channel.
#
# Capture channel layout of the ICE1712 "multi" device:
#   1..8   the eight AK4524 ADCs   (analog inputs - need a signal connected)
#   9..10  AC'97 capture           (this board has no AC'97 codec -> silent)
#   11..12 the ICE1712 digital monitor mix (internal loop, always active)
# So 11/12 prove that the digital path works; the analog inputs must be
# driven with a cable (Out 1 -> In 1) or a source to check channels 1..8.
#
# The script unmutes the ICE1712 monitor mixer and the AK4524 (the driver
# starts muted, like on every ICE1712 board), so speakers on the outputs will
# make noise: outputs 1+2 are the front pair on the D-sub connector.
set -u
CARD=$(awk '/ICE1712/{print $1; exit}' /proc/asound/cards)
[ -n "$CARD" ] || { echo "no ICE1712 card"; exit 1; }
SECS=${1:-3}
DEV="hw:$CARD,0"

# set every control with the given name; $2 is the value
set_ctl() {
	local name=$1 val=$2 n
	for n in $(amixer -c "$CARD" controls |
		   sed -n "s|^numid=\([0-9]*\).*name='$name'.*|\1|p"); do
		amixer -c "$CARD" cset numid="$n" "$val" >/dev/null 2>&1 ||
			echo "  (could not set numid $n to $val)"
	done
}

# The card can only be used by one client at a time: if jackd (or Reaper with
# its own ALSA backend) owns the PCM devices, arecord/speaker-test fail.
BUSY=$(fuser /dev/snd/pcmC${CARD}D0c /dev/snd/pcmC${CARD}D0p 2>/dev/null | tr -s ' ')
if [ -n "$BUSY" ]; then
	echo "card $CARD is busy, held by PID(s):$BUSY"
	for pid in $BUSY; do echo "   $(cat /proc/$pid/comm 2>/dev/null) ($pid)"; done
	echo "Stop it first: QJackCtl 'Stop', or 'jack_control ds', or kill the PID,"
	echo "then run this script again. To measure the inputs *while* JACK runs use"
	echo "phase88-jack-meter.sh instead."
	exit 3
fi

echo "=== PHASE 88 loopback test, card $CARD, $(date) ==="
set_ctl 'Multi Playback Switch' on
set_ctl 'H/W Multi Capture Switch' on
set_ctl 'IEC958 Multi Capture Switch' on
# 96 = unity gain on the ICE1712 monitor mixer, 127 = 0 dB on the AK4524
set_ctl 'Multi Playback Volume' 96
set_ctl 'H/W Multi Capture Volume' 96
set_ctl 'DAC Volume' 127
set_ctl 'ADC Volume' 127

OUT=/tmp/phase88-loopback.raw
PLAYLOG=/tmp/phase88-loopback-play.log
timeout -s INT $((SECS + 6)) speaker-test -D "$DEV" -c 10 -r 48000 \
	--format S32_LE -t sine -f 1000 -l 0 -p 1024 >"$PLAYLOG" 2>&1 &
PLAY=$!
sleep 1
if ! timeout -s INT $((SECS + 2)) arecord -D "$DEV" -c 12 -r 48000 -f S32_LE -t raw "$OUT"; then
	echo "arecord failed - playback side said:"
	sed 's/^/   /' "$PLAYLOG"
	rm -f "$OUT"
	kill -INT "$PLAY" 2>/dev/null
	exit 1
fi
sleep 0.5
kill -INT "$PLAY" 2>/dev/null
wait "$PLAY" 2>/dev/null

python3 - "$OUT" <<'EOF'
import math, os, struct, sys
p = sys.argv[1]
if not os.path.exists(p) or os.path.getsize(p) == 0:
    print("no data captured"); sys.exit(1)
d = open(p, 'rb').read()
v = struct.unpack('<%di' % (len(d) // 4), d)


def peak(c):
    ch = v[c::12]
    return max(abs(x) for x in ch) if ch else 0


def db(x):
    return f"{20 * math.log10(x / 2**31):7.1f} dBFS" if x else "   -inf"


print("analog inputs (AK4524 ADC 1-8):")
analog = 0
for c in range(8):
    pk = peak(c)
    analog = max(analog, pk)
    print(f"   capture ch{c + 1}: peak {pk:>11d} {db(pk)}")
print("monitor loop (ICE1712 digital mixer):")
for c in (10, 11):
    pk = peak(c)
    print(f"   capture ch{c + 1}: peak {pk:>11d} {db(pk)}")
print()
if peak(10) == 0:
    print("RESULT: the internal monitor loop is silent too - digital path broken")
    sys.exit(1)
if analog == 0:
    print("RESULT: digital path ok, no signal on the analog inputs.")
    print("        Connect Out 1 -> In 1 (or a source to any input) and rerun;")
    print("        with speakers on outputs 1/2 the 1 kHz tone must be audible.")
    sys.exit(2)
print("RESULT: analog output -> input path works (peak %d)" % analog)
EOF
rc=$?
rm -f "$OUT"
exit $rc
