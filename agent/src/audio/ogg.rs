//! Minimal Ogg page reader (US-009).
//!
//! ffmpeg muxes the Opus stream as Ogg on stdout; this pulls the Opus
//! packets back out. It handles just the parts an Opus-in-Ogg stream uses:
//! the capture pattern of a page (magic OggS, the 27-byte header, the
//! segment table), and packet continuation across segments and pages. The
//! two Opus header packets (OpusHead, OpusTags) come through like any
//! other; the caller drops them.

/// Splits a byte stream of Ogg pages into the packets they carry.
#[derive(Default)]
pub struct OggReader {
    buffer: Vec<u8>,
    /// Bytes of a packet continued from a previous page or segment.
    partial: Vec<u8>,
}

impl OggReader {
    /// Feed bytes read from ffmpeg and return every complete packet now
    /// available. A packet is complete when a segment shorter than 255
    /// bytes ends it (the Ogg lacing convention).
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(bytes);
        let mut packets = Vec::new();
        let mut consumed = 0;

        while let Some(page_start) = find_capture(&self.buffer[consumed..]) {
            let page = consumed + page_start;
            // Need the fixed 27-byte header to read the segment count.
            if self.buffer.len() < page + 27 {
                break;
            }
            let segment_count = self.buffer[page + 26] as usize;
            let table_end = page + 27 + segment_count;
            if self.buffer.len() < table_end {
                break;
            }
            let segment_sizes = &self.buffer[page + 27..table_end];
            let body_len: usize = segment_sizes.iter().map(|&s| s as usize).sum();
            let body_end = table_end + body_len;
            if self.buffer.len() < body_end {
                break; // page body not fully arrived
            }

            let mut offset = table_end;
            for &size in segment_sizes {
                let size = size as usize;
                self.partial
                    .extend_from_slice(&self.buffer[offset..offset + size]);
                offset += size;
                if size < 255 {
                    // A segment under 255 bytes terminates the packet.
                    packets.push(std::mem::take(&mut self.partial));
                }
            }
            consumed = body_end;
        }

        if consumed > 0 {
            self.buffer.drain(..consumed);
        }
        packets
    }
}

/// Offset of the next "OggS" capture pattern, if any.
fn find_capture(bytes: &[u8]) -> Option<usize> {
    bytes.windows(4).position(|w| w == b"OggS")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build one Ogg page carrying the given packets (each split into 255
    /// byte segments, terminated by a short segment), for the reader test.
    fn page(packets: &[&[u8]]) -> Vec<u8> {
        let mut segments: Vec<u8> = Vec::new();
        let mut body: Vec<u8> = Vec::new();
        for packet in packets {
            let mut remaining = packet.len();
            loop {
                let seg = remaining.min(255);
                segments.push(seg as u8);
                remaining -= seg;
                if seg < 255 {
                    break;
                }
            }
            body.extend_from_slice(packet);
        }
        let mut out = Vec::new();
        out.extend_from_slice(b"OggS");
        out.push(0); // version
        out.push(0); // header type
        out.extend_from_slice(&[0u8; 8]); // granule position
        out.extend_from_slice(&[0u8; 4]); // serial
        out.extend_from_slice(&[0u8; 4]); // page sequence
        out.extend_from_slice(&[0u8; 4]); // checksum (not verified)
        out.push(segments.len() as u8);
        out.extend_from_slice(&segments);
        out.extend_from_slice(&body);
        out
    }

    #[test]
    fn reads_packets_from_a_page() {
        let mut reader = OggReader::default();
        let short = vec![1u8; 100];
        let long = vec![2u8; 600]; // spans three segments (255, 255, 90)
        let data = page(&[&short, &long]);
        let packets = reader.feed(&data);
        assert_eq!(packets, vec![short, long]);
    }

    #[test]
    fn reassembles_across_feeds() {
        let mut reader = OggReader::default();
        let packet = vec![7u8; 300];
        let data = page(&[&packet]);
        // Deliver the page one byte at a time; nothing completes until the
        // whole page has arrived.
        let mut packets = Vec::new();
        for chunk in data.chunks(1) {
            packets.extend(reader.feed(chunk));
        }
        assert_eq!(packets, vec![packet]);
    }

    #[test]
    fn ignores_leading_garbage_before_capture() {
        let mut reader = OggReader::default();
        let packet = vec![9u8; 50];
        let mut data = vec![0xFFu8; 13];
        data.extend_from_slice(&page(&[&packet]));
        assert_eq!(reader.feed(&data), vec![packet]);
    }
}
