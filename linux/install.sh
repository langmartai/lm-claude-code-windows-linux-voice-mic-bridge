#!/usr/bin/env bash
# Installs the Linux side of the mic bridge:
#   - copies scripts to ~/bin
#   - copies systemd units to ~/.config/systemd/user
#   - drops pulse config into /etc/pulse/default.pa.d/ (needs sudo)
#   - migrates legacy windowsmic-watchdog.service away if present
#   - enables linger so the services run without a login session
#   - enables and starts both services
#
# Idempotent: safe to re-run after editing any of the source files.
# Run from the repo root: bash linux/install.sh

set -euo pipefail
cd "$(dirname "$0")"

mkdir -p "$HOME/bin" "$HOME/.config/systemd/user" "$HOME/.config/windowsmic-bridge"

# ---- migration: remove legacy SSH-kill watchdog if present ------------------
# v0.2 replaced windowsmic-watchdog.service (SSH-kill) with
# windowsmic-health.service (status endpoint). Both sampling pulse audio
# concurrently breaks the source, so we MUST disable the old one before
# starting the new one.
if systemctl --user list-unit-files 2>/dev/null | grep -q '^windowsmic-watchdog\.service'; then
    echo "==> migrating: stopping & disabling legacy windowsmic-watchdog.service"
    systemctl --user disable --now windowsmic-watchdog.service 2>/dev/null || true
fi
rm -f "$HOME/.config/systemd/user/windowsmic-watchdog.service"
rm -f "$HOME/bin/windowsmic-watchdog.sh"

# ---- install --------------------------------------------------------------
install -m 755 bin/windowsmic-listen.sh   "$HOME/bin/"
install -m 755 bin/windowsmic-health.py   "$HOME/bin/"
install -m 644 systemd/windowsmic-listen.service "$HOME/.config/systemd/user/"
install -m 644 systemd/windowsmic-health.service "$HOME/.config/systemd/user/"

if [ ! -f "$HOME/.config/windowsmic-bridge/config.env" ]; then
    install -m 600 config.example.env "$HOME/.config/windowsmic-bridge/config.env"
    echo "==> Wrote default $HOME/.config/windowsmic-bridge/config.env (no secrets needed in v0.2)"
fi

sudo install -m 644 pulse/windowsmic.pa /etc/pulse/default.pa.d/windowsmic.pa
echo "==> pulse config installed; reload with: pulseaudio -k && pulseaudio --start"

sudo loginctl enable-linger "$USER" >/dev/null
systemctl --user daemon-reload
systemctl --user enable --now windowsmic-listen.service windowsmic-health.service
systemctl --user --no-pager is-active windowsmic-listen.service windowsmic-health.service

echo
echo "==> Done. Verify with:"
echo "    pactl list short sources | grep WindowsMic"
echo "    curl -s http://127.0.0.1:9998/health | python3 -m json.tool"
echo "    journalctl --user -u windowsmic-health.service -f"
