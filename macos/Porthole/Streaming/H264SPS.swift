import Foundation

/// Minimal H.264 sequence parameter set parser. Extracts the coded
/// dimensions (crop-adjusted) and the VUI color description the renderer
/// needs. Returns nil on malformed input; parsing stops once the fields we
/// need have been read, so trailing VUI sections are not validated.
struct H264SPS {
    /// YCbCr conversion matrix, from VUI matrix_coefficients.
    enum ColorMatrix {
        case bt601
        case bt709
        case bt2020
    }

    let width: Int
    let height: Int
    /// VUI video_full_range_flag; false (limited/video range) when absent.
    let fullRange: Bool
    /// VUI matrix_coefficients mapped to a known matrix, nil when absent or
    /// unrecognized. Callers should fall back to BT.709 for HD content.
    let colorMatrix: ColorMatrix?

    /// Parse an SPS NAL unit including its 1-byte NAL header (0x67).
    init?(nal: Data) {
        guard nal.count > 1, nal[0] & 0x1F == AnnexB.NALType.sps.rawValue else { return nil }
        var reader = BitReader(H264SPS.rbsp(from: nal))

        guard let profileIDC = reader.readBits(8) else { return nil }
        reader.skip(bits: 8) // constraint flags + reserved
        reader.skip(bits: 8) // level_idc
        guard reader.readUE() != nil else { return nil } // seq_parameter_set_id

        // High profiles carry extra format fields before the frame numbers.
        let highProfiles: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        var chromaFormatIDC = 1
        if highProfiles.contains(profileIDC) {
            guard let chroma = reader.readUE() else { return nil }
            chromaFormatIDC = chroma
            if chromaFormatIDC == 3 {
                reader.skip(bits: 1) // separate_colour_plane_flag
            }
            guard reader.readUE() != nil, // bit_depth_luma_minus8
                  reader.readUE() != nil else { return nil } // bit_depth_chroma_minus8
            reader.skip(bits: 1) // qpprime_y_zero_transform_bypass_flag
            if reader.readBits(1) == 1 { // seq_scaling_matrix_present_flag
                let count = chromaFormatIDC == 3 ? 12 : 8
                for index in 0..<count where reader.readBits(1) == 1 {
                    reader.skipScalingList(size: index < 6 ? 16 : 64)
                }
            }
        }

        guard reader.readUE() != nil, // log2_max_frame_num_minus4
              let picOrderCntType = reader.readUE() else { return nil }
        if picOrderCntType == 0 {
            guard reader.readUE() != nil else { return nil } // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            reader.skip(bits: 1) // delta_pic_order_always_zero_flag
            guard reader.readSE() != nil, reader.readSE() != nil else { return nil }
            guard let cycleCount = reader.readUE() else { return nil }
            for _ in 0..<cycleCount {
                guard reader.readSE() != nil else { return nil }
            }
        }

        guard reader.readUE() != nil, // max_num_ref_frames
              reader.readBits(1) != nil, // gaps_in_frame_num_value_allowed_flag
              let picWidthMbsMinus1 = reader.readUE(),
              let picHeightMapUnitsMinus1 = reader.readUE(),
              let frameMBSOnly = reader.readBits(1) else { return nil }
        if frameMBSOnly == 0 {
            reader.skip(bits: 1) // mb_adaptive_frame_field_flag
        }
        reader.skip(bits: 1) // direct_8x8_inference_flag

        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if reader.readBits(1) == 1 { // frame_cropping_flag
            guard let left = reader.readUE(), let right = reader.readUE(),
                  let top = reader.readUE(), let bottom = reader.readUE() else { return nil }
            cropLeft = left; cropRight = right; cropTop = top; cropBottom = bottom
        }

        let frameMbsOnlyFactor = frameMBSOnly == 1 ? 1 : 2
        var codedWidth = (picWidthMbsMinus1 + 1) * 16
        var codedHeight = (picHeightMapUnitsMinus1 + 1) * 16 * frameMbsOnlyFactor
        // Crop unit size depends on chroma subsampling (H.264 table 6-1).
        let subWidthC: Int, subHeightC: Int
        switch chromaFormatIDC {
        case 0: subWidthC = 1; subHeightC = 1 // monochrome
        case 2: subWidthC = 2; subHeightC = 1 // 4:2:2
        case 3: subWidthC = 1; subHeightC = 1 // 4:4:4
        default: subWidthC = 2; subHeightC = 2 // 4:2:0
        }
        let cropUnitX = chromaFormatIDC == 0 ? 1 : subWidthC
        let cropUnitY = (chromaFormatIDC == 0 ? 1 : subHeightC) * frameMbsOnlyFactor
        codedWidth -= (cropLeft + cropRight) * cropUnitX
        codedHeight -= (cropTop + cropBottom) * cropUnitY
        guard codedWidth > 0, codedHeight > 0 else { return nil }
        width = codedWidth
        height = codedHeight

        // VUI: only the color description is needed; everything before it is
        // fixed-layout enough to walk safely.
        var fullRange = false
        var matrix: ColorMatrix?
        if reader.readBits(1) == 1 { // vui_parameters_present_flag
            if reader.readBits(1) == 1 { // aspect_ratio_info_present_flag
                let aspectIDC = reader.readBits(8)
                if aspectIDC == 255 { // EXTENDED_SAR
                    reader.skip(bits: 32)
                }
            }
            if reader.readBits(1) == 1 { // overscan_info_present_flag
                reader.skip(bits: 1)
            }
            if reader.readBits(1) == 1 { // video_signal_type_present_flag
                reader.skip(bits: 3) // video_format
                fullRange = reader.readBits(1) == 1 // video_full_range_flag
                if reader.readBits(1) == 1 { // colour_description_present_flag
                    reader.skip(bits: 8) // colour_primaries
                    reader.skip(bits: 8) // transfer_characteristics
                    switch reader.readBits(8) { // matrix_coefficients
                    case 1: matrix = .bt709
                    case 5, 6: matrix = .bt601
                    case 9, 10: matrix = .bt2020
                    default: break
                    }
                }
            }
        }
        self.fullRange = fullRange
        colorMatrix = matrix
    }

    /// Strip the NAL header byte and remove emulation prevention bytes
    /// (00 00 03 -> 00 00) to get the RBSP.
    private static func rbsp(from nal: Data) -> Data {
        var rbsp = Data()
        rbsp.reserveCapacity(nal.count)
        var zeroCount = 0
        for byte in nal.dropFirst() {
            if zeroCount == 2, byte == 0x03 {
                zeroCount = 0
                continue
            }
            zeroCount = byte == 0 ? zeroCount + 1 : 0
            rbsp.append(byte)
        }
        return rbsp
    }
}

/// MSB-first bit reader with Exp-Golomb support, over the SPS RBSP.
private struct BitReader {
    let data: Data
    private(set) var bitPosition = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readBits(_ count: Int) -> Int? {
        guard count >= 0, bitPosition + count <= data.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let byte = data[bitPosition / 8]
            let bit = (byte >> (7 - UInt8(bitPosition % 8))) & 1
            value = value << 1 | Int(bit)
            bitPosition += 1
        }
        return value
    }

    mutating func skip(bits: Int) {
        bitPosition = min(bitPosition + bits, data.count * 8)
    }

    /// Unsigned Exp-Golomb coded value, ue(v).
    mutating func readUE() -> Int? {
        var leadingZeros = 0
        while let bit = readBits(1), bit == 0 {
            leadingZeros += 1
            guard leadingZeros < 32 else { return nil }
        }
        guard leadingZeros > 0 else { return 0 }
        guard let suffix = readBits(leadingZeros) else { return nil }
        return (1 << leadingZeros) - 1 + suffix
    }

    /// Signed Exp-Golomb coded value, se(v).
    mutating func readSE() -> Int? {
        guard let value = readUE() else { return nil }
        return value % 2 == 0 ? -(value / 2) : (value + 1) / 2
    }

    mutating func skipScalingList(size: Int) {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                guard let delta = readSE() else { return }
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }
}
