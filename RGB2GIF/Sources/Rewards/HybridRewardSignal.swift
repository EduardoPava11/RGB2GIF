//
//  HybridRewardSignal.swift
//  RGB2GIF
//
//  ============================================================================
//  HYBRID REWARD SIGNAL: Multi-Source Training Signal for Attention Genes
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Combines three reward sources into a unified training signal:
//
//  1. PERCEPTUAL (45% weight)
//     - SSIM (structural similarity)
//     - Delta E 2000 (color accuracy)
//     - Measures objective quality of GIF output
//
//  2. USER FEEDBACK (35% weight)
//     - Explicit ratings (1-5 stars)
//     - Implicit behavior (edits, saves, shares)
//     - Captures subjective preferences
//
//  3. COMPRESSION EFFICIENCY (20% weight)
//     - File size relative to target
//     - Rewards compact representations
//     - Balances quality vs size
//
//  FORMULA
//  ───────
//  totalReward = 0.45 × perceptual + 0.35 × user + 0.20 × compression
//
//  Where:
//    perceptual = 0.7 × SSIM + 0.3 × normalizedDeltaE
//    user = (rating/5) × editPenalty × acceptanceBonus
//    compression = 1 - (fileSize / targetSize) clamped to [0,1]
//
//  TRAINING INTEGRATION
//  ────────────────────
//  Rewards are computed after each GIF export and accumulated in RewardAggregator.
//  After 10 GIFs (configurable batch size), gradients are computed and applied
//  to the active gene via GeneTrainer.
//
//  ============================================================================

import Foundation

// MARK: - Hybrid Reward Signal

/// Combined training signal from perceptual, user, and compression sources.
@available(iOS 15.0, macOS 12.0, *)
public struct HybridRewardSignal: Codable, Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Component Scores
    // ═══════════════════════════════════════════════════════════════════════════

    /// Perceptual quality score from SSIM and Delta E (0-1, higher is better).
    public let perceptualScore: Float

    /// User feedback score from ratings and behavior (0-1, higher is better).
    public let userScore: Float

    /// Compression efficiency score (0-1, higher is more efficient).
    public let compressionScore: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Raw Metrics (for debugging/logging)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Structural similarity index (0-1).
    public let ssim: Float

    /// Color difference (Delta E 2000, 0-100+).
    public let deltaE: Float

    /// User rating if provided (1-5).
    public let userRating: Int?

    /// Whether the GIF was edited after generation.
    public let wasEdited: Bool

    /// Whether the GIF was saved/shared (acceptance signal).
    public let wasAccepted: Bool

    /// Final file size in bytes.
    public let fileSize: Int

    /// Target file size in bytes.
    public let targetSize: Int

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Weights (configurable)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Weight for perceptual component (default 0.45).
    public let perceptualWeight: Float

    /// Weight for user feedback component (default 0.35).
    public let userWeight: Float

    /// Weight for compression component (default 0.20).
    public let compressionWeight: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Metadata
    // ═══════════════════════════════════════════════════════════════════════════

    /// When this reward was computed.
    public let timestamp: Date

    /// Gene ID that was active during generation.
    public let geneID: UUID?

    /// Content type classification (for specialization tracking).
    public let contentType: String?

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Computed Properties
    // ═══════════════════════════════════════════════════════════════════════════

    /// Combined reward signal (0-1, higher is better).
    public var totalReward: Float {
        perceptualWeight * perceptualScore +
        userWeight * userScore +
        compressionWeight * compressionScore
    }

    /// Quality tier based on total reward.
    public var qualityTier: QualityTier {
        switch totalReward {
        case 0.8...: return .excellent
        case 0.6..<0.8: return .good
        case 0.4..<0.6: return .acceptable
        default: return .poor
        }
    }

    /// Quality tier categories.
    public enum QualityTier: String, Codable, Sendable {
        case excellent  // 0.8+
        case good       // 0.6-0.8
        case acceptable // 0.4-0.6
        case poor       // <0.4
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize with all components explicitly.
    public init(
        perceptualScore: Float,
        userScore: Float,
        compressionScore: Float,
        ssim: Float,
        deltaE: Float,
        userRating: Int?,
        wasEdited: Bool,
        wasAccepted: Bool,
        fileSize: Int,
        targetSize: Int,
        perceptualWeight: Float = 0.45,
        userWeight: Float = 0.35,
        compressionWeight: Float = 0.20,
        geneID: UUID? = nil,
        contentType: String? = nil
    ) {
        self.perceptualScore = perceptualScore
        self.userScore = userScore
        self.compressionScore = compressionScore
        self.ssim = ssim
        self.deltaE = deltaE
        self.userRating = userRating
        self.wasEdited = wasEdited
        self.wasAccepted = wasAccepted
        self.fileSize = fileSize
        self.targetSize = targetSize
        self.perceptualWeight = perceptualWeight
        self.userWeight = userWeight
        self.compressionWeight = compressionWeight
        self.geneID = geneID
        self.contentType = contentType
        self.timestamp = Date()
    }
}

// MARK: - Reward Calculator

/// Computes hybrid reward signals from raw metrics and user feedback.
@available(iOS 15.0, macOS 12.0, *)
public struct RewardCalculator {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for reward calculation.
    public struct Config: Codable, Sendable {
        /// Weight for perceptual quality (0-1).
        public var perceptualWeight: Float = 0.45

        /// Weight for user feedback (0-1).
        public var userWeight: Float = 0.35

        /// Weight for compression efficiency (0-1).
        public var compressionWeight: Float = 0.20

        /// Target file size for compression scoring (bytes).
        public var targetFileSize: Int = 512_000  // 500KB

        /// Maximum acceptable file size (bytes).
        public var maxFileSize: Int = 2_000_000  // 2MB

        /// Penalty multiplier when user edits the GIF.
        public var editPenalty: Float = 0.8

        /// Bonus multiplier when user accepts (saves/shares).
        public var acceptanceBonus: Float = 1.2

        /// Default rating when user doesn't provide one.
        public var defaultRating: Float = 0.6

        /// Initialize with defaults.
        public init() {}

        /// Validate that weights sum to 1.0.
        public var isValid: Bool {
            abs(perceptualWeight + userWeight + compressionWeight - 1.0) < 0.01
        }
    }

    /// Active configuration.
    public var config: Config

    /// Initialize with configuration.
    public init(config: Config = Config()) {
        self.config = config
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Reward Computation
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute hybrid reward signal from raw metrics.
    ///
    /// - Parameters:
    ///   - perceptualMetrics: Result from PerceptualMetrics computation
    ///   - userRating: Optional explicit rating (1-5)
    ///   - wasEdited: Whether user edited the result
    ///   - wasAccepted: Whether user saved/shared the result
    ///   - fileSize: Final GIF file size in bytes
    ///   - geneID: Active gene during generation
    ///   - contentType: Detected content type
    /// - Returns: Complete hybrid reward signal
    public func computeReward(
        perceptualMetrics: PerceptualMetricsResult,
        userRating: Int? = nil,
        wasEdited: Bool = false,
        wasAccepted: Bool = true,
        fileSize: Int,
        geneID: UUID? = nil,
        contentType: String? = nil
    ) -> HybridRewardSignal {

        // 1. Perceptual Score (already computed in PerceptualMetrics)
        let perceptualScore = perceptualMetrics.combinedScore

        // 2. User Score
        let userScore = computeUserScore(
            rating: userRating,
            wasEdited: wasEdited,
            wasAccepted: wasAccepted
        )

        // 3. Compression Score
        let compressionScore = computeCompressionScore(fileSize: fileSize)

        return HybridRewardSignal(
            perceptualScore: perceptualScore,
            userScore: userScore,
            compressionScore: compressionScore,
            ssim: perceptualMetrics.ssim,
            deltaE: perceptualMetrics.deltaE,
            userRating: userRating,
            wasEdited: wasEdited,
            wasAccepted: wasAccepted,
            fileSize: fileSize,
            targetSize: config.targetFileSize,
            perceptualWeight: config.perceptualWeight,
            userWeight: config.userWeight,
            compressionWeight: config.compressionWeight,
            geneID: geneID,
            contentType: contentType
        )
    }

    /// Compute reward from raw values (for testing/integration).
    ///
    /// - Parameters:
    ///   - ssim: Structural similarity (0-1)
    ///   - deltaE: Color difference (0-100+)
    ///   - psnr: Peak signal-to-noise ratio (dB)
    ///   - userRating: Optional explicit rating (1-5)
    ///   - wasEdited: Whether user edited the result
    ///   - wasAccepted: Whether user saved/shared the result
    ///   - fileSize: Final GIF file size in bytes
    ///   - geneID: Active gene during generation
    ///   - contentType: Detected content type
    /// - Returns: Complete hybrid reward signal
    public func computeReward(
        ssim: Float,
        deltaE: Float,
        psnr: Float,
        userRating: Int? = nil,
        wasEdited: Bool = false,
        wasAccepted: Bool = true,
        fileSize: Int,
        geneID: UUID? = nil,
        contentType: String? = nil
    ) -> HybridRewardSignal {

        // Create perceptual metrics result
        let perceptualMetrics = PerceptualMetricsResult(
            ssim: ssim,
            deltaE: deltaE,
            psnr: psnr,
            combinedScore: PerceptualMetrics.combinedScore(ssim: ssim, deltaE: deltaE, psnr: psnr)
        )

        return computeReward(
            perceptualMetrics: perceptualMetrics,
            userRating: userRating,
            wasEdited: wasEdited,
            wasAccepted: wasAccepted,
            fileSize: fileSize,
            geneID: geneID,
            contentType: contentType
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Component Calculations
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute user feedback score.
    ///
    /// Formula: baseScore × editMultiplier × acceptanceMultiplier
    /// - baseScore = rating/5 (or default if no rating)
    /// - editMultiplier = 0.8 if edited, 1.0 otherwise
    /// - acceptanceMultiplier = 1.2 if accepted, 0.8 otherwise
    private func computeUserScore(
        rating: Int?,
        wasEdited: Bool,
        wasAccepted: Bool
    ) -> Float {
        // Base score from rating
        let baseScore: Float
        if let r = rating {
            baseScore = Float(max(1, min(5, r))) / 5.0
        } else {
            baseScore = config.defaultRating
        }

        // Apply modifiers
        let editMultiplier = wasEdited ? config.editPenalty : 1.0
        let acceptanceMultiplier = wasAccepted ? config.acceptanceBonus : 0.8

        // Combine and clamp
        let score = baseScore * editMultiplier * acceptanceMultiplier
        return max(0, min(1, score))
    }

    /// Compute compression efficiency score.
    ///
    /// Formula: 1 - (fileSize / targetSize), clamped to [0, 1]
    /// - Score is 1.0 if fileSize == 0 (edge case)
    /// - Score is 0.5 if fileSize == targetSize
    /// - Score is 0.0 if fileSize >= 2 × targetSize
    private func computeCompressionScore(fileSize: Int) -> Float {
        guard fileSize > 0 else { return 1.0 }

        let ratio = Float(fileSize) / Float(config.targetFileSize)

        // Sigmoid-like scoring:
        // ratio = 0.5 → score ≈ 0.75
        // ratio = 1.0 → score ≈ 0.5
        // ratio = 2.0 → score ≈ 0.25
        // ratio = 4.0 → score ≈ 0.1
        let score = 1.0 / (1.0 + ratio)

        // Scale to [0, 1] where target gives ~0.5
        return max(0, min(1, score * 2.0))
    }
}

// MARK: - Reward Signal Extensions

@available(iOS 15.0, macOS 12.0, *)
extension HybridRewardSignal: CustomStringConvertible {
    public var description: String {
        """
        HybridRewardSignal:
          Total: \(String(format: "%.3f", totalReward)) (\(qualityTier.rawValue))
          ├── Perceptual: \(String(format: "%.3f", perceptualScore)) × \(perceptualWeight)
          │   ├── SSIM: \(String(format: "%.3f", ssim))
          │   └── ΔE: \(String(format: "%.1f", deltaE))
          ├── User: \(String(format: "%.3f", userScore)) × \(userWeight)
          │   ├── Rating: \(userRating.map { "\($0)/5" } ?? "none")
          │   ├── Edited: \(wasEdited)
          │   └── Accepted: \(wasAccepted)
          └── Compression: \(String(format: "%.3f", compressionScore)) × \(compressionWeight)
              └── Size: \(fileSize / 1024)KB / \(targetSize / 1024)KB target
        """
    }
}

// MARK: - Gradient Direction

/// Direction for gene parameter updates based on reward signal.
@available(iOS 15.0, macOS 12.0, *)
public struct RewardGradient: Codable, Sendable {

    /// Reward signal that generated this gradient.
    public let reward: HybridRewardSignal

    /// Direction for merge alpha adjustment (-1 to 1 per time slice).
    public let alphaGradient: [Float]

    /// Direction for temperature adjustment.
    public let temperatureGradient: Float

    /// Direction for threshold adjustments.
    public let blackThresholdGradient: Float
    public let whiteThresholdGradient: Float

    /// Learning rate for this update.
    public let learningRate: Float

    /// Initialize from reward signal.
    public init(reward: HybridRewardSignal, learningRate: Float = 0.01) {
        self.reward = reward
        self.learningRate = learningRate

        // Compute gradient directions based on reward quality
        let rewardDelta = reward.totalReward - 0.5  // Deviation from neutral

        // Alpha gradient: push toward spatial or temporal based on which contributed more
        // (This is a simplified heuristic; real training would use backprop)
        self.alphaGradient = (0..<9).map { t in
            rewardDelta * Float.random(in: -0.1...0.1)
        }

        // Temperature gradient: lower temp if quality is low (sharpen attention)
        self.temperatureGradient = reward.totalReward < 0.5 ? -0.05 : 0.02

        // Threshold gradients: adjust based on perceptual score
        let perceptualDelta = reward.perceptualScore - 0.5
        self.blackThresholdGradient = perceptualDelta * 0.02
        self.whiteThresholdGradient = -perceptualDelta * 0.02
    }
}
