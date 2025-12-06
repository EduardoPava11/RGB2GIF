//
//  MVP1State.swift
//  RGB2GIF
//
//  ============================================================================
//  MVP1 STATE: Observable state for MVP1 tools
//  ============================================================================
//
//  Holds:
//  - TensorCube729 (the 9×9×9 color tensor)
//  - SliceImportanceAnalyzer.Config (user-configurable weights)
//  - ImportanceResult (analysis output)
//  - Override storage (user overrides)
//
//  ============================================================================

import Foundation
import SwiftUI
import Combine

/// Observable state for MVP1 interactive tools
@available(iOS 26.0, *)
@MainActor
public final class MVP1State: ObservableObject {

    // MARK: - Tensor Data

    /// The 9×9×9 color tensor from captured frames
    @Published public var tensor: TensorCube729?

    /// Raw RGB frames for reference (81 frames × 81×81 pixels)
    @Published public var rgbFrames: [Data] = []

    // MARK: - Analysis Configuration

    /// SliceImportanceAnalyzer configuration (user-adjustable weights)
    @Published public var importanceConfig: SliceImportanceAnalyzer.Config {
        didSet {
            // Re-run analysis when config changes
            runAnalysis()
        }
    }

    /// Kernel sigma for spatial Gaussian (TensorCube729)
    @Published public var spatialSigma: Float = 2.5 {
        didSet {
            rebuildTensor()
        }
    }

    /// Kernel sigma for temporal Gaussian (TensorCube729)
    @Published public var temporalSigma: Float = 2.0 {
        didSet {
            rebuildTensor()
        }
    }

    // MARK: - Analysis Results

    /// Latest importance analysis result
    @Published public private(set) var importanceResult: SliceImportanceAnalyzer.ImportanceResult?

    /// Whether analysis is currently running
    @Published public private(set) var isAnalyzing: Bool = false

    // MARK: - Override Storage

    /// Cells with user-overridden RGB values
    @Published public var rgbOverrides: [TensorPosition: (r: UInt8, g: UInt8, b: UInt8)] = [:]

    /// Cells with user-overridden weights
    @Published public var weightOverrides: [TensorPosition: Float] = [:]

    /// Cells that are locked (won't be affected by analysis changes)
    @Published public var lockedCells: Set<TensorPosition> = []

    // MARK: - View State

    /// Currently selected slice type for viewer
    @Published public var selectedSliceType: SliceType = .xy

    /// Currently selected slice index (0-8)
    @Published public var selectedSliceIndex: Int = 4

    /// Currently selected cell for override editing
    @Published public var selectedCell: TensorPosition?

    // MARK: - Initialization

    public init() {
        self.importanceConfig = SliceImportanceAnalyzer.Config()
    }

    /// Initialize with captured frames
    public init(rgbFrames: [Data]) throws {
        self.importanceConfig = SliceImportanceAnalyzer.Config()
        self.rgbFrames = rgbFrames
        self.tensor = try TensorCube729(rgbFrames: rgbFrames)
        runAnalysis()
    }

    // MARK: - Analysis

    /// Run importance analysis with current config
    public func runAnalysis() {
        guard let tensor = tensor else { return }

        isAnalyzing = true

        // Run analysis (fast, ~5ms)
        let analyzer = SliceImportanceAnalyzer(config: importanceConfig)
        let result = analyzer.analyze(tensor: tensor)

        importanceResult = result
        isAnalyzing = false
    }

    /// Rebuild tensor with current sigma values
    private func rebuildTensor() {
        guard !rgbFrames.isEmpty else { return }

        // TODO: TensorCube729 needs to be modified to accept configurable sigmas
        // For now, this is a placeholder that will be implemented when we modify TensorCube729
    }

    // MARK: - Centroids

    /// Get centroid colors from tensor, applying any overrides
    public func getCentroids() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        guard let tensor = tensor else { return [] }

        var centroids = tensor.centroidColors()

        // Apply RGB overrides
        for (position, rgb) in rgbOverrides {
            let index = position.flatIndex
            if index < centroids.count {
                centroids[index] = rgb
            }
        }

        return centroids
    }

    /// Get importance weights for all 729 cells
    public func getWeights() -> [Float] {
        guard let result = importanceResult else {
            return [Float](repeating: 1.0 / 729.0, count: 729)
        }

        var weights = [Float](repeating: 0, count: 729)

        // Combine spatial and temporal importance
        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let position = TensorPosition(t: t, y: y, x: x)
                    let index = position.flatIndex

                    // Check for user override first
                    if let override = weightOverrides[position] {
                        weights[index] = override
                    } else {
                        // Combine spatial and temporal importance
                        let spatialWeight = result.spatialImportance[t]
                        let temporalWeight = result.temporalImportance[x]
                        weights[index] = (spatialWeight + temporalWeight) / 2.0
                    }
                }
            }
        }

        return weights
    }

    // MARK: - Presets

    /// Apply balanced preset (default weights)
    public func applyBalancedPreset() {
        importanceConfig = SliceImportanceAnalyzer.Config()
    }

    /// Apply edge-focus preset (emphasizes spatial detail)
    public func applyEdgeFocusPreset() {
        importanceConfig.colorVarianceWeight = 0.3
        importanceConfig.edgeDensityWeight = 0.7
        importanceConfig.motionWeight = 0.4
        importanceConfig.frameDeltaWeight = 0.6
    }

    /// Apply motion-focus preset (emphasizes temporal smoothness)
    public func applyMotionFocusPreset() {
        importanceConfig.colorVarianceWeight = 0.7
        importanceConfig.edgeDensityWeight = 0.3
        importanceConfig.motionWeight = 0.8
        importanceConfig.frameDeltaWeight = 0.2
    }

    /// Apply uniform preset (all weights equal)
    public func applyUniformPreset() {
        importanceConfig.colorVarianceWeight = 0.5
        importanceConfig.edgeDensityWeight = 0.5
        importanceConfig.motionWeight = 0.5
        importanceConfig.frameDeltaWeight = 0.5
        importanceConfig.temperature = 10.0  // High temp = more uniform
    }
}

// MARK: - Supporting Types

/// Position in the 9×9×9 tensor
@available(iOS 26.0, *)
public struct TensorPosition: Hashable, Sendable {
    public let t: Int  // Temporal index (0-8)
    public let y: Int  // Spatial Y (0-8)
    public let x: Int  // Spatial X (0-8)

    public init(t: Int, y: Int, x: Int) {
        precondition(t >= 0 && t < 9, "MVP1: t must be 0-8")
        precondition(y >= 0 && y < 9, "MVP1: y must be 0-8")
        precondition(x >= 0 && x < 9, "MVP1: x must be 0-8")
        self.t = t
        self.y = y
        self.x = x
    }

    /// Convert to flat index (0-728)
    public var flatIndex: Int {
        t * 81 + y * 9 + x
    }

    /// Create from flat index
    public static func from(flatIndex: Int) -> TensorPosition {
        let t = flatIndex / 81
        let remainder = flatIndex % 81
        let y = remainder / 9
        let x = remainder % 9
        return TensorPosition(t: t, y: y, x: x)
    }
}

/// Slice type for viewing the tensor
@available(iOS 26.0, *)
public enum SliceType: String, CaseIterable, Sendable {
    case xy = "X/Y (Spatial)"
    case xt = "X/T (Horizontal Motion)"
    case yt = "Y/T (Vertical Motion)"

    public var description: String {
        switch self {
        case .xy: return "View spatial distribution at a time slice"
        case .xt: return "View horizontal changes over time"
        case .yt: return "View vertical changes over time"
        }
    }

    /// Which axis is fixed for this slice type
    public var fixedAxis: String {
        switch self {
        case .xy: return "t"
        case .xt: return "y"
        case .yt: return "x"
        }
    }
}
