//! Annex B access-unit splitting for the encoder output (US-002).
//!
//! ffmpeg's raw `h264`/`hevc` muxers write a byte stream with no frame
//! boundaries. Both hardware encoders run with `-aud 1`, so every access
//! unit starts with an access unit delimiter NAL; this splitter cuts the
//! stream at AUD start codes and flags AUs containing an IDR.
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

/// Find start code positions (and the NAL header byte after each) in `buf`.
/// Scanning for the 3-byte prefix also catches 4-byte start codes (the extra
/// zero simply sits before the match).
fn start_codes(buf: &[u8]) -> Vec<(usize, u8)> {
    let mut found = Vec::new();
    let mut i = 0;
    while i + 3 < buf.len() {
        if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
            found.push((i, buf[i + 3]));
            i += 4;
        } else {
            i += 1;
        }
    }
    found
}

fn au_is_keyframe(au: &[u8], codec: Codec) -> bool {
    start_codes(au)
        .iter()
        .any(|&(_, header)| is_idr(header, codec))
}

/// Accumulates an Annex B stream and yields complete access units.
pub struct AuSplitter {
    codec: Codec,
    buf: Vec<u8>,
}

impl AuSplitter {
    pub fn new(codec: Codec) -> Self {
        Self {
            codec,
            buf: Vec::new(),
        }
    }

    /// Feed a chunk of stream; returns complete (access unit, is_keyframe)
    /// pairs cut at AUD boundaries.
    pub fn feed(&mut self, chunk: &[u8]) -> Vec<(Vec<u8>, bool)> {
        self.buf.extend_from_slice(chunk);
        let auds: Vec<usize> = start_codes(&self.buf)
            .iter()
            .filter(|&&(_, header)| is_aud(header, self.codec))
            .map(|&(pos, _)| pos)
            .collect();
        let mut out = Vec::new();
        if auds.len() >= 2 {
            for pair in auds.windows(2) {
                let au = self.buf[pair[0]..pair[1]].to_vec();
                let keyframe = au_is_keyframe(&au, self.codec);
                out.push((au, keyframe));
            }
            let keep_from = *auds.last().expect("auds.len() >= 2");
            self.buf.drain(..keep_from);
        }
        out
    }

    /// Flush the trailing access unit at end of stream.
    pub fn finish(&mut self) -> Option<(Vec<u8>, bool)> {
        if self.buf.is_empty() {
            return None;
        }
        let au = std::mem::take(&mut self.buf);
        let keyframe = au_is_keyframe(&au, self.codec);
        Some((au, keyframe))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const AUD_H264: &[u8] = &[0, 0, 0, 1, 0x09, 0x10]; // nal type 9
    const IDR_H264: &[u8] = &[0, 0, 0, 1, 0x65, 0x88]; // nal type 5
    const NON_IDR_H264: &[u8] = &[0, 0, 0, 1, 0x41, 0x9a]; // nal type 1
    const AUD_HEVC: &[u8] = &[0, 0, 0, 1, 0x46, 1]; // nal type 35
    const IDR_HEVC: &[u8] = &[0, 0, 0, 1, 0x26, 1]; // nal type 19

    #[test]
    fn splits_h264_at_aud_and_flags_keyframes() {
        let mut splitter = AuSplitter::new(Codec::H264);
        let mut stream = Vec::new();
        stream.extend_from_slice(AUD_H264);
        stream.extend_from_slice(IDR_H264);
        stream.extend_from_slice(AUD_H264);
        stream.extend_from_slice(NON_IDR_H264);
        stream.extend_from_slice(AUD_H264);
        stream.extend_from_slice(NON_IDR_H264);

        // Feed in odd-sized chunks to exercise partial reads.
        let mut aus = Vec::new();
        for chunk in stream.chunks(7) {
            aus.extend(splitter.feed(chunk));
        }
        aus.extend(splitter.finish());

        assert_eq!(aus.len(), 3);
        assert!(aus[0].1, "first AU contains an IDR");
        assert!(!aus[1].1);
        assert!(!aus[2].1);
        assert!(aus[0].0.starts_with(&[0, 0, 1]) || aus[0].0.starts_with(&[0, 0, 0, 1]));
    }

    #[test]
    fn splits_hevc_and_flags_idr() {
        let mut splitter = AuSplitter::new(Codec::Hevc);
        let mut stream = Vec::new();
        stream.extend_from_slice(AUD_HEVC);
        stream.extend_from_slice(IDR_HEVC);
        stream.extend_from_slice(AUD_HEVC);
        stream.extend_from_slice(&[0, 0, 0, 1, 0x02, 1]); // trailing non-IDR

        let aus = splitter.feed(&stream);
        assert_eq!(aus.len(), 1);
        assert!(aus[0].1, "HEVC IDR_W_RADL (type 19) must flag keyframe");
        let tail = splitter.finish().expect("trailing AU");
        assert!(!tail.1);
    }
}
