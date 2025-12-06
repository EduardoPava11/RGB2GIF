//
//  GameRecord.swift
//  RGB2GIF
//
//  ============================================================================
//  GAME RECORD: MOVE HISTORY AND STATE TRACKING
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Tracks the complete history of a Go game played from tensor data.
//  This enables:
//      1. Replay and visualization of game progression
//      2. Full sequential play (multiple inference steps)
//      3. SGF export for external analysis
//      4. Attention weight extraction from game history
//
//  The GameRecord captures every move made by the NN when "playing" the
//  tensor, providing a richer source of attention data than single-inference.
//
//  ============================================================================

import Foundation

// MARK: - Move

/// A single move in a Go game.
public struct Move: Sendable, Codable, Equatable {
    /// Row on the board (0-8).
    public let row: Int

    /// Column on the board (0-8).
    public let col: Int

    /// Color of the stone placed.
    public let color: StoneColor

    /// Move number (1-based).
    public let moveNumber: Int

    /// Policy confidence for this move (if available).
    public let confidence: Float?

    /// Alternative moves considered (top-3 by policy).
    public let alternatives: [(row: Int, col: Int, confidence: Float)]?

    public init(
        row: Int,
        col: Int,
        color: StoneColor,
        moveNumber: Int = 1,
        confidence: Float? = nil,
        alternatives: [(row: Int, col: Int, confidence: Float)]? = nil
    ) {
        self.row = row
        self.col = col
        self.color = color
        self.moveNumber = moveNumber
        self.confidence = confidence
        self.alternatives = alternatives
    }

    /// Standard Go coordinate notation (e.g., "E5").
    public var coordinate: String {
        // Go boards skip 'I' in column naming
        let columnLetters = "ABCDEFGHJKLMNOPQRS"
        let colLetter = columnLetters[columnLetters.index(columnLetters.startIndex, offsetBy: col)]
        return "\(colLetter)\(9 - row)"
    }

    /// SGF format for this move (e.g., ";B[ee]").
    public var sgfNotation: String {
        let colorChar = color == .black ? "B" : "W"
        let colChar = Character(UnicodeScalar(97 + col)!)  // 'a' = 97
        let rowChar = Character(UnicodeScalar(97 + row)!)
        return ";\(colorChar)[\(colChar)\(rowChar)]"
    }
}

// Make alternatives Codable by manually handling it
extension Move {
    enum CodingKeys: String, CodingKey {
        case row, col, color, moveNumber, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.row = try container.decode(Int.self, forKey: .row)
        self.col = try container.decode(Int.self, forKey: .col)
        self.color = try container.decode(StoneColor.self, forKey: .color)
        self.moveNumber = try container.decode(Int.self, forKey: .moveNumber)
        self.confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
        self.alternatives = nil  // Tuples can't be decoded, skip
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(row, forKey: .row)
        try container.encode(col, forKey: .col)
        try container.encode(color, forKey: .color)
        try container.encode(moveNumber, forKey: .moveNumber)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        // Skip alternatives (tuple can't be encoded)
    }

    // Manual Equatable implementation (tuples can't auto-conform)
    public static func == (lhs: Move, rhs: Move) -> Bool {
        lhs.row == rhs.row &&
        lhs.col == rhs.col &&
        lhs.color == rhs.color &&
        lhs.moveNumber == rhs.moveNumber &&
        lhs.confidence == rhs.confidence
        // Ignore alternatives for equality check
    }
}

// MARK: - Game Record

/// Complete record of a Go game played from tensor data.
public struct GameRecord: Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ═══════════════════════════════════════════════════════════════════════════

    /// Unique identifier for this game.
    public let gameID: UUID

    /// The view type used (spatial or temporal).
    public let viewType: TensorViewType

    /// Which slice this game represents (0-8).
    public let sliceIndex: Int

    /// Sequence of moves played.
    public private(set) var moves: [Move]

    /// The initial (seeded) position before any NN moves.
    public let initialPosition: GamePosition

    /// The final position after all moves.
    public private(set) var finalPosition: GamePosition

    /// Value predictions at each move (win probability).
    public private(set) var valuePredictions: [Float]

    /// Policy outputs at each move (81 weights).
    public private(set) var policyHistory: [[Float]]

    /// Ownership predictions at each move (81 values).
    public private(set) var ownershipHistory: [[Float]]

    /// Game result (if completed).
    public var result: GameResult?

    /// Timestamp when game started.
    public let startTime: Date

    /// Timestamp when game ended.
    public var endTime: Date?

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Computed Properties
    // ═══════════════════════════════════════════════════════════════════════════

    /// Number of moves played.
    public var moveCount: Int {
        moves.count
    }

    /// Whether the game has ended.
    public var isComplete: Bool {
        result != nil
    }

    /// Duration of the game.
    public var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// Average confidence across all moves.
    public var averageConfidence: Float {
        let confidences = moves.compactMap { $0.confidence }
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Float(confidences.count)
    }

    /// Final policy as attention weights (from last move or initial).
    public var finalAttentionWeights: [Float] {
        policyHistory.last ?? []
    }

    /// Cumulative attention weights (average across all moves).
    public var cumulativeAttentionWeights: [Float] {
        guard !policyHistory.isEmpty else { return [] }

        var cumulative = [Float](repeating: 0, count: 81)
        for policy in policyHistory {
            for i in 0..<min(81, policy.count) {
                cumulative[i] += policy[i]
            }
        }

        let n = Float(policyHistory.count)
        return cumulative.map { $0 / n }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a new game record.
    public init(
        viewType: TensorViewType,
        sliceIndex: Int,
        initialPosition: GamePosition
    ) {
        self.gameID = UUID()
        self.viewType = viewType
        self.sliceIndex = sliceIndex
        self.initialPosition = initialPosition
        self.finalPosition = initialPosition
        self.moves = []
        self.valuePredictions = []
        self.policyHistory = []
        self.ownershipHistory = []
        self.result = nil
        self.startTime = Date()
        self.endTime = nil
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Mutation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Record a move being played.
    public mutating func recordMove(
        _ move: Move,
        newPosition: GamePosition,
        policy: [Float],
        value: Float,
        ownership: [Float]
    ) {
        moves.append(move)
        finalPosition = newPosition
        policyHistory.append(policy)
        valuePredictions.append(value)
        ownershipHistory.append(ownership)
    }

    /// Mark the game as complete.
    public mutating func complete(result: GameResult) {
        self.result = result
        self.endTime = Date()
    }
}

// MARK: - Game Result

/// Result of a completed game.
public enum GameResult: Sendable {
    /// Game ended with consecutive passes.
    case passes(blackScore: Float, whiteScore: Float)

    /// Game ended by resignation.
    case resignation(winner: StoneColor)

    /// Game ended after move limit.
    case moveLimitReached(moveCount: Int)

    /// NN passed (no good moves found).
    case nnPassed

    /// Winner of the game.
    public var winner: StoneColor? {
        switch self {
        case .passes(let black, let white):
            if black > white { return .black }
            else if white > black { return .white }
            else { return nil }
        case .resignation(let winner):
            return winner
        case .moveLimitReached, .nnPassed:
            return nil
        }
    }

    /// Score differential.
    public var scoreDiff: Float? {
        switch self {
        case .passes(let black, let white):
            return black - white
        default:
            return nil
        }
    }
}

// MARK: - SGF Export

extension GameRecord {

    /// Generate SGF (Smart Game Format) representation.
    ///
    /// This allows viewing the game in external Go software.
    public func toSGF() -> String {
        var sgf = "(;GM[1]FF[4]CA[UTF-8]"
        sgf += "SZ[9]"  // Board size
        sgf += "PB[RGB2GIF \(viewType.rawValue.capitalized) Player]"
        sgf += "PW[Seeded Position]"
        sgf += "KM[\(initialPosition.komi)]"
        sgf += "GN[\(viewType.rawValue.capitalized) Slice \(sliceIndex)]"
        sgf += "DT[\(ISO8601DateFormatter().string(from: startTime))]"

        // Add initial position as setup stones
        let setup = initialPositionSetup()
        if !setup.isEmpty {
            sgf += setup
        }

        // Add moves
        for move in moves {
            sgf += move.sgfNotation
        }

        // Add result
        if let result = result {
            switch result {
            case .passes(let black, let white):
                let diff = black - white
                if diff > 0 {
                    sgf += ";RE[B+\(String(format: "%.1f", diff))]"
                } else if diff < 0 {
                    sgf += ";RE[W+\(String(format: "%.1f", -diff))]"
                } else {
                    sgf += ";RE[0]"
                }
            case .resignation(let winner):
                sgf += ";RE[\(winner == .black ? "B" : "W")+R]"
            case .moveLimitReached:
                sgf += ";RE[Void]"
            case .nnPassed:
                sgf += ";RE[?]"
            }
        }

        sgf += ")"
        return sgf
    }

    private func initialPositionSetup() -> String {
        var blackStones: [String] = []
        var whiteStones: [String] = []

        for row in 0..<9 {
            for col in 0..<9 {
                let colChar = Character(UnicodeScalar(97 + col)!)
                let rowChar = Character(UnicodeScalar(97 + row)!)
                let coord = "\(colChar)\(rowChar)"

                switch initialPosition.stone(row: row, col: col) {
                case .black:
                    blackStones.append(coord)
                case .white:
                    whiteStones.append(coord)
                case .empty:
                    break
                }
            }
        }

        var setup = ""
        if !blackStones.isEmpty {
            setup += "AB" + blackStones.map { "[\($0)]" }.joined()
        }
        if !whiteStones.isEmpty {
            setup += "AW" + whiteStones.map { "[\($0)]" }.joined()
        }

        return setup
    }
}

// MARK: - Debug Extensions

extension GameRecord {

    /// Generate ASCII visualization of the game.
    public func visualize() -> String {
        var lines = [String]()
        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║  GAME RECORD: \(viewType.rawValue.uppercased()) Slice \(sliceIndex)                              ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")
        lines.append("║  Moves: \(moveCount)   Avg Confidence: \(String(format: "%.3f", averageConfidence))                     ║")

        if let duration = duration {
            lines.append("║  Duration: \(String(format: "%.2f", duration))s                                         ║")
        }

        if let result = result {
            lines.append("║  Result: \(resultDescription(result))                                      ║")
        }

        lines.append("╠═══════════════════════════════════════════════════════════════════╣")

        // Final position
        lines.append("║  Final Position:                                                  ║")
        let counts = finalPosition.stoneCounts
        lines.append("║    Black: \(counts.black)  White: \(counts.white)  Empty: \(counts.empty)                              ║")
        lines.append("╚═══════════════════════════════════════════════════════════════════╝")

        return lines.joined(separator: "\n")
    }

    private func resultDescription(_ result: GameResult) -> String {
        switch result {
        case .passes(let black, let white):
            let diff = black - white
            if diff > 0 {
                return "B+\(String(format: "%.1f", diff))"
            } else if diff < 0 {
                return "W+\(String(format: "%.1f", -diff))"
            } else {
                return "Draw"
            }
        case .resignation(let winner):
            return "\(winner == .black ? "B" : "W")+Resign"
        case .moveLimitReached(let count):
            return "Move limit (\(count))"
        case .nnPassed:
            return "NN passed"
        }
    }
}

// MARK: - Game Record Collection

/// Collection of game records from processing a full tensor.
public struct TensorGameCollection: Sendable {
    /// Spatial game records (9 total, one per frame).
    public var spatialGames: [GameRecord]

    /// Temporal game records (9 total, one per column).
    public var temporalGames: [GameRecord]

    /// Combined attention weights (729 total).
    public var attentionWeights: AttentionWeights?

    /// Total processing time.
    public var processingTime: TimeInterval?

    public init() {
        self.spatialGames = []
        self.temporalGames = []
    }

    /// Generate summary statistics.
    public var summary: String {
        """
        TensorGameCollection Summary:
          Spatial Games: \(spatialGames.count)
          Temporal Games: \(temporalGames.count)
          Total Moves: \(spatialGames.map { $0.moveCount }.reduce(0, +) + temporalGames.map { $0.moveCount }.reduce(0, +))
          Avg Spatial Confidence: \(String(format: "%.3f", spatialGames.map { $0.averageConfidence }.reduce(0, +) / max(1, Float(spatialGames.count))))
          Avg Temporal Confidence: \(String(format: "%.3f", temporalGames.map { $0.averageConfidence }.reduce(0, +) / max(1, Float(temporalGames.count))))
        """
    }
}
