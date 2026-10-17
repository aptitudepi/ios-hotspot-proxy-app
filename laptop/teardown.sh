#!/usr/bin/env bash
# Emergency stop. This laptop has no other uplink, so stopping the tunnel takes
# the machine offline - which is the point: it undoes the tunnel and nothing else.
set -euo pipefail

echo "==> Stopping cellproxy"
sudo systemctl stop cellproxy 2>/dev/null || true
sudo systemctl disable cellproxy 2>/dev/null || true

echo "==> Removing tun0 if it survived"
if ip link show tun0 >/dev/null 2>&1; then
    sudo ip link delete tun0 2>/dev/null || true
fi

echo "==> Checking for leftover sing-box routing state"
if pgrep -x sing-box >/dev/null 2>&1; then
    echo "WARNING: a sing-box process is still running. Stopping it."
    sudo pkill -x sing-box || true
    sleep 1
fi

echo
echo "Stopped. tun0: $(ip link show tun0 >/dev/null 2>&1 && echo PRESENT || echo gone)"
echo "Connectivity now comes from whatever you had before - for this machine,"
echo "that means the iSH tunnel: ssh root@10.42.0.10 -N -D 1080 -p 2222"
