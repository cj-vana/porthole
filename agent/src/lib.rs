//! Library surface shared between the agent binary and example tools.
//!
//! The wire format lives here (not in the binary) so the example receiver
//! and later the Mac client implement against the same code/docs.

pub mod protocol;
pub mod thumbnail;
