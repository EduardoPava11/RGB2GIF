//
//  VoxelGIF81Adapter.swift
//  RGB2GIF
//
//  ============================================================================
//  VOXEL GIF81 ADAPTER - Bridge Between 81³ Pipeline and Voxel Visualization
//  ============================================================================
//
//  PURPOSE: Connect the new 81×81×81 GIF pipeline with the existing VoxelRenderer.
//           This preserves the 3D voxel visualization innovation while using
//           the new spatial indexing architecture.
//
//  THE VOXEL INNOVATION
//  ---------------------
//  A GIF is traditionally viewed as 2D animation over time. But an 81×81×81 GIF
//  can also be interpreted as a 3D DATA CUBE:
//
//    X-axis (0-80): Horizontal pixel position
//    Y-axis (0-80): Vertical pixel position
//    Z-axis (0-80): Frame number (time)
//
//  This cube can be:
//  - Rendered as a 3D voxel cloud in Metal
//  - Sliced along any axis (XY = frame, XZ = vertical timeline, YZ = horizontal timeline)
//  - Rotated and inspected from any angle
//  - Exported as 3D mesh (OBJ, PLY) for external tools
//
//  WHY 81 (NOT 80)?
//  -----------------
//  81 = 9 × 9 = potential GO board compatibility
//  81³ = 531,441 voxels = manageable for real-time rendering
//  80 was arbitrary; 81 is intentional
//
//  COMPATIBILITY
//  -------------
//  The existing VoxelRenderer expects VoxelGIFProcessor.VoxelCube with dimension
//  enum values. This adapter creates a compatible structure from the new pipeline
//  output, mapping 81 to a new dimension case.
//
//  ============================================================================

import Foundation
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "VoxelGIF81Adapter")

// MARK: - Voxel GIF81 Adapter

/// Adapts the 81×81×81 GIF pipeline output for use with VoxelRenderer.
/// This preserves the 3D voxel visualization capability while using the new
/// composable palette architecture.
@available(iOS 26.0, *)
public struct VoxelGIF81Adapter {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Types
    // ════════════════════════════════════════════════════════════════════════

    /// Extended dimension enum that includes 81
    public enum VoxelDimension81: Int, Sendable {
        case gif81 = 81   // 81×81×81 (composable GIF format)
        case small = 80   // 80×80×80 (legacy)
        case large = 128  // 128×128×128 (high resolution)

        public var frameCount: Int { rawValue }
        public var resolution: CGSize {
            CGSize(width: rawValue, height: rawValue)
        }
        public var totalVoxels: Int {
            rawValue * rawValue * rawValue
        }
    }

    /// Voxel cube structure for 81³ GIFs
    public struct VoxelCube81: Sendable {
        public let dimension: VoxelDimension81
        public let frames: [ProcessedFrame81]
        public let palette: [(r: UInt8, g: UInt8, b: UInt8)]
        public let metadata: Metadata81

        /// Single frame data
        public struct ProcessedFrame81: Sendable {
            public let indexedPixels: [UInt8]  // 6561 indices per frame
            public let timestamp: TimeInterval
        }

        /// Cube metadata
        public struct Metadata81: Sendable {
            public let captureDate: Date
            public let duration: TimeInterval
            public let fps: Double
            public let gifURL: URL?
        }

        /// Get voxel color at (x, y, t)
        ///
        /// Returns the RGB color at the specified 3D position.
        ///
        /// - Parameters:
        ///   - x: Horizontal position (0-80)
        ///   - y: Vertical position (0-80)
        ///   - t: Frame/time position (0-80)
        /// - Returns: RGB color as packed UInt32 (0x00RRGGBB)
        public func voxelAt(x: Int, y: Int, t: Int) -> UInt32? {
            guard t < frames.count,
                  x < dimension.rawValue,
                  y < dimension.rawValue else { return nil }

            let frame = frames[t]
            let pixelIndex = y * dimension.rawValue + x
            guard pixelIndex < frame.indexedPixels.count else { return nil }

            let paletteIndex = Int(frame.indexedPixels[pixelIndex])
            guard paletteIndex < palette.count else { return nil }

            let color = palette[paletteIndex]
            return (UInt32(color.r) << 16) | (UInt32(color.g) << 8) | UInt32(color.b)
        }

        /// Get voxel as RGBA for Metal rendering
        public func voxelRGBA(x: Int, y: Int, t: Int) -> (r: Float, g: Float, b: Float, a: Float)? {
            guard let color = voxelAt(x: x, y: y, t: t) else { return nil }

            return (
                r: Float((color >> 16) & 0xFF) / 255.0,
                g: Float((color >> 8) & 0xFF) / 255.0,
                b: Float(color & 0xFF) / 255.0,
                a: 1.0
            )
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Conversion from Pipeline
    // ════════════════════════════════════════════════════════════════════════

    /// Create a VoxelCube81 from pipeline output.
    ///
    /// This converts the GIF81Pipeline's indexed frames and palette into
    /// a structure suitable for 3D voxel rendering.
    ///
    /// - Parameters:
    ///   - frames: 81 indexed frames (each 6561 UInt8 indices)
    ///   - palette: 256-color palette
    ///   - gifURL: Optional URL of the generated GIF
    /// - Returns: VoxelCube81 ready for rendering
    public static func createVoxelCube(
        from frames: [[UInt8]],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        gifURL: URL? = nil
    ) throws -> VoxelCube81 {

        // Validate inputs
        guard frames.count == 81 else {
            throw AdapterError.wrongFrameCount(expected: 81, actual: frames.count)
        }

        guard palette.count == 256 else {
            throw AdapterError.wrongPaletteSize(expected: 256, actual: palette.count)
        }

        for (i, frame) in frames.enumerated() {
            guard frame.count == 6561 else {
                throw AdapterError.wrongFrameSize(frame: i, expected: 6561, actual: frame.count)
            }
        }

        // Convert frames
        var processedFrames = [VoxelCube81.ProcessedFrame81]()
        processedFrames.reserveCapacity(81)

        for (i, frame) in frames.enumerated() {
            let timestamp = Double(i) * (Double(GIF81Writer.frameDelay) / 100.0)
            processedFrames.append(VoxelCube81.ProcessedFrame81(
                indexedPixels: frame,
                timestamp: timestamp
            ))
        }

        // Create metadata
        let totalDuration = Double(81) * (Double(GIF81Writer.frameDelay) / 100.0)
        let fps = 100.0 / Double(GIF81Writer.frameDelay)

        let metadata = VoxelCube81.Metadata81(
            captureDate: Date(),
            duration: totalDuration,
            fps: fps,
            gifURL: gifURL
        )

        logger.info("VoxelGIF81Adapter: Created 81³ voxel cube (531,441 voxels)")

        return VoxelCube81(
            dimension: .gif81,
            frames: processedFrames,
            palette: palette,
            metadata: metadata
        )
    }

    /// Load a VoxelCube81 from an existing GIF file.
    ///
    /// Parses the GIF, extracts palette and indexed frames, and creates
    /// a voxel cube structure.
    ///
    /// - Parameter url: URL of the GIF file
    /// - Returns: VoxelCube81 ready for rendering
    public static func loadFromGIF(at url: URL) throws -> VoxelCube81 {
        let data = try Data(contentsOf: url)

        // Validate using GIF81Validator
        let validation = GIF81Validator.validate(data: data)
        guard validation.isValid else {
            throw AdapterError.invalidGIF(validation.errors)
        }

        // Extract palette
        let palette = try PaletteSwapper.extractPalette(from: data)

        // Parse frames (this is a simplified parser - full implementation would need LZW decoding)
        // For now, this is a placeholder that throws an error
        // A complete implementation would use LZWDecoder to extract frame indices

        throw AdapterError.gifParsingNotImplemented
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Voxel Data Export
    // ════════════════════════════════════════════════════════════════════════

    /// Export voxel cube as raw binary data for external 3D tools.
    ///
    /// Format: Repeated (x: Float32, y: Float32, z: Float32, r: Float32, g: Float32, b: Float32, a: Float32)
    ///
    /// - Parameters:
    ///   - cube: The voxel cube to export
    ///   - skipTransparent: Skip voxels with very low luminance (default: true)
    /// - Returns: Binary data suitable for point cloud rendering
    public static func exportAsPointCloud(
        _ cube: VoxelCube81,
        skipTransparent: Bool = true
    ) -> Data {
        var data = Data()
        let dim = Float(cube.dimension.rawValue)

        for t in 0..<cube.dimension.rawValue {
            for y in 0..<cube.dimension.rawValue {
                for x in 0..<cube.dimension.rawValue {
                    guard let rgba = cube.voxelRGBA(x: x, y: y, t: t) else { continue }

                    // Skip very dark voxels if requested
                    if skipTransparent {
                        let luminance = 0.299 * rgba.r + 0.587 * rgba.g + 0.114 * rgba.b
                        if luminance < 0.05 { continue }
                    }

                    // Normalize position to -0.5...0.5 range
                    var px = Float(x) / dim - 0.5
                    var py = Float(y) / dim - 0.5
                    var pz = Float(t) / dim - 0.5

                    data.append(Data(bytes: &px, count: 4))
                    data.append(Data(bytes: &py, count: 4))
                    data.append(Data(bytes: &pz, count: 4))

                    var r = rgba.r
                    var g = rgba.g
                    var b = rgba.b
                    var a = rgba.a

                    data.append(Data(bytes: &r, count: 4))
                    data.append(Data(bytes: &g, count: 4))
                    data.append(Data(bytes: &b, count: 4))
                    data.append(Data(bytes: &a, count: 4))
                }
            }
        }

        logger.info("VoxelGIF81Adapter: Exported point cloud (\(data.count) bytes)")
        return data
    }

    /// Export voxel cube as PLY file (Polygon File Format).
    ///
    /// PLY is widely supported by 3D modeling software (Blender, MeshLab, etc.)
    ///
    /// - Parameter cube: The voxel cube to export
    /// - Returns: PLY file data as string
    public static func exportAsPLY(_ cube: VoxelCube81) -> String {
        var points: [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)] = []
        let dim = Float(cube.dimension.rawValue)

        for t in 0..<cube.dimension.rawValue {
            for y in 0..<cube.dimension.rawValue {
                for x in 0..<cube.dimension.rawValue {
                    guard let color = cube.voxelAt(x: x, y: y, t: t) else { continue }

                    let r = UInt8((color >> 16) & 0xFF)
                    let g = UInt8((color >> 8) & 0xFF)
                    let b = UInt8(color & 0xFF)

                    // Skip very dark voxels
                    let luminance = 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
                    if luminance < 13 { continue }  // ~5% of 255

                    let px = Float(x) / dim - 0.5
                    let py = Float(y) / dim - 0.5
                    let pz = Float(t) / dim - 0.5

                    points.append((px, py, pz, r, g, b))
                }
            }
        }

        // Build PLY header
        var ply = """
        ply
        format ascii 1.0
        comment Generated by RGB2GIF VoxelGIF81Adapter
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """

        // Add vertices
        for point in points {
            ply += String(format: "%.6f %.6f %.6f %d %d %d\n",
                         point.x, point.y, point.z, point.r, point.g, point.b)
        }

        logger.info("VoxelGIF81Adapter: Exported PLY with \(points.count) vertices")
        return ply
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Slice Extraction
    // ════════════════════════════════════════════════════════════════════════

    /// Extract a 2D slice along the XY plane (single frame).
    ///
    /// - Parameters:
    ///   - cube: Source voxel cube
    ///   - t: Frame index (0-80)
    /// - Returns: 81×81 array of palette indices
    public static func sliceXY(_ cube: VoxelCube81, at t: Int) -> [UInt8]? {
        guard t < cube.frames.count else { return nil }
        return cube.frames[t].indexedPixels
    }

    /// Extract a 2D slice along the XZ plane (horizontal timeline).
    ///
    /// - Parameters:
    ///   - cube: Source voxel cube
    ///   - y: Row index (0-80)
    /// - Returns: 81×81 array where rows are X positions and columns are time
    public static func sliceXZ(_ cube: VoxelCube81, at y: Int) -> [UInt8]? {
        guard y < cube.dimension.rawValue else { return nil }

        var slice = [UInt8](repeating: 0, count: 81 * 81)

        for t in 0..<81 {
            for x in 0..<81 {
                let pixelIndex = y * 81 + x
                if pixelIndex < cube.frames[t].indexedPixels.count {
                    slice[t * 81 + x] = cube.frames[t].indexedPixels[pixelIndex]
                }
            }
        }

        return slice
    }

    /// Extract a 2D slice along the YZ plane (vertical timeline).
    ///
    /// - Parameters:
    ///   - cube: Source voxel cube
    ///   - x: Column index (0-80)
    /// - Returns: 81×81 array where rows are Y positions and columns are time
    public static func sliceYZ(_ cube: VoxelCube81, at x: Int) -> [UInt8]? {
        guard x < cube.dimension.rawValue else { return nil }

        var slice = [UInt8](repeating: 0, count: 81 * 81)

        for t in 0..<81 {
            for y in 0..<81 {
                let pixelIndex = y * 81 + x
                if pixelIndex < cube.frames[t].indexedPixels.count {
                    slice[t * 81 + y] = cube.frames[t].indexedPixels[pixelIndex]
                }
            }
        }

        return slice
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
extension VoxelGIF81Adapter {

    /// Errors that can occur during voxel adaptation
    public enum AdapterError: Error, LocalizedError {
        case wrongFrameCount(expected: Int, actual: Int)
        case wrongPaletteSize(expected: Int, actual: Int)
        case wrongFrameSize(frame: Int, expected: Int, actual: Int)
        case invalidGIF([String])
        case gifParsingNotImplemented

        public var errorDescription: String? {
            switch self {
            case .wrongFrameCount(let expected, let actual):
                return "Expected \(expected) frames, got \(actual)"
            case .wrongPaletteSize(let expected, let actual):
                return "Expected \(expected) palette colors, got \(actual)"
            case .wrongFrameSize(let frame, let expected, let actual):
                return "Frame \(frame) has \(actual) pixels, expected \(expected)"
            case .invalidGIF(let errors):
                return "Invalid GIF: \(errors.joined(separator: ", "))"
            case .gifParsingNotImplemented:
                return "GIF parsing not yet implemented - create voxel cube from pipeline output instead"
            }
        }
    }
}

// MARK: - Debug Visualization

@available(iOS 26.0, *)
extension VoxelGIF81Adapter {

    /// Print voxel cube statistics.
    public static func printCubeStats(_ cube: VoxelCube81) {
        // Count non-dark voxels
        var nonDarkCount = 0
        var colorHistogram = [UInt32: Int]()

        for t in 0..<cube.dimension.rawValue {
            for y in 0..<cube.dimension.rawValue {
                for x in 0..<cube.dimension.rawValue {
                    if let color = cube.voxelAt(x: x, y: y, t: t) {
                        colorHistogram[color, default: 0] += 1

                        let r = Float((color >> 16) & 0xFF)
                        let g = Float((color >> 8) & 0xFF)
                        let b = Float(color & 0xFF)
                        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                        if luminance >= 13 { nonDarkCount += 1 }
                    }
                }
            }
        }

        let uniqueColors = colorHistogram.count
        let totalVoxels = cube.dimension.rawValue * cube.dimension.rawValue * cube.dimension.rawValue

        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║  VOXEL CUBE 81³ STATISTICS                                    ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  Dimension:     \(cube.dimension.rawValue)×\(cube.dimension.rawValue)×\(cube.dimension.rawValue)                                      ║")
        print("║  Total voxels:  \(String(format: "%,d", totalVoxels).padding(toLength: 10, withPad: " ", startingAt: 0))                                  ║")
        print("║  Non-dark:      \(String(format: "%,d", nonDarkCount).padding(toLength: 10, withPad: " ", startingAt: 0)) (\(String(format: "%.1f", Double(nonDarkCount) / Double(totalVoxels) * 100))%)               ║")
        print("║  Unique colors: \(uniqueColors)                                          ║")
        print("║  Duration:      \(String(format: "%.2f", cube.metadata.duration))s @ \(String(format: "%.1f", cube.metadata.fps)) FPS                          ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
    }
}
