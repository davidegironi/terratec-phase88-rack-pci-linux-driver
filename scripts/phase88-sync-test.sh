#!/bin/bash
# Does the PHASE 88 sync cable carry a clock the Envy24 can lock to?
#
#   usage: phase88-sync-test.sh [-d seconds] [round ...]
#
# Stop QJackCtl first: jackd owns hw:Phase88, and switching the clock source
# under a running stream makes it xrun.  This script needs both cards free.
#
# The Envy24 has exactly one external clock input in the Linux driver:
# 'Multi Track Internal Clock' = 'IEC958 Input' sets bit 0x10
# (ICE1712_SPDIF_MASTER, ice1712.h:143) of the multi-track RATE register.
# Nothing in the PHASE 88 path drives a "sync out", so the master side may
# have to be enabled through the chip select expander.  The rounds below try
# both directions and the bits that were inert for audio (page 0x01 bits 0x40
# and 0x80), which is where a sync output enable would sit.
#
# Every round measures the real capture clock of both cards from the DMA
# position/timestamp pairs in /proc (see phase88-clock-measure.sh).  A slave
# that locked reads the same rate as the master, far below 1 ppm.
#
# The RFC controls 'Phase88 Debug Expander Page 1' and 'Phase88 Debug Codec
# Init' come from the DO-NOT-SUBMIT commit c021a09f3; without them the script
# only runs the plain rounds.
set -u

SEC=12
CARDS=$(awk '/ICE1712/{print $1}' /proc/asound/cards)
HERE=$(dirname "$(readlink -f "$0")")
CLK='Multi Track Internal Clock'
INT_ITEM=9	# 48 kHz: item 8 is 44100, item 9 is 48000 (item != register value)
EXT_ITEM=13	# 'IEC958 Input'

while [ $# -gt 0 ]; do
	case $1 in
		-d) SEC=$2; shift 2 ;;
		-h) sed -n '1,30p' "$0"; exit 0 ;;
		*) shift ;;
	esac
done

if pgrep -x jackd >/dev/null; then
	echo "jackd is running and holds a card." >&2
	echo "press Stop in QJackCtl (or: jack_control stop) and run this again." >&2
	exit 1
fi
[ "$(echo $CARDS | wc -w)" -ge 2 ] || { echo "need two ICE1712 cards" >&2; exit 1; }

C0=$(echo $CARDS | awk '{print $1}')
C1=$(echo $CARDS | awk '{print $2}')

has() { timeout 10 amixer -c "$1" cget name="$2" >/dev/null 2>&1; }
clk() { timeout 10 amixer -q -c "$1" cset name="$CLK" "$2" >/dev/null 2>&1; }
page1() { # <card> <value>
	has $1 'Phase88 Debug Expander Page 1' &&
		timeout 10 amixer -q -c $1 cset name='Phase88 Debug Expander Page 1' "$2" \
			>/dev/null 2>&1
}
codec_init() {
	has $1 'Phase88 Debug Codec Init' &&
		timeout 10 amixer -q -c $1 cset name='Phase88 Debug Codec Init' 1 \
			>/dev/null 2>&1
}
restore() {
	clk $C0 $INT_ITEM; clk $C1 $INT_ITEM
	page1 $C0 0x20; page1 $C1 0x20
	codec_init $C0; codec_init $C1
}
trap restore EXIT

round() { # <name> <slave|-> <master page1 value|->
	local name=$1 slave=$2 bits=${3:-}
	restore
	if [ -n "$bits" ]; then
		local master=$C0; [ "$slave" = "$C0" ] && master=$C1
		page1 $master "0x$(printf '%x' $((0x20 | bits)))"
	fi
	[ -n "$slave" ] && clk $slave $EXT_ITEM
	sleep 1
	echo
	echo "=============================================================="
	echo "ROUND: $name"
	[ -n "$slave" ] && echo "  card $slave on external clock, card $((slave ^ 1)) on its own"
	[ -n "$bits" ] && printf '  master expander page 1 = 0x%02x\n' $((0x20 | bits))
	timeout $((SEC + 45)) "$HERE/phase88-clock-measure.sh" -d "$SEC" 2>&1 |
		grep -vE '^card [0-9]+: measuring'
}

echo "card $C0 = $(cat /proc/asound/card$C0/id),  card $C1 = $(cat /proc/asound/card$C1/id)"
has $C0 'Phase88 Debug Expander Page 1' ||
	echo "note: no RFC expander controls in this module, only the plain rounds run"

round "both cards on their own oscillator (reference)" ""
round "card $C0 slave, card $C1 master" $C0
round "card $C1 slave, card $C0 master" $C1
for b in 0x40 0x80 0xc0; do
	round "card $C0 slave, master sync-out guess page1 bit $b" $C0 $b
	round "card $C1 slave, master sync-out guess page1 bit $b" $C1 $b
done

restore
echo
echo "=============================================================="
echo "Reading the result:"
echo " * the reference round shows how far apart the two free oscillators are;"
echo "   anything of that order means the slave did not lock."
echo " * a locked slave prints a difference far below that, and no overrun."
echo " * 'timestamp did not advance' or a rate nowhere near 48000 means the"
echo "   selected external input has no clock on it at all."
