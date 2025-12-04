//
//  GIF89aMuxer.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF89a MUXER - FINAL ASSEMBLY STAGE                                      ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║  PURPOSE: Combine GIP2 (palettes) + GIX2 (indices) → GIF89a file          ║
//  ║                                                                           ║
//  ║  INPUT:                                                                   ║
//  ║  - GIP: Palette container with [[R,G,B]] color tables                     ║
//  ║  - GIX: Index stream with LZW-compressed frame payloads                   ║
//  ║                                                                           ║
//  ║  OUTPUT:                                                                  ║
//  ║  - Standards-compliant GIF89a file on disk                                ║
//  ║                                                                           ║
//  ║  MUXING PROCESS:                                                          ║
//  ║  1. Validate GIP and GIX components                                       ║
//  ║  2. Initialize GIFStreamWriter with output URL                            ║
//  ║  3. Write header, LSD, Global Color Table, loop extension                 ║
//  ║  4. For each frame in GIX:                                                ║
//  ║     - Determine if Local CT needed (paletteRef ≠ defaultPaletteRef)       ║
//  ║     - Write GCE + Image Descriptor + [LCT] + Image Data                   ║
//  ║  5. Write trailer (0x3B)                                                  ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//
//  Reference: GIF89a Specification
//  - §18-20: Color tables
//  - §15: LZW compression
//  - §16: Sub-blocks (≤255 bytes)
//  - §23: Graphic Control Extension
//  - Netscape: http://www.vurdalakov.net/misc/gif/netscape-looping-application-extension
//
//  DEBUG FLAGS:
//  - DEBUG_MUXER: Enable muxing process logging
//  - DEBUG_FRAME_DETAILS: Log each frame's parameters
//

import Foundation
import os.log

// ════════════════════════════════════════════════════════════════════════════
// DEBUG FLAGS - Set to true to enable muxer tracing
// ════════════════════════════════════════════════════════════════════════════
private let DEBUG_MUXER = true           // Log muxing process
private let DEBUG_FRAME_DETAILS = true   // Log each frame's details

private let muxerLogger = Logger(subsystem: "com.rgb2gif", category: "GIF89aMuxer")

/// GIF89a Muxer - assembles GIP2+GIX2 into standards-compliant GIF
@available(iOS 26.0, *)
struct GIF89aMuxer {

    // MARK: - Public API

    /// Mux GIP2 + GIX2 into GIF89a file
    /// - Parameters:
    ///   - gip: Palette container (GIP2)
    ///   - gix: Index stream (GIX2)
    ///   - outputURL: Output file URL
    ///   - loopForever: Whether to add Netscape loop extension (if nil, uses GIX.loopCount)
    static func mux(gip: GIP, gix: GIX, to outputURL: URL, loopForever: Bool? = nil) throws {
        muxerLogger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        muxerLogger.info("Starting GIF89a mux: \(gix.width)×\(gix.height), \(gix.frameCount) frames")
        muxerLogger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // SAFETY CHECK: Validate GIP + GIX components before muxing
        muxerLogger.info("🔒 Safety check: Validating GIP + GIX components...")
        let validation = GIPGIXComponentValidator.validateComponents(gip: gip, gix: gix)

        if !validation.isValid {
            muxerLogger.fault("❌ Muxer safety check FAILED - components invalid!")
            muxerLogger.fault("\(validation.summary)")
            throw MuxerError.componentValidationFailed(
                errorCount: validation.errors.count,
                details: validation.summary
            )
        }

        muxerLogger.notice("✅ Safety check passed - components valid")

        // Legacy basic validation (kept for backwards compatibility)
        guard gip.isValid else {
            throw MuxerError.invalidGIP
        }

        guard gix.isValid else {
            throw MuxerError.invalidGIX
        }

        // Initialize writer
        var writer = try GIFStreamWriter(outputURL: outputURL)

        // Get global palette (default palette from GIP2)
        let globalPaletteIdx = Int(gix.defaultPaletteRef)
        guard globalPaletteIdx < gip.palettes.count else {
            throw MuxerError.paletteRefOutOfRange(gix.defaultPaletteRef, max: UInt32(gip.palettes.count))
        }

        let globalPalette = gip.palettes[globalPaletteIdx]

        // Determine loop behavior (V2: use GIX.loopCount if available)
        let shouldLoop: Bool
        let loopCount: UInt16
        if let explicitLoop = loopForever {
            shouldLoop = explicitLoop
            loopCount = 0  // 0 = forever
        } else if let gixLoopCount = gix.loopCount {
            shouldLoop = true
            loopCount = gixLoopCount
        } else {
            shouldLoop = true
            loopCount = 0  // Default to loop forever
        }

        // Write header + GCT + loop extension (with V2 fields)
        try writer.begin(
            width: gix.width,
            height: gix.height,
            paletteExp: gip.paletteExp,
            globalPaletteRGB: globalPalette.rgb,
            loopForever: shouldLoop,
            loopCount: loopCount,
            backgroundColorIndex: gip.backgroundColorIndex,
            pixelAspectRatio: gip.pixelAspectRatio
        )

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ FRAME LOOP: Write each frame to GIF                              │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_MUXER {
            muxerLogger.info("═══════════════════════════════════════════════════════════")
            muxerLogger.info("MUXER: Starting frame loop - \(gix.frames.count) frames")
            muxerLogger.info("  Expected frame size: \(gix.width)×\(gix.height)")
            muxerLogger.info("  LZW min code size: \(gix.lzwMinCodeSize)")
            muxerLogger.info("═══════════════════════════════════════════════════════════")
        }

        var totalPayloadBytes = 0

        for (idx, frame) in gix.frames.enumerated() {
            let paletteRef = Int(frame.paletteRef)

            // Check if frame uses different palette than global
            let useLocalCT = (paletteRef != globalPaletteIdx)

            var localCT: [[UInt8]]? = nil
            if useLocalCT {
                guard paletteRef < gip.palettes.count else {
                    throw MuxerError.paletteRefOutOfRange(frame.paletteRef, max: UInt32(gip.palettes.count))
                }
                localCT = gip.palettes[paletteRef].rgb
                muxerLogger.debug("Frame \(idx): using Local CT (paletteRef=\(paletteRef))")
            }

            // ⚠️ CRITICAL DEBUG: Log frame parameters
            if DEBUG_FRAME_DETAILS {
                totalPayloadBytes += frame.payload.count
                if idx == 0 || idx == gix.frames.count - 1 || !frame.isValid {
                    muxerLogger.debug("┌─ MUXER Frame \(idx) ─────────────────────────")
                    muxerLogger.debug("│ Dimensions: \(frame.frameWidth)×\(frame.frameHeight)")
                    muxerLogger.debug("│ Payload: \(frame.payload.count) bytes")
                    muxerLogger.debug("│ isValid: \(frame.isValid)")
                    muxerLogger.debug("│ CT: \(useLocalCT ? "Local" : "Global")")
                    muxerLogger.debug("└────────────────────────────────────────────")
                }
            }

            // Write frame with optional local color table
            try writer.addFrame(frame, lzwMinCodeSize: gix.lzwMinCodeSize, useLocalCT: useLocalCT, localCT: localCT)
        }

        if DEBUG_MUXER {
            muxerLogger.info("═══════════════════════════════════════════════════════════")
            muxerLogger.info("MUXER: Frame loop complete - \(gix.frames.count) frames")
            muxerLogger.info("  Total payload bytes: \(totalPayloadBytes)")
            muxerLogger.info("  Avg payload/frame: \(totalPayloadBytes / max(1, gix.frames.count)) bytes")
            muxerLogger.info("═══════════════════════════════════════════════════════════")
        }

        // Write trailer
        try writer.end()

        muxerLogger.info("GIF89a mux completed: \(outputURL.lastPathComponent)")
    }

    /// Mux from file paths
    /// - Parameters:
    ///   - gipURL: GIP2 file URL
    ///   - gixURL: GIX2 file URL
    ///   - outputURL: Output GIF file URL
    ///   - loopForever: Whether to add Netscape loop extension
    static func muxFiles(gipURL: URL, gixURL: URL, to outputURL: URL, loopForever: Bool = true) throws {
        let gip = try GIP.load(from: gipURL)
        let gix = try GIX.load(from: gixURL)
        try mux(gip: gip, gix: gix, to: outputURL, loopForever: loopForever)
    }

    // MARK: - Errors

    enum MuxerError: LocalizedError {
        case invalidGIP
        case invalidGIX
        case paletteRefOutOfRange(UInt32, max: UInt32)
        case dimensionMismatch
        case paletteExpMismatch
        case componentValidationFailed(errorCount: Int, details: String)

        var errorDescription: String? {
            switch self {
            case .invalidGIP:
                return "Invalid GIP2 file"
            case .invalidGIX:
                return "Invalid GIX2 file"
            case .paletteRefOutOfRange(let ref, let max):
                return "Palette reference \(ref) out of range (max: \(max))"
            case .dimensionMismatch:
                return "GIP and GIX dimension mismatch"
            case .paletteExpMismatch:
                return "GIP and GIX palette exponent mismatch"
            case .componentValidationFailed(let errorCount, let details):
                return "Component validation failed with \(errorCount) errors:\n\(details)"
            }
        }
    }
}

// MARK: - Convenience Methods

@available(iOS 26.0, *)
extension GIF89aMuxer {

    /// Create GIF from raw data (indices + palette)
    /// - Parameters:
    ///   - indices: Frame indices (width×height per frame)
    ///   - palette: RGB palette [[R,G,B]]
    ///   - width: Frame width
    ///   - height: Frame height
    ///   - frameDelay: Delay per frame in centiseconds (default: 10 = 100ms)
    ///   - outputURL: Output file URL
    static func createGIF(
        indices: [[UInt8]],
        palette: [[UInt8]],
        width: UInt16,
        height: UInt16,
        frameDelay: UInt16 = 10,
        outputURL: URL
    ) throws {
        muxerLogger.info("Creating GIF from raw data: \(indices.count) frames, \(palette.count) colors")

        // Validate dimensions
        let expectedPixels = Int(width) * Int(height)
        guard indices.allSatisfy({ $0.count == expectedPixels }) else {
            throw MuxerError.dimensionMismatch
        }

        // Create GIP2 from palette
        let gip = try GIP.create(rgb: palette)

        // Compress frames with LZW
        let lzwMinCodeSize = max(2, UInt8(gip.paletteExp) + 1)
        var frames: [GIXFrame] = []

        for (idx, frameIndices) in indices.enumerated() {
            muxerLogger.debug("Compressing frame \(idx + 1)/\(indices.count)")

            // LZW compress
            let subBlocks = try LZW_Optimized.compress(indices: frameIndices, minCodeSize: lzwMinCodeSize)

            // Concatenate sub-blocks into single payload
            let payload = subBlocks.reduce(Data()) { $0 + $1 }

            let frame = GIXFrame(
                paletteRef: 0,
                delay: frameDelay,
                disposal: 0,
                transparency: false,
                transparentIndex: 0,
                dataEncoding: .lzwSubblocks,
                payload: payload,
                left: 0,
                top: 0,
                frameWidth: width,
                frameHeight: height,
                interlaced: false
            )
            frames.append(frame)
        }

        // Create GIX2
        let gix = try GIX(
            width: width,
            height: height,
            lzwMinCodeSize: lzwMinCodeSize,
            defaultPaletteRef: 0,
            name: "RGB2GIF",
            frames: frames,
            loopCount: 0  // Loop forever by default
        )

        // Mux to GIF
        try mux(gip: gip, gix: gix, to: outputURL)
    }
}
