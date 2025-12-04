//
//  CaptureToGIP2Pipeline.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF CREATION PIPELINE - STEP-BY-STEP                                     ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║  STEP 1: Camera Capture → [CGImage] array (TemporalCubeCaptureManager)    ║
//  ║  STEP 2: extractRGBPixels() → [[UInt8]] pixel arrays per frame            ║
//  ║  STEP 3: quantizeFramesGlobal() → palette + indexed frames                ║
//  ║  STEP 4: createGIP() → GIP2 palette container                             ║
//  ║  STEP 5: createGIX() → GIX2 index stream (LZW compressed)                 ║
//  ║  STEP 6: GIF89aMuxer.mux() → final GIF89a file                            ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//
//  DEBUG FLAGS:
//  - DEBUG_GIF_PIPELINE: Enable verbose step-by-step logging
//  - DEBUG_PIXEL_COUNTS: Log exact pixel counts at each step
//  - DEBUG_LZW_OUTPUT: Log LZW compression input/output sizes
//

import Foundation
import CoreGraphics
import ImageIO
import os.log

// ════════════════════════════════════════════════════════════════════════════
// DEBUG FLAGS - Set to true to enable detailed pipeline tracing
// ════════════════════════════════════════════════════════════════════════════
private let DEBUG_GIF_PIPELINE = true      // Master switch for all debug output
private let DEBUG_PIXEL_COUNTS = true      // Log exact pixel counts per frame
private let DEBUG_LZW_OUTPUT = true        // Log LZW compression details
private let DEBUG_CGIMAGE_INFO = true      // Log CGImage dimensions/format

private let pipelineLogger = Logger(subsystem: "com.rgb2gif", category: "CaptureToGIP2")

extension Notification.Name {
    static let capturePipelineLog = Notification.Name("com.rgb2gif.capturePipelineLog")
}

/// Capture-to-GIP2/GIX2 Pipeline
@available(iOS 26.0, *)
class CaptureToGIP2Pipeline {

    // MARK: - Palette/Color Options

    /// Palette selection strategy for container assembly
    enum PaletteStrategy: Equatable {
        case global
        case perFrame
        case hybrid(maxOverrides: Int, errorThreshold: Double)

        var description: String {
            switch self {
            case .global: return "global"
            case .perFrame: return "per-frame"
            case .hybrid(let maxOverrides, let error):
                let threshold = String(format: "%.2f", error)
                return "hybrid(maxOverrides:\(maxOverrides),threshold:\(threshold))"
            }
        }
    }

    /// Color extraction pipeline mode
    enum ColorPipeline: String {
        case yuv
        case rgba
    }

    /// Pipeline configuration options
    struct Options {
        let paletteStrategy: PaletteStrategy
        let colorPipeline: ColorPipeline
        let enableDithering: Bool

        static var `default`: Options {
            let config = PaletteStrategyConfig.balanced(frameCount: 80)
            return Options(config: config, colorPipeline: .yuv, enableDithering: false)
        }

        /// High quality preset with dithering enabled
        static var highQuality: Options {
            let config = PaletteStrategyConfig.balanced(frameCount: 80)
            return Options(config: config, colorPipeline: .yuv, enableDithering: true)
        }

        /// Standard initializer (for backward compatibility)
        init(paletteStrategy: PaletteStrategy, colorPipeline: ColorPipeline, enableDithering: Bool = false) {
            self.paletteStrategy = paletteStrategy
            self.colorPipeline = colorPipeline
            self.enableDithering = enableDithering
        }

        /// Convenience initializer from PaletteStrategyConfig (recommended)
        init(config: PaletteStrategyConfig, colorPipeline: ColorPipeline = .yuv, enableDithering: Bool = false) {
            self.paletteStrategy = config.strategy
            self.colorPipeline = colorPipeline
            self.enableDithering = enableDithering
        }
    }

    // MARK: - Types

    struct CaptureResult {
        let gip: GIP              // In-memory palette container
        let gix: GIX              // In-memory index stream
        let gipURL: URL      // Palette file
        let gixURL: URL      // Index stream file
        let gifURL: URL      // Preview GIF
        let metadata: CaptureMetadata
    }

    struct CaptureMetadata: Codable {
        let captureDate: Date
        let frameCount: Int
        let dimension: Int       // 128 or 80
        let paletteSize: Int     // 256
        let colorSpace: String
        let duration: TimeInterval
        let fps: Double
        let paletteStrategy: String
        let colorPipeline: String
    }

    enum CaptureMode {
        case frames128  // 128×128, 128 frames
        case frames80   // 80×80, 80 frames

        var dimension: Int {
            switch self {
            case .frames128: return 128
            case .frames80: return 80
            }
        }

        var frameCount: Int {
            switch self {
            case .frames128: return 128
            case .frames80: return 80
            }
        }
    }

    // MARK: - Properties

    private let mode: CaptureMode
    private let outputDirectory: URL
    private let paletteLibrary: PaletteLibrary?
    private let options: Options
    // NOTE: No shared OctreeColorQuantizer - create fresh instances per-call to avoid NSLock contention
    // when parallel TaskGroup tasks all try to quantize simultaneously

    // MARK: - Initialization

    init(
        mode: CaptureMode,
        outputDirectory: URL,
        paletteLibrary: PaletteLibrary? = nil,
        options: Options = .default
    ) throws {
        self.mode = mode
        self.outputDirectory = outputDirectory
        self.paletteLibrary = paletteLibrary
        self.options = options

        // Create output directory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        emitLog("Capture pipeline initialized: \(mode.dimension)×\(mode.dimension), \(mode.frameCount) frames")
    }

    private func emitLog(_ message: String, level: OSLogType = .info) {
        pipelineLogger.log(level: level, "\(message, privacy: .public)")
        // THREAD SAFETY: NotificationCenter observers may update UI, must post from main thread
        // Using async dispatch to avoid blocking the current (potentially background) thread
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .capturePipelineLog, object: nil, userInfo: ["message": message])
        }
    }

    // MARK: - Public API

    /// Process captured frames → GIP2 + GIX2
    /// - Parameters:
    ///   - frames: Array of CGImages (must match mode.frameCount)
    ///   - captureName: Name for this capture session
    ///   - savePaletteToLibrary: Whether to save palette to library
    /// - Returns: URLs for GIP2, GIX2, and preview GIF
    /// Process captured frames into GIP2 + GIX2 + GIF
    /// THREAD SAFETY: Fully async - no blocking semaphores, runs on Swift concurrency runtime
    func processCapturedFrames(
        _ frames: [CGImage],
        captureName: String,
        savePaletteToLibrary: Bool = true
    ) async throws -> CaptureResult {
        guard frames.count == mode.frameCount else {
            throw PipelineError.invalidFrameCount(frames.count, expected: mode.frameCount)
        }

        emitLog("Processing \(frames.count) frames…")

        let startTime = Date()
        var timingBreakdown: [(String, TimeInterval)] = []  // (step, duration)

        // 1. Build palette set according to selected strategy (ASYNC with parallel quantization)
        let step1Start = Date()
        emitLog("Step 1: Building palette set using strategy \(options.paletteStrategy.description)", level: .debug)
        let paletteSet = try await buildPaletteSet(
            frames,
            targetDimension: mode.dimension,
            captureName: captureName
        )
        timingBreakdown.append(("Quantization", Date().timeIntervalSince(step1Start)))

        // 2. Create GIP2 (palette container)
        let step2Start = Date()
        emitLog("Step 2: Creating GIP2 palette container…", level: .debug)
        let gip = try createGIP(
            paletteSet: paletteSet,
            name: captureName
        )
        timingBreakdown.append(("GIP Creation", Date().timeIntervalSince(step2Start)))

        // 3. Create GIX2 (index stream)
        let step3Start = Date()
        emitLog("Step 3: Creating GIX2 index stream…", level: .debug)
        let gix = try createGIX(
            indexedFrames: paletteSet.indexedFrames,
            dimension: mode.dimension,
            paletteExp: paletteSet.paletteExp,
            name: captureName,
            paletteRefs: paletteSet.paletteRefs,
            defaultPaletteRef: paletteSet.defaultPaletteRef
        )
        timingBreakdown.append(("GIX/LZW", Date().timeIntervalSince(step3Start)))

        // 4. Save files
        let step4Start = Date()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseFilename = "\(captureName)_\(timestamp)"

        let gipURL = outputDirectory.appendingPathComponent("\(baseFilename).gip2")
        let gixURL = outputDirectory.appendingPathComponent("\(baseFilename).gix2")
        let gifURL = outputDirectory.appendingPathComponent("\(baseFilename).gif")

        try gip.write(to: gipURL)
        try gix.write(to: gixURL)
        timingBreakdown.append(("File I/O", Date().timeIntervalSince(step4Start)))

        // 5. PRE-MUX VALIDATION: Check GIP (palette) and GIX (structure) before GIF89a encoding
        let step5Start = Date()
        emitLog("🔍 Validating GIP + GIX components before muxing…")
        let validation = GIPGIXComponentValidator.validateComponents(gip: gip, gix: gix)

        if !validation.isValid {
            emitLog("❌ Component validation FAILED", level: .fault)
            emitLog(validation.summary, level: .fault)
            throw PipelineError.validationFailed(
                message: "GIP/GIX validation failed with \(validation.errors.count) errors. See logs for details."
            )
        }

        emitLog("✅ Components validated successfully")
        emitLog(validation.summary)
        timingBreakdown.append(("Validation", Date().timeIntervalSince(step5Start)))

        // 6. Mux to GIF
        let step6Start = Date()
        emitLog("Step 4: Muxing to GIF…", level: .debug)
        try GIF89aMuxer.mux(gip: gip, gix: gix, to: gifURL, loopForever: true)
        timingBreakdown.append(("GIF Muxing", Date().timeIntervalSince(step6Start)))

        // 7. Save to palette library if requested
        if savePaletteToLibrary, let library = paletteLibrary {
            let step7Start = Date()
            emitLog("Step 5: Saving palette to library…", level: .debug)
            _ = try library.addPalette(gip, name: captureName)
            timingBreakdown.append(("Library", Date().timeIntervalSince(step7Start)))
        }

        let duration = Date().timeIntervalSince(startTime)

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ TIMING BREAKDOWN: Show where time was spent                     │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            emitLog("┌─ TIMING BREAKDOWN ─────────────────────────────────────")
            for (step, stepDuration) in timingBreakdown {
                let percent = (stepDuration / duration) * 100
                let bar = String(repeating: "█", count: Int(percent / 5))
                emitLog("│ \(step.padding(toLength: 14, withPad: " ", startingAt: 0)) \(String(format: "%6.0f", stepDuration * 1000))ms \(String(format: "%5.1f", percent))% \(bar)")
            }
            emitLog("│ ────────────────────────────────────────────────────────")
            emitLog("│ TOTAL: \(String(format: "%.0f", duration * 1000))ms (\(String(format: "%.2f", duration))s)")
            emitLog("└────────────────────────────────────────────────────────")
        }

        let metadata = CaptureMetadata(
            captureDate: Date(),
            frameCount: frames.count,
            dimension: mode.dimension,
            paletteSize: 256,
            colorSpace: "sRGB",
            duration: duration,
            fps: 10.0,
            paletteStrategy: options.paletteStrategy.description,
            colorPipeline: options.colorPipeline.rawValue
        )

        emitLog(String(format: "Capture processing complete: %.2fs", duration))

        return CaptureResult(
            gip: gip,
            gix: gix,
            gipURL: gipURL,
            gixURL: gixURL,
            gifURL: gifURL,
            metadata: metadata
        )
    }

    /// Extract palette only (for palette library)
    /// - Parameters:
    ///   - frames: Array of CGImages
    ///   - paletteName: Name for palette
    /// - Returns: GIP2 palette
    func extractPalette(
        from frames: [CGImage],
        paletteName: String,
        targetDimension: Int? = nil
    ) async throws -> GIP {
        emitLog("Extracting palette from \(frames.count) frames…")

        // For palette extraction, use original dimensions unless specified
        let dimension = targetDimension ?? frames.first?.width ?? 128
        let global = try await quantizeFramesGlobal(frames, targetDimension: dimension, paletteExp: 7)
        let paletteSet = PaletteSet(
            palettes: [global.palette],
            indexedFrames: global.indexedFrames,
            paletteRefs: Array(repeating: 0, count: global.indexedFrames.count),
            hasGlobal: true,
            hasFrameSet: false,
            paletteExp: 7,
            defaultPaletteRef: 0
        )

        return try createGIP(paletteSet: paletteSet, name: paletteName)
    }

    // MARK: - Private Methods

    private struct GlobalQuantizationOutput {
        let palette: [[UInt8]]
        let indexedFrames: [[UInt8]]
        let framePixels: [[[UInt8]]]
    }

    private struct PaletteSet {
        let palettes: [[[UInt8]]]
        let indexedFrames: [[UInt8]]
        let paletteRefs: [UInt32]
        let hasGlobal: Bool
        let hasFrameSet: Bool
        let paletteExp: UInt8
        let defaultPaletteRef: UInt32
    }

    private func buildPaletteSet(
        _ frames: [CGImage],
        targetDimension: Int,
        captureName: String
    ) async throws -> PaletteSet {
        let paletteExp: UInt8 = 7
        let global = try await quantizeFramesGlobal(frames, targetDimension: targetDimension, paletteExp: paletteExp)

        var palettes: [[[UInt8]]] = [global.palette]
        var paletteRefs = Array(repeating: UInt32(0), count: frames.count)
        var indexedFrames = global.indexedFrames
        var hasFrameSet = false

        switch options.paletteStrategy {
        case .global:
            // Nothing to do - already set to global palette
            break

        case .perFrame:
            hasFrameSet = true

            // PARALLEL QUANTIZATION: Use TaskGroup for concurrent per-frame processing
            // This can provide 2-4× speedup on multi-core devices
            // THREAD SAFETY: Each task creates its own fresh OctreeColorQuantizer (no shared state)
            let perFrameResults = try await withThrowingTaskGroup(
                of: (index: Int, palette: [[UInt8]], indices: [UInt8]).self
            ) { group in
                for (frameIndex, frame) in frames.enumerated() {
                    group.addTask {
                        do {
                            let result = try await self.quantizeSingleFrame(
                                frame,
                                targetDimension: targetDimension,
                                paletteExp: paletteExp
                            )
                            return (index: frameIndex, palette: result.palette, indices: result.indexedPixels)
                        } catch {
                            // Wrap error with frame context for debugging
                            throw QuantizationTaskError.frameQuantizationFailed(frameIndex: frameIndex, underlying: error)
                        }
                    }
                }

                // Collect results (may arrive out of order due to parallelism)
                var collected: [(index: Int, palette: [[UInt8]], indices: [UInt8])] = []
                collected.reserveCapacity(frames.count)
                for try await result in group {
                    collected.append(result)
                }

                // Sort by original index to maintain frame order
                return collected.sorted { $0.index < $1.index }
            }

            // Apply results in correct order
            var nextPaletteIndex = palettes.count
            for result in perFrameResults {
                palettes.append(result.palette)
                paletteRefs[result.index] = UInt32(nextPaletteIndex)
                indexedFrames[result.index] = result.indices
                nextPaletteIndex += 1
            }

        case .hybrid(let maxOverrides, let errorThreshold):
            // First, identify which frames need override (based on error threshold)
            var framesToOverride: [(index: Int, frame: CGImage)] = []
            for (frameIndex, frame) in frames.enumerated() {
                let error = computeFrameError(
                    pixels: global.framePixels[frameIndex],
                    indices: indexedFrames[frameIndex],
                    palette: global.palette
                )

                if error > errorThreshold && framesToOverride.count < maxOverrides {
                    framesToOverride.append((index: frameIndex, frame: frame))
                }
            }

            if !framesToOverride.isEmpty {
                hasFrameSet = true

                // PARALLEL QUANTIZATION for frames that need override
                // THREAD SAFETY: Each task creates its own fresh OctreeColorQuantizer (no shared state)
                let overrideResults = try await withThrowingTaskGroup(
                    of: (index: Int, palette: [[UInt8]], indices: [UInt8]).self
                ) { group in
                    for (frameIndex, frame) in framesToOverride {
                        group.addTask {
                            do {
                                let result = try await self.quantizeSingleFrame(
                                    frame,
                                    targetDimension: targetDimension,
                                    paletteExp: paletteExp
                                )
                                return (index: frameIndex, palette: result.palette, indices: result.indexedPixels)
                            } catch {
                                // Wrap error with frame context for debugging
                                throw QuantizationTaskError.frameQuantizationFailed(frameIndex: frameIndex, underlying: error)
                            }
                        }
                    }

                    var collected: [(index: Int, palette: [[UInt8]], indices: [UInt8])] = []
                    for try await result in group {
                        collected.append(result)
                    }
                    return collected.sorted { $0.index < $1.index }
                }

                // Apply override results
                for result in overrideResults {
                    palettes.append(result.palette)
                    paletteRefs[result.index] = UInt32(palettes.count - 1)
                    indexedFrames[result.index] = result.indices
                    emitLog("Hybrid override: frame \(result.index) assigned per-frame palette", level: .debug)
                }
            }
        }

        return PaletteSet(
            palettes: palettes,
            indexedFrames: indexedFrames,
            paletteRefs: paletteRefs,
            hasGlobal: true,
            hasFrameSet: hasFrameSet,
            paletteExp: paletteExp,
            defaultPaletteRef: 0
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 2 & 3: quantizeFramesGlobal - Extract pixels + create palette
    // INPUT:  [CGImage] array from camera
    // OUTPUT: GlobalQuantizationOutput (palette + indexed frames)
    // ═══════════════════════════════════════════════════════════════════════
    private func quantizeFramesGlobal(
        _ frames: [CGImage],
        targetDimension: Int,
        paletteExp: UInt8
    ) async throws -> GlobalQuantizationOutput {

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ DEBUG: Log input frame info                                      │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            emitLog("═══════════════════════════════════════════════════════════")
            emitLog("STEP 2-3: quantizeFramesGlobal() START")
            emitLog("  Input: \(frames.count) CGImage frames")
            emitLog("  Target dimension: \(targetDimension)×\(targetDimension)")
            emitLog("  Expected pixels/frame: \(targetDimension * targetDimension)")
        }

        // DEBUG: Log first frame's CGImage properties
        if DEBUG_CGIMAGE_INFO, let firstFrame = frames.first {
            emitLog("  First CGImage: \(firstFrame.width)×\(firstFrame.height)")
            emitLog("    bitsPerComponent: \(firstFrame.bitsPerComponent)")
            emitLog("    bitsPerPixel: \(firstFrame.bitsPerPixel)")
            emitLog("    bytesPerRow: \(firstFrame.bytesPerRow)")
            if let colorSpace = firstFrame.colorSpace {
                emitLog("    colorSpace: \(colorSpace.name ?? "unknown" as CFString)")
            }
        }

        // ENFORCED CONSTRAINT: Always use 256-color palettes for maximum fidelity
        let enforcedPaletteExp: UInt8 = 7  // 2^(7+1) = 256 colors
        guard paletteExp == enforcedPaletteExp else {
            throw PipelineError.invalidPaletteExp(
                attempted: paletteExp,
                required: enforcedPaletteExp
            )
        }

        // Enforce GIF89a limit: paletteExp must be 0-7 for 2-256 colors
        guard paletteExp <= 7 else {
            throw PipelineError.quantizationFailed
        }

        let paletteSize = 1 << (Int(paletteExp) + 1)
        let expectedPixelsPerFrame = targetDimension * targetDimension

        var framePixels: [[[UInt8]]] = []
        framePixels.reserveCapacity(frames.count)

        // PERFORMANCE FIX: Pre-allocate combinedPixels to avoid O(n²) reallocation
        // For 80 frames × 6400 pixels = 512,000 total pixels
        var combinedPixels: [[UInt8]] = []
        combinedPixels.reserveCapacity(frames.count * expectedPixelsPerFrame)

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ STEP 2a: Extract RGB pixels from each CGImage                    │
        // └─────────────────────────────────────────────────────────────────┘
        for (frameIndex, frame) in frames.enumerated() {
            guard let pixels = extractRGBPixels(from: frame, targetDimension: targetDimension) else {
                emitLog("❌ STEP 2a FAILED: extractRGBPixels returned nil for frame \(frameIndex)", level: .error)
                throw PipelineError.invalidFrameData
            }

            // ⚠️ CRITICAL CHECK: Verify pixel count matches expected
            if DEBUG_PIXEL_COUNTS {
                if pixels.count != expectedPixelsPerFrame {
                    emitLog("⚠️ PIXEL COUNT MISMATCH frame \(frameIndex): got \(pixels.count), expected \(expectedPixelsPerFrame)", level: .error)
                } else if frameIndex == 0 || frameIndex == frames.count - 1 {
                    emitLog("  Frame \(frameIndex): \(pixels.count) pixels ✓")
                }
            }

            framePixels.append(pixels)
            combinedPixels.append(contentsOf: pixels)
        }

        if DEBUG_GIF_PIPELINE {
            emitLog("  STEP 2a complete: extracted \(framePixels.count) frames")
            emitLog("  Total combined pixels: \(combinedPixels.count)")
        }

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ STEP 3a: Build 256-color palette via REAL octree quantization    │
        // │ Creates composite image of all frames, quantizes with octree     │
        // └─────────────────────────────────────────────────────────────────┘
        emitLog("  Using REAL OctreeColorQuantizer (not frequency-based)")

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ DIAGNOSTIC: Analyze input colors before quantization             │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            let inputDiagnostic = analyzeInputColors(combinedPixels)
            emitLog("  ┌─ INPUT COLOR ANALYSIS ─────────────────────────────")
            emitLog("  │ Total pixels: \(combinedPixels.count)")
            emitLog("  │ Unique colors: \(inputDiagnostic.uniqueCount)")
            emitLog("  │ R range: \(inputDiagnostic.rMin)-\(inputDiagnostic.rMax)")
            emitLog("  │ G range: \(inputDiagnostic.gMin)-\(inputDiagnostic.gMax)")
            emitLog("  │ B range: \(inputDiagnostic.bMin)-\(inputDiagnostic.bMax)")
            emitLog("  │ Sample colors (first 5):")
            for (idx, sample) in inputDiagnostic.samples.prefix(5).enumerated() {
                emitLog("  │   [\(idx)] RGB(\(sample.0), \(sample.1), \(sample.2))")
            }
            emitLog("  └──────────────────────────────────────────────────────")
        }

        // Composite dimensions: all frames stacked vertically
        let compositeHeight = targetDimension * frames.count
        let quantStartTime = Date()

        // Quantize with real octree (internally creates image from pixels)
        let quantResult = try await quantizeWithOctree(
            pixels: combinedPixels,
            width: targetDimension,
            height: compositeHeight,
            maxColors: paletteSize,
            enableDithering: options.enableDithering
        )

        let quantDuration = Date().timeIntervalSince(quantStartTime)
        let palette = quantResult.palette

        // Safety check: palette must not exceed 256 colors for UInt8 indices
        guard palette.count <= 256 else {
            throw PipelineError.quantizationFailed
        }

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ DIAGNOSTIC: Analyze output palette after quantization            │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            let paletteDiagnostic = analyzePalette(palette)
            emitLog("  ┌─ OUTPUT PALETTE ANALYSIS ────────────────────────────")
            emitLog("  │ Palette size: \(palette.count) colors")
            emitLog("  │ Quantization time: \(String(format: "%.2f", quantDuration * 1000))ms")
            emitLog("  │ Dithering: \(options.enableDithering ? "ENABLED" : "disabled")")
            emitLog("  │ Non-black colors: \(paletteDiagnostic.nonBlackCount)")
            emitLog("  │ Sample palette entries (first 8):")
            for (idx, color) in palette.prefix(8).enumerated() {
                let r = color[0], g = color[1], b = color[2]
                let hex = String(format: "#%02X%02X%02X", r, g, b)
                emitLog("  │   [\(idx)] RGB(\(r), \(g), \(b)) = \(hex)")
            }
            emitLog("  │ Index usage in first frame:")
            let firstFrameIndices = Array(quantResult.indexedPixels.prefix(expectedPixelsPerFrame))
            let usedIndices = Set(firstFrameIndices)
            emitLog("  │   Unique indices used: \(usedIndices.count)/256")
            emitLog("  │   Most common: \(findMostCommonIndices(firstFrameIndices, top: 3))")
            emitLog("  └──────────────────────────────────────────────────────")
        }

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ STEP 3b: Split composite indices back into per-frame arrays      │
        // │ The octree already did the mapping, we just need to chunk it     │
        // └─────────────────────────────────────────────────────────────────┘
        var indexedFrames: [[UInt8]] = []
        indexedFrames.reserveCapacity(frames.count)

        for frameIndex in 0..<frames.count {
            let startIdx = frameIndex * expectedPixelsPerFrame
            let endIdx = startIdx + expectedPixelsPerFrame

            guard endIdx <= quantResult.indexedPixels.count else {
                emitLog("⚠️ INDEX BOUNDS ERROR frame \(frameIndex): need \(endIdx) but only have \(quantResult.indexedPixels.count)", level: .error)
                throw PipelineError.quantizationFailed
            }

            let frameIndices = Array(quantResult.indexedPixels[startIdx..<endIdx])

            // ⚠️ CRITICAL CHECK: Verify indexed frame size
            if DEBUG_PIXEL_COUNTS && frameIndices.count != expectedPixelsPerFrame {
                emitLog("⚠️ INDEXED FRAME SIZE MISMATCH frame \(frameIndex): \(frameIndices.count) ≠ \(expectedPixelsPerFrame)", level: .error)
            }

            indexedFrames.append(frameIndices)
        }

        if DEBUG_GIF_PIPELINE {
            emitLog("  STEP 3b complete: indexed \(indexedFrames.count) frames")
            if let firstIndexed = indexedFrames.first, let lastIndexed = indexedFrames.last {
                emitLog("    First indexed frame: \(firstIndexed.count) indices")
                emitLog("    Last indexed frame: \(lastIndexed.count) indices")
            }
            emitLog("STEP 2-3: quantizeFramesGlobal() COMPLETE")
            emitLog("═══════════════════════════════════════════════════════════")
        }

        return GlobalQuantizationOutput(
            palette: palette,
            indexedFrames: indexedFrames,
            framePixels: framePixels
        )
    }

    private func quantizeSingleFrame(
        _ frame: CGImage,
        targetDimension: Int,
        paletteExp: UInt8
    ) async throws -> (palette: [[UInt8]], indexedPixels: [UInt8]) {
        // ENFORCED CONSTRAINT: Always use 256-color palettes for maximum fidelity
        let enforcedPaletteExp: UInt8 = 7  // 2^(7+1) = 256 colors
        guard paletteExp == enforcedPaletteExp else {
            throw PipelineError.invalidPaletteExp(
                attempted: paletteExp,
                required: enforcedPaletteExp
            )
        }

        guard let pixels = extractRGBPixels(from: frame, targetDimension: targetDimension) else {
            throw PipelineError.invalidFrameData
        }

        let paletteSize = 1 << (Int(paletteExp) + 1)

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ DIAGNOSTIC: Single-frame input analysis                         │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            let inputDiagnostic = analyzeInputColors(pixels)
            emitLog("  ┌─ SINGLE-FRAME INPUT ────────────────────────────────")
            emitLog("  │ Pixels: \(pixels.count), Unique colors: \(inputDiagnostic.uniqueCount)")
            emitLog("  │ R:[\(inputDiagnostic.rMin)-\(inputDiagnostic.rMax)] G:[\(inputDiagnostic.gMin)-\(inputDiagnostic.gMax)] B:[\(inputDiagnostic.bMin)-\(inputDiagnostic.bMax)]")
            emitLog("  └──────────────────────────────────────────────────────")
        }

        let quantStartTime = Date()

        // Use REAL octree quantization for per-frame palette
        let quantResult = try await quantizeWithOctree(
            pixels: pixels,
            width: targetDimension,
            height: targetDimension,
            maxColors: paletteSize,
            enableDithering: options.enableDithering
        )

        let quantDuration = Date().timeIntervalSince(quantStartTime)

        // Safety check: palette must not exceed 256 colors for UInt8 indices
        guard quantResult.palette.count <= 256 else {
            throw PipelineError.quantizationFailed
        }

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ DIAGNOSTIC: Single-frame output analysis                        │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            let paletteDiagnostic = analyzePalette(quantResult.palette)
            let avgError = computeFrameError(pixels: pixels, indices: quantResult.indexedPixels, palette: quantResult.palette)
            emitLog("  ┌─ SINGLE-FRAME OUTPUT ───────────────────────────────")
            emitLog("  │ Palette: \(quantResult.palette.count) colors, Non-black: \(paletteDiagnostic.nonBlackCount)")
            emitLog("  │ Quantization time: \(String(format: "%.2f", quantDuration * 1000))ms")
            emitLog("  │ Color error (avg): \(String(format: "%.2f", avgError)) (lower=better)")
            emitLog("  │ First 4 palette entries:")
            for (idx, color) in quantResult.palette.prefix(4).enumerated() {
                let hex = String(format: "#%02X%02X%02X", color[0], color[1], color[2])
                emitLog("  │   [\(idx)] \(hex)")
            }
            emitLog("  └──────────────────────────────────────────────────────")
        }

        return (palette: quantResult.palette, indexedPixels: quantResult.indexedPixels)
    }

    private func computeFrameError(
        pixels: [[UInt8]],
        indices: [UInt8],
        palette: [[UInt8]]
    ) -> Double {
        guard !pixels.isEmpty else { return 0 }

        var total: Double = 0
        for (idx, pixel) in pixels.enumerated() where idx < indices.count {
            let paletteColor = palette[Int(indices[idx])]
            let dr = Double(Int(pixel[0]) - Int(paletteColor[0]))
            let dg = Double(Int(pixel[1]) - Int(paletteColor[1]))
            let db = Double(Int(pixel[2]) - Int(paletteColor[2]))
            total += sqrt(dr * dr + dg * dg + db * db)
        }
        return total / Double(pixels.count)
    }

    private func extractRGBPixels(from image: CGImage, targetDimension: Int? = nil) -> [[UInt8]]? {
        let width = targetDimension ?? image.width
        let height = targetDimension ?? image.height

        // FIX: Use bytesPerRow: 0 to let Core Graphics calculate optimal alignment
        // Then use the actual bytesPerRow when reading pixel data
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,  // Let CG choose optimal alignment
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            emitLog("❌ Failed to create CGContext for \(width)×\(height)", level: .error)
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            emitLog("❌ CGContext has no data", level: .error)
            return nil
        }
        let buffer = data.assumingMemoryBound(to: UInt8.self)

        // FIX: Use actual bytesPerRow from context, not assumed width * 4
        // Core Graphics may add padding bytes for alignment
        let bytesPerRow = context.bytesPerRow

        var pixels: [[UInt8]] = []
        pixels.reserveCapacity(width * height)

        // Read pixels row by row using actual bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels.append([buffer[offset], buffer[offset + 1], buffer[offset + 2]])
            }
        }

        emitLog("✅ Extracted \(pixels.count) pixels from \(width)×\(height) image (bytesPerRow=\(bytesPerRow))", level: .debug)
        return pixels
    }

    // MARK: - Real Octree Quantization

    /// Quantize pixels using the real OctreeColorQuantizer
    /// Returns palette as [[R, G, B]] array for compatibility with existing pipeline
    /// Quantize pixels using OctreeColorQuantizer (native async - no semaphore bridge)
    /// THREAD SAFETY: Creates FRESH quantizer per call to avoid NSLock contention in parallel TaskGroup
    /// Each concurrent task gets its own isolated quantizer with independent state
    private func quantizeWithOctree(
        pixels: [[UInt8]],
        width: Int,
        height: Int,
        maxColors: Int,
        enableDithering: Bool = false
    ) async throws -> (palette: [[UInt8]], indexedPixels: [UInt8]) {
        emitLog("  [OCTREE] Creating CGImage from \(pixels.count) pixels (\(width)×\(height))...")
        let imageStartTime = Date()

        // Create a CGImage from the pixel data for OctreeColorQuantizer
        let image = try createImageFromPixels(pixels, width: width, height: height)

        emitLog("  [OCTREE] CGImage created in \(String(format: "%.1f", Date().timeIntervalSince(imageStartTime) * 1000))ms")
        emitLog("  [OCTREE] Creating fresh OctreeColorQuantizer...")

        // CRITICAL FIX: Create FRESH quantizer for each call
        // This eliminates NSLock contention when parallel TaskGroup tasks call this method
        // Each task gets its own octree state, allowing true parallelism
        let freshQuantizer = OctreeColorQuantizer()

        let options = OctreeColorQuantizer.QuantizationOptions(
            maxColors: maxColors,
            dithering: enableDithering,
            enhanceContrast: false
        )

        emitLog("  [OCTREE] Calling quantize() with maxColors=\(maxColors), dithering=\(enableDithering)...")
        let quantStartTime = Date()

        let result = try await freshQuantizer.quantize(image, options: options)

        emitLog("  [OCTREE] quantize() completed in \(String(format: "%.1f", Date().timeIntervalSince(quantStartTime) * 1000))ms")

        // Convert ARGB palette to [[R, G, B]] format
        let rgbPalette: [[UInt8]] = result.palette.map { argb in
            [
                UInt8((argb >> 16) & 0xFF),  // R
                UInt8((argb >> 8) & 0xFF),   // G
                UInt8(argb & 0xFF)           // B
            ]
        }

        return (palette: rgbPalette, indexedPixels: result.indexedPixels)
    }
    /// Create CGImage from pixel array for octree quantization
    private func createImageFromPixels(
        _ pixels: [[UInt8]],
        width: Int,
        height: Int
    ) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 255, count: height * bytesPerRow)

        for (index, pixel) in pixels.enumerated() {
            guard pixel.count >= 3 else { continue }
            let dataIndex = index * bytesPerPixel
            guard dataIndex + 3 < pixelData.count else { continue }

            pixelData[dataIndex] = pixel[0]     // R
            pixelData[dataIndex + 1] = pixel[1] // G
            pixelData[dataIndex + 2] = pixel[2] // B
            pixelData[dataIndex + 3] = 255      // A
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw PipelineError.invalidFrameData
        }

        return cgImage
    }

    // MARK: - Diagnostic Helpers

    /// Result of analyzing input colors
    private struct InputColorDiagnostic {
        let uniqueCount: Int
        let rMin: UInt8, rMax: UInt8
        let gMin: UInt8, gMax: UInt8
        let bMin: UInt8, bMax: UInt8
        let samples: [(UInt8, UInt8, UInt8)]
    }

    /// Analyze input pixel colors for diagnostic logging
    private func analyzeInputColors(_ pixels: [[UInt8]]) -> InputColorDiagnostic {
        var uniqueColors = Set<UInt32>()
        var rMin: UInt8 = 255, rMax: UInt8 = 0
        var gMin: UInt8 = 255, gMax: UInt8 = 0
        var bMin: UInt8 = 255, bMax: UInt8 = 0
        var samples: [(UInt8, UInt8, UInt8)] = []

        for (idx, pixel) in pixels.enumerated() {
            guard pixel.count >= 3 else { continue }
            let r = pixel[0], g = pixel[1], b = pixel[2]

            // Track unique colors (sample every 100th pixel for speed)
            if idx % 100 == 0 {
                let packed = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                uniqueColors.insert(packed)
            }

            // Track ranges
            rMin = min(rMin, r); rMax = max(rMax, r)
            gMin = min(gMin, g); gMax = max(gMax, g)
            bMin = min(bMin, b); bMax = max(bMax, b)

            // Collect first 10 samples
            if samples.count < 10 && idx % (pixels.count / 10 + 1) == 0 {
                samples.append((r, g, b))
            }
        }

        return InputColorDiagnostic(
            uniqueCount: uniqueColors.count,
            rMin: rMin, rMax: rMax,
            gMin: gMin, gMax: gMax,
            bMin: bMin, bMax: bMax,
            samples: samples
        )
    }

    /// Result of analyzing palette
    private struct PaletteDiagnostic {
        let nonBlackCount: Int
    }

    /// Analyze palette for diagnostic logging
    private func analyzePalette(_ palette: [[UInt8]]) -> PaletteDiagnostic {
        var nonBlackCount = 0
        for color in palette {
            guard color.count >= 3 else { continue }
            if color[0] > 5 || color[1] > 5 || color[2] > 5 {
                nonBlackCount += 1
            }
        }
        return PaletteDiagnostic(nonBlackCount: nonBlackCount)
    }

    /// Find the most common palette indices
    private func findMostCommonIndices(_ indices: [UInt8], top: Int) -> String {
        var counts: [UInt8: Int] = [:]
        for idx in indices {
            counts[idx, default: 0] += 1
        }
        let sorted = counts.sorted { $0.value > $1.value }
        let topEntries = sorted.prefix(top)
        return topEntries.map { "[\($0.key)]=\($0.value)" }.joined(separator: ", ")
    }

    // MARK: - GIP Creation

    private func createGIP(paletteSet: PaletteSet, name: String) throws -> GIP {
        let side = UInt16(sqrt(Double(1 << (Int(paletteSet.paletteExp) + 1))))

        let gipPalettes: [GIPPalette] = paletteSet.palettes.enumerated().map { index, palette in
            GIPPalette(
                entryCount: UInt16(palette.count),
                dims: 2,
                dimA: side,
                dimB: side,
                ordering: .rowMajor,
                hasTransparency: false,
                transparentIndex: 0,
                label: index == paletteSet.defaultPaletteRef ? "global" : "palette_\(index)",
                rgb: palette,
                remap: nil,
                hash: nil
            )
        }

        return try GIP(
            paletteExp: paletteSet.paletteExp,
            name: name,
            palettes: gipPalettes,
            hasGlobal: paletteSet.hasGlobal,
            hasFrameSet: paletteSet.hasFrameSet,
            hashAlg: .sha256
        )
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 5: createGIX - LZW compress indexed frames into GIX2 container
    // INPUT:  [[UInt8]] indexed frames (palette indices)
    // OUTPUT: GIX (index stream with LZW compressed payloads)
    // ═══════════════════════════════════════════════════════════════════════
    private func createGIX(
        indexedFrames: [[UInt8]],
        dimension: Int,
        paletteExp: UInt8,
        name: String,
        paletteRefs: [UInt32],
        defaultPaletteRef: UInt32
    ) throws -> GIX {
        let lzwMinCodeSize = max(2, UInt8(paletteExp) + 1)
        let expectedPixelsPerFrame = dimension * dimension

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ DEBUG: Log LZW compression parameters                            │
        // └─────────────────────────────────────────────────────────────────┘
        if DEBUG_GIF_PIPELINE {
            emitLog("═══════════════════════════════════════════════════════════")
            emitLog("STEP 5: createGIX() START")
            emitLog("  Input: \(indexedFrames.count) indexed frames")
            emitLog("  Dimension: \(dimension)×\(dimension)")
            emitLog("  Expected indices/frame: \(expectedPixelsPerFrame)")
            emitLog("  LZW min code size: \(lzwMinCodeSize) (palette exp: \(paletteExp))")
        }

        var frames: [GIXFrame] = []
        frames.reserveCapacity(indexedFrames.count)

        var totalInputBytes = 0
        var totalCompressedBytes = 0

        // ┌─────────────────────────────────────────────────────────────────┐
        // │ STEP 5a: LZW compress each frame                                 │
        // └─────────────────────────────────────────────────────────────────┘
        for (index, indices) in indexedFrames.enumerated() {

            // ⚠️ CRITICAL CHECK: Verify input size before compression
            if DEBUG_PIXEL_COUNTS && indices.count != expectedPixelsPerFrame {
                emitLog("⚠️ LZW INPUT SIZE MISMATCH frame \(index): \(indices.count) ≠ \(expectedPixelsPerFrame)", level: .error)
            }

            let subBlocks = try LZW_Optimized.compress(indices: indices, minCodeSize: lzwMinCodeSize)
            let payload = subBlocks.reduce(Data(), +)

            // ⚠️ CRITICAL CHECK: Verify LZW output is not empty
            if payload.isEmpty {
                emitLog("❌ LZW OUTPUT EMPTY for frame \(index)!", level: .error)
            }

            // DEBUG: Log compression stats for first/last frames
            if DEBUG_LZW_OUTPUT {
                totalInputBytes += indices.count
                totalCompressedBytes += payload.count

                if index == 0 || index == indexedFrames.count - 1 {
                    let ratio = Double(payload.count) / Double(indices.count) * 100
                    emitLog("  Frame \(index): \(indices.count) indices → \(payload.count) LZW bytes (\(String(format: "%.1f", ratio))%)")
                }
            }

            let frame = GIXFrame(
                paletteRef: paletteRefs[index],
                delay: 10,
                disposal: 0,
                transparency: false,
                transparentIndex: 0,
                dataEncoding: .lzwSubblocks,
                payload: payload,
                left: 0,
                top: 0,
                frameWidth: UInt16(dimension),
                frameHeight: UInt16(dimension),
                interlaced: false
            )

            // ⚠️ CRITICAL CHECK: Verify GIXFrame is valid
            if !frame.isValid {
                emitLog("❌ GIXFrame INVALID for frame \(index)! payload size: \(payload.count)", level: .error)
            }

            frames.append(frame)
        }

        if DEBUG_GIF_PIPELINE {
            let avgRatio = totalInputBytes > 0 ? Double(totalCompressedBytes) / Double(totalInputBytes) * 100 : 0
            emitLog("  STEP 5a complete: \(frames.count) frames compressed")
            emitLog("  Total: \(totalInputBytes) indices → \(totalCompressedBytes) LZW bytes (\(String(format: "%.1f", avgRatio))%)")
            emitLog("STEP 5: createGIX() COMPLETE")
            emitLog("═══════════════════════════════════════════════════════════")
        }

        return try GIX(
            width: UInt16(dimension),
            height: UInt16(dimension),
            lzwMinCodeSize: lzwMinCodeSize,
            defaultPaletteRef: defaultPaletteRef,
            name: name,
            frames: frames
        )
    }

    // MARK: - Errors

    /// Error type for TaskGroup quantization with frame context
    /// Wraps underlying errors with the frame index that failed for debugging
    enum QuantizationTaskError: LocalizedError {
        case frameQuantizationFailed(frameIndex: Int, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .frameQuantizationFailed(let frameIndex, let underlying):
                return "Quantization failed for frame \(frameIndex): \(underlying.localizedDescription)"
            }
        }
    }

    enum PipelineError: LocalizedError {
        case invalidFrameCount(Int, expected: Int)
        case invalidFrameData
        case quantizationFailed
        case validationFailed(message: String)
        case invalidPaletteExp(attempted: UInt8, required: UInt8)

        var errorDescription: String? {
            switch self {
            case .invalidFrameCount(let actual, let expected):
                return "Invalid frame count: \(actual) (expected \(expected))"
            case .invalidFrameData:
                return "Invalid frame data"
            case .quantizationFailed:
                return "Color quantization failed"
            case .validationFailed(let message):
                return "Component validation failed: \(message)"
            case .invalidPaletteExp(let attempted, let required):
                return "Invalid palette exponent: \(attempted) (must be \(required) for 256-color palettes)"
            }
        }
    }
}
