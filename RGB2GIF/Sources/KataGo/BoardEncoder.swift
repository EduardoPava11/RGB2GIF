//
//  BoardEncoder.swift
//  RGB2GIF
//
//  ============================================================================
//  TENSOR TO 9×9 BOARD FEATURE ENCODER
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Converts TensorCube729 statistics into KataGo neural network input format.
//  The 81×81×81 voxel cube is projected onto a 9×9 "board" for each player:
//
//  SPATIAL PLAYER (Query provider):
//      Aggregates temporal dimension → 9×9 grid of tile importance
//      Each "stone" represents high color variance in that spatial tile
//
//  TEMPORAL PLAYER (Key provider):
//      Aggregates spatial dimension → 9×9 grid mapped from 81 frames
//      Each "stone" represents high motion/change in that time period
//
//  THE MAPPING
//  ───────────
//  We don't play actual Go moves. Instead, we encode:
//      - Color variance as "stone density" (high variance = more stones)
//      - Brightness changes as "move urgency" (captured in policy)
//      - The NN's inherent balance finds optimal attention weights
//
//  KataGo INPUT FORMAT
//  ───────────────────
//  input_spatial: (1, 22, 9, 9) - 22 binary feature planes
//      Plane 0:  Mask (1.0 for all positions - full 9×9 board)
//      Plane 1:  Own stones (we encode high-variance regions)
//      Plane 2:  Opponent stones (we encode low-variance regions)
//      Planes 3+: History, liberties, etc. (optional, can be zeroed)
//
//  input_global: (1, 19) - Global game features
//      Index 0:  Normalized komi
//      Others:   Pass history, game phase, etc.
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Board Encoder

/// Encodes TensorCube729 features into KataGo neural network input format.
///
/// This encoder creates "pseudo-Go positions" from video cube statistics.
/// The neural network's policy output then provides attention weights.
@available(iOS 15.0, macOS 12.0, *)
public struct BoardEncoder {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Board size (always 9)
    public static let boardSize = 9

    /// Number of spatial feature planes for KataGo
    public static let spatialPlanes = 22

    /// Number of global features for KataGo
    public static let globalFeatures = 19

    /// Threshold for "stone placement" based on normalized variance
    public static let stoneThreshold: Float = 0.5

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Encoding Types
    // ═══════════════════════════════════════════════════════════════════════════

    /// The type of encoding to perform
    public enum EncodingType: Sendable {
        /// For Spatial player: aggregate over time, encode tile variance
        case spatial

        /// For Temporal player: aggregate over space, encode frame activity
        case temporal
    }

    /// Statistics computed from a 9×9 region
    public struct RegionStats: Sendable {
        /// Mean color intensity (0-255 normalized to 0-1)
        public var meanIntensity: Float = 0

        /// Color variance (spread of colors)
        public var colorVariance: Float = 0

        /// Total weight (from TensorCube)
        public var totalWeight: Float = 0

        /// Dominant channel (0=R, 1=G, 2=B)
        public var dominantChannel: Int = 0
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Public API
    // ═══════════════════════════════════════════════════════════════════════════

    /// Encode TensorCube729 for the Spatial player (Query provider).
    ///
    /// Aggregates over time to create a 9×9 grid of tile statistics.
    /// High color variance tiles get "Black stones" (high attention).
    /// Low variance tiles get "White stones" (low attention).
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Tuple of (spatial features, global features) as MLMultiArrays
    @available(iOS 26.0, *)
    public static func encodeSpatialBoard(
        from tensor: TensorCube729
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {

        // Compute 9×9 spatial statistics by aggregating over time
        var stats = [[RegionStats]](
            repeating: [RegionStats](repeating: RegionStats(), count: boardSize),
            count: boardSize
        )

        // Aggregate over all 9 temporal slices
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                var sumR: Float = 0
                var sumG: Float = 0
                var sumB: Float = 0
                var sumWeight: Float = 0
                var colors: [(r: Float, g: Float, b: Float)] = []

                // Sum over time dimension
                for t in 0..<boardSize {
                    let cell = tensor[t, y, x]
                    if cell.totalWeight > 0 {
                        let (r, g, b) = cell.centroidColor()
                        let rf = Float(r)
                        let gf = Float(g)
                        let bf = Float(b)

                        sumR += rf * cell.totalWeight
                        sumG += gf * cell.totalWeight
                        sumB += bf * cell.totalWeight
                        sumWeight += cell.totalWeight
                        colors.append((rf, gf, bf))
                    }
                }

                if sumWeight > 0 {
                    let meanR = sumR / sumWeight
                    let meanG = sumG / sumWeight
                    let meanB = sumB / sumWeight

                    // Compute variance (spread of colors over time)
                    var variance: Float = 0
                    for (r, g, b) in colors {
                        variance += (r - meanR) * (r - meanR)
                        variance += (g - meanG) * (g - meanG)
                        variance += (b - meanB) * (b - meanB)
                    }
                    if !colors.isEmpty {
                        variance /= Float(colors.count * 3)
                    }

                    stats[y][x].meanIntensity = (meanR + meanG + meanB) / (3.0 * 255.0)
                    stats[y][x].colorVariance = min(1.0, variance / (128.0 * 128.0))
                    stats[y][x].totalWeight = sumWeight
                    stats[y][x].dominantChannel = meanR > meanG && meanR > meanB ? 0 :
                                                  meanG > meanB ? 1 : 2
                }
            }
        }

        return try encodeStats(stats, type: .spatial)
    }

    /// Encode TensorCube729 for the Temporal player (Key provider).
    ///
    /// The 81 frames map to a 9×9 grid (9 groups of 9 frames).
    /// Each cell represents one frame group's activity level.
    /// High motion/change → "Black stones" (high attention).
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Tuple of (spatial features, global features) as MLMultiArrays
    @available(iOS 26.0, *)
    public static func encodeTemporalBoard(
        from tensor: TensorCube729
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {

        // For temporal encoding, we map the 9 time groups to the 9×9 board
        // in a way that preserves temporal locality
        var stats = [[RegionStats]](
            repeating: [RegionStats](repeating: RegionStats(), count: boardSize),
            count: boardSize
        )

        // Aggregate spatially within each time slice
        for t in 0..<boardSize {
            // Map time slice t to board position
            let boardY = t
            let boardX = 4  // Center column initially

            var sumR: Float = 0
            var sumG: Float = 0
            var sumB: Float = 0
            var sumWeight: Float = 0
            var colors: [(r: Float, g: Float, b: Float)] = []

            // Sum over spatial dimensions for this time slice
            for y in 0..<boardSize {
                for x in 0..<boardSize {
                    let cell = tensor[t, y, x]
                    if cell.totalWeight > 0 {
                        let (r, g, b) = cell.centroidColor()
                        let rf = Float(r)
                        let gf = Float(g)
                        let bf = Float(b)

                        sumR += rf * cell.totalWeight
                        sumG += gf * cell.totalWeight
                        sumB += bf * cell.totalWeight
                        sumWeight += cell.totalWeight
                        colors.append((rf, gf, bf))
                    }
                }
            }

            // Compute variance (how much spatial variation in this frame group)
            if sumWeight > 0 {
                let meanR = sumR / sumWeight
                let meanG = sumG / sumWeight
                let meanB = sumB / sumWeight

                var variance: Float = 0
                for (r, g, b) in colors {
                    variance += (r - meanR) * (r - meanR)
                    variance += (g - meanG) * (g - meanG)
                    variance += (b - meanB) * (b - meanB)
                }
                if !colors.isEmpty {
                    variance /= Float(colors.count * 3)
                }

                // Spread the temporal info across the row
                for x in 0..<boardSize {
                    stats[boardY][x].meanIntensity = (meanR + meanG + meanB) / (3.0 * 255.0)
                    stats[boardY][x].colorVariance = min(1.0, variance / (128.0 * 128.0))
                    stats[boardY][x].totalWeight = sumWeight / Float(boardSize)
                }
            }
        }

        return try encodeStats(stats, type: .temporal)
    }

    /// Encode from raw centroid data (without full TensorCube729).
    ///
    /// - Parameters:
    ///   - centroids: 729 RGB color tuples from TensorCube729.centroidColors()
    ///   - type: Whether to encode for spatial or temporal player
    /// - Returns: Tuple of (spatial features, global features) as MLMultiArrays
    public static func encodeFromCentroids(
        _ centroids: [(r: UInt8, g: UInt8, b: UInt8)],
        type: EncodingType
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {

        guard centroids.count == 729 else {
            throw BoardEncoderError.invalidCentroidCount(centroids.count)
        }

        var stats = [[RegionStats]](
            repeating: [RegionStats](repeating: RegionStats(), count: boardSize),
            count: boardSize
        )

        switch type {
        case .spatial:
            // Aggregate over time (outer dimension in centroid ordering)
            for y in 0..<boardSize {
                for x in 0..<boardSize {
                    var colors: [(Float, Float, Float)] = []

                    for t in 0..<boardSize {
                        let idx = t * 81 + y * 9 + x
                        let c = centroids[idx]
                        colors.append((Float(c.r), Float(c.g), Float(c.b)))
                    }

                    stats[y][x] = computeStats(from: colors)
                }
            }

        case .temporal:
            // Aggregate over space, map to rows
            for t in 0..<boardSize {
                var colors: [(Float, Float, Float)] = []

                for y in 0..<boardSize {
                    for x in 0..<boardSize {
                        let idx = t * 81 + y * 9 + x
                        let c = centroids[idx]
                        colors.append((Float(c.r), Float(c.g), Float(c.b)))
                    }
                }

                let rowStats = computeStats(from: colors)
                for x in 0..<boardSize {
                    stats[t][x] = rowStats
                }
            }
        }

        return try encodeStats(stats, type: type)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Private Implementation
    // ═══════════════════════════════════════════════════════════════════════════

    private static func computeStats(
        from colors: [(Float, Float, Float)]
    ) -> RegionStats {
        guard !colors.isEmpty else { return RegionStats() }

        // Compute mean
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0

        for (r, g, b) in colors {
            sumR += r
            sumG += g
            sumB += b
        }

        let n = Float(colors.count)
        let meanR = sumR / n
        let meanG = sumG / n
        let meanB = sumB / n

        // Compute variance
        var variance: Float = 0
        for (r, g, b) in colors {
            variance += (r - meanR) * (r - meanR)
            variance += (g - meanG) * (g - meanG)
            variance += (b - meanB) * (b - meanB)
        }
        variance /= n * 3

        return RegionStats(
            meanIntensity: (meanR + meanG + meanB) / (3.0 * 255.0),
            colorVariance: min(1.0, variance / (128.0 * 128.0)),
            totalWeight: n,
            dominantChannel: meanR > meanG && meanR > meanB ? 0 :
                            meanG > meanB ? 1 : 2
        )
    }

    private static func encodeStats(
        _ stats: [[RegionStats]],
        type: EncodingType
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {

        // Create spatial features array: (1, 22, 9, 9)
        let spatial = try MLMultiArray(
            shape: [1, NSNumber(value: spatialPlanes), NSNumber(value: boardSize), NSNumber(value: boardSize)],
            dataType: .float32
        )

        // Create global features array: (1, 19)
        let global = try MLMultiArray(
            shape: [1, NSNumber(value: globalFeatures)],
            dataType: .float32
        )

        // Initialize all to zero
        for i in 0..<spatial.count {
            spatial[i] = 0
        }
        for i in 0..<global.count {
            global[i] = 0
        }

        // Plane 0: Mask (all 1.0 for valid board)
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                spatial[[0, 0, y, x] as [NSNumber]] = 1.0
            }
        }

        // Plane 1: "Own stones" = high variance regions
        // Plane 2: "Opponent stones" = low variance regions
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                let variance = stats[y][x].colorVariance

                if variance > stoneThreshold {
                    // High variance → own stone (needs attention)
                    spatial[[0, 1, y, x] as [NSNumber]] = 1.0
                } else if variance < stoneThreshold * 0.5 {
                    // Low variance → opponent stone (less attention)
                    spatial[[0, 2, y, x] as [NSNumber]] = 1.0
                }
                // Medium variance → empty intersection
            }
        }

        // Planes 3-5: Encode intensity gradients (optional but helps)
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                let intensity = stats[y][x].meanIntensity
                let variance = stats[y][x].colorVariance

                // Plane 3: Intensity feature
                spatial[[0, 3, y, x] as [NSNumber]] = NSNumber(value: intensity)

                // Plane 4: Variance feature
                spatial[[0, 4, y, x] as [NSNumber]] = NSNumber(value: variance)

                // Plane 5: Combined importance
                spatial[[0, 5, y, x] as [NSNumber]] = NSNumber(value: intensity * variance)
            }
        }

        // Global features
        switch type {
        case .spatial:
            // Japanese rules: komi 5.5 normalized
            global[[0, 0] as [NSNumber]] = NSNumber(value: 5.5 / 14.0)
        case .temporal:
            // Tromp-Taylor rules: komi 7.0 normalized
            global[[0, 0] as [NSNumber]] = NSNumber(value: 7.0 / 14.0)
        }

        return (spatial, global)
    }
}

// MARK: - Errors

/// Errors that can occur during board encoding.
public enum BoardEncoderError: Error, LocalizedError {
    case invalidCentroidCount(Int)
    case featureEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCentroidCount(let count):
            return "Expected 729 centroids, got \(count)"
        case .featureEncodingFailed(let reason):
            return "Feature encoding failed: \(reason)"
        }
    }
}

// MARK: - Debug Extensions

@available(iOS 15.0, macOS 12.0, *)
extension BoardEncoder {

    /// Visualize the encoded board as ASCII art.
    public static func visualizeEncoding(
        spatial: MLMultiArray,
        title: String = "Encoded Board"
    ) -> String {
        var lines = [String]()
        lines.append("╔═══════════════════════════════════════════════════════════════════╗")
        lines.append("║  \(title.padding(toLength: 62, withPad: " ", startingAt: 0)) ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════╣")

        lines.append("║  Own Stones (Plane 1):                    Opp Stones (Plane 2):  ║")

        for y in 0..<boardSize {
            var ownLine = "║    "
            var oppLine = "   "

            for x in 0..<boardSize {
                let own = (spatial[[0, 1, y, x] as [NSNumber]] as! NSNumber).floatValue
                let opp = (spatial[[0, 2, y, x] as [NSNumber]] as! NSNumber).floatValue

                ownLine += own > 0.5 ? "● " : "· "
                oppLine += opp > 0.5 ? "○ " : "· "
            }

            lines.append("\(ownLine)      \(oppLine)      ║")
        }

        lines.append("╚═══════════════════════════════════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}

// MARK: - GamePosition Encoding (MVP1)

@available(iOS 15.0, macOS 12.0, *)
extension BoardEncoder {

    /// Encode a GamePosition into KataGo neural network input format.
    ///
    /// This is the proper way to encode for MVP1: we create actual Go game
    /// positions from the tensor data, then encode those positions.
    ///
    /// - Parameters:
    ///   - position: A Go game position derived from tensor analysis
    /// - Returns: Tuple of (spatial features, global features) as MLMultiArrays
    public static func encodeGamePosition(
        _ position: GamePosition
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {

        // Create spatial features array: (1, 22, 9, 9)
        let spatial = try MLMultiArray(
            shape: [1, NSNumber(value: spatialPlanes), NSNumber(value: boardSize), NSNumber(value: boardSize)],
            dataType: .float32
        )

        // Create global features array: (1, 19)
        let global = try MLMultiArray(
            shape: [1, NSNumber(value: globalFeatures)],
            dataType: .float32
        )

        // Initialize all to zero
        for i in 0..<spatial.count {
            spatial[i] = 0
        }
        for i in 0..<global.count {
            global[i] = 0
        }

        // Plane 0: Mask (all 1.0 for valid board)
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                spatial[[0, 0, y, x] as [NSNumber]] = 1.0
            }
        }

        // Plane 1: Own stones (Black = high importance)
        // Plane 2: Opponent stones (White = low importance)
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                switch position.stone(row: y, col: x) {
                case .black:
                    spatial[[0, 1, y, x] as [NSNumber]] = 1.0
                case .white:
                    spatial[[0, 2, y, x] as [NSNumber]] = 1.0
                case .empty:
                    break  // Already zero
                }
            }
        }

        // Planes 3-10: Move history (if available)
        // KataGo uses 5 history planes for each color
        if !position.moveHistory.isEmpty {
            var blackMoveNum = 0
            var whiteMoveNum = 0

            for (row, col, color) in position.moveHistory.suffix(10) {
                switch color {
                case .black:
                    if blackMoveNum < 5 {
                        let plane = 3 + blackMoveNum
                        spatial[[0, plane, row, col] as [NSNumber]] = 1.0
                        blackMoveNum += 1
                    }
                case .white:
                    if whiteMoveNum < 5 {
                        let plane = 8 + whiteMoveNum
                        spatial[[0, plane, row, col] as [NSNumber]] = 1.0
                        whiteMoveNum += 1
                    }
                case .empty:
                    break
                }
            }
        }

        // Global features
        // Index 0: Komi (normalized to ~0.5)
        global[[0, 0] as [NSNumber]] = NSNumber(value: position.komi / 14.0)

        // Index 1: Rules encoding (0 = Japanese, 1 = Tromp-Taylor)
        let isTrompTaylor = position.komi >= 7.0
        global[[0, 1] as [NSNumber]] = NSNumber(value: isTrompTaylor ? 1.0 : 0.0)

        // Index 2: Color to play (0 = Black, 1 = White)
        global[[0, 2] as [NSNumber]] = NSNumber(value: position.toPlay == .black ? 0.0 : 1.0)

        return (spatial, global)
    }

    /// Encode spatial game from TensorCube729 (convenience method for MVP1).
    ///
    /// Creates a spatial game position and encodes it for KataGo.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Tuple of (spatial features, global features) as MLMultiArrays
    @available(iOS 26.0, *)
    public static func encodeSpatialGame(
        from tensor: TensorCube729
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {
        let position = TensorToGame.createSpatialGame(from: tensor)
        return try encodeGamePosition(position)
    }

    /// Encode temporal game from TensorCube729 (convenience method for MVP1).
    ///
    /// Creates a temporal game position and encodes it for KataGo.
    ///
    /// - Parameter tensor: The 9×9×9 tensor cube
    /// - Returns: Tuple of (spatial features, global features) as MLMultiArrays
    @available(iOS 26.0, *)
    public static func encodeTemporalGame(
        from tensor: TensorCube729
    ) throws -> (spatial: MLMultiArray, global: MLMultiArray) {
        let position = TensorToGame.createTemporalGame(from: tensor)
        return try encodeGamePosition(position)
    }
}
