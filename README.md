# ios-hotspot-proxy-app

A SOCKS5 proxy that runs on your **iPhone** so a tethered **Linux laptop** can
send its traffic out over the phone's cellular data.

It replaces this chain:

```
privoxy → ssh -D → iSH sshd
```

with one app and one SOCKS5 port.

<img src="docs/screenshot.png" alt="SocksBypass running on iOS" width="280">

## Why this exists

Two reasons, and the second is the important one.

**1. Tethering detection.** When you tether a laptop to your phone, the phone
*forwards* the laptop's packets to the carrier. They arrive carrying the
laptop's TCP/IP fingerprint and a TTL one hop lower than anything the phone
sends itself. That difference is what tethering detection looks for.

**2. The carrier throttle.** Tethering through **Personal Hotspot** is billed and
metered as hotspot traffic on many carriers, and some carriers throttle it hard.
This app avoids the Personal Hotspot data path entirely — the traffic leaves as
ordinary phone cellular data.

That avoidance is what drives the unusual topology below.

## The topology is reversed — read this before anything else

> **The laptop hosts the WiFi access point. The phone joins it as a client.**

This is **opposite** to how this project is normally used, and it is
intentional.

Normally: phone runs the hotspot → laptop connects to it. Here: laptop runs the
hotspot → phone connects to it.

```
  ┌──────────────┐   WiFi (no uplink)   ┌──────────────────────────┐
  │    LAPTOP    │ ────────────────────▶ │         iPHONE           │
  │  hosts the   │                       │  SocksBypass listens      │
  │   access pt  │ ◀──────────────────── │  0.0.0.0:9876            │
  └──────────────┘   SOCKS5 over LAN     └────────────┬─────────────┘
       │                                             │ cellular
       │  SOCKS5_PROXY=http://<phone-ip>:9876        ▼
       └──────────────────────────────────▶    carrier → internet
```

Why invert it:

- If the phone ran **Personal Hotspot**, the carrier would meter the laptop's
  traffic as hotspot traffic and the throttle comes right back.
- So the phone must **join** a network instead of serving one.
- The laptop's access point has **no internet uplink** — it only carries the
  SOCKS5 session.
- With no uplink on WiFi, iOS fails over to cellular implicitly. Outbound
  traffic has exactly one route out: the radio.

That implicit failover is why the app works. The upstream connection is also
pinned to cellular explicitly (see [Known gaps](#known-gaps)), which turns the
same guarantee from a heuristic into an enforced one.

### Setting it up

1. On the **laptop**, start a WiFi access point (`create_ap`, `hostapd`,
   NetworkManager, whatever you prefer). It does not need internet.
2. On the **iPhone**, join that access point.
3. Open SocksBypass and start the relay. It binds `0.0.0.0:9876`.
4. Note the iPhone's address on that network.
5. On the **laptop**, point your client at it:

   ```bash
   export SOCKS5_PROXY=http://192.168.x.y:9876   # the iPhone's address
   curl --socks5-hostname 192.168.x.y:9876 https://ifconfig.co
   ```

   Confirm the egress IP is your **phone's** carrier IP, not the laptop's.

The relay also supports **UDP ASSOCIATE**, so DNS over UDP works too.

## ⚠️ No password. Read before you run this.

**The listener binds `0.0.0.0` and there is NO authentication of any kind.**

Anything that can reach the phone's address on that port can use it as an **open
relay** — through the phone's cellular data, on your account. No password, no
token, no IP allowlist, no rate limit.

**Only run this on a network you control.** Concretely:

- Do **not** enable the relay on hotel, café, university, airport, or office
  WiFi.
- Do **not** enable it while the phone is on a carrier network or any other
  untrusted network — the bind is not restricted to the WiFi interface.
- Be aware that the phone joins your laptop's AP, so anyone within radio range
  of the laptop can reach the phone.

The safest pattern is to start the relay only for the duration you need it, and
stop it when you are done.

## Build

There is **no shared `SocksBypass` scheme**. The only shared scheme is
`SocksBypass-Benchmark`, whose archive action is pinned to a build configuration
that links `Vendor/HevSocks5Server.xcframework` — a gitignored, uncommitted
binary that does not exist in a fresh clone. So `-scheme` cannot build this
project. Everything below builds by `-target` and zips the `.app` by hand.

### In CI (recommended)

Push to `main`, or run the **build-ios** workflow manually. It builds an unsigned
device `.ipa` on `macos-latest` and uploads it as the artifact
`SocksBypass-unsigned-ipa`.

CI holds **no Apple credentials** — no Apple ID, no certificate, no provisioning
profile, no secrets. It sets `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`. Signing happens on your Linux box, later.

The underlying command is:

```sh
xcodebuild \
  -project SocksBypass.xcodeproj \
  -target SocksBypass \
  -configuration Release \
  -sdk iphoneos \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

### On a Mac

```sh
./scripts/build-ipa.sh
```

Same flags, same result. It prints the exact path of the `.ipa` it produced.

Both paths emit `SocksBypass-unsigned.ipa`, which is a zip containing
`Payload/SocksBypass.app`. It is unsigned and will not install as-is.

## Signing and installing on Linux

The reason CI holds no credentials: a **free Apple ID** can sign an app for
**7 days**, and that signing happens entirely on your machine, on Linux.

1. **Enable Developer Mode on the iPhone.** Settings → Privacy & Security →
   Developer Mode. This is required for any sideloaded app. The phone will ask
   you to reboot.

2. **Get [Legacy iOS Kit](https://github.com/LukeZGD/Legacy-iOS-Kit) and
   [PlumeImpactor](https://github.com/LukeZGD/PlumeImpactor).** Both run on
   Linux. Legacy iOS Kit handles the signing; PlumeImpactor does the install.

3. **Sign `SocksBypass-unsigned.ipa`** with your Apple ID:

   ```sh
   ./Sign_ipa.sh SocksBypass-unsigned.ipa -p
   ```

4. **Install it with PlumeImpactor.** Plug the phone in over USB, trust the
   computer, and either run PlumeImpactor's GUI or drive it from the CLI.

### Know the 7-day expiry

A free-Apple-ID signature **expires after 7 days**, at which point the app stops
launching and must be signed and reinstalled. There is no workaround short of a
paid Apple Developer account ($99/year), which signs for a year and removes the
weekly ritual. For an app that sits on a bench as a tethering tool, the weekly
resign is usually tolerable; pick the paid account if it is not.

## Known gaps

Things that are **not** fixed in this fork. Read before relying on them.

### 1. The cellular pin is TCP-only — UDP egress is unpinned

Outbound **TCP** connections are pinned to cellular with
`requiredInterfaceType = .cellular`. Outbound **UDP** is not.

`UdpAssociation.swift` does not use Network.framework at all — it owns a raw
BSD socket (`Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)`) and uses
`sendto`. `requiredInterfaceType` has no equivalent there short of
`IP_BOUND_IF`-style socket options, which is a much larger change than this
fork is making.

On this topology it does not matter in practice — the laptop's access point has
no uplink, so WiFi cannot carry UDP out either, and it fails over to cellular
implicitly like everything else. But the guarantee is **not** enforced for UDP.
Anything that changes that assumption could regress DNS-over-UDP quietly.

### 2. There is no authentication. See the warning above.

Not a gap to be fixed later — a property of the design. Listed here so it is not
mistaken for an oversight.

### 3. The background keepalive is unreviewed for iOS 26

`BackgroundKeepAlive` keeps the app alive by looping a buffer of **pure zeroes**
through `AVAudioEngine` in an `.playback` `AVAudioSession`, with
`UIBackgroundModes: [audio]` declared in `SOCKS/Info.plist`.

This is upstream's approach, inherited unchanged. It is **under review** for
iOS 26, where silent-audio backgrounding is exactly the kind of thing that
tightens or gets rejected. It is not final, and it should not be optimised or
"fixed" without reading [`docs/KEEPALIVE-TODO.md`](docs/KEEPALIVE-TODO.md)
first.

### 4. UDP ASSOCIATE is untested against a real carrier network

The SOCKS5 path is exercised by upstream's `Bench/` oracle and unit tests. The
end-to-end tethering path — a real laptop, a real phone, a real carrier — has not
been run from this fork.

### 5. No scheme-based tooling

Because there is no `SocksBypass` scheme, anything expecting one will not work
out of the box: `xcodebuild -scheme`, Xcode's normal run/install flow, and most
CI templates. Use `-target` (see [Build](#build)). The upstream
`SocksBypass-Benchmark` scheme and the Android tree are not part of this fork.

## Upstream and license

This project is a fork of **[SocksBypass](https://github.com/Nanako0129/SocksBypass)**,
which is itself a Swift rewrite of
**[nneonneo/socks5-ios](https://github.com/nneonneo/socks5-ios)**.

All source under `SOCKS/`, `SocksBypass.xcodeproj/`, `SocksBypassTests/`,
`Bench/`, `docs/`, and `scripts/` originates from SocksBypass and is unmodified
except where a diff against upstream says otherwise.

MIT licensed throughout — see [`LICENSE`](LICENSE). The Xcode project is a
derivative of the upstream Swift rewrite, and the SOCKS5 protocol handling has
historical roots in `nneonneo/socks5-ios`; both are MIT, and both are credited
there. Third-party notices for vendored components are in
[`ThirdPartyNotices/`](ThirdPartyNotices) — note those cover
`HevSocks5Server`/`HevSocks5Core`/`HevTaskSystem`, which are only used by the
Benchmark configuration that this fork does not build.