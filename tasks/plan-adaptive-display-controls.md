# Adaptive display and session-controls plan

## Context

Porthole currently streams the Linux headless output at the agent's startup
resolution regardless of the Mac session window. Fit therefore scales a fixed
video, wastes encode work on pixels the client does not display, and can blur
text. The display picker also exposes a 1:1 mode that no longer matches the
desired product model: the user wants only Fit and Full, with the Linux virtual
display itself conforming to the available client surface in either mode.

The interface describes configured gaming rates as though they are delivered
frame rates. The agent's variable-frame-rate capture can only encode real
compositor updates, so a 288 fps request is a ceiling, not a measured result.
Porthole already receives actual capture and encode rates in `agent_stats`, and
measures decode and presentation locally; the UI needs to distinguish them.

Finally, the floating status and control capsules can cover remote content.
They need a reversible hidden state without adding an overlay to the
composition-free fullscreen gaming path.

## Research findings

- Hyprland officially supports runtime headless-output creation and monitor
  reconfiguration for remote desktop use:
  https://wiki.hypr.land/Configuring/Advanced-and-Cool/Using-hyprctl/
- Hyprland 0.55's monitor API accepts runtime output, mode, position, and scale
  values through `hl.monitor(...)`:
  https://wiki.hypr.land/0.55.0/Configuring/Basics/Monitors/
- AppKit's `convertToBacking(_:)` converts a view rectangle to pixel-aligned
  backing coordinates and avoids assumptions about Retina scale:
  https://developer.apple.com/documentation/appkit/nsview/converttobacking%28_%3A%29-3zors
- `SurfaceHostView` already receives every window/layout/backing-store change,
  making it the authoritative source for the stream viewport's pixel size.
- The stream protocol ignores unknown message types. A dedicated resize frame
  can be added without changing the existing six-byte settings message, so new
  clients remain compatible with old agents.
- The capture mailbox already has newest-frame semantics. A controlled producer
  and encoder rebuild can resize without accumulating stale work.
- `agent_stats` reports measured capture and encoded fps; the Mac measures
  decoded and presented fps. The `hello` fps field is configured rate, not
  delivered throughput.

## Acceptance criteria

- [ ] The display picker contains only Fit and Full; stored legacy 1:1 values
      migrate safely to Fit.
- [ ] In Fit, the Linux headless output settles to the Metal surface's backing-
      pixel size after a window resize, without restart storms during dragging.
- [ ] In Full, the Linux headless output settles to the fullscreen surface's
      backing-pixel size after the native transition completes.
- [ ] A live resize recreates capture and encode resources coherently, sends a
      fresh hello/keyframe, and updates absolute-pointer geometry.
- [ ] Gaming mode no longer silently forces Full; either supported display mode
      can be chosen explicitly.
- [ ] UI labels call configured frame rates ceilings or local display rates,
      while Stats separately shows measured source, encoded, decoded, and
      presented fps.
- [ ] The status line does not claim a requested cap is an observed fps value.
- [ ] Controls can be hidden with a button and restored with a compact top-edge
      handle. Native fullscreen gaming remains an unobstructed Metal surface,
      and Escape remains its route back to controls.
- [ ] Rust tests, formatting, clippy, Swift tests, SwiftLint, and Debug/Release
      builds pass.
- [ ] Changes are committed, pushed, deployed to `10.0.0.222`, and exercised
      against its real Hyprland headless output.

## Technical approach

1. Add control message `display_resize` (`0x09`) with an eight-byte big-endian
   width/height payload. Keep settings wire-compatible and document both.
2. Have `SurfaceHostView` report its drawable viewport using
   `convertToBacking(bounds)`. Deduplicate exact sizes in AppKit, then debounce
   at the session boundary so interactive window drags produce one remote
   reconfiguration after settling. Clamp to supported, even dimensions.
3. Retain the desired size across the initial handshake and resend after a
   connection or backing-scale change. Ignore the current advertised size.
4. In the agent, parse resize independently, drain adjacent settings/resize
   events together, and perform one coordinated pipeline reconfiguration:
   stop the producer, drop the encoder, reconfigure only the owned headless
   output, recreate the selected capture backend and encoder, reset the latest-
   frame mailbox, update input geometry, and emit a fresh hello/keyframe.
5. Replace fixed absolute-pointer dimensions with a shared atomic geometry
   value that the input worker reads for each absolute event.
6. Remove one-to-one sizing/scrollers and always fit the drawable. Remove the
   gaming-to-fullscreen coercion; native fullscreen remains driven by Full.
7. Rename the local presentation picker to Local display and gaming choices to
   capture ceilings. Feed measured source/encode/decode/present rates into
   distinct Stats rows and describe the advertised cap as `cap <= N fps`.
8. Add a non-persistent `controlsHidden` state. Put Hide Controls in visible
   chrome and show only a compact reveal handle while manually hidden. Do not
   render the handle over exclusive fullscreen gaming.

## Testing strategy

- Protocol unit tests: byte-exact resize encoding and strict payload parsing,
  including malformed lengths and unreasonable dimensions.
- Agent unit tests: shared input-geometry updates, mailbox restart/reset, and
  settings-plus-resize coalescing where factored as pure logic.
- Mac harness: verify resize frame bytes, old display-mode migration, and the
  existing input/shortcut paths.
- Build gates: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`,
  SwiftLint strict, Debug build, Developer-ID Release build, codesign verify,
  input tests, and decoder tests.
- Live acceptance: resize the Mac window repeatedly, verify one settled
  Hyprland mode change and a fresh stream at the corresponding pixel size;
  enter/exit Full, verify input mapping at edges, and inspect all four measured
  fps rates under motion.

## Risks and mitigations

- Reconfiguring a Wayland output invalidates capture and encoder resources.
  Teardown/recreation is ordered and generation-bound; stale producers cannot
  mark a new mailbox generation complete.
- Interactive resizing can trigger expensive encoder restarts. Client debounce,
  exact-size deduplication, even-dimension normalization, and agent-side event
  coalescing bound the restart rate.
- A malicious or corrupt client could request huge outputs. The agent validates
  nonzero, even, bounded dimensions before invoking Hyprland.
- Older agents ignore the new message and continue streaming their configured
  size. Existing settings remain unchanged, avoiding a compatibility break.
- Hiding all UI could trap the user. Windowed sessions keep a clickable reveal
  handle; exclusive fullscreen gaming keeps the established unmodified-Escape
  exit path and avoids composition overhead.
