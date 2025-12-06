//
//  TemporalGamePlayer.swift
//  RGB2GIF
//
//  ============================================================================
//  TEMPORAL GAME PLAYER (x/t TIME-EVOLUTION)
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Interprets the 9×9×9 tensor as 9 COLUMNS, where each column shows how
//  a spatial slice evolves over time. This is the TEMPORAL view - focusing
//  on which frame transitions are most important to preserve.
//
//  PARSING STRATEGY
//  ────────────────
//  For each x-column (0-8):
//      Create a 9×9 board where:
//          intersection[t][y] = tensor[t, y, x]
//
//      This means each board shows:
//          - X-axis: time progression (t=0 to t=8)
//          - Y-axis: spatial rows (y=0 to y=8)
//
//      The board reveals HOW a vertical slice of tiles changes over time.
//
//  STONE PLACEMENT
//  ───────────────
//  High motion (t → t+1 change) → Black (key transition, needs attention)
//  Low motion (static) → White (can skip/blend frames)
//  Medium values → Empty (contested, let the NN decide)
//
//  RULE SET
//  ────────
//  Uses Tromp-Taylor rules (komi 7.0) which encourage:
//      • Fighting/capturing play
//      • Dynamic, contested positions
//      • Active engagement
//
//  This produces KEY weights - indicating which temporal transitions matter.
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Temporal Game Player

/// Game player that interprets tensor as 9 temporal columns (t/y boards).
///
/// Each column represents a spatial x-position, and the board shows how
/// that column evolves over time. The player identifies key transitions.
@available(iOS 15.0, macOS 12.0, *)
public final class TemporalGamePlayer: BaseGamePlayer, GamePlayer, @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ═══════════════════════════════════════════════════════════════════════════

    public let viewType: TensorViewType = .temporal

    /// Komi for Tromp-Taylor rules (fighting, dynamic).
    private let komi: Float = 7.0

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a temporal game player with the given inference engine.
    ///
    /// - Parameters:
    ///   - inference: KataGo inference engine (should use Tromp-Taylor rules)
    ///   - config: Stone seeding configuration (default: temporal preset)
    public override init(inference: KataGoInference, config: StoneSeedingConfig = .temporal) {
        super.init(inference: inference, config: config)
    }

    /// Convenience initializer that creates its own inference engine.
    ///
    /// - Parameter computeUnits: CoreML compute units
    /// - Throws: If model cannot be loaded
    public convenience init(computeUnits: MLComputeUnits = .all) async throws {
        let inference = try await KataGoInference(role: .temporal, computeUnits: computeUnits)
        self.init(inference: inference)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - GamePlayer Protocol
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a seeded game position from a spatial column.
    ///
    /// For temporal view, sliceIndex is the x-column (x=0 to x=8).
    /// The 9×9 board shows time (rows) vs y-position (columns).
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - sliceIndex: Spatial column (0-8)
    /// - Returns: GamePosition with stones based on motion intensity
    @available(iOS 26.0, *)
    public func seedPosition(from tensor: TensorCube729, sliceIndex x: Int) -> GamePosition {
        precondition(x >= 0 && x < 9, "Slice index must be 0-8")

        // Collect importance values for all 81 positions (t × y)
        var importanceValues = [Float](repeating: 0, count: 81)

        for t in 0..<9 {
            for y in 0..<9 {
                let importance = computeMotionImportance(tensor: tensor, t: t, y: y, x: x)
                // Board layout: row=t, col=y
                importanceValues[t * 9 + y] = importance
            }
        }

        // Optionally normalize
        let finalValues = config.normalizeValues ? normalizeValues(importanceValues) : importanceValues

        // Place stones based on thresholds
        var board = [StoneColor](repeating: .empty, count: 81)
        var moveHistory: [(row: Int, col: Int, color: StoneColor)] = []
        var blackMoves: [(Int, Int, Float)] = []  // (t, y, importance)
        var whiteMoves: [(Int, Int, Float)] = []

        for i in 0..<81 {
            let t = i / 9  // Row = time
            let y = i % 9  // Col = spatial y
            let value = finalValues[i]

            if value >= config.blackThreshold {
                blackMoves.append((t, y, value))
            } else if value <= config.whiteThreshold {
                whiteMoves.append((t, y, value))
            }
        }

        // Sort by importance (highest first for black, lowest first for white)
        blackMoves.sort { $0.2 > $1.2 }
        whiteMoves.sort { $0.2 < $1.2 }

        // Interleave moves (Black first, as in Go)
        var moveIndex = 0
        while moveIndex < max(blackMoves.count, whiteMoves.count) {
            if moveIndex < blackMoves.count {
                let (t, y, _) = blackMoves[moveIndex]
                board[t * 9 + y] = .black
                moveHistory.append((t, y, .black))
            }
            if moveIndex < whiteMoves.count {
                let (t, y, _) = whiteMoves[moveIndex]
                board[t * 9 + y] = .white
                moveHistory.append((t, y, .white))
            }
            moveIndex += 1
        }

        // Compute statistics
        let stats = PositionStatistics(
            meanValue: finalValues.reduce(0, +) / Float(finalValues.count),
            stdDev: computeStdDev(finalValues),
            minValue: finalValues.min() ?? 0,
            maxValue: finalValues.max() ?? 0,
            threshold: config.blackThreshold
        )

        return GamePosition(
            board: board,
            moveHistory: moveHistory,
            toPlay: .black,
            komi: komi,
            statistics: stats
        )
    }

    /// Process all 9 spatial columns and return attention weights.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Array of 9 policy arrays, each with 81 weights
    @available(iOS 26.0, *)
    public func processAllSlices(from tensor: TensorCube729) async throws -> [[Float]] {
        var allWeights: [[Float]] = []

        // Process each spatial column
        for x in 0..<9 {
            let position = seedPosition(from: tensor, sliceIndex: x)
            let weights = try await extractWeights(from: position)
            allWeights.append(weights)
        }

        return allWeights
    }

    /// Process all slices and return detailed results.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: BatchProcessingResult with all slice data
    @available(iOS 26.0, *)
    public func processAllSlicesDetailed(from tensor: TensorCube729) async throws -> BatchProcessingResult {
        var sliceResults: [SliceResult] = []
        let startTime = Date()

        for x in 0..<9 {
            let position = seedPosition(from: tensor, sliceIndex: x)
            let weights = try await extractWeights(from: position)

            sliceResults.append(SliceResult(
                sliceIndex: x,
                position: position,
                weights: weights
            ))
        }

        let endTime = Date()

        return BatchProcessingResult(
            viewType: .temporal,
            sliceResults: sliceResults,
            totalInferenceTime: endTime.timeIntervalSince(startTime)
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute motion importance at position (t, y) for column x.
    ///
    /// Motion is computed as color change from t-1 to t.
    @available(iOS 26.0, *)
    private func computeMotionImportance(tensor: TensorCube729, t: Int, y: Int, x: Int) -> Float {
        // First frame has no motion (no previous frame)
        guard t > 0 else {
            // For first frame, use absolute brightness as proxy
            let cell = tensor[t, y, x]
            guard cell.totalWeight > 0 else { return 0 }
            let (r, g, b) = cell.centroidColor()
            return brightnessValue(r: r, g: g, b: b) * 0.3  // Reduced weight
        }

        // Get current and previous frame colors
        let currCell = tensor[t, y, x]
        let prevCell = tensor[t - 1, y, x]

        guard currCell.totalWeight > 0 && prevCell.totalWeight > 0 else { return 0 }

        let (r1, g1, b1) = prevCell.centroidColor()
        let (r2, g2, b2) = currCell.centroidColor()

        // Compute motion as color distance
        let motion = motionValue(r1: r1, g1: g1, b1: b1, r2: r2, g2: g2, b2: b2)

        // Optionally weight by brightness (motion in bright areas is more noticeable)
        let brightness = brightnessValue(r: r2, g: g2, b: b2)
        let weightedMotion = motion * (0.5 + brightness * 0.5)

        return weightedMotion
    }

    /// Compute standard deviation.
    private func computeStdDev(_ values: [Float]) -> Float {
        let n = Float(values.count)
        guard n > 1 else { return 0 }

        let mean = values.reduce(0, +) / n
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        return sqrt(variance)
    }
}

// MARK: - Debug Extensions

@available(iOS 15.0, macOS 12.0, *)
extension TemporalGamePlayer {

    /// Visualize a single column's temporal game position.
    @available(iOS 26.0, *)
    public func visualizeColumn(tensor: TensorCube729, columnIndex x: Int) -> String {
        let position = seedPosition(from: tensor, sliceIndex: x)
        let counts = position.stoneCounts

        var lines = [String]()
        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║  TEMPORAL GAME: Column \(x) (t/y view)                             ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║  Black (high motion):  \(String(format: "%2d", counts.black)) stones (key transitions)          ║")
        lines.append("║  White (low motion):   \(String(format: "%2d", counts.white)) stones (static frames)            ║")
        lines.append("║  Empty (medium):       \(String(format: "%2d", counts.empty)) positions                        ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║     0 1 2 3 4 5 6 7 8     ← y (spatial rows)                     ║")
        lines.append("║     ─────────────────                                            ║")

        for t in 0..<9 {
            var line = "║  \(t)  "
            for y in 0..<9 {
                switch position.stone(row: t, col: y) {
                case .black: line += "● "
                case .white: line += "○ "
                case .empty: line += "· "
                }
            }
            if t == 0 {
                line += "    t=0 (start)                          ║"
            } else if t == 4 {
                line += "    t=4 (middle)                         ║"
            } else if t == 8 {
                line += "    t=8 (end)                            ║"
            } else {
                line += "                                         ║"
            }
            lines.append(line)
        }
        lines.append("║     ↑                                                            ║")
        lines.append("║     t (time progression)                                         ║")
        lines.append("╚═══════════════════════════════════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }

    /// Generate motion heatmap for visualization.
    @available(iOS 26.0, *)
    public func motionHeatmap(tensor: TensorCube729, columnIndex x: Int) -> [[Float]] {
        var heatmap = [[Float]](repeating: [Float](repeating: 0, count: 9), count: 9)

        for t in 0..<9 {
            for y in 0..<9 {
                heatmap[t][y] = computeMotionImportance(tensor: tensor, t: t, y: y, x: x)
            }
        }

        return heatmap
    }
}

// MARK: - Axis Interpretation Note

/*
 IMPORTANT: Understanding the t/y board layout
 ═══════════════════════════════════════════════

 For the temporal view, each board represents a COLUMN (fixed x) over time:

     Board Coordinates          Tensor Coordinates
     ──────────────────         ──────────────────
     row = t (0-8)     →        time index
     col = y (0-8)     →        y spatial position

     board[t][y]       →        tensor[t, y, x=fixed]

 This means:
 • Moving DOWN the board = moving forward in TIME
 • Moving RIGHT = moving down spatially (y increases)
 • The whole board shows how one vertical slice of tiles evolves

 Example: For column x=4 (center of frame):
     ┌─────────────────────────────────────────┐
     │  t=0:  │ y0  y1  y2  y3  y4  y5  y6  y7  y8 │  Start
     │  t=1:  │ ··  ○   ○   ·   ●   ●   ·   ·   ·  │
     │  t=2:  │ ·   ·   ○   ●   ●   ●   ●   ·   ·  │  Motion
     │  ...   │                                     │  spreads
     │  t=8:  │ ○   ○   ○   ·   ·   ○   ○   ○   ○  │  End
     └─────────────────────────────────────────┘

 ● = High motion (Black) - important frame transition
 ○ = Low motion (White) - static, can skip
 · = Medium - let NN decide
*/
