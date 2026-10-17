#!/usr/bin/env bash
# Install sing-box and drop this config in place. Does NOT start or enable anything.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v pacman >/dev/null 2>&1; then
    echo "This script targets Arch/CachyOS (pacman). Install sing-box by hand, then re-run." >&2
    exit 1
fi

echo "==> Validating config against the installed sing-box (if present)"
if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c sing-box.json
else
    echo "    sing-box not installed yet; validating after install"
fi

echo "==> Installing sing-box"
sudo pacman -S --needed sing-box
sing-box version | head -1

echo "==> Re-validating config against $(sing-box version | head -1)"
sing-box check -c sing-box.json

echo "==> Installing systemd unit"
sudo cp cellproxy.service /etc/systemd/system/cellproxy.service
sudo systemctl daemon-reload

echo
echo "Installed. NOT started and NOT enabled at boot - deliberately."
echo "Before starting: put SocksBypass on the phone, join it to this laptop's"
echo "access point, and start the relay. Then:"
echo
echo "    ./start.sh          # preflight check, then start"
echo "    ./verify.sh         # acceptance tests"
echo "    ./teardown.sh       # emergency stop"
echo
echo "On CachyOS sing-box also ships its own sing-box.service; this one is"
echo "separate so the two never fight over tun0."
