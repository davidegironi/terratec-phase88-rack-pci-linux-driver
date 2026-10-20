#!/bin/bash
# phase88-midi-clocktest.sh - is the corruption on a MIDI port influenced by
# anything the driver can reach?  Two knobs are swept while the same pattern is
# looped back through the suspect socket:
#
#   1. the card's sample-clock setting ('Multi Track Internal Clock'), in case
#      the MPU-401 baud generator is derived from it;
#   2. the PHASE 88 chip-select expander bits (RFC debug controls), in case a
#      board function nobody has mapped yet feeds the MIDI path.
#
# usage: phase88-midi-clocktest.sh <hw:X,Y> [--card N]
#
# Needs the RFC debug module for part 2 (it skips itself if the controls are
# absent) and NOTHING streaming on the cards.  Everything is restored on exit.
set -u

PORT=${1:-}
[ -n "$PORT" ] || { echo "usage: $0 <hw:X,Y> [--card N]"; exit 2; }
shift
CARD=${1:-}
[ "${1:-}" = "--card" ] && CARD=${2:-}
if [ -z "$CARD" ]; then
	CARD=$(printf '%s' "${PORT#hw:}" | cut -d, -f1)
fi
DIAG=$(dirname "$(readlink -f "$0")")/phase88-midi-diag.py
CLK='Multi Track Internal Clock'
HERE=$(dirname "$(readlink -f "$0")")
PATTERN=${PATTERN:-fiftysix}

running() { # any stream on this card?
	for f in /proc/asound/card$CARD/pcm0[pc]/sub0/status; do
		[ -r "$f" ] && grep -q '^state *: *RUNNING' "$f" && return 0
	done
	return 1
}
running && { echo "stop JACK / anything streaming on card $CARD first" >&2; exit 1; }

# NOTE: 'amixer -q cget' prints NOTHING at all (-q suppresses the dump), so the
# reads here must not be quiet.  A quiet read silently returns '' and then the
# restore below would write an empty value and leave the card on the last rate
# the loop used - which is exactly what it did the first time this ran.
rate_of() { # <card> -> current clock enum item
	timeout 10 amixer -c "$1" cget name="$CLK" 2>/dev/null |
		sed -n 's/.*: values=\([0-9]*\).*/\1/p'
}
err_rate() { # one measurement -> 'NN.N'
	timeout 120 python3 "$DIAG" "$PORT" --pattern "$PATTERN" --repeat 3 2>/dev/null |
		sed -n 's/.*mean error rate \([0-9.]*\) %.*/\1/p' | tail -1
}

restore() {
	echo "--- restoring"
	if [ -n "${SAVED_CLK:-}" ]; then
		timeout 10 amixer -q -c "$CARD" cset name="$CLK" "$SAVED_CLK" >/dev/null 2>&1
	else
		echo "    WARNING: the original clock item was not read; card $CARD is left"
		echo "             as the loop set it. Check with: phase88-sync-setup.sh --show"
	fi
	[ -n "${DBG1:-}" ] && timeout 10 amixer -q -c "$CARD" cset numid="$DBG1" 0x20 >/dev/null 2>&1
	[ -n "${DBG3:-}" ] && timeout 10 amixer -q -c "$CARD" cset numid="$DBG3" 0x00 >/dev/null 2>&1
	echo "    card $CARD clock back to item $(rate_of "$CARD"), expander back to page1=0x20 page3=0x00"
}
trap restore EXIT

SAVED_CLK=$(rate_of "$CARD")
[ -n "$SAVED_CLK" ] || { echo "cannot read '$CLK' on card $CARD" >&2; exit 1; }
echo "=== clock / expander sensitivity of MIDI port $PORT (card $CARD) ==="
echo "baseline: clock item $SAVED_CLK"
printf "  %-34s %s\n" "baseline (nothing touched)" "$(err_rate) %"

for item in 8 9 12; do
	[ "$item" = "$SAVED_CLK" ] && continue
	timeout 10 amixer -q -c "$CARD" cset name="$CLK" "$item" >/dev/null 2>&1
	printf "  %-34s %s %%\n" "card clock = item $item" "$(err_rate)"
done
timeout 10 amixer -q -c "$CARD" cset name="$CLK" "$SAVED_CLK" >/dev/null 2>&1

DBG1=$(timeout 10 amixer -c "$CARD" controls 2>/dev/null |
	sed -n "s/numid=\([0-9]*\),iface=CARD,name='Phase88 Debug Expander Page 1'/\1/p")
DBG3=$(timeout 10 amixer -c "$CARD" controls 2>/dev/null |
	sed -n "s/numid=\([0-9]*\),iface=CARD,name='Phase88 Debug Expander Page 3'/\1/p")
if [ -z "$DBG1" ]; then
	echo "  (expander part skipped: the running module has no debug controls;"
	echo "   that is the clean submission build, which is how it should be)"
	exit 0
fi
for v in 0x30 0x60 0xa0 0xf0; do
	timeout 10 amixer -q -c "$CARD" cset numid="$DBG1" "$v" >/dev/null 2>&1
	printf "  %-34s %s %%\n" "expander page 1 = $v" "$(err_rate)"
done
timeout 10 amixer -q -c "$CARD" cset numid="$DBG1" 0x20 >/dev/null 2>&1
if [ -n "$DBG3" ]; then
	for v in 0x01 0x02 0x04 0x08; do
		timeout 10 amixer -q -c "$CARD" cset numid="$DBG3" "$v" >/dev/null 2>&1
		printf "  %-34s %s %%\n" "expander page 3 = $v" "$(err_rate)"
	done
fi
echo
echo "flat across all of it = the driver cannot reach this fault; it is in the"
echo "socket, its line driver / optocoupler, or the UART itself."
