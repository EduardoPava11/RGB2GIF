//
//  PaletteStrategyConfig.swift
//  RGB2GIF
//
//  Palette strategy configuration with slider-based control
//  CONSTRAINT: Always 256 colors per palette (maximum fidelity)
//  Slider controls strategy (global/hybrid/per-frame), NOT color count
//

import Foundation

@available(iOS 26.0, *)
public struct PaletteStrategyConfig {

    // MARK: - Properties

    /// Slider position (0.0 = global, 1.0 = per-frame)
    public let position: Double  // 0.0 to 1.0

    /// Total frame count (80 or 128)
    public let frameCount: Int

    // MARK: - Constants

    /// INVARIANT: Always use 256-color palettes for maximum quality
    public static let maxColors = 256

    /// INVARIANT: Palette exponent (2^8 = 256)
    public static let paletteExp: UInt8 = 7

    // MARK: - Initialization

    public init(position: Double, frameCount: Int) {
        self.position = max(0.0, min(1.0, position))  // Clamp to 0-1
        self.frameCount = frameCount
    }

    // MARK: - Computed Properties

    /// Number of frames allowed to have their own palette (hybrid mode)
    public var maxOverrides: Int {
        return Int(round(position * Double(frameCount)))
    }

    /// Error threshold for triggering per-frame palette
    /// Lower position → higher threshold (fewer overrides)
    /// Higher position → lower threshold (more overrides)
    public var errorThreshold: Double {
        let minThreshold = 10.0  // Very strict - almost any deviation triggers override
        let maxThreshold = 60.0  // Very loose - only huge deviations trigger
        return maxThreshold - (position * (maxThreshold - minThreshold))
    }

    /// Palette strategy based on slider position (internal for pipeline use)
    internal var strategy: CaptureToGIP2Pipeline.PaletteStrategy {
        if position == 0.0 {
            return .global
        }
        if position >= 1.0 {
            return .perFrame
        }
        return .hybrid(
            maxOverrides: maxOverrides,
            errorThreshold: errorThreshold
        )
    }

    /// User-facing description
    public var description: String {
        switch position {
        case 0.0:
            return "Global - Single 256-color palette"
        case 0.01..<0.33:
            return "Light Hybrid - Few corrections"
        case 0.33..<0.67:
            return "Balanced - Mix of global/per-frame"
        case 0.67..<1.0:
            return "High Quality - Mostly per-frame"
        case 1.0:
            return "Per-Frame - Every frame optimized"
        default:
            return "Custom (\(Int(position * 100))%)"
        }
    }

    /// Expected palette count
    public var expectedPaletteCount: Int {
        switch position {
        case 0.0:
            return 1  // Global only
        case 1.0...:
            return frameCount  // Every frame
        default:
            return 1 + maxOverrides  // Global + overrides
        }
    }

    /// Estimated file size multiplier relative to global (1.0 = baseline)
    public var fileSizeMultiplier: Double {
        let baseSize = 100_000.0  // Estimated base GIF size (bytes)
        let paletteBytes = Double(Self.maxColors) * 3.0  // 256 colors × 3 bytes RGB

        let globalSize = baseSize + paletteBytes
        let currentSize = baseSize + (Double(expectedPaletteCount) * paletteBytes)

        return currentSize / globalSize
    }

    /// File size increase percentage vs global
    public var fileSizeIncreasePercent: Int {
        return Int((fileSizeMultiplier - 1.0) * 100)
    }

    /// User-facing stats summary
    public var statsSummary: String {
        let percentage = Int(position * 100)
        return """
        Quality: \(percentage)%
        Palettes: ~\(expectedPaletteCount) × \(Self.maxColors) colors
        File size: +\(fileSizeIncreasePercent)% vs global
        """
    }

    // MARK: - Presets

    /// Maximum compression (global palette)
    public static func maxCompression(frameCount: Int) -> PaletteStrategyConfig {
        return PaletteStrategyConfig(position: 0.0, frameCount: frameCount)
    }

    /// Balanced quality (50% hybrid)
    public static func balanced(frameCount: Int) -> PaletteStrategyConfig {
        return PaletteStrategyConfig(position: 0.5, frameCount: frameCount)
    }

    /// Maximum quality (per-frame palettes)
    public static func maxQuality(frameCount: Int) -> PaletteStrategyConfig {
        return PaletteStrategyConfig(position: 1.0, frameCount: frameCount)
    }
}

// MARK: - Codable

extension PaletteStrategyConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case position
        case frameCount
    }
}

// MARK: - Equatable

extension PaletteStrategyConfig: Equatable {
    public static func == (lhs: PaletteStrategyConfig, rhs: PaletteStrategyConfig) -> Bool {
        return abs(lhs.position - rhs.position) < 0.001 &&
               lhs.frameCount == rhs.frameCount
    }
}

// MARK: - Safe UInt8 Conversion Helpers

public extension Int {
    /// Safe conversion to UInt8 with clamping (never crashes)
    func toUInt8Clamped() -> UInt8 {
        return UInt8(clamping: self)
    }

    /// Safe conversion to UInt8 with validation (throws on overflow)
    func toUInt8Safe() throws -> UInt8 {
        guard self >= 0 && self <= 255 else {
            throw PaletteConversionError.indexOutOfRange(value: self)
        }
        return UInt8(self)
    }
}

// MARK: - Palette Validation Helpers

public extension Array where Element == [[UInt8]] {
    /// Safe palette index count (max 256)
    var safeIndexCount: Int {
        return Swift.min(self.count, PaletteStrategyConfig.maxColors)
    }

    /// Validate palette size is within allowed range
    func validatePaletteSize() throws {
        guard self.count > 0 && self.count <= PaletteStrategyConfig.maxColors else {
            throw PaletteConversionError.invalidPaletteSize(
                count: self.count,
                allowed: 1...PaletteStrategyConfig.maxColors
            )
        }
    }
}

// MARK: - Errors

public enum PaletteConversionError: LocalizedError {
    case indexOutOfRange(value: Int)
    case invalidPaletteSize(count: Int, allowed: ClosedRange<Int>)
    case paletteOverflow(attemptedSize: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .indexOutOfRange(let value):
            return "Palette index \(value) out of UInt8 range (0-255)"
        case .invalidPaletteSize(let count, let allowed):
            return "Invalid palette size \(count), must be in range \(allowed)"
        case .paletteOverflow(let attempted, let maximum):
            return "Palette size \(attempted) exceeds maximum \(maximum)"
        }
    }
}
