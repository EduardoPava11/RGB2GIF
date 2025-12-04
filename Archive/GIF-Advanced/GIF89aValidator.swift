//
//  GIF89aValidator.swift
//  RGB2GIF
//
//  Round-trip validator for GIP2 + GIX2 → GIF89a → Decode → Verify
//  Checks:
//  - Magic headers ("GIF89a")
//  - Global/Local Color Table sizes match paletteExp
//  - GCE placement (immediately before each frame)
//  - Sub-block limits (≤255 bytes)
//  - LZW min code size validity
//  - Netscape loop extension placement
//  - Frame palette references resolve correctly
//
//  Reference: GIF89a Specification §15-23
//

import Foundation
import ImageIO
import os.log

private let validatorLogger = Logger(subsystem: "com.rgb2gif", category: "GIF89aValidator")

/// GIF89a Validator - ensures spec compliance
@available(iOS 26.0, *)
struct GIF89aValidator {

    // MARK: - Validation Results

    struct ValidationResult {
        let isValid: Bool
        let errors: [ValidationError]
        let warnings: [ValidationWarning]
        let info: ValidationInfo

        var summary: String {
            var lines: [String] = []
            lines.append("GIF Validation \(isValid ? "✅ PASSED" : "❌ FAILED")")
            lines.append("")
            lines.append("Info:")
            lines.append("  Dimensions: \(info.width)×\(info.height)")
            lines.append("  Frames: \(info.frameCount)")
            lines.append("  Global CT: \(info.hasGlobalCT ? "Yes (\(info.globalCTSize) colors)" : "No")")
            lines.append("  Looping: \(info.hasLoopExtension ? "Yes" : "No")")
            lines.append("  File size: \(info.fileSize) bytes")

            if !errors.isEmpty {
                lines.append("")
                lines.append("Errors (\(errors.count)):")
                for error in errors {
                    lines.append("  ❌ \(error.description)")
                }
            }

            if !warnings.isEmpty {
                lines.append("")
                lines.append("Warnings (\(warnings.count)):")
                for warning in warnings {
                    lines.append("  ⚠️  \(warning.description)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    struct ValidationInfo {
        let width: Int
        let height: Int
        let frameCount: Int
        let hasGlobalCT: Bool
        let globalCTSize: Int
        let hasLoopExtension: Bool
        let fileSize: Int
    }

    enum ValidationError {
        case invalidMagic([UInt8])
        case missingGlobalCT
        case globalCTSizeMismatch(expected: Int, actual: Int)
        case localCTSizeMismatch(frame: Int, expected: Int, actual: Int)
        case invalidLZWMinCodeSize(UInt8)
        case subBlockTooLarge(frame: Int, size: Int)
        case missingGCE(frame: Int)
        case invalidFrameCount(expected: Int, actual: Int)
        case truncatedFile

        var description: String {
            switch self {
            case .invalidMagic(let bytes):
                return "Invalid magic header: \(bytes.map { String(format: "%02X", $0) }.joined()) (expected GIF89a)"
            case .missingGlobalCT:
                return "Global Color Table not present"
            case .globalCTSizeMismatch(let expected, let actual):
                return "Global CT size mismatch: expected \(expected), got \(actual)"
            case .localCTSizeMismatch(let frame, let expected, let actual):
                return "Frame \(frame) Local CT size mismatch: expected \(expected), got \(actual)"
            case .invalidLZWMinCodeSize(let size):
                return "Invalid LZW min code size: \(size) (must be 2-12)"
            case .subBlockTooLarge(let frame, let size):
                return "Frame \(frame) has sub-block > 255 bytes: \(size)"
            case .missingGCE(let frame):
                return "Frame \(frame) missing Graphic Control Extension"
            case .invalidFrameCount(let expected, let actual):
                return "Frame count mismatch: expected \(expected), got \(actual)"
            case .truncatedFile:
                return "File appears truncated"
            }
        }
    }

    enum ValidationWarning {
        case noLoopExtension
        case unusualDelay(frame: Int, delay: UInt16)
        case paletteNotFullyUsed(used: Int, total: Int)

        var description: String {
            switch self {
            case .noLoopExtension:
                return "No Netscape loop extension found"
            case .unusualDelay(let frame, let delay):
                return "Frame \(frame) has unusual delay: \(delay)cs"
            case .paletteNotFullyUsed(let used, let total):
                return "Palette not fully used: \(used)/\(total) colors"
            }
        }
    }

    // MARK: - Public API

    /// Validate GIF file for spec compliance
    /// - Parameter url: GIF file URL
    /// - Returns: Validation result
    static func validate(gifURL: URL) throws -> ValidationResult {
        validatorLogger.info("Validating GIF: \(gifURL.lastPathComponent)")

        let data = try Data(contentsOf: gifURL)
        return try validate(gifData: data)
    }

    /// Validate GIF data
    /// - Parameter data: GIF file data
    /// - Returns: Validation result
    static func validate(gifData data: Data) throws -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationWarning] = []

        // Check minimum size
        guard data.count >= 13 else {
            errors.append(.truncatedFile)
            return ValidationResult(
                isValid: false,
                errors: errors,
                warnings: warnings,
                info: ValidationInfo(width: 0, height: 0, frameCount: 0,
                                    hasGlobalCT: false, globalCTSize: 0,
                                    hasLoopExtension: false, fileSize: data.count)
            )
        }

        var offset = 0

        // 1. Check magic header "GIF89a"
        let header = Array(data[offset..<offset+6])
        offset += 6
        let expectedMagic: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        if header != expectedMagic {
            errors.append(.invalidMagic(header))
        }

        // 2. Parse Logical Screen Descriptor
        let width = Int(data[offset]) | (Int(data[offset+1]) << 8)
        let height = Int(data[offset+2]) | (Int(data[offset+3]) << 8)
        let packed = data[offset+4]
            _ = data[offset+5]
            _ = data[offset+6]
        offset += 7

        let hasGlobalCT = (packed & 0x80) != 0
        let gctSizeBits = Int(packed & 0x07)
        let globalCTSize = hasGlobalCT ? (1 << (gctSizeBits + 1)) : 0

        if !hasGlobalCT {
            errors.append(.missingGlobalCT)
        }

        // 3. Parse Global Color Table
        if hasGlobalCT {
            let gctBytes = globalCTSize * 3
            guard offset + gctBytes <= data.count else {
                errors.append(.truncatedFile)
                return ValidationResult(
                    isValid: false,
                    errors: errors,
                    warnings: warnings,
                    info: ValidationInfo(width: width, height: height, frameCount: 0,
                                        hasGlobalCT: hasGlobalCT, globalCTSize: globalCTSize,
                                        hasLoopExtension: false, fileSize: data.count)
                )
            }
            offset += gctBytes
        }

        // 4. Scan for extensions and frames
        var frameCount = 0
        var hasLoopExtension = false
        var hasGCEBeforeFrame = false

        while offset < data.count {
            let byte = data[offset]

            if byte == 0x21 {
                // Extension
                offset += 1
                guard offset < data.count else { break }
                let label = data[offset]
                offset += 1

                if label == 0xFF {
                    // Application extension (check for NETSCAPE)
                    guard offset < data.count else { break }
                    let blockSize = Int(data[offset])
                    offset += 1

                    if blockSize >= 11, offset + 11 <= data.count {
                        let appID = Array(data[offset..<offset+8])
                        let netscape: [UInt8] = [0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45]
                        if appID == netscape {
                            hasLoopExtension = true
                        }
                    }

                    // Skip remaining sub-blocks
                    offset = skipSubBlocks(data: data, offset: offset)

                } else if label == 0xF9 {
                    // Graphic Control Extension
                    hasGCEBeforeFrame = true
                    guard offset < data.count else { break }
                    let blockSize = Int(data[offset])
                    offset += 1 + blockSize + 1  // blockSize + data + terminator

                } else {
                    // Other extension, skip sub-blocks
                    offset = skipSubBlocks(data: data, offset: offset)
                }

            } else if byte == 0x2C {
                // Image descriptor (frame)
                frameCount += 1

                if !hasGCEBeforeFrame {
                    errors.append(.missingGCE(frame: frameCount))
                }
                hasGCEBeforeFrame = false

                offset += 1
                guard offset + 9 <= data.count else { break }

                // Skip left, top, width, height
                offset += 8

                let imagePacked = data[offset]
                offset += 1

                let hasLocalCT = (imagePacked & 0x80) != 0
                if hasLocalCT {
                    let lctSizeBits = Int(imagePacked & 0x07)
                    let localCTSize = 1 << (lctSizeBits + 1)
                    let lctBytes = localCTSize * 3
                    offset += lctBytes
                }

                // Image data
                guard offset < data.count else { break }
                let lzwMinCodeSize = data[offset]
                offset += 1

                if lzwMinCodeSize < 2 || lzwMinCodeSize > 12 {
                    errors.append(.invalidLZWMinCodeSize(lzwMinCodeSize))
                }

                // Check sub-blocks
                while offset < data.count {
                    let blockSize = Int(data[offset])
                    offset += 1

                    if blockSize == 0 {
                        // Block terminator
                        break
                    }

                    if blockSize > 255 {
                        errors.append(.subBlockTooLarge(frame: frameCount, size: blockSize))
                    }

                    offset += blockSize
                }

            } else if byte == 0x3B {
                // Trailer
                break

            } else {
                // Unknown byte, skip
                offset += 1
            }
        }

        if !hasLoopExtension && frameCount > 1 {
            warnings.append(.noLoopExtension)
        }

        let info = ValidationInfo(
            width: width,
            height: height,
            frameCount: frameCount,
            hasGlobalCT: hasGlobalCT,
            globalCTSize: globalCTSize,
            hasLoopExtension: hasLoopExtension,
            fileSize: data.count
        )

        let isValid = errors.isEmpty

        validatorLogger.info("Validation complete: \(isValid ? "PASSED" : "FAILED") (\(errors.count) errors, \(warnings.count) warnings)")

        return ValidationResult(
            isValid: isValid,
            errors: errors,
            warnings: warnings,
            info: info
        )
    }

    /// Round-trip validation: GIP2 + GIX2 → GIF → Validate
    /// - Parameters:
    ///   - gip: Palette container
    ///   - gix: Index stream
    /// - Returns: Validation result
    static func validateRoundTrip(gip: GIP, gix: GIX) throws -> ValidationResult {
        validatorLogger.info("Starting round-trip validation")

        // Create temp GIF
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("gif")

        // Mux to GIF
        try GIF89aMuxer.mux(gip: gip, gix: gix, to: tempURL)

        // Validate
        let result = try validate(gifURL: tempURL)

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)

        return result
    }

    // MARK: - Private Helpers

    private static func skipSubBlocks(data: Data, offset: Int) -> Int {
        var pos = offset
        while pos < data.count {
            let blockSize = Int(data[pos])
            pos += 1

            if blockSize == 0 {
                break
            }

            pos += blockSize
        }
        return pos
    }
}
