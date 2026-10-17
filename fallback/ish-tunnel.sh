#!/usr/bin/env bash
# The iSH bootstrap tunnel: laptop -> SSH -> SOCKS5 -> iPhone -> cellular.
#
# This is the fallback and the rollback for everything else in this repo. It is
# what the machine uses to reach the internet at all when the phone is the only
# uplink. It is also slow: iSH runs an emulated x86 userspace, so sshd burns CPU
# and the phone gets hot. That is the whole reason the native app exists.
#
# Chain:
#   client -> HTTP proxy (privoxy :8118) -> SOCKS5 (ssh -D :1080) -> iPhone (iSH :2222) -> cellular
#
# Two proxy variables are exported, for two different families of client:
#   all_proxy / ALL_PROXY  -> socks5h://127.0.0.1:1080   for curl and SOCKS-aware tools
#   https_proxy / HTTPS_PROXY -> http://127.0.0.1:8118   for Go binaries like gh
#
# The split matters. Go's net/http honours HTTPS_PROXY but has never heard of
# ALL_PROXY, so gh routed through a SOCKS ALL_PROXY silently fails and then
# reports its token as invalid. privoxy is the bridge that makes one variable
# cover both families.
set -uo pipefail

PHONE_IP="${ISH_PHONE_IP:-10.42.0.10}"
SSH_PORT="${ISH_SSH_PORT:-2222}"
SOCKS_PORT="${ISH_SOCKS_PORT:-1080}"
HTTP_PORT="${ISH_HTTP_PORT:-8118}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/ish-tunnel"
PIDFILE="$STATE_DIR/ssh.pid"
LOGFILE="$STATE_DIR/ssh.log"
SSH_KEY_ARGS="${ISH_SSH_KEY_ARGS:--o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3}"
MARK='ssh root@'"$PHONE_IP"' -N -D'

# The env a client needs. socks5h (not socks5) so the PHONE resolves names,
# which keeps DNS inside the tunnel instead of leaking to the LAN.
proxy_env() {
    echo "all_proxy=socks5h://127.0.0.1:$SOCKS_PORT"
    echo "ALL_PROXY=socks5h://127.0.0.1:$SOCKS_PORT"
    echo "http_proxy=http://127.0.0.1:$HTTP_PORT"
    echo "HTTP_PROXY=http://127.0.0.1:$HTTP_PORT"
    echo "https_proxy=http://127.0.0.1:$HTTP_PORT"
    echo "HTTPS_PROXY=http://127.0.0.1:$HTTP_PORT"
}

port_open() { timeout 2 bash -c "cat </dev/null >/dev/tcp/$1/$2" 2>/dev/null; }

tunnel_pid() {
    # Only ever match OUR tunnel: the -D port is in the pattern, so a peer's
    # session or an unrelated ssh cannot be adopted or killed.
    pgrep -f "ssh root@$PHONE_IP -N -D $SOCKS_PORT -p $SSH_PORT" 2>/dev/null | head -1
}

cmd_start() {
    mkdir -p "$STATE_DIR"

    local pid; pid=$(tunnel_pid)
    if [ -n "$pid" ]; then
        echo "already running (pid $pid). Nothing to do."
        return 0
    fi

    if ! ping -c1 -W2 "$PHONE_IP" >/dev/null 2>&1; then
        echo "ERROR: $PHONE_IP does not answer ping." >&2
        echo "  Is the laptop's access point up, and is the iPhone joined to it?" >&2
        return 1
    fi

    if ! port_open "$PHONE_IP" "$SSH_PORT"; then
        cat >&2 <<EOF
ERROR: nothing listening on $PHONE_IP:$SSH_PORT.

  iSH's sshd serves ONE connection at a time and refuses new ones while a
  session is live. If you have no other session open, this means iSH is not
  running, or was suspended when the screen locked.

  Open iSH on the iPhone, start its sshd, and try again.
EOF
        return 1
    fi

    echo "==> starting ssh -D $SOCKS_PORT -> $PHONE_IP:$SSH_PORT"
    # shellcheck disable=SC2086
    nohup setsid ssh root@"$PHONE_IP" -N -D "$SOCKS_PORT" -p "$SSH_PORT" \
        $SSH_KEY_ARGS >"$LOGFILE" 2>&1 &
    echo $! >"$PIDFILE"
    sleep 2

    pid=$(tunnel_pid)
    if [ -z "$pid" ] || ! port_open 127.0.0.1 "$SOCKS_PORT"; then
        echo "ERROR: tunnel did not come up. Log:" >&2
        tail -5 "$LOGFILE" >&2
        return 1
    fi
    echo "    up (pid $pid), log $LOGFILE"

    if ! systemctl is-active --quiet privoxy 2>/dev/null; then
        echo "    starting privoxy (the HTTP->SOCKS bridge)"
        sudo systemctl start privoxy
    fi
    cmd_status
}

cmd_stop() {
    local pid; pid=$(tunnel_pid)
    if [ -z "$pid" ]; then
        echo "not running."
        rm -f "$PIDFILE"
        return 0
    fi
    echo "==> stopping pid $pid"
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    echo "    stopped. This machine has no other uplink — expect no internet."
}

cmd_status() {
    local pid ok=0
    echo "phone      $PHONE_IP:$SSH_PORT   $(ping -c1 -W2 "$PHONE_IP" >/dev/null 2>&1 && echo 'ping ok' || echo 'NO PING')"
    pid=$(tunnel_pid)
    if [ -n "$pid" ] && port_open 127.0.0.1 "$SOCKS_PORT"; then
        echo "socks5     127.0.0.1:$SOCKS_PORT   listening (pid $pid)"; ok=1
    else
        echo "socks5     127.0.0.1:$SOCKS_PORT   NOT LISTENING"
    fi
    if port_open 127.0.0.1 "$HTTP_PORT"; then
        echo "http       127.0.0.1:$HTTP_PORT   listening (privoxy)"
    else
        echo "http       127.0.0.1:$HTTP_PORT   NOT LISTENING (systemctl start privoxy)"
    fi

    [ "$ok" -eq 1 ] || { echo; echo "  tunnel down — this machine is offline"; return 1; }

    local ip
    ip=$(env -u all_proxy -u ALL_PROXY -u http_proxy -u https_proxy \
             -u HTTP_PROXY -u HTTPS_PROXY \
             curl -s --max-time 12 --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
             https://api.ipify.org 2>/dev/null)
    if [ -n "$ip" ] && [ "$ip" != "000.000.000.000" ]; then
        echo "egress     $ip   <- through the phone's cellular"
    else
        echo "egress     FAILED to reach the internet through the tunnel"
        return 1
    fi
}

cmd_env() { proxy_env; }

# Run a command with the tunnel's env injected.
cmd_run() {
    [ $# -gt 0 ] || { echo "usage: ish-tunnel.sh run <command> [args...]" >&2; return 2; }
    if [ "$(tunnel_pid)" = "" ]; then
        echo "ERROR: tunnel not running. Start it first: $0 start" >&2
        return 1
    fi
    set -a
    # shellcheck disable=SC2046
    eval "$(proxy_env)"
    set +a
    "$@"
}

# Run a command with ALL proxy variables cleared — for proving what actually
# goes over the wire, and for catching the false pass where a "direct" request
# silently inherits an uppercase proxy that was never unset.
cmd_direct() {
    [ $# -gt 0 ] || { echo "usage: ish-tunnel.sh direct <command> [args...]" >&2; return 2; }
    env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY \
        -u https_proxy -u HTTPS_PROXY -u no_proxy -u NO_PROXY "$@"
}

usage() {
    cat <<EOF
usage: $0 <command>

  start            bring the tunnel up (idempotent)
  stop             tear it down. This machine then has no internet.
  status           health check: phone, SOCKS, HTTP proxy, real egress IP
  env              print the proxy exports (for: eval \$($0 env))
  run <cmd...>     run a command with the proxy env injected
  direct <cmd...>  run a command with ALL proxy vars cleared

Config via environment: ISH_PHONE_IP (default 10.42.0.10)
                        ISH_SSH_PORT (default 2222)
                        ISH_SOCKS_PORT (default 1080)
                        ISH_HTTP_PORT (default 8118)
                        ISH_SSH_KEY_ARGS
EOF
}

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    env)    cmd_env ;;
    run)    shift; cmd_run "$@" ;;
    direct) shift; cmd_direct "$@" ;;
    *)      usage; exit 2 ;;
esac
