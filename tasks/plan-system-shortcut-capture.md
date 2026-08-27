# System shortcut capture plan

## Context

Porthole's Shortcuts toggle currently forwards Command chords only when
AppKit delivers them to `SessionSurfaceView`. macOS consumes global shortcuts
such as Command-Space before the focused view receives a key event, so
Spotlight opens locally and the Linux desktop never receives Super-Space.

When Shortcuts is on and the Porthole surface has focus, all ordinary keyboard
events must go to the remote machine and must not trigger macOS, application
menu, Dock, Mission Control, or Spotlight actions. When the surface or app is
not active, keyboard behavior must remain local. Unmodified Escape remains the
existing local safety path for pointer lock and native fullscreen.

## Research findings

- `InputController` already translates every mapped key and tracks left/right
  modifiers correctly. The missing layer is interception, not translation.
- `SessionSurfaceView` receives ordinary AppKit keyboard events, but system
  hotkeys may be consumed before the responder chain.
- Apple's Quartz Event Services documentation defines active event taps as
  filters that can discard events before foreground application delivery:
  https://developer.apple.com/documentation/coregraphics/quartz-event-services
- A non-root process cannot use the HID tap. A head-insert session tap is the
  earliest supported location for this app, and keyboard filtering requires
  Accessibility authorization:
  https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29
- The tap callback must handle timeout/user-disable notifications and enable
  the tap again, or macOS can silently restore local shortcuts after a slow
  callback.
- Apple's public `disableProcessSwitching`, `disableForceQuit`, and related
  presentation options cover Dock-owned interfaces while Porthole is active.
  Those options require a hidden or auto-hidden Dock:
  https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct

## Acceptance criteria

- [x] Command-Space arrives remotely as Super down, Space down/up, Super up.
- [x] Command-Space does not open Spotlight while Shortcuts is enabled and the
      session surface is captured.
- [x] Command-Tab, Command-Q, Control-arrow, function-key shortcuts, and normal
      keys use the same remote-only capture path.
- [x] Disabling Shortcuts, changing focus inside Porthole, or deactivating the
      app restores ordinary local keyboard behavior.
- [x] Missing Accessibility permission produces a clear prompt and does not
      leave the toggle claiming capture is active.
- [x] Unmodified Escape retains the existing pointer-lock/fullscreen escape
      route.
- [x] Input translation tests, SwiftLint, and Debug/Release builds pass.

## Technical approach

1. Give `InputController` an explicit method that enables or disables system
   shortcut capture and reports whether the active tap was installed.
2. Install a head-insert `cgSessionEventTap` for key down, key up, and modifier
   changes. Convert each `CGEvent` to `NSEvent`, run it through the existing
   controller translation, then return `nil` so macOS cannot act on it.
3. Filter only while Shortcuts is enabled, the surface is captured, and
   Porthole is active. Pass events through in every other state.
4. Pass unmodified Escape through the tap so the existing surface safety
   handling remains authoritative.
5. Apply AppKit's process-switching, force-quit, session-termination, and hide
   guards only while the stream surface is captured, then restore the prior
   presentation options on focus loss.
6. Prompt for Accessibility authorization only when the user turns Shortcuts
   on. If creation still fails, turn the stored toggle back off and explain
   how to grant permission.
7. Add a byte-exact Command-Space test through the same controller method the
   event-tap callback uses.

## Testing strategy

- Unit: verify the captured Command-Space sequence and disabled-toggle local
  behavior with factory-built `NSEvent` values.
- Build: run the input harness, SwiftLint, and Porthole Debug and Release
  builds.
- Manual: launch the Release app, capture the surface, enable Shortcuts, send
  Command-Space, and confirm Spotlight stays closed while the remote receives
  Super-Space. Then disable Shortcuts and confirm Spotlight opens locally.
- Regression: verify unmodified Escape still releases pointer lock or exits
  native fullscreen.

Live acceptance passed on 2026-08-27 using the Developer-ID-signed
`/Applications/Porthole.app`: physical Command-Space stayed out of Spotlight
and opened the remote Super-Space action while the surface was captured.

## Risks and mitigations

- Accessibility authorization can be absent or revoked. Tap installation is
  transactional, the toggle rolls back on failure, and the UI provides a
  direct route to Privacy & Security settings.
- A stalled active tap is disabled by macOS. The callback does no blocking
  work and explicitly re-enables timeout/user-disabled taps.
- A global tap could capture input after the user leaves Porthole. Every event
  checks both controller capture state and `NSApp.isActive` before filtering.
- Full capture can remove familiar local escape routes. Unmodified Escape is
  deliberately reserved as Porthole's safety key.
