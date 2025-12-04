//
//  SpatialGamePlayer.swift
//  RGB2GIF
//
//  ============================================================================
//  SPATIAL GAME PLAYER (x/y FRAME-BY-FRAME)
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Interprets the 9×9×9 tensor as 9 FRAMES, where each frame is a 9×9 Go board.
//  This is the SPATIAL view - focusing on which tiles matter at each moment.
//
//  PARSING STRATEGY
//  ────────────────
//  For each time slice t (0-8):
//      Create a 9×9 board where:
//          intersection[y][x] = tensor[t, y, x]
//
//      This means each frame shows the spatial distribution of colors
//      at that moment in time.
//
//  STONE PLACEMENT
//  ───────────────
//  High color intensity/saturation → Black (visually prominent, needs attention)
//  Low intensity (dark/gray) → White (background, can be approximated)
//  Medium values → Empty (contested, let the NN decide)
//
//  RULE SET
//  ────────
//  Uses Japanese rules (komi 5.5) which encourage:
//      • Territorial play (secure regions)
//      • Stable, balanced positions
//      • Efficient stone placement
//
//  This produces QUERY weights - indicating which spatial tiles are important.
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Spatial Game Player

/// Game player that interprets tensor as 9 spatial frames (x/y boards).
///
/// Each frame represents a moment in time, and the player determines
/// which tiles are visually important at that moment.
@available(iOS 15.0, macOS 12.0, *)
public final class SpatialGamePlayer: BaseGamePlayer, GamePlayer, @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ═══════════════════════════════════════════════════════════════════════════

    public let viewType: TensorViewType = .spatial

    /// Komi for Japanese rules (territorial, balanced).
    private let komi: Float = 5.5

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a spatial game player with the given inference engine.
    ///
    /// - Parameters:
    ///   - inference: KataGo inference engine (should use Japanese rules)
    ///   - config: Stone seeding configuration (default: spatial preset)
    public init(inference: KataGoInference, config: StoneSeedingConfig = .spatial) {
        super.init(inference: inference, config: config)
    }

    /// Convenience initializer that creates its own inference engine.
    ///
    /// - Parameter computeUnits: CoreML compute units
    /// - Throws: If model cannot be loaded
    public convenience init(computeUnits: MLComputeUnits = .all) async throws {
        let inference = try await KataGoInference(role: .spatial, computeUnits: computeUnits)
        self.init(inference: inference)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - GamePlayer Protocol
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a seeded game position from a time slice.
    ///
    /// For spatial view, sliceIndex is the time (t=0 to t=8).
    /// The 9×9 board shows spatial tiles at that moment.
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - sliceIndex: Time slice (0-8)
    /// - Returns: GamePosition with stones based on color intensity
    @available(iOS 26.0, *)
    public func seedPosition(from tensor: TensorCube729, sliceIndex t: Int) -> GamePosition {
        precondition(t >= 0 && t < 9, "Slice index must be 0-8")

        // Collect importance values for all 81 tiles
        var importanceValues = [Float](repeating: 0, count: 81)

        for y in 0..<9 {
            for x in 0..<9 {
                let cell = tensor[t, y, x]
                guard cell.totalWeight > 0 else { continue }

                let (r, g, b) = cell.centroidColor()
                let importance = computeImportance(r: r, g: g, b: b, tensor: tensor, t: t, y: y, x: x)
                importanceValues[y * 9 + x] = importance
            }
        }

        // Optionally normalize
        let finalValues = config.normalizeValues ? normalizeValues(importanceValues) : importanceValues

        // Place stones based on thresholds
        var board = [StoneColor](repeating: .empty, count: 81)
        var moveHistory: [(row: Int, col: Int, color: StoneColor)] = []
        var blackMoves: [(Int, Int, Float)] = []
        var whiteMoves: [(Int, Int, Float)] = []

        for i in 0..<81 {
            let y = i / 9
            let x = i % 9
            let value = finalValues[i]

            if value >= config.blackThreshold {
                blackMoves.append((y, x, value))
            } else if value <= config.whiteThreshold {
                whiteMoves.append((y, x, value))
            }
        }

        // Sort by importance (highest first for black, lowest first for white)
        blackMoves.sort { $0.2 > $1.2 }
        whiteMoves.sort { $0.2 < $1.2 }

        // Interleave moves (Black first, as in Go)
        var moveIndex = 0
        while moveIndex < max(blackMoves.count, whiteMoves.count) {
            if moveIndex < blackMoves.count {
                let (y, x, _) = blackMoves[moveIndex]
                board[y * 9 + x] = .black
                moveHistory.append((y, x, .black))
            }
            if moveIndex < whiteMoves.count {
                let (y, x, _) = whiteMoves[moveIndex]
                board[y * 9 + x] = .white
                moveHistory.append((y, x, .white))
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

    /// Process all 9 time slices and return attention weights.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Array of 9 policy arrays, each with 81 weights
    @available(iOS 26.0, *)
    public func processAllSlices(from tensor: TensorCube729) async throws -> [[Float]] {
        var allWeights: [[Float]] = []

        // Process each time slice
        for t in 0..<9 {
            let position = seedPosition(from: tensor, sliceIndex: t)
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

        for t in 0..<9 {
            let position = seedPosition(from: tensor, sliceIndex: t)
            let weights = try await extractWeights(from: position)

            sliceResults.append(SliceResult(
                sliceIndex: t,
                position: position,
                weights: weights
            ))
        }

        let endTime = Date()

        return BatchProcessingResult(
            viewType: .spatial,
            sliceResults: sliceResults,
            totalInferenceTime: endTime.timeIntervalSince(startTime)
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute importance value based on configuration.
    @available(iOS 26.0, *)
    private func computeImportance(
        r: UInt8, g: UInt8, b: UInt8,
        tensor: TensorCube729,
        t: Int, y: Int, x: Int
    ) -> Float {
        switch config.importanceMetric {
        case .brightness:
            return brightnessValue(r: r, g: g, b: b)

        case .saturation:
            return saturationValue(r: r, g: g, b: b)

        case .variance:
            // Compute variance across time for this spatial position
            return computeTemporalVariance(tensor: tensor, y: y, x: x)

        case .motion:
            // Compute motion from previous frame
            guard t > 0 else { return 0 }
            let prevCell = tensor[t - 1, y, x]
            guard prevCell.totalWeight > 0 else { return 0 }
            let (pr, pg, pb) = prevCell.centroidColor()
            return motionValue(r1: pr, g1: pg, b1: pb, r2: r, g2: g, b2: b)

        case .combined:
            let brightness = brightnessValue(r: r, g: g, b: b)
            let saturation = saturationValue(r: r, g: g, b: b)
            return (brightness + saturation) / 2.0
        }
    }

    /// Compute temporal variance for a spatial position.
    @available(iOS 26.0, *)
    private func computeTemporalVariance(tensor: TensorCube729, y: Int, x: Int) -> Float {
        var colors: [(Float, Float, Float)] = []

        for t in 0..<9 {
            let cell = tensor[t, y, x]
            if cell.totalWeight > 0 {
                let (r, g, b) = cell.centroidColor()
                colors.append((Float(r), Float(g), Float(b)))
            }
        }

        guard colors.count >= 2 else { return 0 }

        // Compute mean
        let meanR = colors.map { $0.0 }.reduce(0, +) / Float(colors.count)
        let meanG = colors.map { $0.1 }.reduce(0, +) / Float(colors.count)
        let meanB = colors.map { $0.2 }.reduce(0, +) / Float(colors.count)

        // Compute variance
        var variance: Float = 0
        for (r, g, b) in colors {
            variance += (r - meanR) * (r - meanR)
            variance += (g - meanG) * (g - meanG)
            variance += (b - meanB) * (b - meanB)
        }
        variance /= Float(colors.count * 3)

        // Normalize (max variance is 255^2 = 65025 per channel)
        return min(1.0, variance / (128.0 * 128.0))
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
extension SpatialGamePlayer {

    /// Visualize a single frame's game position.
    @available(iOS 26.0, *)
    public func visualizeFrame(tensor: TensorCube729, frameIndex t: Int) -> String {
        let position = seedPosition(from: tensor, sliceIndex: t)
        let counts = position.stoneCounts

        var lines = [String]()
        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║  SPATIAL GAME: Frame \(t) (x/y view)                               ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║  Black (high intensity): \(String(format: "%2d", counts.black)) stones                           ║")
        lines.append("║  White (low intensity):  \(String(format: "%2d", counts.white)) stones                           ║")
        lines.append("║  Empty (medium):         \(String(format: "%2d", counts.empty)) positions                        ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║     A B C D E F G H J     ← x (horizontal tiles)                 ║")

        for y in 0..<9 {
            var line = "║  \(9 - y)  "
            for x in 0..<9 {
                switch position.stone(row: y, col: x) {
                case .black: line += "● "
                case .white: line += "○ "
                case .empty: line += "· "
                }
            }
            line += "    ↑ y (vertical tiles)                 ║"
            if y == 4 { line = line.replacingOccurrences(of: "↑ y (vertical tiles)", with: "") + "                        ║" }
            lines.append(line)
        }

        lines.append("╚═══════════════════════════════════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}
