//
//  GIF81Writer.swift
//  RGB2GIF
//
//  ============================================================================
//  GIF81 WRITER - Hard-Constrained 81x81x81 GIF Generator
//  ============================================================================
//
//  PURPOSE: Write GIF89a files that are EXACTLY 81x81 pixels, 81 frames, 256 colors.
//           NO OPTIONS. NO FLEXIBILITY. JUST CORRECTNESS.
//
//  HARD CONSTRAINTS (NON-NEGOTIABLE)
//  ----------------------------------
//  1. Dimensions: 81x81 pixels (for 9x9 GO neural network compatibility)
//  2. Frame count: EXACTLY 81 frames (one per row of the cube)
//  3. Palette size: EXACTLY 256 colors (full GIF capacity)
//  4. Color table: GLOBAL ONLY (no local color tables)
//  5. Min LZW code size: 8 (required for 256 colors)
//
//  WHY THESE CONSTRAINTS?
//  ----------------------
//  - 81x81: Enables future 9x9 GO game state encoding (81 = 9*9)
//  - 81 frames: Creates an 81x81x81 voxel cube for 3D visualization
//  - 256 colors: Maximum GIF capacity, enables composable palette swaps
//  - Global palette: Required for palette swapping without re-encoding LZW
//
//  GIF FILE STRUCTURE
//  ------------------
//  ┌─────────────────────────────────────────────┐
//  │ Header (6 bytes): "GIF89a"                  │
//  ├─────────────────────────────────────────────┤
//  │ Logical Screen Descriptor (7 bytes)         │
//  │   Width: 81, Height: 81, GCT=256 colors     │
//  ├─────────────────────────────────────────────┤
//  │ Global Color Table (768 bytes) ← SWAPPABLE! │
//  │   256 colors × 3 bytes (R, G, B)            │
//  ├─────────────────────────────────────────────┤
//  │ Netscape Extension (19 bytes)               │
//  │   Loop forever                              │
//  ├─────────────────────────────────────────────┤
//  │ × 81 FRAMES:                                │
//  │   Graphic Control Extension (8 bytes)       │
//  │   Image Descriptor (10 bytes)               │
//  │   LZW Image Data (variable)                 │
//  ├─────────────────────────────────────────────┤
//  │ Trailer (1 byte): 0x3B                      │
//  └─────────────────────────────────────────────┘
//
//  USAGE
//  -----
//  let frames: [[UInt8]] = ... // 81 frames, each 6561 indices
//  let palette: [(r: UInt8, g: UInt8, b: UInt8)] = ... // 256 colors
//  try GIF81Writer.write(frames: frames, palette: palette, to: outputURL)
//
//  ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "GIF81Writer")

// MARK: - GIF81 Writer

/// Writes GIF89a files with hard constraints: 81x81 pixels, 81 frames, 256 colors.
/// This writer validates ALL constraints before writing and will FAIL if any are violated.
///
/// ## Hard Constraints
/// - Width: 81 pixels
/// - Height: 81 pixels
/// - Frame count: 81 frames
/// - Palette: 256 colors (global only)
/// - Min code size: 8 bits
///
/// ## Design Philosophy
/// This writer has NO configuration options. The constraints are enforced at compile
/// time (where possible) and runtime (where necessary). If your data doesn't fit
/// these constraints, you cannot use this writer.
@available(iOS 26.0, *)
public struct GIF81Writer {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Hard Constraints
    // ════════════════════════════════════════════════════════════════════════

    /// Fixed width (81 pixels for 9x9 GO board compatibility)
    public static let width: Int = 81

    /// Fixed height (81 pixels, square frames)
    public static let height: Int = 81

    /// Fixed frame count (81 frames for 81x81x81 voxel cube)
    public static let frameCount: Int = 81

    /// Fixed palette size (256 colors, full GIF capacity)
    public static let paletteSize: Int = 256

    /// Pixels per frame (81 × 81 = 6561)
    public static let pixelsPerFrame: Int = width * height

    /// Total pixels in GIF (81 × 81 × 81 = 531,441)
    public static let totalPixels: Int = pixelsPerFrame * frameCount

    /// Default frame delay in centiseconds (3 = ~33 FPS)
    public static let defaultFrameDelay: UInt16 = 3

    /// LZW minimum code size for 256 colors
    public static let minCodeSize: UInt8 = 8

    /// Current frame delay (can be overridden per write call)
    private static var currentFrameDelay: UInt16 = defaultFrameDelay

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Public API
    // ════════════════════════════════════════════════════════════════════════

    /// Write a complete GIF file with hard constraints.
    ///
    /// This function validates all inputs and fails fast if any constraint is violated.
    ///
    /// - Parameters:
    ///   - frames: Array of 81 frames, each containing 6561 palette indices (0-255)
    ///   - palette: Array of 256 RGB colors
    ///   - destination: URL to write the GIF file
    ///   - frameDelay: Frame delay in centiseconds (default: 3 = ~33 FPS)
    /// - Throws: `GIF81Error` if any constraint is violated
    public static func write(
        frames: [[UInt8]],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        to destination: URL,
        frameDelay: UInt16 = defaultFrameDelay
    ) throws {
        // Set the frame delay for this write operation
        currentFrameDelay = frameDelay

        // ──────────────────────────────────────────────────────────────────
        // VALIDATION (fail fast on ANY constraint violation)
        // ──────────────────────────────────────────────────────────────────

        logger.info("GIF81Writer: Validating constraints...")

        // Frame count
        guard frames.count == frameCount else {
            throw GIF81Error.wrongFrameCount(expected: frameCount, actual: frames.count)
        }

        // Palette size
        guard palette.count == paletteSize else {
            throw GIF81Error.wrongPaletteSize(expected: paletteSize, actual: palette.count)
        }

        // Frame sizes
        for (i, frame) in frames.enumerated() {
            guard frame.count == pixelsPerFrame else {
                throw GIF81Error.wrongFrameSize(
                    frame: i,
                    expected: pixelsPerFrame,
                    actual: frame.count
                )
            }

            // Validate all indices are valid (0-255)
            // This check is technically unnecessary since UInt8 can only be 0-255,
            // but we keep it for documentation purposes
        }

        logger.info("GIF81Writer: All constraints validated. Writing GIF...")

        // ──────────────────────────────────────────────────────────────────
        // BUILD GIF DATA
        // ──────────────────────────────────────────────────────────────────

        var data = Data()

        // 1. Header (6 bytes)
        data.append(contentsOf: header())

        // 2. Logical Screen Descriptor (7 bytes)
        data.append(contentsOf: logicalScreenDescriptor())

        // 3. Global Color Table (768 bytes)
        data.append(contentsOf: globalColorTable(palette: palette))

        // 4. Netscape Looping Extension (19 bytes)
        data.append(contentsOf: netscapeExtension())

        // 5. Frames (81 × [GCE + Image Descriptor + LZW Data])
        for (i, frame) in frames.enumerated() {
            // Graphic Control Extension
            data.append(contentsOf: graphicControlExtension())

            // Image Descriptor
            data.append(contentsOf: imageDescriptor())

            // LZW Compressed Image Data
            let lzwData = try compressFrame(frame)
            data.append(lzwData)

            if (i + 1) % 10 == 0 {
                logger.debug("GIF81Writer: Compressed frame \(i + 1)/\(frameCount)")
            }
        }

        // 6. Trailer (1 byte)
        data.append(0x3B)

        // ──────────────────────────────────────────────────────────────────
        // FINAL VALIDATION
        // ──────────────────────────────────────────────────────────────────

        try validateGIFStructure(data)

        // ──────────────────────────────────────────────────────────────────
        // WRITE TO DISK
        // ──────────────────────────────────────────────────────────────────

        try data.write(to: destination)

        let sizeKB = Double(data.count) / 1024.0
        logger.info("GIF81Writer: Wrote \(String(format: "%.1f", sizeKB)) KB to \(destination.lastPathComponent)")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - GIF Structure Generators
    // ════════════════════════════════════════════════════════════════════════

    /// GIF89a header (6 bytes)
    private static func header() -> [UInt8] {
        return Array("GIF89a".utf8)
    }

    /// Logical Screen Descriptor (7 bytes)
    ///
    /// Defines the logical screen size and global color table properties.
    private static func logicalScreenDescriptor() -> [UInt8] {
        // Packed byte:
        // Bit 7: Global Color Table Flag (1 = present)
        // Bits 4-6: Color Resolution (7 = 8 bits per primary color)
        // Bit 3: Sort Flag (0 = not sorted)
        // Bits 0-2: Size of GCT (7 = 2^(7+1) = 256 colors)
        let packed: UInt8 = 0b1_111_0_111  // 0xF7

        return [
            UInt8(width & 0xFF),        // Width low byte
            UInt8((width >> 8) & 0xFF), // Width high byte
            UInt8(height & 0xFF),       // Height low byte
            UInt8((height >> 8) & 0xFF), // Height high byte
            packed,                      // Packed byte
            0x00,                        // Background color index
            0x00                         // Pixel aspect ratio (0 = not specified)
        ]
    }

    /// Global Color Table (768 bytes = 256 colors × 3 bytes)
    private static func globalColorTable(palette: [(r: UInt8, g: UInt8, b: UInt8)]) -> [UInt8] {
        var gct = [UInt8]()
        gct.reserveCapacity(768)

        for color in palette {
            gct.append(color.r)
            gct.append(color.g)
            gct.append(color.b)
        }

        // Ensure exactly 768 bytes (pad with black if somehow short)
        while gct.count < 768 {
            gct.append(0)
        }

        return gct
    }

    /// Netscape Application Extension for looping (19 bytes)
    private static func netscapeExtension() -> [UInt8] {
        return [
            0x21,                      // Extension Introducer
            0xFF,                      // Application Extension Label
            0x0B,                      // Block size (11 bytes)
            // "NETSCAPE2.0"
            0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30,
            0x03,                      // Sub-block size (3 bytes)
            0x01,                      // Sub-block ID (animation)
            0x00, 0x00,                // Loop count (0 = infinite)
            0x00                       // Block terminator
        ]
    }

    /// Graphic Control Extension (8 bytes)
    ///
    /// Controls frame timing and transparency.
    private static func graphicControlExtension() -> [UInt8] {
        // Packed byte:
        // Bits 5-7: Reserved (0)
        // Bits 2-4: Disposal method (1 = do not dispose)
        // Bit 1: User input flag (0)
        // Bit 0: Transparent color flag (0)
        let packed: UInt8 = 0b000_001_0_0  // 0x04

        return [
            0x21,                       // Extension Introducer
            0xF9,                       // Graphic Control Label
            0x04,                       // Block size (4 bytes)
            packed,                     // Packed byte
            UInt8(currentFrameDelay & 0xFF),   // Delay time low byte
            UInt8((currentFrameDelay >> 8) & 0xFF), // Delay time high byte
            0x00,                       // Transparent color index (unused)
            0x00                        // Block terminator
        ]
    }

    /// Image Descriptor (10 bytes)
    ///
    /// Defines the position and size of each frame.
    private static func imageDescriptor() -> [UInt8] {
        // Packed byte:
        // Bit 7: Local Color Table Flag (0 = no local table)
        // Bit 6: Interlace Flag (0 = not interlaced)
        // Bit 5: Sort Flag (0)
        // Bits 3-4: Reserved (0)
        // Bits 0-2: Size of Local Color Table (0 = none)
        let packed: UInt8 = 0x00  // No local color table!

        return [
            0x2C,                       // Image Separator
            0x00, 0x00,                 // Left position
            0x00, 0x00,                 // Top position
            UInt8(width & 0xFF),        // Width low byte
            UInt8((width >> 8) & 0xFF), // Width high byte
            UInt8(height & 0xFF),       // Height low byte
            UInt8((height >> 8) & 0xFF), // Height high byte
            packed                       // Packed byte
        ]
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - LZW Compression
    // ════════════════════════════════════════════════════════════════════════

    /// Compress frame data using LZW algorithm
    ///
    /// - Parameter indices: 6561 palette indices (0-255)
    /// - Returns: LZW compressed data with min code size prefix and sub-blocks
    private static func compressFrame(_ indices: [UInt8]) throws -> Data {
        var result = Data()

        // LZW Minimum Code Size (1 byte)
        result.append(minCodeSize)

        // Compress using optimized LZW encoder
        let subBlocks = try LZW_Optimized.compress(indices: indices, minCodeSize: minCodeSize)

        // Write sub-blocks (each prefixed with its length)
        for block in subBlocks {
            result.append(UInt8(block.count))
            result.append(block)
        }

        // Block terminator
        result.append(0x00)

        return result
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Validation
    // ════════════════════════════════════════════════════════════════════════

    /// Validate the final GIF structure before writing
    private static func validateGIFStructure(_ data: Data) throws {
        // 1. Header check
        guard data.count >= 6,
              data.prefix(6) == Data("GIF89a".utf8) else {
            throw GIF81Error.invalidHeader
        }

        // 2. Dimensions check
        guard data.count >= 10 else {
            throw GIF81Error.dataTooShort
        }

        let readWidth = UInt16(data[6]) | (UInt16(data[7]) << 8)
        let readHeight = UInt16(data[8]) | (UInt16(data[9]) << 8)

        guard readWidth == 81 && readHeight == 81 else {
            throw GIF81Error.dimensionMismatch(
                expectedWidth: 81, actualWidth: Int(readWidth),
                expectedHeight: 81, actualHeight: Int(readHeight)
            )
        }

        // 3. Global Color Table check
        let packed = data[10]
        guard (packed & 0x80) != 0 else {
            throw GIF81Error.missingGlobalColorTable
        }

        let gctSize = 1 << ((packed & 0x07) + 1)
        guard gctSize == 256 else {
            throw GIF81Error.wrongGCTSize(expected: 256, actual: gctSize)
        }

        // 4. Trailer check
        guard data.last == 0x3B else {
            throw GIF81Error.missingTrailer
        }

        logger.debug("GIF81Writer: Validation passed")
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
extension GIF81Writer {

    /// Errors that can occur during GIF81 writing
    public enum GIF81Error: Error, LocalizedError {
        case wrongFrameCount(expected: Int, actual: Int)
        case wrongPaletteSize(expected: Int, actual: Int)
        case wrongFrameSize(frame: Int, expected: Int, actual: Int)
        case invalidHeader
        case dataTooShort
        case dimensionMismatch(expectedWidth: Int, actualWidth: Int, expectedHeight: Int, actualHeight: Int)
        case missingGlobalColorTable
        case wrongGCTSize(expected: Int, actual: Int)
        case missingTrailer
        case compressionFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .wrongFrameCount(let expected, let actual):
                return "GIF81 requires exactly \(expected) frames, got \(actual)"
            case .wrongPaletteSize(let expected, let actual):
                return "GIF81 requires exactly \(expected) palette colors, got \(actual)"
            case .wrongFrameSize(let frame, let expected, let actual):
                return "Frame \(frame) has \(actual) pixels, expected \(expected)"
            case .invalidHeader:
                return "Invalid GIF header (expected 'GIF89a')"
            case .dataTooShort:
                return "GIF data too short to contain required headers"
            case .dimensionMismatch(let ew, let aw, let eh, let ah):
                return "Dimensions mismatch: expected \(ew)x\(eh), got \(aw)x\(ah)"
            case .missingGlobalColorTable:
                return "GIF missing required Global Color Table"
            case .wrongGCTSize(let expected, let actual):
                return "GCT size mismatch: expected \(expected) colors, got \(actual)"
            case .missingTrailer:
                return "GIF missing trailer byte (0x3B)"
            case .compressionFailed(let error):
                return "LZW compression failed: \(error.localizedDescription)"
            }
        }
    }
}

// NOTE: GIF81Validator is defined in GIF81Validator.swift with extended functionality
