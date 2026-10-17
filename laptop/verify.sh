#!/usr/bin/env bash
# Acceptance tests for the phone-through tunnel. Exits non-zero on failure.
#
# NOTE ON PROXY ENV: this machine sets both lowercase (all_proxy, http_proxy,
# https_proxy) AND uppercase (HTTP_PROXY, HTTPS_PROXY) proxy variables. Unsetting
# only one set leaves the other live, and a "direct" request silently goes out via
# the old tunnel instead. Every network call here clears both casings.
set -uo pipefail
cd "$(dirname "$0")"

# Parse with python rather than sed: "server" also appears in the dns block, and
# a grep grabs 1.1.1.1 instead of the phone.
read -r PHONE_IP PHONE_PORT < <(python3 -c '
import json
cfg = json.load(open("sing-box.json"))
for ob in cfg["outbounds"]:
    if ob.get("type") == "socks":
        print(ob["server"], ob.get("server_port", ""))
        break
')
[ -z "${PHONE_IP:-}" ] && { echo "FATAL: no socks outbound in sing-box.json"; exit 2; }

clean() { env -u all_proxy -u http_proxy -u https_proxy \
              -u ALL_PROXY -u HTTP_PROXY -u HTTPS_PROXY -u no_proxy -u NO_PROXY "$@"; }

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  ....  %s\n' "$1"; }

echo "Phone endpoint from config: $PHONE_IP:$PHONE_PORT"
echo

echo "[0] prerequisites"
if systemctl is-active --quiet cellproxy; then ok "cellproxy service is running"; else
    bad "cellproxy is not running - start it with ./start.sh"; echo; echo "cannot continue"; exit 1
fi
if ping -c1 -W2 "$PHONE_IP" >/dev/null 2>&1; then ok "phone is reachable at $PHONE_IP"
else bad "phone does not answer ping at $PHONE_IP"; fi
if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$PHONE_IP/$PHONE_PORT" 2>/dev/null; then
    ok "SOCKS5 port $PHONE_PORT is open on the phone"
else
    bad "nothing listening on $PHONE_IP:$PHONE_PORT - is SocksBypass running on the phone?"
fi
echo

echo "[1] baseline: direct egress (no tunnel)"
DIRECT_IP=$(clean curl -s --max-time 10 https://api.ipify.org || echo "<failed>")
note "direct egress IP: $DIRECT_IP"
echo

echo "[2] TCP through the tunnel"
TUNNEL_IP=$(clean curl -s --max-time 15 --socks5-hostname "$PHONE_IP:$PHONE_PORT" https://api.ipify.org || echo "<failed>")
note "tunnelled egress IP: $TUNNEL_IP"
if [ "$TUNNEL_IP" = "<failed>" ]; then
    bad "SOCKS5 fetch failed"
elif [ "$TUNNEL_IP" = "$DIRECT_IP" ]; then
    bad "tunnelled IP equals direct IP - traffic is NOT going through the phone"
else
    ok "egress changed ($DIRECT_IP -> $TUNNEL_IP); traffic leaves via the phone"
fi
echo

echo "[3] system-wide routing (sing-box TUN, not just a --socks5 flag)"
SYS_IP=$(clean curl -s --max-time 15 https://api.ipify.org || echo "<failed>")
note "egress with no explicit proxy flag: $SYS_IP"
if [ "$SYS_IP" = "$TUNNEL_IP" ]; then ok "unconfigured traffic is captured by the TUN"
else bad "plain traffic is not tunnelled (got $SYS_IP, want $TUNNEL_IP)"; fi
echo

echo "[4] DNS leak"
UPLINK=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
[ -z "$UPLINK" ] && { UPLINK=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1); }
if [ -z "$UPLINK" ]; then
    note "no default uplink interface found - this machine may have none by design; skipping"
else
    if command -v tcpdump >/dev/null 2>&1; then
        (sudo -n true 2>/dev/null) || { note "sudo needs a password; run the leak test manually:"; \
            echo "        sudo tcpdump -ni $UPLINK 'port 53'   # then: dig +short example.com"; }
        sudo -n timeout 12 tcpdump -ni "$UPLINK" 'port 53' > /tmp/cellproxy-dnsleak.txt 2>/dev/null &
        TCPDUMP_PID=$!
        sleep 2
        clean dig +short example.com >/dev/null 2>&1 || true
        sleep 6
        kill $TCPDUMP_PID 2>/dev/null || true
        wait $TCPDUMP_PID 2>/dev/null || true
        if [ -s /tmp/cellproxy-dnsleak.txt ]; then
            bad "DNS queries left over $UPLINK - they should go through the phone"
            head -5 /tmp/cellproxy-dnsleak.txt
        else
            ok "no port-53 traffic on $UPLINK"
        fi
    else
        note "tcpdump not installed; skipping leak test"
    fi
fi
echo

echo "[5] UDP through the tunnel (the part SSH could never do)"
clean curl -s --max-time 8 http://127.0.0.1:9090/connections > /tmp/cellproxy-conns.json 2>/dev/null || true
if [ ! -s /tmp/cellproxy-conns.json ]; then
    note "clash API not reachable on 127.0.0.1:9090 - cannot inspect flows"
else
    # Generate real UDP: QUIC over TLS to a host known to speak HTTP/3.
    clean curl -s --max-time 10 --http3 https://cloudflare.com -o /dev/null 2>/dev/null || \
        clean curl -s --max-time 10 https://cloudflare.com -o /dev/null 2>/dev/null || true
    sleep 2
    if command -v jq >/dev/null 2>&1; then
        UDP_N=$(clean curl -s http://127.0.0.1:9090/connections | jq '[.connections[]? | select(.network=="udp")] | length' 2>/dev/null || echo 0)
        if [ "${UDP_N:-0}" -gt 0 ]; then ok "clash API shows $UDP_N UDP flow(s)"
        else bad "no UDP flows in the clash API - UDP ASSOCIATE is not working"; fi
        clean curl -s http://127.0.0.1:9090/connections | jq -r '.connections[]? | select(.network=="udp") | "         \(.metadata.network) \(.metadata.host):\(.metadata.destinationPort)"' 2>/dev/null | head -10
    else
        bad "jq not installed; cannot inspect flows. Install jq and re-run."
    fi
fi
echo

echo "==================================="
echo "  passed: $pass   failed: $fail"
echo "==================================="
[ "$fail" -eq 0 ] || exit 1
