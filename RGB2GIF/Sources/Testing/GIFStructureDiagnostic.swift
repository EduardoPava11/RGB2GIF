//
//  GIFStructureDiagnostic.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF STRUCTURE DIAGNOSTIC - FIND THE MALFORMATION                        ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  This test PARSES the actual GIF bytes and reports:                      ║
//  ║  - Header validity                                                        ║
//  ║  - Logical Screen Descriptor (width, height)                             ║
//  ║  - Global Color Table                                                     ║
//  ║  - Each frame's Image Descriptor (position, dimensions)                  ║
//  ║  - LZW sub-block sizes and pixel counts                                  ║
//  ║  - Trailer presence                                                       ║
//  ║                                                                           ║
//  ║  PURPOSE: NOT pass/fail, but INFORMATIVE DIAGNOSTICS                     ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import os.log

private let diagLogger = Logger(subsystem: "com.rgb2gif.tests", category: "GIFDiagnostic")

@available(iOS 26.0, *)
public struct GIFStructureDiagnostic {

    // MARK: - GIF Structure Components

    public struct GIFHeader {
        let signature: String  // Should be "GIF"
        let version: String    // Should be "89a" or "87a"
        let isValid: Bool
    }

    public struct LogicalScreenDescriptor {
        let width: UInt16
        let height: UInt16
        let packedByte: UInt8
        let hasGlobalColorTable: Bool
        let colorResolution: Int  // Bits per primary color - 1
        let sortFlag: Bool
        let globalColorTableSize: Int  // 2^(N+1) colors
        let backgroundColorIndex: UInt8
        let pixelAspectRatio: UInt8
    }

    public struct FrameDescriptor {
        let frameIndex: Int
        let leftPosition: UInt16
        let topPosition: UInt16
        let width: UInt16
        let height: UInt16
        let packedByte: UInt8
        let hasLocalColorTable: Bool
        let isInterlaced: Bool
        let lzwMinCodeSize: UInt8
        let subBlockCount: Int
        let totalLZWBytes: Int
        let decodedPixelCount: Int  // After LZW decode
    }

    public struct DiagnosticReport {
        let header: GIFHeader
        let screenDescriptor: LogicalScreenDescriptor
        let globalColorTableOffset: Int
        let globalColorTableSize: Int
        let frameDescriptors: [FrameDescriptor]
        let trailerOffset: Int
        let trailerPresent: Bool
        let totalFileSize: Int
        let issues: [String]
    }

    // MARK: - Main Diagnostic Entry Point

    /// Parse a GIF file and generate detailed diagnostic report
    public static func diagnose(gifData: Data) -> String {
        var output: [String] = []
        var issues: [String] = []

        output.append("╔═══════════════════════════════════════════════════════════════════════════════╗")
        output.append("║                    GIF STRUCTURE DIAGNOSTIC REPORT                            ║")
        output.append("╠═══════════════════════════════════════════════════════════════════════════════╣")
        output.append("║  Total File Size: \(gifData.count) bytes")
        output.append("╚═══════════════════════════════════════════════════════════════════════════════╝")
        output.append("")

        var offset = 0

        // ═══════════════════════════════════════════════════════════════════════
        // 1. HEADER (6 bytes)
        // ═══════════════════════════════════════════════════════════════════════
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("1. GIF HEADER (Bytes 0-5)")
        output.append("═══════════════════════════════════════════════════════════════════════════════")

        guard gifData.count >= 6 else {
            issues.append("CRITICAL: File too short for GIF header (\(gifData.count) bytes)")
            output.append("❌ CRITICAL: File too short!")
            return output.joined(separator: "\n")
        }

        let headerBytes = gifData[0..<6]
        let headerString = String(data: Data(headerBytes), encoding: .ascii) ?? "???"
        let signature = String(headerString.prefix(3))
        let version = String(headerString.suffix(3))

        output.append("  Raw bytes: \(headerBytes.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        output.append("  Signature: \(signature) \(signature == "GIF" ? "✓" : "❌ WRONG")")
        output.append("  Version:   \(version) \(version == "89a" || version == "87a" ? "✓" : "❌ WRONG")")

        if signature != "GIF" {
            issues.append("Header signature is '\(signature)', expected 'GIF'")
        }
        if version != "89a" && version != "87a" {
            issues.append("Header version is '\(version)', expected '89a' or '87a'")
        }

        offset = 6

        // ═══════════════════════════════════════════════════════════════════════
        // 2. LOGICAL SCREEN DESCRIPTOR (7 bytes)
        // ═══════════════════════════════════════════════════════════════════════
        output.append("")
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("2. LOGICAL SCREEN DESCRIPTOR (Bytes 6-12)")
        output.append("═══════════════════════════════════════════════════════════════════════════════")

        guard gifData.count >= 13 else {
            issues.append("CRITICAL: File too short for screen descriptor")
            output.append("❌ CRITICAL: File too short!")
            return output.joined(separator: "\n")
        }

        let width = UInt16(gifData[6]) | (UInt16(gifData[7]) << 8)
        let height = UInt16(gifData[8]) | (UInt16(gifData[9]) << 8)
        let packed = gifData[10]
        let bgColor = gifData[11]
        let aspectRatio = gifData[12]

        let hasGCT = (packed & 0x80) != 0
        let colorRes = ((packed >> 4) & 0x07) + 1
        let sortFlag = (packed & 0x08) != 0
        let gctSizeBits = packed & 0x07
        let gctColorCount = hasGCT ? (1 << (gctSizeBits + 1)) : 0

        output.append("  Raw bytes: \(gifData[6..<13].map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        output.append("  Width:     \(width) pixels \(width == 81 ? "✓" : "⚠️ EXPECTED 81")")
        output.append("  Height:    \(height) pixels \(height == 81 ? "✓" : "⚠️ EXPECTED 81")")
        output.append("  Packed:    0x\(String(format: "%02X", packed))")
        output.append("    - Global Color Table: \(hasGCT ? "YES" : "NO")")
        output.append("    - Color Resolution:   \(colorRes) bits per primary")
        output.append("    - Sort Flag:          \(sortFlag)")
        output.append("    - GCT Size:           \(gctColorCount) colors (2^(\(gctSizeBits)+1))")
        output.append("  Background: Index \(bgColor)")
        output.append("  Aspect:    \(aspectRatio)")

        if width != 81 {
            issues.append("Screen width is \(width), expected 81")
        }
        if height != 81 {
            issues.append("Screen height is \(height), expected 81")
        }
        if !hasGCT {
            issues.append("No Global Color Table present")
        }
        if gctColorCount != 256 {
            issues.append("GCT has \(gctColorCount) colors, expected 256")
        }

        offset = 13

        // ═══════════════════════════════════════════════════════════════════════
        // 3. GLOBAL COLOR TABLE
        // ═══════════════════════════════════════════════════════════════════════
        output.append("")
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("3. GLOBAL COLOR TABLE (Bytes 13-\(12 + gctColorCount * 3))")
        output.append("═══════════════════════════════════════════════════════════════════════════════")

        if hasGCT {
            let gctSize = gctColorCount * 3
            guard gifData.count >= offset + gctSize else {
                issues.append("CRITICAL: File too short for GCT")
                output.append("❌ CRITICAL: File too short for color table!")
                return output.joined(separator: "\n")
            }

            output.append("  Size:      \(gctSize) bytes (\(gctColorCount) colors × 3)")

            // Sample some colors
            output.append("  Sample colors (index: R,G,B):")
            for i in [0, 1, 127, 128, 254, 255] {
                if i < gctColorCount {
                    let r = gifData[offset + i * 3]
                    let g = gifData[offset + i * 3 + 1]
                    let b = gifData[offset + i * 3 + 2]
                    output.append("    [\(String(format: "%3d", i))]: (\(String(format: "%3d", r)), \(String(format: "%3d", g)), \(String(format: "%3d", b)))")
                }
            }

            offset += gctSize
        } else {
            output.append("  ⚠️ No Global Color Table")
        }

        // ═══════════════════════════════════════════════════════════════════════
        // 4. PARSE BLOCKS (Extensions, Frames, Trailer)
        // ═══════════════════════════════════════════════════════════════════════
        output.append("")
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("4. BLOCK PARSING")
        output.append("═══════════════════════════════════════════════════════════════════════════════")

        var frameCount = 0
        var frameDescriptors: [FrameDescriptor] = []
        var trailerFound = false

        while offset < gifData.count {
            let blockType = gifData[offset]

            switch blockType {
            case 0x21:  // Extension
                offset += 1
                guard offset < gifData.count else { break }
                let extLabel = gifData[offset]
                offset += 1

                switch extLabel {
                case 0xF9:  // Graphic Control
                    output.append("  [Offset \(offset-2)] Extension: Graphic Control (0x21 0xF9)")
                    if offset + 5 <= gifData.count {
                        let blockSize = gifData[offset]
                        let packed = gifData[offset + 1]
                        let delay = UInt16(gifData[offset + 2]) | (UInt16(gifData[offset + 3]) << 8)
                        let transIndex = gifData[offset + 4]
                        output.append("    Block size: \(blockSize), Delay: \(delay) centisecs, Trans: \(transIndex)")
                        offset += Int(blockSize) + 2  // +1 for size byte, +1 for terminator
                    }

                case 0xFF:  // Application Extension
                    output.append("  [Offset \(offset-2)] Extension: Application (0x21 0xFF)")
                    if offset + 12 <= gifData.count {
                        let blockSize = gifData[offset]
                        let appName = String(data: Data(gifData[offset+1..<offset+12]), encoding: .ascii) ?? "???"
                        output.append("    Block size: \(blockSize), App: \(appName)")
                        offset += Int(blockSize) + 1
                        // Skip sub-blocks
                        while offset < gifData.count && gifData[offset] != 0 {
                            let subSize = Int(gifData[offset])
                            offset += subSize + 1
                        }
                        offset += 1  // Skip terminator
                    }

                case 0xFE:  // Comment
                    output.append("  [Offset \(offset-2)] Extension: Comment (0x21 0xFE)")
                    // Skip sub-blocks
                    while offset < gifData.count && gifData[offset] != 0 {
                        let subSize = Int(gifData[offset])
                        offset += subSize + 1
                    }
                    offset += 1

                default:
                    output.append("  [Offset \(offset-2)] Extension: Unknown (0x21 0x\(String(format: "%02X", extLabel)))")
                    // Skip sub-blocks
                    while offset < gifData.count && gifData[offset] != 0 {
                        let subSize = Int(gifData[offset])
                        offset += subSize + 1
                    }
                    offset += 1
                }

            case 0x2C:  // Image Descriptor
                let imgStart = offset
                offset += 1

                guard offset + 9 <= gifData.count else {
                    issues.append("CRITICAL: File too short for image descriptor at frame \(frameCount)")
                    break
                }

                let imgLeft = UInt16(gifData[offset]) | (UInt16(gifData[offset + 1]) << 8)
                let imgTop = UInt16(gifData[offset + 2]) | (UInt16(gifData[offset + 3]) << 8)
                let imgWidth = UInt16(gifData[offset + 4]) | (UInt16(gifData[offset + 5]) << 8)
                let imgHeight = UInt16(gifData[offset + 6]) | (UInt16(gifData[offset + 7]) << 8)
                let imgPacked = gifData[offset + 8]
                offset += 9

                let hasLCT = (imgPacked & 0x80) != 0
                let isInterlaced = (imgPacked & 0x40) != 0

                // Skip local color table if present
                if hasLCT {
                    let lctSizeBits = imgPacked & 0x07
                    let lctSize = (1 << (lctSizeBits + 1)) * 3
                    offset += lctSize
                }

                // LZW Minimum Code Size
                guard offset < gifData.count else { break }
                let lzwMinCodeSize = gifData[offset]
                offset += 1

                // Count LZW sub-blocks and decode pixel count
                var subBlockCount = 0
                var totalLZWBytes = 0
                var lzwData = Data()

                while offset < gifData.count && gifData[offset] != 0 {
                    let subSize = Int(gifData[offset])
                    offset += 1

                    if subSize > 0 && offset + subSize <= gifData.count {
                        lzwData.append(contentsOf: gifData[offset..<offset + subSize])
                        totalLZWBytes += subSize
                        subBlockCount += 1
                        offset += subSize
                    } else {
                        break
                    }
                }
                offset += 1  // Skip terminator

                // Decode LZW to count pixels
                let decodedPixelCount = decodeLZWPixelCount(lzwData, minCodeSize: Int(lzwMinCodeSize))
                let expectedPixels = Int(imgWidth) * Int(imgHeight)

                // Report frame info
                let isFirstFrame = frameCount == 0
                let isLastFrame = frameCount == 80
                let isMidFrame = frameCount == 40

                if isFirstFrame || isLastFrame || isMidFrame || decodedPixelCount != expectedPixels {
                    output.append("")
                    output.append("  ┌─────────────────────────────────────────────────────────────────────────────┐")
                    output.append("  │ FRAME \(frameCount) [Offset \(imgStart)]")
                    output.append("  ├─────────────────────────────────────────────────────────────────────────────┤")
                    output.append("  │ Position:    (\(imgLeft), \(imgTop)) \(imgLeft == 0 && imgTop == 0 ? "✓" : "⚠️")")
                    output.append("  │ Dimensions:  \(imgWidth) × \(imgHeight) \(imgWidth == width && imgHeight == height ? "✓" : "❌ MISMATCH")")
                    output.append("  │ Interlaced:  \(isInterlaced ? "YES" : "NO")")
                    output.append("  │ Local CT:    \(hasLCT ? "YES" : "NO")")
                    output.append("  │ LZW MinCode: \(lzwMinCodeSize) \(lzwMinCodeSize == 8 ? "✓" : "⚠️")")
                    output.append("  │ Sub-blocks:  \(subBlockCount)")
                    output.append("  │ LZW bytes:   \(totalLZWBytes)")
                    output.append("  │ Decoded px:  \(decodedPixelCount) \(decodedPixelCount == expectedPixels ? "✓" : "❌ EXPECTED \(expectedPixels)")")
                    output.append("  └─────────────────────────────────────────────────────────────────────────────┘")

                    if imgWidth != width || imgHeight != height {
                        issues.append("Frame \(frameCount) dimensions (\(imgWidth)×\(imgHeight)) don't match screen (\(width)×\(height))")
                    }
                    if decodedPixelCount != expectedPixels {
                        issues.append("Frame \(frameCount) decoded \(decodedPixelCount) pixels, expected \(expectedPixels)")
                    }
                }

                let descriptor = FrameDescriptor(
                    frameIndex: frameCount,
                    leftPosition: imgLeft,
                    topPosition: imgTop,
                    width: imgWidth,
                    height: imgHeight,
                    packedByte: imgPacked,
                    hasLocalColorTable: hasLCT,
                    isInterlaced: isInterlaced,
                    lzwMinCodeSize: lzwMinCodeSize,
                    subBlockCount: subBlockCount,
                    totalLZWBytes: totalLZWBytes,
                    decodedPixelCount: decodedPixelCount
                )
                frameDescriptors.append(descriptor)
                frameCount += 1

            case 0x3B:  // Trailer
                output.append("")
                output.append("  [Offset \(offset)] TRAILER (0x3B) ✓")
                trailerFound = true
                offset += 1

            default:
                output.append("  [Offset \(offset)] UNKNOWN BLOCK: 0x\(String(format: "%02X", blockType))")
                issues.append("Unknown block type 0x\(String(format: "%02X", blockType)) at offset \(offset)")
                offset += 1
            }
        }

        // ═══════════════════════════════════════════════════════════════════════
        // 5. SUMMARY
        // ═══════════════════════════════════════════════════════════════════════
        output.append("")
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("5. DIAGNOSTIC SUMMARY")
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("  Total frames:    \(frameCount) \(frameCount == 81 ? "✓" : "⚠️ EXPECTED 81")")
        output.append("  Trailer found:   \(trailerFound ? "YES ✓" : "NO ❌")")
        output.append("  Screen size:     \(width) × \(height)")

        // Check frame dimension consistency
        var dimensionIssues = 0
        for frame in frameDescriptors {
            if frame.width != width || frame.height != height {
                dimensionIssues += 1
            }
        }
        output.append("  Frame dim issues: \(dimensionIssues) frames with wrong dimensions")

        // Check pixel count consistency
        var pixelIssues = 0
        for frame in frameDescriptors {
            let expected = Int(frame.width) * Int(frame.height)
            if frame.decodedPixelCount != expected {
                pixelIssues += 1
            }
        }
        output.append("  Pixel count issues: \(pixelIssues) frames with wrong pixel count")

        if frameCount != 81 {
            issues.append("Frame count is \(frameCount), expected 81")
        }
        if !trailerFound {
            issues.append("No trailer (0x3B) found at end of file")
        }

        // ═══════════════════════════════════════════════════════════════════════
        // 6. ISSUES LIST
        // ═══════════════════════════════════════════════════════════════════════
        output.append("")
        output.append("═══════════════════════════════════════════════════════════════════════════════")
        output.append("6. ISSUES FOUND (\(issues.count) total)")
        output.append("═══════════════════════════════════════════════════════════════════════════════")

        if issues.isEmpty {
            output.append("  ✓ No structural issues detected")
            output.append("  ⚠️ If GIF still looks wrong, issue may be in pixel data/colors")
        } else {
            for (i, issue) in issues.enumerated() {
                output.append("  \(i + 1). ❌ \(issue)")
            }
        }

        return output.joined(separator: "\n")
    }

    // MARK: - LZW Decoder (for pixel count verification)

    /// Decode LZW stream and count pixels produced
    /// This is a simplified decoder just for counting, not full decode
    private static func decodeLZWPixelCount(_ data: Data, minCodeSize: Int) -> Int {
        guard data.count > 0 else { return 0 }

        let clearCode = 1 << minCodeSize
        let eoiCode = clearCode + 1

        var codeSize = minCodeSize + 1
        var nextCode = eoiCode + 1
        var maxCode = (1 << codeSize) - 1

        var bitBuffer: UInt32 = 0
        var bitsInBuffer = 0
        var byteIndex = 0
        var pixelCount = 0

        // Table to track string lengths
        var stringLength = [Int](repeating: 0, count: 4096)
        for i in 0..<clearCode {
            stringLength[i] = 1
        }

        var prevCode = -1

        while byteIndex < data.count || bitsInBuffer >= codeSize {
            // Load more bytes
            while bitsInBuffer < codeSize && byteIndex < data.count {
                bitBuffer |= UInt32(data[byteIndex]) << bitsInBuffer
                bitsInBuffer += 8
                byteIndex += 1
            }

            guard bitsInBuffer >= codeSize else { break }

            // Extract code
            let code = Int(bitBuffer) & maxCode
            bitBuffer >>= codeSize
            bitsInBuffer -= codeSize

            if code == clearCode {
                // Reset
                codeSize = minCodeSize + 1
                maxCode = (1 << codeSize) - 1
                nextCode = eoiCode + 1
                prevCode = -1
                continue
            }

            if code == eoiCode {
                break
            }

            // Count pixels for this code
            if code < nextCode {
                pixelCount += stringLength[code]
            } else if code == nextCode && prevCode >= 0 {
                // Special case: code = nextCode
                pixelCount += stringLength[prevCode] + 1
            }

            // Add new code to table
            if prevCode >= 0 && nextCode < 4096 {
                if code < nextCode {
                    stringLength[nextCode] = stringLength[prevCode] + 1
                } else {
                    stringLength[nextCode] = stringLength[prevCode] + 1
                }
                nextCode += 1

                // Increase code size if needed
                if nextCode > maxCode && codeSize < 12 {
                    codeSize += 1
                    maxCode = (1 << codeSize) - 1
                }
            }

            prevCode = code
        }

        return pixelCount
    }

    // MARK: - Quick Diagnostic

    /// Run diagnostic on session's GIF output
    public static func diagnoseSession(_ session: CBORSessionManager) -> String {
        let gifURL = session.gifOutputURL

        guard FileManager.default.fileExists(atPath: gifURL.path) else {
            return "❌ No GIF file found at: \(gifURL.path)"
        }

        guard let gifData = try? Data(contentsOf: gifURL) else {
            return "❌ Failed to read GIF file"
        }

        return diagnose(gifData: gifData)
    }
}
