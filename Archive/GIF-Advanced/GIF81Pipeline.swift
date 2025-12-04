//
//  GIF81Pipeline.swift
//  RGB2GIF
//
//  ============================================================================
//  GIF81 PIPELINE - Complete 81x81x81 Composable GIF Generation
//  ============================================================================
//
//  PURPOSE: Orchestrate the complete pipeline from camera frames to GIF output.
//           This is the main entry point for GIF creation.
//
//  PIPELINE STEPS
//  --------------
//  1. CAPTURE: Receive 81 CGImage frames from camera
//  2. CROP: Center-crop each frame to square
//  3. RESIZE: Scale each frame to 81x81 pixels
//  4. INDEX: Extract pixels and assign to luminance-ordered buckets
//  5. PALETTE: Build 256-color palette from all pixels
//  6. ENCODE: LZW compress each frame using palette indices
//  7. WRITE: Generate GIF89a with validated structure
//
//  DATA FLOW
//  ---------
//  [Camera Frames: Any Resolution]
//       │
//       ▼
//  [CenterCropper: Square Frames]
//       │
//       ▼
//  [Frame81Resizer: 81×81 Frames]
//       │
//       ▼
//  [SpatialIndexer: Bucket Assignment]
//       │
//       ├──▶ [Palette: 256 Colors]
//       │
//       ▼
//  [GIF81Writer: 81×81×81 GIF]
//       │
//       ▼
//  [Output File: ≈300KB GIF]
//
//  VOXEL INTEGRATION
//  ------------------
//  After GIF creation, the 81×81×81 structure can be:
//  - Rendered as a 3D voxel cube (VoxelRenderer)
//  - Analyzed frame-by-frame (81 Z-slices)
//  - Color-swapped using PaletteSwapper
//
//  USAGE
//  -----
//  let pipeline = GIF81Pipeline()
//  let gifURL = try await pipeline.generateGIF(from: frames, outputURL: destination)
//
//  ============================================================================

import Foundation
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "GIF81Pipeline")

// MARK: - GIF81 Pipeline

/// Orchestrates the complete 81×81×81 GIF generation pipeline.
/// This is the main entry point for creating composable GIFs from camera frames.
///
/// ## Pipeline Overview
/// The pipeline transforms camera frames into a structured GIF format:
/// 1. **Crop** - Extract square region from center
/// 2. **Resize** - Scale to exactly 81×81 pixels
/// 3. **Index** - Map colors to luminance-ordered buckets (0-255)
/// 4. **Build Palette** - Calculate best color for each bucket
/// 5. **Write GIF** - Generate validated GIF89a file
///
/// ## Example
/// ```swift
/// let pipeline = GIF81Pipeline()
/// let gifURL = try await pipeline.generateGIF(
///     from: cameraFrames,
///     outputURL: documentsURL.appending(path: "capture.gif")
/// )
/// ```
@available(iOS 26.0, *)
public final class GIF81Pipeline: @unchecked Sendable {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ════════════════════════════════════════════════════════════════════════

    /// Pipeline configuration options
    public struct Configuration: Sendable {
        /// Interpolation quality for resizing (default: high)
        public var resizeQuality: CenterCropper.InterpolationQuality

        /// Process frames in parallel (default: true)
        public var parallelProcessing: Bool

        /// Emit progress callbacks (default: true)
        public var reportProgress: Bool

        public init(
            resizeQuality: CenterCropper.InterpolationQuality = .high,
            parallelProcessing: Bool = true,
            reportProgress: Bool = true
        ) {
            self.resizeQuality = resizeQuality
            self.parallelProcessing = parallelProcessing
            self.reportProgress = reportProgress
        }

        /// Default configuration for best quality
        public static let `default` = Configuration()

        /// Fast configuration for previews
        public static let fast = Configuration(
            resizeQuality: .low,
            parallelProcessing: true,
            reportProgress: false
        )
    }

    /// Progress callback type
    public typealias ProgressHandler = @Sendable (PipelineProgress) -> Void

    /// Pipeline progress stages
    public enum PipelineStage: String, Sendable {
        case cropping = "Cropping frames"
        case resizing = "Resizing to 81×81"
        case indexing = "Indexing colors"
        case buildingPalette = "Building palette"
        case compressing = "Compressing LZW"
        case writing = "Writing GIF"
        case validating = "Validating output"
        case complete = "Complete"
    }

    /// Progress information
    public struct PipelineProgress: Sendable {
        public let stage: PipelineStage
        public let framesProcessed: Int
        public let totalFrames: Int
        public let percentComplete: Double

        public var description: String {
            return "\(stage.rawValue): \(framesProcessed)/\(totalFrames) (\(Int(percentComplete * 100))%)"
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ════════════════════════════════════════════════════════════════════════

    private let configuration: Configuration
    private var progressHandler: ProgressHandler?

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ════════════════════════════════════════════════════════════════════════

    /// Create a new pipeline with the given configuration.
    ///
    /// - Parameter configuration: Pipeline settings (default: .default)
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Set a progress handler to receive updates during processing.
    ///
    /// - Parameter handler: Closure called with progress updates
    public func setProgressHandler(_ handler: @escaping ProgressHandler) {
        self.progressHandler = handler
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Main Pipeline
    // ════════════════════════════════════════════════════════════════════════

    /// Generate a complete 81×81×81 GIF from camera frames.
    ///
    /// This is the primary entry point for GIF creation. It:
    /// 1. Validates input (exactly 81 frames required)
    /// 2. Crops and resizes all frames to 81×81
    /// 3. Builds a luminance-ordered 256-color palette
    /// 4. Indexes all pixels using spatial buckets
    /// 5. Writes the final GIF with LZW compression
    ///
    /// - Parameters:
    ///   - frames: Array of exactly 81 CGImage frames
    ///   - outputURL: Destination URL for the GIF file
    /// - Returns: URL of the generated GIF
    /// - Throws: `PipelineError` if generation fails
    public func generateGIF(
        from frames: [CGImage],
        outputURL: URL
    ) async throws -> URL {

        let startTime = Date()

        // ──────────────────────────────────────────────────────────────────
        // VALIDATION
        // ──────────────────────────────────────────────────────────────────

        guard frames.count == 81 else {
            throw PipelineError.wrongFrameCount(expected: 81, actual: frames.count)
        }

        logger.info("GIF81Pipeline: Starting generation of 81×81×81 GIF")

        // ──────────────────────────────────────────────────────────────────
        // STEP 1 & 2: CROP AND RESIZE
        // ──────────────────────────────────────────────────────────────────

        reportProgress(.cropping, framesProcessed: 0, totalFrames: 81)

        let resizedFrames: [CGImage]
        if configuration.parallelProcessing {
            resizedFrames = try await CenterCropper.cropAndResizeBatch(
                frames,
                to: 81,
                quality: configuration.resizeQuality
            )
        } else {
            resizedFrames = try CenterCropper.cropAndResizeSequential(
                frames,
                to: 81,
                quality: configuration.resizeQuality,
                progress: { [weak self] processed, total in
                    self?.reportProgress(.resizing, framesProcessed: processed, totalFrames: total)
                }
            )
        }

        reportProgress(.resizing, framesProcessed: 81, totalFrames: 81)
        logger.debug("GIF81Pipeline: Cropped and resized 81 frames to 81×81")

        // ──────────────────────────────────────────────────────────────────
        // STEP 3: COLLECT ALL PIXELS
        // ──────────────────────────────────────────────────────────────────

        reportProgress(.indexing, framesProcessed: 0, totalFrames: 81)

        var allPixels = [(r: UInt8, g: UInt8, b: UInt8)]()
        allPixels.reserveCapacity(81 * 81 * 81)  // 531,441 pixels

        var framePixelArrays = [[(r: UInt8, g: UInt8, b: UInt8)]]()
        framePixelArrays.reserveCapacity(81)

        for (i, frame) in resizedFrames.enumerated() {
            let pixels = try SpatialIndexer.extractPixels(from: frame)
            framePixelArrays.append(pixels)
            allPixels.append(contentsOf: pixels)

            if (i + 1) % 10 == 0 {
                reportProgress(.indexing, framesProcessed: i + 1, totalFrames: 81)
            }
        }

        logger.debug("GIF81Pipeline: Collected \(allPixels.count) pixels from 81 frames")

        // ──────────────────────────────────────────────────────────────────
        // STEP 4: BUILD PALETTE
        // ──────────────────────────────────────────────────────────────────

        reportProgress(.buildingPalette, framesProcessed: 0, totalFrames: 1)

        let palette = SpatialIndexer.buildPalette(from: allPixels)

        reportProgress(.buildingPalette, framesProcessed: 1, totalFrames: 1)
        logger.debug("GIF81Pipeline: Built 256-color luminance-ordered palette")

        // ──────────────────────────────────────────────────────────────────
        // STEP 5: INDEX ALL FRAMES
        // ──────────────────────────────────────────────────────────────────

        reportProgress(.compressing, framesProcessed: 0, totalFrames: 81)

        var indexedFrames = [[UInt8]]()
        indexedFrames.reserveCapacity(81)

        for (i, pixels) in framePixelArrays.enumerated() {
            let indices = SpatialIndexer.indexPixels(pixels)
            indexedFrames.append(indices)

            if (i + 1) % 10 == 0 {
                reportProgress(.compressing, framesProcessed: i + 1, totalFrames: 81)
            }
        }

        logger.debug("GIF81Pipeline: Indexed all 81 frames")

        // ──────────────────────────────────────────────────────────────────
        // STEP 6: WRITE GIF
        // ──────────────────────────────────────────────────────────────────

        reportProgress(.writing, framesProcessed: 0, totalFrames: 1)

        try GIF81Writer.write(
            frames: indexedFrames,
            palette: palette,
            to: outputURL
        )

        reportProgress(.writing, framesProcessed: 1, totalFrames: 1)

        // ──────────────────────────────────────────────────────────────────
        // STEP 7: VALIDATE
        // ──────────────────────────────────────────────────────────────────

        reportProgress(.validating, framesProcessed: 0, totalFrames: 1)

        let validation = try GIF81Validator.validate(at: outputURL)
        guard validation.isValid else {
            throw PipelineError.validationFailed(validation.issues)
        }

        reportProgress(.validating, framesProcessed: 1, totalFrames: 1)

        // ──────────────────────────────────────────────────────────────────
        // COMPLETE
        // ──────────────────────────────────────────────────────────────────

        let duration = Date().timeIntervalSince(startTime)
        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        let fileSizeKB = Double(fileSize) / 1024.0

        logger.info("GIF81Pipeline: Generated \(String(format: "%.1f", fileSizeKB))KB GIF in \(String(format: "%.2f", duration))s")

        reportProgress(.complete, framesProcessed: 81, totalFrames: 81)

        return outputURL
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Operations
    // ════════════════════════════════════════════════════════════════════════

    /// Apply a new palette to an existing GIF.
    ///
    /// This swaps the 768-byte Global Color Table without re-encoding LZW data.
    ///
    /// - Parameters:
    ///   - gifURL: URL of the existing GIF
    ///   - palette: New 256-color palette
    /// - Throws: `PaletteSwapper.SwapperError` if swap fails
    public func applyPalette(
        _ palette: [(r: UInt8, g: UInt8, b: UInt8)],
        to gifURL: URL
    ) throws {
        try PaletteSwapper.swapPalette(at: gifURL, with: palette)
    }

    /// Transfer the palette from one GIF to another.
    ///
    /// - Parameters:
    ///   - sourceGIF: GIF to extract palette from
    ///   - targetGIF: GIF to apply palette to
    /// - Throws: Error if either operation fails
    public func transferPalette(from sourceGIF: URL, to targetGIF: URL) throws {
        let palette = try PaletteSwapper.extractPalette(from: sourceGIF)
        try PaletteSwapper.swapPalette(at: targetGIF, with: palette)
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Progress Reporting
    // ════════════════════════════════════════════════════════════════════════

    private func reportProgress(
        _ stage: PipelineStage,
        framesProcessed: Int,
        totalFrames: Int
    ) {
        guard configuration.reportProgress, let handler = progressHandler else { return }

        let stageWeight: Double
        let stageStart: Double

        switch stage {
        case .cropping:      stageWeight = 0.15; stageStart = 0.0
        case .resizing:      stageWeight = 0.15; stageStart = 0.15
        case .indexing:      stageWeight = 0.20; stageStart = 0.30
        case .buildingPalette: stageWeight = 0.05; stageStart = 0.50
        case .compressing:   stageWeight = 0.30; stageStart = 0.55
        case .writing:       stageWeight = 0.10; stageStart = 0.85
        case .validating:    stageWeight = 0.05; stageStart = 0.95
        case .complete:      stageWeight = 0.0;  stageStart = 1.0
        }

        let stageProgress = totalFrames > 0 ? Double(framesProcessed) / Double(totalFrames) : 1.0
        let overallProgress = stageStart + (stageProgress * stageWeight)

        let progress = PipelineProgress(
            stage: stage,
            framesProcessed: framesProcessed,
            totalFrames: totalFrames,
            percentComplete: min(1.0, overallProgress)
        )

        handler(progress)
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
extension GIF81Pipeline {

    /// Errors that can occur during pipeline execution
    public enum PipelineError: Error, LocalizedError {
        case wrongFrameCount(expected: Int, actual: Int)
        case cropFailed(frameIndex: Int, error: Error)
        case indexingFailed(frameIndex: Int, error: Error)
        case compressionFailed(error: Error)
        case validationFailed([String])
        case writeFailed(error: Error)

        public var errorDescription: String? {
            switch self {
            case .wrongFrameCount(let expected, let actual):
                return "Pipeline requires exactly \(expected) frames, got \(actual)"
            case .cropFailed(let index, let error):
                return "Failed to crop frame \(index): \(error.localizedDescription)"
            case .indexingFailed(let index, let error):
                return "Failed to index frame \(index): \(error.localizedDescription)"
            case .compressionFailed(let error):
                return "LZW compression failed: \(error.localizedDescription)"
            case .validationFailed(let errors):
                return "GIF validation failed: \(errors.joined(separator: ", "))"
            case .writeFailed(let error):
                return "Failed to write GIF: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Debug Helpers

@available(iOS 26.0, *)
extension GIF81Pipeline {

    /// Print pipeline statistics for debugging.
    public static func printPipelineInfo() {
        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║  GIF81 PIPELINE - Composable 81×81×81 GIF Generation          ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  HARD CONSTRAINTS:                                            ║")
        print("║    • Width:       81 pixels                                   ║")
        print("║    • Height:      81 pixels                                   ║")
        print("║    • Frames:      81 frames                                   ║")
        print("║    • Palette:     256 colors (global)                         ║")
        print("║    • Frame delay: 3 centiseconds (~33 FPS)                    ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  PIPELINE STEPS:                                              ║")
        print("║    1. Crop to square (center crop)                            ║")
        print("║    2. Resize to 81×81 (Lanczos)                               ║")
        print("║    3. Index colors (8×8×4 luminance buckets)                  ║")
        print("║    4. Build palette (average per bucket)                      ║")
        print("║    5. LZW compress (sub-blocks ≤255 bytes)                    ║")
        print("║    6. Write GIF89a (validated)                                ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  COMPOSABILITY:                                               ║")
        print("║    • Palette swappable without re-encoding                    ║")
        print("║    • 768 bytes at offset 13                                   ║")
        print("║    • Luminance order = meaningful transfers                   ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  VOXEL VISUALIZATION:                                         ║")
        print("║    • 81³ = 531,441 voxels                                     ║")
        print("║    • Each frame = Z-slice                                     ║")
        print("║    • Render as 3D cube in Metal                               ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
    }
}
