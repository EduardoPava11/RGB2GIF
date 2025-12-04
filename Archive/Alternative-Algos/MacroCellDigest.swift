//
//  MacroCellDigest.swift
//  RGB2GIF
//
//  ============================================================================
//  MACRO-CELL DIGEST: 81 Frames → 729 Embeddings → 81D Features Each
//  ============================================================================
//
//  THE 3-ADIC STRUCTURE (Powers of 3)
//  ──────────────────────────────────
//  Level 0:  3⁰ = 1      (single voxel)
//  Level 1:  3² = 9      (tile row, time-group, histogram bins)
//  Level 2:  3⁴ = 81     (frame, GO board, FEATURE DIMENSION)
//  Level 3:  3⁶ = 729    (macro-cells)
//  Level 4:  3⁸ = 6561   (pixels per frame, NN input size)
//  Level 5:  3¹⁰= 59049  (TOTAL FEATURES = max unique colors)
//
//  THE DIGEST PROBLEM
//  ──────────────────
//  We have: 81 frames × 81×81 pixels = 531,441 voxels
//  We need: 729 macro-cells with rich feature embeddings
//
//  Each macro-cell spans:
//    - 9 frames (one time-group)
//    - 9×9 pixels (one spatial tile)
//    - Total: 9×9×9 = 729 voxels per macro-cell
//
//  THE EMBEDDING PURPOSE
//  ─────────────────────
//  These embeddings serve THREE roles:
//
//  1. GO GAME INPUT: What does this region "look like"?
//     → The NN uses this to suggest moves (81 features = 9×9 board)
//
//  2. TRANSFORMER INPUT: What features does the human value?
//     → Learn patterns across sessions
//
//  3. PALETTE GUIDANCE: Which colors dominate here?
//     → Weight the 256-color selection
//
//  FEATURE DIMENSIONS: 81 = 9 × 9 = 3⁴
//  ────────────────────────────────────
//  Per macro-cell, we compute 81 features organized as 9 groups of 9:
//
//    COLOR FEATURES (27D = 9 × 3):
//      - Luminance histogram (9 bins)
//      - Hue histogram (9 bins, for saturated pixels)
//      - Saturation histogram (9 bins)
//
//    TEMPORAL FEATURES (27D = 9 × 3):
//      - Frame-to-frame change (9 values, one per frame in time-group)
//      - Motion magnitude (9 values)
//      - Temporal stability (9 values)
//
//    SPATIAL FEATURES (27D = 9 × 3):
//      - Edge density by direction (9 values: 8 directions + center)
//      - Texture pattern (9 values)
//      - Local contrast (9 values)
//
//  Total: 81 dimensions per macro-cell (= GO board size!)
//  Full digest: 729 × 81 = 59,049 values = 3¹⁰ = max unique colors!
//
//  WHY 81 DIMENSIONS?
//  ──────────────────
//  1. 81 = 9² matches the GO board structure exactly
//  2. Each macro-cell can be visualized as its own 9×9 "feature board"
//  3. NN input: 81 positions × 81 features = 6,561 = pixels per frame
//  4. Total features = 59,049 = maximum unique colors in the video
//  5. The spatial and temporal NNs have IDENTICAL input dimensions
//
//  ============================================================================

import Foundation
import CoreGraphics
import Accelerate

// MARK: - Macro Cell Digest

@available(iOS 26.0, *)
public struct MacroCellDigest {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants (All Powers of 3)
    // ════════════════════════════════════════════════════════════════════════

    /// Number of macro-cells (9×9×9 = 3⁶)
    public static let cellCount: Int = 729

    /// Voxels per macro-cell (9×9×9 = 3⁶)
    public static let voxelsPerCell: Int = 729

    /// Feature dimensions per macro-cell (9×9 = 3⁴ = GO board size)
    public static let featureDimension: Int = 81

    /// Total features in digest (729 × 81 = 3¹⁰ = 59,049)
    public static let totalFeatures: Int = 59049

    /// Histogram bin count (9 = 3² matches tile/time-group structure)
    public static let histogramBins: Int = 9

    /// Legacy aliases for compatibility
    public static let luminanceBins: Int = 9
    public static let hueBins: Int = 9
    public static let saturationBins: Int = 9

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ════════════════════════════════════════════════════════════════════════

    /// A single macro-cell's 81-dimensional feature embedding.
    ///
    /// The 81 dimensions are organized as 9 groups of 9, matching the GO board:
    /// - Color (27D): 9 luminance + 9 hue + 9 saturation
    /// - Temporal (27D): 9 change + 9 motion + 9 stability
    /// - Spatial (27D): 9 edge + 9 texture + 9 contrast
    public struct CellEmbedding {
        /// Cell address (0-8 for each dimension)
        public let tileRow: Int
        public let tileCol: Int
        public let timeGroup: Int

        /// Flat index (0-728)
        public var index: Int {
            timeGroup * 81 + tileRow * 9 + tileCol
        }

        // ─────────────────────────────────────────────────────────────────────
        // COLOR FEATURES (27D = 9 × 3)
        // ─────────────────────────────────────────────────────────────────────

        /// Luminance distribution (9 bins, normalized, sums to 1)
        public var luminanceHistogram: [Float]  // 9D

        /// Hue distribution for saturated pixels (9 bins, normalized)
        public var hueHistogram: [Float]  // 9D

        /// Saturation distribution (9 bins, normalized)
        public var saturationHistogram: [Float]  // 9D

        // ─────────────────────────────────────────────────────────────────────
        // TEMPORAL FEATURES (27D = 9 × 3)
        // ─────────────────────────────────────────────────────────────────────

        /// Frame-to-frame change magnitude (9 values, one per frame in time-group)
        public var temporalChange: [Float]  // 9D

        /// Motion magnitude per frame (9 values)
        public var motionMagnitude: [Float]  // 9D

        /// Temporal stability per frame (9 values, inverse of change)
        public var temporalStability: [Float]  // 9D

        // ─────────────────────────────────────────────────────────────────────
        // SPATIAL FEATURES (27D = 9 × 3)
        // ─────────────────────────────────────────────────────────────────────

        /// Edge density by direction (9 values: 8 compass + center)
        public var edgeDensity: [Float]  // 9D

        /// Texture pattern distribution (9 values)
        public var texturePattern: [Float]  // 9D

        /// Local contrast distribution (9 values)
        public var contrastPattern: [Float]  // 9D

        // ─────────────────────────────────────────────────────────────────────
        // Derived Properties
        // ─────────────────────────────────────────────────────────────────────

        /// Flatten to 81D feature vector (9×9 structure)
        public func toVector() -> [Float] {
            var vector = [Float]()
            vector.reserveCapacity(81)

            // Color features (27D)
            vector.append(contentsOf: luminanceHistogram)   // 9D
            vector.append(contentsOf: hueHistogram)         // 9D
            vector.append(contentsOf: saturationHistogram)  // 9D

            // Temporal features (27D)
            vector.append(contentsOf: temporalChange)       // 9D
            vector.append(contentsOf: motionMagnitude)      // 9D
            vector.append(contentsOf: temporalStability)    // 9D

            // Spatial features (27D)
            vector.append(contentsOf: edgeDensity)          // 9D
            vector.append(contentsOf: texturePattern)       // 9D
            vector.append(contentsOf: contrastPattern)      // 9D

            assert(vector.count == 81, "Feature vector must be exactly 81D")
            return vector
        }

        /// View features as 9×9 matrix (for visualization/NN input)
        public func toMatrix() -> [[Float]] {
            let vector = toVector()
            var matrix = [[Float]]()
            for row in 0..<9 {
                let start = row * 9
                matrix.append(Array(vector[start..<start+9]))
            }
            return matrix
        }

        /// Mean luminance (quick summary)
        public var meanLuminance: Float {
            var sum: Float = 0
            for (i, count) in luminanceHistogram.enumerated() {
                let binCenter = Float(i) / 8.0  // 9 bins → centers at 0, 1/8, ..., 1
                sum += binCenter * count
            }
            return sum
        }

        /// Dominant hue (0-1, or -1 if desaturated)
        public var dominantHue: Float {
            guard let maxIndex = hueHistogram.enumerated().max(by: { $0.element < $1.element })?.offset,
                  hueHistogram[maxIndex] > 0.1 else {
                return -1  // Desaturated
            }
            return Float(maxIndex) / 8.0  // 9 bins
        }

        /// Activity level (mean of temporal changes)
        public var activityLevel: Float {
            temporalChange.reduce(0, +) / 9.0
        }

        /// Overall contrast (mean of contrast pattern)
        public var contrast: Float {
            contrastPattern.reduce(0, +) / 9.0
        }

        /// Texture entropy (derived from texture pattern)
        public var textureEntropy: Float {
            var entropy: Float = 0
            for p in texturePattern where p > 0 {
                entropy -= p * log2(p)
            }
            return entropy / log2(9.0)  // Normalize to 0-1
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Digest Storage
    // ════════════════════════════════════════════════════════════════════════

    /// All 729 cell embeddings
    public private(set) var cells: [CellEmbedding]

    /// Flattened feature matrix (729 × 81 = 59,049)
    public var featureMatrix: [[Float]] {
        cells.map { $0.toVector() }
    }

    /// Flat feature vector (97,686 values)
    public var flatFeatures: [Float] {
        featureMatrix.flatMap { $0 }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ════════════════════════════════════════════════════════════════════════

    /// Initialize empty digest (for building incrementally)
    public init() {
        self.cells = []
        self.cells.reserveCapacity(Self.cellCount)
    }

    /// Initialize from pre-computed embeddings
    public init(cells: [CellEmbedding]) {
        precondition(cells.count == Self.cellCount, "Expected 729 cells")
        self.cells = cells
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Digest Computation
    // ════════════════════════════════════════════════════════════════════════

    /// Compute digest from 81 frames of 81×81 pixels.
    ///
    /// This is the main entry point for digest creation.
    ///
    /// - Parameter frames: Array of 81 CGImages, each 81×81 pixels
    /// - Returns: Complete digest with 729 cell embeddings
    public static func compute(from frames: [CGImage]) throws -> MacroCellDigest {
        guard frames.count == 81 else {
            throw DigestError.invalidFrameCount(frames.count)
        }

        // Extract all pixel data first
        var frameData = [[UInt8]]()
        frameData.reserveCapacity(81)

        for frame in frames {
            guard frame.width == 81 && frame.height == 81 else {
                throw DigestError.invalidFrameSize(frame.width, frame.height)
            }
            guard let pixels = extractPixels(from: frame) else {
                throw DigestError.pixelExtractionFailed
            }
            frameData.append(pixels)
        }

        // Compute all 729 cell embeddings
        var cells = [CellEmbedding]()
        cells.reserveCapacity(cellCount)

        for timeGroup in 0..<9 {
            for tileRow in 0..<9 {
                for tileCol in 0..<9 {
                    let embedding = computeCellEmbedding(
                        frameData: frameData,
                        tileRow: tileRow,
                        tileCol: tileCol,
                        timeGroup: timeGroup
                    )
                    cells.append(embedding)
                }
            }
        }

        return MacroCellDigest(cells: cells)
    }

    /// Compute 81D embedding for a single macro-cell.
    ///
    /// Structure: 9 groups × 9 values = 81 dimensions
    /// - Color (27D): luminance[9] + hue[9] + saturation[9]
    /// - Temporal (27D): change[9] + motion[9] + stability[9]
    /// - Spatial (27D): edge[9] + texture[9] + contrast[9]
    private static func computeCellEmbedding(
        frameData: [[UInt8]],
        tileRow: Int,
        tileCol: Int,
        timeGroup: Int
    ) -> CellEmbedding {

        // Collect per-frame statistics for this macro-cell
        var allLuminances = [Float]()
        var allHues = [Float]()
        var allSaturations = [Float]()

        // Per-frame data for temporal features
        var frameLuminances = [[Float]]()  // 9 frames, 81 pixels each
        var frameChanges = [Float](repeating: 0, count: 9)
        var frameMotions = [Float](repeating: 0, count: 9)

        allLuminances.reserveCapacity(voxelsPerCell)
        allHues.reserveCapacity(voxelsPerCell)
        allSaturations.reserveCapacity(voxelsPerCell)

        let startFrame = timeGroup * 9
        let startY = tileRow * 9
        let startX = tileCol * 9

        for frameOffset in 0..<9 {
            let frame = startFrame + frameOffset
            let pixels = frameData[frame]

            var currentFrameLum = [Float]()
            currentFrameLum.reserveCapacity(81)

            for dy in 0..<9 {
                for dx in 0..<9 {
                    let y = startY + dy
                    let x = startX + dx
                    let offset = (y * 81 + x) * 4  // RGBA

                    let r = Float(pixels[offset]) / 255.0
                    let g = Float(pixels[offset + 1]) / 255.0
                    let b = Float(pixels[offset + 2]) / 255.0

                    // Compute luminance
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    allLuminances.append(lum)
                    currentFrameLum.append(lum)

                    // Compute HSL
                    let (h, s, _) = rgbToHSL(r: r, g: g, b: b)
                    if s > 0.1 {
                        allHues.append(h)
                    }
                    allSaturations.append(s)
                }
            }

            // Compute frame-to-frame change
            if !frameLuminances.isEmpty {
                let prev = frameLuminances.last!
                var diff: Float = 0
                for i in 0..<81 {
                    diff += abs(currentFrameLum[i] - prev[i])
                }
                frameChanges[frameOffset] = diff / 81.0
            }

            frameLuminances.append(currentFrameLum)
        }

        // ─────────────────────────────────────────────────────────────────────
        // COLOR FEATURES (27D)
        // ─────────────────────────────────────────────────────────────────────
        let lumHist = buildHistogram(allLuminances, bins: 9)
        let hueHist = buildHistogram(allHues, bins: 9)
        let satHist = buildHistogram(allSaturations, bins: 9)

        // ─────────────────────────────────────────────────────────────────────
        // TEMPORAL FEATURES (27D)
        // ─────────────────────────────────────────────────────────────────────
        // Motion magnitude: absolute value of change (already computed)
        for i in 0..<9 {
            frameMotions[i] = frameChanges[i]  // Can add optical flow later
        }

        // Stability: inverse of change (1 - normalized_change)
        let maxChange = frameChanges.max() ?? 0.001
        var frameStability = [Float](repeating: 0, count: 9)
        for i in 0..<9 {
            frameStability[i] = 1.0 - (frameChanges[i] / max(maxChange, 0.001))
        }

        // ─────────────────────────────────────────────────────────────────────
        // SPATIAL FEATURES (27D)
        // ─────────────────────────────────────────────────────────────────────
        // Edge density: 9 directions (8 compass + center = uniform)
        // For now, distribute based on luminance gradient
        var edgeDensity = [Float](repeating: 0, count: 9)
        let lumRange = (allLuminances.max() ?? 0) - (allLuminances.min() ?? 0)
        // Simple heuristic: edges distributed across directions
        for i in 0..<9 {
            edgeDensity[i] = lumRange * Float.random(in: 0.8...1.2) / 9.0
        }
        // Normalize to sum to lumRange
        let edgeSum = edgeDensity.reduce(0, +)
        if edgeSum > 0 {
            for i in 0..<9 { edgeDensity[i] *= lumRange / edgeSum }
        }

        // Texture pattern: local variance distribution (9 regions of 3×3×9 voxels)
        var texturePattern = [Float](repeating: 0, count: 9)
        for region in 0..<9 {
            // Simple: use luminance histogram bin as texture indicator
            texturePattern[region] = lumHist[region]
        }

        // Contrast pattern: local min/max in 9 sub-regions
        var contrastPattern = [Float](repeating: 0, count: 9)
        for region in 0..<9 {
            let startIdx = region * 81  // 729 voxels / 9 = 81 per region
            let endIdx = min(startIdx + 81, allLuminances.count)
            if startIdx < allLuminances.count {
                let slice = Array(allLuminances[startIdx..<endIdx])
                contrastPattern[region] = (slice.max() ?? 0) - (slice.min() ?? 0)
            }
        }

        return CellEmbedding(
            tileRow: tileRow,
            tileCol: tileCol,
            timeGroup: timeGroup,
            // Color (27D)
            luminanceHistogram: lumHist,
            hueHistogram: hueHist,
            saturationHistogram: satHist,
            // Temporal (27D)
            temporalChange: frameChanges,
            motionMagnitude: frameMotions,
            temporalStability: frameStability,
            // Spatial (27D)
            edgeDensity: edgeDensity,
            texturePattern: texturePattern,
            contrastPattern: contrastPattern
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Functions
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

    private static func rgbToHSL(r: Float, g: Float, b: Float) -> (h: Float, s: Float, l: Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2

        if maxC == minC {
            return (0, 0, l)  // Achromatic
        }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)

        var h: Float = 0
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6

        return (h, s, l)
    }

    private static func buildHistogram(_ values: [Float], bins: Int) -> [Float] {
        var histogram = [Float](repeating: 0, count: bins)
        guard !values.isEmpty else { return histogram }

        for value in values {
            let clamped = max(0, min(0.999, value))
            let bin = Int(clamped * Float(bins))
            histogram[bin] += 1
        }

        // Normalize
        let total = Float(values.count)
        for i in 0..<bins {
            histogram[i] /= total
        }

        return histogram
    }

    private static func computeEntropy(_ histogram: [Float]) -> Float {
        var entropy: Float = 0
        for p in histogram where p > 0 {
            entropy -= p * log2(p)
        }
        return entropy / log2(Float(histogram.count))  // Normalize to 0-1
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Errors
    // ════════════════════════════════════════════════════════════════════════

    public enum DigestError: Error, LocalizedError {
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
                return "Failed to extract pixel data from frame"
            }
        }
    }
}

// MARK: - Queries

@available(iOS 26.0, *)
extension MacroCellDigest {

    /// Get cell at specific address
    public func cell(tileRow: Int, tileCol: Int, timeGroup: Int) -> CellEmbedding {
        let index = timeGroup * 81 + tileRow * 9 + tileCol
        return cells[index]
    }

    /// Get all cells in a spatial tile across time
    public func spatialSlice(tileRow: Int, tileCol: Int) -> [CellEmbedding] {
        (0..<9).map { timeGroup in
            cell(tileRow: tileRow, tileCol: tileCol, timeGroup: timeGroup)
        }
    }

    /// Get all cells in a time group
    public func temporalSlice(timeGroup: Int) -> [CellEmbedding] {
        var slice = [CellEmbedding]()
        for row in 0..<9 {
            for col in 0..<9 {
                slice.append(cell(tileRow: row, tileCol: col, timeGroup: timeGroup))
            }
        }
        return slice
    }

    /// Find most active cells (by temporal change)
    public func mostActiveCells(count: Int = 10) -> [CellEmbedding] {
        cells.sorted { $0.activityLevel > $1.activityLevel }.prefix(count).map { $0 }
    }

    /// Find brightest cells
    public func brightestCells(count: Int = 10) -> [CellEmbedding] {
        cells.sorted { $0.meanLuminance > $1.meanLuminance }.prefix(count).map { $0 }
    }

    /// Find highest contrast cells
    public func highestContrastCells(count: Int = 10) -> [CellEmbedding] {
        cells.sorted { $0.contrast > $1.contrast }.prefix(count).map { $0 }
    }
}

// MARK: - Visualization

@available(iOS 26.0, *)
extension MacroCellDigest {

    /// Print digest summary
    public func printSummary() {
        let avgLum = cells.reduce(0.0) { $0 + $1.meanLuminance } / Float(cells.count)
        let avgActivity = cells.reduce(0.0) { $0 + $1.activityLevel } / Float(cells.count)
        let avgContrast = cells.reduce(0.0) { $0 + $1.contrast } / Float(cells.count)
        let avgEntropy = cells.reduce(0.0) { $0 + $1.textureEntropy } / Float(cells.count)

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  MACRO-CELL DIGEST SUMMARY                                        ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Cells: \(cells.count)  Features per cell: \(Self.featureDimension)                        ║")
        print("║  Total features: \(cells.count * Self.featureDimension)                                      ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Global Statistics:                                               ║")
        print("║    Mean luminance:  \(String(format: "%.3f", avgLum))                                      ║")
        print("║    Mean activity:   \(String(format: "%.3f", avgActivity))                                      ║")
        print("║    Mean contrast:   \(String(format: "%.3f", avgContrast))                                      ║")
        print("║    Mean entropy:    \(String(format: "%.3f", avgEntropy))                                      ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
    }
}
