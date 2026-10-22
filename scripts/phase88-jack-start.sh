#!/bin/bash
# Start JACK on the available PHASE 88 device: combine both cards if present.
set -eu

CARDS=$(awk '/ICE1712/{n++} END {print n+0}' /proc/asound/cards 2>/dev/null || echo 0)
case "$CARDS" in
	0)
		echo "phase88-jack: no PHASE 88 card found; nothing to start"
		exit 0
		;;
	1) DEVICE=hw:Phase88 ;;
	2) DEVICE=phase88x2 ;;
	*)
		echo "phase88-jack: found $CARDS PHASE 88 cards; supports one or two" >&2
		exit 1
		;;
esac

if pgrep -x jackd >/dev/null 2>&1; then
	echo "phase88-jack: JACK is already running; leaving the existing server alone"
	exit 0
fi

command -v jackd >/dev/null 2>&1 || {
	echo "phase88-jack: jackd not found; install a JACK server first" >&2
	exit 1
}

# No session D-Bus device reservation is available in every user-manager
# environment. This matches the documented workaround for systemd-launched JACK.
export JACK_NO_AUDIO_RESERVATION=1

echo "phase88-jack: starting JACK with $DEVICE (48 kHz, period 1024, 2 periods)"
exec jackd -d alsa -d "$DEVICE" -r 48000 -p 1024 -n 2
