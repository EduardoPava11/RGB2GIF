//
//  WeightedPaletteBuilder.swift
//  RGB2GIF
//
//  ============================================================================
//  WEIGHTED PALETTE BUILDER - Allocate Colors Based on Dual Game Weights
//  ============================================================================
//
//  PURPOSE
//  ───────
//  This bridges the abstract concept of "macro-cell weights" from the dual GO
//  games into concrete palette color allocation.
//
//  THE CORE ALGORITHM
//  ──────────────────
//  1. Compute merged weights for all 729 macro-cells (spatial × temporal)
//  2. Collect all unique colors from the 81×81×81 voxel cube
//  3. Weight each color by how often it appears in HIGH-WEIGHT macro-cells
//  4. Select top 256 colors based on weighted frequency
//  5. Order palette by luminance (for GIF composability)
//
//  WEIGHT INTERPRETATION
//  ─────────────────────
//  High weight (→1.0): This macro-cell needs PRECISE color representation
//                      Colors here get dedicated palette entries
//
//  Low weight (→0.0):  This macro-cell can tolerate APPROXIMATION
//                      Colors here get mapped to nearest palette neighbor
//
//  The GO game provides BALANCE: roughly half the cube gets high weights,
//  half gets low weights. This prevents any single type of content from
//  dominating the palette.
//
//  DITHERING STRATEGY
//  ──────────────────
//  After palette selection, low-weight regions use error-diffusion dithering
//  to approximate colors that didn't make it into the palette. High-weight
//  regions use direct mapping for crisp color reproduction.
//
//  ============================================================================

import Foundation
import CoreGraphics

// MARK: - Weighted Palette Builder

@available(iOS 26.0, *)
public struct WeightedPaletteBuilder {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ════════════════════════════════════════════════════════════════════════

    /// Standard palette size for GIF
    public static let paletteSize: Int = 256

    /// Cube dimensions
    public static let cubeDimension: Int = 81

    /// Tile size (for macro-cells)
    public static let tileSize: Int = 9

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Color with Weight
    // ════════════════════════════════════════════════════════════════════════

    /// A color with its accumulated weight from the cube.
    public struct WeightedColor: Hashable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public var weight: Float

        /// Luminance for sorting (ITU-R BT.601)
        public var luminance: Float {
            0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
        }

        public init(r: UInt8, g: UInt8, b: UInt8, weight: Float = 0) {
            self.r = r
            self.g = g
            self.b = b
            self.weight = weight
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(r)
            hasher.combine(g)
            hasher.combine(b)
        }

        public static func == (lhs: WeightedColor, rhs: WeightedColor) -> Bool {
            lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Building
    // ════════════════════════════════════════════════════════════════════════

    /// Build a weighted palette from cube data and dual game weights.
    ///
    /// This is the main entry point. It:
    /// 1. Scans all voxels in the cube
    /// 2. Accumulates weights for each unique color
    /// 3. Selects top 256 colors by weight
    /// 4. Orders by luminance for GIF composability
    ///
    /// - Parameters:
    ///   - cubeData: 81×81×81 RGB cube (frames × rows × cols × 3 bytes)
    ///   - weights: Dual game weights for importance
    /// - Returns: 256-color palette ordered by luminance
    public static func buildPalette(
        from cubeData: Data,
        weights: DualGameWeights
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {

        // Validate cube data size: 81 × 81 × 81 × 3 = 1,594,323 bytes
        let expectedSize = cubeDimension * cubeDimension * cubeDimension * 3
        guard cubeData.count == expectedSize else {
            print("Warning: Cube data size mismatch. Expected \(expectedSize), got \(cubeData.count)")
            return buildFallbackPalette()
        }

        // Accumulate weighted colors
        var colorWeights = [UInt32: Float]()  // RGB packed → total weight

        cubeData.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)

            for frame in 0..<cubeDimension {
                for y in 0..<cubeDimension {
                    for x in 0..<cubeDimension {
                        // Get pixel weight from dual game
                        let pixelWeight = weights.weight(x: x, y: y, frame: frame)

                        // Get RGB values
                        let offset = (frame * cubeDimension * cubeDimension + y * cubeDimension + x) * 3
                        let r = bytes[offset]
                        let g = bytes[offset + 1]
                        let b = bytes[offset + 2]

                        // Pack RGB into UInt32 for efficient hashing
                        let packed = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)

                        // Accumulate weight
                        colorWeights[packed, default: 0] += pixelWeight
                    }
                }
            }
        }

        // Convert to WeightedColor array and sort by weight
        var colors = colorWeights.map { packed, weight -> WeightedColor in
            let r = UInt8((packed >> 16) & 0xFF)
            let g = UInt8((packed >> 8) & 0xFF)
            let b = UInt8(packed & 0xFF)
            return WeightedColor(r: r, g: g, b: b, weight: weight)
        }

        // Sort by weight descending, take top 256
        colors.sort { $0.weight > $1.weight }
        let selected = Array(colors.prefix(paletteSize))

        // Ensure we have exactly 256 colors (pad with black if needed)
        var palette = selected.map { (r: $0.r, g: $0.g, b: $0.b) }
        while palette.count < paletteSize {
            palette.append((r: 0, g: 0, b: 0))
        }

        // Sort by luminance for GIF composability
        palette.sort { lum($0) < lum($1) }

        return palette
    }

    /// Build palette from frames directly (without pre-built cube data).
    ///
    /// - Parameters:
    ///   - frames: Array of 81 CGImages (81×81 each)
    ///   - weights: Dual game weights
    /// - Returns: 256-color palette
    public static func buildPalette(
        from frames: [CGImage],
        weights: DualGameWeights
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {

        guard frames.count == cubeDimension else {
            print("Warning: Expected 81 frames, got \(frames.count)")
            return buildFallbackPalette()
        }

        var colorWeights = [UInt32: Float]()

        for (frameIndex, frame) in frames.enumerated() {
            guard frame.width == cubeDimension && frame.height == cubeDimension else {
                continue
            }

            // Extract pixel data from CGImage
            guard let pixelData = extractPixelData(from: frame) else {
                continue
            }

            for y in 0..<cubeDimension {
                for x in 0..<cubeDimension {
                    let pixelWeight = weights.weight(x: x, y: y, frame: frameIndex)
                    let offset = (y * cubeDimension + x) * 4  // RGBA

                    let r = pixelData[offset]
                    let g = pixelData[offset + 1]
                    let b = pixelData[offset + 2]

                    let packed = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                    colorWeights[packed, default: 0] += pixelWeight
                }
            }
        }

        // Same selection and sorting logic
        var colors = colorWeights.map { packed, weight -> WeightedColor in
            let r = UInt8((packed >> 16) & 0xFF)
            let g = UInt8((packed >> 8) & 0xFF)
            let b = UInt8(packed & 0xFF)
            return WeightedColor(r: r, g: g, b: b, weight: weight)
        }

        colors.sort { $0.weight > $1.weight }
        var palette = Array(colors.prefix(paletteSize)).map { (r: $0.r, g: $0.g, b: $0.b) }

        while palette.count < paletteSize {
            palette.append((r: 0, g: 0, b: 0))
        }

        palette.sort { lum($0) < lum($1) }
        return palette
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Functions
    // ════════════════════════════════════════════════════════════════════════

    /// Calculate luminance for a color tuple.
    private static func lum(_ color: (r: UInt8, g: UInt8, b: UInt8)) -> Float {
        0.299 * Float(color.r) + 0.587 * Float(color.g) + 0.114 * Float(color.b)
    }

    /// Extract pixel data from CGImage.
    private static func extractPixelData(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var pixelData = [UInt8](repeating: 0, count: totalBytes)

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
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelData
    }

    /// Build a fallback palette when input is invalid.
    private static func buildFallbackPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        // Generate a simple grayscale ramp
        return (0..<256).map { i in
            (r: UInt8(i), g: UInt8(i), b: UInt8(i))
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Adaptive Indexing
    // ════════════════════════════════════════════════════════════════════════

    /// Index a voxel cube using adaptive dithering based on weights.
    ///
    /// High-weight regions: Direct nearest-color mapping (crisp)
    /// Low-weight regions: Floyd-Steinberg dithering (approximated)
    ///
    /// - Parameters:
    ///   - frames: 81 frames of 81×81 pixels
    ///   - palette: 256-color palette
    ///   - weights: Dual game weights
    ///   - ditherThreshold: Weight below which dithering is applied (default 0.3)
    /// - Returns: Array of 81 frames, each containing 6561 palette indices
    public static func indexWithAdaptiveDithering(
        frames: [CGImage],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        weights: DualGameWeights,
        ditherThreshold: Float = 0.3
    ) -> [[UInt8]] {

        var indexedFrames = [[UInt8]]()
        indexedFrames.reserveCapacity(frames.count)

        for (frameIndex, frame) in frames.enumerated() {
            guard let pixelData = extractPixelData(from: frame) else {
                // Return neutral gray indices on failure
                indexedFrames.append([UInt8](repeating: 128, count: 6561))
                continue
            }

            var indices = [UInt8]()
            indices.reserveCapacity(6561)

            // Error buffers for Floyd-Steinberg
            var errorR = [[Float]](repeating: [Float](repeating: 0, count: 82), count: 82)
            var errorG = [[Float]](repeating: [Float](repeating: 0, count: 82), count: 82)
            var errorB = [[Float]](repeating: [Float](repeating: 0, count: 82), count: 82)

            for y in 0..<81 {
                for x in 0..<81 {
                    let offset = (y * 81 + x) * 4
                    var r = Float(pixelData[offset])
                    var g = Float(pixelData[offset + 1])
                    var b = Float(pixelData[offset + 2])

                    let pixelWeight = weights.weight(x: x, y: y, frame: frameIndex)
                    let useDithering = pixelWeight < ditherThreshold

                    if useDithering {
                        // Add accumulated error
                        r += errorR[y][x]
                        g += errorG[y][x]
                        b += errorB[y][x]
                    }

                    // Clamp to valid range
                    r = max(0, min(255, r))
                    g = max(0, min(255, g))
                    b = max(0, min(255, b))

                    // Find nearest palette color
                    let index = findNearestColor(
                        r: UInt8(r), g: UInt8(g), b: UInt8(b),
                        in: palette
                    )
                    indices.append(index)

                    if useDithering {
                        // Calculate quantization error
                        let pr = Float(palette[Int(index)].r)
                        let pg = Float(palette[Int(index)].g)
                        let pb = Float(palette[Int(index)].b)

                        let errR = r - pr
                        let errG = g - pg
                        let errB = b - pb

                        // Distribute error (Floyd-Steinberg pattern)
                        // Right: 7/16, Bottom-left: 3/16, Bottom: 5/16, Bottom-right: 1/16
                        if x + 1 < 81 {
                            errorR[y][x + 1] += errR * 7 / 16
                            errorG[y][x + 1] += errG * 7 / 16
                            errorB[y][x + 1] += errB * 7 / 16
                        }
                        if y + 1 < 81 {
                            if x > 0 {
                                errorR[y + 1][x - 1] += errR * 3 / 16
                                errorG[y + 1][x - 1] += errG * 3 / 16
                                errorB[y + 1][x - 1] += errB * 3 / 16
                            }
                            errorR[y + 1][x] += errR * 5 / 16
                            errorG[y + 1][x] += errG * 5 / 16
                            errorB[y + 1][x] += errB * 5 / 16
                            if x + 1 < 81 {
                                errorR[y + 1][x + 1] += errR * 1 / 16
                                errorG[y + 1][x + 1] += errG * 1 / 16
                                errorB[y + 1][x + 1] += errB * 1 / 16
                            }
                        }
                    }
                }
            }

            indexedFrames.append(indices)
        }

        return indexedFrames
    }

    /// Find nearest palette color using squared Euclidean distance.
    private static func findNearestColor(
        r: UInt8, g: UInt8, b: UInt8,
        in palette: [(r: UInt8, g: UInt8, b: UInt8)]
    ) -> UInt8 {
        var bestIndex = 0
        var bestDistance = Int.max

        for (i, c) in palette.enumerated() {
            let dr = Int(r) - Int(c.r)
            let dg = Int(g) - Int(c.g)
            let db = Int(b) - Int(c.b)
            let distance = dr * dr + dg * dg + db * db

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
            }

            // Early exit on exact match
            if distance == 0 { break }
        }

        return UInt8(bestIndex)
    }
}

// MARK: - Statistics

@available(iOS 26.0, *)
extension WeightedPaletteBuilder {

    /// Analyze palette distribution and weight correlation.
    public static func analyzePalette(
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        weights: DualGameWeights
    ) {
        let allWeights = weights.allWeights()
        let highWeightCount = allWeights.filter { $0 > 0.5 }.count
        let lowWeightCount = allWeights.filter { $0 <= 0.5 }.count

        let luminances = palette.map { lum($0) }
        let avgLum = luminances.reduce(0, +) / Float(luminances.count)
        let minLum = luminances.min() ?? 0
        let maxLum = luminances.max() ?? 0

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  WEIGHTED PALETTE ANALYSIS                                        ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Weight Distribution:                                             ║")
        print("║    High-weight cells (>0.5): \(String(format: "%3d", highWeightCount)) / 729                         ║")
        print("║    Low-weight cells (≤0.5):  \(String(format: "%3d", lowWeightCount)) / 729                         ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Palette Luminance:                                               ║")
        print("║    Average: \(String(format: "%.1f", avgLum))                                               ║")
        print("║    Range:   \(String(format: "%.1f", minLum)) - \(String(format: "%.1f", maxLum))                                        ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Unique colors in palette: \(palette.count)                               ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
    }
}
