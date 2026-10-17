#!/usr/bin/env bash
# Preflight, then start. Refuses to start if the loop guard does not cover the phone.
set -euo pipefail
cd "$(dirname "$0")"
PHONE_IP="${1:-}"

echo "==> Preflight"
./preflight.py -c sing-box.json ${PHONE_IP:+--phone-ip "$PHONE_IP"}

echo "==> Installing config"
sudo mkdir -p /etc/sing-box
sudo cp sing-box.json /etc/sing-box/cellproxy.json

echo "==> Validating the installed copy"
sing-box check -c /etc/sing-box/cellproxy.json

echo "==> Starting"
sudo systemctl start cellproxy
sleep 2
systemctl is-active --quiet cellproxy && echo "    cellproxy is active" || {
    echo "FAILED to start. Recent logs:" >&2
    journalctl -u cellproxy -n 30 --no-pager >&2
    exit 1
}
echo
echo "Run ./verify.sh for the acceptance tests."
echo "If anything looks wrong: ./teardown.sh"
