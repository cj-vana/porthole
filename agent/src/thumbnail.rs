//! Thumbnail support (FR-10): downscale captured frames for the machine
//! picker. Pure logic, compiled everywhere so tests run on macOS.

/// Thumbnail width in pixels; height follows the source aspect ratio.
pub const THUMBNAIL_WIDTH: u32 = 320;

/// Downscale a BGRA8 frame to RGBA8, `THUMBNAIL_WIDTH` px wide, by nearest
/// neighbor sampling (fast and good enough for picker thumbnails).
///
/// `stride` is the source row length in bytes and may exceed `width * 4`.
/// Returns (width, height, rgba) or None on empty/implausible input.
pub fn downscale_bgra_to_rgba(
    data: &[u8],
    width: u32,
    height: u32,
    stride: usize,
) -> Option<(u16, u16, Vec<u8>)> {
    if width == 0 || height == 0 || stride < width as usize * 4 {
        return None;
    }
    if data.len() < stride * height as usize {
        return None;
    }
    let out_w = THUMBNAIL_WIDTH.min(width);
    let out_h = (u64::from(height) * u64::from(out_w) / u64::from(width)).max(1) as u32;
    let mut out = Vec::with_capacity((out_w * out_h * 4) as usize);
    for y in 0..out_h {
        let src_y = (u64::from(y) * u64::from(height) / u64::from(out_h)) as usize;
        let row = &data[src_y * stride..];
        for x in 0..out_w {
            let src_x = (u64::from(x) * u64::from(width) / u64::from(out_w)) as usize;
            let px = &row[src_x * 4..src_x * 4 + 4];
            // BGRA -> RGBA byte swap.
            out.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
        }
    }
    Some((out_w as u16, out_h as u16, out))
}

/// Wire payload for the thumbnail endpoint: width u16 BE, height u16 BE,
/// then width*height*4 bytes of RGBA8.
pub fn encode_thumbnail(width: u16, height: u16, rgba: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + rgba.len());
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(rgba);
    out
}

/// Parse a thumbnail payload. Returns None when the payload is too short or
/// the declared size does not match the pixel data.
pub fn decode_thumbnail(payload: &[u8]) -> Option<(u16, u16, &[u8])> {
    if payload.len() < 4 {
        return None;
    }
    let width = u16::from_be_bytes(payload[0..2].try_into().ok()?);
    let height = u16::from_be_bytes(payload[2..4].try_into().ok()?);
    let pixels = &payload[4..];
    if width == 0 || height == 0 || pixels.len() != width as usize * height as usize * 4 {
        return None;
    }
    Some((width, height, pixels))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bgra_frame(width: u32, height: u32, stride: usize) -> Vec<u8> {
        // B channel varies by column, R by row; makes sampling observable.
        let mut data = vec![0u8; stride * height as usize];
        for y in 0..height as usize {
            for x in 0..width as usize {
                let o = y * stride + x * 4;
                data[o] = (x % 256) as u8; // B
                data[o + 1] = 0; // G
                data[o + 2] = (y % 256) as u8; // R
                data[o + 3] = 255; // A
            }
        }
        data
    }

    #[test]
    fn downscale_known_size() {
        let data = bgra_frame(2560, 1440, 2560 * 4);
        let (w, h, rgba) = downscale_bgra_to_rgba(&data, 2560, 1440, 2560 * 4).unwrap();
        assert_eq!(w, 320);
        assert_eq!(h, 180);
        assert_eq!(rgba.len(), 320 * 180 * 4);
        // Corner pixel: B from x=0 (0), R from y=0 (0), swapped to RGBA.
        assert_eq!(&rgba[0..4], &[0, 0, 0, 255]);
    }

    #[test]
    fn downscale_handles_odd_stride_and_rejects_garbage() {
        // Stride larger than tight packing must not panic or misread.
        let stride = 100 * 4 + 12;
        let data = bgra_frame(100, 50, stride);
        let (w, h, rgba) = downscale_bgra_to_rgba(&data, 100, 50, stride).unwrap();
        assert_eq!((w, h), (100, 50)); // smaller than THUMBNAIL_WIDTH: kept 1:1
        assert_eq!(rgba.len(), 100 * 50 * 4);

        assert!(downscale_bgra_to_rgba(&data, 0, 50, stride).is_none());
        assert!(downscale_bgra_to_rgba(&data, 100, 50, 100).is_none());
        assert!(downscale_bgra_to_rgba(&data[..100], 100, 50, stride).is_none());
    }

    #[test]
    fn thumbnail_payload_round_trip() {
        let (w, h, rgba) = (2u16, 2u16, vec![1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
        let payload = encode_thumbnail(w, h, &rgba);
        let (dw, dh, dpixels) = decode_thumbnail(&payload).unwrap();
        assert_eq!((dw, dh), (w, h));
        assert_eq!(dpixels, &rgba[..]);

        assert!(decode_thumbnail(&[]).is_none());
        assert!(decode_thumbnail(&payload[..10]).is_none()); // truncated pixels
    }
}
