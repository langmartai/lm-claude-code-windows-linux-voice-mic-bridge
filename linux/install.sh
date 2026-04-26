#!/usr/bin/env bash
# Installs the Linux side of the mic bridge:
#   - copies scripts to ~/bin
#   - copies systemd units to ~/.config/systemd/user
#   - drops pulse config into /etc/pulse/default.pa.d/ (needs sudo)
#   - enables linger so the services run without a login session
#   - enables and starts both services
#
# Idempotent: safe to re-run after editing any of the source files.
# Run from the repo root: bash linux/install.sh

set -euo pipefail
cd "$(dirname "$0")"

mkdir -p "$HOME/bin" "$HOME/.config/systemd/user" "$HOME/.config/windowsmic-bridge"

install -m 755 bin/windowsmic-listen.sh   "$HOME/bin/"
install -m 755 bin/windowsmic-watchdog.sh "$HOME/bin/"
install -m 644 systemd/windowsmic-listen.service   "$HOME/.config/systemd/user/"
install -m 644 systemd/windowsmic-watchdog.service "$HOME/.config/systemd/user/"

if [ ! -f "$HOME/.config/windowsmic-bridge/config.env" ]; then
    install -m 600 config.example.env "$HOME/.config/windowsmic-bridge/config.env"
    echo "==> Edit $HOME/.config/windowsmic-bridge/config.env and set WIN_HOST + WIN_KEY"
fi

sudo install -m 644 pulse/windowsmic.pa /etc/pulse/default.pa.d/windowsmic.pa
echo "==> pulse config installed; reload with: pulseaudio -k && pulseaudio --start"

sudo loginctl enable-linger "$USER" >/dev/null
systemctl --user daemon-reload
systemctl --user enable --now windowsmic-listen.service windowsmic-watchdog.service
systemctl --user --no-pager is-active windowsmic-listen.service windowsmic-watchdog.service

echo
echo "==> Done. Verify with:"
echo "    pactl list short sources | grep WindowsMic"
echo "    journalctl --user -u windowsmic-watchdog.service -f"
