#!/bin/bash
# Measure the PHASE 88 inputs *through JACK* (JACK owns the card, so arecord
# cannot be used while jackd runs).
#
#   usage: phase88-jack-meter.sh [seconds]
#          phase88-jack-meter.sh --selftest [seconds]
#
# Records the eight analog capture ports (and the internal monitor pair 11/12)
# with jack_rec and prints the peak level of each channel.
#
# --selftest additionally runs a sine client into system:playback_1: capture
# 11/12 must then show that sine, which proves playback + capture + the
# Envy24 monitor loop without any cable. The analog inputs 1..8 stay silent
# unless a signal is connected to them.
set -u
SECS=3
SELFTEST=0
if [ "${1:-}" = "--selftest" ]; then SELFTEST=1; shift; fi
SECS=${1:-3}

timeout 5 jack_lsp >/dev/null 2>&1 || {
	echo "jackd is not running - start it (QJackCtl 'Start', or:"
	echo "  jackd -d alsa -d hw:Phase88 -r 48000 -p 1024 -n 2 &)"
	exit 1
}

WAV=/tmp/phase88-jackmeter.wav
PORTS=""
for c in 1 2 3 4 5 6 7 8 11 12; do
	timeout 3 jack_lsp "system:capture_$c" | grep -q "system:capture_$c" &&
		PORTS="$PORTS system:capture_$c"
done
[ -n "$PORTS" ] || { echo "no system:capture_* ports found"; exit 1; }

if [ $SELFTEST -eq 1 ]; then
	( timeout -s INT $((SECS + 12)) jack_simple_client >/dev/null 2>&1 & )
	sleep 2
	timeout 3 jack_connect jack_simple_client:output1 system:playback_1 >/dev/null 2>&1
	echo "selftest: sine -> system:playback_1 (capture 11/12 must react)"
fi

echo "recording${PORTS:+ $PORTS} for ${SECS}s ..."
timeout -s INT $((SECS + 10)) jack_rec -f "$WAV" -d "$SECS" -b 32 $PORTS >/dev/null 2>&1

python3 - "$WAV" <<'EOF'
import math, os, struct, sys
p = sys.argv[1]
if not os.path.exists(p) or os.path.getsize(p) < 100:
    print("jack_rec produced no data")
    sys.exit(1)
w = __import__("wave").open(p)
n, ch, sw = w.getnframes(), w.getnchannels(), w.getsampwidth()
d = w.readframes(n)
v = struct.unpack("<" + str(len(d) // sw) + ("h" if sw == 2 else "i"), d)
full = 2 ** (sw * 8 - 1)


def pk(i):
    cc = v[i::ch]
    return max(abs(x) for x in cc) if cc else 0


def db(x):
    return f"{20 * math.log10(x / full):7.1f} dBFS" if x else "      -inf"


labels = [1, 2, 3, 4, 5, 6, 7, 8, 11, 12]
analog = 0
monitor = 0
for i, c in enumerate(labels[:ch]):
    p = pk(i)
    if c <= 8:
        analog = max(analog, p)
    else:
        monitor = max(monitor, p)
    kind = "analog input" if c <= 8 else "monitor mix  "
    print(f"  system:capture_{c:<2d} ({kind}) peak {p:>11d} {db(p)}")
print()
if analog:
    print("RESULT: signal present on the analog inputs - record path works")
    sys.exit(0)
if monitor:
    print("RESULT: digital loop ok, but no signal on inputs 1..8.")
    print("        Feed a LINE-level source into a REAR input (D-sub breakout).")
    print("        The front jack is the microphone input, which needs the")
    print("        Line/Mic select that the Linux driver does not have yet.")
else:
    print("RESULT: everything silent, including the monitor mix - capture broken")
sys.exit(2)
EOF
rc=$?
rm -f "$WAV"
exit $rc
