//
//  GIPGIXBridge.swift
//  RGB2GIF
//
//  Bridge function: Converts OctreeColorQuantizer output to GIP + GIX
//  This is the critical missing link between capture and GIF export
//
//  Data Flow:
//    Camera → Quantizer → QuantizationResult
//                              ↓
//                        GIPGIXBridge
//                              ↓
//                    ┌────────┴────────┐
//                    ↓                 ↓
//                   GIP               GIX
//             (256 RGB colors)   (LZW compressed frames)
//                    ↓                 ↓
//                    └────────┬────────┘
//                             ↓
//                      GIF89aMuxer → .gif file
//

import Foundation
import os.log
import QuartzCore  // For CACurrentMediaTime()

private let bridgeLogger = Logger(subsystem: "com.rgb2gif", category: "GIPGIXBridge")

// MARK: - Bridge Result

@available(iOS 26.0, *)
public struct GIPGIXBridgeResult {
    public let gip: GIP
    public let gix: GIX
    public let rawIndices: [UInt8]  // For 3D visualization (uncompressed)
    public let processingTime: TimeInterval

    /// Convenience: Mux directly to GIF
    public func muxToGIF(outputURL: URL, loopForever: Bool = true) throws {
        try GIF89aMuxer.mux(gip: gip, gix: gix, to: outputURL, loopForever: loopForever)
    }
}

// MARK: - Bridge Errors

@available(iOS 26.0, *)
public enum GIPGIXBridgeError: LocalizedError {
    case emptyPalette
    case emptyIndices
    case paletteTooLarge(count: Int)
    case lzwCompressionFailed(String)
    case gipCreationFailed(String)
    case gixCreationFailed(String)
    case dimensionMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyPalette:
            return "Cannot create GIP: palette is empty"
        case .emptyIndices:
            return "Cannot create GIX: no pixel indices provided"
        case .paletteTooLarge(let count):
            return "Palette has \(count) colors, maximum is 256"
        case .lzwCompressionFailed(let msg):
            return "LZW compression failed: \(msg)"
        case .gipCreationFailed(let msg):
            return "GIP creation failed: \(msg)"
        case .gixCreationFailed(let msg):
            return "GIX creation failed: \(msg)"
        case .dimensionMismatch(let expected, let actual):
            return "Index array size mismatch: expected \(expected), got \(actual)"
        }
    }
}

// MARK: - Bridge Functions

@available(iOS 26.0, *)
public struct GIPGIXBridge {

    // MARK: - Single Frame Bridge

    /// Convert quantization result to GIP + GIX (single frame)
    /// - Parameters:
    ///   - palette: Array of ARGB colors from quantizer (UInt32, up to 256)
    ///   - indices: Palette indices for each pixel (0-255)
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - delay: Frame delay in centiseconds (default: 10 = 0.1s)
    /// - Returns: GIPGIXBridgeResult containing GIP, GIX, and raw indices
    public static func convert(
        palette: [UInt32],
        indices: [UInt8],
        width: Int,
        height: Int,
        delay: UInt16 = 10
    ) throws -> GIPGIXBridgeResult {
        let startTime = CACurrentMediaTime()

        bridgeLogger.info("🌉 GIPGIXBridge: Converting \(palette.count) colors, \(width)×\(height) frame")

        // Validate inputs
        guard !palette.isEmpty else {
            throw GIPGIXBridgeError.emptyPalette
        }

        guard palette.count <= 256 else {
            throw GIPGIXBridgeError.paletteTooLarge(count: palette.count)
        }

        guard !indices.isEmpty else {
            throw GIPGIXBridgeError.emptyIndices
        }

        let expectedPixels = width * height
        guard indices.count == expectedPixels else {
            throw GIPGIXBridgeError.dimensionMismatch(expected: expectedPixels, actual: indices.count)
        }

        // 1. Convert ARGB palette to RGB triples
        let rgbPalette = convertARGBtoRGB(palette)
        bridgeLogger.debug("Converted \(rgbPalette.count) ARGB colors to RGB")

        // 2. Create GIP
        let gip: GIP
        do {
            gip = try GIP.create(rgb: rgbPalette)
            bridgeLogger.info("✅ GIP created: \(gip.rgb.count) colors, exp=\(gip.paletteExp)")
        } catch {
            throw GIPGIXBridgeError.gipCreationFailed(error.localizedDescription)
        }

        // 3. Calculate LZW min code size from palette
        // For N colors: minCodeSize = ceil(log2(N)), minimum 2
        let lzwMinCodeSize = calculateLZWMinCodeSize(paletteSize: palette.count)
        bridgeLogger.debug("LZW min code size: \(lzwMinCodeSize) for \(palette.count) colors")

        // 4. LZW compress the indices
        let lzwPayload: Data
        do {
            let subBlocks = try LZW_Optimized.compress(indices: indices, minCodeSize: lzwMinCodeSize)
            lzwPayload = subBlocks.reduce(Data()) { $0 + $1 }
            bridgeLogger.info("✅ LZW compressed: \(indices.count) bytes → \(lzwPayload.count) bytes (\(String(format: "%.1f", Double(lzwPayload.count) / Double(indices.count) * 100))%)")
        } catch {
            throw GIPGIXBridgeError.lzwCompressionFailed(error.localizedDescription)
        }

        // 5. Create GIX frame
        let frame = GIXFrame(
            paletteRef: 0,
            delay: delay,
            disposal: 0,
            transparency: false,
            transparentIndex: 0,
            dataEncoding: .lzwSubblocks,
            payload: lzwPayload,
            left: 0,
            top: 0,
            frameWidth: UInt16(width),
            frameHeight: UInt16(height),
            interlaced: false
        )

        // 6. Create GIX
        let gix: GIX
        do {
            gix = try GIX(
                width: UInt16(width),
                height: UInt16(height),
                lzwMinCodeSize: lzwMinCodeSize,
                defaultPaletteRef: 0,
                name: "RGB2GIF",
                frames: [frame],
                loopCount: 0  // Loop forever
            )
            bridgeLogger.info("✅ GIX created: \(width)×\(height), 1 frame")
        } catch {
            throw GIPGIXBridgeError.gixCreationFailed(error.localizedDescription)
        }

        let processingTime = CACurrentMediaTime() - startTime
        bridgeLogger.notice("🌉 Bridge complete in \(String(format: "%.2f", processingTime * 1000))ms")

        return GIPGIXBridgeResult(
            gip: gip,
            gix: gix,
            rawIndices: indices,
            processingTime: processingTime
        )
    }

    // MARK: - Multi-Frame Bridge

    /// Convert multiple frames to GIP + GIX (animated GIF)
    /// - Parameters:
    ///   - palette: Shared palette for all frames (ARGB, up to 256 colors)
    ///   - frames: Array of (indices, delay) tuples for each frame
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    /// - Returns: GIPGIXBridgeResult containing GIP, GIX with all frames
    public static func convertMultiFrame(
        palette: [UInt32],
        frames: [(indices: [UInt8], delay: UInt16)],
        width: Int,
        height: Int
    ) throws -> GIPGIXBridgeResult {
        let startTime = CACurrentMediaTime()

        bridgeLogger.info("🌉 GIPGIXBridge: Converting \(frames.count) frames, \(palette.count) colors, \(width)×\(height)")

        // Validate inputs
        guard !palette.isEmpty else {
            throw GIPGIXBridgeError.emptyPalette
        }

        guard palette.count <= 256 else {
            throw GIPGIXBridgeError.paletteTooLarge(count: palette.count)
        }

        guard !frames.isEmpty else {
            throw GIPGIXBridgeError.emptyIndices
        }

        let expectedPixels = width * height

        // 1. Convert ARGB palette to RGB triples
        let rgbPalette = convertARGBtoRGB(palette)

        // 2. Create GIP
        let gip: GIP
        do {
            gip = try GIP.create(rgb: rgbPalette)
        } catch {
            throw GIPGIXBridgeError.gipCreationFailed(error.localizedDescription)
        }

        // 3. Calculate LZW min code size
        let lzwMinCodeSize = calculateLZWMinCodeSize(paletteSize: palette.count)

        // 4. Create GIX frames with LZW compression
        var gixFrames: [GIXFrame] = []
        var allRawIndices: [UInt8] = []

        for (index, frameData) in frames.enumerated() {
            guard frameData.indices.count == expectedPixels else {
                throw GIPGIXBridgeError.dimensionMismatch(expected: expectedPixels, actual: frameData.indices.count)
            }

            // LZW compress
            let subBlocks = try LZW_Optimized.compress(indices: frameData.indices, minCodeSize: lzwMinCodeSize)
            let lzwPayload = subBlocks.reduce(Data()) { $0 + $1 }

            let frame = GIXFrame(
                paletteRef: 0,
                delay: frameData.delay,
                disposal: 0,
                transparency: false,
                transparentIndex: 0,
                dataEncoding: .lzwSubblocks,
                payload: lzwPayload,
                left: 0,
                top: 0,
                frameWidth: UInt16(width),
                frameHeight: UInt16(height),
                interlaced: false
            )

            gixFrames.append(frame)
            allRawIndices.append(contentsOf: frameData.indices)

            if (index + 1) % 10 == 0 {
                bridgeLogger.debug("Processed \(index + 1)/\(frames.count) frames")
            }
        }

        // 5. Create GIX
        let gix: GIX
        do {
            gix = try GIX(
                width: UInt16(width),
                height: UInt16(height),
                lzwMinCodeSize: lzwMinCodeSize,
                defaultPaletteRef: 0,
                name: "RGB2GIF",
                frames: gixFrames,
                loopCount: 0
            )
        } catch {
            throw GIPGIXBridgeError.gixCreationFailed(error.localizedDescription)
        }

        let processingTime = CACurrentMediaTime() - startTime
        bridgeLogger.notice("🌉 Multi-frame bridge complete: \(frames.count) frames in \(String(format: "%.2f", processingTime * 1000))ms")

        return GIPGIXBridgeResult(
            gip: gip,
            gix: gix,
            rawIndices: allRawIndices,
            processingTime: processingTime
        )
    }

    // MARK: - Quantization Result Bridge

    /// Convert OctreeColorQuantizer.QuantizationResult directly to GIP + GIX
    public static func fromQuantizationResult(
        _ result: OctreeColorQuantizer.QuantizationResult,
        width: Int,
        height: Int,
        delay: UInt16 = 10
    ) throws -> GIPGIXBridgeResult {
        return try convert(
            palette: result.palette,
            indices: result.indexedPixels,
            width: width,
            height: height,
            delay: delay
        )
    }

    // MARK: - Helper Functions

    /// Convert ARGB palette (UInt32) to RGB triples ([[UInt8]])
    private static func convertARGBtoRGB(_ argbPalette: [UInt32]) -> [[UInt8]] {
        return argbPalette.map { argb in
            let r = UInt8((argb >> 16) & 0xFF)
            let g = UInt8((argb >> 8) & 0xFF)
            let b = UInt8(argb & 0xFF)
            return [r, g, b]
        }
    }

    /// Calculate LZW minimum code size from palette size
    /// Per GIF89a spec: minCodeSize = ceil(log2(paletteSize)), minimum 2
    private static func calculateLZWMinCodeSize(paletteSize: Int) -> UInt8 {
        if paletteSize <= 2 { return 2 }
        if paletteSize <= 4 { return 2 }
        if paletteSize <= 8 { return 3 }
        if paletteSize <= 16 { return 4 }
        if paletteSize <= 32 { return 5 }
        if paletteSize <= 64 { return 6 }
        if paletteSize <= 128 { return 7 }
        return 8  // 129-256 colors
    }
}

// MARK: - QuantizationResult Extension

@available(iOS 26.0, *)
extension OctreeColorQuantizer.QuantizationResult {

    /// Convert to GIP + GIX for GIF export
    public func toGIPGIX(
        width: Int,
        height: Int,
        delay: UInt16 = 10
    ) throws -> GIPGIXBridgeResult {
        return try GIPGIXBridge.fromQuantizationResult(
            self,
            width: width,
            height: height,
            delay: delay
        )
    }
}

// MARK: - PaletteColor-Based API

@available(iOS 26.0, *)
extension GIPGIXBridge {

    /// Convert using PaletteColor array (modular API)
    /// - Parameters:
    ///   - colors: Array of PaletteColor (2-256 colors)
    ///   - indices: Palette indices for each pixel (0-255)
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - delay: Frame delay in centiseconds
    /// - Returns: GIPGIXBridgeResult with PaletteColor-aware extensions
    public static func convert(
        colors: [PaletteColor],
        indices: [UInt8],
        width: Int,
        height: Int,
        delay: UInt16 = 10
    ) throws -> GIPGIXBridgeResult {
        // Convert PaletteColor to ARGB UInt32
        let argbPalette = colors.map { $0.asARGB }
        return try convert(
            palette: argbPalette,
            indices: indices,
            width: width,
            height: height,
            delay: delay
        )
    }

    /// Convert multiple frames using PaletteColor array
    public static func convertMultiFrame(
        colors: [PaletteColor],
        frames: [(indices: [UInt8], delay: UInt16)],
        width: Int,
        height: Int
    ) throws -> GIPGIXBridgeResult {
        let argbPalette = colors.map { $0.asARGB }
        return try convertMultiFrame(
            palette: argbPalette,
            frames: frames,
            width: width,
            height: height
        )
    }
}

// MARK: - GIPGIXBridgeResult PaletteColor Extensions

@available(iOS 26.0, *)
extension GIPGIXBridgeResult {

    /// Get palette as PaletteColor array
    public var paletteColors: [PaletteColor] {
        return gip.primaryPaletteColors
    }

    /// Create a new result with a different palette (palette swap)
    /// Useful for applying different color interpretations to the same index data
    public func withPalette(_ newColors: [PaletteColor]) throws -> GIPGIXBridgeResult {
        let newGIP = try GIP.create(colors: newColors)

        // Validate compatibility
        try GIPGIXStructuralValidator.validateComponents(gip: newGIP, gix: gix)

        return GIPGIXBridgeResult(
            gip: newGIP,
            gix: gix,
            rawIndices: rawIndices,
            processingTime: processingTime
        )
    }

    /// Swap to grayscale palette interpretation
    public func withGrayscalePalette() throws -> GIPGIXBridgeResult {
        let grayscale = [PaletteColor].grayscaleRamp(count: gip.paletteSize)
        return try withPalette(grayscale)
    }

    /// Swap to heatmap palette interpretation
    public func withHeatmapPalette() throws -> GIPGIXBridgeResult {
        let heatmap = [PaletteColor].heatmapPalette(count: gip.paletteSize)
        return try withPalette(heatmap)
    }

    /// Export with swapped palette to GIF
    public func muxToGIFWithPalette(
        _ newColors: [PaletteColor],
        outputURL: URL,
        loopForever: Bool = true
    ) throws {
        let swapped = try withPalette(newColors)
        try swapped.muxToGIF(outputURL: outputURL, loopForever: loopForever)
    }
}
