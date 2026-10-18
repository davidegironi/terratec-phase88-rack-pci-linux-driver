#!/bin/bash
# Set sane mixer defaults for the TerraTec PHASE 88.
#
#   usage: phase88-mixer.sh [card-number]
#
# The ICE1712 driver starts with the whole digital monitor mixer and the
# AK4524 muted (as on every board of this family), so without this the card
# is silent on both directions.  Run at boot by phase88-audio.service.
#
# Measured values for this hardware:
#   Multi Playback Switch / H/W Multi Capture Switch   on   = unmuted
#   Multi Playback Volume / H/W Multi Capture Volume   96   = unity gain
#                                    (below 96 it attenuates, 127 = mute)
#   DAC Volume / ADC Volume (AK4524)                   127  = 0 dB
#                                    (0 = mute, 0.5 dB per step)
#
# The front panel microphone pair (inputs 7/8) and the rear aux pair 7/8 share
# the same two codec channels; 'Line/Mic 7/8 Switch' selects between them and
# is OFF by default in the driver.  This script turns the front input on at
# boot.  Override per run with PHASE88_FRONT_MIC=off, or permanently by editing
# the default below.
#
# Everything is applied to every ICE1712 card found, so a second PHASE 88 gets
# the same defaults (pass a card number to configure only one).
set -u
T() { timeout -s KILL 10 "$@"; }
HERE=$(dirname "$(readlink -f "$0")")

FRONT=${PHASE88_FRONT_MIC:-on}

CARDS=${1:-}
for i in 1 2 3 4 5 6 7 8 9 10; do
	[ -n "$CARDS" ] && break
	CARDS=$(T awk '/ICE1712/{print $1}' /proc/asound/cards | tr '\n' ' ')
	sleep 1
done
if [ -z "${CARDS:-}" ]; then
	echo "phase88-mixer: no ICE1712 card, nothing to do" >&2
	exit 1
fi

has_ctl() { # <control name>
	T amixer -c "$CARD" controls | grep -q "name='$1'"
}

set_ctl() { # <control name> <value>
	local name=$1 val=$2 n fail=0
	for n in $(T amixer -c "$CARD" controls |
		   sed -n "s|^numid=\([0-9]*\).*name='$name'.*|\1|p"); do
		T amixer -c "$CARD" cset numid="$n" "$val" >/dev/null 2>&1 || fail=1
	done
	[ $fail -eq 0 ]
}

for CARD in $CARDS; do
	set_ctl 'Multi Playback Switch' on	|| echo "phase88-mixer: card $CARD Multi Playback Switch failed"
	set_ctl 'Multi Playback Volume' 96	|| echo "phase88-mixer: card $CARD Multi Playback Volume failed"
	set_ctl 'DAC Volume' 127		|| echo "phase88-mixer: card $CARD DAC Volume failed"
	set_ctl 'H/W Multi Capture Switch' on	|| echo "phase88-mixer: card $CARD H/W capture switch failed"
	set_ctl 'H/W Multi Capture Volume' 96	|| echo "phase88-mixer: card $CARD H/W capture volume failed"
	set_ctl 'ADC Volume' 127		|| echo "phase88-mixer: card $CARD ADC Volume failed"

	# front panel mic pair (7/8) vs rear aux pair (7/8); older drivers without
	# this control are skipped silently
	if has_ctl 'Line/Mic 7/8 Switch'; then
		set_ctl 'Line/Mic 7/8 Switch' "$FRONT" \
			|| echo "phase88-mixer: card $CARD front input switch failed"
	fi
	echo "phase88-mixer: card $CARD unmuted (monitor mixer unity, AK4524 0 dB, front input $FRONT)"
done

# ---- word clock between two PHASE 88 cards --------------------------------
# /etc/default/phase88 says which card takes its clock from the other one
# through the sync cable (PHASE88_SYNC_SLAVE=<card>, empty = off).  This has
# to happen before anything opens the cards: snd_ice1712_set_pro_rate()
# (ice1712.c:979) drops a clock change while a stream of that card runs, so a
# late 'amixer cset' would look like it worked and do nothing.
if [ -r /etc/default/phase88 ]; then
	. /etc/default/phase88
	if [ -n "${PHASE88_SYNC_SLAVE:-}" ] &&
	   [ "$(T awk '/ICE1712/{print $1}' /proc/asound/cards | wc -w)" -ge 2 ]; then
		if "$HERE/phase88-sync-setup.sh" >>/dev/null 2>&1; then
			echo "phase88-mixer: word clock set (slave card $PHASE88_SYNC_SLAVE)"
		else
			echo "phase88-mixer: word clock setup refused (streams running, or one card)" >&2
		fi
	fi
fi

# NOTE: this deliberately does not touch /var/lib/alsa/asound.state.  The
# standard alsa-restore path runs from a udev rule when the card appears,
# this script runs later (multi-user.target), so these defaults win.  If you
# want your own levels instead, remove the phase88-mixer.sh line from
# /etc/systemd/system/phase88-audio.service and save them with 'alsactl store'.
