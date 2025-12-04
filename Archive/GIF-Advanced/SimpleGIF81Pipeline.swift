//
//  SimpleGIF81Pipeline.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  SIMPLE GIF81 PIPELINE - DIRECT CGImage → GIF                             ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║  MVP0: Minimal 81×81×81 GIF creation without GIP/GIX complexity           ║
//  ║                                                                           ║
//  ║  PIPELINE:                                                                ║
//  ║  1. Validate 81 frames                                                    ║
//  ║  2. Resize each frame to 81×81                                            ║
//  ║  3. Collect all pixels for global palette                                 ║
//  ║  4. Quantize to 256 colors using Octree                                   ║
//  ║  5. Map each frame's pixels to palette indices                            ║
//  ║  6. LZW compress each frame                                               ║
//  ║  7. Write GIF89a directly to disk                                         ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import QuartzCore
import os.log

private let pipelineLogger = Logger(subsystem: "com.rgb2gif", category: "SimpleGIF81")

// MARK: - Pipeline Result

@available(iOS 26.0, *)
public struct SimpleGIF81Result {
    public let gifURL: URL
    public let frameCount: Int
    public let fileSize: Int
    public let processingTimeMs: Double
}

// MARK: - Pipeline Errors

@available(iOS 26.0, *)
public enum SimpleGIF81Error: LocalizedError {
    case wrongFrameCount(got: Int, expected: Int)
    case resizeFailed(frameIndex: Int)
    case quantizationFailed(String)
    case compressionFailed(frameIndex: Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongFrameCount(let got, let expected):
            return "Wrong frame count: \(got) (expected \(expected))"
        case .resizeFailed(let index):
            return "Failed to resize frame \(index)"
        case .quantizationFailed(let reason):
            return "Quantization failed: \(reason)"
        case .compressionFailed(let index):
            return "LZW compression failed for frame \(index)"
        case .writeFailed(let reason):
            return "GIF write failed: \(reason)"
        }
    }
}

// MARK: - Simple GIF81 Pipeline

@available(iOS 26.0, *)
public struct SimpleGIF81Pipeline {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants (81 = 3⁴)
    // ════════════════════════════════════════════════════════════════════════

    public static let frameCount = 81
    public static let dimension = 81
    public static let paletteSize = 256

    /// Frame delay in centiseconds (3 = ~33fps)
    public static let frameDelay: UInt16 = 3

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Public API
    // ════════════════════════════════════════════════════════════════════════

    /// Process 81 captured frames into a GIF
    /// - Parameters:
    ///   - frames: Array of exactly 81 CGImages
    ///   - outputURL: Where to write the GIF
    /// - Returns: Result with file info and timing
    public static func process(
        frames: [CGImage],
        outputURL: URL
    ) async throws -> SimpleGIF81Result {
        let startTime = CACurrentMediaTime()

        pipelineLogger.info("╔══════════════════════════════════════════════════════════╗")
        pipelineLogger.info("║  SimpleGIF81Pipeline - Starting                          ║")
        pipelineLogger.info("╚══════════════════════════════════════════════════════════╝")

        // ── Step 1: Validate frame count ──────────────────────────────────
        guard frames.count == frameCount else {
            throw SimpleGIF81Error.wrongFrameCount(got: frames.count, expected: frameCount)
        }
        pipelineLogger.info("✓ Frame count validated: \(frames.count)")

        // ── Step 2: Resize all frames to 81×81 ────────────────────────────
        let resizedFrames = try resizeFrames(frames)
        pipelineLogger.info("✓ Frames resized to \(dimension)×\(dimension)")

        // ── Step 3: Collect all pixels ────────────────────────────────────
        let allPixels = collectAllPixels(from: resizedFrames)
        pipelineLogger.info("✓ Collected \(allPixels.count) pixels")

        // ── Step 4: Quantize to 256 colors ────────────────────────────────
        let quantizer = OctreeColorQuantizer()
        let quantResult = try await quantizer.quantize(
            resizedFrames[0], // Quantizer needs a CGImage, we'll extract colors separately
            options: .balanced
        )

        // Build palette from quantization result (ARGB → RGB)
        let palette: [[UInt8]] = quantResult.palette.map { argb in
            let r = UInt8((argb >> 16) & 0xFF)
            let g = UInt8((argb >> 8) & 0xFF)
            let b = UInt8(argb & 0xFF)
            return [r, g, b]
        }
        pipelineLogger.info("✓ Palette created: \(palette.count) colors")

        // ── Step 5: Map each frame to palette indices ─────────────────────
        var frameIndices: [[UInt8]] = []
        frameIndices.reserveCapacity(frameCount)

        for (index, frame) in resizedFrames.enumerated() {
            let indices = mapFrameToIndices(frame: frame, palette: quantResult.palette)
            frameIndices.append(indices)

            if index % 20 == 0 {
                pipelineLogger.debug("  Mapped frame \(index)/\(frameCount)")
            }
        }
        pipelineLogger.info("✓ All frames mapped to indices")

        // ── Step 6: LZW compress each frame ───────────────────────────────
        var compressedFrames: [Data] = []
        compressedFrames.reserveCapacity(frameCount)

        for (index, indices) in frameIndices.enumerated() {
            let subBlocks = try LZW_Optimized.compress(indices: indices, minCodeSize: 8)

            // Flatten sub-blocks into single Data
            var frameData = Data()
            for block in subBlocks {
                frameData.append(contentsOf: block)
            }
            compressedFrames.append(frameData)

            if index % 20 == 0 {
                pipelineLogger.debug("  Compressed frame \(index)/\(frameCount)")
            }
        }
        pipelineLogger.info("✓ All frames LZW compressed")

        // ── Step 7: Write GIF ─────────────────────────────────────────────
        try writeGIF(
            to: outputURL,
            palette: palette,
            compressedFrames: compressedFrames
        )

        let fileSize = try FileManager.default.attributesOfItem(
            atPath: outputURL.path
        )[.size] as? Int ?? 0

        let elapsed = (CACurrentMediaTime() - startTime) * 1000

        pipelineLogger.info("╔══════════════════════════════════════════════════════════╗")
        pipelineLogger.info("║  SimpleGIF81Pipeline - Complete                          ║")
        pipelineLogger.info("║  File: \(fileSize) bytes                                 ║")
        pipelineLogger.info("║  Time: \(String(format: "%.1f", elapsed)) ms             ║")
        pipelineLogger.info("╚══════════════════════════════════════════════════════════╝")

        return SimpleGIF81Result(
            gifURL: outputURL,
            frameCount: frameCount,
            fileSize: fileSize,
            processingTimeMs: elapsed
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Frame Processing
    // ════════════════════════════════════════════════════════════════════════

    private static func resizeFrames(_ frames: [CGImage]) throws -> [CGImage] {
        var resized: [CGImage] = []
        resized.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard let resizedFrame = resizeImage(frame, to: dimension) else {
                throw SimpleGIF81Error.resizeFailed(frameIndex: index)
            }
            resized.append(resizedFrame)
        }

        return resized
    }

    private static func resizeImage(_ image: CGImage, to size: Int) -> CGImage? {
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        return context.makeImage()
    }

    private static func collectAllPixels(from frames: [CGImage]) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var pixels: [(r: UInt8, g: UInt8, b: UInt8)] = []
        pixels.reserveCapacity(frames.count * dimension * dimension)

        for frame in frames {
            pixels.append(contentsOf: extractPixels(from: frame))
        }

        return pixels
    }

    private static func extractPixels(from image: CGImage) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4

        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return []
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels: [(r: UInt8, g: UInt8, b: UInt8)] = []
        pixels.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                pixels.append((r, g, b))
            }
        }

        return pixels
    }

    private static func mapFrameToIndices(frame: CGImage, palette: [UInt32]) -> [UInt8] {
        let pixels = extractPixels(from: frame)
        var indices = [UInt8](repeating: 0, count: pixels.count)

        for (i, pixel) in pixels.enumerated() {
            indices[i] = findClosestPaletteIndex(
                r: pixel.r, g: pixel.g, b: pixel.b,
                palette: palette
            )
        }

        return indices
    }

    private static func findClosestPaletteIndex(
        r: UInt8, g: UInt8, b: UInt8,
        palette: [UInt32]
    ) -> UInt8 {
        var bestIndex: UInt8 = 0
        var bestDistance = Int.max

        for (index, color) in palette.enumerated() {
            let pr = Int((color >> 16) & 0xFF)
            let pg = Int((color >> 8) & 0xFF)
            let pb = Int(color & 0xFF)

            // Simple Euclidean distance (squared)
            let dr = Int(r) - pr
            let dg = Int(g) - pg
            let db = Int(b) - pb
            let distance = dr*dr + dg*dg + db*db

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = UInt8(index)
            }

            if distance == 0 { break } // Exact match
        }

        return bestIndex
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - GIF Writing (Embedded Minimal Writer)
    // ════════════════════════════════════════════════════════════════════════

    private static func writeGIF(
        to url: URL,
        palette: [[UInt8]],
        compressedFrames: [Data]
    ) throws {
        // Create file
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw SimpleGIF81Error.writeFailed("Cannot open file for writing")
        }

        defer { try? handle.close() }

        // ── GIF89a Header ─────────────────────────────────────────────────
        handle.write(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) // "GIF89a"

        // ── Logical Screen Descriptor ─────────────────────────────────────
        var lsd = Data()
        lsd.append(UInt8(dimension & 0xFF))          // Width (low)
        lsd.append(UInt8((dimension >> 8) & 0xFF))   // Width (high)
        lsd.append(UInt8(dimension & 0xFF))          // Height (low)
        lsd.append(UInt8((dimension >> 8) & 0xFF))   // Height (high)
        lsd.append(0b1111_0111)                      // GCT flag, 8-bit color, 256 colors
        lsd.append(0)                                 // Background color index
        lsd.append(0)                                 // Pixel aspect ratio
        handle.write(lsd)

        // ── Global Color Table (256 × 3 bytes) ────────────────────────────
        var gct = Data()
        for color in palette {
            gct.append(color[0]) // R
            gct.append(color[1]) // G
            gct.append(color[2]) // B
        }
        // Pad to 256 colors if needed
        while gct.count < 768 {
            gct.append(0)
        }
        handle.write(gct)

        // ── Netscape Loop Extension ───────────────────────────────────────
        handle.write(Data([
            0x21, 0xFF,         // Extension + Application Extension
            0x0B,               // Block size
            0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, // "NETSCAPE"
            0x32, 0x2E, 0x30,   // "2.0"
            0x03,               // Sub-block size
            0x01,               // Loop index
            0x00, 0x00,         // Loop count (0 = infinite)
            0x00                // Block terminator
        ]))

        // ── Write Each Frame ──────────────────────────────────────────────
        for frameData in compressedFrames {
            // Graphic Control Extension
            handle.write(Data([
                0x21, 0xF9,     // Extension + GCE
                0x04,           // Block size
                0x00,           // Packed (disposal=0, no transparency)
                UInt8(frameDelay & 0xFF),         // Delay low
                UInt8((frameDelay >> 8) & 0xFF),  // Delay high
                0x00,           // Transparent index (unused)
                0x00            // Block terminator
            ]))

            // Image Descriptor
            handle.write(Data([
                0x2C,           // Image separator
                0x00, 0x00,     // Left position
                0x00, 0x00,     // Top position
                UInt8(dimension & 0xFF),          // Width low
                UInt8((dimension >> 8) & 0xFF),   // Width high
                UInt8(dimension & 0xFF),          // Height low
                UInt8((dimension >> 8) & 0xFF),   // Height high
                0x00            // Packed (no LCT, not interlaced)
            ]))

            // Image Data
            handle.write(Data([0x08])) // LZW minimum code size = 8

            // Write sub-blocks (≤255 bytes each)
            var offset = 0
            while offset < frameData.count {
                let remaining = frameData.count - offset
                let blockSize = min(remaining, 255)
                handle.write(Data([UInt8(blockSize)]))
                handle.write(frameData[offset..<offset+blockSize])
                offset += blockSize
            }

            handle.write(Data([0x00])) // Block terminator
        }

        // ── GIF Trailer ───────────────────────────────────────────────────
        handle.write(Data([0x3B]))
    }
}
