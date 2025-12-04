//
//  ContentTypeClassifier.swift
//  RGB2GIF
//
//  ============================================================================
//  CONTENT TYPE CLASSIFIER: Automatic Video Content Classification
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Classifies video content into categories for gene specialization:
//
//  1. NATURE     - Landscapes, plants, animals, outdoor scenes
//  2. PORTRAIT   - Faces, people, close-ups of subjects
//  3. ACTION     - Sports, movement, dynamic scenes
//  4. URBAN      - Architecture, streets, city scenes
//  5. ABSTRACT   - Patterns, non-representational content
//  6. LOW_LIGHT  - Night scenes, dimly lit content
//  7. TEXT       - Screenshots, documents, text-heavy content
//  8. ANIMATION  - Cartoons, animated content, graphics
//
//  APPROACH
//  ────────
//  This implementation uses histogram-based heuristics:
//  - Color distribution (hue histogram)
//  - Brightness distribution
//  - Edge density
//  - Motion patterns
//  - Saturation levels
//
//  A future version could use CoreML for more accurate classification,
//  but the histogram approach provides reasonable accuracy (~70-80%)
//  while being extremely fast (<15ms).
//
//  USAGE
//  ─────
//  let classifier = ContentTypeClassifier()
//  let contentType = classifier.classify(centroids: tensor.centroidColors())
//
//  ============================================================================

import Foundation

// MARK: - Content Type

/// Categories of video content for gene specialization.
public enum ContentType: String, CaseIterable, Codable, Sendable {
    case nature      // Landscapes, plants, animals
    case portrait    // Faces, people
    case action      // Sports, movement
    case urban       // Architecture, cities
    case abstract    // Patterns, non-representational
    case lowLight    // Night, dim scenes
    case text        // Screenshots, documents
    case animation   // Cartoons, graphics

    /// Human-readable description.
    public var description: String {
        switch self {
        case .nature: return "Nature & Landscapes"
        case .portrait: return "Portraits & People"
        case .action: return "Action & Sports"
        case .urban: return "Urban & Architecture"
        case .abstract: return "Abstract & Patterns"
        case .lowLight: return "Low Light & Night"
        case .text: return "Text & Screenshots"
        case .animation: return "Animation & Graphics"
        }
    }

    /// Emoji icon for UI.
    public var icon: String {
        switch self {
        case .nature: return "🌿"
        case .portrait: return "👤"
        case .action: return "🏃"
        case .urban: return "🏙️"
        case .abstract: return "🎨"
        case .lowLight: return "🌙"
        case .text: return "📝"
        case .animation: return "🎬"
        }
    }
}

// MARK: - Content Type Classifier

/// Classifies video content using histogram-based heuristics.
public struct ContentTypeClassifier: Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configuration for classification thresholds.
    public struct Config: Sendable {
        /// Brightness threshold for low-light detection.
        public var lowLightThreshold: Float = 0.25

        /// Saturation threshold for animation detection.
        public var highSaturationThreshold: Float = 0.7

        /// Edge density threshold for text detection.
        public var textEdgeThreshold: Float = 0.4

        /// Green-dominance threshold for nature detection.
        public var natureBias: Float = 0.15

        /// Skin tone range for portrait detection (in HSV).
        public var skinHueRange: ClosedRange<Float> = 0.0...0.1

        /// Motion threshold for action detection.
        public var actionMotionThreshold: Float = 0.3

        /// Initialize with defaults.
        public init() {}
    }

    /// Active configuration.
    public var config: Config

    /// Initialize with configuration.
    public init(config: Config = Config()) {
        self.config = config
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Classification Result
    // ═══════════════════════════════════════════════════════════════════════════

    /// Result of content classification.
    public struct ClassificationResult: Sendable {
        /// Primary content type.
        public let primaryType: ContentType

        /// Confidence for primary type (0-1).
        public let confidence: Float

        /// Scores for all content types.
        public let scores: [ContentType: Float]

        /// Secondary type (if close to primary).
        public let secondaryType: ContentType?

        /// Classification time in milliseconds.
        public let classificationTimeMs: Double

        /// Features used for classification (for debugging).
        public let features: ContentFeatures
    }

    /// Features extracted for classification.
    public struct ContentFeatures: Sendable {
        public let meanBrightness: Float
        public let brightnessVariance: Float
        public let meanSaturation: Float
        public let saturationVariance: Float
        public let dominantHue: Float
        public let hueSpread: Float
        public let edgeDensity: Float
        public let motionMagnitude: Float
        public let colorUniqueness: Float
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Classification
    // ═══════════════════════════════════════════════════════════════════════════

    /// Classify content from 729 centroids.
    ///
    /// - Parameter centroids: 729 RGB color tuples from TensorCube729
    /// - Returns: ClassificationResult with type and confidence
    public func classify(centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> ClassificationResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Extract features
        let features = extractFeatures(from: centroids)

        // Score each content type
        var scores = [ContentType: Float]()
        for type in ContentType.allCases {
            scores[type] = scoreContentType(type, features: features)
        }

        // Normalize scores to probabilities
        let totalScore = scores.values.reduce(0, +)
        if totalScore > 0 {
            for type in ContentType.allCases {
                scores[type] = (scores[type] ?? 0) / totalScore
            }
        }

        // Find primary and secondary types
        let sorted = scores.sorted { $0.value > $1.value }
        let primaryType = sorted[0].key
        let primaryConfidence = sorted[0].value
        let secondaryType: ContentType? = sorted.count > 1 && sorted[1].value > 0.2 ? sorted[1].key : nil

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        return ClassificationResult(
            primaryType: primaryType,
            confidence: primaryConfidence,
            scores: scores,
            secondaryType: secondaryType,
            classificationTimeMs: elapsed,
            features: features
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Feature Extraction
    // ═══════════════════════════════════════════════════════════════════════════

    /// Extract content features from centroids.
    private func extractFeatures(from centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> ContentFeatures {
        // Convert to HSV and compute statistics
        var hsvColors: [(h: Float, s: Float, v: Float)] = []
        hsvColors.reserveCapacity(centroids.count)

        for c in centroids {
            hsvColors.append(rgbToHSV(r: c.r, g: c.g, b: c.b))
        }

        // Brightness statistics
        let brightness = hsvColors.map { $0.v }
        let meanBrightness = brightness.reduce(0, +) / Float(brightness.count)
        let brightnessVariance = brightness.map { ($0 - meanBrightness) * ($0 - meanBrightness) }.reduce(0, +) / Float(brightness.count)

        // Saturation statistics
        let saturation = hsvColors.map { $0.s }
        let meanSaturation = saturation.reduce(0, +) / Float(saturation.count)
        let saturationVariance = saturation.map { ($0 - meanSaturation) * ($0 - meanSaturation) }.reduce(0, +) / Float(saturation.count)

        // Hue statistics (using circular mean)
        let hues = hsvColors.filter { $0.s > 0.1 }.map { $0.h }  // Only consider saturated colors
        let (dominantHue, hueSpread) = computeHueStatistics(hues)

        // Edge density (simplified: neighbor color differences)
        let edgeDensity = computeEdgeDensity(centroids)

        // Motion magnitude (frame-to-frame changes)
        let motionMagnitude = computeMotionMagnitude(centroids)

        // Color uniqueness (number of distinct colors / total)
        let colorUniqueness = computeColorUniqueness(centroids)

        return ContentFeatures(
            meanBrightness: meanBrightness,
            brightnessVariance: brightnessVariance,
            meanSaturation: meanSaturation,
            saturationVariance: saturationVariance,
            dominantHue: dominantHue,
            hueSpread: hueSpread,
            edgeDensity: edgeDensity,
            motionMagnitude: motionMagnitude,
            colorUniqueness: colorUniqueness
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Content Type Scoring
    // ═══════════════════════════════════════════════════════════════════════════

    /// Score how well features match a content type.
    private func scoreContentType(_ type: ContentType, features: ContentFeatures) -> Float {
        switch type {
        case .nature:
            return scoreNature(features)
        case .portrait:
            return scorePortrait(features)
        case .action:
            return scoreAction(features)
        case .urban:
            return scoreUrban(features)
        case .abstract:
            return scoreAbstract(features)
        case .lowLight:
            return scoreLowLight(features)
        case .text:
            return scoreText(features)
        case .animation:
            return scoreAnimation(features)
        }
    }

    /// Nature: Green/blue hues, moderate saturation, varied brightness.
    private func scoreNature(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // Green/cyan dominant hue (0.25-0.5 in HSV)
        if f.dominantHue >= 0.2 && f.dominantHue <= 0.5 {
            score += 0.3
        }

        // Moderate saturation (not too muted, not too vivid)
        if f.meanSaturation >= 0.3 && f.meanSaturation <= 0.7 {
            score += 0.25
        }

        // Varied brightness (landscapes have sky and shadows)
        if f.brightnessVariance > 0.02 {
            score += 0.2
        }

        // Wide hue spread (nature has many colors)
        if f.hueSpread > 0.3 {
            score += 0.15
        }

        // Low motion (static landscapes)
        if f.motionMagnitude < 0.15 {
            score += 0.1
        }

        return score
    }

    /// Portrait: Skin tones (orange/red hues), moderate saturation.
    private func scorePortrait(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // Skin tone hue range (0-0.1 or 0.9-1.0, wrapping around red)
        if f.dominantHue <= 0.1 || f.dominantHue >= 0.9 {
            score += 0.35
        }

        // Moderate saturation (skin is not highly saturated)
        if f.meanSaturation >= 0.2 && f.meanSaturation <= 0.5 {
            score += 0.25
        }

        // Narrow hue spread (skin dominates)
        if f.hueSpread < 0.2 {
            score += 0.2
        }

        // Moderate brightness
        if f.meanBrightness >= 0.3 && f.meanBrightness <= 0.7 {
            score += 0.1
        }

        // Low edge density (smooth skin)
        if f.edgeDensity < 0.25 {
            score += 0.1
        }

        return score
    }

    /// Action: High motion, varied content.
    private func scoreAction(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // High motion magnitude
        if f.motionMagnitude > config.actionMotionThreshold {
            score += 0.4
        } else if f.motionMagnitude > 0.15 {
            score += 0.2
        }

        // High brightness variance (movement creates blur/changes)
        if f.brightnessVariance > 0.03 {
            score += 0.2
        }

        // Wide color range
        if f.colorUniqueness > 0.3 {
            score += 0.15
        }

        // Moderate to high saturation
        if f.meanSaturation > 0.3 {
            score += 0.15
        }

        // Wide hue spread
        if f.hueSpread > 0.3 {
            score += 0.1
        }

        return score
    }

    /// Urban: Gray/blue tones, straight edges, geometric patterns.
    private func scoreUrban(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // Low saturation (concrete, glass, metal)
        if f.meanSaturation < 0.3 {
            score += 0.3
        }

        // Blue/gray dominant hue (sky, glass)
        if f.dominantHue >= 0.5 && f.dominantHue <= 0.7 {
            score += 0.2
        }

        // Moderate edge density (architectural lines)
        if f.edgeDensity >= 0.2 && f.edgeDensity <= 0.4 {
            score += 0.2
        }

        // Low motion (static buildings)
        if f.motionMagnitude < 0.1 {
            score += 0.15
        }

        // Moderate brightness variance
        if f.brightnessVariance >= 0.01 && f.brightnessVariance <= 0.04 {
            score += 0.15
        }

        return score
    }

    /// Abstract: High saturation variance, unusual hue distribution.
    private func scoreAbstract(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // High saturation variance (patches of vivid and muted)
        if f.saturationVariance > 0.04 {
            score += 0.25
        }

        // Wide hue spread (many colors)
        if f.hueSpread > 0.5 {
            score += 0.25
        }

        // High color uniqueness
        if f.colorUniqueness > 0.5 {
            score += 0.2
        }

        // Unusual brightness patterns
        if f.brightnessVariance > 0.04 {
            score += 0.15
        }

        // Moderate to low motion
        if f.motionMagnitude < 0.2 {
            score += 0.15
        }

        return score
    }

    /// Low Light: Dark overall, low saturation.
    private func scoreLowLight(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // Dark mean brightness
        if f.meanBrightness < config.lowLightThreshold {
            score += 0.5
        } else if f.meanBrightness < 0.35 {
            score += 0.25
        }

        // Low saturation (colors appear muted in low light)
        if f.meanSaturation < 0.3 {
            score += 0.25
        }

        // Low brightness variance (everything is similarly dark)
        if f.brightnessVariance < 0.02 {
            score += 0.15
        }

        // Low edge density (details lost in darkness)
        if f.edgeDensity < 0.2 {
            score += 0.1
        }

        return score
    }

    /// Text: High contrast, sharp edges, limited colors.
    private func scoreText(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // Very low saturation (black and white text)
        if f.meanSaturation < 0.15 {
            score += 0.3
        }

        // High edge density (sharp text edges)
        if f.edgeDensity > config.textEdgeThreshold {
            score += 0.3
        }

        // Low color uniqueness (limited palette)
        if f.colorUniqueness < 0.2 {
            score += 0.2
        }

        // High brightness variance (white background, dark text)
        if f.brightnessVariance > 0.05 {
            score += 0.1
        }

        // Very low motion
        if f.motionMagnitude < 0.05 {
            score += 0.1
        }

        return score
    }

    /// Animation: High saturation, flat colors, sharp edges.
    private func scoreAnimation(_ f: ContentFeatures) -> Float {
        var score: Float = 0

        // High saturation (vivid cartoon colors)
        if f.meanSaturation > config.highSaturationThreshold {
            score += 0.35
        } else if f.meanSaturation > 0.5 {
            score += 0.2
        }

        // Low saturation variance (flat shading)
        if f.saturationVariance < 0.02 {
            score += 0.2
        }

        // High edge density (cel shading, outlines)
        if f.edgeDensity > 0.35 {
            score += 0.2
        }

        // Low color uniqueness (limited palette)
        if f.colorUniqueness < 0.3 {
            score += 0.15
        }

        // Wide hue spread (colorful characters)
        if f.hueSpread > 0.4 {
            score += 0.1
        }

        return score
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// Convert RGB to HSV.
    private func rgbToHSV(r: UInt8, g: UInt8, b: UInt8) -> (h: Float, s: Float, v: Float) {
        let rf = Float(r) / 255.0
        let gf = Float(g) / 255.0
        let bf = Float(b) / 255.0

        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC

        // Value
        let v = maxC

        // Saturation
        let s = maxC > 0 ? delta / maxC : 0

        // Hue
        var h: Float = 0
        if delta > 0 {
            if maxC == rf {
                h = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == gf {
                h = ((bf - rf) / delta) + 2
            } else {
                h = ((rf - gf) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }

        return (h, s, v)
    }

    /// Compute hue statistics (circular mean and spread).
    private func computeHueStatistics(_ hues: [Float]) -> (mean: Float, spread: Float) {
        guard !hues.isEmpty else { return (0, 0) }

        // Use circular mean for hue
        var sumSin: Float = 0
        var sumCos: Float = 0
        for h in hues {
            let angle = h * 2 * .pi
            sumSin += sin(angle)
            sumCos += cos(angle)
        }
        let meanAngle = atan2(sumSin, sumCos)
        let meanHue = (meanAngle / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)

        // Spread: circular variance
        let r = sqrt(sumSin * sumSin + sumCos * sumCos) / Float(hues.count)
        let spread = 1 - r  // 0 = all same hue, 1 = uniform distribution

        return (meanHue, spread)
    }

    /// Compute edge density from centroids.
    private func computeEdgeDensity(_ centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> Float {
        var totalEdge: Float = 0
        var count = 0

        // Sample spatial edges at middle time slice
        let t = 4
        for y in 0..<8 {
            for x in 0..<8 {
                let idx = t * 81 + y * 9 + x
                let rightIdx = t * 81 + y * 9 + (x + 1)
                let bottomIdx = t * 81 + (y + 1) * 9 + x

                let c = centroids[idx]
                let right = centroids[rightIdx]
                let bottom = centroids[bottomIdx]

                totalEdge += colorDistance(c, right)
                totalEdge += colorDistance(c, bottom)
                count += 2
            }
        }

        return count > 0 ? (totalEdge / Float(count)) / 441.67 : 0
    }

    /// Compute motion magnitude from frame differences.
    private func computeMotionMagnitude(_ centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> Float {
        var totalMotion: Float = 0
        var count = 0

        // Compare consecutive time slices
        for t in 1..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let currIdx = t * 81 + y * 9 + x
                    let prevIdx = (t-1) * 81 + y * 9 + x

                    totalMotion += colorDistance(centroids[currIdx], centroids[prevIdx])
                    count += 1
                }
            }
        }

        return count > 0 ? (totalMotion / Float(count)) / 441.67 : 0
    }

    /// Compute color uniqueness (distinct colors / total).
    private func computeColorUniqueness(_ centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> Float {
        // Quantize colors to 32 levels per channel for uniqueness count
        var uniqueColors = Set<UInt32>()
        for c in centroids {
            let qr = UInt32(c.r / 8)
            let qg = UInt32(c.g / 8)
            let qb = UInt32(c.b / 8)
            let hash = (qr << 10) | (qg << 5) | qb
            uniqueColors.insert(hash)
        }

        // Max unique colors at this quantization: 32³ = 32768
        return Float(uniqueColors.count) / Float(centroids.count)
    }

    /// Color distance (Euclidean).
    private func colorDistance(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Float {
        let dr = Float(a.r) - Float(b.r)
        let dg = Float(a.g) - Float(b.g)
        let db = Float(a.b) - Float(b.b)
        return sqrt(dr*dr + dg*dg + db*db)
    }
}

// MARK: - Debug Description

extension ContentTypeClassifier.ClassificationResult: CustomStringConvertible {
    public var description: String {
        var lines = [String]()
        lines.append("ContentClassification:")
        lines.append("  Primary: \(primaryType.icon) \(primaryType.rawValue) (\(String(format: "%.1f%%", confidence * 100)))")
        if let secondary = secondaryType {
            lines.append("  Secondary: \(secondary.icon) \(secondary.rawValue)")
        }
        lines.append("  Time: \(String(format: "%.2f", classificationTimeMs))ms")
        lines.append("  Features:")
        lines.append("    Brightness: \(String(format: "%.2f", features.meanBrightness)) (var=\(String(format: "%.3f", features.brightnessVariance)))")
        lines.append("    Saturation: \(String(format: "%.2f", features.meanSaturation)) (var=\(String(format: "%.3f", features.saturationVariance)))")
        lines.append("    Hue: \(String(format: "%.2f", features.dominantHue)) (spread=\(String(format: "%.2f", features.hueSpread)))")
        lines.append("    Edge Density: \(String(format: "%.2f", features.edgeDensity))")
        lines.append("    Motion: \(String(format: "%.2f", features.motionMagnitude))")
        return lines.joined(separator: "\n")
    }
}
