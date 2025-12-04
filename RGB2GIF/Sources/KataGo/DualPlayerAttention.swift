//
//  DualPlayerAttention.swift
//  RGB2GIF
//
//  ============================================================================
//  DUAL KATAGO ATTENTION ORCHESTRATOR
//  ============================================================================
//
//  PURPOSE
//  ───────
//  This actor coordinates two KataGo neural networks to produce 729 attention
//  weights for the macro-cell grid. It implements the Q-K-V mechanism where:
//
//      SPATIAL PLAYER (α) ─────────────────────────────────────────────────────
//      │  Model:     KataGo9x9_Spatial.mlpackage                             │
//      │  Rules:     Japanese (territorial)                                   │
//      │  Role:      Query (Q) provider                                       │
//      │  Input:     Tile color statistics (aggregated over time)             │
//      │  Output:    81 weights for which TILES need attention                │
//      └─────────────────────────────────────────────────────────────────────
//
//      TEMPORAL PLAYER (β) ────────────────────────────────────────────────────
//      │  Model:     KataGo9x9_Temporal.mlpackage                            │
//      │  Rules:     Tromp-Taylor (fighting)                                  │
//      │  Role:      Key (K) provider                                         │
//      │  Input:     Frame motion statistics (aggregated over space)          │
//      │  Output:    81 weights reduced to 9 time-group weights               │
//      └─────────────────────────────────────────────────────────────────────
//
//  THE ATTENTION FORMULA
//  ─────────────────────
//  For each of 729 macro-cells (9 tiles × 9 tiles × 9 time groups):
//
//      weight[i,j,t] = λ(Q[i,j], K[t])
//
//  Where λ is a merge function (default: geometric mean √(Q×K))
//
//  USAGE
//  ─────
//  ```swift
//  let dualPlayer = try await DualPlayerAttention()
//  let attention = try await dualPlayer.computeAttentionWeights(for: tensor)
//  let palette = quantizer.quantize(colors, weights: attention)
//  ```
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Dual Player Attention

/// Orchestrates two KataGo neural networks for Q-K-V attention mechanism.
///
/// The Spatial player provides Query weights (which tiles matter), and the
/// Temporal player provides Key weights (which frames matter). These combine
/// to produce 729 attention weights for palette optimization.
@available(iOS 15.0, macOS 12.0, *)
public actor DualPlayerAttention {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════════

    /// The Spatial player (Japanese rules) - Query provider
    private var spatialPlayer: KataGoInference?

    /// The Temporal player (Tromp-Taylor rules) - Key provider
    private var temporalPlayer: KataGoInference?

    /// Default merge strategy
    private var defaultStrategy: AttentionWeights.MergeStrategy = .geometric

    /// Whether models are loaded
    public var isLoaded: Bool {
        spatialPlayer != nil && temporalPlayer != nil
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize without loading models.
    /// Call `loadModels()` before computing attention weights.
    public init() {}

    /// Initialize and load both KataGo models.
    ///
    /// - Parameters:
    ///   - computeUnits: CoreML compute units (default: .all for auto-selection)
    ///   - strategy: Default merge strategy (default: .geometric)
    /// - Throws: KataGoInference.InferenceError if models fail to load
    public init(
        computeUnits: MLComputeUnits = .all,
        strategy: AttentionWeights.MergeStrategy = .geometric
    ) async throws {
        self.defaultStrategy = strategy
        try await loadModels(computeUnits: computeUnits)
    }

    /// Load both KataGo models for inference.
    ///
    /// - Parameter computeUnits: CoreML compute units
    /// - Throws: KataGoInference.InferenceError if models fail to load
    public func loadModels(computeUnits: MLComputeUnits = .all) async throws {
        // Load both models concurrently
        async let spatial = KataGoInference(role: .spatial, computeUnits: computeUnits)
        async let temporal = KataGoInference(role: .temporal, computeUnits: computeUnits)

        self.spatialPlayer = try await spatial
        self.temporalPlayer = try await temporal
    }

    /// Load models from custom URLs.
    ///
    /// - Parameters:
    ///   - spatialURL: URL to Spatial model
    ///   - temporalURL: URL to Temporal model
    ///   - computeUnits: CoreML compute units
    public func loadModels(
        spatialURL: URL,
        temporalURL: URL,
        computeUnits: MLComputeUnits = .all
    ) async throws {
        async let spatial = KataGoInference(
            modelURL: spatialURL,
            role: .spatial,
            computeUnits: computeUnits
        )
        async let temporal = KataGoInference(
            modelURL: temporalURL,
            role: .temporal,
            computeUnits: computeUnits
        )

        self.spatialPlayer = try await spatial
        self.temporalPlayer = try await temporal
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Attention Computation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute attention weights from TensorCube729.
    ///
    /// This is the main entry point for the Q-K-V attention mechanism:
    /// 1. Encode tensor for Spatial player → Get Query weights
    /// 2. Encode tensor for Temporal player → Get Key weights
    /// 3. Merge Q and K with λ function → 729 attention weights
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube with color centroids
    ///   - strategy: Merge strategy (default: use instance default)
    /// - Returns: AttentionWeights with 729 merged weights
    /// - Throws: DualPlayerError if models not loaded or inference fails
    @available(iOS 26.0, *)
    public func computeAttentionWeights(
        for tensor: TensorCube729,
        strategy: AttentionWeights.MergeStrategy? = nil
    ) async throws -> AttentionWeights {

        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw DualPlayerError.modelsNotLoaded
        }

        let mergeStrategy = strategy ?? defaultStrategy

        // Encode tensor for both players
        let (spatialFeatures, spatialGlobal) = try BoardEncoder.encodeSpatialBoard(from: tensor)
        let (temporalFeatures, temporalGlobal) = try BoardEncoder.encodeTemporalBoard(from: tensor)

        // Run both inferences concurrently
        async let spatialOutput = spatial.predict(spatial: spatialFeatures, global: spatialGlobal)
        async let temporalOutput = temporal.predict(spatial: temporalFeatures, global: temporalGlobal)

        let (spatialResult, temporalResult) = try await (spatialOutput, temporalOutput)

        // Extract attention weights
        let queryWeights = spatial.extractAttentionWeights(from: spatialResult)
        let keyWeights = temporal.extractAttentionWeights(from: temporalResult)

        return AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: mergeStrategy,
            spatialValue: spatialResult.expectedValue,
            temporalValue: temporalResult.expectedValue
        )
    }

    /// Compute attention weights from centroid colors.
    ///
    /// - Parameters:
    ///   - centroids: 729 RGB color tuples
    ///   - strategy: Merge strategy
    /// - Returns: AttentionWeights with 729 merged weights
    public func computeAttentionWeights(
        from centroids: [(r: UInt8, g: UInt8, b: UInt8)],
        strategy: AttentionWeights.MergeStrategy? = nil
    ) async throws -> AttentionWeights {

        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw DualPlayerError.modelsNotLoaded
        }

        let mergeStrategy = strategy ?? defaultStrategy

        // Encode centroids for both players
        let (spatialFeatures, spatialGlobal) = try BoardEncoder.encodeFromCentroids(
            centroids,
            type: .spatial
        )
        let (temporalFeatures, temporalGlobal) = try BoardEncoder.encodeFromCentroids(
            centroids,
            type: .temporal
        )

        // Run both inferences concurrently
        async let spatialOutput = spatial.predict(spatial: spatialFeatures, global: spatialGlobal)
        async let temporalOutput = temporal.predict(spatial: temporalFeatures, global: temporalGlobal)

        let (spatialResult, temporalResult) = try await (spatialOutput, temporalOutput)

        // Extract attention weights
        let queryWeights = spatial.extractAttentionWeights(from: spatialResult)
        let keyWeights = temporal.extractAttentionWeights(from: temporalResult)

        return AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: mergeStrategy,
            spatialValue: spatialResult.expectedValue,
            temporalValue: temporalResult.expectedValue
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Alternative Weight Sources
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute attention using ownership instead of policy.
    ///
    /// Ownership provides a different perspective:
    /// - More stable territory-based weights
    /// - Black territory → high attention, White → low
    ///
    /// - Parameters:
    ///   - tensor: The tensor cube
    ///   - strategy: Merge strategy
    /// - Returns: AttentionWeights from ownership predictions
    @available(iOS 26.0, *)
    public func computeOwnershipWeights(
        for tensor: TensorCube729,
        strategy: AttentionWeights.MergeStrategy? = nil
    ) async throws -> AttentionWeights {

        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw DualPlayerError.modelsNotLoaded
        }

        let mergeStrategy = strategy ?? defaultStrategy

        let (spatialFeatures, spatialGlobal) = try BoardEncoder.encodeSpatialBoard(from: tensor)
        let (temporalFeatures, temporalGlobal) = try BoardEncoder.encodeTemporalBoard(from: tensor)

        async let spatialOutput = spatial.predict(spatial: spatialFeatures, global: spatialGlobal)
        async let temporalOutput = temporal.predict(spatial: temporalFeatures, global: temporalGlobal)

        let (spatialResult, temporalResult) = try await (spatialOutput, temporalOutput)

        // Use ownership instead of policy
        let queryWeights = spatial.extractOwnershipWeights(from: spatialResult)
        let keyWeights = temporal.extractOwnershipWeights(from: temporalResult)

        return AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: mergeStrategy,
            spatialValue: spatialResult.expectedValue,
            temporalValue: temporalResult.expectedValue
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Set the default merge strategy.
    public func setDefaultStrategy(_ strategy: AttentionWeights.MergeStrategy) {
        self.defaultStrategy = strategy
    }

    /// Get the current default merge strategy.
    public func getDefaultStrategy() -> AttentionWeights.MergeStrategy {
        return defaultStrategy
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - MVP1: Game Playing Attention (18 Games)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute attention weights using the game playing approach.
    ///
    /// This is the MVP1 method that creates 18 separate games:
    /// - 9 spatial games (one per time frame, x/y view)
    /// - 9 temporal games (one per spatial column, t/y view)
    ///
    /// Each game is seeded with stones based on color/motion intensity, then
    /// KataGo's policy output reveals where attention is needed.
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - strategy: Merge strategy (default: geometric)
    /// - Returns: AttentionWeights with 729 merged weights from 18 games
    @available(iOS 26.0, *)
    public func computeGamePlayingWeights(
        for tensor: TensorCube729,
        strategy: AttentionWeights.MergeStrategy? = nil
    ) async throws -> AttentionWeights {

        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw DualPlayerError.modelsNotLoaded
        }

        let mergeStrategy = strategy ?? defaultStrategy

        // Create game players
        let spatialGamePlayer = SpatialGamePlayer(inference: spatial)
        let temporalGamePlayer = TemporalGamePlayer(inference: temporal)

        // Process all 18 games concurrently
        async let spatialResults = spatialGamePlayer.processAllSlices(from: tensor)
        async let temporalResults = temporalGamePlayer.processAllSlices(from: tensor)

        let (spatialPolicies, temporalPolicies) = try await (spatialResults, temporalResults)

        // Merge into 729 weights
        // spatialPolicies[t][y*9+x] = weight for tile (y,x) at time t
        // temporalPolicies[x][t*9+y] = weight for (t,y) at column x
        var queryWeights = [Float](repeating: 0, count: 729)
        var keyWeights = [Float](repeating: 0, count: 729)

        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let idx = t * 81 + y * 9 + x

                    // Query from spatial: policy[t][y*9+x]
                    queryWeights[idx] = spatialPolicies[t][y * 9 + x]

                    // Key from temporal: policy[x][t*9+y]
                    keyWeights[idx] = temporalPolicies[x][t * 9 + y]
                }
            }
        }

        return AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: mergeStrategy,
            spatialValue: 0,  // Not available in this mode
            temporalValue: 0
        )
    }

    /// Process all games and return detailed results.
    ///
    /// This method returns full BatchProcessingResult for both players,
    /// useful for visualization and debugging.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Tuple of (spatial results, temporal results)
    @available(iOS 26.0, *)
    public func processAllGamesDetailed(
        for tensor: TensorCube729
    ) async throws -> (spatial: BatchProcessingResult, temporal: BatchProcessingResult) {

        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw DualPlayerError.modelsNotLoaded
        }

        let spatialGamePlayer = SpatialGamePlayer(inference: spatial)
        let temporalGamePlayer = TemporalGamePlayer(inference: temporal)

        async let spatialResults = spatialGamePlayer.processAllSlicesDetailed(from: tensor)
        async let temporalResults = temporalGamePlayer.processAllSlicesDetailed(from: tensor)

        return try await (spatialResults, temporalResults)
    }

    /// Create a full game collection from a tensor.
    ///
    /// This processes all 18 games and collects them into a TensorGameCollection
    /// for later analysis, export, or visualization.
    ///
    /// - Parameters:
    ///   - tensor: The 9×9×9 tensor cube
    ///   - strategy: Merge strategy for attention weights
    /// - Returns: TensorGameCollection with all game records and attention weights
    @available(iOS 26.0, *)
    public func createGameCollection(
        from tensor: TensorCube729,
        strategy: AttentionWeights.MergeStrategy? = nil
    ) async throws -> TensorGameCollection {

        let startTime = Date()
        var collection = TensorGameCollection()

        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw DualPlayerError.modelsNotLoaded
        }

        let mergeStrategy = strategy ?? defaultStrategy
        let spatialGamePlayer = SpatialGamePlayer(inference: spatial)
        let temporalGamePlayer = TemporalGamePlayer(inference: temporal)

        // Process spatial games
        var spatialPolicies = [[Float]]()
        for t in 0..<9 {
            let position = spatialGamePlayer.seedPosition(from: tensor, sliceIndex: t)
            let weights = try await spatialGamePlayer.extractWeights(from: position)

            var record = GameRecord(viewType: .spatial, sliceIndex: t, initialPosition: position)
            // For seeded-position approach, we just record the initial policy
            record.recordMove(
                Move(row: 0, col: 0, color: .black, moveNumber: 0),  // Placeholder
                newPosition: position,
                policy: weights,
                value: 0,
                ownership: []
            )
            record.complete(result: .nnPassed)
            collection.spatialGames.append(record)
            spatialPolicies.append(weights)
        }

        // Process temporal games
        var temporalPolicies = [[Float]]()
        for x in 0..<9 {
            let position = temporalGamePlayer.seedPosition(from: tensor, sliceIndex: x)
            let weights = try await temporalGamePlayer.extractWeights(from: position)

            var record = GameRecord(viewType: .temporal, sliceIndex: x, initialPosition: position)
            record.recordMove(
                Move(row: 0, col: 0, color: .black, moveNumber: 0),
                newPosition: position,
                policy: weights,
                value: 0,
                ownership: []
            )
            record.complete(result: .nnPassed)
            collection.temporalGames.append(record)
            temporalPolicies.append(weights)
        }

        // Compute merged attention weights
        var queryWeights = [Float](repeating: 0, count: 729)
        var keyWeights = [Float](repeating: 0, count: 729)

        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let idx = t * 81 + y * 9 + x
                    queryWeights[idx] = spatialPolicies[t][y * 9 + x]
                    keyWeights[idx] = temporalPolicies[x][t * 9 + y]
                }
            }
        }

        collection.attentionWeights = AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: mergeStrategy,
            spatialValue: 0,
            temporalValue: 0
        )

        collection.processingTime = Date().timeIntervalSince(startTime)
        return collection
    }
}

// MARK: - Errors

/// Errors that can occur in DualPlayerAttention.
public enum DualPlayerError: Error, LocalizedError {
    case modelsNotLoaded
    case spatialInferenceFailed(Error)
    case temporalInferenceFailed(Error)
    case encodingFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "KataGo models not loaded. Call loadModels() first."
        case .spatialInferenceFailed(let error):
            return "Spatial player inference failed: \(error.localizedDescription)"
        case .temporalInferenceFailed(let error):
            return "Temporal player inference failed: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Board encoding failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Debug Extensions

@available(iOS 15.0, macOS 12.0, *)
extension DualPlayerAttention {

    /// Print information about both loaded models.
    public func printModelInfo() async {
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  DualPlayerAttention Status                                       ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Spatial Player: \(spatialPlayer != nil ? "✓ Loaded" : "✗ Not Loaded")                                  ║")
        print("║  Temporal Player: \(temporalPlayer != nil ? "✓ Loaded" : "✗ Not Loaded")                                 ║")
        print("║  Default Strategy: \(defaultStrategy.rawValue.padding(toLength: 45, withPad: " ", startingAt: 0)) ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")

        if let spatial = spatialPlayer {
            await spatial.printModelInfo()
        }
        if let temporal = temporalPlayer {
            await temporal.printModelInfo()
        }
    }

    /// Run a test inference with synthetic data.
    public func runTestInference() async throws -> AttentionWeights {
        // Create synthetic centroids (gradient pattern)
        var centroids: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let r = UInt8(x * 28)       // Gradient across X
                    let g = UInt8(y * 28)       // Gradient across Y
                    let b = UInt8(t * 28)       // Gradient across time
                    centroids.append((r, g, b))
                }
            }
        }

        let attention = try await computeAttentionWeights(from: centroids)

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  Test Inference Results                                           ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  \(attention.description.replacingOccurrences(of: "\n", with: "\n║  "))                    ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")

        return attention
    }
}

// MARK: - Convenience Extensions

@available(iOS 15.0, macOS 12.0, *)
extension AttentionWeights {

    /// Create attention weights using DualPlayerAttention.
    ///
    /// This is a convenience factory method that handles model loading.
    ///
    /// - Parameters:
    ///   - centroids: 729 RGB color tuples
    ///   - strategy: Merge strategy
    /// - Returns: AttentionWeights from dual KataGo inference
    public static func fromDualPlayer(
        centroids: [(r: UInt8, g: UInt8, b: UInt8)],
        strategy: MergeStrategy = .geometric
    ) async throws -> AttentionWeights {
        let dualPlayer = try await DualPlayerAttention(strategy: strategy)
        return try await dualPlayer.computeAttentionWeights(from: centroids)
    }

    /// Create attention weights from TensorCube729.
    @available(iOS 26.0, *)
    public static func fromDualPlayer(
        tensor: TensorCube729,
        strategy: MergeStrategy = .geometric
    ) async throws -> AttentionWeights {
        let dualPlayer = try await DualPlayerAttention(strategy: strategy)
        return try await dualPlayer.computeAttentionWeights(for: tensor)
    }
}
