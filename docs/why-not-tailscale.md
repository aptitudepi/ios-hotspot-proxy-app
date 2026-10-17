# Why not Tailscale as the transport

Tailscale added iOS exit nodes in v1.98.1 (May 2026), and an iPhone running one looks
like it should solve this entire problem: App Store install, proper VPN background
lifecycle, IP-layer routing of TCP/UDP/ICMP, and no seven-day refresh. It was tested
and it does not work for this topology. This file records why, so nobody spends the
afternoon again.

## The topology that breaks it

The target case is a laptop with **no internet uplink of its own** whose only path
out is the phone. The laptop hosts a Wi-Fi access point; the iPhone joins it as a
client and also has cellular. Exit traffic must leave via the phone's cellular
interface — which is also what makes the carrier hotspot throttle not apply, since
iOS Personal Hotspot is never engaged.

## What was tried

1. `tailscaled` was given `HTTPS_PROXY=http://127.0.0.1:8118` so its control plane
   could reach the coordination server. This worked: the health-check warning
   cleared and the node came online.
2. The iPhone advertised `Run as Exit Node`, was approved in the admin console, and
   reported `active; offers exit node`.
3. The peer path was tested:

```
$ tailscale ping --until-direct=true -c 2 100.89.44.26
pong from iphone183 (100.89.44.26) via DERP(dfw) in 102ms
pong from iphone183 (100.89.44.26) via DERP(dfw) in 138ms
direct connection not established
```

## The blocker

Tailscale carries traffic over a **direct WireGuard path**, which requires NAT
traversal: each node publishes the endpoints it can be reached on, and each peer
attempts those. So the question is what the iPhone published.

`tailscale status --json` showed the peer advertising exactly two endpoints:

| Endpoint | What it is | Reachable from this laptop? |
| --- | --- | --- |
| `172.58.52.207:65491` | its T-Mobile CGNAT address | no uplink |
| `192.0.0.2:41641` | Tailscale's "unknown public" placeholder | no |

**It did not advertise `10.42.0.10:41641`, its address on the shared LAN.**

`tailscaled` logs confirm it tried what it had, and the kernel refused both:

```
magicsock: ping(100.89.44.26): sending disco ping to [Zpx1Q] iphone183 ...
disco: failed to send ping to 172.58.52.207:65491: sendto: network is unreachable
disco: failed to send ping to 192.0.0.2:41641:   sendto: network is unreachable
```

This laptop does advertise its own LAN endpoint — `Self.Addrs` includes
`10.42.0.1:41641` — and Tailscale did act on it. Capturing `wlan0` shows the
laptop sending WireGuard packets straight at the phone:

```
01:41:38 IP 10.42.0.1.41641 > 10.42.0.10.41641: UDP, length 124
01:41:39 IP 10.42.0.1.41641 > 10.42.0.10.41641: UDP, length 124
01:41:40 IP 10.42.0.1.41641 > 10.42.0.10.41641: UDP, length 124
01:41:44 IP 10.42.0.1.41641 > 10.42.0.10.41641: UDP, length 124
```

and, over that window, **nothing came back**. Not a single inbound packet.

The phone is reachable at that address — ARP is `REACHABLE` and ICMP ping answers,
so the access point is not isolating clients and the packets are arriving. The
phone's Tailscale simply does not answer WireGuard arriving on the local network.
There is also no Local Network entry for Tailscale in iOS Settings, because the
packet-tunnel extension never requests that permission, so it has no local-network
access to speak of.

That is the whole failure. It is a platform limitation on iOS, not something that
can be configured away from the Linux side.

## Why DERP is not a fallback here

DERP relays over HTTPS and is reachable — this laptop got as far as Dallas at 62 ms.
But the relay path is circular for this topology: the laptop's only route to the
internet is *through the phone*, so traffic would travel

```
laptop -> Wi-Fi -> phone -> SSH tunnel -> cellular -> DERP -> phone -> cellular -> internet
```

forwarding through the phone twice, which both wastes the entire bandwidth budget and
defeats the purpose. A relay that is only reachable by traversing the node it is
relaying to cannot be used.

## Conclusion

Tailscale requires a direct path, the iPhone cannot advertise one, and the relay
fallback is circular. **Structurally ruled out for a laptop whose only uplink is the
phone.**

This is specific to the no-uplink case. With an independent internet connection —
café Wi-Fi, a hotel, an office — an iPhone exit node is the better tool by a wide
margin, and nothing here argues otherwise.

## Rollback

The control-plane proxy is harmless but unnecessary once this path is closed:

```sh
sudo sed -i '/^HTTPS_PROXY=/d; /^HTTP_PROXY=/d' /etc/default/tailscaled
sudo systemctl restart tailscaled
```
