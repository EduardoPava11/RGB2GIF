//
//  TensorToGame.swift
//  RGB2GIF
//
//  ============================================================================
//  TENSOR TO GO GAME INTERPRETER
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Converts TensorCube729 statistics into Go game board positions that can be
//  fed to KataGo neural networks. The key insight is:
//
//      The 9×9×9 tensor IS a 3D Go game waiting to be interpreted.
//
//  TWO GAME PERSPECTIVES
//  ─────────────────────
//  SPATIAL GAME (which tiles matter for color accuracy):
//      • Board: 9×9 grid of tiles
//      • Black stones: High temporal variance (colors change over time)
//      • White stones: Low temporal variance (stable colors)
//      • Policy output → Query weights (Q) for attention
//
//  TEMPORAL GAME (which frame transitions matter):
//      • Board: 9×9 grid representing time flow
//      • Black stones: High inter-frame motion (t → t+1 change)
//      • White stones: Low motion (static frames)
//      • Policy output → Key weights (K) for attention
//
//  THE GO GAME METAPHOR
//  ────────────────────
//  In Go, Black plays first and tries to surround territory.
//  White responds defensively. The final board shows balanced regions.
//
//  We exploit this balance: KataGo's policy naturally distributes
//  "attention" across the board in a balanced way, preventing any
//  single region from dominating the color palette.
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Stone Color

/// Represents a stone on the Go board
public enum StoneColor: Int, Sendable {
    case empty = 0
    case black = 1  // High importance (needs attention)
    case white = 2  // Low importance (can approximate)
}

// MARK: - Game Position

/// A 9×9 Go board position derived from tensor analysis
@available(iOS 15.0, macOS 12.0, *)
public struct GamePosition: Sendable {

    /// 9×9 board state (flattened, row-major)
    public let board: [StoneColor]

    /// Move history (sequence of placed stones)
    public let moveHistory: [(row: Int, col: Int, color: StoneColor)]

    /// Which player's turn (for KataGo input)
    public let toPlay: StoneColor

    /// Komi value (Japanese=5.5, Tromp-Taylor=7.0)
    public let komi: Float

    /// Statistics about the position
    public let statistics: PositionStatistics

    /// Board size (always 9)
    public static let boardSize = 9

    /// Total intersections
    public static let totalIntersections = 81

    /// Get stone at position
    public func stone(row: Int, col: Int) -> StoneColor {
        board[row * Self.boardSize + col]
    }

    /// Count stones of each color
    public var stoneCounts: (black: Int, white: Int, empty: Int) {
        var b = 0, w = 0, e = 0
        for stone in board {
            switch stone {
            case .black: b += 1
            case .white: w += 1
            case .empty: e += 1
            }
        }
        return (b, w, e)
    }
}

/// Statistics about a game position
public struct PositionStatistics: Sendable {
    /// Mean value used for thresholding
    public let meanValue: Float
    /// Standard deviation of values
    public let stdDev: Float
    /// Min/max values
    public let minValue: Float
    public let maxValue: Float
    /// Threshold used for stone placement
    public let threshold: Float
}

// MARK: - Tensor To Game Converter

/// Converts TensorCube729 data into Go game positions
@available(iOS 26.0, *)
public struct TensorToGame {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// How to determine stone placement thresholds
    public enum ThresholdMode: Sendable {
        /// Use mean as threshold (balanced stone count)
        case mean
        /// Use median (exactly half black, half white)
        case median
        /// Use fixed percentile (e.g., 0.6 = top 40% are black)
        case percentile(Float)
        /// Use standard deviation bands (mean ± k*stddev)
        case stdDevBands(k: Float)
    }

    /// Configuration for game generation
    public struct Config: Sendable {
        /// Threshold mode for stone placement
        public var thresholdMode: ThresholdMode = .mean
        /// Minimum stones to place (ensures non-trivial game)
        public var minStones: Int = 20
        /// Whether to generate move history
        public var generateHistory: Bool = true
        /// Komi value for the game
        public var komi: Float = 7.0

        public init() {}
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Spatial Game (Tile Variance Over Time)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a spatial game from tensor data.
    ///
    /// Each tile's temporal variance determines its stone color:
    /// - High variance over time → Black (needs color precision)
    /// - Low variance over time → White (can be approximated)
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - config: Game generation configuration
    /// - Returns: A Go game position representing spatial importance
    public static func createSpatialGame(
        from tensor: TensorCube729,
        config: Config = Config()
    ) -> GamePosition {

        // Compute temporal variance for each tile
        var tileVariances = [[Float]](
            repeating: [Float](repeating: 0, count: 9),
            count: 9
        )

        for row in 0..<9 {
            for col in 0..<9 {
                tileVariances[row][col] = computeTemporalVariance(
                    tensor: tensor,
                    tileRow: row,
                    tileCol: col
                )
            }
        }

        // Flatten for threshold computation
        let allVariances = tileVariances.flatMap { $0 }
        let stats = computeStatistics(allVariances)
        let threshold = computeThreshold(allVariances, mode: config.thresholdMode, stats: stats)

        // Place stones based on variance
        var board = [StoneColor](repeating: .empty, count: 81)
        var moveHistory: [(row: Int, col: Int, color: StoneColor)] = []

        // Sort tiles by variance for move ordering (highest first)
        var tilesByVariance: [(row: Int, col: Int, variance: Float)] = []
        for row in 0..<9 {
            for col in 0..<9 {
                tilesByVariance.append((row, col, tileVariances[row][col]))
            }
        }
        tilesByVariance.sort { $0.variance > $1.variance }

        // Place stones alternating colors (Black for high variance first)
        var blackMoves: [(row: Int, col: Int)] = []
        var whiteMoves: [(row: Int, col: Int)] = []

        for (row, col, variance) in tilesByVariance {
            if variance > threshold {
                blackMoves.append((row, col))
            } else if variance < threshold * 0.5 {
                whiteMoves.append((row, col))
            }
            // Variance near threshold → empty (contested territory)
        }

        // Interleave moves (Black first, then White, alternating)
        var moveIndex = 0
        while moveIndex < max(blackMoves.count, whiteMoves.count) {
            if moveIndex < blackMoves.count {
                let (r, c) = blackMoves[moveIndex]
                board[r * 9 + c] = .black
                if config.generateHistory {
                    moveHistory.append((r, c, .black))
                }
            }
            if moveIndex < whiteMoves.count {
                let (r, c) = whiteMoves[moveIndex]
                board[r * 9 + c] = .white
                if config.generateHistory {
                    moveHistory.append((r, c, .white))
                }
            }
            moveIndex += 1
        }

        return GamePosition(
            board: board,
            moveHistory: moveHistory,
            toPlay: .black,  // Convention: Black to play
            komi: 5.5,       // Japanese rules for spatial
            statistics: PositionStatistics(
                meanValue: stats.mean,
                stdDev: stats.stdDev,
                minValue: stats.min,
                maxValue: stats.max,
                threshold: threshold
            )
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Temporal Game (Frame-to-Frame Motion)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a temporal game from tensor data.
    ///
    /// Frame-to-frame motion (t → t+1) determines stone placement:
    /// - High motion between frames → Black (key transition)
    /// - Low motion (static) → White (can skip/blend)
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - config: Game generation configuration
    /// - Returns: A Go game position representing temporal importance
    public static func createTemporalGame(
        from tensor: TensorCube729,
        config: Config = Config()
    ) -> GamePosition {

        // Compute motion between consecutive time groups
        // We have 9 time groups, so 8 transitions (t→t+1)
        // Map these to a 9×9 board by distributing across rows

        var motionGrid = [[Float]](
            repeating: [Float](repeating: 0, count: 9),
            count: 9
        )

        // For each time group, compute overall motion from previous
        for t in 0..<9 {
            let motion = computeInterFrameMotion(tensor: tensor, timeGroup: t)
            // Distribute motion across the row
            for col in 0..<9 {
                // Use spatial location to add variation
                let spatialMotion = computeSpatialMotionAtTime(
                    tensor: tensor,
                    timeGroup: t,
                    col: col
                )
                motionGrid[t][col] = (motion + spatialMotion) / 2.0
            }
        }

        // Flatten for threshold computation
        let allMotion = motionGrid.flatMap { $0 }
        let stats = computeStatistics(allMotion)
        let threshold = computeThreshold(allMotion, mode: config.thresholdMode, stats: stats)

        // Place stones based on motion
        var board = [StoneColor](repeating: .empty, count: 81)
        var moveHistory: [(row: Int, col: Int, color: StoneColor)] = []

        // Sort by motion for move ordering
        var cellsByMotion: [(row: Int, col: Int, motion: Float)] = []
        for row in 0..<9 {
            for col in 0..<9 {
                cellsByMotion.append((row, col, motionGrid[row][col]))
            }
        }
        cellsByMotion.sort { $0.motion > $1.motion }

        // Place stones
        var blackMoves: [(row: Int, col: Int)] = []
        var whiteMoves: [(row: Int, col: Int)] = []

        for (row, col, motion) in cellsByMotion {
            if motion > threshold {
                blackMoves.append((row, col))
            } else if motion < threshold * 0.5 {
                whiteMoves.append((row, col))
            }
        }

        // Interleave moves
        var moveIndex = 0
        while moveIndex < max(blackMoves.count, whiteMoves.count) {
            if moveIndex < blackMoves.count {
                let (r, c) = blackMoves[moveIndex]
                board[r * 9 + c] = .black
                if config.generateHistory {
                    moveHistory.append((r, c, .black))
                }
            }
            if moveIndex < whiteMoves.count {
                let (r, c) = whiteMoves[moveIndex]
                board[r * 9 + c] = .white
                if config.generateHistory {
                    moveHistory.append((r, c, .white))
                }
            }
            moveIndex += 1
        }

        return GamePosition(
            board: board,
            moveHistory: moveHistory,
            toPlay: .black,
            komi: 7.0,  // Tromp-Taylor rules for temporal
            statistics: PositionStatistics(
                meanValue: stats.mean,
                stdDev: stats.stdDev,
                minValue: stats.min,
                maxValue: stats.max,
                threshold: threshold
            )
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Methods
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute temporal variance for a tile (how much colors change over time)
    private static func computeTemporalVariance(
        tensor: TensorCube729,
        tileRow: Int,
        tileCol: Int
    ) -> Float {
        // Collect colors across all 9 time groups
        var colors: [(r: Float, g: Float, b: Float)] = []

        for t in 0..<9 {
            let cell = tensor[t, tileRow, tileCol]
            if cell.totalWeight > 0 {
                let (r, g, b) = cell.centroidColor()
                colors.append((Float(r), Float(g), Float(b)))
            }
        }

        guard colors.count >= 2 else { return 0 }

        // Compute variance across time
        let meanR = colors.map(\.r).reduce(0, +) / Float(colors.count)
        let meanG = colors.map(\.g).reduce(0, +) / Float(colors.count)
        let meanB = colors.map(\.b).reduce(0, +) / Float(colors.count)

        var variance: Float = 0
        for c in colors {
            variance += (c.r - meanR) * (c.r - meanR)
            variance += (c.g - meanG) * (c.g - meanG)
            variance += (c.b - meanB) * (c.b - meanB)
        }

        return variance / Float(colors.count * 3)
    }

    /// Compute motion between consecutive time groups
    private static func computeInterFrameMotion(
        tensor: TensorCube729,
        timeGroup: Int
    ) -> Float {
        guard timeGroup > 0 else { return 0 }

        var totalMotion: Float = 0
        var count: Float = 0

        for row in 0..<9 {
            for col in 0..<9 {
                let cellPrev = tensor[timeGroup - 1, row, col]
                let cellCurr = tensor[timeGroup, row, col]

                if cellPrev.totalWeight > 0 && cellCurr.totalWeight > 0 {
                    let (r1, g1, b1) = cellPrev.centroidColor()
                    let (r2, g2, b2) = cellCurr.centroidColor()

                    let dr = Float(r2) - Float(r1)
                    let dg = Float(g2) - Float(g1)
                    let db = Float(b2) - Float(b1)

                    totalMotion += sqrt(dr*dr + dg*dg + db*db)
                    count += 1
                }
            }
        }

        return count > 0 ? totalMotion / count : 0
    }

    /// Compute spatial motion at a specific time and column
    private static func computeSpatialMotionAtTime(
        tensor: TensorCube729,
        timeGroup: Int,
        col: Int
    ) -> Float {
        guard timeGroup > 0 else { return 0 }

        var totalMotion: Float = 0
        var count: Float = 0

        for row in 0..<9 {
            let cellPrev = tensor[timeGroup - 1, row, col]
            let cellCurr = tensor[timeGroup, row, col]

            if cellPrev.totalWeight > 0 && cellCurr.totalWeight > 0 {
                let (r1, g1, b1) = cellPrev.centroidColor()
                let (r2, g2, b2) = cellCurr.centroidColor()

                let dr = Float(r2) - Float(r1)
                let dg = Float(g2) - Float(g1)
                let db = Float(b2) - Float(b1)

                totalMotion += sqrt(dr*dr + dg*dg + db*db)
                count += 1
            }
        }

        return count > 0 ? totalMotion / count : 0
    }

    /// Compute statistics for an array of values
    private static func computeStatistics(_ values: [Float]) -> (mean: Float, stdDev: Float, min: Float, max: Float) {
        guard !values.isEmpty else {
            return (0, 0, 0, 0)
        }

        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        let stdDev = sqrt(variance)
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 0

        return (mean, stdDev, minVal, maxVal)
    }

    /// Compute threshold based on mode
    private static func computeThreshold(
        _ values: [Float],
        mode: ThresholdMode,
        stats: (mean: Float, stdDev: Float, min: Float, max: Float)
    ) -> Float {
        switch mode {
        case .mean:
            return stats.mean

        case .median:
            let sorted = values.sorted()
            return sorted[sorted.count / 2]

        case .percentile(let p):
            let sorted = values.sorted()
            let index = Int(Float(sorted.count) * p)
            return sorted[min(index, sorted.count - 1)]

        case .stdDevBands(let k):
            return stats.mean + k * stats.stdDev
        }
    }
}

// MARK: - Debug Visualization

@available(iOS 26.0, *)
extension GamePosition {

    /// Generate ASCII visualization of the board
    public func visualize() -> String {
        var lines = [String]()
        let counts = stoneCounts

        lines.append("╔═══════════════════════════════════════╗")
        lines.append("║  GO POSITION FROM TENSOR              ║")
        lines.append("╠═══════════════════════════════════════╣")
        lines.append("║  Black: \(String(format: "%2d", counts.black))  White: \(String(format: "%2d", counts.white))  Empty: \(String(format: "%2d", counts.empty))  ║")
        lines.append("║  Komi: \(String(format: "%.1f", komi))  Threshold: \(String(format: "%.2f", statistics.threshold))     ║")
        lines.append("╠═══════════════════════════════════════╣")

        lines.append("║     A B C D E F G H J                 ║")
        for row in 0..<9 {
            var line = "║  \(9 - row)  "
            for col in 0..<9 {
                switch stone(row: row, col: col) {
                case .black: line += "● "
                case .white: line += "○ "
                case .empty: line += "· "
                }
            }
            line += "                ║"
            lines.append(line)
        }

        lines.append("╚═══════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}
