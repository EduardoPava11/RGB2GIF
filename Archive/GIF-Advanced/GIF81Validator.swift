//
//  GIF81Validator.swift
//  RGB2GIF
//
//  ============================================================================
//  GIF81 VALIDATOR: Verify GIF Structure Meets Hard Constraints
//  ============================================================================
//
//  HARD CONSTRAINTS (from MVP specification)
//  ─────────────────────────────────────────
//  1. Dimensions: EXACTLY 81×81 pixels
//  2. Frame count: EXACTLY 81 frames
//  3. Palette: EXACTLY 256 colors (global only)
//  4. No local color tables
//  5. LZW minimum code size: 8 (for 256-color palette)
//  6. Valid GIF89a magic bytes
//
//  GIF89a STRUCTURE REFERENCE
//  ──────────────────────────
//  Offset  Size  Content
//  ──────────────────────────────────────────
//  0       6     Magic "GIF89a"
//  6       2     Width (little-endian)
//  8       2     Height (little-endian)
//  10      1     Packed byte: GCT flag, color resolution, sort, GCT size
//  11      1     Background color index
//  12      1     Pixel aspect ratio
//  13      768   Global Color Table (256 × 3 bytes)
//  781+          Extension blocks and image data
//
//  PACKED BYTE AT OFFSET 10
//  ────────────────────────
//  Bit 7:    Global Color Table flag (1 = present)
//  Bits 4-6: Color resolution (bits per primary color - 1)
//  Bit 3:    Sort flag
//  Bits 0-2: GCT size = 2^(N+1) colors, so N=7 means 256 colors
//
//  For 256-color GIF: packed byte = 0b11110111 = 0xF7
//
//  ============================================================================

import Foundation

// MARK: - GIF81 Validator

@available(iOS 26.0, *)
public struct GIF81Validator {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Expected Values
    // ════════════════════════════════════════════════════════════════════════

    /// Expected magic bytes for GIF89a
    public static let expectedMagic: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]  // "GIF89a"

    /// Expected dimensions
    public static let expectedWidth: UInt16 = 81
    public static let expectedHeight: UInt16 = 81

    /// Expected frame count
    public static let expectedFrameCount: Int = 81

    /// Expected palette size
    public static let expectedPaletteSize: Int = 256

    /// Expected packed byte for 256-color global palette
    /// Bit 7 = 1 (GCT present), Bits 4-6 = 7 (8 bits), Bit 3 = 1 (sorted), Bits 0-2 = 7 (256 colors)
    public static let expectedPackedByte: UInt8 = 0xF7

    /// Offset where Global Color Table starts
    public static let gctOffset: Int = 13

    /// Size of Global Color Table (256 × 3 = 768 bytes)
    public static let gctSize: Int = 768

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Validation
    // ════════════════════════════════════════════════════════════════════════

    /// Validate a GIF file at the given URL.
    ///
    /// - Parameter url: Path to the GIF file
    /// - Returns: Validation result with details
    public static func validate(at url: URL) throws -> ValidationResult {
        let data = try Data(contentsOf: url)
        return validate(data: data)
    }

    /// Validate GIF data in memory.
    ///
    /// - Parameter data: Raw GIF bytes
    /// - Returns: Validation result with details
    public static func validate(data: Data) -> ValidationResult {
        var result = ValidationResult()

        // ─────────────────────────────────────────────────────────────────────
        // Check 1: File size is reasonable
        // ─────────────────────────────────────────────────────────────────────
        result.fileSize = data.count

        if data.count < 800 {  // Minimum: header (13) + GCT (768) + some data
            result.issues.append("File too small: \(data.count) bytes")
            return result
        }

        let bytes = [UInt8](data)

        // ─────────────────────────────────────────────────────────────────────
        // Check 2: Magic bytes
        // ─────────────────────────────────────────────────────────────────────
        let magic = Array(bytes[0..<6])
        result.hasMagicBytes = (magic == expectedMagic)

        if !result.hasMagicBytes {
            let magicStr = String(bytes: magic, encoding: .ascii) ?? "invalid"
            result.issues.append("Invalid magic bytes: '\(magicStr)' (expected 'GIF89a')")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 3: Dimensions
        // ─────────────────────────────────────────────────────────────────────
        let width = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let height = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)

        result.width = Int(width)
        result.height = Int(height)
        result.hasCorrectDimensions = (width == expectedWidth && height == expectedHeight)

        if !result.hasCorrectDimensions {
            result.issues.append("Incorrect dimensions: \(width)×\(height) (expected 81×81)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 4: Packed byte (GCT present, 256 colors)
        // ─────────────────────────────────────────────────────────────────────
        let packedByte = bytes[10]

        // Check GCT flag (bit 7)
        let hasGCT = (packedByte & 0x80) != 0
        result.hasGlobalColorTable = hasGCT

        if !hasGCT {
            result.issues.append("No Global Color Table (packed byte bit 7 = 0)")
        }

        // Check GCT size (bits 0-2)
        let gctSizeBits = packedByte & 0x07
        let gctColorCount = 1 << (Int(gctSizeBits) + 1)
        result.paletteSize = gctColorCount

        result.hasCorrectPaletteSize = (gctColorCount == expectedPaletteSize)

        if !result.hasCorrectPaletteSize {
            result.issues.append("Incorrect palette size: \(gctColorCount) (expected 256)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 5: Count frames (Image Descriptors)
        // ─────────────────────────────────────────────────────────────────────
        result.frameCount = countFrames(in: bytes)
        result.hasCorrectFrameCount = (result.frameCount == expectedFrameCount)

        if !result.hasCorrectFrameCount {
            result.issues.append("Incorrect frame count: \(result.frameCount) (expected 81)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 6: No local color tables
        // ─────────────────────────────────────────────────────────────────────
        result.localColorTableCount = countLocalColorTables(in: bytes)
        result.hasNoLocalColorTables = (result.localColorTableCount == 0)

        if !result.hasNoLocalColorTables {
            result.issues.append("Found \(result.localColorTableCount) local color tables (expected 0)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 7: LZW minimum code size
        // ─────────────────────────────────────────────────────────────────────
        let lzwMinCodes = findLZWMinCodes(in: bytes)
        result.lzwMinCodeSizes = lzwMinCodes
        result.hasCorrectLZWMinCode = lzwMinCodes.allSatisfy { $0 == 8 }

        if !result.hasCorrectLZWMinCode {
            let incorrect = lzwMinCodes.filter { $0 != 8 }
            result.issues.append("Incorrect LZW min code sizes: \(incorrect) (expected all 8)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 8: File ends with trailer
        // ─────────────────────────────────────────────────────────────────────
        result.hasTrailer = (bytes.last == 0x3B)

        if !result.hasTrailer {
            result.issues.append("Missing GIF trailer byte (0x3B)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Extract palette for analysis
        // ─────────────────────────────────────────────────────────────────────
        if hasGCT && data.count >= gctOffset + gctSize {
            var palette = [(r: UInt8, g: UInt8, b: UInt8)]()
            for i in 0..<256 {
                let offset = gctOffset + i * 3
                palette.append((
                    r: bytes[offset],
                    g: bytes[offset + 1],
                    b: bytes[offset + 2]
                ))
            }
            result.palette = palette

            // Check palette is luminance-ordered
            result.paletteIsLuminanceOrdered = checkLuminanceOrder(palette)
        }

        return result
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Parsing Helpers
    // ════════════════════════════════════════════════════════════════════════

    /// Count Image Descriptor blocks (0x2C introducer).
    private static func countFrames(in bytes: [UInt8]) -> Int {
        var count = 0
        var i = gctOffset + gctSize  // Start after GCT

        while i < bytes.count - 1 {
            if bytes[i] == 0x2C {  // Image Descriptor
                count += 1
                i += 10  // Skip past image descriptor header

                // Skip image data
                if i < bytes.count {
                    i += 1  // LZW min code size
                    while i < bytes.count && bytes[i] != 0 {
                        let subBlockSize = Int(bytes[i])
                        i += 1 + subBlockSize
                    }
                    i += 1  // Block terminator
                }
            } else if bytes[i] == 0x21 {  // Extension
                i += 2  // Extension introducer + label
                while i < bytes.count && bytes[i] != 0 {
                    let subBlockSize = Int(bytes[i])
                    i += 1 + subBlockSize
                }
                i += 1  // Block terminator
            } else if bytes[i] == 0x3B {  // Trailer
                break
            } else {
                i += 1
            }
        }

        return count
    }

    /// Count Local Color Tables in image descriptors.
    private static func countLocalColorTables(in bytes: [UInt8]) -> Int {
        var count = 0
        var i = gctOffset + gctSize

        while i < bytes.count - 10 {
            if bytes[i] == 0x2C {  // Image Descriptor
                let packed = bytes[i + 9]
                if (packed & 0x80) != 0 {  // LCT flag set
                    count += 1
                }

                // Skip past this image
                i += 10
                if i < bytes.count {
                    // Skip LCT if present
                    if (packed & 0x80) != 0 {
                        let lctSize = 1 << ((Int(packed & 0x07)) + 1)
                        i += lctSize * 3
                    }
                    i += 1  // LZW min code
                    while i < bytes.count && bytes[i] != 0 {
                        i += 1 + Int(bytes[i])
                    }
                    i += 1
                }
            } else if bytes[i] == 0x21 {
                i += 2
                while i < bytes.count && bytes[i] != 0 {
                    i += 1 + Int(bytes[i])
                }
                i += 1
            } else if bytes[i] == 0x3B {
                break
            } else {
                i += 1
            }
        }

        return count
    }

    /// Find LZW minimum code sizes for all image blocks.
    private static func findLZWMinCodes(in bytes: [UInt8]) -> [UInt8] {
        var codes = [UInt8]()
        var i = gctOffset + gctSize

        while i < bytes.count - 10 {
            if bytes[i] == 0x2C {  // Image Descriptor
                let packed = bytes[i + 9]
                i += 10

                // Skip LCT if present
                if (packed & 0x80) != 0 {
                    let lctSize = 1 << ((Int(packed & 0x07)) + 1)
                    i += lctSize * 3
                }

                if i < bytes.count {
                    codes.append(bytes[i])  // LZW min code size
                    i += 1

                    // Skip image data
                    while i < bytes.count && bytes[i] != 0 {
                        i += 1 + Int(bytes[i])
                    }
                    i += 1
                }
            } else if bytes[i] == 0x21 {
                i += 2
                while i < bytes.count && bytes[i] != 0 {
                    i += 1 + Int(bytes[i])
                }
                i += 1
            } else if bytes[i] == 0x3B {
                break
            } else {
                i += 1
            }
        }

        return codes
    }

    /// Check if palette is sorted by luminance.
    private static func checkLuminanceOrder(_ palette: [(r: UInt8, g: UInt8, b: UInt8)]) -> Bool {
        var lastLuminance: Float = -1

        for color in palette {
            let lum = 0.299 * Float(color.r) + 0.587 * Float(color.g) + 0.114 * Float(color.b)
            if lum < lastLuminance - 0.5 {  // Allow small tolerance
                return false
            }
            lastLuminance = lum
        }

        return true
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Validation Result
    // ════════════════════════════════════════════════════════════════════════

    /// Complete validation result.
    public struct ValidationResult {
        // File metrics
        public var fileSize: Int = 0

        // Header checks
        public var hasMagicBytes: Bool = false
        public var width: Int = 0
        public var height: Int = 0
        public var hasCorrectDimensions: Bool = false

        // Palette checks
        public var hasGlobalColorTable: Bool = false
        public var paletteSize: Int = 0
        public var hasCorrectPaletteSize: Bool = false
        public var palette: [(r: UInt8, g: UInt8, b: UInt8)]?
        public var paletteIsLuminanceOrdered: Bool = false

        // Frame checks
        public var frameCount: Int = 0
        public var hasCorrectFrameCount: Bool = false
        public var hasNoLocalColorTables: Bool = false
        public var localColorTableCount: Int = 0

        // LZW checks
        public var lzwMinCodeSizes: [UInt8] = []
        public var hasCorrectLZWMinCode: Bool = false

        // Trailer
        public var hasTrailer: Bool = false

        // Issues found
        public var issues: [String] = []

        /// Overall validity
        public var isValid: Bool {
            hasMagicBytes &&
            hasCorrectDimensions &&
            hasGlobalColorTable &&
            hasCorrectPaletteSize &&
            hasCorrectFrameCount &&
            hasNoLocalColorTables &&
            hasCorrectLZWMinCode &&
            hasTrailer
        }

        /// Print detailed report
        public func printReport() {
            print("╔═══════════════════════════════════════════════════════════════════╗")
            print("║  GIF81 VALIDATION REPORT                                          ║")
            print("╠═══════════════════════════════════════════════════════════════════╣")
            print("║  File size: \(fileSize) bytes                                     ║")
            print("╠═══════════════════════════════════════════════════════════════════╣")
            print("║  Header:                                                          ║")
            print("║    Magic bytes:    \(hasMagicBytes ? "✓ GIF89a" : "✗ Invalid")                               ║")
            print("║    Dimensions:     \(hasCorrectDimensions ? "✓" : "✗") \(width)×\(height)                                     ║")
            print("╠═══════════════════════════════════════════════════════════════════╣")
            print("║  Palette:                                                         ║")
            print("║    Global CT:      \(hasGlobalColorTable ? "✓ Present" : "✗ Missing")                               ║")
            print("║    Size:           \(hasCorrectPaletteSize ? "✓" : "✗") \(paletteSize) colors                             ║")
            print("║    Luminance sort: \(paletteIsLuminanceOrdered ? "✓ Yes" : "✗ No")                                   ║")
            print("╠═══════════════════════════════════════════════════════════════════╣")
            print("║  Frames:                                                          ║")
            print("║    Count:          \(hasCorrectFrameCount ? "✓" : "✗") \(frameCount)                                       ║")
            print("║    Local CTs:      \(hasNoLocalColorTables ? "✓" : "✗") \(localColorTableCount) (should be 0)                        ║")
            print("║    LZW min code:   \(hasCorrectLZWMinCode ? "✓ All 8" : "✗ Varies")                               ║")
            print("╠═══════════════════════════════════════════════════════════════════╣")
            print("║  Trailer:          \(hasTrailer ? "✓ Present" : "✗ Missing")                               ║")
            print("╠═══════════════════════════════════════════════════════════════════╣")
            print("║  Overall:          \(isValid ? "✓ VALID" : "✗ INVALID")                                 ║")
            if !issues.isEmpty {
                print("╠═══════════════════════════════════════════════════════════════════╣")
                print("║  Issues:                                                          ║")
                for issue in issues {
                    print("║    • \(issue.prefix(58))".padding(toLength: 68, withPad: " ", startingAt: 0) + "║")
                }
            }
            print("╚═══════════════════════════════════════════════════════════════════╝")
        }
    }
}
