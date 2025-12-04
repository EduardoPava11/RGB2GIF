//
//  RealtimeDownsampler.swift
//  RGB2GIF
//
//  Fast image downsampling using Metal Performance Shaders with Lanczos filtering
//

import Foundation
import Metal
import MetalPerformanceShaders
import MetalKit
import Accelerate
import CoreGraphics
import os.log
import QuartzCore
import CoreVideo

private let downsamplerLogger = Logger(subsystem: "com.rgb2gif", category: "Downsampler")

/// High-performance real-time image downsampler for thumbnail generation
@available(iOS 26.0, *)
public final class RealtimeDownsampler {

    // MARK: - Types

    public enum DownsampleSize: Int, CaseIterable {
        case tiny = 64
        case small = 80
        case medium = 128
        case large = 256

        var cgSize: CGSize {
            let dimension = CGFloat(self.rawValue)
            return CGSize(width: dimension, height: dimension)
        }
    }

    public struct DownsampleResult {
        let original: CGImage
        let tiny64: CGImage?
        let small80: CGImage?
        let medium128: CGImage?
        let large256: CGImage?
        let processingTime: TimeInterval
    }

    // MARK: - Properties

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let textureCache: CVMetalTextureCache?
    private var lanczosScaler: MPSImageLanczosScale?
    private var bicubicScaler: MPSImageBilinearScale?

    // Fallback vImage context for CPU processing
    private let vImageFlags: vImage_Flags = vImage_Flags(kvImageHighQualityResampling)

    // Performance monitoring
    private var averageProcessingTime: TimeInterval = 0
    private var processedFrameCount = 0

    // MARK: - Initialization

    public init() {
        // Initialize Metal for GPU acceleration
        self.device = MTLCreateSystemDefaultDevice()

        if let device = device {
            self.commandQueue = device.makeCommandQueue()

            // Create texture cache for CVPixelBuffer conversion
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            self.textureCache = cache

            // Initialize Metal Performance Shaders
            self.lanczosScaler = MPSImageLanczosScale(device: device)
            self.bicubicScaler = MPSImageBilinearScale(device: device)

            downsamplerLogger.info("Metal initialized: \(device.name)")
        } else {
            self.commandQueue = nil
            self.textureCache = nil
            downsamplerLogger.warning("Metal not available, using CPU fallback")
        }
    }

    // MARK: - Public API

    /// Downsample image to multiple sizes in parallel
    public func downsampleParallel(
        _ image: CGImage,
        sizes: [DownsampleSize] = [.small, .medium]
    ) async throws -> DownsampleResult {
        let startTime = CACurrentMediaTime()

        // Use Metal if available for best performance
        if device != nil {
            let result = try await downsampleWithMetal(image, sizes: sizes)
            updatePerformanceMetrics(CACurrentMediaTime() - startTime)
            return result
        } else {
            // Fallback to vImage for CPU processing
            let result = try await downsampleWithVImage(image, sizes: sizes)
            updatePerformanceMetrics(CACurrentMediaTime() - startTime)
            return result
        }
    }

    /// Downsample CVPixelBuffer directly from camera (most efficient)
    public func downsampleFromCamera(
        _ pixelBuffer: CVPixelBuffer,
        sizes: [DownsampleSize] = [.small, .medium]
    ) async throws -> DownsampleResult {
        let startTime = CACurrentMediaTime()

        // Convert to CGImage first
        guard let cgImage = createCGImage(from: pixelBuffer) else {
            throw DownsampleError.pixelBufferConversionFailed
        }

        // Process with optimal path
        if device != nil, textureCache != nil {
            // Direct Metal texture from pixel buffer (zero-copy)
            let result = try await downsamplePixelBufferWithMetal(
                pixelBuffer,
                cgImage: cgImage,
                sizes: sizes
            )
            updatePerformanceMetrics(CACurrentMediaTime() - startTime)
            return result
        } else {
            // CPU fallback
            let result = try await downsampleWithVImage(cgImage, sizes: sizes)
            updatePerformanceMetrics(CACurrentMediaTime() - startTime)
            return result
        }
    }

    // MARK: - Metal Processing

    private func downsampleWithMetal(
        _ image: CGImage,
        sizes: [DownsampleSize]
    ) async throws -> DownsampleResult {
        guard let device = device,
              let commandQueue = commandQueue,
              let lanczosScaler = lanczosScaler else {
            throw DownsampleError.metalNotAvailable
        }

        // Create source texture from CGImage
        let sourceTexture = try createMetalTexture(from: image, device: device)

        // Process each size in parallel
        async let tiny64Task = sizes.contains(.tiny) ?
            processSize(.tiny, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil
        async let small80Task = sizes.contains(.small) ?
            processSize(.small, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil
        async let medium128Task = sizes.contains(.medium) ?
            processSize(.medium, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil
        async let large256Task = sizes.contains(.large) ?
            processSize(.large, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil

        // Await all results
        let tiny64 = try await tiny64Task
        let small80 = try await small80Task
        let medium128 = try await medium128Task
        let large256 = try await large256Task

        return DownsampleResult(
            original: image,
            tiny64: tiny64,
            small80: small80,
            medium128: medium128,
            large256: large256,
            processingTime: 0
        )
    }

    private func processSize(
        _ size: DownsampleSize,
        source: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        scaler: MPSImageLanczosScale
    ) async throws -> CGImage {
        // Create destination texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size.rawValue,
            height: size.rawValue,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let destinationTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DownsampleError.metalProcessingFailed
        }

        // Encode scaling operation
        scaler.encode(
            commandBuffer: commandBuffer,
            sourceTexture: source,
            destinationTexture: destinationTexture
        )

        // Execute and await completion
        commandBuffer.commit()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in
                cont.resume()
            }
        }

        // Convert texture to CGImage
        return try createCGImage(from: destinationTexture)
    }

    private func downsamplePixelBufferWithMetal(
        _ pixelBuffer: CVPixelBuffer,
        cgImage: CGImage,
        sizes: [DownsampleSize]
    ) async throws -> DownsampleResult {
        guard let device = device,
              let commandQueue = commandQueue,
              let textureCache = textureCache,
              let lanczosScaler = lanczosScaler else {
            throw DownsampleError.metalNotAvailable
        }

        // Create Metal texture directly from pixel buffer (zero-copy)
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess,
              let texture = cvTexture,
              let sourceTexture = CVMetalTextureGetTexture(texture) else {
            throw DownsampleError.textureCreationFailed
        }

        // Process each size
        async let tiny64Task = sizes.contains(.tiny) ?
            processSize(.tiny, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil
        async let small80Task = sizes.contains(.small) ?
            processSize(.small, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil
        async let medium128Task = sizes.contains(.medium) ?
            processSize(.medium, source: sourceTexture, device: device, commandQueue: commandQueue, scaler: lanczosScaler) : nil

        let tiny64 = try await tiny64Task
        let small80 = try await small80Task
        let medium128 = try await medium128Task

        return DownsampleResult(
            original: cgImage,
            tiny64: tiny64,
            small80: small80,
            medium128: medium128,
            large256: nil,
            processingTime: 0
        )
    }

    // MARK: - vImage CPU Fallback

    private func downsampleWithVImage(
        _ image: CGImage,
        sizes: [DownsampleSize]
    ) async throws -> DownsampleResult {
        // Process each size using vImage with Lanczos5
        async let tiny64Task = sizes.contains(.tiny) ?
            processWithVImage(image, targetSize: .tiny) : nil
        async let small80Task = sizes.contains(.small) ?
            processWithVImage(image, targetSize: .small) : nil
        async let medium128Task = sizes.contains(.medium) ?
            processWithVImage(image, targetSize: .medium) : nil
        async let large256Task = sizes.contains(.large) ?
            processWithVImage(image, targetSize: .large) : nil

        let tiny64 = try await tiny64Task
        let small80 = try await small80Task
        let medium128 = try await medium128Task
        let large256 = try await large256Task

        return DownsampleResult(
            original: image,
            tiny64: tiny64,
            small80: small80,
            medium128: medium128,
            large256: large256,
            processingTime: 0
        )
    }

    private func processWithVImage(
        _ image: CGImage,
        targetSize: DownsampleSize
    ) async throws -> CGImage {
        return try await Task.detached(priority: .userInitiated) {
            // Setup source buffer
            guard let sourceData = image.dataProvider?.data else {
                throw DownsampleError.invalidImageData
            }

            var sourceBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: CFDataGetBytePtr(sourceData)),
                height: vImagePixelCount(image.height),
                width: vImagePixelCount(image.width),
                rowBytes: image.bytesPerRow
            )

            // Setup destination buffer
            let destWidth = targetSize.rawValue
            let destHeight = targetSize.rawValue
            let bytesPerPixel = 4
            let destBytesPerRow = destWidth * bytesPerPixel
            let destData = UnsafeMutablePointer<UInt8>.allocate(capacity: destHeight * destBytesPerRow)
            defer { destData.deallocate() }

            var destBuffer = vImage_Buffer(
                data: destData,
                height: vImagePixelCount(destHeight),
                width: vImagePixelCount(destWidth),
                rowBytes: destBytesPerRow
            )

            // Perform Lanczos5 scaling
            let error = vImageScale_ARGB8888(
                &sourceBuffer,
                &destBuffer,
                nil,
                self.vImageFlags
            )

            guard error == kvImageNoError else {
                throw DownsampleError.vImageProcessingFailed(error)
            }

            // Create CGImage from result
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let context = CGContext(
                data: destData,
                width: destWidth,
                height: destHeight,
                bitsPerComponent: 8,
                bytesPerRow: destBytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ),
            let resultImage = context.makeImage() else {
                throw DownsampleError.imageCreationFailed
            }

            return resultImage
        }.value
    }

    // MARK: - Helper Methods

    private func createMetalTexture(from image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = image.width
        let height = image.height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DownsampleError.textureCreationFailed
        }

        // Copy image data to texture
        let bytesPerRow = width * 4
        let imageData = UnsafeMutableRawPointer.allocate(
            byteCount: height * bytesPerRow,
            alignment: 1
        )
        defer { imageData.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: imageData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DownsampleError.contextCreationFailed
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: imageData,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    private func createCGImage(from texture: MTLTexture) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4

        let imageData = UnsafeMutableRawPointer.allocate(
            byteCount: height * bytesPerRow,
            alignment: 1
        )
        defer { imageData.deallocate() }

        texture.getBytes(
            imageData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: imageData,
            size: height * bytesPerRow,
            releaseData: { _, _, _ in }
        ),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw DownsampleError.imageCreationFailed
        }

        return image
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    private func updatePerformanceMetrics(_ processingTime: TimeInterval) {
        processedFrameCount += 1
        averageProcessingTime = (averageProcessingTime * Double(processedFrameCount - 1) + processingTime) / Double(processedFrameCount)

        if processedFrameCount % 100 == 0 {
            downsamplerLogger.info("Average downsampling time: \(String(format: "%.2f", self.averageProcessingTime * 1000))ms")
        }
    }

    // MARK: - Performance Monitoring

    public var performanceReport: String {
        """
        Downsampler Performance:
        - Device: \(device?.name ?? "CPU")
        - Frames Processed: \(processedFrameCount)
        - Average Time: \(String(format: "%.2f", averageProcessingTime * 1000))ms
        - FPS Capability: \(averageProcessingTime > 0 ? String(format: "%.0f", 1.0 / averageProcessingTime) : "N/A")
        """
    }
}

// MARK: - Errors

public enum DownsampleError: LocalizedError {
    case metalNotAvailable
    case textureCreationFailed
    case metalProcessingFailed
    case vImageProcessingFailed(vImage_Error)
    case imageCreationFailed
    case invalidImageData
    case contextCreationFailed
    case pixelBufferConversionFailed

    public var errorDescription: String? {
        switch self {
        case .metalNotAvailable:
            return "Metal is not available on this device"
        case .textureCreationFailed:
            return "Failed to create Metal texture"
        case .metalProcessingFailed:
            return "Metal processing failed"
        case .vImageProcessingFailed(let error):
            return "vImage processing failed with error: \(error)"
        case .imageCreationFailed:
            return "Failed to create CGImage"
        case .invalidImageData:
            return "Invalid image data"
        case .contextCreationFailed:
            return "Failed to create graphics context"
        case .pixelBufferConversionFailed:
            return "Failed to convert pixel buffer"
        }
    }
}
