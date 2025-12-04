//
//  AttentionWeights.swift
//  RGB2GIF
//
//  ============================================================================
//  729-CELL ATTENTION WEIGHTS FROM Q-K-V MECHANISM
//  ============================================================================
//
//  PURPOSE
//  ───────
//  This structure holds the final attention weights for all 729 macro-cells.
//  Each weight determines how much "attention" (palette resources) that cell
//  receives during color quantization.
//
//  THE Q-K-V FORMULA
//  ─────────────────
//  For each macro-cell (tile_row, tile_col, time_group):
//
//      Q[i,j] = spatialPolicy[i * 9 + j]    // From Spatial player
//      K[t]   = temporalPolicy[t]           // From Temporal player
//      V[i,j,t] = TensorCube729[t,i,j].centroidColor()  // RGB value
//
//      weight[i,j,t] = λ(Q[i,j], K[t])      // Merge function
//
//  MERGE STRATEGIES
//  ────────────────
//  • geometric:  √(Q × K) - Default, balanced emphasis
//  • multiply:   Q × K - Both must agree, creates contrast
//  • average:    (Q + K) / 2 - Balanced combination
//  • max:        max(Q, K) - Either can promote
//  • min:        min(Q, K) - Both must agree (strict)
//
//  USAGE
//  ─────
//  These weights are passed to OctreeColorQuantizer to influence:
//  1. Which colors get dedicated palette entries
//  2. How error diffusion is weighted during dithering
//  3. Frame priority during temporal optimization
//
//  ============================================================================

import Foundation

// MARK: - Attention Weights

/// Contains the 729 attention weights for macro-cell palette allocation.
///
/// The weights determine how palette colors are distributed across the
/// 9×9×9 grid of macro-cells. Higher weight = more dedicated colors.
@available(iOS 15.0, macOS 12.0, *)
public struct AttentionWeights: Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════════

    /// Strategy for merging Query and Key weights
    public enum MergeStrategy: String, CaseIterable, Sendable {
        /// √(Q × K) - Geometric mean, balanced emphasis
        case geometric

        /// Q × K - Product, both must be high for attention
        case multiply

        /// (Q + K) / 2 - Average, balanced blend
        case average

        /// max(Q, K) - Either can promote attention
        case max

        /// min(Q, K) - Both must agree, strict
        case min

        /// Apply the merge function
        public func apply(_ query: Float, _ key: Float) -> Float {
            switch self {
            case .geometric:
                return sqrt(query * key)
            case .multiply:
                return query * key
            case .average:
                return (query + key) / 2.0
            case .max:
                return Swift.max(query, key)
            case .min:
                return Swift.min(query, key)
            }
        }

        /// Human-readable description
        public var description: String {
            switch self {
            case .geometric:
                return "Geometric mean (√Q×K) - balanced emphasis"
            case .multiply:
                return "Product (Q×K) - both must agree"
            case .average:
                return "Average ((Q+K)/2) - balanced blend"
            case .max:
                return "Maximum (max(Q,K)) - either promotes"
            case .min:
                return "Minimum (min(Q,K)) - both must agree"
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ═══════════════════════════════════════════════════════════════════════════

    /// Grid dimension (9)
    public static let gridDimension = 9

    /// Total macro-cells (729)
    public static let totalCells = 729

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Storage
    // ═══════════════════════════════════════════════════════════════════════════

    /// Query weights from Spatial player (81 values, one per tile)
    public let queryWeights: [Float]

    /// Key weights from Temporal player (9 values, one per time group)
    /// Note: The 81-value policy is reduced to 9 time-group weights
    public let keyWeights: [Float]

    /// Merged attention weights (729 values, one per macro-cell)
    public let weights: [Float]

    /// The merge strategy used to compute weights
    public let mergeStrategy: MergeStrategy

    /// Value head output from Spatial player (win probability)
    public let spatialValue: Float

    /// Value head output from Temporal player (win probability)
    public let temporalValue: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create attention weights from Query and Key arrays.
    ///
    /// - Parameters:
    ///   - query: 81 Query weights from Spatial player
    ///   - key: Key weights from Temporal player (9 or 81 values)
    ///   - strategy: Merge function to use
    ///   - spatialValue: Value head from Spatial player (default 0.5)
    ///   - temporalValue: Value head from Temporal player (default 0.5)
    public init(
        query: [Float],
        key: [Float],
        strategy: MergeStrategy = .geometric,
        spatialValue: Float = 0.5,
        temporalValue: Float = 0.5
    ) {
        precondition(query.count == 81, "Query must have 81 values")
        precondition(key.count == 9 || key.count == 81, "Key must have 9 or 81 values")

        self.queryWeights = query
        self.mergeStrategy = strategy
        self.spatialValue = spatialValue
        self.temporalValue = temporalValue

        // Convert 81-value key to 9 time-group weights if needed
        if key.count == 81 {
            // Average each row to get 9 time-group weights
            var reducedKey = [Float](repeating: 0, count: 9)
            for t in 0..<9 {
                var sum: Float = 0
                for i in 0..<9 {
                    sum += key[t * 9 + i]
                }
                reducedKey[t] = sum / 9.0
            }
            self.keyWeights = reducedKey
        } else {
            self.keyWeights = key
        }

        // Compute 729 merged weights
        var merged = [Float](repeating: 0, count: Self.totalCells)
        for t in 0..<Self.gridDimension {
            for row in 0..<Self.gridDimension {
                for col in 0..<Self.gridDimension {
                    let q = query[row * 9 + col]
                    let k = self.keyWeights[t]
                    let idx = t * 81 + row * 9 + col
                    merged[idx] = strategy.apply(q, k)
                }
            }
        }

        self.weights = merged
    }

    /// Create uniform attention weights (all equal).
    public static func uniform() -> AttentionWeights {
        let uniform: Float = 1.0 / 81.0
        return AttentionWeights(
            query: [Float](repeating: uniform, count: 81),
            key: [Float](repeating: uniform, count: 9),
            strategy: .geometric
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Weight Access
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get weight for a specific macro-cell by indices.
    ///
    /// - Parameters:
    ///   - tileRow: Row in 9×9 tile grid (0-8)
    ///   - tileCol: Column in 9×9 tile grid (0-8)
    ///   - timeGroup: Time group index (0-8)
    /// - Returns: Attention weight [0, 1]
    public func weight(tileRow: Int, tileCol: Int, timeGroup: Int) -> Float {
        let idx = timeGroup * 81 + tileRow * 9 + tileCol
        return weights[idx]
    }

    /// Get weight for a pixel and frame coordinate.
    ///
    /// - Parameters:
    ///   - x: Pixel X coordinate (0-80)
    ///   - y: Pixel Y coordinate (0-80)
    ///   - frame: Frame number (0-80)
    /// - Returns: Attention weight [0, 1]
    public func weight(x: Int, y: Int, frame: Int) -> Float {
        let tileRow = y / 9
        let tileCol = x / 9
        let timeGroup = frame / 9
        return weight(tileRow: tileRow, tileCol: tileCol, timeGroup: timeGroup)
    }

    /// Get Query weight for a specific tile.
    public func queryWeight(row: Int, col: Int) -> Float {
        return queryWeights[row * 9 + col]
    }

    /// Get Key weight for a specific time group.
    public func keyWeight(timeGroup: Int) -> Float {
        return keyWeights[timeGroup]
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Allocation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Calculate palette color allocation based on weights.
    ///
    /// - Parameter totalColors: Total palette size (typically 256)
    /// - Returns: Array of color counts per macro-cell (729 entries)
    public func paletteAllocation(totalColors: Int = 256) -> [Int] {
        let totalWeight = weights.reduce(0, +)

        guard totalWeight > 0 else {
            // Uniform distribution if all weights are zero
            let uniform = totalColors / Self.totalCells
            return [Int](repeating: uniform, count: Self.totalCells)
        }

        // Proportional allocation
        var allocation = weights.map { w in
            Int((w / totalWeight) * Float(totalColors))
        }

        // Ensure at least 1 color per macro-cell with non-zero weight
        for i in 0..<allocation.count where weights[i] > 0 && allocation[i] == 0 {
            allocation[i] = 1
        }

        // Adjust to exactly match totalColors
        let allocated = allocation.reduce(0, +)
        let delta = totalColors - allocated

        if delta > 0 {
            // Add extra colors to highest-weight cells
            let sorted = weights.enumerated().sorted { $0.element > $1.element }
            for i in 0..<delta {
                allocation[sorted[i % sorted.count].offset] += 1
            }
        } else if delta < 0 {
            // Remove colors from lowest-weight cells (but keep minimum 1)
            let sorted = weights.enumerated().sorted { $0.element < $1.element }
            var toRemove = -delta
            for (_, idx) in sorted.enumerated() where toRemove > 0 {
                if allocation[idx.offset] > 1 {
                    allocation[idx.offset] -= 1
                    toRemove -= 1
                }
            }
        }

        return allocation
    }

    /// Get normalized weights (sum to 1.0).
    public var normalizedWeights: [Float] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights }
        return weights.map { $0 / sum }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Statistics
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute statistics about the weight distribution.
    public var statistics: AttentionStatistics {
        let sorted = weights.sorted()
        let sum = weights.reduce(0, +)
        let mean = sum / Float(weights.count)
        let median = sorted[sorted.count / 2]
        let minW = sorted.first ?? 0
        let maxW = sorted.last ?? 0

        // Standard deviation
        var varianceSum: Float = 0
        for w in weights {
            varianceSum += (w - mean) * (w - mean)
        }
        let stddev = sqrt(varianceSum / Float(weights.count))

        // Entropy (measure of distribution uniformity)
        var entropy: Float = 0
        for w in normalizedWeights where w > 0 {
            entropy -= w * log2(w)
        }
        let maxEntropy = log2(Float(weights.count))

        return AttentionStatistics(
            mean: mean,
            median: median,
            min: minW,
            max: maxW,
            stddev: stddev,
            entropy: entropy,
            normalizedEntropy: entropy / maxEntropy
        )
    }
}

// MARK: - Statistics Structure

/// Statistics about attention weight distribution.
public struct AttentionStatistics: Sendable, CustomStringConvertible {
    /// Mean weight
    public let mean: Float

    /// Median weight
    public let median: Float

    /// Minimum weight
    public let min: Float

    /// Maximum weight
    public let max: Float

    /// Standard deviation
    public let stddev: Float

    /// Entropy (bits)
    public let entropy: Float

    /// Normalized entropy (0 = concentrated, 1 = uniform)
    public let normalizedEntropy: Float

    public var description: String {
        """
        Attention Statistics:
          Mean:   \(String(format: "%.4f", mean))
          Median: \(String(format: "%.4f", median))
          Min:    \(String(format: "%.4f", min))
          Max:    \(String(format: "%.4f", max))
          StdDev: \(String(format: "%.4f", stddev))
          Entropy: \(String(format: "%.2f", entropy)) bits (\(String(format: "%.1f%%", normalizedEntropy * 100)) uniform)
        """
    }
}

// MARK: - Debug Extensions

@available(iOS 15.0, macOS 12.0, *)
extension AttentionWeights: CustomStringConvertible {

    public var description: String {
        """
        AttentionWeights:
          Strategy: \(mergeStrategy.description)
          Spatial Value: \(String(format: "%.2f", spatialValue))
          Temporal Value: \(String(format: "%.2f", temporalValue))
        \(statistics.description)
        """
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension AttentionWeights {

    /// Visualize Query weights as 9×9 grid.
    public func visualizeQuery() -> String {
        var lines = [String]()
        lines.append("Query Weights (Spatial - which TILES matter):")
        lines.append("┌─────────────────────────────────────┐")

        for row in 0..<Self.gridDimension {
            var line = "│ "
            for col in 0..<Self.gridDimension {
                let w = queryWeights[row * 9 + col]
                let char = weightChar(w * 81)  // Denormalize for display
                line += "\(char) "
            }
            lines.append("\(line)│")
        }

        lines.append("└─────────────────────────────────────┘")
        return lines.joined(separator: "\n")
    }

    /// Visualize Key weights as vertical bar.
    public func visualizeKey() -> String {
        var lines = [String]()
        lines.append("Key Weights (Temporal - which FRAMES matter):")

        for t in 0..<Self.gridDimension {
            let w = keyWeights[t]
            let barLen = Int(w * 81 * 30)  // Denormalize and scale to 30 chars
            let bar = String(repeating: "█", count: barLen)
            lines.append("  T\(t): \(bar) \(String(format: "%.3f", w))")
        }

        return lines.joined(separator: "\n")
    }

    private func weightChar(_ w: Float) -> String {
        switch w {
        case 0.875...Float.infinity: return "██"
        case 0.625..<0.875: return "▓▓"
        case 0.375..<0.625: return "░░"
        case 0.125..<0.375: return "··"
        default: return "  "
        }
    }
}
