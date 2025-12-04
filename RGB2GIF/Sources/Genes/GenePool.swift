//
//  GenePool.swift
//  RGB2GIF
//
//  ============================================================================
//  GENE POOL: Content-Specialized Gene Management
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Manages a collection of specialized attention genes, one for each content
//  type plus a general-purpose fallback. The pool enables:
//
//  1. CONTENT-BASED SELECTION
//     Automatically selects the best gene for detected content type
//
//  2. GENE BLENDING
//     For hybrid content, blends top-2 matching genes
//
//  3. EVOLUTION TRACKING
//     Tracks lineage, fitness, and specialization over time
//
//  4. PERSISTENCE
//     Saves/loads genes to disk for continuity across sessions
//
//  ARCHITECTURE
//  ────────────
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │                        GENE POOL (9 genes)                              │
//  ├─────────────────────────────────────────────────────────────────────────┤
//  │                                                                         │
//  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
//  │  │  nature  │  │ portrait │  │  action  │  │  urban   │               │
//  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘               │
//  │                                                                         │
//  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
//  │  │ abstract │  │ lowLight │  │   text   │  │animation │               │
//  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘               │
//  │                                                                         │
//  │                      ┌──────────────────┐                              │
//  │                      │     general      │  ← fallback                 │
//  │                      └──────────────────┘                              │
//  │                                                                         │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  ============================================================================

import Foundation

// MARK: - Gene Pool

/// Manages a collection of content-specialized attention genes.
@available(iOS 15.0, macOS 12.0, *)
public actor GenePool {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ═══════════════════════════════════════════════════════════════════════════

    /// Specialized genes indexed by content type.
    private var specializedGenes: [AttentionGene.ContentType: AttentionGene]

    /// General-purpose fallback gene.
    private var generalGene: AttentionGene

    /// User's currently active gene (may be custom).
    private var activeGene: AttentionGene?

    /// Directory for gene persistence.
    private let storageDirectory: URL

    /// Configuration for the pool.
    public let config: Config

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for gene pool behavior.
    public struct Config: Codable, Sendable {
        /// Minimum confidence to use specialized gene (otherwise blend).
        public var specializationThreshold: Float = 0.6

        /// Weight for top gene in blending (1 - this = second gene weight).
        public var blendingWeight: Float = 0.7

        /// Enable automatic gene selection based on content type.
        public var autoSelectEnabled: Bool = true

        /// Number of generations to keep in history.
        public var maxHistoryGenerations: Int = 10

        /// LoRA rank for new genes.
        public var loraRank: Int = 4

        /// Initialize with defaults.
        public init() {}
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize gene pool with optional storage directory.
    public init(storageDirectory: URL? = nil, config: Config = Config()) {
        self.config = config

        // Set up storage directory
        if let dir = storageDirectory {
            self.storageDirectory = dir
        } else {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.storageDirectory = documentsDir.appendingPathComponent("RGB2GIF/Genes", isDirectory: true)
        }

        // Initialize with empty dictionaries - will be populated by load() or createDefaults()
        self.specializedGenes = [:]
        self.generalGene = AttentionGene(name: "General", loraRank: config.loraRank)
        self.activeGene = nil
    }

    /// Load genes from storage or create defaults.
    public func initialize() async throws {
        // Create storage directory if needed
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        // Try to load existing genes
        do {
            try await loadFromStorage()
        } catch {
            // Create default genes if none exist
            createDefaultGenes()
            try await saveToStorage()
        }
    }

    /// Create default specialized genes for all content types.
    private func createDefaultGenes() {
        for contentType in AttentionGene.ContentType.allCases {
            var gene = AttentionGene(
                name: "\(contentType.rawValue.capitalized) Specialist",
                loraRank: config.loraRank
            )
            gene.specialization = contentType

            // Apply content-type-specific initial parameters
            applySpecializationDefaults(to: &gene, for: contentType)

            specializedGenes[contentType] = gene
        }

        // General gene is already initialized
        generalGene.name = "General Purpose"
    }

    /// Apply sensible defaults based on content type.
    private func applySpecializationDefaults(to gene: inout AttentionGene, for type: AttentionGene.ContentType) {
        switch type {
        case .nature:
            // Nature: favor spatial coherence, moderate temperature
            gene.mergeAlpha = [0.6, 0.55, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 0.6]
            gene.temperature = 0.9
            gene.blackThreshold = 0.65
            gene.whiteThreshold = 0.35

        case .portrait:
            // Portrait: balanced spatial/temporal, smooth transitions
            gene.mergeAlpha = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
            gene.temperature = 1.1
            gene.blackThreshold = 0.6
            gene.whiteThreshold = 0.4

        case .action:
            // Action: favor temporal dynamics, lower temperature
            gene.mergeAlpha = [0.4, 0.35, 0.35, 0.4, 0.4, 0.4, 0.35, 0.35, 0.4]
            gene.temperature = 0.7
            gene.blackThreshold = 0.7
            gene.whiteThreshold = 0.3

        case .urban:
            // Urban: strong edges, balanced weights
            gene.mergeAlpha = [0.55, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55]
            gene.temperature = 0.85
            gene.blackThreshold = 0.7
            gene.whiteThreshold = 0.3

        case .abstract:
            // Abstract: high temperature for diversity
            gene.mergeAlpha = [0.5, 0.45, 0.5, 0.55, 0.5, 0.55, 0.5, 0.45, 0.5]
            gene.temperature = 1.3
            gene.blackThreshold = 0.6
            gene.whiteThreshold = 0.4

        case .lowLight:
            // Low light: favor brightness preservation
            gene.mergeAlpha = [0.55, 0.55, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 0.55]
            gene.temperature = 1.0
            gene.blackThreshold = 0.5
            gene.whiteThreshold = 0.5

        case .text:
            // Text: sharp edges, favor spatial
            gene.mergeAlpha = [0.7, 0.65, 0.6, 0.6, 0.6, 0.6, 0.6, 0.65, 0.7]
            gene.temperature = 0.6
            gene.blackThreshold = 0.75
            gene.whiteThreshold = 0.25

        case .animation:
            // Animation: flat colors, moderate dynamics
            gene.mergeAlpha = [0.5, 0.45, 0.45, 0.5, 0.5, 0.5, 0.45, 0.45, 0.5]
            gene.temperature = 0.8
            gene.blackThreshold = 0.65
            gene.whiteThreshold = 0.35
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gene Selection
    // ═══════════════════════════════════════════════════════════════════════════

    /// Select the best gene for a content type.
    ///
    /// - Parameters:
    ///   - contentType: Detected content type
    ///   - confidence: Classification confidence (0-1)
    /// - Returns: Selected gene, potentially blended
    public func selectGene(
        for contentType: AttentionGene.ContentType,
        confidence: Float
    ) -> AttentionGene {
        // If user has active custom gene, use it
        if let active = activeGene {
            return active
        }

        // If confidence is high enough, use specialized gene
        if confidence >= config.specializationThreshold {
            return specializedGenes[contentType] ?? generalGene
        }

        // Otherwise, use general gene
        return generalGene
    }

    /// Select and optionally blend genes based on classification scores.
    ///
    /// - Parameter scores: Content type scores from classifier (should sum to 1)
    /// - Returns: Selected or blended gene
    public func selectGene(fromScores scores: [AttentionGene.ContentType: Float]) -> AttentionGene {
        // If user has active custom gene, use it
        if let active = activeGene {
            return active
        }

        // Sort by score
        let sorted = scores.sorted { $0.value > $1.value }

        guard let (topType, topScore) = sorted.first else {
            return generalGene
        }

        // If top score is dominant, use specialized gene
        if topScore >= config.specializationThreshold {
            return specializedGenes[topType] ?? generalGene
        }

        // Check if we should blend
        if sorted.count >= 2 {
            let (secondType, secondScore) = sorted[1]

            // If both scores are significant, blend
            if secondScore > 0.2 {
                return blendGenes(
                    primary: specializedGenes[topType] ?? generalGene,
                    secondary: specializedGenes[secondType] ?? generalGene,
                    weight: config.blendingWeight
                )
            }
        }

        return specializedGenes[topType] ?? generalGene
    }

    /// Blend two genes with weighted interpolation.
    private func blendGenes(primary: AttentionGene, secondary: AttentionGene, weight: Float) -> AttentionGene {
        return GeneMerger.merge(
            parent1: primary,
            parent2: secondary,
            strategy: .taskArithmetic(tau: 1.0 - weight),
            offspringName: "Blended: \(primary.name) + \(secondary.name)"
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gene Access
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get specialized gene for a content type.
    public func getGene(for contentType: AttentionGene.ContentType) -> AttentionGene? {
        specializedGenes[contentType]
    }

    /// Get the general-purpose gene.
    public func getGeneralGene() -> AttentionGene {
        generalGene
    }

    /// Get all specialized genes.
    public func getAllSpecializedGenes() -> [AttentionGene.ContentType: AttentionGene] {
        specializedGenes
    }

    /// Get currently active gene (if set).
    public func getActiveGene() -> AttentionGene? {
        activeGene
    }

    /// Set custom active gene (overrides automatic selection).
    public func setActiveGene(_ gene: AttentionGene?) {
        activeGene = gene
    }

    /// Get total number of genes in the pool.
    public var geneCount: Int {
        specializedGenes.count + 1  // +1 for general
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gene Updates
    // ═══════════════════════════════════════════════════════════════════════════

    /// Update a specialized gene after training.
    ///
    /// - Parameters:
    ///   - contentType: Content type of the gene to update
    ///   - updatedGene: New gene with updated weights
    public func updateGene(for contentType: AttentionGene.ContentType, with updatedGene: AttentionGene) {
        var gene = updatedGene
        gene.specialization = contentType
        specializedGenes[contentType] = gene
    }

    /// Update the general gene.
    public func updateGeneralGene(with updatedGene: AttentionGene) {
        var gene = updatedGene
        gene.specialization = nil
        generalGene = gene
    }

    /// Update gene quality score based on reward signal.
    public func updateQualityScore(
        for contentType: AttentionGene.ContentType?,
        reward: Float,
        learningRate: Float = 0.1
    ) {
        if let type = contentType, var gene = specializedGenes[type] {
            // Exponential moving average
            gene.qualityScore = gene.qualityScore * (1 - learningRate) + reward * learningRate
            specializedGenes[type] = gene
        } else {
            // Update general gene
            generalGene.qualityScore = generalGene.qualityScore * (1 - learningRate) + reward * learningRate
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gene Evolution
    // ═══════════════════════════════════════════════════════════════════════════

    /// Evolve a gene by merging with another high-performing gene.
    ///
    /// - Parameters:
    ///   - contentType: Content type to evolve
    ///   - strategy: Merge strategy to use
    /// - Returns: Evolved gene
    public func evolveGene(
        for contentType: AttentionGene.ContentType,
        strategy: GeneMergeStrategy = .geneticCrossover(crossoverRate: 0.3, mutationRate: 0.1)
    ) -> AttentionGene? {
        guard let baseGene = specializedGenes[contentType] else { return nil }

        // Find best performing gene to cross with
        let candidates = specializedGenes.values.filter { $0.id != baseGene.id }
        guard let bestCandidate = candidates.max(by: { $0.fitness < $1.fitness }) else {
            return nil
        }

        // Create offspring
        let offspring = GeneMerger.merge(
            parent1: baseGene,
            parent2: bestCandidate,
            strategy: strategy,
            offspringName: "\(contentType.rawValue.capitalized) Gen\(baseGene.generation + 1)"
        )

        return offspring
    }

    /// Get the fittest gene across all content types.
    public func getFittestGene() -> AttentionGene {
        let allGenes = Array(specializedGenes.values) + [generalGene]
        return allGenes.max(by: { $0.fitness < $1.fitness }) ?? generalGene
    }

    /// Get pool statistics.
    public func getStatistics() -> PoolStatistics {
        let allGenes = Array(specializedGenes.values) + [generalGene]

        let avgFitness = allGenes.map { $0.fitness }.reduce(0, +) / Float(allGenes.count)
        let avgQuality = allGenes.map { $0.qualityScore }.reduce(0, +) / Float(allGenes.count)
        let totalAdoptions = allGenes.map { $0.adoptionCount }.reduce(0, +)
        let avgGeneration = Float(allGenes.map { $0.generation }.reduce(0, +)) / Float(allGenes.count)

        return PoolStatistics(
            geneCount: allGenes.count,
            averageFitness: avgFitness,
            averageQuality: avgQuality,
            totalAdoptions: totalAdoptions,
            averageGeneration: avgGeneration,
            fittestGeneID: getFittestGene().id
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Persistence
    // ═══════════════════════════════════════════════════════════════════════════

    /// Save all genes to storage.
    public func saveToStorage() async throws {
        // Save specialized genes
        for (contentType, gene) in specializedGenes {
            let filename = "specialized_\(contentType.rawValue).json"
            let url = storageDirectory.appendingPathComponent(filename)
            try gene.save(to: url)
        }

        // Save general gene
        let generalURL = storageDirectory.appendingPathComponent("general.json")
        try generalGene.save(to: generalURL)

        // Save active gene if set
        if let active = activeGene {
            let activeURL = storageDirectory.appendingPathComponent("active.json")
            try active.save(to: activeURL)
        }
    }

    /// Load all genes from storage.
    private func loadFromStorage() async throws {
        // Load specialized genes
        for contentType in AttentionGene.ContentType.allCases {
            let filename = "specialized_\(contentType.rawValue).json"
            let url = storageDirectory.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: url.path) {
                let gene = try AttentionGene.load(from: url)
                specializedGenes[contentType] = gene
            }
        }

        // Load general gene
        let generalURL = storageDirectory.appendingPathComponent("general.json")
        if FileManager.default.fileExists(atPath: generalURL.path) {
            generalGene = try AttentionGene.load(from: generalURL)
        }

        // Load active gene if exists
        let activeURL = storageDirectory.appendingPathComponent("active.json")
        if FileManager.default.fileExists(atPath: activeURL.path) {
            activeGene = try AttentionGene.load(from: activeURL)
        }

        // Validate we have all genes
        guard specializedGenes.count == AttentionGene.ContentType.allCases.count else {
            throw GenePoolError.incompletePool
        }
    }

    /// Export a gene for sharing.
    public func exportGene(_ gene: AttentionGene) throws -> Data {
        try gene.toData()
    }

    /// Import a shared gene.
    public func importGene(from data: Data) throws -> AttentionGene {
        try AttentionGene.fromData(data)
    }
}

// MARK: - Supporting Types

/// Statistics about the gene pool.
public struct PoolStatistics: Codable, Sendable {
    public let geneCount: Int
    public let averageFitness: Float
    public let averageQuality: Float
    public let totalAdoptions: Int
    public let averageGeneration: Float
    public let fittestGeneID: UUID
}

/// Errors from gene pool operations.
public enum GenePoolError: Error, LocalizedError {
    case geneNotFound(AttentionGene.ContentType)
    case incompletePool
    case invalidGeneData
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .geneNotFound(let type):
            return "Gene not found for content type: \(type.rawValue)"
        case .incompletePool:
            return "Gene pool is incomplete - missing one or more specialized genes"
        case .invalidGeneData:
            return "Invalid gene data format"
        case .storageError(let message):
            return "Storage error: \(message)"
        }
    }
}

// MARK: - Gene Pool Description

@available(iOS 15.0, macOS 12.0, *)
extension GenePool {
    /// Get a text description of the pool state.
    public func descriptionText() async -> String {
        let stats = getStatistics()
        var lines = [String]()

        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║                     GENE POOL STATUS                              ║")
        lines.append("╚═══════════════════════════════════════════════════════════════════╝")
        lines.append("")
        lines.append("  Genes: \(stats.geneCount)")
        lines.append("  Avg Fitness: \(String(format: "%.3f", stats.averageFitness))")
        lines.append("  Avg Quality: \(String(format: "%.3f", stats.averageQuality))")
        lines.append("  Avg Generation: \(String(format: "%.1f", stats.averageGeneration))")
        lines.append("")
        lines.append("  Specialized Genes:")

        for (type, gene) in specializedGenes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let marker = gene.id == stats.fittestGeneID ? "★" : "•"
            lines.append("    \(marker) \(type.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) " +
                        "fit=\(String(format: "%.2f", gene.fitness)) " +
                        "q=\(String(format: "%.2f", gene.qualityScore)) " +
                        "gen=\(gene.generation)")
        }

        lines.append("")
        lines.append("    • general       " +
                    "fit=\(String(format: "%.2f", generalGene.fitness)) " +
                    "q=\(String(format: "%.2f", generalGene.qualityScore)) " +
                    "gen=\(generalGene.generation)")

        if let active = activeGene {
            lines.append("")
            lines.append("  Active Override: \(active.name)")
        }

        return lines.joined(separator: "\n")
    }
}
