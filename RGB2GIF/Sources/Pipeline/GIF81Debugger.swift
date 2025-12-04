//
//  GIF81Debugger.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF81 PIPELINE DEBUGGER - Comprehensive Validation & Logging            ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  PURPOSE: Trace and validate every step of the GIF creation pipeline     ║
//  ║                                                                           ║
//  ║  FEATURES:                                                                ║
//  ║  • CGImage property validation (bytesPerRow, bitmapInfo, dimensions)     ║
//  ║  • Pixel data hex dump for visual inspection                             ║
//  ║  • OSSignposter integration for timing analysis                          ║
//  ║  • GIF structure validation against GIF89a spec                          ║
//  ║  • 729-tensor integrity checks                                           ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import os.log
import os.signpost

// MARK: - Debug Configuration

/// Global debug flags - set to true to enable detailed logging
@available(iOS 26.0, *)
public struct GIF81DebugFlags {
    /// Enable all debugging (master switch)
    public static var enabled = true

    /// Log CGImage properties at each stage
    public static var logImageProperties = true

    /// Dump sample pixels as hex (first/middle/last rows)
    public static var dumpPixelHex = true

    /// Validate bytesPerRow matches expected
    public static var validateBytesPerRow = true

    /// Log tensor statistics
    public static var logTensorStats = true

    /// Log palette colors
    public static var logPalette = true

    /// Log LZW compression stats
    public static var logLZWStats = true

    /// Validate final GIF structure
    public static var validateGIFStructure = true

    /// Number of sample pixels to dump per row
    public static var pixelSampleCount = 5
}

// MARK: - Debug Logger

private let debugLogger = Logger(subsystem: "com.rgb2gif.debug", category: "GIF81Debugger")
private let signposter = OSSignposter(subsystem: "com.rgb2gif", category: "Pipeline")

// MARK: - GIF81Debugger

@available(iOS 26.0, *)
public struct GIF81Debugger {

    // MARK: - Signpost Intervals

    /// Begin a signposted interval for timing analysis
    /// Returns the interval state which MUST be passed to endStage
    public static func beginStage(_ name: StaticString) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: id)
    }

    /// End a signposted interval
    public static func endStage(_ name: StaticString, state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    // MARK: - CGImage Validation

    /// Validate and log CGImage properties
    public static func validateCGImage(_ image: CGImage, stage: String, frameIndex: Int = 0) -> CGImageValidation {
        guard GIF81DebugFlags.enabled else { return CGImageValidation(isValid: true) }

        let validation = CGImageValidation(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: image.bytesPerRow,
            bitmapInfo: image.bitmapInfo,
            colorSpace: image.colorSpace,
            dataLength: (image.dataProvider?.data).map { CFDataGetLength($0) } ?? 0
        )

        if GIF81DebugFlags.logImageProperties {
            debugLogger.info("""
            ┌─────────────────────────────────────────────────────────────
            │ CGImage Validation: \(stage) [Frame \(frameIndex)]
            ├─────────────────────────────────────────────────────────────
            │ Dimensions:      \(validation.width) × \(validation.height)
            │ BitsPerComponent: \(validation.bitsPerComponent)
            │ BitsPerPixel:    \(validation.bitsPerPixel)
            │ BytesPerRow:     \(validation.bytesPerRow) (expected: \(validation.expectedBytesPerRow))
            │ BytesPerRow OK:  \(validation.bytesPerRowValid ? "✅" : "❌ MISMATCH")
            │ BitmapInfo:      \(validation.bitmapInfoDescription)
            │ Alpha Info:      \(validation.alphaInfoDescription)
            │ Byte Order:      \(validation.byteOrderDescription)
            │ Data Length:     \(validation.dataLength) bytes (expected: \(validation.expectedDataLength))
            │ Data Length OK:  \(validation.dataLengthValid ? "✅" : "❌ MISMATCH")
            │ ColorSpace:      \(validation.colorSpaceName)
            └─────────────────────────────────────────────────────────────
            """)
        }

        if GIF81DebugFlags.validateBytesPerRow && !validation.bytesPerRowValid {
            debugLogger.error("❌ BytesPerRow MISMATCH at \(stage): got \(validation.bytesPerRow), expected \(validation.expectedBytesPerRow)")
        }

        return validation
    }

    // MARK: - Pixel Hex Dump

    /// Dump sample pixels as hex for visual inspection
    public static func dumpPixelHex(_ image: CGImage, stage: String, frameIndex: Int = 0) {
        guard GIF81DebugFlags.enabled && GIF81DebugFlags.dumpPixelHex else { return }

        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            debugLogger.error("❌ Cannot access pixel data for hex dump at \(stage)")
            return
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        let dataLength = CFDataGetLength(pixelData)

        // Sample rows: first, middle, last
        let sampleRows = [0, height / 2, height - 1]
        let sampleCols = Array(stride(from: 0, to: width, by: max(1, width / GIF81DebugFlags.pixelSampleCount)))

        var hexDump = """
        ┌─────────────────────────────────────────────────────────────
        │ Pixel Hex Dump: \(stage) [Frame \(frameIndex)]
        │ Format: [offset] R G B A (assuming RGBA)
        ├─────────────────────────────────────────────────────────────
        """

        for row in sampleRows {
            hexDump += "\n│ Row \(row):"
            for col in sampleCols.prefix(GIF81DebugFlags.pixelSampleCount) {
                let offset = row * bytesPerRow + col * bytesPerPixel
                if offset + 3 < dataLength {
                    let r = data[offset]
                    let g = data[offset + 1]
                    let b = data[offset + 2]
                    let a = bytesPerPixel > 3 ? data[offset + 3] : 255
                    hexDump += String(format: " [%05d] %02X %02X %02X %02X", offset, r, g, b, a)
                } else {
                    hexDump += " [OUT OF BOUNDS]"
                }
            }
        }

        hexDump += "\n└─────────────────────────────────────────────────────────────"
        debugLogger.info("\(hexDump)")
    }

    // MARK: - Tensor Validation

    /// Log tensor statistics
    public static func logTensorStats(_ stats: TensorStatistics, cellColors: [(r: UInt8, g: UInt8, b: UInt8)]) {
        guard GIF81DebugFlags.enabled && GIF81DebugFlags.logTensorStats else { return }

        // Count unique colors
        var uniqueColors = Set<UInt32>()
        for color in cellColors {
            let packed = (UInt32(color.r) << 16) | (UInt32(color.g) << 8) | UInt32(color.b)
            uniqueColors.insert(packed)
        }

        // Sample some colors
        let sampleColors = cellColors.prefix(10).map { String(format: "(%d,%d,%d)", $0.r, $0.g, $0.b) }.joined(separator: " ")

        debugLogger.info("""
        ┌─────────────────────────────────────────────────────────────
        │ TensorCube729 Statistics
        ├─────────────────────────────────────────────────────────────
        │ Total Cells:     729 (9×9×9)
        │ Non-Zero Cells:  \(stats.nonZeroCells)
        │ Unique Colors:   \(uniqueColors.count)
        │ Total Weight:    \(String(format: "%.2f", stats.totalWeight))
        │ Average Weight:  \(String(format: "%.2f", stats.averageWeight))
        │ Min Weight:      \(String(format: "%.2f", stats.minWeight))
        │ Max Weight:      \(String(format: "%.2f", stats.maxWeight))
        │ Sample Colors:   \(sampleColors)
        └─────────────────────────────────────────────────────────────
        """)

        if stats.nonZeroCells == 0 {
            debugLogger.error("❌ CRITICAL: All tensor cells are ZERO - no pixel data was accumulated!")
        }

        if uniqueColors.count < 10 {
            debugLogger.warning("⚠️ WARNING: Only \(uniqueColors.count) unique colors in tensor - image may lack variety")
        }
    }

    // MARK: - Palette Validation

    /// Log palette colors
    public static func logPalette(_ palette: [UInt32]) {
        guard GIF81DebugFlags.enabled && GIF81DebugFlags.logPalette else { return }

        // Count unique and non-black colors
        let uniqueColors = Set(palette)
        let nonBlackColors = palette.filter { ($0 & 0x00FFFFFF) != 0 }

        // Sample first 16 colors
        let sampleColors = palette.prefix(16).map { color -> String in
            let r = (color >> 16) & 0xFF
            let g = (color >> 8) & 0xFF
            let b = color & 0xFF
            return String(format: "#%02X%02X%02X", r, g, b)
        }.joined(separator: " ")

        debugLogger.info("""
        ┌─────────────────────────────────────────────────────────────
        │ Palette Analysis
        ├─────────────────────────────────────────────────────────────
        │ Palette Size:    \(palette.count)
        │ Unique Colors:   \(uniqueColors.count)
        │ Non-Black:       \(nonBlackColors.count)
        │ First 16:        \(sampleColors)
        └─────────────────────────────────────────────────────────────
        """)

        if uniqueColors.count < 10 {
            debugLogger.error("❌ CRITICAL: Palette has only \(uniqueColors.count) unique colors!")
        }
    }

    // MARK: - Frame Indices Validation

    /// Validate frame indices distribution
    public static func validateFrameIndices(_ indices: [UInt8], frameIndex: Int, width: Int, height: Int) {
        guard GIF81DebugFlags.enabled else { return }

        let expectedCount = width * height
        var histogram = [UInt8: Int]()
        for idx in indices {
            histogram[idx, default: 0] += 1
        }

        let uniqueIndices = histogram.count
        let mostCommonIndex = histogram.max(by: { $0.value < $1.value })
        let mostCommonPercent = (mostCommonIndex?.value ?? 0) * 100 / max(1, indices.count)

        // Sample indices from different rows
        let firstRowIndices = Array(indices.prefix(min(10, width)))
        let middleStart = (height / 2) * width
        let middleRowIndices = Array(indices[middleStart..<min(middleStart + 10, indices.count)])
        let lastStart = max(0, (height - 1) * width)
        let lastRowIndices = Array(indices[lastStart..<min(lastStart + 10, indices.count)])

        debugLogger.info("""
        ┌─────────────────────────────────────────────────────────────
        │ Frame Indices Analysis [Frame \(frameIndex)]
        ├─────────────────────────────────────────────────────────────
        │ Index Count:     \(indices.count) (expected: \(expectedCount))
        │ Count Valid:     \(indices.count == expectedCount ? "✅" : "❌")
        │ Unique Indices:  \(uniqueIndices)
        │ Most Common:     Index \(mostCommonIndex?.key ?? 0) (\(mostCommonPercent)% of pixels)
        │ First Row[0-9]:  \(firstRowIndices.map { String($0) }.joined(separator: " "))
        │ Mid Row[0-9]:    \(middleRowIndices.map { String($0) }.joined(separator: " "))
        │ Last Row[0-9]:   \(lastRowIndices.map { String($0) }.joined(separator: " "))
        └─────────────────────────────────────────────────────────────
        """)

        if mostCommonPercent > 90 {
            debugLogger.error("❌ CRITICAL: \(mostCommonPercent)% of pixels use index \(mostCommonIndex?.key ?? 0) - likely data corruption!")
        }

        if uniqueIndices < 5 {
            debugLogger.warning("⚠️ WARNING: Only \(uniqueIndices) unique indices used in frame \(frameIndex)")
        }
    }

    // MARK: - LZW Validation

    /// Log LZW compression statistics
    public static func logLZWStats(_ compressedFrames: [[Data]], originalPixelCount: Int) {
        guard GIF81DebugFlags.enabled && GIF81DebugFlags.logLZWStats else { return }

        var totalCompressedBytes = 0
        var totalSubBlocks = 0
        var emptyFrames = 0

        for frameData in compressedFrames {
            let frameBytes = frameData.reduce(0) { $0 + $1.count }
            totalCompressedBytes += frameBytes
            totalSubBlocks += frameData.count
            if frameBytes == 0 {
                emptyFrames += 1
            }
        }

        let compressionRatio = Double(totalCompressedBytes) / Double(originalPixelCount * compressedFrames.count) * 100

        debugLogger.info("""
        ┌─────────────────────────────────────────────────────────────
        │ LZW Compression Statistics
        ├─────────────────────────────────────────────────────────────
        │ Total Frames:        \(compressedFrames.count)
        │ Total Sub-Blocks:    \(totalSubBlocks)
        │ Total Bytes:         \(totalCompressedBytes)
        │ Compression Ratio:   \(String(format: "%.1f", compressionRatio))%
        │ Empty Frames:        \(emptyFrames)
        │ Avg Bytes/Frame:     \(totalCompressedBytes / max(1, compressedFrames.count))
        └─────────────────────────────────────────────────────────────
        """)

        if emptyFrames > 0 {
            debugLogger.error("❌ CRITICAL: \(emptyFrames) frames have EMPTY LZW data!")
        }
    }

    // MARK: - GIF Structure Validation

    /// Validate final GIF structure against GIF89a spec
    public static func validateGIFStructure(_ gifData: Data) -> GIFValidation {
        guard GIF81DebugFlags.enabled && GIF81DebugFlags.validateGIFStructure else {
            return GIFValidation(isValid: true)
        }

        var validation = GIFValidation()
        let bytes = [UInt8](gifData)

        // Check minimum size
        guard bytes.count > 13 else {
            validation.errors.append("GIF too small: \(bytes.count) bytes")
            return validation
        }

        // Check header (GIF89a)
        let header = String(bytes: bytes[0..<6], encoding: .ascii) ?? ""
        validation.hasValidHeader = header == "GIF89a" || header == "GIF87a"
        if !validation.hasValidHeader {
            validation.errors.append("Invalid header: '\(header)'")
        }

        // Parse Logical Screen Descriptor
        let width = Int(bytes[6]) | (Int(bytes[7]) << 8)
        let height = Int(bytes[8]) | (Int(bytes[9]) << 8)
        let packed = bytes[10]
        let hasGlobalColorTable = (packed & 0x80) != 0
        let colorTableSize = 1 << ((packed & 0x07) + 1)

        validation.width = width
        validation.height = height
        validation.hasGlobalColorTable = hasGlobalColorTable
        validation.colorTableSize = colorTableSize

        // Check trailer
        validation.hasTrailer = bytes.last == 0x3B
        if !validation.hasTrailer {
            validation.errors.append("Missing trailer (0x3B)")
        }

        // Count frames (look for Image Separator 0x2C)
        var frameCount = 0
        var i = 13 + (hasGlobalColorTable ? colorTableSize * 3 : 0)
        while i < bytes.count - 1 {
            if bytes[i] == 0x2C {
                frameCount += 1
                // Skip past image descriptor and data
                i += 10
                if i < bytes.count {
                    let lzwMinCodeSize = bytes[i]
                    i += 1
                    // Skip sub-blocks
                    while i < bytes.count && bytes[i] != 0 {
                        let blockSize = Int(bytes[i])
                        i += 1 + blockSize
                    }
                    i += 1 // Skip block terminator
                }
            } else if bytes[i] == 0x21 {
                // Extension block
                i += 2
                if i < bytes.count {
                    while i < bytes.count && bytes[i] != 0 {
                        let blockSize = Int(bytes[i])
                        i += 1 + blockSize
                    }
                    i += 1
                }
            } else {
                i += 1
            }
        }
        validation.frameCount = frameCount

        validation.isValid = validation.hasValidHeader && validation.hasTrailer && frameCount > 0

        debugLogger.info("""
        ┌─────────────────────────────────────────────────────────────
        │ GIF Structure Validation
        ├─────────────────────────────────────────────────────────────
        │ Total Size:       \(gifData.count) bytes
        │ Header:           \(header) \(validation.hasValidHeader ? "✅" : "❌")
        │ Dimensions:       \(width) × \(height)
        │ Global Palette:   \(hasGlobalColorTable ? "Yes (\(colorTableSize) colors)" : "No")
        │ Frame Count:      \(frameCount)
        │ Has Trailer:      \(validation.hasTrailer ? "✅" : "❌")
        │ Overall:          \(validation.isValid ? "✅ VALID" : "❌ INVALID")
        │ Errors:           \(validation.errors.isEmpty ? "None" : validation.errors.joined(separator: ", "))
        └─────────────────────────────────────────────────────────────
        """)

        return validation
    }

    // MARK: - Summary Report

    /// Generate final summary report
    public static func generateReport(
        inputFrameCount: Int,
        resizedValidation: CGImageValidation?,
        tensorStats: TensorStatistics?,
        paletteSize: Int,
        compressedFrameCount: Int,
        gifValidation: GIFValidation?
    ) {
        guard GIF81DebugFlags.enabled else { return }

        let issues = collectIssues(
            resizedValidation: resizedValidation,
            tensorStats: tensorStats,
            gifValidation: gifValidation
        )

        debugLogger.info("""
        ╔═════════════════════════════════════════════════════════════
        ║  GIF81 PIPELINE SUMMARY REPORT
        ╠═════════════════════════════════════════════════════════════
        ║  Input Frames:     \(inputFrameCount)
        ║  Resized:          \(resizedValidation?.isValid == true ? "✅" : "❌")
        ║  Tensor Cells:     \(tensorStats?.nonZeroCells ?? 0) / 729
        ║  Palette Size:     \(paletteSize)
        ║  Compressed:       \(compressedFrameCount) frames
        ║  GIF Valid:        \(gifValidation?.isValid == true ? "✅" : "❌")
        ╠═════════════════════════════════════════════════════════════
        ║  ISSUES FOUND:     \(issues.count)
        \(issues.isEmpty ? "║  None - Pipeline completed successfully!" : issues.map { "║  • \($0)" }.joined(separator: "\n"))
        ╚═════════════════════════════════════════════════════════════
        """)
    }

    private static func collectIssues(
        resizedValidation: CGImageValidation?,
        tensorStats: TensorStatistics?,
        gifValidation: GIFValidation?
    ) -> [String] {
        var issues: [String] = []

        if let rv = resizedValidation {
            if !rv.bytesPerRowValid {
                issues.append("BytesPerRow mismatch: \(rv.bytesPerRow) vs expected \(rv.expectedBytesPerRow)")
            }
            if !rv.dataLengthValid {
                issues.append("Data length mismatch: \(rv.dataLength) vs expected \(rv.expectedDataLength)")
            }
        }

        if let ts = tensorStats {
            if ts.nonZeroCells == 0 {
                issues.append("All tensor cells are zero - no pixel data!")
            }
        }

        if let gv = gifValidation {
            issues.append(contentsOf: gv.errors)
        }

        return issues
    }
}

// MARK: - Validation Structures

@available(iOS 26.0, *)
public struct CGImageValidation {
    public var isValid: Bool = false
    public var width: Int = 0
    public var height: Int = 0
    public var bitsPerComponent: Int = 0
    public var bitsPerPixel: Int = 0
    public var bytesPerRow: Int = 0
    public var bitmapInfo: CGBitmapInfo = []
    public var colorSpace: CGColorSpace?
    public var dataLength: Int = 0

    public var expectedBytesPerRow: Int { width * (bitsPerPixel / 8) }
    public var expectedDataLength: Int { bytesPerRow * height }
    public var bytesPerRowValid: Bool { bytesPerRow == expectedBytesPerRow }
    public var dataLengthValid: Bool { dataLength >= expectedDataLength }

    public var alphaInfo: CGImageAlphaInfo {
        CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
    }

    public var byteOrder: CGBitmapInfo {
        CGBitmapInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
    }

    public var alphaInfoDescription: String {
        switch alphaInfo {
        case .none: return "None"
        case .premultipliedLast: return "PremultipliedLast (RGBA)"
        case .premultipliedFirst: return "PremultipliedFirst (ARGB)"
        case .last: return "Last (RGBA non-premultiplied)"
        case .first: return "First (ARGB non-premultiplied)"
        case .noneSkipLast: return "NoneSkipLast (RGBx)"
        case .noneSkipFirst: return "NoneSkipFirst (xRGB)"
        case .alphaOnly: return "AlphaOnly"
        @unknown default: return "Unknown"
        }
    }

    public var byteOrderDescription: String {
        if byteOrder.contains(.byteOrder32Big) { return "32Big (RGBA)" }
        if byteOrder.contains(.byteOrder32Little) { return "32Little (BGRA)" }
        if byteOrder.contains(.byteOrder16Big) { return "16Big" }
        if byteOrder.contains(.byteOrder16Little) { return "16Little" }
        return "Default"
    }

    public var bitmapInfoDescription: String {
        String(format: "0x%08X", bitmapInfo.rawValue)
    }

    public var colorSpaceName: String {
        colorSpace?.name as String? ?? "Unknown"
    }
}

@available(iOS 26.0, *)
public struct GIFValidation {
    public var isValid: Bool = false
    public var hasValidHeader: Bool = false
    public var hasTrailer: Bool = false
    public var hasGlobalColorTable: Bool = false
    public var width: Int = 0
    public var height: Int = 0
    public var colorTableSize: Int = 0
    public var frameCount: Int = 0
    public var errors: [String] = []
}
