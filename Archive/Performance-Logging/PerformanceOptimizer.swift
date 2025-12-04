//
//  PerformanceOptimizer.swift
//  RGB2GIF
//
//  iPhone 17 Pro specific performance optimizations
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import UIKit
import Metal
import MetalPerformanceShaders
import os.log
import CoreVideo
import Darwin

private let perfLogger = Logger(subsystem: "com.rgb2gif", category: "Performance")

/// Performance optimizer for iPhone 17 Pro hardware
@available(iOS 26.0, *)
public final class PerformanceOptimizer {

    // MARK: - Properties

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let memoryMonitor = MemoryMonitor()
    private let thermalMonitor = ProcessInfo.processInfo

    // iPhone 17 Pro specific thresholds
    private struct Thresholds {
        static let maxMemoryUsage: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB
        static let criticalMemoryUsage: UInt64 = 3 * 1024 * 1024 * 1024 // 3GB
        static let targetFrameTime: TimeInterval = 1.0 / 60.0 // 60 FPS
        static let maxFrameBufferSize = 100 // Frames to keep in memory
    }

    // MARK: - Initialization

    public init() {
        // Initialize Metal for GPU acceleration
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        if device == nil {
            perfLogger.warning("Metal not available, falling back to CPU processing")
        } else {
            perfLogger.info("Metal initialized with device: \(self.device!.name)")
        }
    }

    // MARK: - Frame Processing Optimization

    /// Process frame with Metal acceleration for iPhone 17 Pro
    public func processFrameOptimized(
        _ pixelBuffer: CVPixelBuffer,
        targetSize: CGSize
    ) -> CGImage? {
        // Use Metal if available for iPhone 17 Pro's GPU
        if device != nil {
            return processWithMetal(pixelBuffer, targetSize: targetSize)
        } else {
            return processWithCoreImage(pixelBuffer, targetSize: targetSize)
        }
    }

    private func processWithMetal(
        _ pixelBuffer: CVPixelBuffer,
        targetSize: CGSize
    ) -> CGImage? {
        guard let device = device,
              let commandQueue = commandQueue else {
            return nil
        }

        // Create Metal texture from pixel buffer
        var metalTexture: CVMetalTexture?
        let textureCache = CVMetalTextureCache.allocate(device: device)

        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &metalTexture
        )

        guard status == kCVReturnSuccess,
              let texture = metalTexture,
              let inputTexture = CVMetalTextureGetTexture(texture) else {
            return nil
        }

        // Apply Metal Performance Shaders for scaling
        let scaler = MPSImageLanczosScale(device: device)

        // Create output texture
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        // Configure and encode scaling
        scaler.encode(
            commandBuffer: commandBuffer,
            sourceTexture: inputTexture,
            destinationTexture: outputTexture
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Convert Metal texture to CGImage
        return convertMetalTextureToCGImage(outputTexture)
    }

    private func processWithCoreImage(
        _ pixelBuffer: CVPixelBuffer,
        targetSize: CGSize
    ) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Use hardware-accelerated context
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .useSoftwareRenderer: false,
            .highQualityDownsample: true,
            .cacheIntermediates: false
        ])

        // Apply transforms
        let scale = min(
            targetSize.width / ciImage.extent.width,
            targetSize.height / ciImage.extent.height
        )

        let transformed = ciImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1.05,
                "inputContrast": 1.02,
                "inputBrightness": 0.02
            ])

        return context.createCGImage(transformed, from: transformed.extent)
    }

    private func convertMetalTextureToCGImage(_ texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4

        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(
            &data,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cgImage = CGImage(
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
            return nil
        }

        return cgImage
    }

    // MARK: - Memory Optimization

    public func optimizeMemoryUsage() {
        let currentUsage = memoryMonitor.currentUsage()

        if currentUsage > Thresholds.criticalMemoryUsage {
            perfLogger.warning("Critical memory usage: \(self.formatBytes(currentUsage))")
            // Force memory cleanup
            URLCache.shared.removeAllCachedResponses()
            URLCache.shared.diskCapacity = 0
            URLCache.shared.memoryCapacity = 0
        } else if currentUsage > Thresholds.maxMemoryUsage {
            perfLogger.info("High memory usage: \(self.formatBytes(currentUsage))")
            // Suggest cleanup
            NotificationCenter.default.post(
                name: .memoryWarning,
                object: nil,
                userInfo: ["usage": currentUsage]
            )
        }
    }

    // MARK: - Adaptive Quality

    public func adaptiveQualitySettings() -> QualitySettings {
        let thermalState = thermalMonitor.thermalState
        let memoryUsage = memoryMonitor.currentUsage()
        let batteryLevel = UIDevice.current.batteryLevel

        var settings = QualitySettings()

        // Adjust based on thermal state
        switch thermalState {
        case .nominal:
            settings.resolution = CGSize(width: 1920, height: 1080)
            settings.frameRate = 60
            settings.quality = 1.0

        case .fair:
            settings.resolution = CGSize(width: 1280, height: 720)
            settings.frameRate = 30
            settings.quality = 0.8

        case .serious, .critical:
            settings.resolution = CGSize(width: 854, height: 480)
            settings.frameRate = 24
            settings.quality = 0.6
            perfLogger.warning("Thermal throttling active: \(thermalState.rawValue)")

        @unknown default:
            settings.resolution = CGSize(width: 1280, height: 720)
            settings.frameRate = 30
            settings.quality = 0.8
        }

        // Adjust for memory pressure
        if memoryUsage > Thresholds.maxMemoryUsage {
            settings.frameRate = min(settings.frameRate, 30)
            settings.maxFrameBuffer = 50
        }

        // Adjust for battery level
        if batteryLevel < 0.2 && batteryLevel >= 0 {
            settings.frameRate = min(settings.frameRate, 24)
            settings.quality *= 0.8
            perfLogger.info("Low battery mode: reducing quality")
        }

        return settings
    }

    // MARK: - Helper Methods

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Types

    public struct QualitySettings {
        public var resolution = CGSize(width: 1280, height: 720)
        public var frameRate = 30
        public var quality: Float = 0.8
        public var maxFrameBuffer = 100
        public var useHardwareAcceleration = true
    }
}

// MARK: - Memory Monitor

@available(iOS 26.0, *)
private class MemoryMonitor {
    func currentUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    func availableMemory() -> UInt64 {
        return ProcessInfo.processInfo.physicalMemory - currentUsage()
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let memoryWarning = Notification.Name("com.rgb2gif.memoryWarning")
    static let thermalStateChanged = Notification.Name("com.rgb2gif.thermalStateChanged")
    static let qualityAdjusted = Notification.Name("com.rgb2gif.qualityAdjusted")
}

// MARK: - CVMetalTextureCache Extension

extension CVMetalTextureCache {
    static func allocate(device: MTLDevice) -> CVMetalTextureCache? {
        var textureCache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(
            nil,
            nil,
            device,
            nil,
            &textureCache
        )
        return result == kCVReturnSuccess ? textureCache : nil
    }
}