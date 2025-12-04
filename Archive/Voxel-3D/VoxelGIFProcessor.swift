//
//  VoxelGIFProcessor.swift
//  RGB2GIF
//
//  3D Voxel GIF structure processor for 80x80x80 or 128x128x128 temporal cubes
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import MetalKit
import os.log
import QuartzCore
import UIKit

private let voxelLogger = Logger(subsystem: "com.rgb2gif", category: "VoxelProcessor")

/// 3D Voxel GIF processor for temporal cube generation
@available(iOS 26.0, *)
public final class VoxelGIFProcessor {

    // MARK: - Types

    public enum VoxelDimension: Int {
        case small = 80  // 80x80x80
        case large = 128 // 128x128x128

        var frameCount: Int { rawValue }
        var resolution: CGSize {
            CGSize(width: rawValue, height: rawValue)
        }
        var totalVoxels: Int {
            rawValue * rawValue * rawValue
        }
    }

    public struct VoxelCube {
        public let dimension: VoxelDimension
        public let frames: [ProcessedFrame]
        public let globalPalette: [UInt32]?
        public let metadata: Metadata

        public struct ProcessedFrame {
            let image: CGImage
            let thumbnail: CGImage
            let palette: [UInt32]
            let indexedPixels: [UInt8]
            let timestamp: TimeInterval
        }

        public struct Metadata {
            let captureDate: Date
            let duration: TimeInterval
            let fps: Double
            let device: String
            let totalSize: Int64
        }

        /// Get voxel value at (x, y, t)
        public func voxelAt(x: Int, y: Int, t: Int) -> UInt32? {
            guard t < frames.count,
                  x < dimension.rawValue,
                  y < dimension.rawValue else { return nil }

            let frame = frames[t]
            let pixelIndex = y * dimension.rawValue + x
            guard pixelIndex < frame.indexedPixels.count else { return nil }

            let paletteIndex = Int(frame.indexedPixels[pixelIndex])
            let palette = frame.palette.isEmpty ? globalPalette ?? [] : frame.palette
            guard paletteIndex < palette.count else { return nil }

            return palette[paletteIndex]
        }
    }

    public struct ProcessingOptions {
        public let dimension: VoxelDimension
        public let targetFPS: Double
        public let useGlobalPalette: Bool
        public let quantizationQuality: Float // 0.0-1.0
        public let enableDithering: Bool
        public let parallelProcessing: Bool

        public init(
            dimension: VoxelDimension = .small,
            targetFPS: Double = 10.0,
            useGlobalPalette: Bool = true,
            quantizationQuality: Float = 0.8,
            enableDithering: Bool = false,
            parallelProcessing: Bool = true
        ) {
            self.dimension = dimension
            self.targetFPS = targetFPS
            self.useGlobalPalette = useGlobalPalette
            self.quantizationQuality = max(0.0, min(1.0, quantizationQuality))
            self.enableDithering = enableDithering
            self.parallelProcessing = parallelProcessing
        }
    }

    // MARK: - Properties

    private let downsampler = RealtimeDownsampler()
    private let quantizer = OctreeColorQuantizer()
    private let cborStorage = CBORFrameStorage()
    private let processingQueue = DispatchQueue(label: "voxel.processing", attributes: .concurrent)

    // Metal resources for GPU acceleration
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    // MARK: - Initialization

    public init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        if device != nil {
            voxelLogger.info("VoxelGIFProcessor initialized with Metal support")
        } else {
            voxelLogger.warning("Metal not available, using CPU processing")
        }
    }

    // MARK: - Public API

    /// Process captured frames into voxel cube structure
    public func createVoxelCube(
        from frames: [CGImage],
        options: ProcessingOptions = ProcessingOptions()
    ) async throws -> VoxelCube {
        voxelLogger.info("Creating \(options.dimension.rawValue)³ voxel cube from \(frames.count) frames")
        let startTime = CACurrentMediaTime()

        // Select frames based on dimension
        let selectedFrames = selectFrames(from: frames, count: options.dimension.frameCount)

        // Process frames
        let processedFrames: [VoxelCube.ProcessedFrame]
        if options.parallelProcessing {
            processedFrames = try await processFramesParallel(
                selectedFrames,
                options: options
            )
        } else {
            processedFrames = try await processFramesSequential(
                selectedFrames,
                options: options
            )
        }

        // Generate global palette if requested
        let globalPalette: [UInt32]?
        if options.useGlobalPalette {
            globalPalette = try await generateGlobalPalette(from: processedFrames)
        } else {
            globalPalette = nil
        }

        // Calculate total size
        let totalSize = calculateTotalSize(frames: processedFrames)

        // Create voxel cube
        let cube = VoxelCube(
            dimension: options.dimension,
            frames: processedFrames,
            globalPalette: globalPalette,
            metadata: VoxelCube.Metadata(
                captureDate: Date(),
                duration: Double(processedFrames.count) / options.targetFPS,
                fps: options.targetFPS,
                device: UIDevice.current.model,
                totalSize: totalSize
            )
        )

        let processingTime = CACurrentMediaTime() - startTime
        voxelLogger.info("Voxel cube created in \(String(format: "%.2f", processingTime))s")

        return cube
    }

    /// Export voxel cube as animated GIF
    public func exportAsGIF(
        _ cube: VoxelCube,
        to url: URL,
        loopCount: Int = 0
    ) async throws {
        voxelLogger.info("Exporting voxel cube as GIF to \(url.lastPathComponent)")

        // Create GIF destination
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            cube.frames.count,
            nil
        ) else {
            throw VoxelError.gifCreationFailed
        }

        // Set GIF properties
        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopCount,
                kCGImagePropertyGIFHasGlobalColorMap: cube.globalPalette != nil
            ] as CFDictionary
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Add frames
        let frameDelay = 1.0 / cube.metadata.fps
        for frame in cube.frames {
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: frameDelay
                ] as CFDictionary
            ]

            CGImageDestinationAddImage(destination, frame.image, frameProperties as CFDictionary)
        }

        // Finalize GIF
        guard CGImageDestinationFinalize(destination) else {
            throw VoxelError.gifFinalizationFailed
        }

        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        voxelLogger.info("GIF exported: \(self.formatBytes(fileSize))")
    }

    /// Save voxel cube as CBOR
    public func saveAsCBOR(_ cube: VoxelCube, name: String) async throws -> URL {
        // Convert to CBOR-compatible structure
        let cborData = try await cborStorage.encodeBatch(
            frames: cube.frames.map { $0.image },
            dimension: cube.dimension.rawValue,
            fps: cube.metadata.fps
        )

        // Save to disk
        return try cborStorage.saveVoxelCube(cborData, name: name)
    }

    /// Load voxel cube from CBOR
    public func loadFromCBOR(url: URL) async throws -> VoxelCube {
        let data = try Data(contentsOf: url)
        let cborCube = try cborStorage.decodeVoxelCube(from: data)

        // Convert CBOR frames to processed frames
        var processedFrames: [VoxelCube.ProcessedFrame] = []
        for frameData in cborCube.frames {
            let (image, _) = try cborStorage.decodeFrame(from: try JSONEncoder().encode(frameData))

            // Generate thumbnail
            let downsampleResult = try await downsampler.downsampleParallel(
                image,
                sizes: [.small]
            )

            // Quantize if no palette
            let quantResult = try await quantizer.quantize(
                image,
                options: OctreeColorQuantizer.QuantizationOptions()
            )

            processedFrames.append(VoxelCube.ProcessedFrame(
                image: image,
                thumbnail: downsampleResult.small80 ?? image,
                palette: quantResult.palette,
                indexedPixels: quantResult.indexedPixels,
                timestamp: frameData.timestamp
            ))
        }

        return VoxelCube(
            dimension: cborCube.dimension == 80 ? .small : .large,
            frames: processedFrames,
            globalPalette: cborCube.globalPalette,
            metadata: VoxelCube.Metadata(
                captureDate: cborCube.metadata.captureDate,
                duration: Double(cborCube.frameCount) / cborCube.metadata.fps,
                fps: cborCube.metadata.fps,
                device: cborCube.metadata.deviceModel,
                totalSize: 0
            )
        )
    }

    // MARK: - Frame Processing

    private func processFramesParallel(
        _ frames: [CGImage],
        options: ProcessingOptions
    ) async throws -> [VoxelCube.ProcessedFrame] {
        return try await withThrowingTaskGroup(of: (Int, VoxelCube.ProcessedFrame).self) { group in
            for (index, frame) in frames.enumerated() {
                group.addTask {
                    let processed = try await self.processFrame(
                        frame,
                        index: index,
                        options: options
                    )
                    return (index, processed)
                }
            }

            // Collect results in order
            var results = Array<VoxelCube.ProcessedFrame?>(repeating: nil, count: frames.count)
            for try await (index, frame) in group {
                results[index] = frame
            }

            return results.compactMap { $0 }
        }
    }

    private func processFramesSequential(
        _ frames: [CGImage],
        options: ProcessingOptions
    ) async throws -> [VoxelCube.ProcessedFrame] {
        var processedFrames: [VoxelCube.ProcessedFrame] = []

        for (index, frame) in frames.enumerated() {
            let processed = try await processFrame(frame, index: index, options: options)
            processedFrames.append(processed)

            // Progress logging
            if index % 10 == 0 {
                voxelLogger.debug("Processed \(index + 1)/\(frames.count) frames")
            }
        }

        return processedFrames
    }

    private func processFrame(
        _ frame: CGImage,
        index: Int,
        options: ProcessingOptions
    ) async throws -> VoxelCube.ProcessedFrame {
        // Downsample to target resolution
        let targetSize: RealtimeDownsampler.DownsampleSize =
            options.dimension == .small ? .small : .medium

        let downsampleResult = try await downsampler.downsampleParallel(
            frame,
            sizes: [targetSize, .tiny]
        )

        let resizedImage = (options.dimension == .small ?
            downsampleResult.small80 : downsampleResult.medium128) ?? frame
        let thumbnail = downsampleResult.tiny64 ?? resizedImage

        // Quantize to 256 colors
        let quantOptions = OctreeColorQuantizer.QuantizationOptions(
            maxColors: 256,
            dithering: options.enableDithering,
            enhanceContrast: options.quantizationQuality > 0.7
        )

        let quantResult = try await quantizer.quantize(
            resizedImage,
            options: quantOptions
        )

        return VoxelCube.ProcessedFrame(
            image: quantResult.quantizedImage,
            thumbnail: thumbnail,
            palette: quantResult.palette,
            indexedPixels: quantResult.indexedPixels,
            timestamp: Double(index) / options.targetFPS
        )
    }

    // MARK: - Helper Methods

    private func selectFrames(from frames: [CGImage], count: Int) -> [CGImage] {
        guard frames.count > count else { return frames }

        // Select evenly distributed frames
        var selected: [CGImage] = []
        let step = Double(frames.count - 1) / Double(count - 1)

        for i in 0..<count {
            let index = Int(Double(i) * step)
            selected.append(frames[min(index, frames.count - 1)])
        }

        return selected
    }

    private func generateGlobalPalette(
        from frames: [VoxelCube.ProcessedFrame]
    ) async throws -> [UInt32] {
        // Combine all palettes and find most common colors
        var colorFrequency: [UInt32: Int] = [:]

        for frame in frames {
            for color in frame.palette {
                colorFrequency[color, default: 0] += 1
            }
        }

        // Sort by frequency and take top 256
        let sortedColors = colorFrequency.sorted { $0.value > $1.value }
        let globalPalette = Array(sortedColors.prefix(256).map { $0.key })

        voxelLogger.info("Generated global palette with \(globalPalette.count) colors")
        return globalPalette
    }

    private func calculateTotalSize(frames: [VoxelCube.ProcessedFrame]) -> Int64 {
        var totalSize: Int64 = 0

        for frame in frames {
            // Estimate size: indexed pixels + palette
            totalSize += Int64(frame.indexedPixels.count)
            totalSize += Int64(frame.palette.count * 4)
        }

        return totalSize
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Visualization Support

    /// Generate cross-section view at time T
    public func crossSection(
        of cube: VoxelCube,
        at time: Int
    ) -> CGImage? {
        guard time < cube.frames.count else { return nil }
        return cube.frames[time].image
    }

    /// Generate temporal slice at position (x, y) over all time
    public func temporalSlice(
        of cube: VoxelCube,
        x: Int,
        y: Int
    ) -> [UInt32] {
        var slice: [UInt32] = []

        for t in 0..<cube.frames.count {
            if let voxel = cube.voxelAt(x: x, y: y, t: t) {
                slice.append(voxel)
            }
        }

        return slice
    }

    /// Generate 3D visualization data
    public func generate3DVisualization(
        of cube: VoxelCube,
        sampleRate: Int = 4
    ) -> Data {
        var voxelData = Data()

        // Sample voxels for visualization (full cube would be too large)
        for t in stride(from: 0, to: cube.frames.count, by: sampleRate) {
            for y in stride(from: 0, to: cube.dimension.rawValue, by: sampleRate) {
                for x in stride(from: 0, to: cube.dimension.rawValue, by: sampleRate) {
                    if let color = cube.voxelAt(x: x, y: y, t: t) {
                        // Store position and color
                        withUnsafeBytes(of: Float32(x)) { voxelData.append(contentsOf: $0) }
                        withUnsafeBytes(of: Float32(y)) { voxelData.append(contentsOf: $0) }
                        withUnsafeBytes(of: Float32(t)) { voxelData.append(contentsOf: $0) }
                        withUnsafeBytes(of: color) { voxelData.append(contentsOf: $0) }
                    }
                }
            }
        }

        return voxelData
    }
}

// MARK: - Errors

public enum VoxelError: LocalizedError {
    // General voxel/tensor pipeline errors
    case insufficientFrames
    case gifCreationFailed
    case gifFinalizationFailed
    case cborEncodingFailed
    case cborDecodingFailed

    // Shader/palette system errors (moved here to avoid duplicate enums)
    case textureCreationFailed
    case functionNotFound(String)
    case invalidData
    case deviceNotFound

    public var errorDescription: String? {
        switch self {
        case .insufficientFrames:
            return "Insufficient frames for voxel cube creation"
        case .gifCreationFailed:
            return "Failed to create GIF destination"
        case .gifFinalizationFailed:
            return "Failed to finalize GIF"
        case .cborEncodingFailed:
            return "Failed to encode voxel cube to CBOR"
        case .cborDecodingFailed:
            return "Failed to decode voxel cube from CBOR"
        case .textureCreationFailed:
            return "Failed to create texture"
        case .functionNotFound(let name):
            return "Metal function not found: \(name)"
        case .invalidData:
            return "Invalid data"
        case .deviceNotFound:
            return "Metal device not available"
        }
    }
}
