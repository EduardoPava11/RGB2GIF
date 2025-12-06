//
//  VoxelCube729.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  VOXEL CUBE 729 - THE 9×9×9 SPATIOTEMPORAL GAME BOARD                     ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  MATHEMATICAL FOUNDATION:                                                 ║
//  ║  ────────────────────────                                                 ║
//  ║  729 = 9³ = 9 × 9 × 9 = 3⁶                                                ║
//  ║                                                                           ║
//  ║  The 81×81×81 voxel cube (531,441 voxels) maps to a 9×9×9 game board:     ║
//  ║  • Each 81×81 frame → 9×9 grid (9 rows × 9 cols)                          ║
//  ║  • Each grid cell = 9×9 pixels = 81 voxels                                ║
//  ║  • 81 frames → 9 temporal layers (9 frames per layer)                     ║
//  ║  • 9×9 spatial × 9 temporal = 729 cells                                   ║
//  ║                                                                           ║
//  ║  EACH CELL CONTAINS:                                                      ║
//  ║  ───────────────────                                                      ║
//  ║  • 9×9 = 81 pixels per frame                                              ║
//  ║  • 9 frames per temporal segment                                          ║
//  ║  • 81 × 9 = 729 voxels per cell                                           ║
//  ║  • 729 cells × 729 voxels/cell = 531,441 total voxels ✓                   ║
//  ║                                                                           ║
//  ║  GO GAME MAPPING:                                                         ║
//  ║  ────────────────                                                         ║
//  ║  • 9×9 board = standard small GO board                                    ║
//  ║  • 9 temporal layers = 9 "moves" in the game                              ║
//  ║  • Cell color = stone color (palette index)                               ║
//  ║  • Groups = connected regions of similar colors                           ║
//  ║                                                                           ║
//  ║  MVP0 → MVP1 BRIDGE:                                                      ║
//  ║  ───────────────────                                                      ║
//  ║  • MVP0: Capture raw 81×81×81 → GIF                                       ║
//  ║  • MVP1: Also build VoxelCube729 for game analysis                        ║
//  ║  • Spatial GO: Clustering game on 9×9 board                               ║
//  ║  • Temporal GO: Evolution of palette across 9 layers                      ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import os.log

private let voxelLogger = Logger(subsystem: "com.rgb2gif", category: "VoxelCube729")

// MARK: - Constants

/// The magic numbers that define our voxel space
public enum VoxelConstants {
    /// Original cube dimension (81 = 3⁴)
    public static let sourceDimension = 81

    /// Compressed grid dimension (9 = 3²)
    public static let gridDimension = 9

    /// Downsampling factor (81/9 = 9)
    public static let downsampleFactor = 9

    /// Total cells in compressed cube (9³ = 729)
    public static let totalCells = 729

    /// Voxels per cell (9×9×9 = 729)
    public static let voxelsPerCell = 729

    /// Total voxels in source cube (81³ = 531,441)
    public static let totalSourceVoxels = 531_441

    /// Palette size (2⁸ = 256)
    public static let paletteSize = 256
}

// MARK: - Cell Data Structure

/// Data for a single cell in the 9×9×9 cube
/// Each cell represents 729 voxels from the source 81×81×81 cube
@available(iOS 26.0, *)
public struct VoxelCell {

    // MARK: - Color Statistics

    /// Dominant palette index (most frequent color in this cell)
    public var dominantIndex: UInt8 = 0

    /// Second most common palette index (for edge detection)
    public var secondaryIndex: UInt8 = 0

    /// Average RGB color of all voxels in this cell
    public var averageColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)

    /// Color variance (0.0 = uniform, 1.0 = maximum variation)
    public var colorVariance: Float = 0.0

    // MARK: - Histogram (compact)

    /// Top 4 palette indices and their frequencies (covers most cases)
    /// Format: [(index, count), ...]
    public var topColors: [(index: UInt8, count: UInt16)] = []

    // MARK: - GO Game Properties

    /// "Stone color" for GO game mechanics (derived from dominant index)
    public var stoneColor: VoxelStoneColor {
        // Map 256 palette indices to 3 stone colors
        // Black: indices 0-84, White: indices 85-169, Empty: indices 170-255
        if dominantIndex < 85 {
            return .black
        } else if dominantIndex < 170 {
            return .white
        } else {
            return .empty
        }
    }

    /// Liberty count (for GO game mechanics)
    public var liberties: UInt8 = 0

    /// Group ID (connected component label)
    public var groupID: UInt16 = 0

    // MARK: - Temporal Properties

    /// Motion magnitude (how much this cell changed from previous layer)
    public var motionMagnitude: Float = 0.0

    /// Temporal gradient direction
    public var temporalGradient: Float = 0.0

    public init() {}
}

/// Stone colors for Voxel GO game mechanics (distinct from KataGo's StoneColor)
public enum VoxelStoneColor: UInt8, CaseIterable, Sendable {
    case empty = 0
    case black = 1
    case white = 2
}

// MARK: - VoxelCube729

/// The 9×9×9 spatiotemporal cube structure
/// This is the bridge between MVP0's raw capture and MVP1's game mechanics
@available(iOS 26.0, *)
public struct VoxelCube729 {

    // MARK: - Storage

    /// 3D array of cells: [temporal][y][x] or [z][y][x]
    /// z=0 is earliest time, z=8 is latest time
    public var cells: [[[VoxelCell]]]

    /// Global palette (256 colors as ARGB)
    public var palette: [UInt32]

    /// Timestamp of cube creation
    public let timestamp: Date

    /// Source frame count (should be 81)
    public let sourceFrameCount: Int

    // MARK: - Initialization

    /// Create empty cube
    public init() {
        let dim = VoxelConstants.gridDimension
        self.cells = Array(
            repeating: Array(
                repeating: Array(repeating: VoxelCell(), count: dim),
                count: dim
            ),
            count: dim
        )
        self.palette = Array(repeating: 0, count: VoxelConstants.paletteSize)
        self.timestamp = Date()
        self.sourceFrameCount = VoxelConstants.sourceDimension
    }

    /// Create cube from 81 frames and palette
    /// - Parameters:
    ///   - frames: Array of 81 CGImages (each 81×81)
    ///   - palette: 256-color palette as ARGB values
    ///   - indices: 81 frames of palette indices (each 81×81)
    public init(frames: [CGImage], palette: [UInt32], indices: [[UInt8]]) {
        self.init()
        self.palette = palette

        guard frames.count == VoxelConstants.sourceDimension,
              indices.count == VoxelConstants.sourceDimension else {
            voxelLogger.error("Invalid input: expected 81 frames, got \(frames.count)")
            return
        }

        buildFromFrames(indices: indices)
    }

    // MARK: - Building from Source Data

    /// Build the 9×9×9 cube from 81 frames of palette indices
    private mutating func buildFromFrames(indices: [[UInt8]]) {
        let dim = VoxelConstants.gridDimension  // 9
        let factor = VoxelConstants.downsampleFactor  // 9

        voxelLogger.info("Building VoxelCube729 from \(indices.count) frames")

        // For each cell in the 9×9×9 cube
        for z in 0..<dim {  // temporal layer
            for y in 0..<dim {  // row
                for x in 0..<dim {  // column
                    var cell = VoxelCell()
                    var histogram = [UInt8: Int]()
                    var totalR = 0, totalG = 0, totalB = 0
                    var voxelCount = 0

                    // Aggregate voxels for this cell
                    // Temporal range: frames [z*9, z*9+8]
                    // Spatial range: pixels [y*9, y*9+8] × [x*9, x*9+8]
                    let frameStart = z * factor
                    let frameEnd = min(frameStart + factor, indices.count)

                    for frameIdx in frameStart..<frameEnd {
                        let frameIndices = indices[frameIdx]

                        for dy in 0..<factor {
                            for dx in 0..<factor {
                                let py = y * factor + dy
                                let px = x * factor + dx
                                let pixelIdx = py * VoxelConstants.sourceDimension + px

                                guard pixelIdx < frameIndices.count else { continue }

                                let paletteIdx = frameIndices[pixelIdx]
                                histogram[paletteIdx, default: 0] += 1

                                // Accumulate RGB from palette
                                let color = palette[Int(paletteIdx)]
                                totalR += Int((color >> 16) & 0xFF)
                                totalG += Int((color >> 8) & 0xFF)
                                totalB += Int(color & 0xFF)
                                voxelCount += 1
                            }
                        }
                    }

                    // Calculate statistics
                    if voxelCount > 0 {
                        cell.averageColor = (
                            r: UInt8(totalR / voxelCount),
                            g: UInt8(totalG / voxelCount),
                            b: UInt8(totalB / voxelCount)
                        )

                        // Find top colors
                        let sorted = histogram.sorted { $0.value > $1.value }
                        cell.topColors = sorted.prefix(4).map { (index: $0.key, count: UInt16($0.value)) }

                        if let dominant = sorted.first {
                            cell.dominantIndex = dominant.key
                        }
                        if sorted.count > 1 {
                            cell.secondaryIndex = sorted[1].key
                        }

                        // Calculate variance
                        let dominantCount = histogram[cell.dominantIndex] ?? 0
                        cell.colorVariance = 1.0 - Float(dominantCount) / Float(voxelCount)
                    }

                    cells[z][y][x] = cell
                }
            }
        }

        // Calculate motion between temporal layers
        calculateMotion()

        // Calculate GO liberties and groups
        calculateGOProperties()

        voxelLogger.info("VoxelCube729 built: 729 cells from 531,441 voxels")
    }

    // MARK: - Motion Analysis

    /// Calculate motion magnitude between temporal layers
    private mutating func calculateMotion() {
        let dim = VoxelConstants.gridDimension

        for z in 1..<dim {  // Skip first layer (no previous)
            for y in 0..<dim {
                for x in 0..<dim {
                    let current = cells[z][y][x]
                    let previous = cells[z-1][y][x]

                    // Calculate color difference
                    let dr = Float(current.averageColor.r) - Float(previous.averageColor.r)
                    let dg = Float(current.averageColor.g) - Float(previous.averageColor.g)
                    let db = Float(current.averageColor.b) - Float(previous.averageColor.b)

                    let magnitude = sqrt(dr*dr + dg*dg + db*db) / 441.67  // Normalize to 0-1
                    cells[z][y][x].motionMagnitude = magnitude
                    cells[z][y][x].temporalGradient = magnitude - cells[z-1][y][x].motionMagnitude
                }
            }
        }
    }

    // MARK: - GO Game Properties

    /// Calculate liberties and group IDs for GO game mechanics
    private mutating func calculateGOProperties() {
        let dim = VoxelConstants.gridDimension
        var nextGroupID: UInt16 = 1

        // For each temporal layer, calculate GO properties
        for z in 0..<dim {
            // Reset group IDs for this layer
            for y in 0..<dim {
                for x in 0..<dim {
                    cells[z][y][x].groupID = 0
                    cells[z][y][x].liberties = 0
                }
            }

            // Flood fill to identify groups
            for y in 0..<dim {
                for x in 0..<dim {
                    if cells[z][y][x].groupID == 0 && cells[z][y][x].stoneColor != .empty {
                        floodFillGroup(z: z, startY: y, startX: x, groupID: nextGroupID)
                        nextGroupID += 1
                    }
                }
            }

            // Calculate liberties for each group
            calculateLibertiesForLayer(z: z)
        }
    }

    /// Flood fill to identify connected groups
    private mutating func floodFillGroup(z: Int, startY: Int, startX: Int, groupID: UInt16) {
        let dim = VoxelConstants.gridDimension
        let targetColor = cells[z][startY][startX].stoneColor

        var stack = [(y: startY, x: startX)]

        while !stack.isEmpty {
            let (y, x) = stack.removeLast()

            guard y >= 0 && y < dim && x >= 0 && x < dim else { continue }
            guard cells[z][y][x].groupID == 0 else { continue }
            guard cells[z][y][x].stoneColor == targetColor else { continue }

            cells[z][y][x].groupID = groupID

            // Add neighbors
            stack.append((y: y-1, x: x))
            stack.append((y: y+1, x: x))
            stack.append((y: y, x: x-1))
            stack.append((y: y, x: x+1))
        }
    }

    /// Calculate liberties for all groups in a layer
    private mutating func calculateLibertiesForLayer(z: Int) {
        let dim = VoxelConstants.gridDimension
        var groupLiberties = [UInt16: Set<Int>]()  // groupID -> set of liberty positions

        for y in 0..<dim {
            for x in 0..<dim {
                let cell = cells[z][y][x]
                guard cell.stoneColor != .empty else { continue }

                // Check neighbors for liberties
                let neighbors = [(y-1, x), (y+1, x), (y, x-1), (y, x+1)]
                for (ny, nx) in neighbors {
                    guard ny >= 0 && ny < dim && nx >= 0 && nx < dim else { continue }

                    if cells[z][ny][nx].stoneColor == .empty {
                        let libertyPos = ny * dim + nx
                        groupLiberties[cell.groupID, default: []].insert(libertyPos)
                    }
                }
            }
        }

        // Assign liberty counts
        for y in 0..<dim {
            for x in 0..<dim {
                let groupID = cells[z][y][x].groupID
                if groupID > 0, let liberties = groupLiberties[groupID] {
                    cells[z][y][x].liberties = UInt8(min(liberties.count, 255))
                }
            }
        }
    }

    // MARK: - Accessors

    /// Get cell at position
    public subscript(z: Int, y: Int, x: Int) -> VoxelCell {
        get { cells[z][y][x] }
        set { cells[z][y][x] = newValue }
    }

    /// Get a single temporal layer as 9×9 grid
    public func layer(_ z: Int) -> [[VoxelCell]] {
        return cells[z]
    }

    /// Get all cells as flat array (for neural network input)
    public func flatCells() -> [VoxelCell] {
        return cells.flatMap { $0.flatMap { $0 } }
    }

    /// Get dominant indices as flat array (for palette analysis)
    public func dominantIndices() -> [UInt8] {
        return flatCells().map { $0.dominantIndex }
    }

    /// Get stone colors as 9×9×9 tensor (for GO game)
    public func stoneTensor() -> [[[VoxelStoneColor]]] {
        return cells.map { layer in
            layer.map { row in
                row.map { $0.stoneColor }
            }
        }
    }

    // MARK: - Statistics

    /// Calculate overall statistics for the cube
    public func statistics() -> CubeStatistics {
        let flat = flatCells()

        let avgVariance = flat.map { $0.colorVariance }.reduce(0, +) / Float(flat.count)
        let avgMotion = flat.map { $0.motionMagnitude }.reduce(0, +) / Float(flat.count)

        var stoneDistribution: [VoxelStoneColor: Int] = [.empty: 0, .black: 0, .white: 0]
        for cell in flat {
            stoneDistribution[cell.stoneColor, default: 0] += 1
        }

        let uniqueGroups = Set(flat.map { $0.groupID }).count - 1  // Subtract 1 for groupID 0

        return CubeStatistics(
            averageColorVariance: avgVariance,
            averageMotionMagnitude: avgMotion,
            stoneDistribution: stoneDistribution,
            uniqueGroupCount: uniqueGroups
        )
    }
}

// MARK: - Statistics

@available(iOS 26.0, *)
public struct CubeStatistics {
    public let averageColorVariance: Float
    public let averageMotionMagnitude: Float
    public let stoneDistribution: [VoxelStoneColor: Int]
    public let uniqueGroupCount: Int

    public var description: String {
        """
        VoxelCube729 Statistics:
        ├── Color Variance: \(String(format: "%.2f", averageColorVariance))
        ├── Motion Magnitude: \(String(format: "%.2f", averageMotionMagnitude))
        ├── Stone Distribution:
        │   ├── Empty: \(stoneDistribution[.empty] ?? 0)
        │   ├── Black: \(stoneDistribution[.black] ?? 0)
        │   └── White: \(stoneDistribution[.white] ?? 0)
        └── Unique Groups: \(uniqueGroupCount)
        """
    }
}

// MARK: - Serialization

@available(iOS 26.0, *)
extension VoxelCube729 {

    /// Serialize to compact binary format for storage/transmission
    /// Format: [timestamp:8][palette:1024][cells:729×cellSize]
    public func serialize() -> Data {
        var data = Data()

        // Timestamp (8 bytes)
        var timestamp = self.timestamp.timeIntervalSince1970
        data.append(Data(bytes: &timestamp, count: 8))

        // Palette (256 × 4 = 1024 bytes)
        for color in palette {
            var c = color
            data.append(Data(bytes: &c, count: 4))
        }

        // Cells (729 cells, each ~16 bytes)
        for z in 0..<VoxelConstants.gridDimension {
            for y in 0..<VoxelConstants.gridDimension {
                for x in 0..<VoxelConstants.gridDimension {
                    let cell = cells[z][y][x]
                    data.append(cell.dominantIndex)
                    data.append(cell.secondaryIndex)
                    data.append(cell.averageColor.r)
                    data.append(cell.averageColor.g)
                    data.append(cell.averageColor.b)
                    data.append(cell.liberties)

                    var groupID = cell.groupID
                    data.append(Data(bytes: &groupID, count: 2))

                    var variance = cell.colorVariance
                    data.append(Data(bytes: &variance, count: 4))

                    var motion = cell.motionMagnitude
                    data.append(Data(bytes: &motion, count: 4))
                }
            }
        }

        return data
    }

    /// Deserialize from binary format
    public static func deserialize(from data: Data) -> VoxelCube729? {
        guard data.count >= 8 + 1024 + (729 * 16) else { return nil }

        var cube = VoxelCube729()
        var offset = 0

        // Skip timestamp for now
        offset = 8

        // Read palette
        for i in 0..<256 {
            let color = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            cube.palette[i] = color
            offset += 4
        }

        // Read cells
        for z in 0..<VoxelConstants.gridDimension {
            for y in 0..<VoxelConstants.gridDimension {
                for x in 0..<VoxelConstants.gridDimension {
                    var cell = VoxelCell()
                    cell.dominantIndex = data[offset]; offset += 1
                    cell.secondaryIndex = data[offset]; offset += 1
                    cell.averageColor.r = data[offset]; offset += 1
                    cell.averageColor.g = data[offset]; offset += 1
                    cell.averageColor.b = data[offset]; offset += 1
                    cell.liberties = data[offset]; offset += 1

                    cell.groupID = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }
                    offset += 2

                    cell.colorVariance = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                    offset += 4

                    cell.motionMagnitude = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                    offset += 4

                    cube.cells[z][y][x] = cell
                }
            }
        }

        return cube
    }
}
