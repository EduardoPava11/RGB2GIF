//
//  RewardAggregator.swift
//  RGB2GIF
//
//  ============================================================================
//  REWARD AGGREGATOR: Batched Training Signal for Gene Evolution
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Accumulates reward signals from multiple GIF exports and computes batch
//  statistics for stable gene training. Instead of updating genes after every
//  GIF (which would cause high variance), we batch updates:
//
//    10 GIFs → 1 Gene Update
//
//  This smooths out noise from individual user interactions and produces
//  more stable learning gradients.
//
//  BATCH STATISTICS
//  ────────────────
//  For each batch, we compute:
//  - Mean reward (overall quality trend)
//  - Variance (consistency of performance)
//  - Best/worst rewards (for exploration)
//  - Per-content-type breakdown (for specialization)
//
//  TRAINING TRIGGER
//  ────────────────
//  When a batch is complete (10 GIFs), the aggregator:
//  1. Computes aggregate gradients
//  2. Notifies GeneTrainer via delegate/callback
//  3. Clears the batch buffer
//  4. Persists metrics for analytics
//
//  PERSISTENCE
//  ───────────
//  Rewards are persisted to disk for:
//  - Recovery after app termination
//  - Long-term analytics
//  - A/B testing validation
//
//  ============================================================================

import Foundation

// MARK: - Reward Aggregator

/// Batches reward signals for stable gene training.
@available(iOS 15.0, macOS 12.0, *)
public final class RewardAggregator: @unchecked Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for reward aggregation.
    public struct Config: Codable, Sendable {
        /// Number of rewards to accumulate before triggering update.
        public var batchSize: Int = 10

        /// Minimum variance to consider batch stable.
        public var minVarianceForUpdate: Float = 0.001

        /// Maximum age of rewards in batch (seconds).
        public var maxBatchAge: TimeInterval = 3600  // 1 hour

        /// Whether to persist rewards to disk.
        public var persistRewards: Bool = true

        /// Initialize with defaults.
        public init() {}
    }

    /// Active configuration.
    public let config: Config

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════════

    /// Current batch of accumulated rewards.
    private var currentBatch: [HybridRewardSignal] = []

    /// Lock for thread-safe batch access.
    private let batchLock = NSLock()

    /// Storage directory for persistence.
    private let storageDirectory: URL

    /// Total rewards processed (all time).
    private(set) public var totalRewardsProcessed: Int = 0

    /// Total batches completed (all time).
    private(set) public var totalBatchesCompleted: Int = 0

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Callbacks
    // ═══════════════════════════════════════════════════════════════════════════

    /// Called when a batch is ready for gene training.
    public var onBatchReady: ((BatchSummary) -> Void)?

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize with configuration.
    public init(config: Config = Config()) {
        self.config = config

        // Set up storage directory
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageDirectory = documents
            .appendingPathComponent("RGB2GIF")
            .appendingPathComponent("Rewards")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )

        // Load pending batch from disk
        loadPendingBatch()
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Public API
    // ═══════════════════════════════════════════════════════════════════════════

    /// Add a reward signal to the current batch.
    ///
    /// When batch size is reached, automatically triggers gene training.
    ///
    /// - Parameter reward: The reward signal to add
    /// - Returns: True if batch is now ready for processing
    @discardableResult
    public func addReward(_ reward: HybridRewardSignal) -> Bool {
        batchLock.lock()
        defer { batchLock.unlock() }

        currentBatch.append(reward)
        totalRewardsProcessed += 1

        // Persist incrementally
        if config.persistRewards {
            persistPendingBatch()
        }

        // Check if batch is ready
        if currentBatch.count >= config.batchSize {
            processBatch()
            return true
        }

        return false
    }

    /// Force process current batch even if not full.
    ///
    /// Useful for:
    /// - App backgrounding
    /// - User-initiated training
    /// - Testing
    public func flushBatch() {
        batchLock.lock()
        defer { batchLock.unlock() }

        guard !currentBatch.isEmpty else { return }
        processBatch()
    }

    /// Get current batch statistics without triggering update.
    public var currentBatchStats: BatchSummary? {
        batchLock.lock()
        defer { batchLock.unlock() }

        guard !currentBatch.isEmpty else { return nil }
        return computeBatchSummary(currentBatch)
    }

    /// Number of rewards pending in current batch.
    public var pendingCount: Int {
        batchLock.lock()
        defer { batchLock.unlock()  }
        return currentBatch.count
    }

    /// Progress toward next batch (0-1).
    public var batchProgress: Float {
        Float(pendingCount) / Float(config.batchSize)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Batch Processing
    // ═══════════════════════════════════════════════════════════════════════════

    /// Process the current batch and notify callback.
    private func processBatch() {
        // Compute summary
        let summary = computeBatchSummary(currentBatch)

        // Archive batch
        archiveBatch(currentBatch, summary: summary)

        // Clear batch
        currentBatch.removeAll()
        totalBatchesCompleted += 1

        // Clear pending file
        try? FileManager.default.removeItem(at: pendingBatchURL)

        // Notify callback
        onBatchReady?(summary)
    }

    /// Compute summary statistics for a batch.
    private func computeBatchSummary(_ batch: [HybridRewardSignal]) -> BatchSummary {
        guard !batch.isEmpty else {
            return BatchSummary.empty
        }

        let rewards = batch.map { $0.totalReward }
        let mean = rewards.reduce(0, +) / Float(rewards.count)
        let variance = rewards.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(rewards.count)

        // Per-component means
        let perceptualMean = batch.map { $0.perceptualScore }.reduce(0, +) / Float(batch.count)
        let userMean = batch.map { $0.userScore }.reduce(0, +) / Float(batch.count)
        let compressionMean = batch.map { $0.compressionScore }.reduce(0, +) / Float(batch.count)

        // Per-content-type breakdown
        var contentBreakdown: [String: ContentTypeStats] = [:]
        for reward in batch {
            guard let contentType = reward.contentType else { continue }
            if contentBreakdown[contentType] == nil {
                contentBreakdown[contentType] = ContentTypeStats(count: 0, totalReward: 0)
            }
            contentBreakdown[contentType]!.count += 1
            contentBreakdown[contentType]!.totalReward += reward.totalReward
        }

        // Compute gradients
        let aggregateGradient = computeAggregateGradient(batch)

        return BatchSummary(
            batchSize: batch.count,
            meanReward: mean,
            variance: variance,
            minReward: rewards.min() ?? 0,
            maxReward: rewards.max() ?? 0,
            perceptualMean: perceptualMean,
            userMean: userMean,
            compressionMean: compressionMean,
            contentBreakdown: contentBreakdown,
            gradient: aggregateGradient,
            timestamp: Date()
        )
    }

    /// Compute aggregate gradient from batch of rewards.
    private func computeAggregateGradient(_ batch: [HybridRewardSignal]) -> AggregateGradient {
        guard !batch.isEmpty else {
            return AggregateGradient.zero
        }

        // Compute individual gradients
        let gradients = batch.map { RewardGradient(reward: $0) }

        // Average alpha gradients
        var alphaGradient = [Float](repeating: 0, count: 9)
        for grad in gradients {
            for i in 0..<9 {
                alphaGradient[i] += grad.alphaGradient[i]
            }
        }
        alphaGradient = alphaGradient.map { $0 / Float(batch.count) }

        // Average other gradients
        let tempGradient = gradients.map { $0.temperatureGradient }.reduce(0, +) / Float(batch.count)
        let blackThreshGradient = gradients.map { $0.blackThresholdGradient }.reduce(0, +) / Float(batch.count)
        let whiteThreshGradient = gradients.map { $0.whiteThresholdGradient }.reduce(0, +) / Float(batch.count)

        return AggregateGradient(
            alphaGradient: alphaGradient,
            temperatureGradient: tempGradient,
            blackThresholdGradient: blackThreshGradient,
            whiteThresholdGradient: whiteThreshGradient,
            batchSize: batch.count
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Persistence
    // ═══════════════════════════════════════════════════════════════════════════

    /// URL for pending batch file.
    private var pendingBatchURL: URL {
        storageDirectory.appendingPathComponent("pending_batch.json")
    }

    /// Persist pending batch to disk.
    private func persistPendingBatch() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(currentBatch)
            try data.write(to: pendingBatchURL)
        } catch {
            print("⚠️ Failed to persist pending batch: \(error)")
        }
    }

    /// Load pending batch from disk.
    private func loadPendingBatch() {
        guard FileManager.default.fileExists(atPath: pendingBatchURL.path) else { return }

        do {
            let data = try Data(contentsOf: pendingBatchURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            currentBatch = try decoder.decode([HybridRewardSignal].self, from: data)
            print("📥 Loaded \(currentBatch.count) pending rewards from disk")
        } catch {
            print("⚠️ Failed to load pending batch: \(error)")
        }
    }

    /// Archive completed batch for analytics.
    private func archiveBatch(_ batch: [HybridRewardSignal], summary: BatchSummary) {
        let archiveDir = storageDirectory.appendingPathComponent("archive")
        try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let filename = "batch_\(ISO8601DateFormatter().string(from: Date())).json"
        let archiveURL = archiveDir.appendingPathComponent(filename)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let archive = BatchArchive(rewards: batch, summary: summary)
            let data = try encoder.encode(archive)
            try data.write(to: archiveURL)
        } catch {
            print("⚠️ Failed to archive batch: \(error)")
        }
    }
}

// MARK: - Supporting Types

/// Summary statistics for a batch of rewards.
@available(iOS 15.0, macOS 12.0, *)
public struct BatchSummary: Codable, Sendable {
    /// Number of rewards in batch.
    public let batchSize: Int

    /// Mean total reward.
    public let meanReward: Float

    /// Variance of rewards.
    public let variance: Float

    /// Minimum reward in batch.
    public let minReward: Float

    /// Maximum reward in batch.
    public let maxReward: Float

    /// Mean perceptual component.
    public let perceptualMean: Float

    /// Mean user feedback component.
    public let userMean: Float

    /// Mean compression component.
    public let compressionMean: Float

    /// Statistics per content type.
    public let contentBreakdown: [String: ContentTypeStats]

    /// Aggregate gradient for gene update.
    public let gradient: AggregateGradient

    /// When summary was computed.
    public let timestamp: Date

    /// Empty summary.
    public static let empty = BatchSummary(
        batchSize: 0,
        meanReward: 0,
        variance: 0,
        minReward: 0,
        maxReward: 0,
        perceptualMean: 0,
        userMean: 0,
        compressionMean: 0,
        contentBreakdown: [:],
        gradient: .zero,
        timestamp: Date()
    )

    /// Standard deviation of rewards.
    public var standardDeviation: Float {
        sqrt(variance)
    }

    /// Whether batch is stable (low variance).
    public var isStable: Bool {
        standardDeviation < 0.15
    }
}

/// Statistics for a single content type.
@available(iOS 15.0, macOS 12.0, *)
public struct ContentTypeStats: Codable, Sendable {
    public var count: Int
    public var totalReward: Float

    public var averageReward: Float {
        count > 0 ? totalReward / Float(count) : 0
    }
}

/// Aggregate gradient from a batch.
@available(iOS 15.0, macOS 12.0, *)
public struct AggregateGradient: Codable, Sendable {
    /// Alpha gradient per time slice.
    public let alphaGradient: [Float]

    /// Temperature gradient.
    public let temperatureGradient: Float

    /// Black threshold gradient.
    public let blackThresholdGradient: Float

    /// White threshold gradient.
    public let whiteThresholdGradient: Float

    /// Batch size used for averaging.
    public let batchSize: Int

    /// Zero gradient (no update).
    public static let zero = AggregateGradient(
        alphaGradient: [Float](repeating: 0, count: 9),
        temperatureGradient: 0,
        blackThresholdGradient: 0,
        whiteThresholdGradient: 0,
        batchSize: 0
    )

    /// Magnitude of gradient (L2 norm).
    public var magnitude: Float {
        let alphaSum = alphaGradient.map { $0 * $0 }.reduce(0, +)
        return sqrt(alphaSum + temperatureGradient * temperatureGradient +
                   blackThresholdGradient * blackThresholdGradient +
                   whiteThresholdGradient * whiteThresholdGradient)
    }
}

/// Archive structure for persisting completed batches.
@available(iOS 15.0, macOS 12.0, *)
private struct BatchArchive: Codable {
    let rewards: [HybridRewardSignal]
    let summary: BatchSummary
}

// MARK: - Description

@available(iOS 15.0, macOS 12.0, *)
extension BatchSummary: CustomStringConvertible {
    public var description: String {
        """
        BatchSummary (\(batchSize) rewards):
          Mean Reward: \(String(format: "%.3f", meanReward)) ± \(String(format: "%.3f", standardDeviation))
          Range: [\(String(format: "%.3f", minReward)), \(String(format: "%.3f", maxReward))]
          Components:
            Perceptual: \(String(format: "%.3f", perceptualMean))
            User: \(String(format: "%.3f", userMean))
            Compression: \(String(format: "%.3f", compressionMean))
          Gradient Magnitude: \(String(format: "%.4f", gradient.magnitude))
          Stable: \(isStable ? "yes" : "no")
        """
    }
}
