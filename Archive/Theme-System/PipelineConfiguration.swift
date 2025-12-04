//
//  PipelineConfiguration.swift
//  RGB2GIF
//
//  Pipeline configuration for GIP/GIX capture with palette and color mode options
//

import Foundation

@available(iOS 26.0, *)
public struct PipelineConfiguration {

    // MARK: - Dimension Mode

    /// Target dimension for frames
    public enum DimensionMode: Int, Codable, CaseIterable {
        case dim80 = 80    // 80×80 frames
        case dim128 = 128  // 128×128 frames

        public var dimension: Int {
            return self.rawValue
        }

        public var frameCount: Int {
            switch self {
            case .dim80: return 80
            case .dim128: return 128
            }
        }

        public var description: String {
            return "\(dimension)×\(dimension)"
        }
    }

    // MARK: - Palette Strategy

    /// Palette generation strategy
    public enum PaletteStrategy: String, Codable, CaseIterable {
        case global      // Single global palette for all frames
        case hybrid      // Global with per-frame optimization if diversity high
        case perFrame    // Separate palette per frame (max quality)

        public var description: String {
            switch self {
            case .global: return "Global (Shared)"
            case .hybrid: return "Hybrid (Adaptive)"
            case .perFrame: return "Per-Frame (Max Quality)"
            }
        }

        /// Whether this strategy supports multiple palettes
        public var supportsMultiplePalettes: Bool {
            switch self {
            case .global: return false
            case .hybrid, .perFrame: return true
            }
        }

        /// Expected file size multiplier relative to global
        public var fileSizeMultiplier: Double {
            switch self {
            case .global: return 1.0
            case .hybrid: return 1.2  // +20% for some per-frame palettes
            case .perFrame: return 1.5  // +50% for all per-frame palettes
            }
        }
    }

    // MARK: - Color Pipeline

    /// Color acquisition and processing pipeline
    /// NOTE: Only .yuv is used in production. RGBA/auto are legacy options kept for API compatibility.
    public enum ColorPipeline: String, Codable, CaseIterable {
        case yuv         // YUV420 native (fastest, most compatible) - ONLY USED OPTION
        case rgba        // RGBA fallback (wider color gamut) - DEPRECATED
        case auto        // Auto-select based on device capabilities - DEPRECATED

        public var description: String {
            switch self {
            case .yuv: return "YUV (Default)"
            case .rgba: return "RGBA (Fallback)"
            case .auto: return "Auto"
            }
        }

        public var bytesPerPixel: Int {
            switch self {
            case .yuv: return 3   // Y, U, V
            case .rgba: return 4  // R, G, B, A
            case .auto: return 3  // Default to YUV
            }
        }
    }

    // MARK: - Properties

    public let dimensionMode: DimensionMode
    public let paletteStrategy: PaletteStrategy
    public let colorPipeline: ColorPipeline

    // Hybrid strategy thresholds
    public let hybridDiversityThreshold: Double  // Color diversity threshold (0.0-1.0)
    public let hybridMaxPerFramePalettes: Int     // Max frames with per-frame palettes

    // Quality settings
    public let enableDithering: Bool
    public let paletteSize: Int  // 2-256 colors

    // MARK: - Initialization

    public init(
        dimensionMode: DimensionMode = .dim80,
        paletteStrategy: PaletteStrategy = .global,
        colorPipeline: ColorPipeline = .yuv,
        hybridDiversityThreshold: Double = 0.7,
        hybridMaxPerFramePalettes: Int = 16,
        enableDithering: Bool = false,
        paletteSize: Int = 256
    ) {
        self.dimensionMode = dimensionMode
        self.paletteStrategy = paletteStrategy
        self.colorPipeline = colorPipeline
        self.hybridDiversityThreshold = max(0.0, min(1.0, hybridDiversityThreshold))
        self.hybridMaxPerFramePalettes = max(0, min(dimensionMode.frameCount, hybridMaxPerFramePalettes))
        self.enableDithering = enableDithering
        self.paletteSize = min(256, max(2, paletteSize))
    }

    // MARK: - Presets

    /// Fast preset: 80×80, global palette, YUV
    public static var fast: PipelineConfiguration {
        return PipelineConfiguration(
            dimensionMode: .dim80,
            paletteStrategy: .global,
            colorPipeline: .yuv,
            enableDithering: false
        )
    }

    /// Balanced preset: 80×80, hybrid palette, YUV
    public static var balanced: PipelineConfiguration {
        return PipelineConfiguration(
            dimensionMode: .dim80,
            paletteStrategy: .hybrid,
            colorPipeline: .yuv,
            enableDithering: false
        )
    }

    /// Quality preset: 128×128, per-frame palette, YUV with dithering
    public static var quality: PipelineConfiguration {
        return PipelineConfiguration(
            dimensionMode: .dim128,
            paletteStrategy: .perFrame,
            colorPipeline: .yuv,  // Always YUV
            enableDithering: true
        )
    }

    // MARK: - Computed Properties

    /// Expected palette count based on strategy
    public var expectedPaletteCount: Int {
        switch paletteStrategy {
        case .global:
            return 1
        case .hybrid:
            return hybridMaxPerFramePalettes + 1  // Global + up to N per-frame
        case .perFrame:
            return dimensionMode.frameCount
        }
    }

    /// Total pixels per frame
    public var pixelsPerFrame: Int {
        let dim = dimensionMode.dimension
        return dim * dim
    }

    /// Memory estimate for frame buffer (MB)
    public var estimatedMemoryMB: Double {
        let frameCount = dimensionMode.frameCount
        let bytesPerPixel = colorPipeline.bytesPerPixel
        let frameBytes = pixelsPerFrame * bytesPerPixel
        let totalBytes = frameCount * frameBytes
        let paletteBytes = expectedPaletteCount * paletteSize * 3  // RGB
        return Double(totalBytes + paletteBytes) / (1024 * 1024)
    }

    /// User-facing description of configuration
    public var userDescription: String {
        return """
        Dimension: \(dimensionMode.description)
        Palette: \(paletteStrategy.description)
        Pipeline: \(colorPipeline.description)
        Frames: \(dimensionMode.frameCount)
        Palettes: ~\(expectedPaletteCount)
        Memory: ~\(String(format: "%.1f", estimatedMemoryMB)) MB
        """
    }
}

// MARK: - Codable Support

extension PipelineConfiguration: Codable {

    enum CodingKeys: String, CodingKey {
        case dimensionMode
        case paletteStrategy
        case colorPipeline
        case hybridDiversityThreshold
        case hybridMaxPerFramePalettes
        case enableDithering
        case paletteSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.dimensionMode = try container.decode(DimensionMode.self, forKey: .dimensionMode)
        self.paletteStrategy = try container.decode(PaletteStrategy.self, forKey: .paletteStrategy)
        self.colorPipeline = try container.decode(ColorPipeline.self, forKey: .colorPipeline)
        self.hybridDiversityThreshold = try container.decode(Double.self, forKey: .hybridDiversityThreshold)
        self.hybridMaxPerFramePalettes = try container.decode(Int.self, forKey: .hybridMaxPerFramePalettes)
        self.enableDithering = try container.decode(Bool.self, forKey: .enableDithering)
        self.paletteSize = try container.decode(Int.self, forKey: .paletteSize)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(dimensionMode, forKey: .dimensionMode)
        try container.encode(paletteStrategy, forKey: .paletteStrategy)
        try container.encode(colorPipeline, forKey: .colorPipeline)
        try container.encode(hybridDiversityThreshold, forKey: .hybridDiversityThreshold)
        try container.encode(hybridMaxPerFramePalettes, forKey: .hybridMaxPerFramePalettes)
        try container.encode(enableDithering, forKey: .enableDithering)
        try container.encode(paletteSize, forKey: .paletteSize)
    }
}

// MARK: - AppStorage Support

extension PipelineConfiguration {

    /// Save to UserDefaults
    public func save(to defaults: UserDefaults = .standard, key: String = "pipelineConfiguration") {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: key)
        }
    }

    /// Load from UserDefaults
    public static func load(from defaults: UserDefaults = .standard, key: String = "pipelineConfiguration") -> PipelineConfiguration? {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(PipelineConfiguration.self, from: data) else {
            return nil
        }
        return config
    }
}
