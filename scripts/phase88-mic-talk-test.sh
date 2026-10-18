#!/bin/bash
# Decide whether page 0x03 bit 0x10 is a routing mux (front XLR vs rear aux) or
# only a preamp gain: record with the switch OFF and ON while somebody talks into
# the front microphone.  OFF + silence on the channel = mux, OFF + faint speech =
# preamp.
#
#   usage: phase88-mic-talk-test.sh [seconds per phase]     (default 10)
#
# jackd must not be running.  Talk during BOTH phases - say "hello hello" out loud.
set -u
CARD=$(awk '/ICE1712/{print $1; exit}' /proc/asound/cards)
[ -n "${CARD:-}" ] || { echo "no PHASE 88 card"; exit 1; }
S=${1:-10}
SW="Line/Mic 7/8 Switch"
timeout 5 pgrep -x jackd >/dev/null 2>&1 && { echo "stop jackd/QJackCtl first"; exit 1; }
T() { timeout -s KILL 30 "$@"; }

lvl() { python3 - "$1" <<'PY'
import sys, wave, array, math
w=wave.open(sys.argv[1],'rb'); ch=w.getnchannels()
d=w.readframes(w.getnframes())[w.getframerate()//2*ch*4:]
a=array.array('i'); a.frombytes(d[:len(d)//(ch*4)*(ch*4)])
for k in (6,7):
    seg=a[k::ch]
    p=max((abs(x) for x in seg), default=0)
    rms=0
    n=len(seg)
    if n:
        rms=int((sum(x*x for x in seg)//n) ** 0.5)
    print(f"ch{k+1}: peak {((20*math.log10(p)-186.2) if p>0 else -999):7.1f}  rms {((20*math.log10(rms)-186.2) if rms>0 else -999):7.1f} dBFS")
PY
}
echo "### talk into the front microphone when told; ${S}s per phase"
for st in off on off; do
	echo ">>> phase $st  (talk now)"
	T amixer -q -c "$CARD" cset name="$SW" "$st"
	sleep 1
	T arecord -D "hw:$CARD,0" -f S32_LE -c 12 -r 48000 -d "$S" -q "/tmp/talk-$st.wav"
	echo "    $st:"; lvl "/tmp/talk-$st.wav" | sed 's/^/      /'
done
T amixer -q -c "$CARD" cset name="$SW" off
echo "files: /tmp/talk-off.wav /tmp/talk-on.wav"
