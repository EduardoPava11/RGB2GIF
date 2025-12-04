//
//  TensorCube729.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  9×9×9 TENSOR FOR PALETTE SELECTION                                       ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  PURPOSE: Build 729 weighted centroids from 81×81×81 voxels               ║
//  ║           These 729 colors drive octree palette selection                 ║
//  ║                                                                           ║
//  ║  KEY INSIGHT: Quantizing 729 colors is 730× faster than 531,441 pixels    ║
//  ║               AND produces better palettes due to center-weighting        ║
//  ║                                                                           ║
//  ║  MATH: Each cell = 9×9 pixels × 9 frames = 729 voxels                     ║
//  ║        Weighted by Gaussian kernel (center = 1.0, edges = 0.14)           ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import QuartzCore
import os.log

private let tensorLogger = Logger(subsystem: "com.rgb2gif", category: "TensorCube729")

// MARK: - TensorCube729

/// 9×9×9 tensor of weighted color centroids for palette generation
/// Each cell aggregates 729 voxels (9×9 pixels × 9 frames)
@available(iOS 26.0, *)
public struct TensorCube729: Sendable {

    // MARK: - Constants

    /// Grid dimension in each axis (9)
    public static let gridDimension = 9

    /// Source dimension (81 pixels, 81 frames)
    public static let sourceDimension = 81

    /// Downsample factor (81 / 9 = 9)
    public static let downsampleFactor = 9

    /// Total cells (9³ = 729)
    public static let totalCells = 729

    /// Voxels per cell (9×9×9 = 729)
    public static let voxelsPerCell = 729

    // MARK: - Cell Structure

    /// A single cell's aggregated color data
    public struct Cell: Sendable {
        /// Weighted sum of red channel
        public var weightedR: Float = 0
        /// Weighted sum of green channel
        public var weightedG: Float = 0
        /// Weighted sum of blue channel
        public var weightedB: Float = 0
        /// Total weight accumulated
        public var totalWeight: Float = 0

        /// Compute final centroid color
        public func centroidColor() -> (r: UInt8, g: UInt8, b: UInt8) {
            guard totalWeight > 0 else { return (0, 0, 0) }
            let r = UInt8(min(255, max(0, Int(weightedR / totalWeight))))
            let g = UInt8(min(255, max(0, Int(weightedG / totalWeight))))
            let b = UInt8(min(255, max(0, Int(weightedB / totalWeight))))
            return (r, g, b)
        }
    }

    // MARK: - Storage

    /// 3D array of cells: [temporal][y][x]
    private var cells: [[[Cell]]]

    // MARK: - Precomputed Weight Kernels

    /// 9×9 Gaussian spatial weight kernel (center = 1.0)
    private static let spatialKernel: [[Float]] = {
        var kernel = [[Float]](repeating: [Float](repeating: 0, count: 9), count: 9)
        let center: Float = 4.0  // Center index (0-8)
        let sigma: Float = 2.5   // Gaussian spread

        for y in 0..<9 {
            for x in 0..<9 {
                let dx = Float(x) - center
                let dy = Float(y) - center
                let distSq = dx * dx + dy * dy
                kernel[y][x] = exp(-distSq / (2 * sigma * sigma))
            }
        }
        return kernel
    }()

    /// 9-element Gaussian temporal weight kernel (center = 1.0)
    private static let temporalKernel: [Float] = {
        var kernel = [Float](repeating: 0, count: 9)
        let center: Float = 4.0
        let sigma: Float = 2.0

        for t in 0..<9 {
            let dt = Float(t) - center
            kernel[t] = exp(-(dt * dt) / (2 * sigma * sigma))
        }
        return kernel
    }()

    // MARK: - Initialization

    /// Create empty tensor
    public init() {
        let dim = Self.gridDimension
        self.cells = Array(
            repeating: Array(
                repeating: Array(repeating: Cell(), count: dim),
                count: dim
            ),
            count: dim
        )
    }

    /// Build tensor from 81 frames (each 81×81 pixels)
    /// - Parameter frames: Array of 81 CGImages, each exactly 81×81
    /// - Throws: RGB2GIFError if frames are invalid
    public init(frames: [CGImage]) throws {
        guard frames.count == Self.sourceDimension else {
            throw RGB2GIFError.wrongFrameCount(got: frames.count, expected: Self.sourceDimension)
        }

        self.init()

        tensorLogger.info("Building TensorCube729 from \(frames.count) frames...")
        let startTime = CACurrentMediaTime()

        // Process each frame
        for (frameIndex, frame) in frames.enumerated() {
            guard frame.width == Self.sourceDimension && frame.height == Self.sourceDimension else {
                tensorLogger.warning("Frame \(frameIndex) is \(frame.width)×\(frame.height), expected 81×81")
                continue
            }

            // Extract pixel data
            guard let pixelData = frame.dataProvider?.data,
                  let data = CFDataGetBytePtr(pixelData) else {
                tensorLogger.warning("Failed to get pixel data for frame \(frameIndex)")
                continue
            }

            let bytesPerRow = frame.bytesPerRow
            let bytesPerPixel = frame.bitsPerPixel / 8

            // Determine which temporal cell this frame belongs to
            let tCell = frameIndex / Self.downsampleFactor
            let tOffset = frameIndex % Self.downsampleFactor

            // Process each pixel
            for py in 0..<Self.sourceDimension {
                for px in 0..<Self.sourceDimension {
                    let offset = py * bytesPerRow + px * bytesPerPixel
                    guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                    let r = Float(data[offset])
                    let g = Float(data[offset + 1])
                    let b = Float(data[offset + 2])

                    // Determine spatial cell
                    let yCell = py / Self.downsampleFactor
                    let xCell = px / Self.downsampleFactor

                    // Offset within cell
                    let yOffset = py % Self.downsampleFactor
                    let xOffset = px % Self.downsampleFactor

                    // Compute combined weight
                    let spatialWeight = Self.spatialKernel[yOffset][xOffset]
                    let temporalWeight = Self.temporalKernel[tOffset]
                    let weight = spatialWeight * temporalWeight

                    // Accumulate weighted color
                    cells[tCell][yCell][xCell].weightedR += r * weight
                    cells[tCell][yCell][xCell].weightedG += g * weight
                    cells[tCell][yCell][xCell].weightedB += b * weight
                    cells[tCell][yCell][xCell].totalWeight += weight
                }
            }
        }

        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        tensorLogger.info("TensorCube729 built in \(String(format: "%.1f", elapsed))ms")
    }

    /// Build tensor from 81 RGB Data arrays (pre-converted, no format confusion)
    /// - Parameter rgbFrames: Array of 81 Data objects, each 81×81×3 bytes (RGB)
    /// - Throws: RGB2GIFError if frames are invalid
    ///
    /// This initializer accepts pre-converted RGB data from FrameFormatConverter,
    /// eliminating any BGRA/RGBA format confusion. Each byte triplet is guaranteed
    /// to be [R, G, B] in that order.
    public init(rgbFrames: [Data]) throws {
        let expectedBytes = Self.sourceDimension * Self.sourceDimension * 3  // 81×81×3 = 19683

        guard rgbFrames.count == Self.sourceDimension else {
            throw RGB2GIFError.wrongFrameCount(got: rgbFrames.count, expected: Self.sourceDimension)
        }

        self.init()

        tensorLogger.info("Building TensorCube729 from \(rgbFrames.count) RGB Data arrays...")
        let startTime = CACurrentMediaTime()

        for (frameIndex, rgbData) in rgbFrames.enumerated() {
            guard rgbData.count == expectedBytes else {
                tensorLogger.error("Frame \(frameIndex) has \(rgbData.count) bytes, expected \(expectedBytes)")
                throw RGB2GIFError.cborExportFailed("RGB frame \(frameIndex) size mismatch: \(rgbData.count) vs \(expectedBytes)")
            }

            // Which temporal cell and offset
            let tCell = frameIndex / Self.downsampleFactor
            let tOffset = frameIndex % Self.downsampleFactor

            // Process each pixel
            for py in 0..<Self.sourceDimension {
                for px in 0..<Self.sourceDimension {
                    let pixelIndex = py * Self.sourceDimension + px
                    let offset = pixelIndex * 3

                    // RGB data is guaranteed to be [R, G, B] order
                    let r = Float(rgbData[offset])
                    let g = Float(rgbData[offset + 1])
                    let b = Float(rgbData[offset + 2])

                    // Spatial cell and offset
                    let yCell = py / Self.downsampleFactor
                    let xCell = px / Self.downsampleFactor
                    let yOffset = py % Self.downsampleFactor
                    let xOffset = px % Self.downsampleFactor

                    // Combined Gaussian weight
                    let spatialWeight = Self.spatialKernel[yOffset][xOffset]
                    let temporalWeight = Self.temporalKernel[tOffset]
                    let weight = spatialWeight * temporalWeight

                    // Accumulate
                    cells[tCell][yCell][xCell].weightedR += r * weight
                    cells[tCell][yCell][xCell].weightedG += g * weight
                    cells[tCell][yCell][xCell].weightedB += b * weight
                    cells[tCell][yCell][xCell].totalWeight += weight
                }
            }
        }

        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        tensorLogger.info("TensorCube729 built from RGB Data in \(String(format: "%.1f", elapsed))ms")
    }

    // MARK: - Public API

    /// Get all 729 centroid colors for palette generation
    /// - Returns: Array of 729 RGB color tuples
    public func centroidColors() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = []
        colors.reserveCapacity(Self.totalCells)

        for t in 0..<Self.gridDimension {
            for y in 0..<Self.gridDimension {
                for x in 0..<Self.gridDimension {
                    colors.append(cells[t][y][x].centroidColor())
                }
            }
        }

        return colors
    }

    /// Access a specific cell
    public subscript(t: Int, y: Int, x: Int) -> Cell {
        get { cells[t][y][x] }
        set { cells[t][y][x] = newValue }
    }

    /// Get a temporal layer (9×9 spatial grid)
    public func layer(_ t: Int) -> [[Cell]] {
        return cells[t]
    }

    /// Statistics for debugging
    public func statistics() -> TensorStatistics {
        var totalWeight: Float = 0
        var minWeight: Float = .infinity
        var maxWeight: Float = 0
        var nonZeroCells = 0

        for t in 0..<Self.gridDimension {
            for y in 0..<Self.gridDimension {
                for x in 0..<Self.gridDimension {
                    let w = cells[t][y][x].totalWeight
                    totalWeight += w
                    if w > 0 {
                        nonZeroCells += 1
                        minWeight = min(minWeight, w)
                        maxWeight = max(maxWeight, w)
                    }
                }
            }
        }

        return TensorStatistics(
            totalWeight: totalWeight,
            averageWeight: totalWeight / Float(Self.totalCells),
            minWeight: minWeight == .infinity ? 0 : minWeight,
            maxWeight: maxWeight,
            nonZeroCells: nonZeroCells
        )
    }
}

// MARK: - Statistics

@available(iOS 26.0, *)
public struct TensorStatistics: Sendable {
    public let totalWeight: Float
    public let averageWeight: Float
    public let minWeight: Float
    public let maxWeight: Float
    public let nonZeroCells: Int
}
