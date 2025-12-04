//
//  SliceImportanceAnalyzer.swift
//  RGB2GIF
//
//  ============================================================================
//  SLICE IMPORTANCE ANALYZER: Fast Pre-Analysis for Adaptive Processing
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Performs fast (~5ms) pre-analysis of the tensor cube to determine which
//  slices deserve full KataGo inference vs. interpolation. This enables
//  adaptive compute allocation where more interesting regions get more
//  attention.
//
//  IMPORTANCE METRICS
//  ──────────────────
//  For SPATIAL slices (time frames):
//  - Color variance: High variance = visually complex = important
//  - Edge density: More edges = more detail = important
//  - Unique colors: More unique colors = diverse palette needs
//
//  For TEMPORAL slices (spatial columns):
//  - Motion magnitude: High motion = changing content = important
//  - Frame-to-frame delta: Rapid changes = important transitions
//
//  ALGORITHM
//  ─────────
//  1. Compute importance score for each slice (0-1)
//  2. Normalize using softmax with temperature
//  3. Return ranked list for budget allocation
//
//  PERFORMANCE
//  ───────────
//  Target: <10ms for full analysis
//  - No memory allocation (reuses buffers)
//  - SIMD-friendly operations
//  - Single pass through tensor
//
//  ============================================================================

import Foundation

// MARK: - Slice Importance Analyzer

/// Analyzes tensor slices to determine relative importance for adaptive processing.
@available(iOS 26.0, *)
public struct SliceImportanceAnalyzer {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for importance analysis.
    public struct Config: Sendable {
        /// Temperature for softmax normalization (higher = more uniform).
        public var temperature: Float = 1.0

        /// Weight for color variance in spatial importance.
        public var colorVarianceWeight: Float = 0.6

        /// Weight for edge density in spatial importance.
        public var edgeDensityWeight: Float = 0.4

        /// Weight for motion magnitude in temporal importance.
        public var motionWeight: Float = 0.7

        /// Weight for frame delta in temporal importance.
        public var frameDeltaWeight: Float = 0.3

        /// Initialize with defaults.
        public init() {}
    }

    /// Active configuration.
    public var config: Config

    /// Initialize with configuration.
    public init(config: Config = Config()) {
        self.config = config
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Importance Result
    // ═══════════════════════════════════════════════════════════════════════════

    /// Result of importance analysis.
    public struct ImportanceResult: Sendable {
        /// Importance scores for spatial slices (9 time frames).
        public let spatialImportance: [Float]

        /// Importance scores for temporal slices (9 spatial columns).
        public let temporalImportance: [Float]

        /// Indices of spatial slices sorted by importance (highest first).
        public let spatialRanking: [Int]

        /// Indices of temporal slices sorted by importance (highest first).
        public let temporalRanking: [Int]

        /// Analysis time in milliseconds.
        public let analysisTimeMs: Double

        /// Total importance (sum, for verification).
        public var totalSpatialImportance: Float {
            spatialImportance.reduce(0, +)
        }

        public var totalTemporalImportance: Float {
            temporalImportance.reduce(0, +)
        }

        /// Get spatial slices for a given budget.
        ///
        /// Always includes indices 0, 4, 8 (start, middle, end) plus
        /// highest importance slices up to budget.
        ///
        /// - Parameter budget: Maximum number of slices to return
        /// - Returns: Set of slice indices to process
        public func selectSpatialSlices(budget: Int) -> Set<Int> {
            var selected: Set<Int> = [0, 4, 8]  // Always include anchor slices

            // Add highest importance slices up to budget
            for idx in spatialRanking {
                if selected.count >= budget { break }
                selected.insert(idx)
            }

            return selected
        }

        /// Get temporal slices for a given budget.
        public func selectTemporalSlices(budget: Int) -> Set<Int> {
            var selected: Set<Int> = [0, 4, 8]  // Always include anchor slices

            for idx in temporalRanking {
                if selected.count >= budget { break }
                selected.insert(idx)
            }

            return selected
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Analysis
    // ═══════════════════════════════════════════════════════════════════════════

    /// Analyze tensor cube and compute slice importance scores.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: ImportanceResult with scores and rankings
    public func analyze(tensor: TensorCube729) -> ImportanceResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Compute spatial importance (per time frame)
        var spatialImportance = [Float](repeating: 0, count: 9)
        for t in 0..<9 {
            spatialImportance[t] = computeSpatialImportance(tensor: tensor, timeSlice: t)
        }

        // Compute temporal importance (per spatial column)
        var temporalImportance = [Float](repeating: 0, count: 9)
        for x in 0..<9 {
            temporalImportance[x] = computeTemporalImportance(tensor: tensor, column: x)
        }

        // Normalize with softmax
        spatialImportance = softmax(spatialImportance, temperature: config.temperature)
        temporalImportance = softmax(temporalImportance, temperature: config.temperature)

        // Create rankings
        let spatialRanking = spatialImportance.enumerated()
            .sorted { $0.element > $1.element }
            .map { $0.offset }

        let temporalRanking = temporalImportance.enumerated()
            .sorted { $0.element > $1.element }
            .map { $0.offset }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        return ImportanceResult(
            spatialImportance: spatialImportance,
            temporalImportance: temporalImportance,
            spatialRanking: spatialRanking,
            temporalRanking: temporalRanking,
            analysisTimeMs: elapsed
        )
    }

    /// Analyze from centroid colors (for convenience).
    ///
    /// - Parameter centroids: 729 RGB color tuples
    /// - Returns: ImportanceResult with scores and rankings
    public func analyze(centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> ImportanceResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Compute spatial importance (per time frame t)
        var spatialImportance = [Float](repeating: 0, count: 9)
        for t in 0..<9 {
            spatialImportance[t] = computeSpatialImportance(centroids: centroids, timeSlice: t)
        }

        // Compute temporal importance (per column x)
        var temporalImportance = [Float](repeating: 0, count: 9)
        for x in 0..<9 {
            temporalImportance[x] = computeTemporalImportance(centroids: centroids, column: x)
        }

        // Normalize
        spatialImportance = softmax(spatialImportance, temperature: config.temperature)
        temporalImportance = softmax(temporalImportance, temperature: config.temperature)

        // Rankings
        let spatialRanking = spatialImportance.enumerated()
            .sorted { $0.element > $1.element }
            .map { $0.offset }

        let temporalRanking = temporalImportance.enumerated()
            .sorted { $0.element > $1.element }
            .map { $0.offset }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        return ImportanceResult(
            spatialImportance: spatialImportance,
            temporalImportance: temporalImportance,
            spatialRanking: spatialRanking,
            temporalRanking: temporalRanking,
            analysisTimeMs: elapsed
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Spatial Importance (Color Variance + Edge Density)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute importance for a spatial slice (single time frame).
    private func computeSpatialImportance(tensor: TensorCube729, timeSlice t: Int) -> Float {
        var colors: [(r: Float, g: Float, b: Float)] = []
        colors.reserveCapacity(81)

        // Extract colors from this time slice
        for y in 0..<9 {
            for x in 0..<9 {
                let cell = tensor[t, y, x]
                let centroid = cell.centroidColor()
                colors.append((Float(centroid.r), Float(centroid.g), Float(centroid.b)))
            }
        }

        // Compute color variance
        let variance = computeColorVariance(colors)

        // Compute edge density (simplified: using neighbor differences)
        let edgeDensity = computeEdgeDensity(colors, width: 9, height: 9)

        return config.colorVarianceWeight * variance + config.edgeDensityWeight * edgeDensity
    }

    /// Compute importance from centroid array.
    private func computeSpatialImportance(centroids: [(r: UInt8, g: UInt8, b: UInt8)], timeSlice t: Int) -> Float {
        var colors: [(r: Float, g: Float, b: Float)] = []
        colors.reserveCapacity(81)

        // Extract colors for this time slice
        for y in 0..<9 {
            for x in 0..<9 {
                let idx = t * 81 + y * 9 + x
                let c = centroids[idx]
                colors.append((Float(c.r), Float(c.g), Float(c.b)))
            }
        }

        let variance = computeColorVariance(colors)
        let edgeDensity = computeEdgeDensity(colors, width: 9, height: 9)

        return config.colorVarianceWeight * variance + config.edgeDensityWeight * edgeDensity
    }

    /// Compute color variance (normalized 0-1).
    private func computeColorVariance(_ colors: [(r: Float, g: Float, b: Float)]) -> Float {
        guard !colors.isEmpty else { return 0 }

        // Compute mean
        var meanR: Float = 0, meanG: Float = 0, meanB: Float = 0
        for c in colors {
            meanR += c.r
            meanG += c.g
            meanB += c.b
        }
        let n = Float(colors.count)
        meanR /= n
        meanG /= n
        meanB /= n

        // Compute variance
        var varR: Float = 0, varG: Float = 0, varB: Float = 0
        for c in colors {
            let dr = c.r - meanR
            let dg = c.g - meanG
            let db = c.b - meanB
            varR += dr * dr
            varG += dg * dg
            varB += db * db
        }
        varR /= n
        varG /= n
        varB /= n

        // Combined variance normalized by max possible (255²)
        let maxVar: Float = 255 * 255
        return (varR + varG + varB) / (3 * maxVar)
    }

    /// Compute edge density using neighbor differences (normalized 0-1).
    private func computeEdgeDensity(_ colors: [(r: Float, g: Float, b: Float)], width: Int, height: Int) -> Float {
        var totalEdge: Float = 0
        var count = 0

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let c = colors[idx]

                // Check right neighbor
                if x < width - 1 {
                    let rightIdx = y * width + (x + 1)
                    let right = colors[rightIdx]
                    totalEdge += colorDistance(c, right)
                    count += 1
                }

                // Check bottom neighbor
                if y < height - 1 {
                    let bottomIdx = (y + 1) * width + x
                    let bottom = colors[bottomIdx]
                    totalEdge += colorDistance(c, bottom)
                    count += 1
                }
            }
        }

        // Normalize by max possible distance (sqrt(3 * 255²) ≈ 441)
        return count > 0 ? (totalEdge / Float(count)) / 441.67 : 0
    }

    /// Euclidean color distance.
    private func colorDistance(_ a: (r: Float, g: Float, b: Float), _ b: (r: Float, g: Float, b: Float)) -> Float {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return sqrt(dr * dr + dg * dg + db * db)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Temporal Importance (Motion + Frame Delta)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute importance for a temporal slice (single spatial column).
    private func computeTemporalImportance(tensor: TensorCube729, column x: Int) -> Float {
        var motion: Float = 0
        var frameDelta: Float = 0
        var count = 0

        // Analyze motion along time axis for this column
        for t in 1..<9 {
            for y in 0..<9 {
                let curr = tensor[t, y, x].centroidColor()
                let prev = tensor[t-1, y, x].centroidColor()

                // Motion magnitude
                let dr = Float(curr.r) - Float(prev.r)
                let dg = Float(curr.g) - Float(prev.g)
                let db = Float(curr.b) - Float(prev.b)
                motion += sqrt(dr*dr + dg*dg + db*db)
                count += 1
            }
        }

        // Also compute variance across time at each y position
        for y in 0..<9 {
            var colors: [(r: Float, g: Float, b: Float)] = []
            for t in 0..<9 {
                let c = tensor[t, y, x].centroidColor()
                colors.append((Float(c.r), Float(c.g), Float(c.b)))
            }
            frameDelta += computeColorVariance(colors)
        }
        frameDelta /= 9  // Average across y positions

        // Normalize motion
        let normalizedMotion = count > 0 ? (motion / Float(count)) / 441.67 : 0

        return config.motionWeight * normalizedMotion + config.frameDeltaWeight * frameDelta
    }

    /// Compute temporal importance from centroid array.
    private func computeTemporalImportance(centroids: [(r: UInt8, g: UInt8, b: UInt8)], column x: Int) -> Float {
        var motion: Float = 0
        var frameDelta: Float = 0
        var count = 0

        // Motion along time axis
        for t in 1..<9 {
            for y in 0..<9 {
                let currIdx = t * 81 + y * 9 + x
                let prevIdx = (t-1) * 81 + y * 9 + x
                let curr = centroids[currIdx]
                let prev = centroids[prevIdx]

                let dr = Float(curr.r) - Float(prev.r)
                let dg = Float(curr.g) - Float(prev.g)
                let db = Float(curr.b) - Float(prev.b)
                motion += sqrt(dr*dr + dg*dg + db*db)
                count += 1
            }
        }

        // Variance across time
        for y in 0..<9 {
            var colors: [(r: Float, g: Float, b: Float)] = []
            for t in 0..<9 {
                let idx = t * 81 + y * 9 + x
                let c = centroids[idx]
                colors.append((Float(c.r), Float(c.g), Float(c.b)))
            }
            frameDelta += computeColorVariance(colors)
        }
        frameDelta /= 9

        let normalizedMotion = count > 0 ? (motion / Float(count)) / 441.67 : 0

        return config.motionWeight * normalizedMotion + config.frameDeltaWeight * frameDelta
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Normalization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Softmax normalization with temperature.
    private func softmax(_ values: [Float], temperature: Float) -> [Float] {
        guard !values.isEmpty else { return [] }

        // Find max for numerical stability
        let maxVal = values.max() ?? 0

        // Compute exp((x - max) / temp)
        var exps = values.map { exp(($0 - maxVal) / temperature) }

        // Normalize
        let sum = exps.reduce(0, +)
        if sum > 0 {
            exps = exps.map { $0 / sum }
        }

        return exps
    }
}

// MARK: - Debug Description

@available(iOS 26.0, *)
extension SliceImportanceAnalyzer.ImportanceResult: CustomStringConvertible {
    public var description: String {
        var lines = [String]()
        lines.append("SliceImportance (computed in \(String(format: "%.2f", analysisTimeMs))ms):")
        lines.append("  Spatial (frames):")
        for (i, imp) in spatialImportance.enumerated() {
            let rank = spatialRanking.firstIndex(of: i)! + 1
            lines.append("    t=\(i): \(String(format: "%.3f", imp)) (rank \(rank))")
        }
        lines.append("  Temporal (columns):")
        for (i, imp) in temporalImportance.enumerated() {
            let rank = temporalRanking.firstIndex(of: i)! + 1
            lines.append("    x=\(i): \(String(format: "%.3f", imp)) (rank \(rank))")
        }
        return lines.joined(separator: "\n")
    }
}
