//
//  KataGoInference.swift
//  RGB2GIF
//
//  ============================================================================
//  CORE ML WRAPPER FOR KATAGO 9×9 NEURAL NETWORK
//  ============================================================================
//
//  PURPOSE
//  ───────
//  This actor wraps a CoreML-compiled KataGo neural network for on-device
//  inference. The network provides policy and value predictions that serve
//  as the Q (Query) and K (Key) weights in our attention mechanism.
//
//  MODEL ARCHITECTURE (b18c384nbt)
//  ───────────────────────────────
//  - 18 residual blocks, 384 channels
//  - Specialized for 9×9 boards (KataGo v1.13.2-kata9x9)
//  - Binary spatial features: 22 planes
//  - Global features: 19 values
//
//  INPUTS
//  ──────
//  • input_spatial: MLMultiArray (1, 22, 9, 9)
//      - Plane 0:  Mask (1.0 for valid positions)
//      - Plane 1:  Own stones (Black or to-play)
//      - Plane 2:  Opponent stones
//      - Planes 3-21: History, liberties, ko, etc.
//
//  • input_global: MLMultiArray (1, 19)
//      - Komi, game phase, pass history, etc.
//
//  OUTPUTS
//  ───────
//  • policy: 82 logits (81 intersections + pass)
//      → After softmax: move probability distribution
//      → Used as Q (spatial) or K (temporal) attention weights
//
//  • value: 3 logits (win, loss, draw)
//      → Provides overall position evaluation
//      → Can modulate attention intensity
//
//  • ownership: 9×9 per-point territory prediction
//      → Alternative weight source (more granular)
//
//  USAGE IN RGB2GIF
//  ────────────────
//  Spatial Player (Japanese rules):
//      policy[0..80] → Query weights for which TILES need attention
//
//  Temporal Player (Tromp-Taylor rules):
//      policy[0..80] → Key weights for which FRAMES need attention
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Policy Value Output

/// Output from KataGo neural network inference.
///
/// Contains the three main predictions:
/// - `policy`: Move probability distribution (81 board + 1 pass)
/// - `value`: Win/loss/draw prediction
/// - `ownership`: Per-intersection territory ownership
@available(iOS 15.0, macOS 12.0, *)
public struct PolicyValueOutput: Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Policy Head
    // ═══════════════════════════════════════════════════════════════════════════

    /// Raw policy logits before softmax.
    /// Shape: 82 values (81 intersections + 1 pass move)
    /// Index mapping: i = row * 9 + col, with 81 = pass
    public let policyLogits: [Float]

    /// Policy after softmax normalization (probabilities sum to 1.0).
    public var policyProbabilities: [Float] {
        softmax(policyLogits)
    }

    /// Policy for just the 81 board intersections (excluding pass).
    /// These are the weights we use for Q-K-V attention.
    public var boardPolicy: [Float] {
        Array(policyProbabilities.prefix(81))
    }

    /// Reshape policy to 9×9 grid for spatial interpretation.
    public var policyGrid: [[Float]] {
        let probs = boardPolicy
        return (0..<9).map { row in
            (0..<9).map { col in
                probs[row * 9 + col]
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Value Head
    // ═══════════════════════════════════════════════════════════════════════════

    /// Raw value logits: [win, loss, draw]
    public let valueLogits: [Float]

    /// Win probability after softmax
    public var winProbability: Float {
        let probs = softmax(valueLogits)
        return probs[0]
    }

    /// Loss probability after softmax
    public var lossProbability: Float {
        let probs = softmax(valueLogits)
        return probs[1]
    }

    /// Draw probability after softmax
    public var drawProbability: Float {
        let probs = softmax(valueLogits)
        return probs[2]
    }

    /// Expected score from the current player's perspective.
    /// Range: -1 (certain loss) to +1 (certain win)
    public var expectedValue: Float {
        winProbability - lossProbability
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Ownership Head
    // ═══════════════════════════════════════════════════════════════════════════

    /// Per-intersection ownership prediction.
    /// Values range from -1 (opponent territory) to +1 (own territory).
    /// Shape: 81 values (flattened 9×9 grid)
    public let ownership: [Float]

    /// Reshape ownership to 9×9 grid.
    public var ownershipGrid: [[Float]] {
        (0..<9).map { row in
            (0..<9).map { col in
                ownership[row * 9 + col]
            }
        }
    }

    /// Convert ownership to attention weights.
    /// Maps [-1, +1] ownership to [0, 1] weight.
    /// Black territory → high weight (1.0)
    /// White territory → low weight (0.0)
    public var ownershipAsWeights: [Float] {
        ownership.map { o in (1.0 - o) / 2.0 }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Utilities
    // ═══════════════════════════════════════════════════════════════════════════

    private func softmax(_ logits: [Float]) -> [Float] {
        let maxLogit = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxLogit) }
        let sumExps = exps.reduce(0, +)
        return exps.map { $0 / sumExps }
    }
}

// MARK: - KataGo Inference Actor

/// CoreML wrapper for KataGo 9×9 neural network.
///
/// This actor provides thread-safe, asynchronous inference using either
/// the Spatial model (Japanese rules) or Temporal model (Tromp-Taylor rules).
///
/// ## Example Usage
///
/// ```swift
/// let inference = try await KataGoInference(role: .spatial)
///
/// // Create input from TensorCube729
/// let features = BoardEncoder.encodeSpatialBoard(from: tensor)
///
/// // Run inference
/// let output = try await inference.predict(features)
///
/// // Get 81 policy weights for Q (Query)
/// let queryWeights = output.boardPolicy
/// ```
@available(iOS 15.0, macOS 12.0, *)
public actor KataGoInference {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ═══════════════════════════════════════════════════════════════════════════

    /// The role this model plays in the Q-K-V attention mechanism.
    public enum Role: String, Sendable {
        case spatial    // Japanese rules → Query (Q) provider
        case temporal   // Tromp-Taylor rules → Key (K) provider

        /// The CoreML model name for this role.
        var modelName: String {
            switch self {
            case .spatial:  return "KataGo9x9_Spatial"
            case .temporal: return "KataGo9x9_Temporal"
            }
        }

        /// Human-readable description.
        var description: String {
            switch self {
            case .spatial:
                return "Spatial Player (Japanese rules) - Query provider"
            case .temporal:
                return "Temporal Player (Tromp-Taylor rules) - Key provider"
            }
        }
    }

    /// Errors that can occur during inference.
    public enum InferenceError: Error, LocalizedError {
        case modelNotFound(String)
        case modelLoadFailed(String, Error)
        case predictionFailed(Error)
        case invalidInputShape(expected: String, got: String)
        case outputExtractionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let name):
                return "CoreML model '\(name)' not found in bundle"
            case .modelLoadFailed(let name, let error):
                return "Failed to load CoreML model '\(name)': \(error.localizedDescription)"
            case .predictionFailed(let error):
                return "CoreML prediction failed: \(error.localizedDescription)"
            case .invalidInputShape(let expected, let got):
                return "Invalid input shape: expected \(expected), got \(got)"
            case .outputExtractionFailed(let key):
                return "Failed to extract output '\(key)' from prediction"
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Board size (always 9 for this implementation)
    public static let boardSize: Int = 9

    /// Number of spatial feature planes
    public static let spatialPlanes: Int = 22

    /// Number of global features
    public static let globalFeatures: Int = 19

    /// Total board intersections
    public static let boardIntersections: Int = 81

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ═══════════════════════════════════════════════════════════════════════════

    /// The role this inference engine plays
    public let role: Role

    /// The loaded CoreML model
    private let model: MLModel

    /// Model configuration
    private let configuration: MLModelConfiguration

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// Initialize with a specific role (spatial or temporal).
    ///
    /// - Parameters:
    ///   - role: The attention role (.spatial for Q, .temporal for K)
    ///   - computeUnits: CoreML compute units (default: .all for auto-selection)
    /// - Throws: InferenceError if model cannot be loaded
    public init(
        role: Role,
        computeUnits: MLComputeUnits = .all
    ) async throws {
        self.role = role

        // Configure compute units
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        self.configuration = config

        // Load the model
        guard let modelURL = Bundle.main.url(
            forResource: role.modelName,
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: role.modelName,
            withExtension: "mlpackage"
        ) else {
            throw InferenceError.modelNotFound(role.modelName)
        }

        do {
            self.model = try await MLModel.load(contentsOf: modelURL, configuration: config)
        } catch {
            throw InferenceError.modelLoadFailed(role.modelName, error)
        }
    }

    /// Initialize with a custom model URL.
    ///
    /// - Parameters:
    ///   - modelURL: URL to the .mlmodelc or .mlpackage file
    ///   - role: The attention role for this model
    ///   - computeUnits: CoreML compute units
    public init(
        modelURL: URL,
        role: Role,
        computeUnits: MLComputeUnits = .all
    ) async throws {
        self.role = role

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        self.configuration = config

        do {
            self.model = try await MLModel.load(contentsOf: modelURL, configuration: config)
        } catch {
            throw InferenceError.modelLoadFailed(modelURL.lastPathComponent, error)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Inference
    // ═══════════════════════════════════════════════════════════════════════════

    /// Run inference with pre-encoded features.
    ///
    /// - Parameters:
    ///   - spatial: Spatial features (1, 22, 9, 9)
    ///   - global: Global features (1, 19)
    /// - Returns: PolicyValueOutput containing policy, value, and ownership
    /// - Throws: InferenceError if prediction fails
    public func predict(
        spatial: MLMultiArray,
        global: MLMultiArray
    ) async throws -> PolicyValueOutput {

        // Validate input shapes
        let spatialShape = spatial.shape.map { $0.intValue }
        let expectedSpatial = [1, Self.spatialPlanes, Self.boardSize, Self.boardSize]
        guard spatialShape == expectedSpatial else {
            throw InferenceError.invalidInputShape(
                expected: "\(expectedSpatial)",
                got: "\(spatialShape)"
            )
        }

        let globalShape = global.shape.map { $0.intValue }
        let expectedGlobal = [1, Self.globalFeatures]
        guard globalShape == expectedGlobal else {
            throw InferenceError.invalidInputShape(
                expected: "\(expectedGlobal)",
                got: "\(globalShape)"
            )
        }

        // Create input feature provider
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_spatial": MLFeatureValue(multiArray: spatial),
            "input_global": MLFeatureValue(multiArray: global)
        ])

        // Run prediction
        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: inputFeatures)
        } catch {
            throw InferenceError.predictionFailed(error)
        }

        // Extract outputs
        guard let policyValue = prediction.featureValue(for: "policy"),
              let policyArray = policyValue.multiArrayValue else {
            throw InferenceError.outputExtractionFailed("policy")
        }

        guard let valueValue = prediction.featureValue(for: "value"),
              let valueArray = valueValue.multiArrayValue else {
            throw InferenceError.outputExtractionFailed("value")
        }

        guard let ownershipValue = prediction.featureValue(for: "ownership"),
              let ownershipArray = ownershipValue.multiArrayValue else {
            throw InferenceError.outputExtractionFailed("ownership")
        }

        // Convert to Float arrays
        let policyLogits = extractFloatArray(from: policyArray)
        let valueLogits = extractFloatArray(from: valueArray)
        let ownership = extractFloatArray(from: ownershipArray)

        return PolicyValueOutput(
            policyLogits: policyLogits,
            valueLogits: valueLogits,
            ownership: ownership
        )
    }

    /// Run inference with a simple board representation.
    ///
    /// This is a convenience method that creates default global features.
    ///
    /// - Parameters:
    ///   - spatial: Spatial features (1, 22, 9, 9)
    ///   - komi: Komi value (default: 7.0 for 9x9)
    /// - Returns: PolicyValueOutput
    public func predict(
        spatial: MLMultiArray,
        komi: Float = 7.0
    ) async throws -> PolicyValueOutput {
        let global = try createDefaultGlobalFeatures(komi: komi)
        return try await predict(spatial: spatial, global: global)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Attention Weight Extraction
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get attention weights from the last inference result.
    ///
    /// For Spatial player: Returns 81 Query weights (which tiles matter)
    /// For Temporal player: Returns 81 Key weights (which frames matter)
    ///
    /// - Parameter output: The inference output
    /// - Returns: 81 normalized weights (sum to 1.0)
    public func extractAttentionWeights(from output: PolicyValueOutput) -> [Float] {
        // Use board policy (81 values, excludes pass)
        return output.boardPolicy
    }

    /// Get attention weights using ownership instead of policy.
    ///
    /// Ownership provides a different perspective:
    /// - More stable, represents territorial control
    /// - Black territory → high weight
    /// - White territory → low weight
    ///
    /// - Parameter output: The inference output
    /// - Returns: 81 weights normalized to [0, 1]
    public func extractOwnershipWeights(from output: PolicyValueOutput) -> [Float] {
        return output.ownershipAsWeights
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Methods
    // ═══════════════════════════════════════════════════════════════════════════

    private func extractFloatArray(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        var result = [Float](repeating: 0, count: count)

        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            result[i] = ptr[i]
        }

        return result
    }

    private func createDefaultGlobalFeatures(komi: Float) throws -> MLMultiArray {
        let global = try MLMultiArray(
            shape: [1, NSNumber(value: Self.globalFeatures)],
            dataType: .float32
        )

        // Initialize to zeros
        for i in 0..<Self.globalFeatures {
            global[[0, NSNumber(value: i)]] = NSNumber(value: Float(0))
        }

        // Set komi (normalized to ~0.5 for standard komi)
        global[[0, 0]] = NSNumber(value: komi / 14.0)  // Normalize to ~0.5

        return global
    }
}

// MARK: - Debug Extensions

@available(iOS 15.0, macOS 12.0, *)
extension PolicyValueOutput: CustomStringConvertible {

    public var description: String {
        var lines = [String]()
        lines.append("PolicyValueOutput:")
        lines.append("  Win: \(String(format: "%.2f%%", winProbability * 100))")
        lines.append("  Loss: \(String(format: "%.2f%%", lossProbability * 100))")
        lines.append("  Draw: \(String(format: "%.2f%%", drawProbability * 100))")
        lines.append("  Expected: \(String(format: "%.3f", expectedValue))")
        lines.append("  Policy (top 5 moves):")

        let probs = boardPolicy
        let indexed = probs.enumerated().sorted { $0.element > $1.element }
        for i in 0..<min(5, indexed.count) {
            let (idx, prob) = indexed[i]
            let row = idx / 9
            let col = idx % 9
            let coord = "\(Character(UnicodeScalar(65 + col)!))\(9 - row)"
            lines.append("    \(coord): \(String(format: "%.2f%%", prob * 100))")
        }

        return lines.joined(separator: "\n")
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension KataGoInference {

    /// Print model information for debugging.
    public func printModelInfo() {
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  KataGoInference: \(role.description)")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Model: \(role.modelName)")
        print("║  Board Size: \(Self.boardSize)×\(Self.boardSize)")
        print("║  Spatial Features: \(Self.spatialPlanes) planes")
        print("║  Global Features: \(Self.globalFeatures) values")
        print("║  Compute Units: \(configuration.computeUnits)")
        print("╚═══════════════════════════════════════════════════════════════════╝")
    }
}
