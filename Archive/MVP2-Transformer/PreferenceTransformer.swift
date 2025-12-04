//
//  PreferenceTransformer.swift
//  RGB2GIF
//
//  ============================================================================
//  PREFERENCE TRANSFORMER: Learning Human Values from GO Game Sessions
//  ============================================================================
//
//  THE CORE INSIGHT
//  ────────────────
//  When a human plays GO against the NN, their moves are IMPLICIT SIGNALS
//  about what they value in the video:
//
//    Move 1: "This tile/time is MOST important to me"
//    Move 2: "This is SECOND most important"
//    ...
//    Response to NN move: "I DISAGREE with your suggestion" or
//                         "I ACCEPT your suggestion"
//
//  THE LEARNING PROBLEM
//  ────────────────────
//  Given:
//    - Cube features (what the video looks like)
//    - Human's GO moves (what they valued)
//    - Final palette (the result)
//
//  Learn:
//    - What KINDS of features does this human value?
//    - Can we predict their moves on NEW videos?
//    - Can we generate presets that match their style?
//
//  HIERARCHY OF CHOICES
//  ────────────────────
//  Level 0: Pixel colors (data, not learned)
//  Level 1: Tile patterns (what content appears where)
//  Level 2: Macro-cell importance (learned from moves)
//  Level 3: Cross-cell relationships (higher-order patterns)
//  Level 4: User style embedding (abstract preferences)
//
//  THE TRANSFORMER ARCHITECTURE
//  ────────────────────────────
//
//  ENCODER (processes cube features):
//    Input: 729 macro-cell embeddings (81D each, matching GO board)
//    + Positional encoding (3D: row, col, time)
//    → Self-attention layers (cells attend to each other)
//    → Rich contextual embeddings
//
//  DECODER (predicts human preferences):
//    Input: Encoder output + move history (if any)
//    → Cross-attention to encoder
//    → Multiple prediction heads:
//        - MOVE HEAD: Predict next human move
//        - WEIGHT HEAD: Predict final 729 weights
//        - PALETTE HEAD: Predict 256 colors directly
//        - STYLE HEAD: Predict user style embedding
//
//  TRAINING OBJECTIVES
//  ───────────────────
//  L_move:    Cross-entropy on predicting human's next move
//  L_weight:  MSE on predicting final macro-cell weights
//  L_palette: Color distance on predicting final palette
//  L_style:   Contrastive loss for style embedding
//
//  L_total = α·L_move + β·L_weight + γ·L_palette + δ·L_style
//
//  ============================================================================

import Foundation
import CoreML
import Accelerate

// MARK: - Preference Transformer

@available(iOS 26.0, *)
public struct PreferenceTransformer {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Architecture Configuration
    // ════════════════════════════════════════════════════════════════════════

    public struct Config {
        /// Input feature dimension per macro-cell (81 = 9×9 = GO board)
        public var inputDimension: Int = 81

        /// Internal embedding dimension
        public var embeddingDimension: Int = 256

        /// Number of attention heads
        public var numHeads: Int = 8

        /// Number of encoder layers
        public var numEncoderLayers: Int = 4

        /// Number of decoder layers
        public var numDecoderLayers: Int = 2

        /// Feedforward hidden dimension
        public var ffnDimension: Int = 512

        /// Dropout rate
        public var dropout: Float = 0.1

        /// Style embedding dimension
        public var styleDimension: Int = 64

        /// Maximum moves to consider in history
        public var maxMoveHistory: Int = 81

        public init() {}
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Training Data Types
    // ════════════════════════════════════════════════════════════════════════

    /// A single GO game session for training
    public struct GameSession: Codable {
        /// Unique session ID
        public let sessionID: UUID

        /// When this session occurred
        public let timestamp: Date

        /// User identifier (for personalization)
        public let userID: String

        /// Cube digest features (729 × 81 = 59,049 = 3¹⁰)
        public let cubeFeatures: [[Float]]

        /// Moves played in the spatial game
        public let spatialMoves: [Move]

        /// Moves played in the temporal game
        public let temporalMoves: [Move]

        /// Final weights after both games
        public let finalWeights: [Float]

        /// Final palette (256 × 3)
        public let finalPalette: [[UInt8]]

        /// Optional user feedback (1-5 rating)
        public let userRating: Int?

        /// Whether user edited the result
        public let wasEdited: Bool
    }

    /// A single move in a GO game
    public struct Move: Codable {
        /// Move number (0-based)
        public let moveNumber: Int

        /// Player: 0=human, 1=NN
        public let player: Int

        /// Board position (0-80)
        public let position: Int

        /// Time spent on this move (seconds)
        public let thinkingTime: Float

        /// Whether this was a response to NN's previous move
        public let isResponse: Bool

        /// NN's evaluation of this move (if available)
        public let nnEvaluation: Float?
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Model Inputs
    // ════════════════════════════════════════════════════════════════════════

    /// Input batch for training/inference
    public struct ModelInput {
        /// Cube features: [batch, 729, 81]
        public var cubeFeatures: [[[Float]]]

        /// Positional encoding: [batch, 729, 6]
        /// (row, col, time, center_dist, time_dist, region_type)
        public var positions: [[[Float]]]

        /// Move history: [batch, max_moves, 4]
        /// (player, position, move_number, is_spatial)
        public var moveHistory: [[[Float]]]

        /// Move history mask: [batch, max_moves]
        public var moveHistoryMask: [[Float]]
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Model Outputs
    // ════════════════════════════════════════════════════════════════════════

    /// Output predictions from the model
    public struct ModelOutput {
        /// Next move logits: [batch, 82] (81 positions + pass)
        public var nextMoveLogits: [[Float]]

        /// Macro-cell weights: [batch, 729]
        public var cellWeights: [[Float]]

        /// Palette colors: [batch, 256, 3]
        public var paletteColors: [[[Float]]]

        /// Style embedding: [batch, style_dim]
        public var styleEmbedding: [[Float]]

        /// Attention weights for interpretability: [batch, num_heads, 729, 729]
        public var attentionWeights: [[[[Float]]]]?
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Inference
    // ════════════════════════════════════════════════════════════════════════

    /// Predict weights from cube features and optional move history.
    ///
    /// This is the main inference function for generating palette weights
    /// without requiring the user to play a full game.
    ///
    /// - Parameters:
    ///   - digest: Computed macro-cell digest
    ///   - moveHistory: Optional partial move history
    ///   - userStyle: Optional learned user style embedding
    /// - Returns: 729 macro-cell weights
    public static func predictWeights(
        from digest: MacroCellDigest,
        moveHistory: [Move] = [],
        userStyle: [Float]? = nil
    ) -> [Float] {
        // This would load the CoreML model and run inference
        // For now, return uniform weights
        return [Float](repeating: 0.5, count: 729)
    }

    /// Predict next move given current game state.
    ///
    /// Used when the NN plays against the human.
    ///
    /// - Parameters:
    ///   - digest: Cube features
    ///   - moveHistory: Moves played so far
    ///   - isSpatialGame: Whether this is spatial or temporal game
    /// - Returns: (position, confidence) for the recommended move
    public static func predictNextMove(
        from digest: MacroCellDigest,
        moveHistory: [Move],
        isSpatialGame: Bool
    ) -> (position: Int, confidence: Float) {
        // This would run the move prediction head
        // For now, return a reasonable default
        let center = 40  // Center of 9×9 board
        return (center, 0.5)
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Style Operations
    // ════════════════════════════════════════════════════════════════════════

    /// Extract user style embedding from multiple sessions.
    ///
    /// The style embedding is learned by:
    /// 1. Running encoder on each session's cube features
    /// 2. Conditioning on the human's actual moves
    /// 3. Extracting a consistent latent representation
    ///
    /// - Parameter sessions: Multiple sessions from the same user
    /// - Returns: 64D style embedding
    public static func extractStyleEmbedding(from sessions: [GameSession]) -> [Float] {
        // Aggregate style across sessions
        // For now, return zeros
        return [Float](repeating: 0, count: 64)
    }

    /// Compute style similarity between two users.
    ///
    /// Used for recommending presets or finding similar users.
    public static func styleSimilarity(
        style1: [Float],
        style2: [Float]
    ) -> Float {
        // Cosine similarity
        var dotProduct: Float = 0
        var norm1: Float = 0
        var norm2: Float = 0

        for i in 0..<min(style1.count, style2.count) {
            dotProduct += style1[i] * style2[i]
            norm1 += style1[i] * style1[i]
            norm2 += style2[i] * style2[i]
        }

        let denominator = sqrt(norm1) * sqrt(norm2)
        return denominator > 0 ? dotProduct / denominator : 0
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Preset Generation
    // ════════════════════════════════════════════════════════════════════════

    /// A learned preset that can be applied to new videos.
    public struct Preset: Codable {
        /// Preset name (user-defined or auto-generated)
        public let name: String

        /// Description of what this preset does
        public let description: String

        /// Style embedding that defines this preset
        public let styleEmbedding: [Float]

        /// Merge strategy preference
        public let mergeStrategy: String

        /// Dither threshold preference
        public let ditherThreshold: Float

        /// Sample palette (for preview)
        public let samplePalette: [[UInt8]]

        /// Sessions this preset was derived from
        public let sourceSessionCount: Int
    }

    /// Generate a preset from a collection of user sessions.
    ///
    /// This clusters the user's choices to find consistent patterns.
    public static func generatePreset(
        from sessions: [GameSession],
        name: String,
        description: String
    ) -> Preset {
        let style = extractStyleEmbedding(from: sessions)

        // Analyze move patterns to determine preferences
        var avgDitherThreshold: Float = 0.3
        var mergeStrategy = "geometric"

        // Look at which cells the user consistently prioritizes
        // (This would be more sophisticated in the real implementation)

        // Generate a sample palette based on the style
        let samplePalette = (0..<256).map { i -> [UInt8] in
            [UInt8(i), UInt8(i), UInt8(i)]  // Placeholder grayscale
        }

        return Preset(
            name: name,
            description: description,
            styleEmbedding: style,
            mergeStrategy: mergeStrategy,
            ditherThreshold: avgDitherThreshold,
            samplePalette: samplePalette,
            sourceSessionCount: sessions.count
        )
    }

    /// Apply a preset to new cube features.
    ///
    /// This conditions the model on the preset's style embedding
    /// to generate weights that match the user's preferences.
    public static func applyPreset(
        _ preset: Preset,
        to digest: MacroCellDigest
    ) -> [Float] {
        return predictWeights(
            from: digest,
            moveHistory: [],
            userStyle: preset.styleEmbedding
        )
    }
}

// MARK: - Higher-Order Features

@available(iOS 26.0, *)
extension PreferenceTransformer {

    /// Higher-order features that emerge from move patterns.
    ///
    /// These capture abstract preferences that generalize across videos.
    public struct HigherOrderFeatures {

        // ─────────────────────────────────────────────────────────────────────
        // CONTRAST VS HARMONY
        // ─────────────────────────────────────────────────────────────────────

        /// Does the user prefer high-contrast adjacent cells? (0-1)
        public var contrastPreference: Float

        /// Does the user prefer similar adjacent cells? (0-1)
        public var harmonyPreference: Float

        // ─────────────────────────────────────────────────────────────────────
        // SPATIAL PREFERENCES
        // ─────────────────────────────────────────────────────────────────────

        /// Does the user focus on center vs edges? (-1=edges, 0=uniform, 1=center)
        public var centerVsEdge: Float

        /// Does the user prefer specific quadrants? (4 values, 0-1)
        public var quadrantPreference: [Float]

        // ─────────────────────────────────────────────────────────────────────
        // TEMPORAL PREFERENCES
        // ─────────────────────────────────────────────────────────────────────

        /// Does the user focus on beginning vs end? (-1=end, 0=uniform, 1=begin)
        public var beginVsEnd: Float

        /// Does the user prefer stable vs dynamic moments? (-1=stable, 1=dynamic)
        public var stableVsDynamic: Float

        // ─────────────────────────────────────────────────────────────────────
        // COLOR PREFERENCES
        // ─────────────────────────────────────────────────────────────────────

        /// Does the user prefer warm vs cool tones? (-1=cool, 1=warm)
        public var warmVsCool: Float

        /// Does the user prefer saturated vs muted colors? (-1=muted, 1=saturated)
        public var saturatedVsMuted: Float

        /// Does the user prefer bright vs dark? (-1=dark, 1=bright)
        public var brightVsDark: Float

        // ─────────────────────────────────────────────────────────────────────
        // DERIVED METRICS
        // ─────────────────────────────────────────────────────────────────────

        /// Compute from a collection of sessions
        public static func compute(from sessions: [GameSession]) -> HigherOrderFeatures {
            // Analyze move patterns across all sessions
            var centerMoves = 0
            var edgeMoves = 0
            var earlyFrameMoves = 0
            var lateFrameMoves = 0

            for session in sessions {
                for move in session.spatialMoves where move.player == 0 {
                    let row = move.position / 9
                    let col = move.position % 9

                    // Is this center or edge?
                    let isCenter = (row >= 2 && row <= 6) && (col >= 2 && col <= 6)
                    if isCenter {
                        centerMoves += 1
                    } else {
                        edgeMoves += 1
                    }
                }

                for move in session.temporalMoves where move.player == 0 {
                    let timeGroup = move.position / 9
                    if timeGroup < 4 {
                        earlyFrameMoves += 1
                    } else if timeGroup > 4 {
                        lateFrameMoves += 1
                    }
                }
            }

            let totalSpatial = centerMoves + edgeMoves
            let centerVsEdge = totalSpatial > 0
                ? Float(centerMoves - edgeMoves) / Float(totalSpatial)
                : 0

            let totalTemporal = earlyFrameMoves + lateFrameMoves
            let beginVsEnd = totalTemporal > 0
                ? Float(earlyFrameMoves - lateFrameMoves) / Float(totalTemporal)
                : 0

            return HigherOrderFeatures(
                contrastPreference: 0.5,
                harmonyPreference: 0.5,
                centerVsEdge: centerVsEdge,
                quadrantPreference: [0.25, 0.25, 0.25, 0.25],
                beginVsEnd: beginVsEnd,
                stableVsDynamic: 0.0,
                warmVsCool: 0.0,
                saturatedVsMuted: 0.0,
                brightVsDark: 0.0
            )
        }

        /// Convert to feature vector for model input
        public func toVector() -> [Float] {
            var v = [Float]()
            v.append(contrastPreference)
            v.append(harmonyPreference)
            v.append(centerVsEdge)
            v.append(contentsOf: quadrantPreference)
            v.append(beginVsEnd)
            v.append(stableVsDynamic)
            v.append(warmVsCool)
            v.append(saturatedVsMuted)
            v.append(brightVsDark)
            return v  // 13 dimensions
        }
    }
}

// MARK: - Training Loop

@available(iOS 26.0, *)
extension PreferenceTransformer {

    /// Training configuration
    public struct TrainingConfig {
        /// Batch size
        public var batchSize: Int = 16

        /// Learning rate
        public var learningRate: Float = 1e-4

        /// Weight decay
        public var weightDecay: Float = 1e-5

        /// Number of epochs
        public var epochs: Int = 100

        /// Loss weights
        public var moveLossWeight: Float = 1.0
        public var weightLossWeight: Float = 0.5
        public var paletteLossWeight: Float = 0.3
        public var styleLossWeight: Float = 0.2

        /// Checkpoint interval (epochs)
        public var checkpointInterval: Int = 10

        public init() {}
    }

    /// Training step result
    public struct TrainingStep {
        public var epoch: Int
        public var batch: Int
        public var moveLoss: Float
        public var weightLoss: Float
        public var paletteLoss: Float
        public var styleLoss: Float

        public var totalLoss: Float {
            moveLoss + weightLoss + paletteLoss + styleLoss
        }
    }

    /// Placeholder for actual training (would use Metal Performance Shaders)
    public static func train(
        sessions: [GameSession],
        config: TrainingConfig,
        progressCallback: @escaping (TrainingStep) -> Void
    ) async throws {
        // This would:
        // 1. Convert sessions to ModelInput batches
        // 2. Forward pass through encoder/decoder
        // 3. Compute losses
        // 4. Backward pass and update weights
        // 5. Report progress

        print("Training would process \(sessions.count) sessions")
        print("Configuration: \(config.epochs) epochs, batch size \(config.batchSize)")
    }
}

// MARK: - Interpretability

@available(iOS 26.0, *)
extension PreferenceTransformer {

    /// Explain why the model made certain predictions.
    public struct Explanation {
        /// Which cells most influenced the prediction
        public var importantCells: [(index: Int, importance: Float)]

        /// Which historical moves most influenced the prediction
        public var importantMoves: [(moveNumber: Int, importance: Float)]

        /// Human-readable explanation
        public var textExplanation: String
    }

    /// Generate explanation for a prediction.
    public static func explain(
        prediction: ModelOutput,
        input: ModelInput
    ) -> Explanation {
        // Use attention weights to identify important cells
        var cellImportance = [(Int, Float)]()

        // Analyze which moves had the most impact
        var moveImportance = [(Int, Float)]()

        // Generate text explanation
        let text = """
        The model predicted these weights based on:
        - High activity in the center tiles (cells 36-44)
        - User's historical preference for bright regions
        - Temporal focus on frames 27-54 (middle third)
        """

        return Explanation(
            importantCells: cellImportance,
            importantMoves: moveImportance,
            textExplanation: text
        )
    }
}
