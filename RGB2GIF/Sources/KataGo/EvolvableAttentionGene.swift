//
//  EvolvableAttentionGene.swift
//  RGB2GIF
//
//  ============================================================================
//  EVOLVABLE ATTENTION GENE SYSTEM (EAGS)
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Implements a "gene-like" system where learned attention biases can be:
//      1. Trained on-device from user preferences
//      2. Shared between users (like genetic material)
//      3. Merged/crossed over to create offspring genes
//      4. Selected for fitness through natural selection
//
//  The system uses LoRA (Low-Rank Adaptation) to keep genes small (~500KB)
//  while still being expressive enough to capture user preferences.
//
//  ARCHITECTURE
//  ────────────
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │  Base KataGo Models (Frozen, ~36M params each)                          │
//  │     ├── Spatial Player (Japanese rules)                                 │
//  │     └── Temporal Player (Tromp-Taylor rules)                            │
//  │                                                                         │
//  │  AttentionGene (Trainable, ~122K params total)                          │
//  │     ├── Spatial LoRA weights (~61K params)                              │
//  │     ├── Temporal LoRA weights (~61K params)                             │
//  │     ├── Merge parameters (9 alpha values)                               │
//  │     └── Encoding thresholds (black/white/temperature)                   │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  INSPIRATION
//  ───────────
//  • LoRA: Low-rank adaptation for efficient fine-tuning
//  • Model Soups: Averaging weights from multiple models
//  • TIES-Merging: Trim, elect signs, merge for robust combination
//  • Neuroevolution: Genetic operators on neural network weights
//  • Federated Learning: On-device personalization
//  • DNA Codons: Triplet encoding (3 values → discrete category)
//
//  ============================================================================

import Foundation

// MARK: - Attention Gene

/// A shareable "gene" containing learned attention biases.
///
/// Genes are small (~500KB) packages of learned weights that modify
/// how the dual KataGo players interpret tensor data. They can be:
/// - Trained from user preferences
/// - Shared between users
/// - Merged to create offspring
/// - Selected through natural selection
public struct AttentionGene: Codable, Sendable, Identifiable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Identity
    // ═══════════════════════════════════════════════════════════════════════════

    /// Unique identifier for this gene.
    public let id: UUID

    /// Human-readable name (e.g., "Vibrant Sunset v2").
    public var name: String

    /// Creator's anonymous identifier.
    public let creatorID: UUID

    /// Generation number (increments with each merge/training).
    public var generation: Int

    /// Parent gene IDs for lineage tracking.
    public var parentIDs: [UUID]

    /// Creation timestamp.
    public let createdAt: Date

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - LoRA Weights
    // ═══════════════════════════════════════════════════════════════════════════

    /// Spatial player LoRA weights.
    ///
    /// Low-rank adaptation matrices that modify the frozen base model's
    /// attention layers. Format: A matrices (down-project) and B matrices
    /// (up-project) for each target layer.
    public var spatialLoRA: LoRAWeights

    /// Temporal player LoRA weights.
    public var temporalLoRA: LoRAWeights

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Merge Parameters
    // ═══════════════════════════════════════════════════════════════════════════

    /// Per-frame spatial-temporal balance (9 values, one per time slice).
    ///
    /// alpha[t] determines how much to weight spatial vs temporal attention
    /// at time slice t. Values closer to 1.0 favor spatial (what's important now),
    /// values closer to 0.0 favor temporal (what's changing).
    public var mergeAlpha: [Float]

    /// Temperature for attention softmax.
    ///
    /// Lower values make attention more peaked (winner-take-all).
    /// Higher values make attention more uniform (democratic).
    public var temperature: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Stone Encoding Parameters
    // ═══════════════════════════════════════════════════════════════════════════

    /// Threshold for classifying as Black stone (high importance).
    public var blackThreshold: Float

    /// Threshold for classifying as White stone (low importance).
    public var whiteThreshold: Float

    /// Codon lookup table for triplet encoding (27 entries).
    ///
    /// Maps RGB triplets (each channel quantized to 3 levels) to stone colors.
    /// This is like how DNA codons map to amino acids.
    public var codonTable: [StoneColor]?

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Fitness Metadata
    // ═══════════════════════════════════════════════════════════════════════════

    /// Number of users who have adopted this gene.
    public var adoptionCount: Int

    /// Average quality score from user feedback (0-1).
    public var qualityScore: Float

    /// Content type this gene excels at.
    public var specialization: ContentType?

    /// Affinity scores for each content type (0-1, higher = better match).
    ///
    /// Unlike `specialization` which is a single category, affinity tracks
    /// how well this gene performs across ALL content types. This enables:
    /// - Blending genes based on content similarity
    /// - Transfer learning between related content types
    /// - Detecting when a gene has "drifted" from its specialization
    public var specializationAffinity: [ContentType: Float]

    /// Content type categories.
    public enum ContentType: String, Codable, CaseIterable, Sendable {
        case nature
        case urban
        case portrait
        case action
        case abstract
        case lowLight
        case text
        case animation
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a new gene with default parameters.
    public init(
        name: String = "Untitled Gene",
        creatorID: UUID = UUID(),
        loraRank: Int = 4
    ) {
        self.id = UUID()
        self.name = name
        self.creatorID = creatorID
        self.generation = 0
        self.parentIDs = []
        self.createdAt = Date()

        // Initialize LoRA with small random values
        self.spatialLoRA = LoRAWeights(rank: loraRank)
        self.temporalLoRA = LoRAWeights(rank: loraRank)

        // Default merge parameters
        self.mergeAlpha = [Float](repeating: 0.5, count: 9)
        self.temperature = 1.0

        // Default encoding thresholds
        self.blackThreshold = 0.65
        self.whiteThreshold = 0.35
        self.codonTable = nil

        // Initial fitness
        self.adoptionCount = 0
        self.qualityScore = 0.5
        self.specialization = nil

        // Initialize affinity with uniform distribution
        var affinity: [ContentType: Float] = [:]
        for type in ContentType.allCases {
            affinity[type] = 1.0 / Float(ContentType.allCases.count)
        }
        self.specializationAffinity = affinity
    }

    /// Create a gene from parent genes (for merging).
    public init(
        name: String,
        parents: [AttentionGene],
        spatialLoRA: LoRAWeights,
        temporalLoRA: LoRAWeights,
        mergeAlpha: [Float],
        temperature: Float,
        blackThreshold: Float,
        whiteThreshold: Float
    ) {
        self.id = UUID()
        self.name = name
        self.creatorID = UUID()  // Offspring has new creator
        self.generation = (parents.map { $0.generation }.max() ?? 0) + 1
        self.parentIDs = parents.map { $0.id }
        self.createdAt = Date()

        self.spatialLoRA = spatialLoRA
        self.temporalLoRA = temporalLoRA
        self.mergeAlpha = mergeAlpha
        self.temperature = temperature
        self.blackThreshold = blackThreshold
        self.whiteThreshold = whiteThreshold
        self.codonTable = nil

        self.adoptionCount = 0
        self.qualityScore = 0.5
        self.specialization = parents.first?.specialization

        // Blend parent affinities
        var affinity: [ContentType: Float] = [:]
        for type in ContentType.allCases {
            let parentAffinities = parents.compactMap { $0.specializationAffinity[type] }
            affinity[type] = parentAffinities.isEmpty ? 0.125 : parentAffinities.reduce(0, +) / Float(parentAffinities.count)
        }
        self.specializationAffinity = affinity
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Computed Properties
    // ═══════════════════════════════════════════════════════════════════════════

    /// Total number of trainable parameters.
    public var parameterCount: Int {
        spatialLoRA.parameterCount + temporalLoRA.parameterCount + 9 + 3  // +9 alpha, +3 thresholds
    }

    /// Estimated size in bytes.
    public var estimatedSize: Int {
        parameterCount * 2  // Float16 encoding
    }

    /// Combined fitness score.
    public var fitness: Float {
        let popularityScore = log(Float(adoptionCount + 1)) / 10  // Log scale
        let qualityWeight: Float = 0.6
        let popularityWeight: Float = 0.3
        let noveltyWeight: Float = 0.1
        let noveltyScore = min(1.0, Float(generation) / 10)  // Newer = some bonus

        return qualityWeight * qualityScore +
               popularityWeight * popularityScore +
               noveltyWeight * noveltyScore
    }

    /// Share code for easy distribution (URL-safe).
    public var shareCode: String {
        let idPrefix = id.uuidString.prefix(8).lowercased()
        let genCode = String(format: "%02d", min(99, generation))
        return "RGB2GIF://g/\(idPrefix)\(genCode)"
    }

    /// Get the content type this gene has highest affinity for.
    public var dominantAffinity: ContentType? {
        specializationAffinity.max(by: { $0.value < $1.value })?.key
    }

    /// Check if gene is specialized (affinity > 0.5 for primary type).
    public var isSpecialized: Bool {
        guard let maxAffinity = specializationAffinity.values.max() else { return false }
        return maxAffinity > 0.5
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Learning Methods
    // ═══════════════════════════════════════════════════════════════════════════

    /// Update gene from a reward signal.
    ///
    /// This is a lightweight update suitable for immediate feedback.
    /// For full training with EWC, use `GeneTrainer` instead.
    ///
    /// - Parameters:
    ///   - reward: Total reward signal (0-1)
    ///   - contentType: Content type that generated this reward
    ///   - learningRate: Rate of update (default 0.05)
    public mutating func updateFromReward(
        _ reward: Float,
        contentType: ContentType,
        learningRate: Float = 0.05
    ) {
        // Update quality score (exponential moving average)
        qualityScore = qualityScore * (1 - learningRate) + reward * learningRate

        // Update affinity for this content type
        updateAffinity(for: contentType, reward: reward, learningRate: learningRate)

        // Optionally adjust merge alpha based on reward
        if reward > 0.7 {
            // Good reward - strengthen current configuration
            // No change needed, configuration is working
        } else if reward < 0.3 {
            // Poor reward - add some exploration noise
            for i in 0..<9 {
                mergeAlpha[i] += Float.random(in: -0.02...0.02)
                mergeAlpha[i] = max(0, min(1, mergeAlpha[i]))
            }
        }

        // Temperature adjustment based on reward variance
        // (This would need reward history for proper implementation)
    }

    /// Update specialization affinity based on performance.
    ///
    /// - Parameters:
    ///   - contentType: Content type that was processed
    ///   - reward: Reward received for this content
    ///   - learningRate: Rate of affinity update
    public mutating func updateAffinity(
        for contentType: ContentType,
        reward: Float,
        learningRate: Float = 0.1
    ) {
        // Get current affinity
        let currentAffinity = specializationAffinity[contentType] ?? 0.125

        // Update using exponential moving average
        let newAffinity = currentAffinity * (1 - learningRate) + reward * learningRate

        // Clamp and store
        specializationAffinity[contentType] = max(0, min(1, newAffinity))

        // Renormalize so affinities sum to 1 (soft specialization)
        let total = specializationAffinity.values.reduce(0, +)
        if total > 0 {
            for type in ContentType.allCases {
                specializationAffinity[type] = (specializationAffinity[type] ?? 0) / total
            }
        }
    }

    /// Get affinity for a specific content type.
    public func affinity(for contentType: ContentType) -> Float {
        specializationAffinity[contentType] ?? 0.125
    }

    /// Check if this gene is suitable for a content type.
    ///
    /// - Parameters:
    ///   - contentType: Content type to check
    ///   - threshold: Minimum affinity to be considered suitable
    /// - Returns: True if gene is suitable
    public func isSuitable(for contentType: ContentType, threshold: Float = 0.2) -> Bool {
        affinity(for: contentType) >= threshold
    }
}

// MARK: - LoRA Weights

/// Low-Rank Adaptation weights for efficient fine-tuning.
///
/// LoRA works by adding trainable low-rank matrices to frozen model layers:
///     output = W₀x + BAx
/// Where W₀ is frozen, and B (down-project) and A (up-project) are trainable.
/// With rank=4, this requires only ~61K parameters vs ~36M in the base model.
public struct LoRAWeights: Codable, Sendable {

    /// Rank of the adaptation (lower = smaller, less expressive).
    public let rank: Int

    /// Down-projection matrices (A) for each target layer.
    /// Shape: [layer_index][rank × input_dim]
    public var matricesA: [[Float]]

    /// Up-projection matrices (B) for each target layer.
    /// Shape: [layer_index][output_dim × rank]
    public var matricesB: [[Float]]

    /// Scaling factor (alpha / rank).
    public var scalingFactor: Float

    /// Number of layers with LoRA adaptation.
    public static let targetLayers = 6  // Attention layers to modify

    /// Dimension of each attention layer.
    public static let layerDim = 384  // KataGo 9x9 dimension

    /// Total parameter count.
    public var parameterCount: Int {
        let perLayer = rank * Self.layerDim * 2  // A and B matrices
        return Self.targetLayers * perLayer
    }

    /// Initialize with small random values.
    public init(rank: Int = 4, alpha: Float = 32.0) {
        self.rank = rank
        self.scalingFactor = alpha / Float(rank)

        // Initialize A with small Gaussian, B with zeros (standard LoRA init)
        self.matricesA = (0..<Self.targetLayers).map { _ in
            (0..<(rank * Self.layerDim)).map { _ in
                Float.random(in: -0.01...0.01)
            }
        }

        self.matricesB = (0..<Self.targetLayers).map { _ in
            [Float](repeating: 0, count: Self.layerDim * rank)
        }
    }

    /// Create from existing weights.
    public init(rank: Int, matricesA: [[Float]], matricesB: [[Float]], scalingFactor: Float) {
        self.rank = rank
        self.matricesA = matricesA
        self.matricesB = matricesB
        self.scalingFactor = scalingFactor
    }

    /// Apply LoRA modification to a layer output.
    public func apply(layerIndex: Int, input: [Float]) -> [Float] {
        guard layerIndex < Self.targetLayers else { return input }

        let A = matricesA[layerIndex]
        let B = matricesB[layerIndex]

        // Compute Ax (down-project to rank dimensions)
        var lowRank = [Float](repeating: 0, count: rank)
        for r in 0..<rank {
            for d in 0..<Self.layerDim {
                lowRank[r] += A[r * Self.layerDim + d] * input[d]
            }
        }

        // Compute BAx (up-project back to full dimension)
        var output = [Float](repeating: 0, count: Self.layerDim)
        for d in 0..<Self.layerDim {
            for r in 0..<rank {
                output[d] += B[d * rank + r] * lowRank[r]
            }
            output[d] *= scalingFactor
        }

        return output
    }
}

// MARK: - Gene Merging Strategies

/// Strategies for merging parent genes into offspring.
public enum GeneMergeStrategy: Sendable {
    /// Simple parameter averaging (Model Soup).
    case soup

    /// Task Arithmetic with scaling factor.
    case taskArithmetic(tau: Float)

    /// TIES-Merging with density parameter.
    case ties(density: Float)

    /// Spherical linear interpolation.
    case slerp(t: Float)

    /// Random crossover at layer boundaries.
    case geneticCrossover(crossoverRate: Float, mutationRate: Float)
}

// MARK: - Gene Merger

/// Merges parent genes into offspring using various strategies.
public struct GeneMerger {

    /// Merge two parent genes into offspring.
    public static func merge(
        parent1: AttentionGene,
        parent2: AttentionGene,
        strategy: GeneMergeStrategy,
        offspringName: String? = nil
    ) -> AttentionGene {

        let name = offspringName ?? "\(parent1.name) × \(parent2.name)"

        switch strategy {
        case .soup:
            return soupMerge(parent1, parent2, name: name)

        case .taskArithmetic(let tau):
            return taskArithmeticMerge(parent1, parent2, tau: tau, name: name)

        case .ties(let density):
            return tiesMerge(parent1, parent2, density: density, name: name)

        case .slerp(let t):
            return slerpMerge(parent1, parent2, t: t, name: name)

        case .geneticCrossover(let crossoverRate, let mutationRate):
            return geneticCrossoverMerge(parent1, parent2, crossoverRate: crossoverRate, mutationRate: mutationRate, name: name)
        }
    }

    // MARK: - Merge Implementations

    /// Model Soup: Simple parameter averaging.
    private static func soupMerge(_ p1: AttentionGene, _ p2: AttentionGene, name: String) -> AttentionGene {
        AttentionGene(
            name: name,
            parents: [p1, p2],
            spatialLoRA: averageLoRA(p1.spatialLoRA, p2.spatialLoRA),
            temporalLoRA: averageLoRA(p1.temporalLoRA, p2.temporalLoRA),
            mergeAlpha: zip(p1.mergeAlpha, p2.mergeAlpha).map { ($0 + $1) / 2 },
            temperature: (p1.temperature + p2.temperature) / 2,
            blackThreshold: (p1.blackThreshold + p2.blackThreshold) / 2,
            whiteThreshold: (p1.whiteThreshold + p2.whiteThreshold) / 2
        )
    }

    /// Task Arithmetic: parent1 + tau * (parent2 - parent1).
    private static func taskArithmeticMerge(
        _ p1: AttentionGene,
        _ p2: AttentionGene,
        tau: Float,
        name: String
    ) -> AttentionGene {
        func blend(_ a: Float, _ b: Float) -> Float {
            a + tau * (b - a)
        }

        func blendArray(_ a: [Float], _ b: [Float]) -> [Float] {
            zip(a, b).map { blend($0, $1) }
        }

        return AttentionGene(
            name: name,
            parents: [p1, p2],
            spatialLoRA: blendLoRA(p1.spatialLoRA, p2.spatialLoRA, tau: tau),
            temporalLoRA: blendLoRA(p1.temporalLoRA, p2.temporalLoRA, tau: tau),
            mergeAlpha: blendArray(p1.mergeAlpha, p2.mergeAlpha),
            temperature: blend(p1.temperature, p2.temperature),
            blackThreshold: blend(p1.blackThreshold, p2.blackThreshold),
            whiteThreshold: blend(p1.whiteThreshold, p2.whiteThreshold)
        )
    }

    /// TIES-Merging: Trim low-magnitude, elect signs, merge.
    private static func tiesMerge(
        _ p1: AttentionGene,
        _ p2: AttentionGene,
        density: Float,
        name: String
    ) -> AttentionGene {
        AttentionGene(
            name: name,
            parents: [p1, p2],
            spatialLoRA: tiesMergeLoRA(p1.spatialLoRA, p2.spatialLoRA, density: density),
            temporalLoRA: tiesMergeLoRA(p1.temporalLoRA, p2.temporalLoRA, density: density),
            mergeAlpha: tiesMergeVector(p1.mergeAlpha, p2.mergeAlpha, density: density),
            temperature: (p1.temperature + p2.temperature) / 2,
            blackThreshold: (p1.blackThreshold + p2.blackThreshold) / 2,
            whiteThreshold: (p1.whiteThreshold + p2.whiteThreshold) / 2
        )
    }

    /// SLERP: Spherical linear interpolation for smooth blending.
    private static func slerpMerge(
        _ p1: AttentionGene,
        _ p2: AttentionGene,
        t: Float,
        name: String
    ) -> AttentionGene {
        AttentionGene(
            name: name,
            parents: [p1, p2],
            spatialLoRA: slerpLoRA(p1.spatialLoRA, p2.spatialLoRA, t: t),
            temporalLoRA: slerpLoRA(p1.temporalLoRA, p2.temporalLoRA, t: t),
            mergeAlpha: slerpVector(p1.mergeAlpha, p2.mergeAlpha, t: t),
            temperature: (1 - t) * p1.temperature + t * p2.temperature,
            blackThreshold: (1 - t) * p1.blackThreshold + t * p2.blackThreshold,
            whiteThreshold: (1 - t) * p1.whiteThreshold + t * p2.whiteThreshold
        )
    }

    /// Genetic crossover: Random layer exchange + mutation.
    private static func geneticCrossoverMerge(
        _ p1: AttentionGene,
        _ p2: AttentionGene,
        crossoverRate: Float,
        mutationRate: Float,
        name: String
    ) -> AttentionGene {
        var offspring = AttentionGene(
            name: name,
            parents: [p1, p2],
            spatialLoRA: crossoverLoRA(p1.spatialLoRA, p2.spatialLoRA, rate: crossoverRate),
            temporalLoRA: crossoverLoRA(p1.temporalLoRA, p2.temporalLoRA, rate: crossoverRate),
            mergeAlpha: crossoverVector(p1.mergeAlpha, p2.mergeAlpha, rate: crossoverRate),
            temperature: Float.random(in: 0...1) < crossoverRate ? p2.temperature : p1.temperature,
            blackThreshold: Float.random(in: 0...1) < crossoverRate ? p2.blackThreshold : p1.blackThreshold,
            whiteThreshold: Float.random(in: 0...1) < crossoverRate ? p2.whiteThreshold : p1.whiteThreshold
        )

        // Apply mutations
        offspring = mutate(offspring, rate: mutationRate)

        return offspring
    }

    // MARK: - Helper Functions

    private static func averageLoRA(_ a: LoRAWeights, _ b: LoRAWeights) -> LoRAWeights {
        LoRAWeights(
            rank: a.rank,
            matricesA: zip(a.matricesA, b.matricesA).map { zip($0, $1).map { ($0 + $1) / 2 } },
            matricesB: zip(a.matricesB, b.matricesB).map { zip($0, $1).map { ($0 + $1) / 2 } },
            scalingFactor: (a.scalingFactor + b.scalingFactor) / 2
        )
    }

    private static func blendLoRA(_ a: LoRAWeights, _ b: LoRAWeights, tau: Float) -> LoRAWeights {
        LoRAWeights(
            rank: a.rank,
            matricesA: zip(a.matricesA, b.matricesA).map { zip($0, $1).map { $0 + tau * ($1 - $0) } },
            matricesB: zip(a.matricesB, b.matricesB).map { zip($0, $1).map { $0 + tau * ($1 - $0) } },
            scalingFactor: a.scalingFactor + tau * (b.scalingFactor - a.scalingFactor)
        )
    }

    private static func tiesMergeLoRA(_ a: LoRAWeights, _ b: LoRAWeights, density: Float) -> LoRAWeights {
        LoRAWeights(
            rank: a.rank,
            matricesA: zip(a.matricesA, b.matricesA).map { tiesMergeVector($0, $1, density: density) },
            matricesB: zip(a.matricesB, b.matricesB).map { tiesMergeVector($0, $1, density: density) },
            scalingFactor: (a.scalingFactor + b.scalingFactor) / 2
        )
    }

    private static func tiesMergeVector(_ v1: [Float], _ v2: [Float], density: Float) -> [Float] {
        // Step 1: Compute trim thresholds
        let magnitudes1 = v1.map { abs($0) }.sorted()
        let magnitudes2 = v2.map { abs($0) }.sorted()
        let trimIndex = Int(Float(v1.count) * (1 - density))
        let threshold1 = trimIndex < magnitudes1.count ? magnitudes1[trimIndex] : 0
        let threshold2 = trimIndex < magnitudes2.count ? magnitudes2[trimIndex] : 0

        // Step 2: Trim and elect signs
        var result = [Float](repeating: 0, count: v1.count)
        for i in 0..<v1.count {
            let trimmed1 = abs(v1[i]) >= threshold1 ? v1[i] : 0
            let trimmed2 = abs(v2[i]) >= threshold2 ? v2[i] : 0

            let values = [trimmed1, trimmed2].filter { $0 != 0 }
            guard !values.isEmpty else { continue }

            // Elect sign by majority
            let positiveCount = values.filter { $0 > 0 }.count
            let sign: Float = positiveCount > values.count / 2 ? 1 : -1

            // Average magnitudes with elected sign
            let agreeing = values.filter { $0 * sign > 0 }
            if !agreeing.isEmpty {
                result[i] = sign * (agreeing.map { abs($0) }.reduce(0, +) / Float(agreeing.count))
            }
        }

        return result
    }

    private static func slerpLoRA(_ a: LoRAWeights, _ b: LoRAWeights, t: Float) -> LoRAWeights {
        LoRAWeights(
            rank: a.rank,
            matricesA: zip(a.matricesA, b.matricesA).map { slerpVector($0, $1, t: t) },
            matricesB: zip(a.matricesB, b.matricesB).map { slerpVector($0, $1, t: t) },
            scalingFactor: (1 - t) * a.scalingFactor + t * b.scalingFactor
        )
    }

    private static func slerpVector(_ v1: [Float], _ v2: [Float], t: Float) -> [Float] {
        // Normalize vectors
        let norm1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let norm2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))

        guard norm1 > 0 && norm2 > 0 else {
            return zip(v1, v2).map { (1 - t) * $0 + t * $1 }  // Fallback to lerp
        }

        let normalized1 = v1.map { $0 / norm1 }
        let normalized2 = v2.map { $0 / norm2 }

        // Compute angle
        let dot = zip(normalized1, normalized2).map { $0 * $1 }.reduce(0, +)
        let theta = acos(min(1, max(-1, dot)))

        guard theta > 0.001 else {
            return zip(v1, v2).map { (1 - t) * $0 + t * $1 }  // Nearly parallel, use lerp
        }

        // SLERP formula
        let sinTheta = sin(theta)
        let w1 = sin((1 - t) * theta) / sinTheta
        let w2 = sin(t * theta) / sinTheta

        // Interpolate and restore magnitude
        let interpNorm = (1 - t) * norm1 + t * norm2
        return zip(normalized1, normalized2).map { (w1 * $0 + w2 * $1) * interpNorm }
    }

    private static func crossoverLoRA(_ a: LoRAWeights, _ b: LoRAWeights, rate: Float) -> LoRAWeights {
        LoRAWeights(
            rank: a.rank,
            matricesA: zip(a.matricesA, b.matricesA).map { Float.random(in: 0...1) < rate ? $1 : $0 },
            matricesB: zip(a.matricesB, b.matricesB).map { Float.random(in: 0...1) < rate ? $1 : $0 },
            scalingFactor: Float.random(in: 0...1) < rate ? b.scalingFactor : a.scalingFactor
        )
    }

    private static func crossoverVector(_ v1: [Float], _ v2: [Float], rate: Float) -> [Float] {
        zip(v1, v2).map { Float.random(in: 0...1) < rate ? $1 : $0 }
    }

    private static func mutate(_ gene: AttentionGene, rate: Float) -> AttentionGene {
        var mutated = gene

        // Mutate LoRA weights
        mutated.spatialLoRA = mutateLoRA(gene.spatialLoRA, rate: rate)
        mutated.temporalLoRA = mutateLoRA(gene.temporalLoRA, rate: rate)

        // Mutate merge alpha
        mutated.mergeAlpha = gene.mergeAlpha.map { value in
            if Float.random(in: 0...1) < rate {
                return max(0, min(1, value + Float.random(in: -0.1...0.1)))
            }
            return value
        }

        // Mutate temperature
        if Float.random(in: 0...1) < rate * 0.1 {
            mutated.temperature = max(0.1, gene.temperature * Float.random(in: 0.9...1.1))
        }

        // Mutate thresholds
        if Float.random(in: 0...1) < rate * 0.1 {
            mutated.blackThreshold = max(0.5, min(0.9, gene.blackThreshold + Float.random(in: -0.05...0.05)))
        }
        if Float.random(in: 0...1) < rate * 0.1 {
            mutated.whiteThreshold = max(0.1, min(0.5, gene.whiteThreshold + Float.random(in: -0.05...0.05)))
        }

        return mutated
    }

    private static func mutateLoRA(_ lora: LoRAWeights, rate: Float) -> LoRAWeights {
        LoRAWeights(
            rank: lora.rank,
            matricesA: lora.matricesA.map { layer in
                layer.map { weight in
                    if Float.random(in: 0...1) < rate {
                        return weight + Float.random(in: -0.01...0.01)
                    }
                    return weight
                }
            },
            matricesB: lora.matricesB.map { layer in
                layer.map { weight in
                    if Float.random(in: 0...1) < rate {
                        return weight + Float.random(in: -0.01...0.01)
                    }
                    return weight
                }
            },
            scalingFactor: lora.scalingFactor
        )
    }
}

// MARK: - Stone Encoder

/// Learnable RGB-to-Stone encoder using gene parameters.
public struct GeneticStoneEncoder {

    /// Encode RGB to stone probabilities using Gumbel-Softmax.
    ///
    /// Returns soft probabilities (black, white, empty) that are differentiable
    /// during training but can be discretized for inference.
    public static func encode(
        r: UInt8, g: UInt8, b: UInt8,
        gene: AttentionGene,
        temperature: Float? = nil
    ) -> (black: Float, white: Float, empty: Float) {

        let temp = temperature ?? gene.temperature

        // Compute features
        let brightness = (Float(r) + Float(g) + Float(b)) / (3 * 255)
        let saturation = computeSaturation(r: r, g: g, b: b)
        let energy = max(Float(r), Float(g), Float(b)) / 255

        // Compute logits using gene thresholds
        let logitBlack = gene.blackThreshold * brightness + (1 - gene.blackThreshold) * energy
        let logitWhite = (1 - gene.whiteThreshold) * (1 - brightness)
        let logitEmpty = 0.5 - abs(brightness - 0.5) * 0.3 + saturation * 0.2

        // Softmax with temperature
        let maxLogit = max(logitBlack, logitWhite, logitEmpty)
        let expBlack = exp((logitBlack - maxLogit) / temp)
        let expWhite = exp((logitWhite - maxLogit) / temp)
        let expEmpty = exp((logitEmpty - maxLogit) / temp)
        let sum = expBlack + expWhite + expEmpty

        return (expBlack / sum, expWhite / sum, expEmpty / sum)
    }

    /// Sample discrete stone color for inference.
    public static func sample(r: UInt8, g: UInt8, b: UInt8, gene: AttentionGene) -> StoneColor {
        let probs = encode(r: r, g: g, b: b, gene: gene, temperature: 0.1)

        if probs.black > probs.white && probs.black > probs.empty {
            return .black
        } else if probs.white > probs.empty {
            return .white
        } else {
            return .empty
        }
    }

    /// Triplet (codon) encoding - maps RGB levels to stones like DNA codons.
    public static func tripletEncode(
        r: UInt8, g: UInt8, b: UInt8,
        gene: AttentionGene
    ) -> StoneColor {
        // Quantize each channel to 3 levels (0, 1, 2)
        let rLevel = min(2, Int(Float(r) / 85.0))
        let gLevel = min(2, Int(Float(g) / 85.0))
        let bLevel = min(2, Int(Float(b) / 85.0))

        // Triplet index (0-26)
        let index = rLevel * 9 + gLevel * 3 + bLevel

        // Use gene's codon table or default
        let table = gene.codonTable ?? defaultCodonTable
        return table[index]
    }

    /// Default codon table (27 entries).
    private static var defaultCodonTable: [StoneColor] {
        [
            .white,  // 000 - very dark
            .white,  // 001
            .empty,  // 002
            .white,  // 010
            .empty,  // 011
            .empty,  // 012
            .empty,  // 020
            .empty,  // 021
            .black,  // 022 - high G,B
            .white,  // 100
            .empty,  // 101
            .empty,  // 102
            .empty,  // 110
            .empty,  // 111 - gray (neutral)
            .empty,  // 112
            .empty,  // 120
            .empty,  // 121
            .black,  // 122
            .empty,  // 200
            .empty,  // 201
            .black,  // 202 - high R,B (magenta)
            .empty,  // 210
            .empty,  // 211
            .black,  // 212
            .black,  // 220 - high R,G (yellow)
            .black,  // 221
            .black,  // 222 - very bright
        ]
    }

    private static func computeSaturation(r: UInt8, g: UInt8, b: UInt8) -> Float {
        let rf = Float(r) / 255
        let gf = Float(g) / 255
        let bf = Float(b) / 255
        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        return maxC > 0 ? (maxC - minC) / maxC : 0
    }
}

// MARK: - Attention Balancer

/// Computes balanced attention weights from spatial and temporal policies.
public struct GeneticAttentionBalancer {

    /// Compute 729 attention weights using gene parameters.
    public static func computeWeights(
        spatialPolicies: [[Float]],   // 9 frames × 81 positions
        temporalPolicies: [[Float]],  // 9 columns × 81 positions
        gene: AttentionGene
    ) -> [Float] {

        var result = [Float](repeating: 0, count: 729)

        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let idx = t * 81 + y * 9 + x

                    // Q from spatial: frame t, position (y,x)
                    let q = spatialPolicies[t][y * 9 + x]

                    // K from temporal: column x, position (t,y)
                    let k = temporalPolicies[x][t * 9 + y]

                    // Learned balance for this time slice
                    let alpha = gene.mergeAlpha[t]

                    // Temperature-scaled attention
                    let attention = (q * k) / sqrt(gene.temperature)

                    // Weighted geometric merge
                    result[idx] = pow(q, alpha) * pow(k, 1 - alpha) * attention
                }
            }
        }

        // Normalize
        let sum = result.reduce(0, +)
        if sum > 0 {
            result = result.map { $0 / sum }
        }

        return result
    }
}

// MARK: - Gene Serialization

extension AttentionGene {

    /// Serialize to compact binary format.
    public func toData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// Deserialize from binary format.
    public static func fromData(_ data: Data) throws -> AttentionGene {
        let decoder = JSONDecoder()
        return try decoder.decode(AttentionGene.self, from: data)
    }

    /// Export to file.
    public func save(to url: URL) throws {
        let data = try toData()
        try data.write(to: url)
    }

    /// Import from file.
    public static func load(from url: URL) throws -> AttentionGene {
        let data = try Data(contentsOf: url)
        return try fromData(data)
    }
}

// MARK: - Gene Description

extension AttentionGene: CustomStringConvertible {
    public var description: String {
        let affinityString = specializationAffinity
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key.rawValue): \(String(format: "%.0f%%", $0.value * 100))" }
            .joined(separator: ", ")

        return """
        AttentionGene "\(name)"
          ID: \(id.uuidString.prefix(8))
          Generation: \(generation)
          Parents: \(parentIDs.count)
          Parameters: \(parameterCount) (~\(estimatedSize / 1024) KB)
          Fitness: \(String(format: "%.3f", fitness))
          Adoption: \(adoptionCount)
          Quality: \(String(format: "%.2f", qualityScore))
          Specialization: \(specialization?.rawValue ?? "none")
          Dominant Affinity: \(dominantAffinity?.rawValue ?? "none")
          Top Affinities: \(affinityString)
        """
    }
}
