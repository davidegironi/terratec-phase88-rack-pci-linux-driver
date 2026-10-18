#!/bin/bash
# Measure what each PHASE 88 clock really does, and whether two cards are locked.
#
#   usage: phase88-clock-measure.sh [-d seconds] [card ...]
#
# The Envy24 capture DMA advances with the card's own bit clock, and
# /proc/asound/cardN/pcm0c/sub0/status carries the DMA position together with
# the timestamp of that very position, so  rate = d(hw_ptr) / d(tstamp)
# measures the bit clock against the CPU clock, independent of PCI load and
# scheduling jitter.  Two cards on their own crystals differ by tens of ppm;
# a card that slaves to the other one reads the same rate, i.e. a difference
# far below 1 ppm.
#
# A timestamp is only produced when the stream owner enables the timestamp
# mode: jackd does, plain arecord does not.  So a card that is not streaming
# already gets a silent measuring stream from phase88-pcm-run (built next to
# this script on first use), which turns the mode on and throws the data away.
#
# Changing 'Multi Track Internal Clock' on a card that jackd owns makes jackd
# xrun, so stop JACK before you switch clock sources.
set -u

HERE=$(dirname "$(readlink -f "$0")")
SEC=20
CARDS=""
while [ $# -gt 0 ]; do
	case $1 in
		-d) SEC=$2; shift 2 ;;
		*) CARDS="$CARDS $1"; shift ;;
	esac
done
[ -n "$CARDS" ] || CARDS=$(awk '/ICE1712/{print $1}' /proc/asound/cards)

if [ ! -x "$HERE/phase88-pcm-run" ] ||
   [ "$HERE/phase88-pcm-run.c" -nt "$HERE/phase88-pcm-run" ]; then
	echo "building phase88-pcm-run ..." >&2
	cc -O2 -Wall -o "$HERE/phase88-pcm-run" "$HERE/phase88-pcm-run.c" \
		-L/usr/lib/x86_64-linux-gnu -l:libasound.so.2 || exit 1
fi

state() { sed -n 's/^state: *\([A-Z]*\).*/\1/p' \
	/proc/asound/card$1/pcm0c/sub0/status 2>/dev/null; }

# a stream that already carries a timestamp (jackd) can be measured as it is
usable() {
	local st ts
	st=$(state $1)
	ts=$(sed -n 's/^tstamp  *: *\([0-9]*\.[0-9]*\).*/\1/p' \
		/proc/asound/card$1/pcm0c/sub0/status 2>/dev/null)
	[ "$st" = RUNNING ] && [ "$ts" != "0.000000000" ]
}

PIDS=""
RUN=""
for c in $CARDS; do
	if usable $c; then
		echo "card $c: measuring the stream that is already running" >&2
		continue
	fi
	"$HERE/phase88-pcm-run" $((SEC + 30)) $c >/tmp/p88clk.$c.log 2>&1 &
	PIDS="$PIDS $!"
	RUN="$RUN $c"
done
[ -n "$PIDS" ] && sleep 3
trap '[ -n "$PIDS" ] && kill $PIDS 2>/dev/null; wait 2>/dev/null' EXIT

snap() { # <card> -> "hw_ptr tstamp"
	local f=/proc/asound/card$1/pcm0c/sub0/status h t
	[ -r "$f" ] || return 1
	h=$(sed -n 's/^hw_ptr  *: *\([0-9]*\).*/\1/p' "$f")
	t=$(sed -n 's/^tstamp  *: *\([0-9]*\.[0-9]*\).*/\1/p' "$f")
	[ -n "$h" ] && [ -n "$t" ] && [ "$t" != "0.000000000" ] && echo "$h $t"
}

# sample all cards repeatedly; the report fits a line through the points, so a
# stray late sample does not move the result
END=$(( $(date +%s) + SEC ))
{
	while [ "$(date +%s)" -lt "$END" ]; do
		for i in $CARDS; do
			read -r h t <<< "$(snap $i)"
			[ -n "$h" ] && echo "$i $h $t"
		done
		sleep 0.4
	done
	for i in $CARDS; do
		read -r h t <<< "$(snap $i)"
		[ -n "$h" ] && echo "$i $h $t"
	done
} | python3 "$HERE/phase88-clock-report.py"

rc=0
for c in $RUN; do
	if [ -s /tmp/p88clk.$c.log ]; then
		echo "--- card $c helper ---"
		cat /tmp/p88clk.$c.log
		rc=1
	fi
done
exit $rc
