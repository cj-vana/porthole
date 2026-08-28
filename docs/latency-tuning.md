# Native fullscreen latency tuning

This is the acceptance record for Porthole's Gaming presentation path. Windowed
Fit remains useful for interaction testing, but macOS can throttle or composite
an inactive, occluded, or windowed surface differently. Timing choices therefore
come from an active native Full session only.

## Test shape

- Client: native 2560x1440 Full, Gaming + Auto, capture ceiling Max 288.
- Source: 2560x1440 gaming virtual display on `10.0.0.222`.
- Record settled one-second windows from `/tmp/porthole-mac-stats.log`.
- Accept only samples tagged
  `surface=active1,visible1,window1,key1,space1,full1,screen144,view144,sync0,buf3,hidden0`.
- Reject a candidate for packet loss, cadence deadline resynchronization,
  persistent drawable stalls, or a meaningful presentation-rate regression.
- Compare `cap_present_ms`, `present_phase_ms`, `present_fps`, and
  `drawable_wait_ms`. These software timestamps are not a claim about
  camera-measured input-to-photon latency.

## Selected path

Gaming keeps a three-surface `CAMetalLayer`, but acquires a drawable only after
the content latch. The third surface is a recycle cushion, not a queued decoded
frame. The steady latch is 4.0 ms before a target with a 1.5 ms output phase.
Only a measured drawable wait widens the next six latches to 5.0 ms.

The cadence wheel is seeded by `CVDisplayLink`, then a bounded phase servo
continues comparing it with fresh hardware forecasts. Each tick may move by at
most 0.25 ms. This follows a genuine display-phase step without making callback
delivery jitter the pacing clock. A stale forecast older than four refreshes is
ignored, leaving the independent mach-time wheel authoritative.

Two independent, already-settled 25-second signed-Release windows produced:

- 11.90 ms mean / 12.8 ms p95 capture-to-present;
- 143.38 mean / 144 median / 141 p05 presented fps;
- 144.0 mean GPU-completion fps;
- 0.061 ms mean / 0.15 ms p95 drawable wait;
- zero packet loss and 17 sub-margin submissions across 7,200 target frames.

The previous sustained direct-latch result was 12.114 ms mean / 15.18 ms p95,
142.188 mean / 128.4 p05 presented fps, 0.72 ms p95 drawable wait, and 236
sub-margin submissions in 85 seconds. The servo therefore improved the latency
tail by 2.38 ms, raised p05 presentation by 12.6 fps, and reduced the miss rate
by about 88%. These are compositor software timestamps, not an optical
input-to-photon claim.

## Rejected candidates

- The previous two-surface prefetch path measured 10.49 ms mean / 11.50 ms p95
  over 67 seconds, but fresh runs exposed occasional recycle cascades down to
  roughly 105 presented fps. Its better central latency hid the visible stutter.
- A 4.5 ms latch / 1.5 ms phase increased latency to 13.09 ms mean / 17.50 ms
  p95 at 142.36 mean presented fps.
- A 4.0 ms latch / 1.0 ms phase missed more output slots: 12.74 ms mean /
  18.50 ms p95 at 141.37 mean presented fps.
- Bounded asynchronous empty-drawable admission at 5.0 ms reduced latency to
  11.92 ms mean but hard-skipped 126 admissions in 85 seconds and lowered mean
  presentation to 141.51 fps. Starting at 6.0 ms held the third surface longer
  and made misses worse. Continuously reserving the third surface also reduced
  presentation rate.
- Source ceilings of Max 180 and Max 144 did not remove the presentation tail;
  capture/decode load was not the limiting stage.
- Explicit `present(atTime:)` held surfaces until a future transaction, dropping
  presentation to roughly 95–100 fps and raising capture-to-present to 21–22 ms.
- `CAMetalDisplayLink` added about 3 ms and produced a lower, more variable
  cadence than the Core Video pacing path on this display.
- Borderless Full avoided the native Space transition, but the AppKit style
  change swallowed the invariant Escape exit route. It failed usability before
  it was eligible for latency acceptance and was removed.

Hidden defaults may be used for an A/B run, but must be removed before an
acceptance run so the committed 4.0 / 5.0 recovery / 1.5 ms phase defaults are
what gets tested. Fullscreen inspection screenshots perturb WindowServer; use a
harmless key event to activate the app and read the append-only stats log only
after the sampling window.
