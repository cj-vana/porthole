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

After acquiring, the tick may hold the drawable up to 1.5 ms more when the
learned source decode period predicts the next decode is imminent, submitting
that newer frame into the same output slot. The hold preserves a 2.0 ms submit
reserve before the deadline, so a prediction miss costs only the bounded wait,
never the slot. Nothing is prefetched and the mailbox never becomes a queue.

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

## Predictive micro-latch A/B (2026-08-29)

The predictive hold was selected from a live A/B over the hidden
`gamingPredictiveLatchMaxMicros` default, one relaunch per arm, 65 valid
active-Full seconds per window, against the same 214 fps HEVC source:

- Off (0): 12.73 and 12.65 ms mean / 14.4 ms p95 capture-to-present across two
  windows; 139.6 and 139.8 mean presented fps.
- 1000 us: 12.14 ms mean; 1506/1545 waits hit (97.5%).
- 1500 us: 12.04 and 12.05 ms mean / 14.0 and 13.7 ms p95 across two windows;
  2032/2051 and 2450/2484 waits hit (99%); each hit presented a frame a full
  decode period (about 4.6 ms) fresher; presented fps unchanged within noise.

1500 us became the committed default. A final 95-second window on committed
defaults with every override deleted measured 12.13 ms mean / 11.9 ms median /
14.4 ms p95 at 0.00% loss, with 99.5% of attempted waits hitting.

This session ran with the built-in panel active alongside the 144 Hz external
display, and the presentation path behaved composited rather than direct:
presentation trailed the nominal target by about 3.5 ms wherever the target
was placed, and the baseline itself logged about two deadline
resynchronizations per second. Absolute numbers above therefore sit roughly
2.5 ms over the single-display direct-scanout acceptance runs recorded in the
Selected path section and are not comparable to them; the arm-to-arm deltas
are within-session and stand. The zero-resync direct-scanout soak still wants
the single-display state.

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
- Raising the output phase from 1.5 to 4.0 ms (`gamingOutputPhaseMicros`) in
  the two-display composited session changed nothing: capture-to-present held
  12.75 vs 12.73 ms and the presentation still trailed the target by ~3.5 ms.
  Presentation there follows the submission, not a fixed slot, so moving the
  target buys no freshness. The committed 1.5 ms from the direct-scanout A/B
  stays.

Hidden defaults may be used for an A/B run, but must be removed before an
acceptance run so the committed 4.0 / 5.0 recovery / 1.5 ms phase / 1.5 ms
predictive defaults are what gets tested. The tunable keys are
`gamingLatchLeadMicros`, `gamingOutputPhaseMicros`, and
`gamingPredictiveLatchMaxMicros`; the stats line's `latch_lead_ms`,
`phase_offset_ms`, `predictive_max_ms`, and `drawable_policy` fields show
which values a sample actually ran, so a stale override cannot hide. Fullscreen inspection screenshots perturb WindowServer; use a
harmless key event to activate the app and read the append-only stats log only
after the sampling window.
