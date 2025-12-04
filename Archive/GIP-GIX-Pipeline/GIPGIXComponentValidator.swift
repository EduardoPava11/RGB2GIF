//
//  GIPGIXComponentValidator.swift
//  RGB2GIF
//
//  Validates GIP (palette) and GIX (structure) components before GIF89a muxing
//  Ensures color palette and index structure are correctly formed for playback
//
//  Two-component validation:
//  1. GIP (Global Image Palette) - Color palette for GIF
//  2. GIX (Global Image Index) - Structure/indices/everything else
//

import Foundation
import os.log

@available(iOS 26.0, *)
public struct GIPGIXComponentValidator {

    private static let logger = Logger(subsystem: "com.rgb2gif", category: "ComponentValidator")

    // MARK: - Validation Errors

    public enum ValidationError: LocalizedError {
        // GIP (Palette) Errors
        case invalidPaletteSize(expected: Int, actual: Int)
        case paletteOverflow(colorCount: Int, maxAllowed: Int)
        case emptyPalette
        case invalidRGBValues(index: Int, rgb: [UInt8])
        case paletteDimensionMismatch(expected: (Int, Int), actual: (Int, Int))
        case invalidPaletteExponent(exp: UInt8, paletteSize: Int)

        // GIX (Structure) Errors
        case frameCountMismatch(declared: Int, actual: Int)
        case invalidFrameDimensions(frameIndex: Int, width: UInt16, height: UInt16, expected: (UInt16, UInt16))
        case indexArraySizeMismatch(frameIndex: Int, expected: Int, actual: Int)
        case emptyIndexData(frameIndex: Int)
        case invalidLZWMinCodeSize(value: UInt8, paletteExp: UInt8)
        case frameDimensionInconsistent(frameIndex: Int, width: UInt16, height: UInt16, gixWidth: UInt16, gixHeight: UInt16)

        // GIP + GIX Compatibility Errors
        case paletteIndexOutOfBounds(frameIndex: Int, pixelIndex: Int, indexValue: UInt8, paletteSize: Int)
        case dimensionMismatch(gipDims: (Int, Int), gixDims: (UInt16, UInt16))
        case lzwCodeSizeMismatch(gixValue: UInt8, expectedFromPalette: UInt8)

        public var errorDescription: String? {
            switch self {
            // GIP Errors
            case .invalidPaletteSize(let expected, let actual):
                return "❌ GIP: Invalid palette size: expected \(expected) colors, got \(actual)"
            case .paletteOverflow(let colorCount, let maxAllowed):
                return "❌ GIP: Palette overflow: \(colorCount) colors exceeds GIF89a max of \(maxAllowed)"
            case .emptyPalette:
                return "❌ GIP: Palette is empty - GIF requires at least 2 colors"
            case .invalidRGBValues(let index, let rgb):
                return "❌ GIP: Invalid RGB at index \(index): \(rgb)"
            case .paletteDimensionMismatch(let expected, let actual):
                return "❌ GIP: Dimensions mismatch: expected \(expected), got \(actual)"
            case .invalidPaletteExponent(let exp, let size):
                return "❌ GIP: Exponent \(exp) doesn't match size \(size) (2^(\(exp)+1) = \(1 << (Int(exp) + 1)))"

            // GIX Errors
            case .frameCountMismatch(let declared, let actual):
                return "❌ GIX: Frame count mismatch: declared \(declared), found \(actual)"
            case .invalidFrameDimensions(let frame, let w, let h, let expected):
                return "❌ GIX: Frame \(frame) invalid dimensions: \(w)×\(h), expected \(expected.0)×\(expected.1)"
            case .indexArraySizeMismatch(let frame, let expected, let actual):
                return "❌ GIX: Frame \(frame) index size: expected \(expected) (\(Int(sqrt(Double(expected))))×\(Int(sqrt(Double(expected))))), got \(actual)"
            case .emptyIndexData(let frame):
                return "❌ GIX: Frame \(frame) has empty index data"
            case .invalidLZWMinCodeSize(let value, let exp):
                return "❌ GIX: LZW min code size \(value) invalid for palette exp \(exp) (should be \(max(2, exp + 1)))"
            case .frameDimensionInconsistent(let frame, let fw, let fh, let gw, let gh):
                return "❌ GIX: Frame \(frame) dimensions (\(fw)×\(fh)) ≠ canvas (\(gw)×\(gh))"

            // Compatibility Errors
            case .paletteIndexOutOfBounds(let frame, let pixel, let index, let size):
                return "❌ COMPAT: Frame \(frame) pixel \(pixel): index \(index) exceeds palette size \(size)"
            case .dimensionMismatch(let gipDims, let gixDims):
                return "❌ COMPAT: GIP dims \(gipDims) ≠ GIX dims \(gixDims)"
            case .lzwCodeSizeMismatch(let gixValue, let expected):
                return "❌ COMPAT: GIX lzwMinCodeSize=\(gixValue) but palette requires \(expected)"
            }
        }
    }

    // MARK: - Validation Results

    public struct ValidationResult {
        public let isValid: Bool
        public let errors: [ValidationError]
        public let warnings: [String]
        public let diagnostics: DiagnosticInfo

        public struct DiagnosticInfo {
            // GIP (Palette) Diagnostics
            public let paletteSizeBytes: Int
            public let paletteColorCount: Int
            public let paletteExponent: UInt8
            public let paletteIsGlobal: Bool

            // GIX (Structure) Diagnostics
            public let frameCount: Int
            public let canvasWidth: UInt16
            public let canvasHeight: UInt16
            public let lzwMinCodeSize: UInt8
            public let totalPixelsPerFrame: Int
            public let totalCompressedBytes: Int

            // Compatibility
            public let expectedIndexArraySize: Int
            public let actualIndexArraySizes: [Int]
            public let compressionRatios: [Double]
            public let avgCompressionRatio: Double
        }

        public var summary: String {
            var lines: [String] = []

            if isValid {
                lines.append("✅ GIF89a Components VALID")
            } else {
                lines.append("❌ GIF89a Components INVALID (\(errors.count) errors)")
            }

            lines.append("\n📊 GIP (Palette) Diagnostics:")
            lines.append("  Colors: \(diagnostics.paletteColorCount) (exp=\(diagnostics.paletteExponent))")
            lines.append("  Size: \(diagnostics.paletteSizeBytes) bytes (\(diagnostics.paletteColorCount)×3 RGB)")
            lines.append("  Type: \(diagnostics.paletteIsGlobal ? "Global" : "Local")")

            lines.append("\n📊 GIX (Structure) Diagnostics:")
            lines.append("  Canvas: \(diagnostics.canvasWidth)×\(diagnostics.canvasHeight)")
            lines.append("  Frames: \(diagnostics.frameCount)")
            lines.append("  LZW min code size: \(diagnostics.lzwMinCodeSize)")
            lines.append("  Pixels/frame: \(diagnostics.totalPixelsPerFrame)")
            lines.append("  Compressed total: \(diagnostics.totalCompressedBytes) bytes")
            lines.append("  Avg compression: \(String(format: "%.1f%%", diagnostics.avgCompressionRatio * 100))")

            if !errors.isEmpty {
                lines.append("\n❌ Errors (\(errors.count)):")
                for error in errors {
                    lines.append("  • \(error.localizedDescription)")
                }
            }

            if !warnings.isEmpty {
                lines.append("\n⚠️  Warnings (\(warnings.count)):")
                for warning in warnings {
                    lines.append("  • \(warning)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    // MARK: - GIP (Palette) Validation

    /// Validate GIP palette component for GIF89a compatibility
    public static func validateGIP(_ gip: GIP) -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [String] = []

        logger.info("🎨 Validating GIP (Color Palette) component...")

        // 1. Check palette is not empty
        if gip.rgb.isEmpty {
            errors.append(.emptyPalette)
            logger.error("GIP: Palette is empty")
        }

        // 2. Validate palette size matches exponent
        let expectedSize = 1 << (Int(gip.paletteExp) + 1)  // 2^(exp+1)
        if gip.rgb.count != expectedSize {
            errors.append(.invalidPaletteSize(expected: expectedSize, actual: gip.rgb.count))
            logger.error("GIP: Palette size mismatch - expected \(expectedSize), got \(gip.rgb.count)")
        } else {
            logger.info("GIP: Palette size correct: \(gip.rgb.count) colors")
        }

        // 3. Validate palette exponent (GIF allows 0-7, meaning 2-256 colors)
        if gip.paletteExp > 7 {
            warnings.append("Palette exponent \(gip.paletteExp) exceeds GIF spec maximum of 7")
        }

        // 4. Validate each RGB entry
        var invalidCount = 0
        for (index, color) in gip.rgb.enumerated() {
            if color.count != 3 {
                errors.append(.invalidRGBValues(index: index, rgb: color))
                invalidCount += 1
            } else {
                for component in color {
                    if component > 255 {
                        errors.append(.invalidRGBValues(index: index, rgb: color))
                        invalidCount += 1
                        break
                    }
                }
            }
            if invalidCount >= 10 {
                warnings.append("More than 10 invalid RGB entries detected, stopping validation")
                break
            }
        }

        // 5. Validate palette tensor dimensions if available
        if !gip.palettes.isEmpty {
            let firstPalette = gip.palettes[0]
            if gip.paletteExp == 7 && (firstPalette.dimA != 16 || firstPalette.dimB != 16) {
                warnings.append("Palette dimensions \(firstPalette.dimA)×\(firstPalette.dimB) unusual for 256 colors (expected 16×16)")
            }
        }

        let diagnostics = ValidationResult.DiagnosticInfo(
            paletteSizeBytes: gip.rgb.count * 3,
            paletteColorCount: gip.rgb.count,
            paletteExponent: gip.paletteExp,
            paletteIsGlobal: true,
            frameCount: 0,
            canvasWidth: 0,
            canvasHeight: 0,
            lzwMinCodeSize: 0,
            totalPixelsPerFrame: 0,
            totalCompressedBytes: 0,
            expectedIndexArraySize: 0,
            actualIndexArraySizes: [],
            compressionRatios: [],
            avgCompressionRatio: 0.0
        )

        let result = ValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings,
            diagnostics: diagnostics
        )

        if result.isValid {
            logger.info("✅ GIP validation PASSED: \(gip.rgb.count) colors, exp=\(gip.paletteExp)")
        } else {
            logger.error("❌ GIP validation FAILED with \(errors.count) errors")
        }

        return result
    }

    // MARK: - GIX (Structure) Validation

    /// Validate GIX structure component for GIF89a compatibility
    public static func validateGIX(_ gix: GIX) -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [String] = []

        logger.info("🏗️  Validating GIX (Structure/Indices) component...")

        let expectedPixelsPerFrame = Int(gix.width) * Int(gix.height)
        var actualSizes: [Int] = []
        var compressedSizes: [Int] = []

        logger.info("GIX: Canvas \(gix.width)×\(gix.height), expecting \(expectedPixelsPerFrame) pixels/frame")

        // 1. Validate each frame
        for (index, frame) in gix.frames.enumerated() {

            // Check frame dimensions match GIX canvas
            if frame.frameWidth != gix.width || frame.frameHeight != gix.height {
                errors.append(.frameDimensionInconsistent(
                    frameIndex: index,
                    width: frame.frameWidth,
                    height: frame.frameHeight,
                    gixWidth: gix.width,
                    gixHeight: gix.height
                ))
                logger.error("GIX: Frame \(index) dimensions (\(frame.frameWidth)×\(frame.frameHeight)) ≠ canvas (\(gix.width)×\(gix.height))")
            }

            // Check payload is not empty
            if frame.payload.isEmpty {
                errors.append(.emptyIndexData(frameIndex: index))
                logger.error("GIX: Frame \(index) has empty payload")
                continue
            }

            compressedSizes.append(frame.payload.count)

            // For LZW-encoded data, estimate decompressed size
            if frame.dataEncoding == .lzwSubblocks {
                // LZW compressed data should be smaller than raw
                let maxCompressedSize = expectedPixelsPerFrame * 2  // Generous upper bound
                if frame.payload.count > maxCompressedSize {
                    warnings.append("Frame \(index) LZW payload large: \(frame.payload.count) bytes for \(expectedPixelsPerFrame) pixels")
                }

                actualSizes.append(expectedPixelsPerFrame)  // Assume decompressed size matches
                logger.debug("GIX: Frame \(index) LZW compressed: \(frame.payload.count) bytes → ~\(expectedPixelsPerFrame) pixels")

            } else if frame.dataEncoding == .rawIndices {
                // Raw indices: must be exactly width × height
                if frame.payload.count != expectedPixelsPerFrame {
                    errors.append(.indexArraySizeMismatch(
                        frameIndex: index,
                        expected: expectedPixelsPerFrame,
                        actual: frame.payload.count
                    ))
                    logger.error("GIX: Frame \(index) raw index size mismatch - expected \(expectedPixelsPerFrame), got \(frame.payload.count)")
                }
                actualSizes.append(frame.payload.count)
            }
        }

        // 2. Validate LZW min code size (must be 2-12 per GIF spec)
        if gix.lzwMinCodeSize < 2 || gix.lzwMinCodeSize > 12 {
            errors.append(.invalidLZWMinCodeSize(value: gix.lzwMinCodeSize, paletteExp: 7))
            logger.error("GIX: LZW min code size \(gix.lzwMinCodeSize) out of spec range [2-12]")
        } else {
            logger.info("GIX: LZW min code size \(gix.lzwMinCodeSize) valid")
        }

        // 3. Check frame count consistency
        if gix.frames.isEmpty {
            errors.append(.frameCountMismatch(declared: 0, actual: gix.frames.count))
            logger.error("GIX: No frames present")
        } else {
            logger.info("GIX: \(gix.frames.count) frames validated")
        }

        // Calculate compression ratios
        let compressionRatios = zip(compressedSizes, actualSizes).map { compressed, raw in
            raw > 0 ? Double(compressed) / Double(raw) : 0.0
        }
        let avgRatio = compressionRatios.isEmpty ? 0.0 : compressionRatios.reduce(0, +) / Double(compressionRatios.count)

        let diagnostics = ValidationResult.DiagnosticInfo(
            paletteSizeBytes: 0,
            paletteColorCount: 0,
            paletteExponent: 0,
            paletteIsGlobal: true,
            frameCount: gix.frames.count,
            canvasWidth: gix.width,
            canvasHeight: gix.height,
            lzwMinCodeSize: gix.lzwMinCodeSize,
            totalPixelsPerFrame: expectedPixelsPerFrame,
            totalCompressedBytes: compressedSizes.reduce(0, +),
            expectedIndexArraySize: expectedPixelsPerFrame,
            actualIndexArraySizes: actualSizes,
            compressionRatios: compressionRatios,
            avgCompressionRatio: avgRatio
        )

        let result = ValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings,
            diagnostics: diagnostics
        )

        if result.isValid {
            logger.info("✅ GIX validation PASSED: \(gix.frames.count) frames, \(gix.width)×\(gix.height), lzwMin=\(gix.lzwMinCodeSize)")
        } else {
            logger.error("❌ GIX validation FAILED with \(errors.count) errors")
        }

        return result
    }

    // MARK: - Combined GIP + GIX Validation

    /// Validate GIP and GIX compatibility for GIF89a muxing
    /// This is the primary validation method to call before muxing
    public static func validateComponents(gip: GIP, gix: GIX) -> ValidationResult {
        var allErrors: [ValidationError] = []
        var allWarnings: [String] = []

        logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.info("🔍 Pre-Mux Validation: GIP + GIX → GIF89a")
        logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // 1. Validate GIP (Color Palette)
        let gipResult = validateGIP(gip)
        allErrors.append(contentsOf: gipResult.errors)
        allWarnings.append(contentsOf: gipResult.warnings)

        // 2. Validate GIX (Structure/Indices)
        let gixResult = validateGIX(gix)
        allErrors.append(contentsOf: gixResult.errors)
        allWarnings.append(contentsOf: gixResult.warnings)

        // 3. Check GIP + GIX compatibility

        // Validate LZW min code size matches palette requirements
        let expectedLZWSize = max(2, UInt8(gip.paletteExp) + 1)
        if gix.lzwMinCodeSize != expectedLZWSize {
            allErrors.append(.lzwCodeSizeMismatch(
                gixValue: gix.lzwMinCodeSize,
                expectedFromPalette: expectedLZWSize
            ))
            logger.error("COMPAT: LZW size mismatch - GIX=\(gix.lzwMinCodeSize), palette requires \(expectedLZWSize)")
        } else {
            logger.info("COMPAT: LZW size matches palette: \(gix.lzwMinCodeSize)")
        }

        // 4. Validate index values don't exceed palette size (for raw indices)
        let rgbCount = gip.rgb.count
        guard rgbCount > 0 && rgbCount <= 256 else {
            let maxAllowed = 256
            allErrors.append(.paletteOverflow(colorCount: rgbCount, maxAllowed: maxAllowed))
            logger.fault("FATAL: Palette overflow - \(rgbCount) colors exceeds GIF89a limit of \(maxAllowed)")

            let finalResult = ValidationResult(
                isValid: false,
                errors: allErrors,
                warnings: allWarnings,
                diagnostics: ValidationResult.DiagnosticInfo(
                    paletteSizeBytes: gipResult.diagnostics.paletteSizeBytes,
                    paletteColorCount: gipResult.diagnostics.paletteColorCount,
                    paletteExponent: gipResult.diagnostics.paletteExponent,
                    paletteIsGlobal: gipResult.diagnostics.paletteIsGlobal,
                    frameCount: gixResult.diagnostics.frameCount,
                    canvasWidth: gixResult.diagnostics.canvasWidth,
                    canvasHeight: gixResult.diagnostics.canvasHeight,
                    lzwMinCodeSize: gixResult.diagnostics.lzwMinCodeSize,
                    totalPixelsPerFrame: gixResult.diagnostics.totalPixelsPerFrame,
                    totalCompressedBytes: gixResult.diagnostics.totalCompressedBytes,
                    expectedIndexArraySize: gixResult.diagnostics.expectedIndexArraySize,
                    actualIndexArraySizes: gixResult.diagnostics.actualIndexArraySizes,
                    compressionRatios: gixResult.diagnostics.compressionRatios,
                    avgCompressionRatio: gixResult.diagnostics.avgCompressionRatio
                )
            )

            logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            logger.info("\(finalResult.summary)")
            logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            logger.fault("❌ Components NOT ready for muxing - palette overflow error")

            return finalResult
        }

        // Validate indices against palette size
        // For 256-color palette: valid indices are 0-255 (index < 256)
        // For N-color palette: valid indices are 0 to N-1 (index < N)
        let maxValidIndex = rgbCount  // rgbCount is already validated as 1-256
        var indexErrorCount = 0
        for (frameIndex, frame) in gix.frames.enumerated() where indexErrorCount < 5 {
            if frame.dataEncoding == .rawIndices {
                for (pixelIndex, indexByte) in frame.payload.enumerated() {
                    // Check: index must be < palette size (e.g., 0-255 for 256 colors)
                    if Int(indexByte) >= maxValidIndex {
                        allErrors.append(.paletteIndexOutOfBounds(
                            frameIndex: frameIndex,
                            pixelIndex: pixelIndex,
                            indexValue: indexByte,
                            paletteSize: maxValidIndex
                        ))
                        indexErrorCount += 1
                        if indexErrorCount >= 5 {
                            allWarnings.append("More than 5 out-of-bounds indices detected, stopping validation")
                            break
                        }
                    }
                }
            }
        }

        // 5. Combine diagnostics
        let combinedDiagnostics = ValidationResult.DiagnosticInfo(
            paletteSizeBytes: gipResult.diagnostics.paletteSizeBytes,
            paletteColorCount: gipResult.diagnostics.paletteColorCount,
            paletteExponent: gipResult.diagnostics.paletteExponent,
            paletteIsGlobal: gipResult.diagnostics.paletteIsGlobal,
            frameCount: gixResult.diagnostics.frameCount,
            canvasWidth: gixResult.diagnostics.canvasWidth,
            canvasHeight: gixResult.diagnostics.canvasHeight,
            lzwMinCodeSize: gixResult.diagnostics.lzwMinCodeSize,
            totalPixelsPerFrame: gixResult.diagnostics.totalPixelsPerFrame,
            totalCompressedBytes: gixResult.diagnostics.totalCompressedBytes,
            expectedIndexArraySize: gixResult.diagnostics.expectedIndexArraySize,
            actualIndexArraySizes: gixResult.diagnostics.actualIndexArraySizes,
            compressionRatios: gixResult.diagnostics.compressionRatios,
            avgCompressionRatio: gixResult.diagnostics.avgCompressionRatio
        )

        let finalResult = ValidationResult(
            isValid: allErrors.isEmpty,
            errors: allErrors,
            warnings: allWarnings,
            diagnostics: combinedDiagnostics
        )

        logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.info("\(finalResult.summary)")
        logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        if finalResult.isValid {
            logger.notice("✅ Components ready for GIF89a muxing")
        } else {
            logger.fault("❌ Components NOT ready for muxing - \(allErrors.count) errors must be fixed")
        }

        return finalResult
    }
}
