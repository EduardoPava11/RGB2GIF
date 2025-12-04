//
//  ColorVectorSpace.swift
//  RGB2GIF
//
//  ============================================================================
//  COLOR VECTOR SPACE: 732D Representation (3 RGB + 729 Cell Presence)
//  ============================================================================
//
//  THE 3-ADIC STRUCTURE
//  ────────────────────
//  Level 0:  3⁰ = 1      (single voxel)
//  Level 1:  3² = 9      (tile row/col, time group, bins)
//  Level 2:  3⁴ = 81     (frame count, tile count, GO board)
//  Level 3:  3⁶ = 729    (macro-cells, PRESENCE DIMENSIONS)
//  Level 4:  3⁸ = 6561   (pixels per frame)
//  Level 5:  3¹⁰= 59049  (max unique colors)
//
//  THE 729-CELL CUBE
//  ─────────────────
//  The video is a 9×9×9 cube of macro-cells:
//    - 9 tile rows × 9 tile cols × 9 time groups = 729 cells
//    - Each cell contains 9×9×9 = 729 voxels
//    - Total: 729 × 729 = 531,441 voxels ✓
//
//  THE COLOR VECTOR (732D)
//  ───────────────────────
//  For each unique color C:
//    - RGB (3D): The color value itself
//    - Cell Presence (729D): Frequency of C in each macro-cell
//
//  Cell indexing: cell_index = time_group × 81 + tile_row × 9 + tile_col
//
//  WHY THIS IS BETTER THAN 165D (3 + 81 + 81)
//  ──────────────────────────────────────────
//  The old model stored:
//    - spatial_presence[81]: presence per tile (summed over time)
//    - temporal_presence[81]: presence per frame (summed over tiles)
//
//  This LOSES the joint distribution. The 729D model preserves:
//    - WHERE the color appears (which tiles)
//    - WHEN the color appears (which time groups)
//    - The JOINT pattern (which tile at which time)
//
//  THE GO GAMES AS PROJECTIONS
//  ───────────────────────────
//  SPATIAL GAME:
//    - Board: 9×9 = 81 tiles
//    - Produces: tile_weight[row][col]
//    - Score: project cell_presence onto tiles, dot with weights
//
//  TEMPORAL GAME:
//    - Board: 9×9 = 81 positions (mapping 81 frames)
//    - Produces: frame_weight[row][col]
//    - Score: project cell_presence onto time_groups, dot with weights
//
//  ============================================================================

import Foundation
import CoreGraphics

// MARK: - Color Vector (732 Dimensions)

@available(iOS 26.0, *)
public struct ColorVector: Hashable {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ════════════════════════════════════════════════════════════════════════

    /// Total dimensions: 3 (RGB) + 729 (cell presence) = 732
    public static let totalDimensions: Int = 732

    /// Number of macro-cells in the cube
    public static let cellCount: Int = 729

    /// Cells per spatial slice (81 tiles)
    public static let tilesPerFrame: Int = 81

    /// Number of time groups
    public static let timeGroupCount: Int = 9

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Core Properties
    // ════════════════════════════════════════════════════════════════════════

    /// RGB color (3D - the point in color space)
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    /// Cell presence: frequency in each of 729 macro-cells
    /// Indexed as: cell_index = time_group × 81 + tile_row × 9 + tile_col
    /// This is the 729D presence vector that captures JOINT spatial-temporal distribution
    public var cellPresence: [Float]

    /// Total frequency (count of pixels with this color)
    public var totalFrequency: Int

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Computed Properties
    // ════════════════════════════════════════════════════════════════════════

    /// Pack RGB into single value for hashing
    public var packedRGB: UInt32 {
        (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    /// Luminance (for ordering)
    public var luminance: Float {
        0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
    }

    /// The full 732D vector representation
    public var vector: [Float] {
        var v = [Float]()
        v.reserveCapacity(Self.totalDimensions)
        v.append(Float(r) / 255.0)
        v.append(Float(g) / 255.0)
        v.append(Float(b) / 255.0)
        v.append(contentsOf: cellPresence)
        return v
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Projections
    // ════════════════════════════════════════════════════════════════════════

    /// Project onto tiles (sum over time groups) → 81D
    /// This gives spatial presence (where the color appears)
    public var tilePresence: [Float] {
        var presence = [Float](repeating: 0, count: 81)
        for timeGroup in 0..<9 {
            for tileIdx in 0..<81 {
                let cellIdx = timeGroup * 81 + tileIdx
                presence[tileIdx] += cellPresence[cellIdx]
            }
        }
        return presence
    }

    /// Project onto time groups (sum over tiles) → 9D
    /// This gives temporal presence at time-group resolution
    public var timeGroupPresence: [Float] {
        var presence = [Float](repeating: 0, count: 9)
        for timeGroup in 0..<9 {
            for tileIdx in 0..<81 {
                let cellIdx = timeGroup * 81 + tileIdx
                presence[timeGroup] += cellPresence[cellIdx]
            }
        }
        return presence
    }

    /// Expand time group presence to frame presence (81D)
    /// Each time group contains 9 frames, so we replicate
    public var framePresence: [Float] {
        let tgPresence = timeGroupPresence
        var presence = [Float](repeating: 0, count: 81)
        for frame in 0..<81 {
            let timeGroup = frame / 9
            presence[frame] = tgPresence[timeGroup] / 9.0  // Distribute evenly
        }
        return presence
    }

    /// Spatial entropy (how spread out across tiles)
    public var spatialEntropy: Float {
        computeEntropy(tilePresence)
    }

    /// Temporal entropy (how spread out across time groups)
    public var temporalEntropy: Float {
        computeEntropy(timeGroupPresence)
    }

    /// Is this color spatially localized (appears in few tiles)?
    public var isSpatiallyLocalized: Bool {
        spatialEntropy < 2.0
    }

    /// Is this color temporally localized (appears in few time groups)?
    public var isTemporallyLocalized: Bool {
        temporalEntropy < 1.5  // Lower threshold for 9 groups vs 81 tiles
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ════════════════════════════════════════════════════════════════════════

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.cellPresence = [Float](repeating: 0, count: Self.cellCount)
        self.totalFrequency = 0
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Score Computation
    // ════════════════════════════════════════════════════════════════════════

    /// Compute spatial score using tile weights from GO game.
    ///
    /// Projects 729D cell presence onto 81 tiles, then dots with weights.
    ///
    /// score = Σ tile_weight[r,c] × tile_presence[r,c]
    ///       = Σ tile_weight[r,c] × Σₜ cell_presence[t,r,c]
    public func spatialScore(weights: [[Float]]) -> Float {
        let tiles = tilePresence
        var score: Float = 0
        for row in 0..<9 {
            for col in 0..<9 {
                let tileIdx = row * 9 + col
                score += weights[row][col] * tiles[tileIdx]
            }
        }
        return score
    }

    /// Compute temporal score using frame weights from GO game.
    ///
    /// The 9×9 board maps to 81 frames: position (r,c) = frame r*9 + c
    /// We use time_group presence and distribute across frames.
    ///
    /// score = Σ frame_weight[f] × frame_presence[f]
    public func temporalScore(weights: [[Float]]) -> Float {
        let frames = framePresence
        var score: Float = 0
        for frame in 0..<81 {
            let row = frame / 9
            let col = frame % 9
            score += weights[row][col] * frames[frame]
        }
        return score
    }

    /// Direct cell score (for advanced weighting).
    ///
    /// Uses 729D weights directly on cell presence.
    /// cell_weight[t,r,c] comes from combining spatial and temporal games.
    public func cellScore(weights: [[[Float]]]) -> Float {
        var score: Float = 0
        for timeGroup in 0..<9 {
            for row in 0..<9 {
                for col in 0..<9 {
                    let cellIdx = timeGroup * 81 + row * 9 + col
                    score += weights[timeGroup][row][col] * cellPresence[cellIdx]
                }
            }
        }
        return score
    }

    /// Combined score from both games using geometric weighting.
    ///
    /// cell_weight[t,r,c] = tile_weight[r,c] × time_weight[t]
    ///
    /// This means a color scores high only if it appears in tiles AND times
    /// that both games consider important.
    public func combinedScore(
        spatialWeights: [[Float]],
        temporalWeights: [[Float]]
    ) -> Float {
        var score: Float = 0
        for timeGroup in 0..<9 {
            // Get the average temporal weight for this time group
            // (map 9 frames in this group to their weights and average)
            var timeWeight: Float = 0
            for frameInGroup in 0..<9 {
                let frame = timeGroup * 9 + frameInGroup
                let row = frame / 9
                let col = frame % 9
                timeWeight += temporalWeights[row][col]
            }
            timeWeight /= 9.0

            for row in 0..<9 {
                for col in 0..<9 {
                    let cellIdx = timeGroup * 81 + row * 9 + col
                    let combinedWeight = spatialWeights[row][col] * timeWeight
                    score += combinedWeight * cellPresence[cellIdx]
                }
            }
        }
        return score
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ════════════════════════════════════════════════════════════════════════

    private func computeEntropy(_ distribution: [Float]) -> Float {
        let total = distribution.reduce(0, +)
        guard total > 0 else { return 0 }

        var entropy: Float = 0
        for value in distribution where value > 0 {
            let p = value / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Hashable
    // ════════════════════════════════════════════════════════════════════════

    public func hash(into hasher: inout Hasher) {
        hasher.combine(packedRGB)
    }

    public static func == (lhs: ColorVector, rhs: ColorVector) -> Bool {
        lhs.packedRGB == rhs.packedRGB
    }
}

// MARK: - Color Vector Space

@available(iOS 26.0, *)
public struct ColorVectorSpace {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ════════════════════════════════════════════════════════════════════════

    /// All unique colors in the video with their 729D cell presence
    public private(set) var colors: [UInt32: ColorVector]

    /// Total pixels analyzed (should be 531,441 = 81×81×81)
    public private(set) var totalPixels: Int = 0

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ════════════════════════════════════════════════════════════════════════

    public init() {
        self.colors = [:]
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Building the Space
    // ════════════════════════════════════════════════════════════════════════

    /// Build 732D color vector space from 81 frames of 81×81 pixels.
    ///
    /// For each pixel, we determine:
    ///   - Which macro-cell it belongs to (based on tile and time group)
    ///   - Increment that cell's presence for the pixel's color
    ///
    /// The result is a 729D presence vector for each unique color.
    public static func build(from frames: [CGImage]) throws -> ColorVectorSpace {
        guard frames.count == 81 else {
            throw ColorSpaceError.invalidFrameCount(frames.count)
        }

        var space = ColorVectorSpace()

        for (frameIndex, frame) in frames.enumerated() {
            guard frame.width == 81 && frame.height == 81 else {
                throw ColorSpaceError.invalidFrameSize(frame.width, frame.height)
            }

            guard let pixels = extractPixels(from: frame) else {
                throw ColorSpaceError.pixelExtractionFailed
            }

            // Determine time group for this frame
            let timeGroup = frameIndex / 9  // 0-8

            for y in 0..<81 {
                for x in 0..<81 {
                    let offset = (y * 81 + x) * 4
                    let r = pixels[offset]
                    let g = pixels[offset + 1]
                    let b = pixels[offset + 2]

                    // Determine tile
                    let tileRow = y / 9  // 0-8
                    let tileCol = x / 9  // 0-8
                    let tileIdx = tileRow * 9 + tileCol  // 0-80

                    // Compute cell index: time_group × 81 + tile_idx
                    let cellIdx = timeGroup * 81 + tileIdx

                    space.addPixel(r: r, g: g, b: b, cell: cellIdx)
                }
            }
        }

        // Normalize presence vectors
        space.normalize()

        return space
    }

    /// Add a pixel observation to the space.
    private mutating func addPixel(r: UInt8, g: UInt8, b: UInt8, cell: Int) {
        let packed = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)

        if colors[packed] == nil {
            colors[packed] = ColorVector(r: r, g: g, b: b)
        }

        colors[packed]!.cellPresence[cell] += 1
        colors[packed]!.totalFrequency += 1
        totalPixels += 1
    }

    /// Normalize presence vectors to sum to 1 per color.
    private mutating func normalize() {
        for packed in colors.keys {
            let total = colors[packed]!.cellPresence.reduce(0, +)
            if total > 0 {
                for i in 0..<729 {
                    colors[packed]!.cellPresence[i] /= total
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Selection
    // ════════════════════════════════════════════════════════════════════════

    /// A color with its score from a GO game projection.
    public typealias ScoredPalette = [(color: (r: UInt8, g: UInt8, b: UInt8), score: Float)]

    /// Select top 256 colors by SPATIAL score.
    ///
    /// Projects 729D presence onto 81 tiles, dots with spatial weights.
    public func selectSpatialPalette(weights: [[Float]]) -> ScoredPalette {
        let colorArray = Array(colors.values)

        let ranked = colorArray
            .map { ($0, $0.spatialScore(weights: weights)) }
            .sorted { $0.1 > $1.1 }

        let selected = ranked.prefix(256)

        var result: ScoredPalette = selected.map { (color, score) in
            ((r: color.r, g: color.g, b: color.b), score)
        }

        while result.count < 256 {
            result.append(((r: 0, g: 0, b: 0), 0.0))
        }

        return result
    }

    /// Select top 256 colors by TEMPORAL score.
    ///
    /// Projects 729D presence onto time groups, dots with temporal weights.
    public func selectTemporalPalette(weights: [[Float]]) -> ScoredPalette {
        let colorArray = Array(colors.values)

        let ranked = colorArray
            .map { ($0, $0.temporalScore(weights: weights)) }
            .sorted { $0.1 > $1.1 }

        let selected = ranked.prefix(256)

        var result: ScoredPalette = selected.map { (color, score) in
            ((r: color.r, g: color.g, b: color.b), score)
        }

        while result.count < 256 {
            result.append(((r: 0, g: 0, b: 0), 0.0))
        }

        return result
    }

    /// Select BOTH palettes (256 each) for merging via ColorMerger.
    ///
    /// THE ALGORITHM:
    /// 1. Spatial game projects onto tiles → selects 256
    /// 2. Temporal game projects onto frames → selects 256
    /// 3. ColorMerger combines into final 256
    public func selectBothPalettes(
        spatialWeights: [[Float]],
        temporalWeights: [[Float]]
    ) -> (spatial: ScoredPalette, temporal: ScoredPalette) {
        let spatial = selectSpatialPalette(weights: spatialWeights)
        let temporal = selectTemporalPalette(weights: temporalWeights)
        return (spatial, temporal)
    }

    /// Select palette using uniform weights (MVP0 mode).
    public func selectPaletteUniform() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let uniform = [[Float]](
            repeating: [Float](repeating: 0.5, count: 9),
            count: 9
        )
        return selectPaletteWithMerge(
            spatialWeights: uniform,
            temporalWeights: uniform
        )
    }

    /// Select 256 colors using dual GO game weights with CIEDE2000 merge.
    public func selectPaletteWithMerge(
        spatialWeights: [[Float]],
        temporalWeights: [[Float]]
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {

        let (spatialPalette, temporalPalette) = selectBothPalettes(
            spatialWeights: spatialWeights,
            temporalWeights: temporalWeights
        )

        return ColorMerger.merge(
            spatialPalette: spatialPalette,
            temporalPalette: temporalPalette
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Vector Space Metrics
    // ════════════════════════════════════════════════════════════════════════

    /// Compute distance between two colors in the 732D vector space.
    ///
    /// Combines RGB distance with cell presence similarity.
    public func distance(_ a: ColorVector, _ b: ColorVector) -> Float {
        // RGB distance (normalized to 0-1)
        let dr = Float(Int(a.r) - Int(b.r)) / 255.0
        let dg = Float(Int(a.g) - Int(b.g)) / 255.0
        let db = Float(Int(a.b) - Int(b.b)) / 255.0
        let rgbDist = sqrt(dr*dr + dg*dg + db*db)

        // Cell presence similarity (cosine similarity of 729D vectors)
        let cellSim = cosineSimilarity(a.cellPresence, b.cellPresence)

        // Combined distance: RGB distance weighted by (1 - similarity)
        return rgbDist * (2.0 - cellSim) / 2.0
    }

    /// Find colors that appear in similar contexts (cells).
    public func neighbors(of color: ColorVector, limit: Int = 10) -> [ColorVector] {
        Array(colors.values)
            .filter { $0.packedRGB != color.packedRGB }
            .sorted { distance(color, $0) < distance(color, $1) }
            .prefix(limit)
            .map { $0 }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Statistics
    // ════════════════════════════════════════════════════════════════════════

    /// Number of unique colors in the video
    public var uniqueColorCount: Int {
        colors.count
    }

    /// Memory usage estimate (bytes)
    public var memoryUsage: Int {
        // Each color: 732 floats × 4 bytes + overhead ≈ 3000 bytes
        colors.count * 3000
    }

    /// Colors that appear in many tiles (global colors)
    public var globalColors: [ColorVector] {
        colors.values.filter { !$0.isSpatiallyLocalized }
            .sorted { $0.totalFrequency > $1.totalFrequency }
    }

    /// Colors that appear in few tiles (localized colors)
    public var localizedColors: [ColorVector] {
        colors.values.filter { $0.isSpatiallyLocalized }
            .sorted { $0.totalFrequency > $1.totalFrequency }
    }

    /// Colors that persist across many time groups (stable colors)
    public var stableColors: [ColorVector] {
        colors.values.filter { !$0.isTemporallyLocalized }
            .sorted { $0.totalFrequency > $1.totalFrequency }
    }

    /// Colors that appear briefly (transient colors)
    public var transientColors: [ColorVector] {
        colors.values.filter { $0.isTemporallyLocalized }
            .sorted { $0.totalFrequency > $1.totalFrequency }
    }

    /// Print statistics about the color space
    public func printStatistics() {
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  COLOR VECTOR SPACE (732D = 3 RGB + 729 Cell Presence)            ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Total pixels:       \(String(format: "%7d", totalPixels)) (should be 531,441)            ║")
        print("║  Unique colors:      \(String(format: "%7d", uniqueColorCount)) (max 59,049)               ║")
        print("║  Memory usage:       \(String(format: "%7.1f", Float(memoryUsage) / 1_000_000)) MB                             ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Color Distribution:                                              ║")
        print("║    Global colors:    \(String(format: "%7d", globalColors.count)) (appear across many tiles)    ║")
        print("║    Localized colors: \(String(format: "%7d", localizedColors.count)) (appear in few tiles)       ║")
        print("║    Stable colors:    \(String(format: "%7d", stableColors.count)) (persist across time)        ║")
        print("║    Transient colors: \(String(format: "%7d", transientColors.count)) (appear briefly)            ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ════════════════════════════════════════════════════════════════════════

    private static func extractPixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
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
        return pixels
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Errors
    // ════════════════════════════════════════════════════════════════════════

    public enum ColorSpaceError: Error, LocalizedError {
        case invalidFrameCount(Int)
        case invalidFrameSize(Int, Int)
        case pixelExtractionFailed

        public var errorDescription: String? {
            switch self {
            case .invalidFrameCount(let count):
                return "Expected 81 frames, got \(count)"
            case .invalidFrameSize(let w, let h):
                return "Expected 81×81 pixels, got \(w)×\(h)"
            case .pixelExtractionFailed:
                return "Failed to extract pixel data"
            }
        }
    }
}

// MARK: - Visualization

@available(iOS 26.0, *)
extension ColorVectorSpace {

    /// Visualize the 729-cell cube structure
    public func visualizeCubeStructure() {
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  THE 729-CELL CUBE (9 × 9 × 9)                                    ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║                                                                   ║")
        print("║            time_group                                             ║")
        print("║               ↑                                                   ║")
        print("║               │    ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐          ║")
        print("║               │   ╱ 8 ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱│          ║")
        print("║              8│  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │          ║")
        print("║               │  │   │   │   │   │   │   │   │   │   │╱│          ║")
        print("║               │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │          ║")
        print("║               │  │   │   │   │   │   │   │   │   │   │╱│          ║")
        print("║               │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ ╱          ║")
        print("║              0│  └───┴───┴───┴───┴───┴───┴───┴───┴───┘╱           ║")
        print("║               └─────────────────────────────────────→ tile_col    ║")
        print("║              ╱ 0                                   8              ║")
        print("║             ╱                                                     ║")
        print("║            ↓                                                      ║")
        print("║         tile_row                                                  ║")
        print("║                                                                   ║")
        print("║  cell_index = time_group × 81 + tile_row × 9 + tile_col           ║")
        print("║                                                                   ║")
        print("║  Each cell contains 9 × 9 × 9 = 729 voxels                        ║")
        print("║  Total: 729 cells × 729 voxels = 531,441 voxels ✓                 ║")
        print("║                                                                   ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
    }

    /// Visualize how GO game weights affect palette selection.
    public func visualizeSelection(
        spatialWeights: [[Float]],
        temporalWeights: [[Float]]
    ) {
        let colorArray = Array(colors.values)

        let spatialScores = colorArray.map { $0.spatialScore(weights: spatialWeights) }
        let temporalScores = colorArray.map { $0.temporalScore(weights: temporalWeights) }

        let maxSpatial = spatialScores.max() ?? 1
        let maxTemporal = temporalScores.max() ?? 1

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  PALETTE SELECTION (732D → 256 colors)                            ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")

        // Top by spatial
        let topSpatial = colorArray.enumerated()
            .sorted { spatialScores[$0.offset] > spatialScores[$1.offset] }
            .prefix(5)

        print("║  TOP 5 BY SPATIAL GAME:                                           ║")
        for (_, (idx, color)) in topSpatial.enumerated() {
            let score = spatialScores[idx]
            let bar = String(repeating: "█", count: Int(score / maxSpatial * 15))
            let rgb = String(format: "#%02X%02X%02X", color.r, color.g, color.b)
            print("║    \(rgb) \(bar.padding(toLength: 15, withPad: " ", startingAt: 0)) \(String(format: "%.3f", score))              ║")
        }

        // Top by temporal
        let topTemporal = colorArray.enumerated()
            .sorted { temporalScores[$0.offset] > temporalScores[$1.offset] }
            .prefix(5)

        print("║  TOP 5 BY TEMPORAL GAME:                                          ║")
        for (_, (idx, color)) in topTemporal.enumerated() {
            let score = temporalScores[idx]
            let bar = String(repeating: "█", count: Int(score / maxTemporal * 15))
            let rgb = String(format: "#%02X%02X%02X", color.r, color.g, color.b)
            print("║    \(rgb) \(bar.padding(toLength: 15, withPad: " ", startingAt: 0)) \(String(format: "%.3f", score))              ║")
        }

        print("╚═══════════════════════════════════════════════════════════════════╝")
    }
}
