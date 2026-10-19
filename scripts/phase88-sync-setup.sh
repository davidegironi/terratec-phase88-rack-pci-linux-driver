#!/bin/bash
# Set up master/slave word clock between two PHASE 88 cards.
#
#   usage: phase88-sync-setup.sh [--show] [master-card [slave-card]]
#          phase88-sync-setup.sh --off [card ...]
#
# This box as wired:  card 0 = hw:Phase88   = PCI 03:01.0 = SYNC IN  = slave
#                     card 1 = hw:Phase88_1 = PCI 03:02.0 = SYNC OUT = master
#
# What the sync cable carries (measured, see analysis/README.md): the clock of
# the master card, into the clock input the Envy24 calls 'IEC958 Input'.  The
# proof: with 'Multi Track Internal Clock' = 'IEC958 Input' on the slave and
# the master pulled 8.1 % slow (EXT bit), the slave's capture DMA slowed by the
# identical amount, -81295 ppm against -81292 ppm.
#
# Facts this script depends on:
#   * the master drives its SYNC OUT even while it is idle, so the slave has a
#     clock even when only the slave is streaming;
#   * a card on 'IEC958 Input' with an EMPTY clock input does not stall, it
#     free runs at about 33168 frames/s - so if you unplug the cable, run
#     'phase88-sync-setup.sh --off' or JACK will run at the wrong speed;
#   * snd_ice1712_set_pro_rate() (ice1712.c:979) returns without writing while
#     a stream of that card is running, so the clock source must be set before
#     JACK or PulseAudio opens the card.  This script refuses to do it silently
#     in that case;
#   * once the slave is on 'IEC958 Input' the driver treats the rate as locked
#     (is_pro_rate_locked(), ice1712.c:113), so jackd starting at 48 kHz no
#     longer reprograms the clock on either card.
#
# /etc/default/phase88:
#   PHASE88_SYNC_MASTER=1
#   PHASE88_SYNC_SLAVE=0
set -u

CLK='Multi Track Internal Clock'
ITEM_48K=9		# enum item 9 = 48000; item 8 is 44100, item 13 is IEC958
ITEM_IEC958=13
CONF=/etc/default/phase88
MASTER=${PHASE88_SYNC_MASTER:-}
SLAVE=${PHASE88_SYNC_SLAVE:-}
[ -r $CONF ] && . $CONF

off=""
show=""
while [ $# -gt 0 ]; do
	case $1 in
		--off) off=1; shift ;;
		--show) show=1; shift ;;
		[0-9]*) if [ -z "$MASTER" ]; then MASTER=$1; else SLAVE=$1; fi; shift ;;
		*) shift ;;
	esac
done

cards=$(awk '/ICE1712/{print $1}' /proc/asound/cards)
n=$(echo $cards | wc -w)

label_of() { # <item> - the enum item is not the register value: 8 = 44100,
		 # 9 = 48000, 13 = IEC958 Input (snd_ice1712_pro_internal_clock_info)
	case $1 in
		13) echo "IEC958 Input = external clock" ;;
		9)  echo "48000 = own oscillator" ;;
		8)  echo "44100 = own oscillator" ;;
		*)  echo "own oscillator" ;;
	esac
}
# the human-readable label of the rate a card is set to, e.g. '48000'
rate_label_of() {
	local it; it=$(name_of $1)
	timeout 10 amixer -c "$1" cget name="$CLK" 2>/dev/null |
		sed -n "s/.*Item #$it '\([^']*\)'.*/\1/p"
}

show_state() {
	local c it slaves="" other
	for c in $cards; do
		it=$(name_of $c)
		printf "card %s (%s): 'Multi Track Internal Clock' = %s (%s)\n" \
			$c "$(cat /proc/asound/card$c/id)" "$it" "$(label_of $it)"
		[ "$it" = "$ITEM_IEC958" ] && slaves="$slaves $c"
	done
	# A card on an external clock is also rate-locked: the driver clamps
	# rate_min = rate_max in snd_ice1712_playback_pro_open() while
	# is_pro_rate_locked() is true (ice1712.c:1122), so a slave accepts ONLY the
	# rate the master sends.  Say so, because jackd failing at 96 kHz on a card
	# that happily did 96 kHz yesterday looks like a broken driver.
	if [ -n "$slaves" ]; then
		for c in $cards; do
			case " $slaves " in *" $c "*) continue ;; esac
			echo "note: card(s)$slaves are SLAVES - they accept only the master's rate,"
			echo "      which card $c is sending ($(rate_label_of $c)).  To record at 96 kHz,"
			echo "      set the MASTER's 'Multi Track Internal Clock' to 96000 first, then"
			echo "      start JACK at 96000; a slave asked for another rate will not open."
			break
		done
	fi
}
streaming() { # <card> -> 0 if a pcm stream of that card is RUNNING
	local f
	for f in /proc/asound/card$1/pcm0[pc]/sub0/status; do
		[ -r $f ] && grep -q '^state *: *RUNNING' "$f" && return 0
	done
	return 1
}
setclk() { # <card> <item>
	timeout 10 amixer -q -c "$1" cset name="$CLK" "$2" >/dev/null 2>&1
}
name_of() { timeout 10 amixer -c "$1" cget name="$CLK" 2>/dev/null |
	sed -n 's/.*: values=\([0-9]*\).*/\1/p'; }

if [ -n "$show" ]; then show_state; exit 0; fi

if [ -n "$off" ]; then
	for c in $cards; do
		[ "$(name_of $c)" = "$ITEM_IEC958" ] || continue
		if streaming $c; then
			echo "card $c: on IEC958 Input but a stream is running - stop it first" >&2
			continue
		fi
		setclk $c $ITEM_48K && echo "card $c: back on its own oscillator (48000)"
	done
	show_state
	exit 0
fi

if [ "$n" -lt 2 ]; then
	echo "only one ICE1712 card present ($cards); nothing to sync" >&2
	exit 1
fi
[ -n "$MASTER" ] || MASTER=$(echo $cards | awk '{print $2}')
[ -n "$SLAVE" ] || SLAVE=$(echo $cards | awk '{print $1}')

echo "master = card $MASTER ($(cat /proc/asound/card$MASTER/id)), SYNC OUT"
echo "slave  = card $SLAVE ($(cat /proc/asound/card$SLAVE/id)), SYNC IN"

rc=0
for c in $MASTER $SLAVE; do
	if streaming $c; then
		echo "card $c has a RUNNING stream: the driver would ignore a clock change." >&2
		echo "stop JACK (and anything else on the card) and run this again." >&2
		exit 1
	fi
done

setclk $MASTER $ITEM_48K
setclk $SLAVE $ITEM_IEC958
sleep 1
[ "$(name_of $MASTER)" != "$ITEM_IEC958" ] || { echo "master did not switch" >&2; rc=1; }
[ "$(name_of $SLAVE)" = "$ITEM_IEC958" ] || { echo "slave did not switch" >&2; rc=1; }
show_state
if [ $rc -eq 0 ]; then
	cat <<EOF

Both cards are set.  The slave now runs off the clock of the master, so start
JACK over both cards with the combined ALSA device from /etc/asound.conf:

	jackd -d alsa -d phase88x2 -r 48000 -p 1024

(in QJackCtl: set 'ALSA Device Name' to phase88x2.)  That gives 16 inputs and
16 outputs, 1..8 from the master card and 9..16 from the slave card.

Check it with:  phase88-sync-follow.sh   and   phase88-clock-measure.sh
If you unplug the sync cable, run:  phase88-sync-setup.sh --off
EOF
fi
exit $rc
