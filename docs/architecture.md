# Architecture

Two paths exist. Both have the laptop **dialing into the phone** over a Wi-Fi access
point the laptop itself hosts, and the phone **dialing out over cellular**. The
phone is always the server; the laptop is always the client.

That direction is what makes the carrier hotspot throttle inapplicable: iOS
Personal Hotspot is never engaged, so the traffic is ordinary app data.

```
┌─ iPhone ──────────────────────────┐        ┌─ Laptop ──────────────────────┐
│                                    │        │                                │
│  SocksBypass  │        │  wlan0 = access point         │
│    listens 0.0.0.0:9876           │        │    10.42.0.1/24  (NO uplink)   │
│    ▲ WiFi interface                │        │    ▲                          │
│    │                               │        │    │ iPhone joins as client     │
│    │  sing-box dials in            │        │    │ 10.42.0.10                  │
│    └───────────────────────────────┼────────┼───┘                          │
│                                    │        │                                │
│  NWParameters                      │        │  tun0 = 172.19.0.1/30         │
│    requiredInterfaceType           │        │    auto_route: true           │
│      = .wifi      ◄── LISTENER     │        │    strict_route: true         │
│                                    │        │    dns_mode: hijack           │
│  NWParameters                      │        │    route_exclude: 10.42.0.0/24│
│    requiredInterfaceType           │        │                                │
│      = .cellular  ◄── ALL EGRESS   │        │  socks outbound               │
│                                    │        │    → 10.42.0.10:9876          │
└────────────┬───────────────────────┘        └───────────────┬────────────────┘
             │ cellular │ wlan0
             ▼                                             │
        ══════╪══════ T-Mobile ═══════════► internet        │
```

## One packet's journey

```
browser
  → tun0                    (captured by auto_route)
  → sing-box routes to "proxy"    (TCP, UDP, QUIC alike)
  → SOCKS5 CONNECT to 10.42.0.10:9876   (crosses wlan0)
  → app's listener           (WiFi — that is the LAN)
  → app opens its own connection      (pinned to .cellular)
  → T-Mobile → internet
```

## The asymmetry

The listener and the egress must be pinned to **different interfaces**, and this
is the single most important detail in the codebase.

| Socket | Interface | Why |
| --- | --- | --- |
| Listener `:9876` | `.wifi` | it is how the tethered laptop reaches the device |
| every outbound connection | `.cellular` | that is the phone's only route out |

They are built by separate parameter factories in
`SOCKS/Core/NetworkTCPRelay.swift` — `makeTCPParameters()` and
`makeUpstreamTCPParameters()`. **Never merge them.** Pinning the listener to
cellular makes the app unreachable on the very network it exists to serve.

## ⚠️ The loop guard is load-bearing

`route_exclude_address` in `laptop/sing-box.json` contains `10.42.0.0/24` so that
traffic to the phone does **not** enter the tunnel.

This laptop has no internet uplink of its own. If sing-box captures traffic to the
phone, sing-box tunnels its own transport, and the machine loses its only path to
the internet with no automatic recovery. This is not hypothetical: the config
inherited from upstream excluded `192.168.137.0/24`, which does not contain
`10.42.0.10`.

`laptop/preflight.py` refuses to start the tunnel unless the exclusion provably
covers the phone's address, and `laptop/start.sh` runs it before anything else.
Seven self-tests, no device and no root required:

```sh
./laptop/preflight.py --self-test
```

## What each layer does

| Layer | File | Role |
| --- | --- | --- |
| SOCKS5 server | `SOCKS/Core/NetworkTCPRelay.swift` | `CONNECT` + `UDP ASSOCIATE`, interface pinning |
| keepalive | `SOCKS/App/RelayViewModel.swift` | silent-audio background survival |
| build | `.github/workflows/build-ios.yml` | unsigned arm64 device `.ipa`, no credentials |
| laptop TUN | `laptop/sing-box.json` | capture everything, DNS hijack, loop guard |
| guard | `laptop/preflight.py` | refuse to start with a broken loop guard |
| tests | `laptop/verify.sh` | six acceptance tests, incl. a real UDP check |
| rollback | `fallback/ish-tunnel.sh` | the iSH tunnel, no signing required |

## The fallback, for contrast

```
┌─ iPhone ─────────────────┐      ┌─ Laptop ──────────────────────┐
│  iSH: emulated x86 Linux │      │  wlan0 10.42.0.1/24            │
│    sshd listens :2222    │◄─────┤  ssh -D 1080  (SOCKS5, TCP only)
│    ▲ WiFi                │  ssh │        │                        │
│  x86 emulation           │      │  privoxy :8118 (HTTP→SOCKS5)   │
│  heat, throttling,       │      │        │                        │
│  suspends on lock,       │      │  client ┘  (per-app env vars)  │
│  ONE connection at a time│      │                                │
└───────────┬──────────────┘      └────────────────────────────────┘
            │ cellular ▼
       T-Mobile → internet
```

Structurally the same. What changes is quality:

| | iSH fallback | native app |
| --- | --- | --- |
| phone-side CPU | emulated x86, burns a core | arm64 native |
| transport | SSH, TCP only | SOCKS5, TCP + UDP ASSOCIATE |
| backgrounding | dies when the screen locks | silent-audio keepalive |
| concurrent connections | 1 | `NWListener`, many |
| laptop-side capture | per-app env vars | `tun0`, everything |
| UDP, QUIC, games | no | yes |

The fallback needs nothing installed on the phone — no signing, no seven-day
profile, no entitlement. That is why it stays.

## Acceptance gates

Run in order. Stop at the first failure and fall back to the iSH tunnel.

1. **Build** — CI produces an unsigned device `.ipa`. Verified arm64, correct
   bundle ID, `UIBackgroundModes: ["audio"]`, no entitlements.
2. **Signing** — Impactor signs and installs locally with the free Apple Account.
3. **TCP** — egress IP changes to the phone's carrier IP, from a client with no
   proxy flags set.
4. **UDP** — `laptop/verify.sh` test 5 shows live UDP flows in the Clash API.
5. **Background** — lock the phone 30 minutes; traffic still flows.
6. **Sustained** — multi-hour, then overnight.

Refresh on day five rather than relying on the final hours of the seven-day
profile.

## Related

- [why-not-tailscale.md](why-not-tailscale.md) — the iPhone exit-node path, and
  why it cannot work when the laptop has no uplink of its own
- [../laptop/README.md](../laptop/README.md) — operating the tunnel
- [../fallback/README.md](../fallback/README.md) — the rollback
