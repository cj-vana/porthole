# Direct-scanout gaming latch

## Problem

The Linux GPU-resident capture, LAN transport, and VideoToolbox decode path
complete in roughly 3-4 ms, but macOS presentation still determines most of
the measured capture-to-present latency and the visible cadence. Metal HUD
testing separated the two display paths:

- Fit is WindowServer-composited and measured roughly 18 ms on the live host.
- Settled Full with no Porthole overlays is eligible for direct presentation
  and can sustain the physical panel's 144 Hz cadence near 10-11 ms.

The old 3 ms latch guard sometimes committed just after the direct path's
cutoff. That single miss adds an entire 6.94 ms refresh and feels like a
stutter even though capture, decode, and packet loss remain healthy.

## Research and rejected experiment

Apple's `CAMetalDisplayLink` exposes an update drawable, submission deadline,
and target timestamp, so it looked like a way to replace Porthole's inferred
Core Video phase. A live prototype was built and measured, then rejected:

- Fit delivered unstable callbacks as low as 0-6 fps during startup.
- Full eventually reached 144 callbacks/s, but its target was about 20 ms
  ahead of the compositor-reported presentation and capture-to-present rose
  to 22-28 ms.
- Concurrent layer replacement and display-link invalidation crashed twice
  during Full transitions.

The experiment was removed completely rather than shipping a compatibility
switch around a lifecycle hazard. The installed app was restored to the safe
Core Video cadence driver before further work.

Primary references:

- https://developer.apple.com/documentation/quartzcore/cametaldisplaylink
- https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update
- https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled
- https://developer.apple.com/videos/play/tech-talks/110339/
- https://github.com/apple/game-porting-toolkit/blob/main/game-porting-skills/skills/setting-up-macos-window/references/window-implementation.md

## Adopted approach

Keep the proven Core Video phase-locked cadence and direct Full surface, but
move the late-latch commit guard from 3 ms to 4 ms. This gives the tiny Metal
pass and WindowServer handoff enough margin to stay on the current refresh.
The source mailbox remains open for nearly the full refresh; no video queue is
introduced.

Add hidden microsecond overrides for controlled on-device A/B tests and report:

- `present_driver`
- `present_phase_ms` (actual presented time minus the selected output slot)
- `latch_lead_ms`
- `phase_offset_ms`

The presented-time delta makes a one-refresh miss visible in ordinary logs
without enabling the Metal HUD, which itself forces composition.

## Live A/B result

At 2560x1440, Max 288 VFR, Gaming + Auto, 144 Hz direct Full:

- 3 ms intermittently jumped to a later refresh, producing roughly 14-19 ms
  capture-to-present and 5-10 ms presentation phase.
- 3.5 ms reduced mean latency but still showed a 12.2 ms tail and cadence dips
  to 114 fps in a short sample.
- 4 ms held capture-to-present mostly at 10.1-10.4 ms, presentation phase
  around 0.7-1.3 ms, and 138-144 presentations/s with no deadline resyncs.
- 4.5 ms was similarly stable but needlessly closed the source mailbox about
  0.5 ms earlier.

These are software timestamps from `CAMetalDrawable.presentedTime`, not an
optical glass-to-glass result. Five milliseconds is not a truthful claim on a
144 Hz scanout; the current clean software path is about 10 ms.

## Acceptance criteria

- [x] Unsafe `CAMetalDisplayLink` prototype removed from source and install.
- [x] Full + Gaming contains one opaque Metal surface and is direct eligible.
- [x] 4 ms latch selected from live A/B rather than intuition.
- [x] Presentation-phase telemetry identifies full-refresh misses.
- [x] Fit and Full viewport resizing remain unchanged.
- [ ] Sixty-second live Full soak stays smooth with 0% packet loss and no
      deadline resyncs.
- [ ] SwiftLint, Rust tests, Mac builds, input/decode gates, signed universal
      Release, deployment, and final UI regression pass.
