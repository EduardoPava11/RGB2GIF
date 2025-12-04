//
//  GamePlayer.swift
//  RGB2GIF
//
//  ============================================================================
//  GAME PLAYER PROTOCOL FOR MVP1 DUAL-NN ATTENTION
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Defines the protocol for game players that interpret TensorCube729 data
//  as Go game positions and extract attention weights via KataGo inference.
//
//  TWO PARSING MODES
//  ─────────────────
//  SPATIAL (x/y frame-by-frame):
//      • 9×9×9 tensor parsed as 9 FRAMES
//      • Each frame is a 9×9 Go board
//      • Color intensity → stone placement
//      • 9 games × 81 weights = 729 spatial attention weights
//
//  TEMPORAL (x/t time-evolution):
//      • 9×9×9 tensor parsed as 9 COLUMNS
//      • Each column shows time evolution (t vs y)
//      • Motion/change → stone placement
//      • 9 games × 81 weights = 729 temporal attention weights
//
//  THE KEY INSIGHT
//  ───────────────
//  KataGo's policy output tells us WHERE IT WANTS TO PLAY, which is exactly
//  where attention is needed. By using the NN's game-playing intelligence,
//  we get sophisticated attention allocation without hand-crafted heuristics.
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Game Player Protocol

/// Protocol for game players that extract attention weights from tensor data.
///
/// Conforming types interpret the 9×9×9 tensor as Go game positions and use
/// KataGo neural network inference to extract attention weights.
@available(iOS 15.0, macOS 12.0, *)
public protocol GamePlayer: Sendable {

    /// The type of view this player uses to interpret tensor data.
    var viewType: TensorViewType { get }

    /// Create a seeded game position from a tensor slice.
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - sliceIndex: Which slice to use (0-8)
    /// - Returns: A GamePosition with stones placed based on tensor statistics
    @available(iOS 26.0, *)
    func seedPosition(from tensor: TensorCube729, sliceIndex: Int) -> GamePosition

    /// Run inference and extract attention weights from a game position.
    ///
    /// - Parameter position: The seeded game position
    /// - Returns: 81 attention weights (one per board intersection)
    func extractWeights(from position: GamePosition) async throws -> [Float]

    /// Process all 9 slices and return 9×81 = 729 weights.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Array of 9 policy arrays, each with 81 weights
    @available(iOS 26.0, *)
    func processAllSlices(from tensor: TensorCube729) async throws -> [[Float]]
}

// MARK: - Tensor View Type

/// How the 9×9×9 tensor is interpreted as Go game boards.
public enum TensorViewType: String, Sendable {
    /// Spatial view: parse as 9 frames (x/y boards over time)
    /// Each frame t gives a 9×9 board where tiles[y][x] = tensor[t, y, x]
    case spatial

    /// Temporal view: parse as 9 columns (t/y boards across x)
    /// Each column x gives a 9×9 board where tiles[t][y] = tensor[t, y, x]
    case temporal
}

// MARK: - Stone Seeding Configuration

/// Configuration for how tensor values map to stone placement.
public struct StoneSeedingConfig: Sendable {

    /// Threshold for placing Black stones (high importance).
    /// Values above this are marked as Black.
    public var blackThreshold: Float = 0.6

    /// Threshold for placing White stones (low importance).
    /// Values below this are marked as White.
    public var whiteThreshold: Float = 0.3

    /// How to compute the importance value from color data.
    public var importanceMetric: ImportanceMetric = .brightness

    /// Whether to normalize values before thresholding.
    public var normalizeValues: Bool = true

    /// Minimum stones to ensure (prevents trivial empty positions).
    public var minStones: Int = 10

    public init() {}

    /// Predefined configuration for spatial (frame-by-frame) parsing.
    public static var spatial: StoneSeedingConfig {
        var config = StoneSeedingConfig()
        config.importanceMetric = .brightness
        config.blackThreshold = 0.65
        config.whiteThreshold = 0.35
        return config
    }

    /// Predefined configuration for temporal (motion-based) parsing.
    public static var temporal: StoneSeedingConfig {
        var config = StoneSeedingConfig()
        config.importanceMetric = .motion
        config.blackThreshold = 0.25  // Motion is typically lower magnitude
        config.whiteThreshold = 0.08
        return config
    }
}

/// How to compute importance value for stone seeding.
public enum ImportanceMetric: String, Sendable {
    /// Use color brightness (R+G+B)/3
    case brightness

    /// Use saturation (color vs gray)
    case saturation

    /// Use motion (change from previous frame)
    case motion

    /// Use variance (change across time/space)
    case variance

    /// Combine brightness and saturation
    case combined
}

// MARK: - Base Game Player Implementation

/// Base implementation with shared functionality for game players.
@available(iOS 15.0, macOS 12.0, *)
public class BaseGamePlayer {

    /// The KataGo inference engine.
    public let inference: KataGoInference

    /// Configuration for stone seeding.
    public let config: StoneSeedingConfig

    /// Initialize with an inference engine and configuration.
    public init(inference: KataGoInference, config: StoneSeedingConfig) {
        self.inference = inference
        self.config = config
    }

    /// Extract weights from a game position using KataGo inference.
    public func extractWeights(from position: GamePosition) async throws -> [Float] {
        let (spatial, global) = try BoardEncoder.encodeGamePosition(position)
        let output = try await inference.predict(spatial: spatial, global: global)
        return output.boardPolicy  // 81 weights
    }

    /// Compute brightness-based importance value.
    public func brightnessValue(r: UInt8, g: UInt8, b: UInt8) -> Float {
        return (Float(r) + Float(g) + Float(b)) / (3.0 * 255.0)
    }

    /// Compute saturation-based importance value.
    public func saturationValue(r: UInt8, g: UInt8, b: UInt8) -> Float {
        let maxC = Float(max(r, g, b))
        let minC = Float(min(r, g, b))
        guard maxC > 0 else { return 0 }
        return (maxC - minC) / maxC
    }

    /// Compute motion between two colors (normalized Euclidean distance).
    public func motionValue(
        r1: UInt8, g1: UInt8, b1: UInt8,
        r2: UInt8, g2: UInt8, b2: UInt8
    ) -> Float {
        let dr = Float(r2) - Float(r1)
        let dg = Float(g2) - Float(g1)
        let db = Float(b2) - Float(b1)
        // Max possible distance is sqrt(255^2 * 3) ≈ 441.67
        return sqrt(dr*dr + dg*dg + db*db) / 441.67
    }

    /// Place stone based on importance value and thresholds.
    public func stoneForImportance(_ value: Float, config: StoneSeedingConfig) -> StoneColor {
        if value >= config.blackThreshold {
            return .black
        } else if value <= config.whiteThreshold {
            return .white
        } else {
            return .empty
        }
    }

    /// Normalize values to [0, 1] range using min-max scaling.
    public func normalizeValues(_ values: [Float]) -> [Float] {
        guard let minVal = values.min(), let maxVal = values.max(), maxVal > minVal else {
            return values
        }
        let range = maxVal - minVal
        return values.map { ($0 - minVal) / range }
    }
}

// MARK: - Slice Result

/// Result of processing a single tensor slice.
public struct SliceResult: Sendable {
    /// The slice index (0-8).
    public let sliceIndex: Int

    /// The game position created from this slice.
    public let position: GamePosition

    /// The 81 attention weights extracted from this slice.
    public let weights: [Float]

    /// Policy confidence (how decisive the NN was).
    public var confidence: Float {
        guard let maxWeight = weights.max() else { return 0 }
        return maxWeight
    }

    /// Number of stones placed.
    public var stoneCount: Int {
        let counts = position.stoneCounts
        return counts.black + counts.white
    }
}

// MARK: - Batch Processing

/// Results from processing all 9 slices of a tensor.
public struct BatchProcessingResult: Sendable {
    /// View type used for parsing.
    public let viewType: TensorViewType

    /// Results for each slice (9 total).
    public let sliceResults: [SliceResult]

    /// All 729 weights flattened (9 slices × 81 weights).
    public var flattenedWeights: [Float] {
        sliceResults.flatMap { $0.weights }
    }

    /// Reshape to 9×9×9 grid matching tensor dimensions.
    ///
    /// For spatial view: weights[t][y*9+x] = attention for tensor[t, y, x]
    /// For temporal view: weights[x][t*9+y] = attention for tensor[t, y, x]
    public var weightsGrid: [[[Float]]] {
        var grid = [[[Float]]](
            repeating: [[Float]](repeating: [Float](repeating: 0, count: 9), count: 9),
            count: 9
        )

        for (sliceIdx, result) in sliceResults.enumerated() {
            for i in 0..<81 {
                let row = i / 9
                let col = i % 9

                switch viewType {
                case .spatial:
                    // spatial: slice=t, policy[y*9+x]
                    grid[sliceIdx][row][col] = result.weights[i]
                case .temporal:
                    // temporal: slice=x, policy[t*9+y]
                    // Need to map: grid[t][y][x] = weights[x][t*9+y]
                    // Here sliceIdx=x, row=t, col=y
                    // grid[row][col][sliceIdx] = result.weights[i]
                    // Actually: i = row*9 + col where row=t, col=y
                    // So grid[row][col][sliceIdx] = weights[i]
                    grid[row][col][sliceIdx] = result.weights[i]
                }
            }
        }

        return grid
    }

    /// Average confidence across all slices.
    public var averageConfidence: Float {
        guard !sliceResults.isEmpty else { return 0 }
        return sliceResults.map { $0.confidence }.reduce(0, +) / Float(sliceResults.count)
    }

    /// Total inference time (if tracked).
    public var totalInferenceTime: TimeInterval?
}

// MARK: - Debug Extensions

@available(iOS 15.0, macOS 12.0, *)
extension BatchProcessingResult {

    /// Generate ASCII visualization of attention weights.
    public func visualize() -> String {
        var lines = [String]()
        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║  Batch Processing Result: \(viewType.rawValue.uppercased()) VIEW             ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║  Slices: \(sliceResults.count)                                                   ║")
        lines.append("║  Total Weights: \(flattenedWeights.count)                                           ║")
        lines.append("║  Avg Confidence: \(String(format: "%.3f", averageConfidence))                                      ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")

        // Show per-slice summary
        for result in sliceResults {
            let counts = result.position.stoneCounts
            lines.append("║  Slice \(result.sliceIndex): \(counts.black)B/\(counts.white)W stones, confidence=\(String(format: "%.3f", result.confidence))       ║")
        }

        lines.append("╚═══════════════════════════════════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}
