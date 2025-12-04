//
//  GIF81Pipeline.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF81 PIPELINE - THE 81×81×81 VOXEL CUBE TO GIF ENGINE                   ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  INPUT:  81 CGImage frames (any size, will be cropped/resized)            ║
//  ║  OUTPUT: GIF89a file + VoxelCube729 (for MVP1 game mechanics)             ║
//  ║                                                                           ║
//  ║  PIPELINE STAGES:                                                         ║
//  ║  ┌────────────────────────────────────────────────────────────────────┐   ║
//  ║  │ 1. VALIDATE     │ Verify exactly 81 frames received               │   ║
//  ║  ├────────────────────────────────────────────────────────────────────┤   ║
//  ║  │ 2. RESIZE       │ Crop center square → resize to 81×81            │   ║
//  ║  ├────────────────────────────────────────────────────────────────────┤   ║
//  ║  │ 3. QUANTIZE     │ Octree on ALL pixels → 256-color global palette │   ║
//  ║  ├────────────────────────────────────────────────────────────────────┤   ║
//  ║  │ 4. INDEX        │ Map each pixel to nearest palette color         │   ║
//  ║  ├────────────────────────────────────────────────────────────────────┤   ║
//  ║  │ 5. COMPRESS     │ LZW encode each frame's indices                 │   ║
//  ║  ├────────────────────────────────────────────────────────────────────┤   ║
//  ║  │ 6. WRITE        │ Assemble GIF89a with NETSCAPE loop extension    │   ║
//  ║  ├────────────────────────────────────────────────────────────────────┤   ║
//  ║  │ 7. VOXELIZE     │ Build VoxelCube729 for MVP1 (9×9×9 cells)       │   ║
//  ║  └────────────────────────────────────────────────────────────────────┘   ║
//  ║                                                                           ║
//  ║  MAGIC NUMBERS:                                                           ║
//  ║  • 81 = 3⁴ (frames, width, height)                                        ║
//  ║  • 256 = 2⁸ (palette colors)                                              ║
//  ║  • 729 = 9³ (VoxelCube729 cells)                                          ║
//  ║  • 531,441 = 81³ (total voxels)                                           ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import QuartzCore
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "GIF81Pipeline")

// MARK: - Pipeline Configuration

@available(iOS 26.0, *)
public struct GIF81Config {
    /// Number of frames (81 = 3⁴)
    public static let frameCount = 81

    /// Frame dimensions (81×81)
    public static let dimension = 81

    /// Palette size (256 = 2⁸)
    public static let paletteSize = 256

    /// Frame delay in centiseconds (3cs = 30fps, 4cs = 25fps)
    public var frameDelay: UInt16 = 3

    /// Whether to build VoxelCube729 for MVP1
    public var buildVoxelCube: Bool = true

    /// Loop count (0 = infinite)
    public var loopCount: UInt16 = 0

    public init() {}
}

// MARK: - Pipeline Result

@available(iOS 26.0, *)
public struct GIF81Result {
    /// URL of the generated GIF file
    public let gifURL: URL

    /// File size in bytes
    public let fileSize: Int

    /// Number of frames (should be 81)
    public let frameCount: Int

    /// Processing time in milliseconds
    public let processingTimeMs: Double

    /// The 256-color palette as ARGB values
    public let palette: [UInt32]

    /// Per-frame palette indices (81 arrays of 6561 indices each)
    public let frameIndices: [[UInt8]]

    /// VoxelCube729 for MVP1 game mechanics (nil if not built)
    public let voxelCube: VoxelCube729?

    /// Formatted file size string
    public var fileSizeString: String {
        if fileSize < 1024 {
            return "\(fileSize) B"
        } else if fileSize < 1024 * 1024 {
            return String(format: "%.1f KB", Double(fileSize) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(fileSize) / 1024.0 / 1024.0)
        }
    }
}

// MARK: - Pipeline Errors

@available(iOS 26.0, *)
public enum GIF81Error: LocalizedError {
    case wrongFrameCount(got: Int, expected: Int)
    case resizeFailed(frameIndex: Int, reason: String)
    case pixelExtractionFailed(frameIndex: Int)
    case quantizationFailed(reason: String)
    case paletteEmpty
    case compressionFailed(frameIndex: Int, reason: String)
    case fileWriteFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .wrongFrameCount(let got, let expected):
            return "Expected \(expected) frames, got \(got)"
        case .resizeFailed(let index, let reason):
            return "Failed to resize frame \(index): \(reason)"
        case .pixelExtractionFailed(let index):
            return "Failed to extract pixels from frame \(index)"
        case .quantizationFailed(let reason):
            return "Color quantization failed: \(reason)"
        case .paletteEmpty:
            return "Quantizer produced empty palette"
        case .compressionFailed(let index, let reason):
            return "LZW compression failed for frame \(index): \(reason)"
        case .fileWriteFailed(let reason):
            return "Failed to write GIF: \(reason)"
        }
    }
}

// MARK: - GIF81 Pipeline

@available(iOS 26.0, *)
public struct GIF81Pipeline {

    // MARK: - Public API

    /// Process 81 frames into a GIF with optional VoxelCube729
    /// - Parameters:
    ///   - frames: Exactly 81 CGImages (any size, will be center-cropped to square then resized)
    ///   - outputURL: Destination URL for the GIF file
    ///   - config: Pipeline configuration options
    /// - Returns: Result containing GIF URL, palette, indices, and optional VoxelCube729
    public static func process(
        frames: [CGImage],
        outputURL: URL,
        config: GIF81Config = GIF81Config()
    ) async throws -> GIF81Result {

        let startTime = CACurrentMediaTime()

        logger.info("╔════════════════════════════════════════════════════════════╗")
        logger.info("║  GIF81Pipeline - Starting (81×81×81 → GIF + Voxel729)      ║")
        logger.info("╚════════════════════════════════════════════════════════════╝")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 1: VALIDATE
        // ══════════════════════════════════════════════════════════════════════

        guard frames.count == GIF81Config.frameCount else {
            logger.error("❌ Wrong frame count: \(frames.count) (expected \(GIF81Config.frameCount))")
            throw GIF81Error.wrongFrameCount(got: frames.count, expected: GIF81Config.frameCount)
        }
        logger.info("✓ Stage 1: Validated \(frames.count) frames")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 2: RESIZE (Center crop to square, then resize to 81×81)
        // ══════════════════════════════════════════════════════════════════════

        let resizedFrames = try resizeAllFrames(frames)
        logger.info("✓ Stage 2: Resized all frames to \(GIF81Config.dimension)×\(GIF81Config.dimension)")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 3: QUANTIZE (Build global 256-color palette from ALL pixels)
        // ══════════════════════════════════════════════════════════════════════

        logger.info("  Stage 3: Quantizing \(GIF81Config.frameCount * GIF81Config.dimension * GIF81Config.dimension) pixels...")

        // Extract ALL pixels from ALL frames for global palette
        var allPixels: [(r: UInt8, g: UInt8, b: UInt8)] = []
        allPixels.reserveCapacity(GIF81Config.frameCount * GIF81Config.dimension * GIF81Config.dimension)

        for (index, frame) in resizedFrames.enumerated() {
            guard let pixels = extractPixelsRGBA(from: frame) else {
                throw GIF81Error.pixelExtractionFailed(frameIndex: index)
            }
            allPixels.append(contentsOf: pixels)
        }

        // Build Octree from ALL pixels
        let quantizer = OctreeColorQuantizer()
        let palette = await quantizer.quantizeFromPixels(allPixels, maxColors: GIF81Config.paletteSize)

        guard !palette.isEmpty else {
            throw GIF81Error.paletteEmpty
        }

        logger.info("✓ Stage 3: Generated \(palette.count)-color global palette")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 4: INDEX (Map each pixel to nearest palette entry)
        // ══════════════════════════════════════════════════════════════════════

        logger.info("  Stage 4: Mapping pixels to palette indices...")

        var frameIndices: [[UInt8]] = []
        frameIndices.reserveCapacity(GIF81Config.frameCount)

        // Build lookup table for faster palette matching
        let lookupTable = buildPaletteLookup(palette: palette)

        for (index, frame) in resizedFrames.enumerated() {
            guard let pixels = extractPixelsRGBA(from: frame) else {
                throw GIF81Error.pixelExtractionFailed(frameIndex: index)
            }

            let indices = mapPixelsToIndices(pixels: pixels, palette: palette, lookup: lookupTable)
            frameIndices.append(indices)

            if index % 20 == 0 {
                logger.debug("  Indexed frame \(index)/\(GIF81Config.frameCount)")
            }
        }

        logger.info("✓ Stage 4: Indexed all frames")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 5: COMPRESS (LZW encode each frame)
        // ══════════════════════════════════════════════════════════════════════

        logger.info("  Stage 5: LZW compressing frames...")

        var compressedFrames: [Data] = []
        compressedFrames.reserveCapacity(GIF81Config.frameCount)

        for (index, indices) in frameIndices.enumerated() {
            do {
                let subBlocks = try LZW_Optimized.compress(indices: indices, minCodeSize: 8)
                var frameData = Data()
                for block in subBlocks {
                    frameData.append(contentsOf: block)
                }
                compressedFrames.append(frameData)
            } catch {
                throw GIF81Error.compressionFailed(frameIndex: index, reason: error.localizedDescription)
            }

            if index % 20 == 0 {
                logger.debug("  Compressed frame \(index)/\(GIF81Config.frameCount)")
            }
        }

        logger.info("✓ Stage 5: Compressed all frames")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 6: WRITE GIF
        // ══════════════════════════════════════════════════════════════════════

        logger.info("  Stage 6: Writing GIF89a file...")

        // Convert palette to RGB arrays for GIF writer
        let rgbPalette: [[UInt8]] = palette.map { argb in
            [
                UInt8((argb >> 16) & 0xFF),  // R
                UInt8((argb >> 8) & 0xFF),   // G
                UInt8(argb & 0xFF)           // B
            ]
        }

        try writeGIF89a(
            to: outputURL,
            palette: rgbPalette,
            compressedFrames: compressedFrames,
            config: config
        )

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0

        logger.info("✓ Stage 6: Wrote GIF (\(fileSize) bytes)")

        // ══════════════════════════════════════════════════════════════════════
        // STAGE 7: BUILD VOXELCUBE729 (Optional, for MVP1)
        // ══════════════════════════════════════════════════════════════════════

        var voxelCube: VoxelCube729? = nil

        if config.buildVoxelCube {
            logger.info("  Stage 7: Building VoxelCube729 (9×9×9 cells)...")
            voxelCube = VoxelCube729(frames: resizedFrames, palette: palette, indices: frameIndices)

            if let cube = voxelCube {
                let stats = cube.statistics()
                logger.info("✓ Stage 7: Built VoxelCube729")
                logger.debug("  \(stats.description)")
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // COMPLETE
        // ══════════════════════════════════════════════════════════════════════

        let elapsed = (CACurrentMediaTime() - startTime) * 1000

        logger.info("╔════════════════════════════════════════════════════════════╗")
        logger.info("║  GIF81Pipeline - COMPLETE                                  ║")
        logger.info("║  Output: \(outputURL.lastPathComponent)")
        logger.info("║  Size: \(fileSize) bytes (\(String(format: "%.1f", Double(fileSize)/1024.0)) KB)")
        logger.info("║  Time: \(String(format: "%.1f", elapsed)) ms                             ║")
        logger.info("╚════════════════════════════════════════════════════════════╝")

        return GIF81Result(
            gifURL: outputURL,
            fileSize: fileSize,
            frameCount: GIF81Config.frameCount,
            processingTimeMs: elapsed,
            palette: palette,
            frameIndices: frameIndices,
            voxelCube: voxelCube
        )
    }

    // MARK: - Stage 2: Resize

    private static func resizeAllFrames(_ frames: [CGImage]) throws -> [CGImage] {
        var resized: [CGImage] = []
        resized.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard let result = centerCropAndResize(frame, to: GIF81Config.dimension) else {
                throw GIF81Error.resizeFailed(frameIndex: index, reason: "CGContext creation failed")
            }
            resized.append(result)
        }

        return resized
    }

    /// Center crop to square, then resize to target dimension
    private static func centerCropAndResize(_ image: CGImage, to size: Int) -> CGImage? {
        let sourceW = image.width
        let sourceH = image.height

        // Calculate center square crop
        let cropSize = min(sourceW, sourceH)
        let cropX = (sourceW - cropSize) / 2
        let cropY = (sourceH - cropSize) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)

        // Crop
        guard let cropped = image.cropping(to: cropRect) else {
            return nil
        }

        // If already correct size, return cropped
        if cropSize == size {
            return cropped
        }

        // Resize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))

        return context.makeImage()
    }

    // MARK: - Stage 3/4: Pixel Extraction & Indexing

    /// Extract RGB pixels from CGImage (returns nil if fails)
    private static func extractPixelsRGBA(from image: CGImage) -> [(r: UInt8, g: UInt8, b: UInt8)]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let totalBytes = height * bytesPerRow

        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels: [(r: UInt8, g: UInt8, b: UInt8)] = []
        pixels.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                pixels.append((
                    r: pixelData[offset],
                    g: pixelData[offset + 1],
                    b: pixelData[offset + 2]
                ))
            }
        }

        return pixels
    }

    /// Build 3D lookup table for fast palette matching (16×16×16 buckets)
    private static func buildPaletteLookup(palette: [UInt32]) -> [[[UInt8]]] {
        // 16×16×16 = 4096 buckets, each containing the best palette index for that RGB region
        var lookup = [[[UInt8]]](repeating: [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 16), count: 16)

        for ri in 0..<16 {
            for gi in 0..<16 {
                for bi in 0..<16 {
                    let r = UInt8(ri * 16 + 8)  // Center of bucket
                    let g = UInt8(gi * 16 + 8)
                    let b = UInt8(bi * 16 + 8)
                    lookup[ri][gi][bi] = findNearestPaletteIndex(r: r, g: g, b: b, palette: palette)
                }
            }
        }

        return lookup
    }

    /// Map pixels to palette indices using lookup table
    private static func mapPixelsToIndices(
        pixels: [(r: UInt8, g: UInt8, b: UInt8)],
        palette: [UInt32],
        lookup: [[[UInt8]]]
    ) -> [UInt8] {
        var indices = [UInt8](repeating: 0, count: pixels.count)

        for (i, pixel) in pixels.enumerated() {
            // Use lookup table for approximate match (very fast)
            let ri = Int(pixel.r) >> 4
            let gi = Int(pixel.g) >> 4
            let bi = Int(pixel.b) >> 4
            indices[i] = lookup[ri][gi][bi]
        }

        return indices
    }

    /// Find nearest palette index for a color (brute force, for building lookup)
    private static func findNearestPaletteIndex(r: UInt8, g: UInt8, b: UInt8, palette: [UInt32]) -> UInt8 {
        var bestIndex: UInt8 = 0
        var bestDistance = Int.max

        for (index, color) in palette.enumerated() {
            let pr = Int((color >> 16) & 0xFF)
            let pg = Int((color >> 8) & 0xFF)
            let pb = Int(color & 0xFF)

            let dr = Int(r) - pr
            let dg = Int(g) - pg
            let db = Int(b) - pb
            let distance = dr*dr + dg*dg + db*db

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = UInt8(index)
                if distance == 0 { break }
            }
        }

        return bestIndex
    }

    // MARK: - Stage 6: GIF Writing

    private static func writeGIF89a(
        to url: URL,
        palette: [[UInt8]],
        compressedFrames: [Data],
        config: GIF81Config
    ) throws {
        var gifData = Data()
        let dim = GIF81Config.dimension

        // ── GIF89a Signature ─────────────────────────────────────────────────
        gifData.append(contentsOf: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])  // "GIF89a"

        // ── Logical Screen Descriptor ────────────────────────────────────────
        gifData.append(UInt8(dim & 0xFF))           // Width low
        gifData.append(UInt8((dim >> 8) & 0xFF))    // Width high
        gifData.append(UInt8(dim & 0xFF))           // Height low
        gifData.append(UInt8((dim >> 8) & 0xFF))    // Height high
        gifData.append(0b1111_0111)                 // GCT flag, 8bpp, 256 colors
        gifData.append(0x00)                        // Background color index
        gifData.append(0x00)                        // Pixel aspect ratio

        // ── Global Color Table (256 × 3 bytes) ───────────────────────────────
        for color in palette {
            gifData.append(color[0])  // R
            gifData.append(color[1])  // G
            gifData.append(color[2])  // B
        }
        // Pad to 256 entries if needed
        let padding = 256 - palette.count
        if padding > 0 {
            gifData.append(contentsOf: [UInt8](repeating: 0, count: padding * 3))
        }

        // ── NETSCAPE Application Extension (infinite loop) ───────────────────
        gifData.append(contentsOf: [
            0x21, 0xFF,         // Extension introducer + Application extension label
            0x0B,               // Block size (11 bytes)
            0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45,  // "NETSCAPE"
            0x32, 0x2E, 0x30,   // "2.0"
            0x03,               // Sub-block size
            0x01,               // Loop sub-block ID
            UInt8(config.loopCount & 0xFF),         // Loop count low
            UInt8((config.loopCount >> 8) & 0xFF),  // Loop count high
            0x00                // Block terminator
        ])

        // ── Write Each Frame ─────────────────────────────────────────────────
        for frameData in compressedFrames {
            // Graphic Control Extension
            gifData.append(contentsOf: [
                0x21, 0xF9,     // Extension introducer + GCE label
                0x04,           // Block size (4 bytes)
                0x04,           // Packed: disposal=1 (do not dispose), no transparency
                UInt8(config.frameDelay & 0xFF),         // Delay low (centiseconds)
                UInt8((config.frameDelay >> 8) & 0xFF),  // Delay high
                0x00,           // Transparent color index (unused)
                0x00            // Block terminator
            ])

            // Image Descriptor
            gifData.append(contentsOf: [
                0x2C,           // Image separator
                0x00, 0x00,     // Left position
                0x00, 0x00,     // Top position
                UInt8(dim & 0xFF),          // Width low
                UInt8((dim >> 8) & 0xFF),   // Width high
                UInt8(dim & 0xFF),          // Height low
                UInt8((dim >> 8) & 0xFF),   // Height high
                0x00            // Packed: no LCT, not interlaced
            ])

            // LZW Minimum Code Size
            gifData.append(0x08)

            // Image Data Sub-blocks (max 255 bytes each)
            var offset = 0
            while offset < frameData.count {
                let remaining = frameData.count - offset
                let blockSize = min(remaining, 255)
                gifData.append(UInt8(blockSize))
                gifData.append(contentsOf: frameData[offset..<offset+blockSize])
                offset += blockSize
            }

            // Block terminator
            gifData.append(0x00)
        }

        // ── GIF Trailer ──────────────────────────────────────────────────────
        gifData.append(0x3B)

        // ── Write to File ────────────────────────────────────────────────────
        do {
            try gifData.write(to: url)
        } catch {
            throw GIF81Error.fileWriteFailed(reason: error.localizedDescription)
        }
    }
}

