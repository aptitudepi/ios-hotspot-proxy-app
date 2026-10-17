# KEEPALIVE TODO

**Status: open. Do not treat the current implementation as correct or final.**

`BackgroundKeepAlive` in `SOCKS/App/RelayViewModel.swift` currently keeps the app
alive by activating an `AVAudioSession` in `.playback` mode and looping a buffer
of pure zeroes through `AVAudioEngine`.

## Why this is flagged

That approach is inherited verbatim from upstream SocksBypass. It is **under
review** — in particular for iOS 26, where the App Store's review guidelines and
the background-execution behaviour around long-lived silent audio have tightened.
A silently-looping audio session that exists only to hold a process alive is the
kind of thing that gets flagged, and relying on it may simply stop working.

A parallel track owns the investigation into the correct iOS 26 method.

## Rules for anyone touching this

- **Nothing in `BackgroundKeepAlive` has been modified by this fork.** The only
  change is a `// TODO(keepalive):` comment at the class.
- Read this file before changing the audio-session logic.
- Do not assume the pure-zeros buffer is the right approach; it is upstream's
  approach, not a validated one.
- Do not delete the `TODO(keepalive)` marker until the replacement lands and this
  file has been updated to describe what actually ships.

## What a fix needs to decide

Open questions for the tracking track, listed so they are not lost:

1. Which background-execution mechanism is appropriate on iOS 26 for a
   user-initiated, foreground-launched relay — `connectedDevice` foreground
   service, background task, `BGProcessingTask`, or something else.
2. Whether `UIBackgroundModes` in `SOCKS/Info.plist` needs to change, and whether
   the `audio` mode is still declared or should be.
3. Whether the silence generator should be replaced by the upstream
   `SOCKS/blank.wav` asset, or removed entirely.
4. What the failure mode looks like when the session is interrupted, and whether
   the existing `interruptionNotification` observer is sufficient.

Until those are answered, the app is expected to work as upstream has it
behaving, and any regression here should be checked against upstream before being
attributed to this fork.