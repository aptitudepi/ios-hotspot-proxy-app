# KEEPALIVE

**Status: the zero-buffer approach has been replaced. What ships now is described
below. What remains uncertain is listed under [Open](#open) — read it before
touching this code again.**

`BackgroundKeepAlive` in `SOCKS/App/RelayViewModel.swift` keeps the app alive by
holding an active `.playback` `AVAudioSession` with `UIBackgroundModes: [audio]`
declared in `SOCKS/Info.plist`.

## What used to ship

Upstream SocksBypass (inherited verbatim by this fork) fed a buffer of **pure
digital zeroes** into `AVAudioEngine`. The class comment said so: *"already
zeroed"*.

That is the state with the least evidence behind it, for a specific and
attested reason.

## The failure it fixes

`alananisimov/olcbox` PR #109, merged 2026-07-07, is an iOS SOCKS proxy app
hitting exactly this problem. From that PR:

> The `audio` background mode was declared but no audio was ever produced, so iOS
> suspended the app ~30s after backgrounding, freezing the transport and killing
> the SOCKS proxy.

Their fix, verified on a physical iPhone with a real proxy routed through it:

> play a continuous inaudible buffer through an active `AVAudioSession` so the
> audio route stays live and the proxy keeps running in the background. Re-armed
> after audio interruptions, route changes and media-services resets.

Note the shape of that sentence. *Declared* the mode but produced nothing → dead
in ~30 s. *Produced something* → stable. The failure is not "silence", it is
"nothing at all".

### The mechanism is behavioural, not spectral

There is **no evidence** of iOS analysing PCM content — no amplitude threshold,
no frequency analysis, no buffer hashing. What is attested is an
**output-activity assertion**: the audio server holds a
`MediaPlayback isPlayingProcessAssertion` and logs `IsPlayingOutput:YES` while
output is flowing. Apple DTS, in answer to an alarm app whose white noise
stopped after a few hours, put it this way:

> Strictly speaking, no. The "audio" background category allows your app to remain
> awake **while your audio session is active**, which isn't quite the same as
> guaranteeing it will not be suspended.

and named the top causes, of which the relevant one is second:

> At some point, your app stopped playing audio (went silent) for "too long", so
> the system triggered an interruption and never resumed.

So the design rule is *make the output genuinely, physically present*, rather
than hunting for a threshold. Two states are specifically to be avoided because
they are indistinguishable from "nothing at all" at the audio server:

- **digital zeroes** — what upstream shipped
- **`player.volume = 0`** — a mute is still a mute

If you are tempted by the widely-repeated "use −50 dBFS noise" or "18–21 kHz
tone" advice: **there is no reproducible primary source for either.** They are
blog folklore. No near-ultrasonic content is used here, partly because it risks
an audible whine and partly because it buys nothing that is evidenced.

## What ships now

| | |
|---|---|
| Signal | Band-limited noise, one 1 s buffer at 44.1 kHz mono float32 |
| Level | −40 dBFS peak (0.01), ≈ −51 dBFS RMS — measured, not assumed |
| Band-limit | 3 cascaded one-pole stages at 0.95; under 0.002 % of power above 8 kHz |
| Loop seam | Wrap-around 1024-sample crossfade, so the 1 s splice is not a click |
| Session | `.playback` / `.default` / `.mixWithOthers` — **unchanged from upstream** |
| Now Playing | `MPNowPlayingInfoCenter` title/artist + `MPNowPlayingInfoPropertyIsLiveStream` |
| Re-arm triggers | `interruptionNotification`, `routeChangeNotification`, `mediaServicesWereResetNotification` |
| Re-arm cadence | 1 Hz `DispatchSourceTimer` on a `.utility` queue, not the main thread |
| Idle timer | `isIdleTimerDisabled = true` while serving, `false` on `stop()` |

Three design choices worth not undoing:

- **Noise, not a tone.** Broadband hiss at −51 dBFS RMS is masked by room noise.
  A pure tone at the same peak is not.
- **The loop crossfade.** Without it the engine splices the buffer to itself once
  a second and every splice is a click — audible, *and* an amplitude transient the
  audio server can see. That is the exact thing the output-activity assertion is
  sensitive to.
- **The watchdog is not on the main thread.** iOS kills any process exceeding 80 %
  average CPU over a 60 s window (`cpu_resource_fatal`). Looping audio is free;
  main-thread polling is not. Keep it off `.main` and keep the QoS low.

Apple DTS also recommends Now Playing over a purely mixable session: a Now
Playing app is "generally safe from memory termination" while background memory
stays under ~100 MB. What this relay holds in the background is a connection
table and a 50-entry log.

`.mixWithOthers` is **deliberately unchanged**. Dropping it would make `.playback`
interrupt the user's music, and there is no evidence that either improves
survival. Changing it is an experiment, not part of this fix.

## Open

What is **not** established:

1. **Whether the exact level matters at all.** −40 dBFS was chosen as
   "unambiguously present, inaudible in practice", not because any threshold was
   measured. See the A/B test below.
2. **Residual iOS 26 kill rate.** See README known-gaps §3 — iOS 26.5 has been
   observed SIGKILLing at ~50 s *even with a correct audio setup*, with no
   identified distinguishing factor. **Assume this is ~90 % reliable, not
   certain.** The auto-rearm and the foreground fallback are load-bearing, not
   belt-and-braces.
3. **Whether the watchdog can ever fire while suspended.** It cannot, by
   construction — a suspended process runs no threads. It only helps once
   something else has already bought the process another few seconds.

### The A/B test that would settle (1)

Build two variants differing in one constant — `tonePeak` — and nothing else:

```swift
private static let tonePeak: Float = 0.01   // vs 0.0 (upstream's zeroes)
```

Protocol, per arm:

1. Sideload, start the relay, confirm `backgroundActive` in the UI.
2. Lock the phone. **Plug in USB power** so low battery is not a confounder.
3. From the tethered laptop, poll the SOCKS port every 10 s and log the first
   failure timestamp.
4. Leave it for at least 4 hours. Repeat 3 times per arm.

Expected: both arms survive, because both produce a live output signal. The test
is worth running anyway — it is the cheapest possible measurement of the actual
question ("does this survive the night?"), and a surprise in the zeros arm would
invalidate the output-activity reading of the mechanism entirely. If it does,
the fallback is not a quieter tone but `BGContinuedProcessingTask`.

## Considered and deliberately not built

- **`BGContinuedProcessingTask`** (new in iOS 26, no entitlement needed). Real
  and sanctioned, and it can use the network in the background — but it must be
  started by a foreground user action, the user can cancel it from a Live
  Activity, it is cancelled outright if the app is swiped from the app switcher,
  and there is field evidence of it silently never starting for some users. There
  is **no published data on an hours-long task**. Worth an experiment later; not
  worth building on. Note its App Review value is nil for this fork, which
  sideloads.
- **`voip`, `location`, `bluetooth-central`, `processing` background modes.**
  Every one is an independent App Review 2.5.4 rejection with no evidence of
  helping. On iPhone 17 specifically, `bluetooth-central` background scanning is
  reported broken outright (Apple Developer Forums thread 815922: *"scanning
  appears to stop entirely on iPhone 17 — even with `bluetooth-central` in
  `UIBackgroundModes`. On iPhone 16, background scanning continued"*).
- **CallKit / PushKit.** A fake `CXProvider` call demonstrably *does* keep the app
  alive on iOS 26.5 (thread 826462: *"CallKit fake call — works but creates the
  green pill UI which our product can't ship"*), but it shows a persistent
  incoming-call UI. There is also no scheduling API to exploit:
  `CXStartCallAction` has no `date`, and `fulfill(withDateStarted:)` is a
  reporting call, not a scheduling one.
- **`NEPacketTunnelProvider`.** Not just an entitlement question. TN3120 says it
  outright: *"Do not use a packet tunnel provider to host a network listener or
  proxy server… This path is simply not a recommended use case for a packet tunnel
  provider or any other Network Extension."*

## Rules for anyone touching this

- Do not "optimise" the buffer down to digital zeroes or add `volume = 0`. Those
  are the two states this whole design exists to avoid.
- Do not move the watchdog onto `.main` or raise its QoS. That is how a
  keepalive turns into a `cpu_resource_fatal`.
- Do not drop `.mixWithOthers` without treating it as its own experiment.
- Keep the bounded 50-entry log and the traffic counters intact. They are how
  anyone diagnoses how long a session actually survived.
