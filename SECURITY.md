# Security and trust model

Read this before you run Porthole anywhere but a network you control.

## There is no authentication

Version 1 has none. Any machine that can reach the agent's control port can
connect, see the screen, and drive the keyboard, mouse, and (when enabled)
the gamepad. There is no password, no pairing, and no per-connection
approval. The agent hands the desktop to whoever connects first, and a new
connection replaces the current one.

This is a deliberate scope choice for the first version, not an oversight,
and it is why the next point matters.

## Run it only on a trusted network

Porthole is built for a LAN or a private overlay network you own end to end,
which in practice means one of:

- A home or office LAN whose other devices you trust.
- A [Tailscale](https://tailscale.com) or WireGuard tunnel, where the network
  itself is the access control: only your own devices are on it, and the
  agent's ports are not exposed to anyone else.

Do not port-forward the agent's ports to the public internet, and do not run
the agent on a network with devices you do not control. Anyone who reaches
the control port has full control of the machine.

## Ports

The agent listens on these by default (all configurable):

| Port  | Protocol | Purpose                          |
|-------|----------|----------------------------------|
| 52800 | UDP      | Video stream                     |
| 52801 | TCP      | Control channel (input, settings, clipboard) |
| 52802 | UDP      | Audio stream                     |
| 52803 | TCP      | Thumbnail endpoint (machine picker) |
| 52804 | TCP      | File transfer                    |

The mDNS announcement (`_porthole._tcp`) advertises the machine on the local
link so the Mac app can find it without typing an address. mDNS does not
cross a router or a Tailscale tunnel; off-LAN machines are added by address
in the app.

## What the agent can do to the machine

- Inject keyboard and mouse input through the compositor (no root; it uses
  Wayland virtual-input protocols).
- Create a virtual gamepad through `/dev/uinput` when a udev rule grants the
  `input` group access to it (US-014). That rule is the one privileged setup
  step; it is documented in `agent/README.md`.
- Read and write the clipboard.
- Write files dragged from the Mac into the configured transfer folder
  (default `~/Downloads`). File names are reduced to their base name, so a
  transfer cannot write outside that folder.

The agent does not run as root and does not need to.

## Reporting a problem

If you find a security issue, please open a GitHub issue describing it, or
contact the maintainer listed in the repository. Because v1 is explicitly
unauthenticated and LAN-only, the useful reports are ones that break a
boundary the design does claim: a file transfer escaping the destination
folder, the agent crashing on malformed input, or the agent being reachable
in a way the ports table above does not describe.

## Planned

Authentication (a pairing token or a per-machine key, so the trust boundary
is the pairing rather than the network) is the top item for a later version.
Until it lands, the network is the security boundary.
