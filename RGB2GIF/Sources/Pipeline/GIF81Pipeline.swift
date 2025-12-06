//
//  GIF81Pipeline.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  MVP0: 729-CELL-DRIVEN GIF81 PIPELINE                                     ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  NEW ARCHITECTURE (729× faster palette generation):                       ║
//  ║                                                                           ║
//  ║  1. RESIZE    : 81 frames (any size) → 81 frames (81×81 each)             ║
//  ║  2. TENSOR    : Build TensorCube729 (9×9×9 weighted centroids)            ║
//  ║  3. QUANTIZE  : 729 colors → Octree → 256-color palette                   ║
//  ║  4. RECOLOR   : Map 531,441 pixels to nearest palette colors              ║
//  ║  5. COMPRESS  : LZW encode each frame's indices                           ║
//  ║  6. WRITE     : Assemble GIF89a                                           ║
//  ║                                                                           ║
//  ║  KEY INSIGHT: Palette is built from 729 weighted centroids,               ║
//  ║               NOT from all 531,441 pixels. This is intentional.           ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import QuartzCore
import os.log

private let pipelineLogger = Logger(subsystem: "com.rgb2gif", category: "GIF81Pipeline")

// MARK: - Pipeline Result

@available(iOS 26.0, *)
public struct GIF81Result: Sendable {
    public let gifData: Data
    public let gifURL: URL?
    public let fileSize: Int
    public let frameCount: Int
    public let processingTimeMs: Double
    public let palette: [UInt32]
    public let tensorStats: TensorStatistics

    public var fileSizeKB: Double { Double(fileSize) / 1024.0 }
}

// MARK: - Pipeline Configuration

@available(iOS 26.0, *)
public struct GIF81Config: Sendable {
    public static let frameCount = 81
    public static let dimension = 81
    public static let paletteSize = 256

    /// Frame delay in centiseconds (3 = ~33fps)
    public var frameDelay: UInt16 = 3
    /// Loop count (0 = infinite)
    public var loopCount: UInt16 = 0
    /// Save to file URL (nil = only return Data)
    public var outputURL: URL? = nil

    public init() {}
}

// MARK: - GIF81Pipeline

@available(iOS 26.0, *)
public struct GIF81Pipeline {

    // MARK: - Main Entry Point

    /// Process 81 frames into a GIF using STEP-BY-STEP CBOR-VERIFIED pipeline
    /// - Parameters:
    ///   - frames: 81 CGImages (any size, BGRA format from camera)
    ///   - config: Pipeline configuration
    ///   - debugExport: If true, exports all intermediate data to CBOR files
    /// - Returns: GIF result with data and statistics
    ///
    /// ## NEW ARCHITECTURE (Step-by-Step with Explicit Format Conversion)
    ///
    /// The pipeline now uses explicit BGRA→RGB conversion to eliminate format confusion:
    ///
    /// ```
    /// L0_raw     → Original camera frames (BGRA, any size)
    /// L1_cropped → Center-cropped squares (BGRA)
    /// L2_frames  → Resized 81×81 RGB (explicit BGRA→RGB!)
    /// L3_tensor  → 729 weighted centroids from RGB data
    /// L4_palette → 256-color palette
    /// L5_indices → Palette indices for each pixel
    /// L6_output  → Final GIF
    /// ```
    ///
    /// The key fix is in L2_frames: instead of relying on CGContext.draw() to
    /// convert formats, we explicitly read BGRA bytes and write RGB bytes using
    /// `FrameFormatConverter.resizeBGRAToRGB()`.
    public static func process(
        frames: [CGImage],
        config: GIF81Config = GIF81Config(),
        debugExport: Bool = true  // MVP0: Always export CBOR for debugging
    ) async throws -> GIF81Result {
        let startTime = CACurrentMediaTime()

        pipelineLogger.info("╔══════════════════════════════════════════════════════════╗")
        pipelineLogger.info("║  GIF81 PIPELINE v2 - STEP-BY-STEP CBOR-VERIFIED         ║")
        pipelineLogger.info("║  EXPLICIT BGRA→RGB CONVERSION                            ║")
        pipelineLogger.info("╚══════════════════════════════════════════════════════════╝")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE 0: VALIDATE INPUT
        // ═══════════════════════════════════════════════════════════════════════
        guard frames.count == GIF81Config.frameCount else {
            throw RGB2GIFError.wrongFrameCount(got: frames.count, expected: GIF81Config.frameCount)
        }
        // MVP0 VERIFICATION: Must have exactly 81 input frames
        precondition(frames.count == 81, "MVP0: Pipeline requires exactly 81 frames, got \(frames.count)")
        pipelineLogger.info("Stage 0: Validated \(frames.count) input frames")

        // Create CBOR session for all exports
        let session = try CBORSessionManager()
        let frameExporter = CBORFrameExporter(session: session)
        pipelineLogger.info("CBOR Session: \(session.sessionID)")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L0_raw: Export original camera frames (BGRA, any size)
        // ═══════════════════════════════════════════════════════════════════════
        pipelineLogger.info("Stage L0_raw: Exporting original camera frames...")
        _ = try frameExporter.exportAllRawFrames(frames)
        pipelineLogger.info("Stage L0_raw: ✓ Exported 81 raw frames + PNGs")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L1_cropped: SKIPPED - CGImage.cropping() causes data corruption!
        // ═══════════════════════════════════════════════════════════════════════
        // NOTE: We no longer use a separate crop stage. The L2_frames stage now
        // does crop+resize in ONE operation using safeCropAndResizeToRGB().
        // This avoids CGImage.cropping() which creates CGImages with shared data
        // that CoreGraphics fails to render correctly.
        pipelineLogger.info("Stage L1_cropped: ⏭️ SKIPPED (crop+resize combined in L2)")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L2_frames: Crop + Resize to 81×81 + BGRA→RGB in ONE operation
        // This is the CRITICAL stage - does crop+resize without CGImage.cropping()
        // ═══════════════════════════════════════════════════════════════════════
        pipelineLogger.info("Stage L2_frames: Crop+resize to 81×81 RGB (single operation)...")
        // CRITICAL: Pass ORIGINAL frames, not cropped! safeCropAndResizeToRGB handles everything.
        let (rgbFrames, _) = try frameExporter.exportAllResizedRGBFrames(frames)
        pipelineLogger.info("Stage L2_frames: ✓ Exported 81 RGB frames + PNGs")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L3_tensor: Build TensorCube729 from RGB Data (no format confusion!)
        // ═══════════════════════════════════════════════════════════════════════
        pipelineLogger.info("Stage L3_tensor: Building tensor from RGB data...")
        let tensor = try TensorCube729(rgbFrames: rgbFrames)
        let tensorStats = tensor.statistics()
        pipelineLogger.info("Stage L3_tensor: ✓ Built TensorCube729 (\(tensorStats.nonZeroCells) active cells)")

        // Export tensor cells
        let tensorExporter = CBORTensorExporter(session: session)
        _ = try tensorExporter.exportAllCells(from: tensor)
        pipelineLogger.info("Stage L3_tensor: ✓ Exported 729 tensor cells + summary")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L4_palette: Quantize SAMPLED PIXELS to 256-color palette
        // ═══════════════════════════════════════════════════════════════════════
        // FIX: Use actual sampled pixels, NOT averaged centroids!
        // Averaging destroys color diversity (red + cyan = gray).
        //
        // We sample the CENTER PIXEL of each 9×9×9 cell = 729 actual colors
        // This preserves the full color gamut while still being fast.
        //
        // MVP1 (future): Will use dual KataGo Q-K-V attention here
        // See: Sources/KataGo/DualPlayerAttention.swift
        // ═══════════════════════════════════════════════════════════════════════
        pipelineLogger.info("Stage L4_palette: Sampling actual pixels for palette...")
        let quantizer = OctreeColorQuantizer()

        // Sample center pixel from each of the 729 cells (9×9×9 grid)
        let sampledPixels = sampleCenterPixels(from: rgbFrames)
        // MVP0 VERIFICATION: Must sample exactly 729 center pixels (9×9×9 grid)
        precondition(sampledPixels.count == 729, "MVP0: Must sample exactly 729 pixels, got \(sampledPixels.count)")
        pipelineLogger.info("Stage L4_palette: Sampled \(sampledPixels.count) actual pixels (not averages)")

        let palette = await quantizer.quantizeFromPixels(sampledPixels, maxColors: GIF81Config.paletteSize)
        // MVP0 VERIFICATION: Palette must have exactly 256 colors
        precondition(palette.count == 256, "MVP0: Palette must have 256 colors, got \(palette.count)")
        pipelineLogger.info("Stage L4_palette: ✓ Generated \(palette.count)-color palette")

        // Export palette
        let paletteExporter = CBORPaletteExporter(session: session)
        _ = try paletteExporter.exportPalette(palette)
        let mapping = paletteExporter.computeMapping(tensor: tensor, palette: palette)
        _ = try paletteExporter.exportMapping(mapping)
        pipelineLogger.info("Stage L4_palette: ✓ Exported palette + mapping")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L5_indices: Map RGB pixels to palette indices
        // ═══════════════════════════════════════════════════════════════════════
        pipelineLogger.info("Stage L5_indices: Mapping pixels to palette indices...")
        let frameIndices = try mapRGBFramesToPalette(rgbFrames, palette: palette)
        // MVP0 VERIFICATION: Must produce 81 frames of palette indices
        precondition(frameIndices.count == 81, "MVP0: Must have 81 frames of indices, got \(frameIndices.count)")
        // MVP0 VERIFICATION: Each frame must have 6561 indices (81×81 pixels)
        precondition(frameIndices.allSatisfy { $0.count == 6561 }, "MVP0: Each frame must have 6561 indices (81×81)")
        pipelineLogger.info("Stage L5_indices: ✓ Mapped \(81 * 81 * 81) pixels to indices")

        // Export indices
        let indicesExporter = CBORIndicesExporter(session: session)
        _ = try indicesExporter.exportAllFrameIndices(frameIndices)
        pipelineLogger.info("Stage L5_indices: ✓ Exported 81 index files")

        // ═══════════════════════════════════════════════════════════════════════
        // STAGE L6_output: LZW compress + assemble GIF89a
        // ═══════════════════════════════════════════════════════════════════════
        pipelineLogger.info("Stage L6_output: Compressing and writing GIF...")
        let compressedFrames = try compressFrames(frameIndices)
        // MVP0 VERIFICATION: Must produce 81 LZW-compressed frames
        precondition(compressedFrames.count == 81, "MVP0: Must have 81 compressed frames, got \(compressedFrames.count)")
        pipelineLogger.info("Stage L6_output: ✓ LZW compressed \(compressedFrames.count) frames")

        var gifConfig = GIFWriter.Config()
        gifConfig.width = UInt16(GIF81Config.dimension)
        gifConfig.height = UInt16(GIF81Config.dimension)
        gifConfig.frameDelay = config.frameDelay
        gifConfig.loopCount = config.loopCount

        let gifData = try GIFWriter.write(
            palette: palette,
            compressedFrames: compressedFrames,
            config: gifConfig
        )
        pipelineLogger.info("Stage L6_output: ✓ Assembled GIF (\(gifData.count) bytes)")

        // Save GIF to output directory
        try gifData.write(to: session.gifOutputURL)
        pipelineLogger.info("Stage L6_output: ✓ Saved to \(session.gifOutputURL.lastPathComponent)")

        // Optional: Also save to user-specified location
        var outputURL: URL? = session.gifOutputURL
        if let url = config.outputURL {
            try gifData.write(to: url)
            outputURL = url
            pipelineLogger.info("Also saved to: \(url.lastPathComponent)")
        }

        // Write manifest
        let manifest = CBORManifest(sessionID: session.sessionID)
        try manifest.write(to: session.manifestURL)

        let processingTime = (CACurrentMediaTime() - startTime) * 1000

        pipelineLogger.info("╔══════════════════════════════════════════════════════════╗")
        pipelineLogger.info("║  COMPLETE: \(String(format: "%.1f", processingTime))ms, \(String(format: "%.1f", Double(gifData.count) / 1024))KB            ║")
        pipelineLogger.info("║  SESSION: \(session.sessionID)                           ║")
        pipelineLogger.info("║  VERIFY: Check L2_frames/*.png for correct colors!       ║")
        pipelineLogger.info("╚══════════════════════════════════════════════════════════╝")

        return GIF81Result(
            gifData: gifData,
            gifURL: outputURL,
            fileSize: gifData.count,
            frameCount: GIF81Config.frameCount,
            processingTimeMs: processingTime,
            palette: palette,
            tensorStats: tensorStats
        )
    }

    // MARK: - Stage 2: Resize Frames

    private static func resizeFrames(_ frames: [CGImage]) throws -> [CGImage] {
        let dim = GIF81Config.dimension
        var resized: [CGImage] = []
        resized.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard let resizedFrame = centerCropAndResize(frame, to: dim) else {
                pipelineLogger.error("Failed to resize frame \(index)")
                throw RGB2GIFError.frameResizeFailed
            }
            resized.append(resizedFrame)
        }

        return resized
    }

    // Debug counter for resize diagnostics
    private static var resizeDebugCounter = 0

    /// Center-crop to square, then resize to target dimension
    /// Uses CPU-allocated buffer to ensure pixel data is fully accessible
    private static func centerCropAndResize(_ image: CGImage, to size: Int) -> CGImage? {
        let frameIndex = resizeDebugCounter
        resizeDebugCounter += 1

        let srcWidth = image.width
        let srcHeight = image.height

        // Determine crop rect (center square)
        let cropSize = min(srcWidth, srcHeight)
        let cropX = (srcWidth - cropSize) / 2
        let cropY = (srcHeight - cropSize) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)

        // Crop
        guard let cropped = image.cropping(to: cropRect) else {
            print("❌ [RESIZE \(frameIndex)] cropping FAILED")
            return nil
        }

        // Resize with CPU-allocated buffer for guaranteed pixel access
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = size * 4
        let bufferSize = bytesPerRow * size
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)

        // Allocate our own buffer to ensure CPU-accessible pixel data
        var pixelBuffer = [UInt8](repeating: 0, count: bufferSize)

        guard let context = CGContext(
            data: &pixelBuffer,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            print("❌ [RESIZE \(frameIndex)] CGContext creation FAILED")
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))

        // DEBUG: Verify buffer was actually written to (check first, middle, last rows)
        if frameIndex == 0 || frameIndex == 40 || frameIndex == 80 {
            let firstRowStart = 0
            let midRowStart = (size / 2) * bytesPerRow
            let lastRowStart = (size - 1) * bytesPerRow

            let firstPixel = (pixelBuffer[firstRowStart], pixelBuffer[firstRowStart+1], pixelBuffer[firstRowStart+2])
            let midPixel = (pixelBuffer[midRowStart], pixelBuffer[midRowStart+1], pixelBuffer[midRowStart+2])
            let lastPixel = (pixelBuffer[lastRowStart], pixelBuffer[lastRowStart+1], pixelBuffer[lastRowStart+2])

            print("🔍 [RESIZE \(frameIndex)] src=\(srcWidth)×\(srcHeight) → \(size)×\(size) bufferSize=\(bufferSize)")
            print("🔍 [RESIZE \(frameIndex)] firstRow RGB=\(firstPixel) midRow RGB=\(midPixel) lastRow RGB=\(lastPixel)")

            // Check if buffer is mostly zeros (indicates draw failed)
            let nonZeroCount = pixelBuffer.prefix(1000).filter { $0 != 0 }.count
            if nonZeroCount < 100 {
                print("⚠️ [RESIZE \(frameIndex)] WARNING: Buffer appears mostly EMPTY! nonZeroIn1000=\(nonZeroCount)")
            }
        }

        // Create CGImage from our CPU buffer with known data layout
        let bufferData = Data(pixelBuffer)
        guard let provider = CGDataProvider(data: bufferData as CFData) else {
            print("❌ [RESIZE \(frameIndex)] CGDataProvider creation FAILED")
            return nil
        }

        // DEBUG: Verify the Data was created correctly
        if frameIndex == 0 {
            print("🔍 [RESIZE \(frameIndex)] Data size=\(bufferData.count) (expected \(bufferSize))")
        }

        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Stage 5: Map Frames to Palette

    private static func mapFramesToPalette(
        _ frames: [CGImage],
        palette: [UInt32]
    ) throws -> [[UInt8]] {
        // Build lookup table for fast nearest-neighbor search
        let lookup = buildPaletteLookup(palette: palette)

        var allIndices: [[UInt8]] = []
        allIndices.reserveCapacity(frames.count)

        for (frameIndex, frame) in frames.enumerated() {
            guard let pixelData = frame.dataProvider?.data,
                  let data = CFDataGetBytePtr(pixelData) else {
                print("❌ [FRAME \(frameIndex)] pixelData extraction FAILED")
                throw RGB2GIFError.pixelExtractionFailed
            }

            let width = frame.width
            let height = frame.height
            let bytesPerRow = frame.bytesPerRow
            let bytesPerPixel = frame.bitsPerPixel / 8
            let dataLength = CFDataGetLength(pixelData)
            let expectedLength = bytesPerRow * height

            // DEBUG: Print frame data diagnostics (first, middle, last frames only)
            if frameIndex == 0 || frameIndex == 40 || frameIndex == 80 {
                print("📊 [FRAME \(frameIndex)] dimensions=\(width)×\(height) bytesPerRow=\(bytesPerRow) bytesPerPixel=\(bytesPerPixel)")
                print("📊 [FRAME \(frameIndex)] dataLength=\(dataLength) expectedLength=\(expectedLength) match=\(dataLength >= expectedLength ? "✅" : "❌ SHORT BY \(expectedLength - dataLength)")")
            }

            var frameIndices = [UInt8](repeating: 0, count: width * height)
            var skippedPixels = 0

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    guard offset + 2 < dataLength else {
                        skippedPixels += 1
                        continue
                    }

                    let r = data[offset]
                    let g = data[offset + 1]
                    let b = data[offset + 2]

                    // Use lookup table for fast index finding
                    let ri = Int(r) >> 4  // 0-15
                    let gi = Int(g) >> 4
                    let bi = Int(b) >> 4

                    frameIndices[y * width + x] = lookup[ri][gi][bi]
                }
            }

            // DEBUG: Report skipped pixels
            if skippedPixels > 0 {
                print("⚠️ [FRAME \(frameIndex)] SKIPPED \(skippedPixels) pixels due to data truncation!")
            }

            allIndices.append(frameIndices)
        }

        return allIndices
    }

    /// Build 16×16×16 lookup table for fast palette matching
    private static func buildPaletteLookup(palette: [UInt32]) -> [[[UInt8]]] {
        var lookup = [[[UInt8]]](
            repeating: [[UInt8]](
                repeating: [UInt8](repeating: 0, count: 16),
                count: 16
            ),
            count: 16
        )

        // For each bucket in the 16×16×16 grid
        for ri in 0..<16 {
            for gi in 0..<16 {
                for bi in 0..<16 {
                    // Representative color for this bucket
                    let r = (ri << 4) + 8
                    let g = (gi << 4) + 8
                    let b = (bi << 4) + 8

                    // Find nearest palette entry
                    var minDist = Int.max
                    var bestIndex: UInt8 = 0

                    for (i, color) in palette.enumerated() {
                        let pr = Int((color >> 16) & 0xFF)
                        let pg = Int((color >> 8) & 0xFF)
                        let pb = Int(color & 0xFF)

                        let dr = r - pr
                        let dg = g - pg
                        let db = b - pb
                        let dist = dr * dr + dg * dg + db * db

                        if dist < minDist {
                            minDist = dist
                            bestIndex = UInt8(i)
                        }
                    }

                    lookup[ri][gi][bi] = bestIndex
                }
            }
        }

        return lookup
    }

    // MARK: - Stage L5: Map RGB Data to Palette Indices (NEW)

    /// Map RGB Data frames to palette indices
    /// This works with pre-converted RGB data, ensuring correct color channel order
    private static func mapRGBFramesToPalette(
        _ rgbFrames: [Data],
        palette: [UInt32]
    ) throws -> [[UInt8]] {
        let lookup = buildPaletteLookup(palette: palette)

        var allIndices: [[UInt8]] = []
        allIndices.reserveCapacity(rgbFrames.count)

        for (frameIndex, rgbData) in rgbFrames.enumerated() {
            let pixelCount = rgbData.count / 3  // Each pixel is 3 bytes (RGB)
            guard pixelCount == GIF81Config.dimension * GIF81Config.dimension else {
                pipelineLogger.error("Frame \(frameIndex) has \(pixelCount) pixels, expected \(GIF81Config.dimension * GIF81Config.dimension)")
                throw RGB2GIFError.pixelExtractionFailed
            }

            var frameIndices = [UInt8](repeating: 0, count: pixelCount)

            for i in 0..<pixelCount {
                let offset = i * 3
                // RGB Data is guaranteed to be [R, G, B] order
                let r = rgbData[offset]
                let g = rgbData[offset + 1]
                let b = rgbData[offset + 2]

                // Use lookup table for fast index finding
                let ri = Int(r) >> 4  // 0-15
                let gi = Int(g) >> 4
                let bi = Int(b) >> 4

                frameIndices[i] = lookup[ri][gi][bi]
            }

            allIndices.append(frameIndices)
        }

        return allIndices
    }

    // MARK: - Stage L4: Sample Center Pixels for Palette

    /// Sample the center pixel of each 9×9×9 cell from RGB frames
    /// - Parameter rgbFrames: 81 RGB Data arrays (each 81×81×3 bytes)
    /// - Returns: 729 actual pixel colors (NOT averaged!)
    ///
    /// Each cell in the 9×9×9 grid covers:
    /// - Spatial: 9×9 pixels
    /// - Temporal: 9 frames
    ///
    /// We sample the CENTER pixel of each cell (offset 4 in each dimension)
    /// to get representative colors that preserve the full color gamut.
    private static func sampleCenterPixels(from rgbFrames: [Data]) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var samples: [(r: UInt8, g: UInt8, b: UInt8)] = []
        samples.reserveCapacity(729)

        let dim = GIF81Config.dimension  // 81
        let cellSize = 9  // 81 / 9 = 9 pixels per cell dimension
        let centerOffset = 4  // Middle of 0-8 range

        // For each temporal cell (9 cells covering 81 frames)
        for tCell in 0..<9 {
            let centerFrame = tCell * cellSize + centerOffset

            guard centerFrame < rgbFrames.count else { continue }
            let frameData = rgbFrames[centerFrame]

            // For each spatial cell in this frame
            for yCell in 0..<9 {
                let centerY = yCell * cellSize + centerOffset

                for xCell in 0..<9 {
                    let centerX = xCell * cellSize + centerOffset

                    // Get the RGB values at this center pixel
                    let pixelIndex = centerY * dim + centerX
                    let offset = pixelIndex * 3

                    if offset + 2 < frameData.count {
                        let r = frameData[offset]
                        let g = frameData[offset + 1]
                        let b = frameData[offset + 2]
                        samples.append((r, g, b))
                    } else {
                        // Fallback: black pixel if out of bounds
                        samples.append((0, 0, 0))
                    }
                }
            }
        }

        return samples
    }

    // MARK: - Stage L6: LZW Compression

    private static func compressFrames(_ frameIndices: [[UInt8]]) throws -> [[Data]] {
        var compressed: [[Data]] = []
        compressed.reserveCapacity(frameIndices.count)

        for indices in frameIndices {
            do {
                let subBlocks = try LZW_Optimized.compress(indices: indices, minCodeSize: 8)
                compressed.append(subBlocks)
            } catch {
                throw RGB2GIFError.compressionFailed(error.localizedDescription)
            }
        }

        return compressed
    }
}
