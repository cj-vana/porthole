# Contributing to Porthole

Porthole is two programs that share one wire protocol: a Rust agent that
runs on the Linux machine (`agent/`) and a SwiftUI app that runs on the Mac
(`macos/`). The protocol lives in `docs/protocol.md`. Most changes touch one
side; changes to what goes over the wire touch all three, in that order.

## Setting up

You need a Mac with Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen swiftlint`), a Rust stable toolchain, and, to test
the agent for real, a Linux machine running Hyprland with an NVIDIA or AMD
GPU and `ffmpeg`. The agent crate builds and its unit tests run on macOS;
everything that needs Wayland, ffmpeg, or the GPU is gated behind
`cfg(target_os = "linux")` and only does anything on the Linux side.

The development loop that works: edit on the Mac, `rsync` the `agent/`
directory (minus `target/`) to the Linux machine, build and run it there
over SSH, and run the Mac app locally against it. `agent/README.md` has the
environment variables the agent needs when started from an SSH shell.

## Before you open a pull request

CI runs exactly these, so run them first.

Agent, from `agent/`:

```sh
cargo fmt --check
cargo build --locked
cargo clippy --all-targets -- -D warnings
cargo test
```

On Linux the build also needs `libxkbcommon` development headers.

Mac app, from `macos/`:

```sh
xcodegen generate
swiftlint lint --strict
xcodebuild -scheme Porthole -configuration Debug build
xcodebuild -scheme porthole-decode-test -configuration Debug build
xcodebuild -scheme porthole-input-test -configuration Debug -derivedDataPath build build
./build/Build/Products/Debug/porthole-input-test local
```

`Porthole.xcodeproj` is generated from `project.yml` and not committed. Edit
`project.yml`, never the project file, and rerun `xcodegen generate` after
adding or removing source files.

Anything that changes how the stream looks or feels also needs a run
against a real agent. Say in the pull request what you ran and what the
stats lines showed; the agent logs one per second, and the Mac app writes
its own to `/tmp/porthole-mac-stats.log`.

## Changing the wire protocol

Write the change into `docs/protocol.md` first, then implement it in
`agent/src/protocol.rs` with a unit test that round-trips the bytes, then
mirror it in `macos/Porthole/Streaming/WireProtocol.swift`. Both sides
ignore control message types they do not know, so additive changes inside
protocol version 1 stay compatible with older peers. Changing the layout of
an existing message or the video datagram header means bumping the version
byte and updating both sides in the same change.

The reference receiver (`cargo run --example receiver`) and the scripted
input sender (`cargo run --example input_sender`) are the way to exercise
the agent without the Mac app. Keep them working.

## What not to commit

Plans, progress logs, screenshots, and verification write-ups belong in the
pull request, not the tree. Documentation that describes how the system
works goes under `docs/` or in the component README. The product
requirements document in `tasks/prd-porthole.md` is the exception: it is
the definition of done for the first version, and its checkboxes are
updated as stories land.

## Reporting a problem

Include the agent's startup lines (they print the negotiated output,
resolution, refresh rate, encoder, and capture backend), the output of
`cargo run --example wl_globals` on the Linux machine, and the Hyprland
version. For streaming problems, a few seconds of the per-second stats lines
from both sides say more than a description.
