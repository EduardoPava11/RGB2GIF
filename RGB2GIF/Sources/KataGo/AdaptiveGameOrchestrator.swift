//
//  AdaptiveGameOrchestrator.swift
//  RGB2GIF
//
//  ============================================================================
//  ADAPTIVE GAME ORCHESTRATOR: Budget-Controlled KataGo Processing
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Orchestrates KataGo inference with adaptive compute allocation. Instead of
//  always running 18 games (9 spatial + 9 temporal), this orchestrator:
//
//  1. Analyzes slice importance (fast, ~5ms)
//  2. Allocates inference budget (6-18 games)
//  3. Runs KataGo on high-importance slices
//  4. Interpolates weights for skipped slices
//
//  This provides significant speedup (33-66%) while maintaining quality on
//  visually important regions.
//
//  BUDGET ALLOCATION
//  ─────────────────
//  Default budget: 12 inferences (6 spatial + 6 temporal)
//  Minimum: 6 inferences (3 + 3, always anchor slices)
//  Maximum: 18 inferences (9 + 9, full processing)
//
//  Anchor slices (always processed): 0, 4, 8
//  - Frame 0: Start of video
//  - Frame 4: Middle of video
//  - Frame 8: End of video
//
//  INTERPOLATION
//  ─────────────
//  Skipped slices use linear interpolation from neighboring processed slices.
//  This works well because:
//  - Low-importance slices have uniform content (neighbors similar)
//  - Interpolation preserves smooth attention gradients
//  - Error is bounded by slice importance (low importance = low error)
//
//  USAGE
//  ─────
//  let orchestrator = AdaptiveGameOrchestrator(budget: 12)
//  let weights = try await orchestrator.computeWeights(tensor)
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Adaptive Game Orchestrator

/// Orchestrates KataGo inference with adaptive compute allocation.
@available(iOS 26.0, *)
public actor AdaptiveGameOrchestrator {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for adaptive processing.
    public struct Config: Sendable {
        /// Total inference budget (minimum 6, maximum 18).
        public var budget: Int = 12

        /// Minimum budget (always process anchor slices).
        public static let minBudget = 6

        /// Maximum budget (full processing).
        public static let maxBudget = 18

        /// Anchor slices (always processed).
        public static let anchorSlices: Set<Int> = [0, 4, 8]

        /// Importance analyzer configuration.
        public var importanceConfig: SliceImportanceAnalyzer.Config = .init()

        /// Merge strategy for attention weights.
        public var mergeStrategy: AttentionWeights.MergeStrategy = .geometric

        /// Whether to use gene-based attention balancing.
        public var useGene: Bool = false

        /// Initialize with defaults.
        public init() {}

        /// Initialize with specific budget.
        public init(budget: Int) {
            self.budget = max(Self.minBudget, min(Self.maxBudget, budget))
        }

        /// Validate configuration.
        public var isValid: Bool {
            budget >= Self.minBudget && budget <= Self.maxBudget
        }
    }

    /// Active configuration.
    public private(set) var config: Config

    /// Importance analyzer.
    private let importanceAnalyzer: SliceImportanceAnalyzer

    /// Spatial player reference.
    private var spatialPlayer: KataGoInference?

    /// Temporal player reference.
    private var temporalPlayer: KataGoInference?

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Result
    // ═══════════════════════════════════════════════════════════════════════════

    /// Result of adaptive attention computation.
    public struct AdaptiveResult: Sendable {
        /// Final 729 attention weights.
        public let weights: AttentionWeights

        /// Which spatial slices were processed (not interpolated).
        public let processedSpatialSlices: Set<Int>

        /// Which temporal slices were processed.
        public let processedTemporalSlices: Set<Int>

        /// Importance analysis used for allocation.
        public let importance: SliceImportanceAnalyzer.ImportanceResult

        /// Total processing time in milliseconds.
        public let processingTimeMs: Double

        /// Inference count (actual KataGo calls).
        public let inferenceCount: Int

        /// Estimated speedup vs full processing.
        public var speedupRatio: Float {
            18.0 / Float(inferenceCount)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize with configuration.
    public init(config: Config = Config()) {
        self.config = config
        self.importanceAnalyzer = SliceImportanceAnalyzer(config: config.importanceConfig)
    }

    /// Initialize with budget shorthand.
    public convenience init(budget: Int) {
        self.init(config: Config(budget: budget))
    }

    /// Load KataGo models.
    ///
    /// - Parameter computeUnits: CoreML compute units
    /// - Throws: If models fail to load
    public func loadModels(computeUnits: MLComputeUnits = .all) async throws {
        async let spatial = KataGoInference(role: .spatial, computeUnits: computeUnits)
        async let temporal = KataGoInference(role: .temporal, computeUnits: computeUnits)

        self.spatialPlayer = try await spatial
        self.temporalPlayer = try await temporal
    }

    /// Check if models are loaded.
    public var isLoaded: Bool {
        spatialPlayer != nil && temporalPlayer != nil
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Adaptive Attention Computation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute attention weights with adaptive processing.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: AdaptiveResult with weights and processing info
    /// - Throws: If models not loaded or inference fails
    public func computeWeights(for tensor: TensorCube729) async throws -> AdaptiveResult {
        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw AdaptiveError.modelsNotLoaded
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Step 1: Analyze importance (~5ms)
        let importance = importanceAnalyzer.analyze(tensor: tensor)

        // Step 2: Allocate budget
        let spatialBudget = max(3, config.budget / 2)
        let temporalBudget = config.budget - spatialBudget

        let spatialSlices = importance.selectSpatialSlices(budget: spatialBudget)
        let temporalSlices = importance.selectTemporalSlices(budget: temporalBudget)

        // Step 3: Create game players
        let spatialGamePlayer = SpatialGamePlayer(inference: spatial)
        let temporalGamePlayer = TemporalGamePlayer(inference: temporal)

        // Step 4: Process selected slices
        var spatialPolicies = [[Float]?](repeating: nil, count: 9)
        var temporalPolicies = [[Float]?](repeating: nil, count: 9)

        // Process spatial slices
        for t in spatialSlices {
            let position = spatialGamePlayer.seedPosition(from: tensor, sliceIndex: t)
            let weights = try await spatialGamePlayer.extractWeights(from: position)
            spatialPolicies[t] = weights
        }

        // Process temporal slices
        for x in temporalSlices {
            let position = temporalGamePlayer.seedPosition(from: tensor, sliceIndex: x)
            let weights = try await temporalGamePlayer.extractWeights(from: position)
            temporalPolicies[x] = weights
        }

        // Step 5: Interpolate missing slices
        interpolateMissing(&spatialPolicies, processed: spatialSlices)
        interpolateMissing(&temporalPolicies, processed: temporalSlices)

        // Step 6: Merge into 729 weights
        var queryWeights = [Float](repeating: 0, count: 729)
        var keyWeights = [Float](repeating: 0, count: 729)

        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let idx = t * 81 + y * 9 + x

                    // Query from spatial
                    queryWeights[idx] = spatialPolicies[t]![y * 9 + x]

                    // Key from temporal
                    keyWeights[idx] = temporalPolicies[x]![t * 9 + y]
                }
            }
        }

        let attention = AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: config.mergeStrategy,
            spatialValue: 0,
            temporalValue: 0
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        return AdaptiveResult(
            weights: attention,
            processedSpatialSlices: spatialSlices,
            processedTemporalSlices: temporalSlices,
            importance: importance,
            processingTimeMs: elapsed,
            inferenceCount: spatialSlices.count + temporalSlices.count
        )
    }

    /// Compute attention weights from centroids.
    public func computeWeights(from centroids: [(r: UInt8, g: UInt8, b: UInt8)]) async throws -> AdaptiveResult {
        guard let spatial = spatialPlayer, let temporal = temporalPlayer else {
            throw AdaptiveError.modelsNotLoaded
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Analyze importance
        let importance = importanceAnalyzer.analyze(centroids: centroids)

        // Allocate budget
        let spatialBudget = max(3, config.budget / 2)
        let temporalBudget = config.budget - spatialBudget

        let spatialSlices = importance.selectSpatialSlices(budget: spatialBudget)
        let temporalSlices = importance.selectTemporalSlices(budget: temporalBudget)

        // Process selected slices
        var spatialPolicies = [[Float]?](repeating: nil, count: 9)
        var temporalPolicies = [[Float]?](repeating: nil, count: 9)

        // Spatial processing
        for t in spatialSlices {
            let (features, global) = try BoardEncoder.encodeSpatialSlice(centroids: centroids, timeSlice: t)
            let result = try await spatial.predict(spatial: features, global: global)
            spatialPolicies[t] = await spatial.extractAttentionWeights(from: result)
        }

        // Temporal processing
        for x in temporalSlices {
            let (features, global) = try BoardEncoder.encodeTemporalSlice(centroids: centroids, column: x)
            let result = try await temporal.predict(spatial: features, global: global)
            temporalPolicies[x] = await temporal.extractAttentionWeights(from: result)
        }

        // Interpolate missing
        interpolateMissing(&spatialPolicies, processed: spatialSlices)
        interpolateMissing(&temporalPolicies, processed: temporalSlices)

        // Merge
        var queryWeights = [Float](repeating: 0, count: 729)
        var keyWeights = [Float](repeating: 0, count: 729)

        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let idx = t * 81 + y * 9 + x
                    queryWeights[idx] = spatialPolicies[t]![y * 9 + x]
                    keyWeights[idx] = temporalPolicies[x]![t * 9 + y]
                }
            }
        }

        let attention = AttentionWeights(
            query: queryWeights,
            key: keyWeights,
            strategy: config.mergeStrategy,
            spatialValue: 0,
            temporalValue: 0
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        return AdaptiveResult(
            weights: attention,
            processedSpatialSlices: spatialSlices,
            processedTemporalSlices: temporalSlices,
            importance: importance,
            processingTimeMs: elapsed,
            inferenceCount: spatialSlices.count + temporalSlices.count
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Interpolation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Interpolate missing slices from neighboring processed slices.
    ///
    /// Uses linear interpolation between the nearest processed neighbors.
    /// Boundary slices (0, 8) use nearest-neighbor if one side is missing.
    private func interpolateMissing(_ policies: inout [[Float]?], processed: Set<Int>) {
        for i in 0..<9 {
            if policies[i] != nil { continue }  // Already has data

            // Find nearest processed neighbors
            var leftIdx: Int?
            var rightIdx: Int?

            for j in stride(from: i-1, through: 0, by: -1) {
                if processed.contains(j) {
                    leftIdx = j
                    break
                }
            }

            for j in (i+1)..<9 {
                if processed.contains(j) {
                    rightIdx = j
                    break
                }
            }

            // Interpolate
            if let left = leftIdx, let right = rightIdx,
               let leftPolicy = policies[left], let rightPolicy = policies[right] {
                // Linear interpolation
                let t = Float(i - left) / Float(right - left)
                policies[i] = zip(leftPolicy, rightPolicy).map { (1-t) * $0 + t * $1 }
            } else if let left = leftIdx, let leftPolicy = policies[left] {
                // Copy from left neighbor
                policies[i] = leftPolicy
            } else if let right = rightIdx, let rightPolicy = policies[right] {
                // Copy from right neighbor
                policies[i] = rightPolicy
            } else {
                // Fallback: uniform distribution
                policies[i] = [Float](repeating: 1.0/81.0, count: 81)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration Updates
    // ═══════════════════════════════════════════════════════════════════════════

    /// Update budget.
    public func setBudget(_ budget: Int) {
        config.budget = max(Config.minBudget, min(Config.maxBudget, budget))
    }

    /// Update merge strategy.
    public func setMergeStrategy(_ strategy: AttentionWeights.MergeStrategy) {
        config.mergeStrategy = strategy
    }
}

// MARK: - Errors

/// Errors for AdaptiveGameOrchestrator.
public enum AdaptiveError: Error, LocalizedError {
    case modelsNotLoaded
    case invalidBudget(Int)
    case inferenceFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "KataGo models not loaded. Call loadModels() first."
        case .invalidBudget(let budget):
            return "Invalid budget \(budget). Must be 6-18."
        case .inferenceFailed(let error):
            return "Inference failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Board Encoder Extensions

@available(iOS 26.0, *)
extension BoardEncoder {

    /// Encode a single spatial slice from centroids.
    ///
    /// - Parameters:
    ///   - centroids: 729 RGB color tuples
    ///   - timeSlice: Which time frame (0-8)
    /// - Returns: Feature and global arrays for KataGo
    static func encodeSpatialSlice(
        centroids: [(r: UInt8, g: UInt8, b: UInt8)],
        timeSlice t: Int
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {
        // Extract 81 colors for this time slice
        var sliceCentroids = [(r: UInt8, g: UInt8, b: UInt8)]()
        sliceCentroids.reserveCapacity(81)

        for y in 0..<9 {
            for x in 0..<9 {
                let idx = t * 81 + y * 9 + x
                sliceCentroids.append(centroids[idx])
            }
        }

        return try encodeFromCentroids(sliceCentroids, type: .spatial)
    }

    /// Encode a single temporal slice from centroids.
    ///
    /// - Parameters:
    ///   - centroids: 729 RGB color tuples
    ///   - column: Which spatial column (0-8)
    /// - Returns: Feature and global arrays for KataGo
    static func encodeTemporalSlice(
        centroids: [(r: UInt8, g: UInt8, b: UInt8)],
        column x: Int
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {
        // Extract colors for this column (all t, all y, fixed x)
        var sliceCentroids = [(r: UInt8, g: UInt8, b: UInt8)]()
        sliceCentroids.reserveCapacity(81)

        for t in 0..<9 {
            for y in 0..<9 {
                let idx = t * 81 + y * 9 + x
                sliceCentroids.append(centroids[idx])
            }
        }

        return try encodeFromCentroids(sliceCentroids, type: .temporal)
    }
}

// MARK: - Debug Description

@available(iOS 26.0, *)
extension AdaptiveGameOrchestrator.AdaptiveResult: CustomStringConvertible {
    public var description: String {
        """
        AdaptiveResult:
          Processing: \(String(format: "%.1f", processingTimeMs))ms
          Inferences: \(inferenceCount)/18 (\(String(format: "%.1fx", speedupRatio)) speedup)
          Spatial: \(processedSpatialSlices.sorted())
          Temporal: \(processedTemporalSlices.sorted())
          Weights: min=\(String(format: "%.4f", weights.weights.min() ?? 0)), max=\(String(format: "%.4f", weights.weights.max() ?? 0))
        """
    }
}
