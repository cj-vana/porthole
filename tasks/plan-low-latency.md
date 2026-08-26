# Gaming-mode latency plan

## Context

Porthole's current low-latency path is functional but still carries multiple
whole-frame waits. On the target Linux host (`10.0.0.222`) and the Mac's
2560x1440 144 Hz display, the 2026-08-26 baseline was:

| Mode | Decode fps | Encode | Capture to arrival | Decode | Capture to present | Loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Quality (H.264, 60 fps) | 59-60 | 23.6-24.5 ms | 26.5-29.2 ms | 2.8-3.5 ms | 47.7-53.6 ms | 0.00% |
| Gaming (HEVC, requested 144 fps) | 112-120 | 13.8-15.4 ms | 21.2-22.8 ms | 2.4-2.7 ms | 44.7-49.8 ms | 0.00% |

The host's headless output is confirmed at 2560x1440@144. The LAN RTT is
typically 0.4-0.9 ms. The agent only captures about 117 fps in gaming mode,
despite both endpoints running at 144 Hz.

The target is a sustained mean below 20 ms from the agent's captured-frame
timestamp to the drawable's reported presentation time in gaming mode, with
no unbounded queues and no material packet loss. This metric is the one the
existing HUD calls `cap_present`; physical input-to-photon latency still needs
external high-speed-camera or photodiode measurement.

## Research findings

### Existing code

- `agent/src/capture/wlr.rs` copies every 14.7 MB 1440p frame out of the
  compositor's reusable shm mapping into a newly allocated `Vec`.
- `agent/src/main.rs` performs Wayland capture, a blocking 14.7 MB ffmpeg
  stdin write, encoder drain, and UDP transmission serially on one thread.
- The encoder reader can finish while that thread is blocked waiting for the
  next Wayland frame. The access unit is not transmitted until capture
  returns, adding nearly one refresh interval after encode.
- `agent/src/encode/annexb.rs` cannot emit the current access unit until the
  following frame's AUD arrives. This is another complete-frame delay.
- Gaming mode configures NVENC with `p1`, `ull`, no B-frames, zero delay, and
  CBR, but its 160 Mbit VBV is two seconds deep.
- The macOS receiver and decoder already use bounded/latest-frame behavior.
  VideoToolbox decode averages about 2.5 ms and has no persistent backlog.
- `MetalRenderer` manually draws each decoded frame, but dispatches through
  the main queue and leaves the Metal layer display-synchronized. Measured
  decode-to-present time is about 20 ms even on the 144 Hz display.

### Primary documentation and experiments

- NVIDIA recommends ultra-low-latency/low-latency tuning, CBR, no reorder
  delay, and a VBV of roughly one frame for game streaming:
  https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/ffmpeg-with-nvidia-gpu/index.html
- FFmpeg's `flush_packets=1` flushes the underlying I/O after every encoded
  packet, and its Unix protocol supports reliable packet-oriented
  `SOCK_SEQPACKET` sockets:
  https://ffmpeg.org/ffmpeg-formats.html and
  https://ffmpeg.org/ffmpeg-protocols.html#unix
- A target-host probe using ffmpeg 9.0.1, HEVC NVENC, 1440p/144, and a Unix
  seqpacket receiver produced exactly 16 socket messages for 16 encoded
  frames. Every message began with an HEVC AUD, so packet boundaries provide
  access-unit boundaries without one-frame lookahead.
- `CAMetalLayer.displaySyncEnabled` controls whether layer updates synchronize
  to the display refresh. Gaming mode can trade tearing risk for minimum
  presentation latency while quality mode remains synchronized:
  https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled

## Acceptance criteria

- [ ] Gaming mode sustains at least 135 captured and decoded fps on the target
      144 Hz endpoints during a representative moving scene.
- [ ] Mean gaming-mode capture-to-present latency is below 20 ms over at least
      60 consecutive one-second windows; p95 is reported separately.
- [ ] No pipeline stage can accumulate an unbounded queue; newest-frame wins
      whenever encode, decode, or rendering cannot keep up.
- [ ] Steady-state LAN packet loss remains below 0.1% and decoder recovery
      remains functional after deliberate encoder restarts.
- [ ] Quality mode retains synchronized presentation and its current visual
      behavior.
- [ ] Rust tests, clippy, formatting, macOS builds, and protocol/decode test
      targets pass.
- [ ] Every stable performance milestone is committed and pushed with its
      before/after measurement.

## Technical approach

1. Add stage instrumentation for encoder-ready-to-send, decoded-to-main-draw,
   command submission, and drawable presentation. Keep it aggregated to one
   log line per second so measurement does not perturb the hot path.
2. Decouple blocking Wayland capture from the pipeline consumer with a
   one-slot latest-frame mailbox. The consumer can drain and transmit encoder
   output within a fraction of a millisecond instead of waiting for capture.
3. Replace raw stdout stream splitting on Linux with ffmpeg's local Unix
   seqpacket output. Treat each message as one complete access unit and retain
   Annex-B validation/keyframe detection.
4. Configure gaming NVENC's VBV to one frame (`bitrate / fps`), retaining the
   existing two-second quality-mode buffer.
5. In gaming mode, configure the Metal layer for immediate presentation and
   measure main-queue and drawable delay. If main-queue dispatch remains a
   full-frame bottleneck, move only command encoding/submission to a dedicated
   serial render queue while keeping AppKit view mutation on main.
6. Deploy each agent milestone to `10.0.0.222`, rebuild/restart the running
   process with its existing environment, gather a sustained stats sample,
   and compare distributions rather than one favorable second.
7. Review queue ownership, teardown, encoder restart, protocol compatibility,
   error recovery, and resource cleanup before the final commit.

## Testing strategy

- Unit tests: access-unit validation/keyframe classification, newest-frame
  mailbox replacement, one-frame VBV calculation, and timing aggregation.
- Agent integration: target-host release build; connect/reconfigure/reconnect;
  verify H.264 and HEVC with ffprobe/decode; observe bounded process memory.
- Mac integration: build the app and decode-test targets; verify both codecs;
  exercise gaming toggle and 60/120/144 presentation policies.
- Performance: retain raw one-second stats, summarize count/mean/p50/p95/max,
  capture/encode/decode fps, loss, and every instrumented stage.
- Manual: run a high-motion game for five minutes after automated latency
  acceptance, watching for tearing, judder, color regressions, and input feel.

## Risks and mitigations

- Unix seqpacket message size is bounded by socket buffering. A one-frame VBV
  limits normal access-unit size; the receiver will detect truncation, log it,
  and fail rather than feed corrupt video. Large-IDR behavior is tested on the
  target before rollout.
- Immediate Metal presentation can tear. It is gaming-mode-only; quality mode
  stays display-synchronized, and the measured tradeoff is documented.
- A separate capture producer can outrun encode. Its mailbox holds exactly one
  frame and replacement is explicit, preventing latency growth.
- The remote checkout contains old uncommitted deployment files. Deployment
  will update only reviewed source paths and will not reset or delete that
  checkout's unrelated files.
- Sub-20 ms may remain hardware/API-bound with shm capture plus a subprocess
  encoder. If measured stages still exceed the budget, the next architectural
  step is direct NVENC/libavcodec integration and dmabuf capture, justified by
  the stage data rather than assumed up front.
