//
//  GeneTrainer.swift
//  RGB2GIF
//
//  ============================================================================
//  GENE TRAINER: On-Device Learning with EWC Regularization
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Trains attention genes from hybrid reward signals while preventing
//  catastrophic forgetting through Elastic Weight Consolidation (EWC).
//
//  The trainer:
//  1. Accumulates reward signals in batches
//  2. Computes gradients from reward-weighted parameter changes
//  3. Applies EWC regularization to protect important weights
//  4. Updates gene parameters with momentum
//
//  EWC ALGORITHM
//  ─────────────
//  After training on task A, EWC prevents forgetting by:
//
//  1. Computing Fisher Information Matrix F_i for each parameter θ_i
//     F_i = E[(∂log p(x|θ) / ∂θ_i)²]
//     This measures how important each parameter is for task A
//
//  2. When training on task B, adding regularization:
//     L_total = L_B + (λ/2) × Σ_i F_i × (θ_i - θ*_i)²
//     Where θ*_i are the optimal parameters for task A
//
//  This allows the model to learn task B while staying close to task A
//  performance on important parameters.
//
//  BATCH TRAINING
//  ──────────────
//  Training happens in batches (default: 10 GIFs) to:
//  - Reduce variance from individual samples
//  - Amortize EWC computation overhead
//  - Enable mini-batch gradient estimation
//
//  ============================================================================

import Foundation

// MARK: - Gene Trainer

/// Trains attention genes using hybrid reward signals with EWC regularization.
@available(iOS 15.0, macOS 12.0, *)
public actor GeneTrainer {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ═══════════════════════════════════════════════════════════════════════════

    /// Gene pool to update.
    private let genePool: GenePool

    /// Accumulated training samples.
    private var trainingBuffer: [TrainingSample]

    /// Fisher information matrices for EWC.
    private var fisherMatrices: [AttentionGene.ContentType: FisherMatrix]

    /// Optimal parameters from previous training.
    private var previousOptimalParams: [AttentionGene.ContentType: GeneParameters]

    /// Momentum accumulators for parameter updates.
    private var momentumBuffers: [AttentionGene.ContentType: GeneParameters]

    /// Configuration.
    public let config: Config

    /// Training statistics.
    private var stats: TrainingStatistics

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for gene training.
    public struct Config: Codable, Sendable {
        /// Number of samples before triggering batch update.
        public var batchSize: Int = 10

        /// Learning rate for parameter updates.
        public var learningRate: Float = 0.01

        /// Momentum coefficient for updates.
        public var momentum: Float = 0.9

        /// EWC regularization strength (λ).
        public var ewcLambda: Float = 0.5

        /// Minimum Fisher information to consider parameter important.
        public var fisherThreshold: Float = 0.001

        /// Decay rate for Fisher information over time.
        public var fisherDecay: Float = 0.99

        /// Maximum gradient magnitude (for clipping).
        public var maxGradientNorm: Float = 1.0

        /// Minimum reward to include in training.
        public var minRewardThreshold: Float = 0.1

        /// Initialize with defaults.
        public init() {}
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize trainer with gene pool.
    public init(genePool: GenePool, config: Config = Config()) {
        self.genePool = genePool
        self.config = config
        self.trainingBuffer = []
        self.fisherMatrices = [:]
        self.previousOptimalParams = [:]
        self.momentumBuffers = [:]
        self.stats = TrainingStatistics()
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Training Interface
    // ═══════════════════════════════════════════════════════════════════════════

    /// Add a training sample from GIF generation.
    ///
    /// - Parameters:
    ///   - reward: Hybrid reward signal from generation
    ///   - gene: Gene that was used for generation
    ///   - attentionWeights: Attention weights produced (729 values)
    ///   - contentType: Detected content type
    /// - Returns: True if batch update was triggered
    @discardableResult
    public func addSample(
        reward: HybridRewardSignal,
        gene: AttentionGene,
        attentionWeights: [Float],
        contentType: AttentionGene.ContentType
    ) async -> Bool {
        // Filter low-quality samples
        guard reward.totalReward >= config.minRewardThreshold else {
            return false
        }

        let sample = TrainingSample(
            reward: reward,
            gene: gene,
            attentionWeights: attentionWeights,
            contentType: contentType
        )

        trainingBuffer.append(sample)
        stats.samplesReceived += 1

        // Check if batch update should trigger
        if trainingBuffer.count >= config.batchSize {
            await processBatch()
            return true
        }

        return false
    }

    /// Force batch processing even if batch not full.
    public func flush() async {
        if !trainingBuffer.isEmpty {
            await processBatch()
        }
    }

    /// Get current training statistics.
    public func getStatistics() -> TrainingStatistics {
        stats
    }

    /// Reset trainer state (keeps gene pool).
    public func reset() {
        trainingBuffer.removeAll()
        fisherMatrices.removeAll()
        previousOptimalParams.removeAll()
        momentumBuffers.removeAll()
        stats = TrainingStatistics()
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Batch Processing
    // ═══════════════════════════════════════════════════════════════════════════

    /// Process accumulated batch of training samples.
    private func processBatch() async {
        guard !trainingBuffer.isEmpty else { return }

        let batchStart = Date()

        // Group samples by content type
        var samplesByType: [AttentionGene.ContentType: [TrainingSample]] = [:]
        for sample in trainingBuffer {
            samplesByType[sample.contentType, default: []].append(sample)
        }

        // Update each content type's gene
        for (contentType, samples) in samplesByType {
            await updateGene(for: contentType, with: samples)
        }

        // Update statistics
        stats.batchesProcessed += 1
        stats.totalTrainingTime += Date().timeIntervalSince(batchStart)

        // Clear buffer
        trainingBuffer.removeAll()
    }

    /// Update gene for a specific content type from samples.
    private func updateGene(for contentType: AttentionGene.ContentType, with samples: [TrainingSample]) async {
        guard let baseGene = await genePool.getGene(for: contentType) else { return }

        // Compute gradients from samples
        let gradients = computeGradients(from: samples, baseGene: baseGene)

        // Apply EWC regularization
        let regularizedGradients = applyEWCRegularization(
            gradients: gradients,
            contentType: contentType,
            currentParams: extractParameters(from: baseGene)
        )

        // Apply momentum
        let momentumGradients = applyMomentum(
            gradients: regularizedGradients,
            contentType: contentType
        )

        // Clip gradients
        let clippedGradients = clipGradients(momentumGradients)

        // Apply updates to gene
        var updatedGene = baseGene
        applyGradients(clippedGradients, to: &updatedGene)

        // Update gene in pool
        await genePool.updateGene(for: contentType, with: updatedGene)

        // Update Fisher information
        updateFisherMatrix(for: contentType, samples: samples, gene: updatedGene)

        // Store optimal parameters for future EWC
        previousOptimalParams[contentType] = extractParameters(from: updatedGene)

        // Update quality score in pool
        let avgReward = samples.map { $0.reward.totalReward }.reduce(0, +) / Float(samples.count)
        await genePool.updateQualityScore(for: contentType, reward: avgReward)

        stats.genesUpdated += 1
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gradient Computation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute gradients from training samples.
    private func computeGradients(from samples: [TrainingSample], baseGene: AttentionGene) -> GeneGradients {
        var alphaGradients = [Float](repeating: 0, count: 9)
        var temperatureGradient: Float = 0
        var blackThresholdGradient: Float = 0
        var whiteThresholdGradient: Float = 0
        var loraGradients = LoRAGradients(rank: baseGene.spatialLoRA.rank)

        // Compute reward-weighted gradients
        for sample in samples {
            // Reward delta from baseline (0.5 is neutral)
            let rewardDelta = sample.reward.totalReward - 0.5

            // Alpha gradients: use attention weight statistics
            for t in 0..<9 {
                let sliceWeights = Array(sample.attentionWeights[(t * 81)..<((t + 1) * 81)])
                let variance = computeVariance(sliceWeights)
                // Push alpha toward spatial if variance is high (more focused attention)
                alphaGradients[t] += rewardDelta * (variance > 0.1 ? 0.1 : -0.1)
            }

            // Temperature gradient: lower if quality low, higher if good
            temperatureGradient += rewardDelta * 0.02

            // Threshold gradients based on perceptual quality
            let perceptualDelta = sample.reward.perceptualScore - 0.5
            blackThresholdGradient += perceptualDelta * 0.01
            whiteThresholdGradient -= perceptualDelta * 0.01

            // LoRA gradients (simplified: proportional to reward)
            loraGradients.accumulate(scale: rewardDelta * 0.001)
        }

        // Average over samples
        let n = Float(samples.count)
        return GeneGradients(
            alphaGradients: alphaGradients.map { $0 / n },
            temperatureGradient: temperatureGradient / n,
            blackThresholdGradient: blackThresholdGradient / n,
            whiteThresholdGradient: whiteThresholdGradient / n,
            loraGradients: loraGradients.scaled(by: 1.0 / n)
        )
    }

    /// Compute variance of a slice.
    private func computeVariance(_ values: [Float]) -> Float {
        let n = Float(values.count)
        guard n > 1 else { return 0 }
        let mean = values.reduce(0, +) / n
        let sumSquaredDiff = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSquaredDiff / (n - 1)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - EWC Regularization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Apply EWC regularization to gradients.
    private func applyEWCRegularization(
        gradients: GeneGradients,
        contentType: AttentionGene.ContentType,
        currentParams: GeneParameters
    ) -> GeneGradients {
        guard let fisher = fisherMatrices[contentType],
              let optimal = previousOptimalParams[contentType] else {
            return gradients  // No previous training, no regularization
        }

        var regularized = gradients

        // Regularize alpha gradients
        for i in 0..<9 {
            let paramDiff = currentParams.mergeAlpha[i] - optimal.mergeAlpha[i]
            let importance = fisher.alphaFisher[i]

            if importance > config.fisherThreshold {
                regularized.alphaGradients[i] -= config.ewcLambda * importance * paramDiff
            }
        }

        // Regularize temperature
        let tempDiff = currentParams.temperature - optimal.temperature
        if fisher.temperatureFisher > config.fisherThreshold {
            regularized.temperatureGradient -= config.ewcLambda * fisher.temperatureFisher * tempDiff
        }

        // Regularize thresholds
        let blackDiff = currentParams.blackThreshold - optimal.blackThreshold
        if fisher.blackThresholdFisher > config.fisherThreshold {
            regularized.blackThresholdGradient -= config.ewcLambda * fisher.blackThresholdFisher * blackDiff
        }

        let whiteDiff = currentParams.whiteThreshold - optimal.whiteThreshold
        if fisher.whiteThresholdFisher > config.fisherThreshold {
            regularized.whiteThresholdGradient -= config.ewcLambda * fisher.whiteThresholdFisher * whiteDiff
        }

        return regularized
    }

    /// Update Fisher information matrix after training.
    private func updateFisherMatrix(
        for contentType: AttentionGene.ContentType,
        samples: [TrainingSample],
        gene: AttentionGene
    ) {
        var fisher = fisherMatrices[contentType] ?? FisherMatrix()

        // Decay existing Fisher info
        fisher.decay(by: config.fisherDecay)

        // Compute new Fisher contributions from samples
        for sample in samples {
            let rewardDelta = sample.reward.totalReward - 0.5

            // Fisher ≈ squared gradient (simplified)
            for t in 0..<9 {
                let sliceWeights = Array(sample.attentionWeights[(t * 81)..<((t + 1) * 81)])
                let variance = computeVariance(sliceWeights)
                let gradSquared = pow(rewardDelta * (variance > 0.1 ? 0.1 : -0.1), 2)
                fisher.alphaFisher[t] += gradSquared / Float(samples.count)
            }

            fisher.temperatureFisher += pow(rewardDelta * 0.02, 2) / Float(samples.count)
            fisher.blackThresholdFisher += pow(sample.reward.perceptualScore * 0.01, 2) / Float(samples.count)
            fisher.whiteThresholdFisher += pow(sample.reward.perceptualScore * 0.01, 2) / Float(samples.count)
        }

        fisherMatrices[contentType] = fisher
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Momentum
    // ═══════════════════════════════════════════════════════════════════════════

    /// Apply momentum to gradients.
    private func applyMomentum(gradients: GeneGradients, contentType: AttentionGene.ContentType) -> GeneGradients {
        var momentum = momentumBuffers[contentType] ?? GeneParameters.zero()

        // Update momentum: m = β × m + (1-β) × g
        momentum.mergeAlpha = zip(momentum.mergeAlpha, gradients.alphaGradients).map {
            config.momentum * $0 + (1 - config.momentum) * $1
        }
        momentum.temperature = config.momentum * momentum.temperature + (1 - config.momentum) * gradients.temperatureGradient
        momentum.blackThreshold = config.momentum * momentum.blackThreshold + (1 - config.momentum) * gradients.blackThresholdGradient
        momentum.whiteThreshold = config.momentum * momentum.whiteThreshold + (1 - config.momentum) * gradients.whiteThresholdGradient

        momentumBuffers[contentType] = momentum

        return GeneGradients(
            alphaGradients: momentum.mergeAlpha,
            temperatureGradient: momentum.temperature,
            blackThresholdGradient: momentum.blackThreshold,
            whiteThresholdGradient: momentum.whiteThreshold,
            loraGradients: gradients.loraGradients
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gradient Application
    // ═══════════════════════════════════════════════════════════════════════════

    /// Clip gradients to prevent instability.
    private func clipGradients(_ gradients: GeneGradients) -> GeneGradients {
        let norm = sqrt(
            gradients.alphaGradients.map { $0 * $0 }.reduce(0, +) +
            gradients.temperatureGradient * gradients.temperatureGradient +
            gradients.blackThresholdGradient * gradients.blackThresholdGradient +
            gradients.whiteThresholdGradient * gradients.whiteThresholdGradient
        )

        if norm > config.maxGradientNorm {
            let scale = config.maxGradientNorm / norm
            return GeneGradients(
                alphaGradients: gradients.alphaGradients.map { $0 * scale },
                temperatureGradient: gradients.temperatureGradient * scale,
                blackThresholdGradient: gradients.blackThresholdGradient * scale,
                whiteThresholdGradient: gradients.whiteThresholdGradient * scale,
                loraGradients: gradients.loraGradients.scaled(by: scale)
            )
        }

        return gradients
    }

    /// Apply gradients to gene parameters.
    private func applyGradients(_ gradients: GeneGradients, to gene: inout AttentionGene) {
        // Update merge alpha (clamped to [0, 1])
        for i in 0..<9 {
            gene.mergeAlpha[i] = max(0, min(1, gene.mergeAlpha[i] + config.learningRate * gradients.alphaGradients[i]))
        }

        // Update temperature (clamped to [0.1, 2.0])
        gene.temperature = max(0.1, min(2.0, gene.temperature + config.learningRate * gradients.temperatureGradient))

        // Update thresholds (maintaining black > white constraint)
        gene.blackThreshold = max(0.5, min(0.9, gene.blackThreshold + config.learningRate * gradients.blackThresholdGradient))
        gene.whiteThreshold = max(0.1, min(0.5, gene.whiteThreshold + config.learningRate * gradients.whiteThresholdGradient))

        // Ensure constraint: blackThreshold > whiteThreshold
        if gene.blackThreshold <= gene.whiteThreshold {
            let mid = (gene.blackThreshold + gene.whiteThreshold) / 2
            gene.blackThreshold = mid + 0.1
            gene.whiteThreshold = mid - 0.1
        }

        // Increment generation
        gene.generation += 1
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Parameter Extraction
    // ═══════════════════════════════════════════════════════════════════════════

    /// Extract trainable parameters from gene.
    private func extractParameters(from gene: AttentionGene) -> GeneParameters {
        GeneParameters(
            mergeAlpha: gene.mergeAlpha,
            temperature: gene.temperature,
            blackThreshold: gene.blackThreshold,
            whiteThreshold: gene.whiteThreshold
        )
    }
}

// MARK: - Supporting Types

/// Training sample for batch processing.
struct TrainingSample {
    let reward: HybridRewardSignal
    let gene: AttentionGene
    let attentionWeights: [Float]
    let contentType: AttentionGene.ContentType
}

/// Extracted gene parameters for EWC.
struct GeneParameters {
    var mergeAlpha: [Float]
    var temperature: Float
    var blackThreshold: Float
    var whiteThreshold: Float

    static func zero() -> GeneParameters {
        GeneParameters(
            mergeAlpha: [Float](repeating: 0, count: 9),
            temperature: 0,
            blackThreshold: 0,
            whiteThreshold: 0
        )
    }
}

/// Computed gradients for gene update.
struct GeneGradients {
    var alphaGradients: [Float]
    var temperatureGradient: Float
    var blackThresholdGradient: Float
    var whiteThresholdGradient: Float
    var loraGradients: LoRAGradients
}

/// Gradients for LoRA weights.
struct LoRAGradients {
    var matricesA: [[Float]]
    var matricesB: [[Float]]

    init(rank: Int) {
        let layerSize = rank * LoRAWeights.layerDim
        self.matricesA = (0..<LoRAWeights.targetLayers).map { _ in [Float](repeating: 0, count: layerSize) }
        self.matricesB = (0..<LoRAWeights.targetLayers).map { _ in [Float](repeating: 0, count: layerSize) }
    }

    mutating func accumulate(scale: Float) {
        for layer in 0..<LoRAWeights.targetLayers {
            for i in 0..<matricesA[layer].count {
                matricesA[layer][i] += Float.random(in: -0.001...0.001) * scale
            }
            for i in 0..<matricesB[layer].count {
                matricesB[layer][i] += Float.random(in: -0.001...0.001) * scale
            }
        }
    }

    func scaled(by factor: Float) -> LoRAGradients {
        var result = self
        for layer in 0..<LoRAWeights.targetLayers {
            result.matricesA[layer] = matricesA[layer].map { $0 * factor }
            result.matricesB[layer] = matricesB[layer].map { $0 * factor }
        }
        return result
    }
}

/// Fisher information matrix for EWC.
struct FisherMatrix {
    var alphaFisher: [Float] = [Float](repeating: 0, count: 9)
    var temperatureFisher: Float = 0
    var blackThresholdFisher: Float = 0
    var whiteThresholdFisher: Float = 0

    mutating func decay(by factor: Float) {
        alphaFisher = alphaFisher.map { $0 * factor }
        temperatureFisher *= factor
        blackThresholdFisher *= factor
        whiteThresholdFisher *= factor
    }
}

/// Training statistics.
public struct TrainingStatistics: Codable, Sendable {
    public var samplesReceived: Int = 0
    public var batchesProcessed: Int = 0
    public var genesUpdated: Int = 0
    public var totalTrainingTime: TimeInterval = 0

    public var averageBatchTime: TimeInterval {
        batchesProcessed > 0 ? totalTrainingTime / Double(batchesProcessed) : 0
    }
}
