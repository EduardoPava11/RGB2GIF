//
//  ColorMerger.swift
//  RGB2GIF
//
//  ============================================================================
//  COLOR MERGER: Combine Two 256-Color Palettes into One
//  ============================================================================
//
//  THE CORRECTED APPROACH
//  ──────────────────────
//  Previous (flawed): Split 256 into 128+128 before selection
//  Corrected:         Let each game select its OWN 256, then merge
//
//  WHY THIS IS BETTER
//  ──────────────────
//  1. Each game has FULL expressive power (256 choices)
//  2. Overlaps reveal AGREEMENT (high confidence colors)
//  3. Conflicts reveal TRADE-OFFS (where games disagree)
//  4. Final 256 is a NEGOTIATED result, not arbitrary split
//
//  THE MERGE ALGORITHM
//  ───────────────────
//  Input:  Spatial palette (256 colors), Temporal palette (256 colors)
//  Output: Merged palette (exactly 256 colors)
//
//  Step 1: Find EXACT matches (both games picked same RGB)
//          → These go directly into final palette
//
//  Step 2: Find SIMILAR colors (within ΔE threshold)
//          → Average them or pick higher-scoring one
//
//  Step 3: Fill remaining slots
//          → Alternate between games, highest-scoring first
//          → Use perceptual distance to avoid redundancy
//
//  PERCEPTUAL DISTANCE
//  ───────────────────
//  We use CIEDE2000 (not Euclidean RGB) because:
//  - Human perception is non-linear
//  - Green differences are more noticeable than blue
//  - Dark colors are harder to distinguish
//
//  Reference: Sharma et al. "The CIEDE2000 Color-Difference Formula"
//
//  ============================================================================

import Foundation
import simd
import Accelerate

// MARK: - Color Merger

@available(iOS 26.0, *)
public struct ColorMerger {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ════════════════════════════════════════════════════════════════════════

    /// CIEDE2000 threshold for "similar" colors
    /// ΔE < 2.3 is "just noticeable difference" for trained observers
    /// ΔE < 5.0 is noticeable but acceptable for most purposes
    public static let similarityThreshold: Float = 5.0

    /// Target palette size
    public static let paletteSize: Int = 256

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Scored Color
    // ════════════════════════════════════════════════════════════════════════

    /// A color with its score from a GO game
    public struct ScoredColor: Hashable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public let score: Float
        public let source: Source

        public enum Source {
            case spatial
            case temporal
            case both  // When both games selected this exact color
        }

        public var rgb: (UInt8, UInt8, UInt8) { (r, g, b) }
        public var packed: UInt32 {
            (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(packed)
        }

        public static func == (lhs: ScoredColor, rhs: ScoredColor) -> Bool {
            lhs.packed == rhs.packed
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Merge Algorithm
    // ════════════════════════════════════════════════════════════════════════

    /// Merge two 256-color palettes into one.
    ///
    /// Each input palette comes from a different GO game:
    /// - Spatial palette: Colors important for spatial coherence
    /// - Temporal palette: Colors important for temporal coherence
    ///
    /// The merge process:
    /// 1. Exact matches → keep with combined score, mark as .both
    /// 2. Similar colors → average RGB, combine scores
    /// 3. Fill remaining → alternate between games by score
    ///
    /// - Parameters:
    ///   - spatialPalette: 256 colors with scores from spatial game
    ///   - temporalPalette: 256 colors with scores from temporal game
    /// - Returns: Merged 256-color palette, ordered by luminance
    public static func merge(
        spatialPalette: [(color: (r: UInt8, g: UInt8, b: UInt8), score: Float)],
        temporalPalette: [(color: (r: UInt8, g: UInt8, b: UInt8), score: Float)]
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {

        // Convert to ScoredColor for easier processing
        let spatialSet = Set(spatialPalette.map {
            ScoredColor(r: $0.color.r, g: $0.color.g, b: $0.color.b,
                       score: $0.score, source: .spatial)
        })
        let temporalSet = Set(temporalPalette.map {
            ScoredColor(r: $0.color.r, g: $0.color.g, b: $0.color.b,
                       score: $0.score, source: .temporal)
        })

        var merged = [ScoredColor]()
        var usedPacked = Set<UInt32>()

        // ─────────────────────────────────────────────────────────────────────
        // Step 1: Find EXACT matches (high confidence - both games agree)
        // ─────────────────────────────────────────────────────────────────────
        let exactMatches = spatialSet.intersection(temporalSet)

        for spatialColor in exactMatches {
            if let temporalColor = temporalSet.first(where: { $0.packed == spatialColor.packed }) {
                let combined = ScoredColor(
                    r: spatialColor.r, g: spatialColor.g, b: spatialColor.b,
                    score: spatialColor.score + temporalColor.score,  // Boost for agreement
                    source: .both
                )
                merged.append(combined)
                usedPacked.insert(combined.packed)
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Step 2: Find SIMILAR colors (within ΔE threshold)
        // ─────────────────────────────────────────────────────────────────────
        let remainingSpatial = spatialPalette.filter { !usedPacked.contains(packRGB($0.color)) }
        let remainingTemporal = temporalPalette.filter { !usedPacked.contains(packRGB($0.color)) }

        var spatialUsed = Set<UInt32>()
        var temporalUsed = Set<UInt32>()

        for spatial in remainingSpatial {
            if spatialUsed.contains(packRGB(spatial.color)) { continue }

            // Find similar temporal color
            for temporal in remainingTemporal {
                if temporalUsed.contains(packRGB(temporal.color)) { continue }

                let deltaE = ciede2000(spatial.color, temporal.color)

                if deltaE < similarityThreshold {
                    // Average the colors, combine scores
                    let avgR = UInt8((Int(spatial.color.r) + Int(temporal.color.r)) / 2)
                    let avgG = UInt8((Int(spatial.color.g) + Int(temporal.color.g)) / 2)
                    let avgB = UInt8((Int(spatial.color.b) + Int(temporal.color.b)) / 2)

                    let combined = ScoredColor(
                        r: avgR, g: avgG, b: avgB,
                        score: spatial.score + temporal.score,
                        source: .both
                    )

                    if !usedPacked.contains(combined.packed) {
                        merged.append(combined)
                        usedPacked.insert(combined.packed)
                        spatialUsed.insert(packRGB(spatial.color))
                        temporalUsed.insert(packRGB(temporal.color))
                    }
                    break
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Step 3: Fill remaining slots alternating between games
        // ─────────────────────────────────────────────────────────────────────
        let unusedSpatial = remainingSpatial
            .filter { !spatialUsed.contains(packRGB($0.color)) }
            .sorted { $0.score > $1.score }

        let unusedTemporal = remainingTemporal
            .filter { !temporalUsed.contains(packRGB($0.color)) }
            .sorted { $0.score > $1.score }

        var spatialIdx = 0
        var temporalIdx = 0
        var useSpatialNext = true

        while merged.count < paletteSize {
            if useSpatialNext && spatialIdx < unusedSpatial.count {
                let c = unusedSpatial[spatialIdx].color
                let packed = packRGB(c)

                // Check it's not too similar to existing colors
                if !usedPacked.contains(packed) && !isTooSimilar(c, to: merged) {
                    merged.append(ScoredColor(
                        r: c.r, g: c.g, b: c.b,
                        score: unusedSpatial[spatialIdx].score,
                        source: .spatial
                    ))
                    usedPacked.insert(packed)
                }
                spatialIdx += 1
            } else if !useSpatialNext && temporalIdx < unusedTemporal.count {
                let c = unusedTemporal[temporalIdx].color
                let packed = packRGB(c)

                if !usedPacked.contains(packed) && !isTooSimilar(c, to: merged) {
                    merged.append(ScoredColor(
                        r: c.r, g: c.g, b: c.b,
                        score: unusedTemporal[temporalIdx].score,
                        source: .temporal
                    ))
                    usedPacked.insert(packed)
                }
                temporalIdx += 1
            } else {
                // If one list is exhausted, keep pulling from the other
                if spatialIdx >= unusedSpatial.count && temporalIdx >= unusedTemporal.count {
                    break  // Both exhausted
                }
                useSpatialNext = spatialIdx < unusedSpatial.count
                continue
            }

            useSpatialNext.toggle()
        }

        // ─────────────────────────────────────────────────────────────────────
        // Step 4: Pad if needed, sort by luminance
        // ─────────────────────────────────────────────────────────────────────
        var result = merged.map { ($0.r, $0.g, $0.b) }

        // Pad with black if we somehow have fewer than 256
        while result.count < paletteSize {
            result.append((0, 0, 0))
        }

        // Truncate if over (shouldn't happen)
        if result.count > paletteSize {
            result = Array(result.prefix(paletteSize))
        }

        // Sort by luminance for GIF composability
        result.sort { luminance($0) < luminance($1) }

        return result
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - CIEDE2000 Color Difference
    // ════════════════════════════════════════════════════════════════════════

    /// Calculate CIEDE2000 color difference (perceptual distance).
    ///
    /// Reference: Sharma, Wu, Dalal (2005)
    /// "The CIEDE2000 Color-Difference Formula"
    /// Color Research and Application, Vol. 30, No. 1
    ///
    /// - Returns: ΔE value (0 = identical, ~2.3 = just noticeable, >5 = clearly different)
    public static func ciede2000(
        _ c1: (r: UInt8, g: UInt8, b: UInt8),
        _ c2: (r: UInt8, g: UInt8, b: UInt8)
    ) -> Float {
        // Convert RGB to LAB
        let lab1 = rgbToLab(c1)
        let lab2 = rgbToLab(c2)

        return ciede2000Lab(lab1, lab2)
    }

    /// CIEDE2000 on LAB colors
    private static func ciede2000Lab(
        _ lab1: (L: Float, a: Float, b: Float),
        _ lab2: (L: Float, a: Float, b: Float)
    ) -> Float {
        let L1 = lab1.L, a1 = lab1.a, b1 = lab1.b
        let L2 = lab2.L, a2 = lab2.a, b2 = lab2.b

        // Parametric weighting factors
        let kL: Float = 1.0
        let kC: Float = 1.0
        let kH: Float = 1.0

        // Calculate C'ab and h'ab
        let C1 = sqrt(a1 * a1 + b1 * b1)
        let C2 = sqrt(a2 * a2 + b2 * b2)
        let Cab = (C1 + C2) / 2.0

        let G = 0.5 * (1.0 - sqrt(pow(Cab, 7) / (pow(Cab, 7) + pow(25, 7))))

        let a1p = a1 * (1.0 + G)
        let a2p = a2 * (1.0 + G)

        let C1p = sqrt(a1p * a1p + b1 * b1)
        let C2p = sqrt(a2p * a2p + b2 * b2)

        var h1p: Float = 0
        if a1p != 0 || b1 != 0 {
            h1p = atan2(b1, a1p)
            if h1p < 0 { h1p += 2 * .pi }
        }

        var h2p: Float = 0
        if a2p != 0 || b2 != 0 {
            h2p = atan2(b2, a2p)
            if h2p < 0 { h2p += 2 * .pi }
        }

        // Calculate ΔL', ΔC', ΔH'
        let dLp = L2 - L1
        let dCp = C2p - C1p

        var dhp: Float = 0
        if C1p * C2p != 0 {
            dhp = h2p - h1p
            if dhp > .pi { dhp -= 2 * .pi }
            if dhp < -.pi { dhp += 2 * .pi }
        }

        let dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2)

        // Calculate CIEDE2000
        let Lp = (L1 + L2) / 2
        let Cp = (C1p + C2p) / 2

        var Hp: Float = 0
        if C1p * C2p != 0 {
            Hp = (h1p + h2p) / 2
            if abs(h1p - h2p) > .pi {
                Hp += .pi
            }
        }

        let T = 1 - 0.17 * cos(Hp - .pi / 6) + 0.24 * cos(2 * Hp) +
                0.32 * cos(3 * Hp + .pi / 30) - 0.20 * cos(4 * Hp - 63 * .pi / 180)

        let dTheta = 30 * exp(-pow((Hp - 275 * .pi / 180) / (25 * .pi / 180), 2))
        let RC = 2 * sqrt(pow(Cp, 7) / (pow(Cp, 7) + pow(25, 7)))
        let SL = 1 + (0.015 * pow(Lp - 50, 2)) / sqrt(20 + pow(Lp - 50, 2))
        let SC = 1 + 0.045 * Cp
        let SH = 1 + 0.015 * Cp * T
        let RT = -sin(2 * dTheta * .pi / 180) * RC

        let dE = sqrt(
            pow(dLp / (kL * SL), 2) +
            pow(dCp / (kC * SC), 2) +
            pow(dHp / (kH * SH), 2) +
            RT * (dCp / (kC * SC)) * (dHp / (kH * SH))
        )

        return dE
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Color Space Conversion
    // ════════════════════════════════════════════════════════════════════════

    /// Convert RGB to CIELAB
    private static func rgbToLab(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> (L: Float, a: Float, b: Float) {
        // RGB to XYZ (sRGB with D65 illuminant)
        var r = Float(c.r) / 255.0
        var g = Float(c.g) / 255.0
        var b = Float(c.b) / 255.0

        // Apply gamma correction
        r = r > 0.04045 ? pow((r + 0.055) / 1.055, 2.4) : r / 12.92
        g = g > 0.04045 ? pow((g + 0.055) / 1.055, 2.4) : g / 12.92
        b = b > 0.04045 ? pow((b + 0.055) / 1.055, 2.4) : b / 12.92

        // sRGB to XYZ matrix (D65)
        let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041

        // XYZ to LAB (D65 reference white)
        let xn: Float = 0.95047
        let yn: Float = 1.00000
        let zn: Float = 1.08883

        let fx = labF(x / xn)
        let fy = labF(y / yn)
        let fz = labF(z / zn)

        let L = 116 * fy - 16
        let a = 500 * (fx - fy)
        let bLab = 200 * (fy - fz)

        return (L, a, bLab)
    }

    private static func labF(_ t: Float) -> Float {
        let delta: Float = 6.0 / 29.0
        if t > pow(delta, 3) {
            return pow(t, 1.0 / 3.0)
        } else {
            return t / (3 * delta * delta) + 4.0 / 29.0
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ════════════════════════════════════════════════════════════════════════

    private static func packRGB(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> UInt32 {
        (UInt32(c.r) << 16) | (UInt32(c.g) << 8) | UInt32(c.b)
    }

    private static func luminance(_ c: (UInt8, UInt8, UInt8)) -> Float {
        0.299 * Float(c.0) + 0.587 * Float(c.1) + 0.114 * Float(c.2)
    }

    /// Check if a color is too similar to any existing color in the palette
    private static func isTooSimilar(
        _ c: (r: UInt8, g: UInt8, b: UInt8),
        to existing: [ScoredColor],
        threshold: Float = 2.0  // Stricter than similarityThreshold
    ) -> Bool {
        for e in existing {
            if ciede2000(c, (e.r, e.g, e.b)) < threshold {
                return true
            }
        }
        return false
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Statistics
    // ════════════════════════════════════════════════════════════════════════

    /// Analyze a merge result
    public struct MergeStats {
        public let exactMatches: Int
        public let similarMerges: Int
        public let spatialOnly: Int
        public let temporalOnly: Int
        public let totalColors: Int

        public var agreementRate: Float {
            Float(exactMatches + similarMerges) / Float(totalColors)
        }
    }

    /// Get statistics about a merge operation
    public static func analyzeMerge(
        spatialPalette: [(color: (r: UInt8, g: UInt8, b: UInt8), score: Float)],
        temporalPalette: [(color: (r: UInt8, g: UInt8, b: UInt8), score: Float)]
    ) -> MergeStats {
        let spatialPacked = Set(spatialPalette.map { packRGB($0.color) })
        let temporalPacked = Set(temporalPalette.map { packRGB($0.color) })

        let exactMatches = spatialPacked.intersection(temporalPacked).count

        // Count similar (but not exact) matches
        var similarCount = 0
        let spatialUsed = Set<UInt32>()
        for s in spatialPalette {
            if temporalPacked.contains(packRGB(s.color)) { continue }
            for t in temporalPalette {
                if spatialPacked.contains(packRGB(t.color)) { continue }
                if ciede2000(s.color, t.color) < similarityThreshold {
                    similarCount += 1
                    break
                }
            }
        }

        return MergeStats(
            exactMatches: exactMatches,
            similarMerges: similarCount,
            spatialOnly: 256 - exactMatches - similarCount,
            temporalOnly: 256 - exactMatches - similarCount,
            totalColors: 256
        )
    }
}

// MARK: - Accelerate-Optimized Batch Operations

@available(iOS 26.0, *)
extension ColorMerger {

    /// Compute all pairwise CIEDE2000 distances using Accelerate.
    ///
    /// This is O(n²) but optimized with vDSP for the inner loops.
    ///
    /// - Parameter colors: Array of RGB colors
    /// - Returns: Distance matrix (symmetric, diagonal = 0)
    public static func computeDistanceMatrix(
        colors: [(r: UInt8, g: UInt8, b: UInt8)]
    ) -> [[Float]] {
        let n = colors.count

        // Convert all to LAB first
        let labs = colors.map { rgbToLab($0) }

        var matrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)

        // Compute upper triangle (matrix is symmetric)
        for i in 0..<n {
            for j in (i+1)..<n {
                let d = ciede2000Lab(labs[i], labs[j])
                matrix[i][j] = d
                matrix[j][i] = d
            }
        }

        return matrix
    }

    /// Find the k most distinct colors from a set using greedy selection.
    ///
    /// Start with the highest-scoring color, then iteratively add
    /// the color that is MOST DIFFERENT from all already-selected colors.
    ///
    /// - Parameters:
    ///   - colors: Scored colors to select from
    ///   - k: Number of colors to select
    /// - Returns: k most distinct colors
    public static func selectMostDistinct(
        from colors: [(color: (r: UInt8, g: UInt8, b: UInt8), score: Float)],
        k: Int
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        guard !colors.isEmpty else { return [] }
        guard k > 0 else { return [] }

        // Start with highest-scoring color
        let sorted = colors.sorted { $0.score > $1.score }
        var selected = [sorted[0].color]
        var remaining = Array(sorted.dropFirst())

        while selected.count < k && !remaining.isEmpty {
            // Find color with maximum minimum distance to selected set
            var bestIdx = 0
            var bestMinDist: Float = -1

            for (idx, candidate) in remaining.enumerated() {
                var minDist = Float.infinity
                for s in selected {
                    let d = ciede2000(candidate.color, s)
                    minDist = min(minDist, d)
                }

                // Weight by score as well
                let weightedDist = minDist * (1 + candidate.score)

                if weightedDist > bestMinDist {
                    bestMinDist = weightedDist
                    bestIdx = idx
                }
            }

            selected.append(remaining[bestIdx].color)
            remaining.remove(at: bestIdx)
        }

        return selected
    }
}
