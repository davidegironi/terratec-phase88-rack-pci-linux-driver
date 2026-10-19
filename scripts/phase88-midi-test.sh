#!/bin/bash
# phase88-midi-test.sh - does a PHASE 88 MIDI port actually send and receive?
#
# Linux registers one MPU-401 UART per card (the EEPROM Codec byte of the
# PHASE 88 is 0x0f, so ICE1712_CFG_2xMPU401 (0x20) is clear and only
# /dev/snd/midiCxD0 is created).  The Terratec Windows driver installs two,
# "PHASE88 MIDI Port 1" and "PHASE88 MIDI Port 2" (see
# driver/win/ews88wdm.inf, [PHASE88.Interface.Midi1/2]; its
# history says "17-Sep-02 - Mic28 Extensions (Midi 2)").  Whether the second
# UART is wired to a connector on your rack is a hardware question: look at the
# rack, if it has two MIDI INs tell me and it is a one-line quirk to enable the
# second UART.
#
# This script proves the electrical path, which nothing else here can: the
# driver accepts writes whether or not anything is plugged in.
#
# usage:
#   phase88-midi-test.sh                     loopback on card 0: cable from that
#                                            rack's MIDI OUT to its MIDI IN
#   phase88-midi-test.sh hw:Phase88_1        same, on the other card
#   phase88-midi-test.sh --cross OUT IN      one cable between two racks:
#                                            OUT's MIDI OUT -> IN's MIDI IN
#   phase88-midi-test.sh --note              also send a note so a synth or
#                                            keyboard attached to the OUT plays
#   phase88-midi-test.sh --watch [hw:X,Y] [secs]
#                                            listen only and print what arrives:
#                                            for "I pressed a key on the synth"
#                                            or "does the second DIN react"
#
# Nothing here needs JACK.  jackd with a MIDI backend and PipeWire can hold the
# ports; the script tells you when that is the case, it does not kill anything.

set -u
A_OUT="hw:Phase88"
A_IN="hw:Phase88"
NOTE=0
CROSS=0
WATCH=0
WSECS=15

OUTSET=0
INSET=0
while [ $# -gt 0 ]; do
	case "$1" in
		--cross) CROSS=1; shift ;;
		--note)  NOTE=1; shift ;;
		--watch) WATCH=1; shift ;;
		[0-9]*)  WSECS="$1"; shift ;;   # bare number = watch/listen seconds
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		hw:*)
			# first port argument is the sender, the second the listener
			if [ "$OUTSET" = 0 ]; then A_OUT="$1"; OUTSET=1
			elif [ "$INSET" = 0 ]; then A_IN="$1"; INSET=1
			else echo "too many ports given (one sender, one listener)" >&2; exit 2
			fi
			shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ "$INSET" = 0 ]; then
	if [ "$CROSS" = 1 ]; then
		echo "--cross needs two ports: the sending card and the listening card" >&2
		exit 2
	fi
	A_IN="$A_OUT"	# plain loopback on one card
fi
if [ "$CROSS" = 1 ] && [ "$A_OUT" = "$A_IN" ]; then
	echo "--cross with the same port on both sides is a loopback; drop --cross" >&2
	exit 2
fi

# --watch: pure listener, nothing to compare against.  It answers the question
# "is anything at all arriving on this DIN?", which is what you need when a
# synth is attached and you do not know which of the two UARTs is wired.
if [ "$WATCH" = 1 ]; then
	GOT=$(mktemp /tmp/p88-watch-XXXX.raw)
	echo "phase88-midi-test: listening on $A_IN for $WSECS s - send something now"
	echo "  (press a key on a synth wired to that DIN, or run amidi -s on the other end)"
	timeout $((WSECS + 5)) amidi -p "$A_IN" -r "$GOT" -t "$WSECS" >/dev/null 2>&1
	N=$(wc -c < "$GOT")
	echo "  received $N bytes"
	if [ "$N" -gt 0 ]; then
		od -Ad -tx1z "$GOT" | head -12
		rm -f "$GOT"
		exit 0
	fi
	rm -f "$GOT"
	echo "  nothing arrived.  If you are sure something was sent, try the other"
	echo "  UART of that card (hw:0,1 or hw:1,1 - the second one only exists when"
	echo "  snd_ice1712 is loaded with mpu401_2=1), and check that the cable goes"
	echo "  into the connector labelled OUT at the sending device."
	exit 1
fi

# Payload: a SysEx block (byte-exact, no timing, so it is easy to compare) plus
# a GM note so a device on the other end is audible.  F0 ... F7 with a
# manufacturer id of 0x43 (Yamaha) and a made-up model id; harmless to
# everything else on the bus.
PAYLOAD=$(mktemp /tmp/p88-midi-XXXX.syx)
trap 'rm -f "$PAYLOAD"' EXIT
printf '\xf0\x43\x12\x00phase88\xf7' > "$PAYLOAD"
printf '\xb0\x07\x64' >> "$PAYLOAD"	# CC 7 volume, so a synth has something to say
if [ "$NOTE" = 1 ]; then
	printf '\x90\x3c\x66' >> "$PAYLOAD"	# note on C4, velocity 102
	printf '\xf8\xf8\xf8' >> "$PAYLOAD"	# a few clock bytes: real clocks if a
						# master is involved, ignored by the
						# UART test itself
	NOTE_ON_GONE=1
else
	printf '\x90\x3c\x00' >> "$PAYLOAD"	# note off again immediately
fi

echo "phase88-midi-test: out=$A_OUT in=$A_IN payload=$(wc -c < "$PAYLOAD") bytes"

# Is anything else holding the rawmidi devices?  Exclusive use would make this
# fail with EBUSY and that is not a hardware fault.
# hw: accepts a card number, 'hw:0,1', or the card id string ('hw:Phase88',
# 'hw:Phase88_1'), so resolve it through /proc/asound/cards rather than
# pattern-matching a number.
card_of() {
	local p=${1#hw:}
	case "$p" in
		[0-9]*) printf '%s\n' "${p%%,*}"; return 0 ;;
	esac
	awk -v id="$p" '{ gsub(/[][]/, "", $2); if ($2 == id) { print $1; exit } }' \
		/proc/asound/cards
}
device_of() {
	local p=${1#hw:}
	case "$p" in
		*,*) printf '%s\n' "${p#*,}" ;;
		*)   printf '0\n' ;;
	esac
}

SEEN=""
for p in "$A_OUT" "$A_IN"; do
	num=$(card_of "$p")
	[ -z "$num" ] && { echo "  (cannot map $p to a card number, continuing)"; continue; }
	dev="/dev/snd/midiC${num}D$(device_of "$p")"
	case " $SEEN " in *" $dev "*) continue ;; esac   # loopback: same device twice
	SEEN="$SEEN $dev"
	if command -v fuser >/dev/null 2>&1 && [ -e "$dev" ]; then
		holders=$(fuser "$dev" 2>/dev/null || true)
		[ -n "$holders" ] && echo "  NOTE: $dev is held by: $holders"
	fi
done

# A rawmidi device allows one client: jackd (-X seq or -X raw) and Reaper's own
# ALSA MIDI backend keep it open, and the resulting EBUSY looks like broken
# hardware if it is not called out.
report_busy() {
	cat <<EOF
RESULT: PORT BUSY - something else owns the raw MIDI device.
  jackd with a MIDI backend (-X seq or -X raw) and Reaper's own ALSA MIDI
  backend keep /dev/snd/midiCxDy open, and a rawmidi device allows only one
  client at a time.  Stop JACK (QJackCtl 'Stop') or Reaper, run this again,
  and check the JACK path separately if you need it with JACK running.
EOF
	exit 3
}

GOT=$(mktemp /tmp/p88-midi-got-XXXX.syx)
trap 'rm -f "$PAYLOAD" "$GOT"' EXIT

# Listen first, then send: the MPU-401 UART has a small FIFO and no flow control
# worth the name, so a send before the reader is up can lose the start of the
# stream and look like broken hardware.
timeout 12 amidi -p "$A_IN" -r "$GOT" -t 5 >/tmp/p88-midi-rx.log 2>&1 &
RX=$!
sleep 1

REPEAT=3
i=1
while [ $i -le $REPEAT ]; do
	if ! timeout 10 amidi -p "$A_OUT" -s "$PAYLOAD" 2>/tmp/p88-midi-tx.err; then
		grep -qi busy /tmp/p88-midi-tx.err && report_busy
		echo "  FAIL: amidi could not send on $A_OUT: $(cat /tmp/p88-midi-tx.err)"
		kill $RX 2>/dev/null
		exit 1
	fi
	i=$((i + 1))
	sleep 0.4
done
echo "  sent $REPEAT x $(wc -c < "$PAYLOAD") bytes on $A_OUT, waiting for $A_IN ..."
wait $RX
RC=$?

RXB=$(wc -c < "$GOT")
TXB=$(wc -c < "$PAYLOAD")
if grep -qi busy /tmp/p88-midi-rx.log 2>/dev/null; then
	report_busy
fi
echo "  received $RXB bytes on $A_IN (amidi exit $RC)"
echo -n "  sent     : "; od -An -tx1 "$PAYLOAD" | tr -s ' '
if [ "$RXB" -gt 0 ]; then
	echo -n "  received : "; od -An -tx1 "$GOT" | tr -s ' '
fi

if [ "$RXB" -eq 0 ]; then
	cat <<EOF

RESULT: NO DATA RECEIVED.
  The driver accepted every write, so the software side is fine.  Either
    * no cable: this test needs MIDI OUT of the source looped to MIDI IN of the
      same (loopback) or the other (cross) rack, or
    * the cable is in the other socket: hw:<card>,0 is the rack's FRONT MIDI,
      hw:<card>,1 the REAR one, and both carry the same name in amidi -l, so
      the number is all that tells them apart.  Try the other number, or run
      'phase88-midi-racks.sh --probe <card>' which tries every combination,
      or
    * the DIN wiring is the odd 'all poles swapped' kind (rare on Terratec).
  'amidi exit 0' here means its -t idle timeout expired with an empty buffer;
  exit 124 means the outer timeout did.  Neither is a driver error.
EOF
	exit 1
fi

# Compare loosely: count how many whole payloads arrived.  The UART can merge or
# split reads, so byte-for-byte equality of the file is not required.
N=$(python3 - "$PAYLOAD" "$GOT" <<'PY'
import sys
pay = open(sys.argv[1], 'rb').read()
got = open(sys.argv[2], 'rb').read()
print(got.count(pay), len(got))
PY
)
set -- $N
HITS=$1
echo "  complete payload frames found: $HITS"
if [ "$HITS" -ge 1 ]; then
	echo "RESULT: MIDI WORKS - the bytes came back intact (frame(s) seen: $HITS)."
	exit 0
fi
echo "RESULT: data arrived but not the payload frame - partial or corrupted."
echo "        Try the other card, and check the cable is MIDI OUT -> MIDI IN."
exit 1
