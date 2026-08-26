//! Annex B access-unit inspection for the encoder output (US-002).
//!
//! ffmpeg's raw `h264`/`hevc` muxers write access units as bounded local
//! seqpacket fragments. Both hardware encoders run with `-aud 1`, so the first
//! fragment of each access unit can be recognized immediately and a completed
//! access unit can be checked for an IDR.
//!
//! Pure byte logic, compiled everywhere so unit tests run on macOS too.

use super::Codec;

/// NAL unit type of the byte following a start code.
fn nal_type(header: u8, codec: Codec) -> u8 {
    match codec {
        Codec::H264 => header & 0x1f,
        Codec::Hevc => (header >> 1) & 0x3f,
    }
}

fn is_aud(header: u8, codec: Codec) -> bool {
    match codec {
        Codec::H264 => nal_type(header, codec) == 9,
        Codec::Hevc => nal_type(header, codec) == 35,
    }
}

fn is_idr(header: u8, codec: Codec) -> bool {
    match codec {
        Codec::H264 => nal_type(header, codec) == 5,
        // IDR_W_RADL and IDR_N_LP.
        Codec::Hevc => matches!(nal_type(header, codec), 19 | 20),
    }
}

fn contains_idr(buf: &[u8], codec: Codec) -> bool {
    let mut i = 0;
    while i + 3 < buf.len() {
        if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
            if is_idr(buf[i + 3], codec) {
                return true;
            }
            i += 4;
        } else {
            i += 1;
        }
    }
    false
}

/// Whether one complete Annex B access unit contains an IDR NAL.
///
/// Kept independent of transport framing so the seqpacket assembler can mark
/// completed access units without parsing slice headers.
pub(super) fn access_unit_is_keyframe(au: &[u8], codec: Codec) -> bool {
    contains_idr(au, codec)
}

/// Whether a byte slice begins with the AUD that marks a new access unit.
pub(super) fn access_unit_starts_with_aud(au: &[u8], codec: Codec) -> bool {
    let header = if au.starts_with(&[0, 0, 1]) {
        au.get(3)
    } else if au.starts_with(&[0, 0, 0, 1]) {
        au.get(4)
    } else {
        None
    };
    header.is_some_and(|&header| is_aud(header, codec))
}

#[cfg(test)]
mod tests {
    use super::*;

    const AUD_H264: &[u8] = &[0, 0, 0, 1, 0x09, 0x10]; // nal type 9
    const IDR_H264: &[u8] = &[0, 0, 0, 1, 0x65, 0x88]; // nal type 5
    const AUD_HEVC: &[u8] = &[0, 0, 0, 1, 0x46, 1]; // nal type 35
    const IDR_HEVC: &[u8] = &[0, 0, 0, 1, 0x26, 1]; // nal type 19

    #[test]
    fn validates_packet_framed_access_units() {
        let mut h264 = Vec::from(AUD_H264);
        h264.extend_from_slice(IDR_H264);
        assert!(access_unit_starts_with_aud(&h264, Codec::H264));
        assert!(access_unit_is_keyframe(&h264, Codec::H264));

        let mut hevc = Vec::from(AUD_HEVC);
        hevc.extend_from_slice(IDR_HEVC);
        assert!(access_unit_starts_with_aud(&hevc, Codec::Hevc));
        assert!(access_unit_is_keyframe(&hevc, Codec::Hevc));

        assert!(!access_unit_starts_with_aud(IDR_H264, Codec::H264));
    }
}
