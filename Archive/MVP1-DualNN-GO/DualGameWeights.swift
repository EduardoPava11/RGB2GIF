//
//  DualGameWeights.swift
//  RGB2GIF
//
//  ============================================================================
//  DUAL-GAME ARCHITECTURE: Two GO Games for Palette Optimization
//  ============================================================================
//
//  THE CORE INSIGHT
//  ─────────────────
//  The 81×81×81 voxel cube factors in TWO orthogonal ways:
//
//    SPATIAL:  81×81 pixels = (9×9 tiles) × (9×9 pixels per tile)
//    TEMPORAL: 81 frames    = (9×9 groups) × (1 frame per "slot")
//
//  Each dimension maps to a 9×9 GO board. We play TWO games:
//
//    1. SPATIAL GAME:  Which tiles matter for color accuracy?
//    2. TEMPORAL GAME: Which time periods matter for color accuracy?
//
//  The games' outputs MERGE via lambdas into unified macro-cell weights.
//  These weights determine how 256 palette colors are distributed.
//
//  WHY GO?
//  ───────
//  GO provides BALANCE by construction:
//  - Territory is roughly equal between players (~40-41 points each)
//  - This prevents any single region from dominating the palette
//  - The neural network finds optimal balance, not human intuition
//
//  THE LAMBDA MERGE
//  ────────────────
//  For each of 729 macro-cells: weight = λ(spatial_w, temporal_w)
//
//  Possible merge functions:
//    • MULTIPLY: spatial × temporal (both must agree → selective)
//    • ADD:      (spatial + temporal) / 2 (average → balanced)
//    • MAX:      max(spatial, temporal) (either can promote → inclusive)
//    • MIN:      min(spatial, temporal) (both must agree → strict)
//    • LEARNED:  transformer predicts optimal λ per cell (future goal)
//
//  PALETTE ALLOCATION
//  ──────────────────
//  High-weight cells → dedicated palette entries (crisp colors)
//  Low-weight cells  → shared entries (dithered, approximated)
//
//  Example: If macro-cell (3,5,7) has weight 0.9 and cell (8,1,2) has 0.1,
//           the former gets precise colors, the latter borrows from neighbors.
//
//  ============================================================================

import Foundation

// MARK: - Dual Game Weights

/// Combines spatial and temporal GO game results into macro-cell weights.
///
/// ## Conceptual Model
///
/// ```
/// 81×81×81 Cube Factorization:
/// ════════════════════════════
///
///        ┌───────────── OUTER (9×9×9) ─────────────┐
///        │                                          │
///        │   Tile(0,0), Tile(0,1), ... Tile(0,8)    │  ← Row 0
///        │   Tile(1,0), Tile(1,1), ... Tile(1,8)    │  ← Row 1
///        │        ...        ...          ...       │
///        │   Tile(8,0), Tile(8,1), ... Tile(8,8)    │  ← Row 8
///        │                                          │
///        │   × 9 time groups (frames 0-8, 9-17, ..80)│
///        │                                          │
///        └──────────────────────────────────────────┘
///
/// Each macro-cell = one tile × one time group
/// Total: 9 × 9 × 9 = 729 macro-cells
///
/// SPATIAL GAME (9×9):
/// ┌─┬─┬─┬─┬─┬─┬─┬─┬─┐
/// │ │ │ │ │ │ │●│ │ │  ← Black stones = high spatial priority
/// ├─┼─┼─┼─┼─┼─┼─┼─┼─┤     (these tiles need accurate colors)
/// │ │ │○│ │ │●│ │ │ │
/// ├─┼─┼─┼─┼─┼─┼─┼─┼─┤  ← White stones = low spatial priority
/// │ │●│ │●│ │ │○│ │ │     (these tiles can be dithered)
/// │...                │
/// └─┴─┴─┴─┴─┴─┴─┴─┴─┘
///
/// TEMPORAL GAME (9×9):
/// ┌─┬─┬─┬─┬─┬─┬─┬─┬─┐
/// │ │●│ │ │○│ │ │ │ │  ← Each cell = 9 frames
/// ├─┼─┼─┼─┼─┼─┼─┼─┼─┤     Frame 0-8: cell (0,0)-(0,8)
/// │○│ │●│ │ │●│ │ │○│     Frame 9-17: cell (1,0)-(1,8)
/// │...                │     etc.
/// └─┴─┴─┴─┴─┴─┴─┴─┴─┘
///
/// LAMBDA MERGE:
///   weight(tile, time) = λ(spatial[tile], temporal[time])
/// ```
@available(iOS 26.0, *)
public struct DualGameWeights {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ════════════════════════════════════════════════════════════════════════

    /// Size of each game board (9×9 for GO)
    public static let boardSize: Int = 9

    /// Total macro-cells in the outer cube
    public static let totalMacroCells: Int = 729  // 9 × 9 × 9

    /// Default weight for unplayed regions (neutral)
    public static let neutralWeight: Float = 0.5

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Merge Strategies
    // ════════════════════════════════════════════════════════════════════════

    /// Lambda function for combining spatial and temporal weights.
    ///
    /// Each strategy has different characteristics:
    /// - **multiply**: Both dimensions must agree (selective, creates contrast)
    /// - **average**: Balanced combination (moderate, spreads palette)
    /// - **max**: Either dimension can promote (inclusive, more colors)
    /// - **min**: Both must agree (strict, fewer colors)
    /// - **geometric**: Square root of product (balanced multiplication)
    public enum MergeStrategy: String, CaseIterable {
        case multiply   // spatial × temporal
        case average    // (spatial + temporal) / 2
        case max        // max(spatial, temporal)
        case min        // min(spatial, temporal)
        case geometric  // sqrt(spatial × temporal)

        /// Apply the merge function to two weights.
        public func apply(_ spatial: Float, _ temporal: Float) -> Float {
            switch self {
            case .multiply:
                return spatial * temporal
            case .average:
                return (spatial + temporal) / 2.0
            case .max:
                return Swift.max(spatial, temporal)
            case .min:
                return Swift.min(spatial, temporal)
            case .geometric:
                return sqrt(spatial * temporal)
            }
        }

        /// Human-readable description of this strategy.
        public var description: String {
            switch self {
            case .multiply:
                return "Multiply: Both spatial and temporal must agree (selective)"
            case .average:
                return "Average: Balanced blend of both games (moderate)"
            case .max:
                return "Maximum: Either game can promote importance (inclusive)"
            case .min:
                return "Minimum: Both games must agree (strict)"
            case .geometric:
                return "Geometric: Square root of product (balanced contrast)"
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ════════════════════════════════════════════════════════════════════════

    /// Spatial game weights (9×9 board, one weight per tile).
    /// Values in range [0.0, 1.0] where:
    /// - 1.0 = maximum importance (Black territory → crisp colors)
    /// - 0.0 = minimum importance (White territory → dithered colors)
    public var spatialWeights: [[Float]]

    /// Temporal game weights (9×9 board mapped from 81 frames).
    /// Frame mapping: frame f → row f/9, col f%9
    /// Values in range [0.0, 1.0] with same semantics as spatial.
    public var temporalWeights: [[Float]]

    /// Current merge strategy for combining weights.
    public var mergeStrategy: MergeStrategy

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ════════════════════════════════════════════════════════════════════════

    /// Create with neutral weights (all 0.5).
    public init(strategy: MergeStrategy = .geometric) {
        let neutral = [[Float]](
            repeating: [Float](repeating: Self.neutralWeight, count: Self.boardSize),
            count: Self.boardSize
        )
        self.spatialWeights = neutral
        self.temporalWeights = neutral
        self.mergeStrategy = strategy
    }

    /// Create with specific weights from completed games.
    ///
    /// - Parameters:
    ///   - spatial: 9×9 weights from spatial GO game
    ///   - temporal: 9×9 weights from temporal GO game
    ///   - strategy: Merge function to use
    public init(
        spatial: [[Float]],
        temporal: [[Float]],
        strategy: MergeStrategy = .geometric
    ) {
        precondition(spatial.count == Self.boardSize)
        precondition(temporal.count == Self.boardSize)
        precondition(spatial.allSatisfy { $0.count == Self.boardSize })
        precondition(temporal.allSatisfy { $0.count == Self.boardSize })

        self.spatialWeights = spatial
        self.temporalWeights = temporal
        self.mergeStrategy = strategy
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Weight Queries
    // ════════════════════════════════════════════════════════════════════════

    /// Get merged weight for a specific macro-cell.
    ///
    /// - Parameters:
    ///   - tileRow: Spatial row (0-8)
    ///   - tileCol: Spatial column (0-8)
    ///   - timeGroup: Temporal group (0-8)
    /// - Returns: Combined weight [0.0, 1.0]
    public func weight(tileRow: Int, tileCol: Int, timeGroup: Int) -> Float {
        let spatial = spatialWeights[tileRow][tileCol]
        let temporal = temporalWeights[timeGroup / Self.boardSize][timeGroup % Self.boardSize]
        return mergeStrategy.apply(spatial, temporal)
    }

    /// Get merged weight for a pixel coordinate across frames.
    ///
    /// - Parameters:
    ///   - x: Pixel X coordinate (0-80)
    ///   - y: Pixel Y coordinate (0-80)
    ///   - frame: Frame number (0-80)
    /// - Returns: Combined weight [0.0, 1.0]
    public func weight(x: Int, y: Int, frame: Int) -> Float {
        let tileRow = y / 9
        let tileCol = x / 9
        let timeGroup = frame / 9
        return weight(tileRow: tileRow, tileCol: tileCol, timeGroup: timeGroup)
    }

    /// Get all 729 macro-cell weights as a flat array.
    ///
    /// Order: z-major (time), then y (row), then x (col)
    /// Index = timeGroup * 81 + tileRow * 9 + tileCol
    public func allWeights() -> [Float] {
        var weights = [Float]()
        weights.reserveCapacity(Self.totalMacroCells)

        for timeGroup in 0..<Self.boardSize {
            for tileRow in 0..<Self.boardSize {
                for tileCol in 0..<Self.boardSize {
                    let spatial = spatialWeights[tileRow][tileCol]
                    let temporal = temporalWeights[timeGroup][0]  // Use row for time mapping
                    weights.append(mergeStrategy.apply(spatial, temporal))
                }
            }
        }

        return weights
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Allocation
    // ════════════════════════════════════════════════════════════════════════

    /// Calculate palette color allocation based on weights.
    ///
    /// High-weight macro-cells get more dedicated palette entries.
    /// Returns how many colors to allocate per macro-cell.
    ///
    /// - Parameter totalColors: Total palette size (typically 256)
    /// - Returns: Array of color counts per macro-cell (729 entries)
    public func paletteAllocation(totalColors: Int = 256) -> [Int] {
        let weights = allWeights()
        let totalWeight = weights.reduce(0, +)

        guard totalWeight > 0 else {
            // Uniform distribution if all weights are zero
            let uniform = totalColors / Self.totalMacroCells
            return [Int](repeating: uniform, count: Self.totalMacroCells)
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

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Game State Conversion
    // ════════════════════════════════════════════════════════════════════════

    /// Convert GO board ownership to weight matrix.
    ///
    /// GO boards use: 0=empty, 1=black, 2=white
    /// Ownership prediction uses: -1=black, 0=neutral, +1=white
    ///
    /// We map: Black territory → high weight (1.0)
    ///         White territory → low weight (0.0)
    ///         Neutral → middle (0.5)
    ///
    /// - Parameter ownership: KataGo ownership prediction (-1 to +1)
    /// - Returns: Weight matrix (0.0 to 1.0)
    public static func weightsFromOwnership(_ ownership: [[Float]]) -> [[Float]] {
        // ownership: -1 (black) to +1 (white)
        // weight:    1.0 (black=important) to 0.0 (white=unimportant)
        return ownership.map { row in
            row.map { o in
                // Flip sign: -1 → 1.0, +1 → 0.0
                (1.0 - o) / 2.0
            }
        }
    }

    /// Convert simple board position (stones) to weight hints.
    ///
    /// - Parameter board: Flat array of 81 values (0=empty, 1=black, 2=white)
    /// - Returns: 9×9 weight matrix based on stone density
    public static func weightsFromBoard(_ board: [Int]) -> [[Float]] {
        precondition(board.count == 81)

        var weights = [[Float]](
            repeating: [Float](repeating: neutralWeight, count: boardSize),
            count: boardSize
        )

        for i in 0..<81 {
            let row = i / boardSize
            let col = i % boardSize

            switch board[i] {
            case 1:  // Black stone
                weights[row][col] = 1.0
            case 2:  // White stone
                weights[row][col] = 0.0
            default:  // Empty
                weights[row][col] = neutralWeight
            }
        }

        return weights
    }
}

// MARK: - Weight Visualization

@available(iOS 26.0, *)
extension DualGameWeights {

    /// Generate ASCII visualization of merged weights.
    public func visualize() -> String {
        var lines = [String]()
        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║  DUAL GAME WEIGHTS: Merged View (Time Group 0)                    ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║  Strategy: \(mergeStrategy.description.padding(toLength: 52, withPad: " ", startingAt: 0)) ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")

        let timeGroup = 0  // Show first time group

        // Header
        lines.append("║     0    1    2    3    4    5    6    7    8                     ║")
        lines.append("║   ┌────┬────┬────┬────┬────┬────┬────┬────┬────┐                  ║")

        for row in 0..<Self.boardSize {
            var line = "║ \(row) │"
            for col in 0..<Self.boardSize {
                let w = weight(tileRow: row, tileCol: col, timeGroup: timeGroup)
                let char = weightChar(w)
                line += " \(char)  │"
            }
            line += "                  ║"
            lines.append(line)

            if row < Self.boardSize - 1 {
                lines.append("║   ├────┼────┼────┼────┼────┼────┼────┼────┼────┤                  ║")
            }
        }

        lines.append("║   └────┴────┴────┴────┴────┴────┴────┴────┴────┘                  ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║  Legend: ██=1.0 ▓▓=0.75 ░░=0.5 ··=0.25   =0.0                   ║")
        lines.append("╚═══════════════════════════════════════════════════════════════════╝")

        return lines.joined(separator: "\n")
    }

    private func weightChar(_ w: Float) -> String {
        switch w {
        case 0.875...1.0:   return "██"
        case 0.625..<0.875: return "▓▓"
        case 0.375..<0.625: return "░░"
        case 0.125..<0.375: return "··"
        default:            return "  "
        }
    }

    /// Print detailed statistics.
    public func printStatistics() {
        let weights = allWeights()
        let sum = weights.reduce(0, +)
        let mean = sum / Float(weights.count)
        let sorted = weights.sorted()
        let median = sorted[sorted.count / 2]
        let minW = sorted.first ?? 0
        let maxW = sorted.last ?? 0

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  DUAL GAME STATISTICS                                             ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Total macro-cells: \(Self.totalMacroCells)                                          ║")
        print("║  Strategy: \(mergeStrategy.rawValue.padding(toLength: 54, withPad: " ", startingAt: 0))║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Weight Statistics:                                               ║")
        print("║    Mean:   \(String(format: "%.4f", mean))                                              ║")
        print("║    Median: \(String(format: "%.4f", median))                                              ║")
        print("║    Min:    \(String(format: "%.4f", minW))                                              ║")
        print("║    Max:    \(String(format: "%.4f", maxW))                                              ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
    }
}

// MARK: - Opening Book Integration

@available(iOS 26.0, *)
extension DualGameWeights {

    /// Apply weights from a KataGo opening book position.
    ///
    /// The opening book provides pre-computed professional analysis:
    /// - Board state (stones placed)
    /// - Policy distribution (where to play next)
    /// - Win rate predictions
    ///
    /// - Parameters:
    ///   - board: 81-element board array from opening book
    ///   - isSpaceGame: If true, applies to spatial weights; if false, temporal
    public mutating func applyFromOpeningBook(
        board: [Int],
        isSpaceGame: Bool
    ) {
        let weights = Self.weightsFromBoard(board)

        if isSpaceGame {
            spatialWeights = weights
        } else {
            temporalWeights = weights
        }
    }

    /// Apply both games from two opening book positions.
    ///
    /// This allows using different rule sets for each game:
    /// - Japanese rules (book9x9jp): More territorial, defensive
    /// - Tromp-Taylor rules (book9x9tt): More aggressive, fighting
    ///
    /// - Parameters:
    ///   - spatialBoard: Board state for spatial game
    ///   - temporalBoard: Board state for temporal game
    public mutating func applyFromOpeningBooks(
        spatialBoard: [Int],
        temporalBoard: [Int]
    ) {
        spatialWeights = Self.weightsFromBoard(spatialBoard)
        temporalWeights = Self.weightsFromBoard(temporalBoard)
    }
}
