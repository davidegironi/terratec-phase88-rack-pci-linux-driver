#!/bin/bash
# Install JACK plus a per-user PulseAudio-to-JACK bridge for a desktop account.
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: sudo scripts/phase88-install-jackpulse.sh [desktop-user]

Run from the target desktop user's account with sudo, or pass that user's
name when running as root. The target must be a non-root account.
EOF
}

if [ "$(id -u)" -ne 0 ]; then
	echo "run with sudo, or as root with an explicit desktop username" >&2
	exit 1
fi
[ "$#" -le 1 ] || { usage >&2; exit 2; }

TARGET=${1:-${SUDO_USER:-}}
[ -n "$TARGET" ] || { usage >&2; exit 2; }
ENTRY=$(getent passwd "$TARGET") || { echo "cannot find user: $TARGET" >&2; exit 1; }
UID_NUM=$(printf '%s\n' "$ENTRY" | cut -d: -f3)
HOME_DIR=$(printf '%s\n' "$ENTRY" | cut -d: -f6)
[ "$UID_NUM" -ne 0 ] || { echo "refusing to install PulseAudio for root; choose a non-root desktop user" >&2; exit 1; }
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { echo "invalid home for $TARGET: $HOME_DIR" >&2; exit 1; }
TARGET_GROUP=$(id -gn "$TARGET")

HERE=$(dirname "$(readlink -f "$0")")
JACK_INSTALLER="$HERE/phase88-install-jackservice.sh"
BRIDGE_HELPER="$HERE/phase88-pulse-jack.sh"
[ -x "$JACK_INSTALLER" ] || { echo "missing executable helper: $JACK_INSTALLER" >&2; exit 1; }
[ -x "$BRIDGE_HELPER" ] || { echo "missing executable helper: $BRIDGE_HELPER" >&2; exit 1; }

if ! command -v apt-get >/dev/null 2>&1; then
	echo "this installer currently supports Debian/apt systems only" >&2
	exit 1
fi
if dpkg-query -W -f='${db:Status-Status}' pipewire-pulse 2>/dev/null | grep -qx installed; then
	echo "pipewire-pulse is installed; refusing to replace the active PulseAudio-compatible server" >&2
	echo "configure the JACK bridge for PipeWire separately, or remove pipewire-pulse intentionally first" >&2
	exit 1
fi

# The user may previously have installed JACK for root. Do not leave that
# auto-start enabled or the two user sessions can contend for the same card.
ROOT_HOME=$(getent passwd root | cut -d: -f6)
ROOT_JACK_WANT="$ROOT_HOME/.config/systemd/user/default.target.wants/phase88-jack.service"
if [ -L "$ROOT_JACK_WANT" ]; then
	echo "root's JACK service is still enabled; disable it first with: systemctl --user disable --now phase88-jack.service" >&2
	exit 1
fi

# The existing JACK starter treats any existing jackd as the server to use.
# Refuse to silently leave the target's service attached to another user's JACK.
if pgrep -x jackd >/dev/null 2>&1; then
	JACK_UIDS=$(ps -C jackd -o uid= | awk '{$1=$1; print}' | sort -u)
	if [ "$JACK_UIDS" != "$UID_NUM" ]; then
		echo "another user's JACK server is running (UIDs: $JACK_UIDS); stop it before installing for $TARGET" >&2
		exit 1
	fi
fi

printf 'Installing JACK and PulseAudio bridge packages for %s...\n' "$TARGET"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
	jackd2 jack-example-tools pulseaudio pulseaudio-utils pulseaudio-module-jack

# The existing installer uses SUDO_USER to select the desktop account. Set it
# explicitly too, so the optional username form behaves the same when invoked
# directly from a root shell.
SUDO_USER="$TARGET" "$JACK_INSTALLER"

BIN_DIR="$HOME_DIR/.local/bin"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
WANTS_DIR="$UNIT_DIR/default.target.wants"
install -d -m 0755 -o "$TARGET" -g "$TARGET_GROUP" "$BIN_DIR" "$UNIT_DIR" "$WANTS_DIR"
install -m 0755 -o "$TARGET" -g "$TARGET_GROUP" "$BRIDGE_HELPER" "$BIN_DIR/phase88-pulse-jack"

cat > "$UNIT_DIR/phase88-pulse-jack.service" <<EOF
[Unit]
Description=PulseAudio bridge to the TerraTec PHASE 88 JACK server
Wants=phase88-jack.service pulseaudio.socket
After=phase88-jack.service pulseaudio.socket

[Service]
Type=oneshot
ExecStart=$BIN_DIR/phase88-pulse-jack
Restart=on-failure
RestartSec=3
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
chown "$TARGET:$TARGET_GROUP" "$UNIT_DIR/phase88-pulse-jack.service"
chmod 0644 "$UNIT_DIR/phase88-pulse-jack.service"
ln -sfn ../phase88-pulse-jack.service "$WANTS_DIR/phase88-pulse-jack.service"
chown -h "$TARGET:$TARGET_GROUP" "$WANTS_DIR/phase88-pulse-jack.service"

RUNTIME_DIR="/run/user/$UID_NUM"
if [ -S "$RUNTIME_DIR/bus" ]; then
	if runuser -u "$TARGET" -- env \
		XDG_RUNTIME_DIR="$RUNTIME_DIR" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
		systemctl --user daemon-reload; then
		runuser -u "$TARGET" -- env \
			XDG_RUNTIME_DIR="$RUNTIME_DIR" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
			systemctl --user start phase88-pulse-jack.service || {
				echo "units installed, but the PulseAudio bridge did not start; inspect as $TARGET:" >&2
				echo "  systemctl --user status phase88-pulse-jack.service" >&2
				echo "  journalctl --user -u phase88-pulse-jack.service" >&2
				exit 1
			}
		echo "installed and started JACK and the PulseAudio bridge for $TARGET"
	else
		echo "units installed and enabled for $TARGET; they will start at the next desktop login"
	fi
else
	echo "units installed and enabled for $TARGET; they will start at the next desktop login"
fi

echo "PulseAudio sink/source: phase88_jack_out / phase88_jack_in (stereo)"
echo "status: run as $TARGET: systemctl --user status phase88-jack.service phase88-pulse-jack.service"
echo "disable: run as $TARGET: systemctl --user disable --now phase88-pulse-jack.service phase88-jack.service"
echo "Do not also configure QJackCtl to auto-start another JACK server."
