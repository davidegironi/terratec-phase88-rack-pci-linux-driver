#!/bin/bash
# Which clock path does the PHASE 88 sync cable actually drive?
#
#   usage: phase88-sync-probe.sh [-d seconds] [phase ...]
#          phase88-sync-probe.sh --list
#
# Wiring assumed: the SYNC OUT of the master card goes to the SYNC IN of the
# slave card, i.e. the slave is the card that can be locked.  Find out which
# ALSA card is which with:  grep ICE1712 /proc/asound/cards  (and lspci -nn).
#
# The Envy24 (VT1712) has exactly two clock inputs the driver can reach, and
# this script measures what each one does with the sync cable attached:
#
#   internal    RATE register (item 8 = internal 48k of the 'Multi Track
#               Internal Clock' control, numid 42) - the chip divides its own
#               oscillator.  This is the default on both cards.
#   IEC958      bit 0x10 ICE1712_SPDIF_MASTER of the same register (item 13
#               'IEC958 Input') - clock recovered from the serial input.
#   EXT         bit 0x80 ICE1712_CFG_EXT of PCI config 0x60 (ice1712.h:180).
#               The driver never touches this bit; the EEPROM value is written
#               to config space once at probe (ice1712.c:2316).
#
# Proof of a lock is the capture rate measured from the DMA position/timestamp
# pairs in /proc (phase88-clock-measure.sh): a free running slave sits a few
# ppm away from the master and wanders, a locked one reads the master's rate.
#
# jackd is NOT stopped here.  Switching the clock of the card jackd owns makes
# it xrun for the duration of that phase - it recovers when the phase ends.
# The other card is measured with the silent helper stream of phase88-pcm-run.
set -u

SEC=40
CARDS=$(awk '/ICE1712/{print $1}' /proc/asound/cards)
HERE=$(dirname "$(readlink -f "$0")")
CLK='Multi Track Internal Clock'
INT_ITEM=9		# internal 48 kHz: the enum item is NOT the register value
			# (items: 8 = 44100, 9 = 48000, 13 = IEC958 Input)
EXT_ITEM=13		# 'IEC958 Input'
ITEMS=()

if [ "$(echo $CARDS | wc -w)" -lt 2 ]; then
	echo "need two ICE1712 cards, found: $CARDS" >&2
	exit 1
fi
C0=$(echo $CARDS | awk '{print $1}')	# first ALSA card = sync slave
C1=$(echo $CARDS | awk '{print $2}')	# second ALSA card = sync master
# PCI function of each card, so setpci can reach config byte 0x60
P0=$(basename "$(readlink -f /sys/class/sound/card$C0/device)")
P1=$(basename "$(readlink -f /sys/class/sound/card$C1/device)")

cfg_get() { setpci -s "$1" 0x60.b; }
cfg_set() { setpci -s "$1" 0x60.b="$2"; }
clk() { timeout 10 amixer -q -c "$1" cset name="$CLK" "$2" >/dev/null 2>&1; }
has() { timeout 10 amixer -c "$1" cget name="$2" >/dev/null 2>&1; }
codec_init() {
	has $1 'Phase88 Debug Codec Init' &&
		timeout 10 amixer -q -c $1 cset name='Phase88 Debug Codec Init' 1 >/dev/null 2>&1
}
restore() {
	echo "--- restoring both cards to their own oscillator"
	cfg_set $P0 $(cfg_base $P0); cfg_set $P1 $(cfg_base $P1)
	clk $C0 $INT_ITEM; clk $C1 $INT_ITEM
	codec_init $C0; codec_init $C1
}
# the value the driver left in config 0x60 (EEPROM codec byte, 0x1f here) plus
# whatever the driver writes: keep a copy of it so EXT can be cleared without
# guessing the rest of the byte
cfg_base() {
	local v=$(cfg_get $1)
	printf '0x%02x' $(( $(printf 0x%s "$v") & ~0x80 ))
}
trap restore EXIT

phase() { # <name> <body ...>  - body configures the clocks, then we measure
	local name=$1; shift
	echo
	echo "=============================================================="
	echo "PHASE: $name"
	echo "  card $C0 ($P0) config 0x60 = $(cfg_get $P0), clock item $(clock_of $C0)"
	echo "  card $C1 ($P1) config 0x60 = $(cfg_get $P1), clock item $(clock_of $C1)"
	"$@"
	sleep 2
	echo "  measuring ${SEC}s ..."
	timeout $((SEC + 60)) "$HERE/phase88-clock-measure.sh" -d "$SEC" $C0 $C1 2>&1 |
		grep -vE '^(card [0-9]+: measuring|building)'
}
clock_of() { sed -n 's/^  RATE  *: *0x\(.*\)/\1/p' /proc/asound/card$1/ice1712; }

do_internal() { clk $C0 $INT_ITEM; clk $C1 $INT_ITEM; }
do_ext_slave()  { cfg_set $P0 $(printf '0x%02x' $(( $(cfg_base $P0) | 0x80 ))); }
do_iec958_slave() { clk $C0 $EXT_ITEM; }

while [ $# -gt 0 ]; do
	case $1 in
		-d) SEC=$2; shift 2 ;;
		--list) sed -n '1,32p' "$0"; exit 0 ;;
		*) ITEMS+=("$1"); shift ;;
	esac
done

echo "card $C0 = $(cat /proc/asound/card$C0/id) ($P0)"
echo "card $C1 = $(cat /proc/asound/card$C1/id) ($P1)"
pgrep -x jackd >/dev/null &&
	echo "note: jackd is running and will xrun while the card it owns is re-clocked"

phase "both cards on their own oscillator (free running reference)" do_internal
phase "card $C0 (slave) EXT clock bit set in PCI config 0x60" do_ext_slave
phase "card $C0 (slave) clock from 'IEC958 Input'" do_iec958_slave

echo
echo "=============================================================="
echo "How to read this:"
echo " * the reference phase shows the drift between the two free oscillators;"
echo "   a couple of ppm is normal, and it is what a failed lock looks like."
echo " * a locked slave reads the master's rate: the difference drops far below"
echo "   the reference value (well under 1 ppm) and stays there."
echo " * a rate of about 44100 while the card is programmed for 48000 means the"
echo "   EXT input is the on-board 44.1 kHz family oscillator, i.e. the sync"
echo "   header is NOT the chip's clock input."
echo " * a rate far off 48000 or a DMA that stops means that input has no clock."
