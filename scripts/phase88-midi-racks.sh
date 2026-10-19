#!/bin/bash
# phase88-midi-racks.sh - test all four MIDI sockets of a two-rack PHASE 88 box.
#
# Each PHASE 88 rack has two MIDI interfaces and each one is a separate MPU-401
# UART of the Envy24:
#
#   hw:<card>,0   the FRONT connector of that rack   (MIDI 1)
#   hw:<card>,1   the REAR connector of that rack    (MIDI 2)
#
# The rear one only exists because of the driver quirk that sets
# ICE1712_CFG_2xMPU401; the stock driver registers the front one only.
#
# This script walks the four sockets in order and asks you to move ONE loopback
# cable (5-pin DIN, MIDI OUT -> MIDI IN on the same rack) between them, so you
# do not need four cables.  It calls phase88-midi-test.sh for the actual send
# and compare.
#
# usage:
#   phase88-midi-racks.sh                 walk all four sockets, prompting
#   phase88-midi-racks.sh --yes           same without prompting (all four
#                                         sockets already looped back)
#   phase88-midi-racks.sh --probe         definitive map: tries every
#                                         send/listen combination on a rack, so
#                                         one cable answers "which UART is the
#                                         front and which is the rear"
#   phase88-midi-racks.sh --list          print the socket map and card facts
#   phase88-midi-racks.sh --identify 0    beep on that card's outputs 1/2 so you
#                                         can see which rack is which
#
# Which rack is "rack 1"?  The numbering here comes from /etc/default/phase88
# (PHASE88_RACK1 / PHASE88_RACK2) or the defaults below: rack 1 = the card that
# is the clock SLAVE (its SYNC IN is fed from the other card's SYNC OUT), rack 2
# = the clock MASTER.  Use --identify if you are not sure: make noise on one
# card and look at which rack's meters move.
set -u

HERE=$(dirname "$(readlink -f "$0")")
TEST="$HERE/phase88-midi-test.sh"
[ -x "$TEST" ] || TEST="sh $HERE/phase88-midi-test.sh"

# card numbers of the two racks; override in /etc/default/phase88
RACK1=${PHASE88_RACK1:-0}
RACK2=${PHASE88_RACK2:-1}
[ -r /etc/default/phase88 ] && . /etc/default/phase88
RACK1=${PHASE88_RACK1:-0}
RACK2=${PHASE88_RACK2:-1}

id_of() {
	awk -v c="$1" '$1 == c { gsub(/[][]/, "", $2); print $2 }' /proc/asound/cards
}
pci_of() {
	# /sys/class/sound/cardN/device is a symlink to the PCI device, e.g.
	# /sys/devices/.../0000:03:01.0 - its basename is what lspci prints.
	basename "$(readlink -f "/sys/class/sound/card$1/device" 2>/dev/null)"
}
clock_role() {
	local v
	v=$(amixer -c "$1" cget name='Multi Track Internal Clock' 2>/dev/null |
		awk -F= '/: values=/{print $2}')
	case "$v" in
		13) printf 'clock SLAVE (external clock in)\n' ;;
		9)  printf 'clock MASTER (own oscillator, 48 kHz)\n' ;;
		8)  printf 'own oscillator, 44.1 kHz\n' ;;
		*)  printf 'clock item %s\n' "${v:-?}" ;;
	esac
}

socket_line() {   # $1 = rack label, $2 = card
	printf '%s MIDI 1 (front)  hw:%s,0\n' "$1" "$2"
	printf '%s MIDI 2 (rear)   hw:%s,1\n' "$1" "$2"
}

list_map() {
	local r c
	for r in 1 2; do
		eval "c=\$RACK$r"
		echo "rack #$r = card $c ($(id_of "$c"))  PCI $(pci_of "$c")  $(clock_role "$c")"
		socket_line "rack #$r" "$c"
	done
	echo
	echo "one loopback cable is enough: OUT -> IN on the rack under test."
}

run_one() {       # $1 = label, $2 = port
	echo "--- $1 ($2)"
	timeout 60 $TEST "$2" 2>&1 | sed -n 's/^/    /p'
	echo
}

probe_rack() {    # $1 = card, tries all four send/listen combinations
	local c=$1 a b
	for a in 0 1; do
		for b in 0 1; do
			printf 'card %s send hw:%s,%s -> listen hw:%s,%s : ' "$c" "$c" "$a" "$c" "$b"
			timeout 60 $TEST "hw:$c,$a" "hw:$c,$b" 2>&1 |
				grep -E "^RESULT|received" | tail -2 | tr '\n' ' '
			echo
		done
	done
}

case "${1:-}" in
	--list)
		list_map
		exit 0 ;;
	--identify)
		c=${2:-$RACK1}
		echo "making noise on card $c ($(id_of "$c")) outputs 1 and 2 -"
		echo "the rack whose speakers/meters react is that card."
		timeout 6 amixer -c "$c" cset name='Multi Playback Switch' on >/dev/null 2>&1
		timeout 6 amixer -c "$c" cset name='Multi Playback Volume' 80 >/dev/null 2>&1
		timeout -s INT 6 speaker-test -D "hw:$c,0" -c 10 -r 48000 \
			--format S32_LE -t sine -f 440 -l 0 -p 21000 >/dev/null 2>&1
		echo "done (a 440 Hz tone on outputs 1/2 for a few seconds)."
		exit 0 ;;
	--probe)
		shift
		for c in "$@"; do
			[ -n "$c" ] || c=$RACK1
		done
		for c in "${@:-$RACK1}"; do
			echo "=== probing card $c ($(id_of "$c")) - one loopback cable plugged in"
			probe_rack "$c"
		done
		exit 0 ;;
	--yes)
		BATCH=1; shift ;;
	"") BATCH=0 ;;
	*) echo "unknown argument: $1 (try --list)" >&2; exit 2 ;;
esac

echo "=== PHASE 88 MIDI socket test, $(date) ==="
list_map
echo

RESULTS=""
for r in 1 2; do
	eval "c=\$RACK$r"
	for p in 0 1; do
		name="rack #$r MIDI $((p + 1)) ($([ "$p" = 0 ] && echo front || echo rear))"
		port="hw:$c,$p"
		if [ "$BATCH" != 1 ]; then
			echo ">>> put the loopback cable into ${name} of the rack you call #${r}"
			echo "    (${port}: MIDI OUT straight back into MIDI IN, same rack)"
			printf ">>> press ENTER to test it, or 's' + ENTER to skip: "
			read -r ans
			[ "$ans" = "s" ] && { RESULTS="$RESULTS\nSKIP    $name"; echo "--- $name: SKIP"; echo; continue; }
		fi
		out=$(timeout 60 $TEST "$port" 2>&1); rc=$?
		# Verdict per socket.  Report the verdict of THIS socket, not something
		# scraped back out of $RESULTS (which is one long \n-escaped string, so a
		# 'tail -1' there used to print the FIRST socket's verdict every time).
		if [ "$rc" = 3 ] || echo "$out" | grep -q "PORT BUSY"; then
			verdict="BUSY"
			RESULTS="$RESULTS\nBUSY    $name  $port  (jackd/Reaper holds the port - stop it)"
		elif echo "$out" | grep -q "MIDI WORKS"; then
			verdict="PASS"
			RESULTS="$RESULTS\nPASS    $name  $port"
		elif echo "$out" | grep -q "NO DATA RECEIVED"; then
			verdict="FAIL"
			RESULTS="$RESULTS\nFAIL    $name  $port"
		else
			verdict="UNKNOWN"
			RESULTS="$RESULTS\nUNKNOWN $name  $port"
			echo "$out" | tail -4 | sed 's/^/    /'
		fi
		echo "--- $name ($port): $verdict"
		echo
	done
done

echo "=== summary ==="
printf "%b\n" "$RESULTS"
echo
echo "If a socket FAILED while the same cable PASSED on another one, that DIN is"
echo "either not wired to the Envy24 or it is the UART the driver does not know"
echo "about - run 'phase88-midi-racks.sh --probe $RACK1' with the cable left in"
echo "the failing socket: that tries every send/listen combination and shows"
echo "whether some other port sees the bytes."
