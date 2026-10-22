#!/bin/bash
# Install/enable a per-user systemd service that starts JACK at login.
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "run with sudo so the helper and user unit can be installed safely" >&2
	exit 1
fi

HERE=$(dirname "$(readlink -f "$0")")
STARTER="$HERE/phase88-jack-start.sh"
[ -x "$STARTER" ] || { echo "missing executable helper: $STARTER" >&2; exit 1; }

# Install for the desktop user when invoked through sudo; direct root invocation
# installs for root. The service itself still runs unprivileged in that user's session.
TARGET=${SUDO_USER:-root}
ENTRY=$(getent passwd "$TARGET") || { echo "cannot find user: $TARGET" >&2; exit 1; }
UID_NUM=$(printf '%s\n' "$ENTRY" | cut -d: -f3)
HOME_DIR=$(printf '%s\n' "$ENTRY" | cut -d: -f6)
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { echo "invalid home for $TARGET: $HOME_DIR" >&2; exit 1; }

BIN_DIR="$HOME_DIR/.local/bin"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
WANTS_DIR="$UNIT_DIR/default.target.wants"
install -d -m 0755 -o "$TARGET" -g "$(id -gn "$TARGET")" "$BIN_DIR" "$UNIT_DIR" "$WANTS_DIR"
install -m 0755 -o "$TARGET" -g "$(id -gn "$TARGET")" "$STARTER" "$BIN_DIR/phase88-jack-start"

cat > "$UNIT_DIR/phase88-jack.service" <<EOF
[Unit]
Description=JACK audio server for TerraTec PHASE 88

[Service]
Type=simple
Environment=JACK_NO_AUDIO_RESERVATION=1
ExecStart=$BIN_DIR/phase88-jack-start
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
chown "$TARGET:$(id -gn "$TARGET")" "$UNIT_DIR/phase88-jack.service"
chmod 0644 "$UNIT_DIR/phase88-jack.service"
ln -sfn ../phase88-jack.service "$WANTS_DIR/phase88-jack.service"
chown -h "$TARGET:$(id -gn "$TARGET")" "$WANTS_DIR/phase88-jack.service"

# Reload and start immediately if this user already has a live systemd session;
# otherwise the enabled default.target link starts it at the next login.
RUNTIME_DIR="/run/user/$UID_NUM"
if [ -S "$RUNTIME_DIR/bus" ]; then
	if runuser -u "$TARGET" -- env \
		XDG_RUNTIME_DIR="$RUNTIME_DIR" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
		systemctl --user daemon-reload; then
		runuser -u "$TARGET" -- env \
			XDG_RUNTIME_DIR="$RUNTIME_DIR" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
			systemctl --user start phase88-jack.service || {
				echo "unit installed, but it did not start; inspect: systemctl --user status phase88-jack.service" >&2
				exit 1
			}
		echo "installed and started phase88-jack.service for $TARGET"
	else
		echo "unit installed and enabled for $TARGET; it will start at the next login"
	fi
else
	echo "unit installed and enabled for $TARGET; it will start at the next login"
fi

echo "status: run as $TARGET: systemctl --user status phase88-jack.service"
echo "stop/disable: systemctl --user disable --now phase88-jack.service"
echo "If QJackCtl also starts JACK automatically, disable that autostart to avoid competing servers."
