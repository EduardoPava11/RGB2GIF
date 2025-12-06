//
//  GIFWriter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF89a BYTE ASSEMBLY                                                     ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Pure byte-level GIF89a format writing:                                   ║
//  ║  • Header (GIF89a)                                                        ║
//  ║  • Logical Screen Descriptor                                              ║
//  ║  • Global Color Table (256 colors)                                        ║
//  ║  • NETSCAPE2.0 Loop Extension                                             ║
//  ║  • Frame Image Descriptors + LZW Data                                     ║
//  ║  • Trailer                                                                ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import os.log

private let gifLogger = Logger(subsystem: "com.rgb2gif", category: "GIFWriter")

// MARK: - GIFWriter

/// Assembles GIF89a format from palette and compressed frame data
@available(iOS 26.0, *)
public struct GIFWriter {

    // MARK: - Configuration

    public struct Config: Sendable {
        /// Frame width (default 81)
        public var width: UInt16 = 81
        /// Frame height (default 81)
        public var height: UInt16 = 81
        /// Delay between frames in centiseconds (default 3 = ~33fps)
        public var frameDelay: UInt16 = 3
        /// Number of loops (0 = infinite)
        public var loopCount: UInt16 = 0

        public init() {}
    }

    // MARK: - Public API

    /// Write complete GIF89a to Data
    /// - Parameters:
    ///   - palette: 256-color palette (ARGB format)
    ///   - compressedFrames: LZW-compressed data for each frame
    ///   - config: GIF configuration
    /// - Returns: Complete GIF89a data
    public static func write(
        palette: [UInt32],
        compressedFrames: [[Data]],
        config: Config = Config()
    ) throws -> Data {
        // MVP0 VERIFICATION: Dimensions must be 81×81
        precondition(config.width == 81 && config.height == 81, "MVP0: GIF dimensions must be 81×81, got \(config.width)×\(config.height)")
        // MVP0 VERIFICATION: Palette must have exactly 256 colors (MVP0 strict requirement)
        precondition(palette.count == 256, "MVP0: Palette must have exactly 256 colors, got \(palette.count)")
        // MVP0 VERIFICATION: Must have exactly 81 compressed frames
        precondition(compressedFrames.count == 81, "MVP0: GIF must have exactly 81 frames, got \(compressedFrames.count)")

        var output = Data()
        output.reserveCapacity(1024 * 100)  // ~100KB initial

        gifLogger.info("Writing GIF: \(config.width)×\(config.height), \(compressedFrames.count) frames")

        // Header
        writeHeader(&output)

        // Logical Screen Descriptor
        writeScreenDescriptor(&output, width: config.width, height: config.height)

        // Global Color Table (256 colors)
        writeColorTable(&output, palette: palette)

        // NETSCAPE2.0 Loop Extension
        writeLoopExtension(&output, loopCount: config.loopCount)

        // Write each frame
        for (index, frameData) in compressedFrames.enumerated() {
            writeFrame(&output, compressedData: frameData, delay: config.frameDelay, width: config.width, height: config.height, index: index)
        }

        // Trailer
        writeTrailer(&output)

        gifLogger.info("GIF written: \(output.count) bytes")
        return output
    }

    // MARK: - Private Implementation

    /// GIF89a header
    private static func writeHeader(_ output: inout Data) {
        output.append(contentsOf: "GIF89a".utf8)
    }

    /// Logical Screen Descriptor (7 bytes)
    private static func writeScreenDescriptor(_ output: inout Data, width: UInt16, height: UInt16) {
        // Width (little-endian)
        output.append(UInt8(width & 0xFF))
        output.append(UInt8((width >> 8) & 0xFF))

        // Height (little-endian)
        output.append(UInt8(height & 0xFF))
        output.append(UInt8((height >> 8) & 0xFF))

        // Packed byte:
        // - Global Color Table Flag: 1
        // - Color Resolution: 7 (8 bits per primary color)
        // - Sort Flag: 0
        // - Size of Global Color Table: 7 (2^(7+1) = 256 colors)
        output.append(0b11110111)  // 0xF7

        // Background Color Index
        output.append(0)

        // Pixel Aspect Ratio (0 = not specified)
        output.append(0)
    }

    /// Global Color Table (256 × 3 = 768 bytes)
    private static func writeColorTable(_ output: inout Data, palette: [UInt32]) {
        for i in 0..<256 {
            if i < palette.count {
                let color = palette[i]
                output.append(UInt8((color >> 16) & 0xFF))  // R
                output.append(UInt8((color >> 8) & 0xFF))   // G
                output.append(UInt8(color & 0xFF))          // B
            } else {
                output.append(contentsOf: [0, 0, 0])
            }
        }
    }

    /// NETSCAPE2.0 Application Extension (for looping)
    private static func writeLoopExtension(_ output: inout Data, loopCount: UInt16) {
        output.append(0x21)  // Extension Introducer
        output.append(0xFF)  // Application Extension Label
        output.append(0x0B)  // Block Size (11 bytes)
        output.append(contentsOf: "NETSCAPE2.0".utf8)
        output.append(0x03)  // Sub-block Size
        output.append(0x01)  // Sub-block ID
        output.append(UInt8(loopCount & 0xFF))        // Loop count (little-endian)
        output.append(UInt8((loopCount >> 8) & 0xFF))
        output.append(0x00)  // Block Terminator
    }

    /// Write a single frame
    private static func writeFrame(
        _ output: inout Data,
        compressedData: [Data],
        delay: UInt16,
        width: UInt16,
        height: UInt16,
        index: Int
    ) {
        // Graphic Control Extension
        output.append(0x21)  // Extension Introducer
        output.append(0xF9)  // Graphic Control Label
        output.append(0x04)  // Block Size
        output.append(0x00)  // Packed byte (no transparency, no disposal)
        output.append(UInt8(delay & 0xFF))        // Delay (little-endian)
        output.append(UInt8((delay >> 8) & 0xFF))
        output.append(0x00)  // Transparent Color Index (not used)
        output.append(0x00)  // Block Terminator

        // Image Descriptor
        output.append(0x2C)  // Image Separator
        output.append(0x00)  // Left Position (0) - little-endian
        output.append(0x00)
        output.append(0x00)  // Top Position (0) - little-endian
        output.append(0x00)
        output.append(UInt8(width & 0xFF))         // Width - little-endian
        output.append(UInt8((width >> 8) & 0xFF))
        output.append(UInt8(height & 0xFF))        // Height - little-endian
        output.append(UInt8((height >> 8) & 0xFF))
        output.append(0x00)  // Packed byte (no local color table)

        // LZW Minimum Code Size
        output.append(0x08)

        // LZW Compressed Data (sub-blocks)
        var totalLZWBytes = 0
        var subBlockCount = 0
        for subBlock in compressedData {
            if subBlock.count > 0 && subBlock.count <= 255 {
                output.append(UInt8(subBlock.count))
                output.append(subBlock)
                totalLZWBytes += subBlock.count
                subBlockCount += 1
            }
        }

        // Log frame LZW stats (first frame only to avoid spam)
        if index == 0 {
            gifLogger.debug("📊 Frame 0 LZW: \(subBlockCount) sub-blocks, \(totalLZWBytes) bytes")
        }

        // Block Terminator
        output.append(0x00)
    }

    /// GIF Trailer
    private static func writeTrailer(_ output: inout Data) {
        output.append(0x3B)
    }
}
