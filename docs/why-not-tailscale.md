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

Tailscale peers locate each other by exchanging **endpoint lists** through the
coordination server. A direct connection is only attempted against endpoints the
peer published. The iPhone published none:

```
Addrs:    None
CurAddr:  ''
Relay:    dfw
```

The phone was verified to be on the laptop's access point — ARP `REACHABLE` at
`10.42.0.10` with a randomised iOS MAC. So this is not a topology mistake.

There is also **no Local Network entry for Tailscale in iOS Settings**, because the
packet-tunnel extension never requests one. Without local-network access it cannot
perform LAN discovery, so it never learns or advertises its `wlan0` address.

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
