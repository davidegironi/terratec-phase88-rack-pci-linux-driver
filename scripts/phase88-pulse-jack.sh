#!/bin/bash
# Load the PulseAudio JACK bridge once both PulseAudio and JACK are available.
set -euo pipefail

SINK_NAME=phase88_jack_out
SOURCE_NAME=phase88_jack_in

has_module() {
	local module=$1 name=$2
	pactl list short modules | awk -v module="$module" -v arg="$name" \
		'$2 == module && index($0, arg) { found = 1 } END { exit !found }'
}

ensure_module() {
	local module=$1 name=$2
	shift 2
	has_module "$module" "$name" || pactl load-module "$module" "$@" >/dev/null
}

# JACK can take a moment to initialise its ALSA backend after systemd starts it.
# pactl info also activates PulseAudio through its user socket if needed. Do not
# let jack_lsp spawn an accidental second server if the configured JACK failed.
for attempt in $(seq 1 60); do
	PA_INFO=$(pactl info 2>/dev/null || true)
	if [ -n "$PA_INFO" ]; then
		if printf '%s\n' "$PA_INFO" | grep -qi 'PipeWire'; then
			echo "phase88-pulse-jack: pactl is connected to PipeWire, not PulseAudio; use the PipeWire JACK bridge instead" >&2
			exit 1
		fi
		if JACK_NO_START_SERVER=1 jack_lsp system:playback_1 >/dev/null 2>&1 \
			&& ensure_module module-jack-sink "sink_name=$SINK_NAME" \
				sink_name="$SINK_NAME" channels=2 connect=yes \
			&& ensure_module module-jack-source "source_name=$SOURCE_NAME" \
				source_name="$SOURCE_NAME" channels=2 connect=yes; then
			pactl set-default-sink "$SINK_NAME"
			pactl set-default-source "$SOURCE_NAME"
			echo "phase88-pulse-jack: PulseAudio is bridged to JACK (stereo)"
			exit 0
		fi
	fi
	sleep 1
done

echo "phase88-pulse-jack: timed out waiting for PulseAudio/JACK or loading bridge modules" >&2
exit 1
