//
//  SquareCropper.swift
//  RGB2GIF
//
//  High-performance centered square cropping for camera frames
//

import Foundation
import CoreImage
import Accelerate
import Metal
import MetalPerformanceShaders
import os.log

private let cropLogger = Logger(subsystem: "com.rgb2gif", category: "SquareCropper")

/// High-performance square cropping with multiple backend support
@available(iOS 26.0, *)
public final class SquareCropper {

    // MARK: - Properties

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext

    // MARK: - Initialization

    public init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()

        if let device = device {
            self.context = CIContext(mtlDevice: device)
        } else {
            self.context = CIContext(options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .useSoftwareRenderer: false
            ])
        }
    }

    // MARK: - Public Methods

    /// Compute the largest centered square rect for a given size
    public static func centerSquareRect(for size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        return CGRect(
            x: (size.width - side) * 0.5,
            y: (size.height - side) * 0.5,
            width: side,
            height: side
        )
    }

    /// Crop a CIImage to its largest centered square
    public func cropToSquare(_ image: CIImage) -> CIImage {
        let cropRect = Self.centerSquareRect(for: image.extent.size)
        return image.cropped(to: cropRect)
    }

    /// Crop a CGImage to its largest centered square
    public func cropToSquare(_ image: CGImage) -> CGImage? {
        let cropRect = Self.centerSquareRect(for: CGSize(
            width: image.width,
            height: image.height
        ))

        return image.cropping(to: CGRect(
            x: Int(cropRect.origin.x),
            y: Int(cropRect.origin.y),
            width: Int(cropRect.width),
            height: Int(cropRect.height)
        ))
    }

    /// Crop using Metal texture (fastest for GPU pipeline)
    public func cropToSquare(texture: MTLTexture) -> MTLTexture? {
        guard let device = device,
              let commandQueue = commandQueue else {
            cropLogger.warning("Metal not available for texture cropping")
            return nil
        }

        let side = min(texture.width, texture.height)
        let x = (texture.width - side) / 2
        let y = (texture.height - side) / 2

        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: side,
            height: side,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        // Use MPS to crop
        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
            size: MTLSize(width: side, height: side, depth: 1)
        )

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: region.origin,
                sourceSize: region.size,
                to: outputTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputTexture
    }

    /// Crop using vImage (CPU-optimized path)
    public func cropToSquare(buffer: vImage_Buffer) throws -> vImage_Buffer {
        let side = min(buffer.width, buffer.height)
        let x = (buffer.width - side) / 2
        let y = (buffer.height - side) / 2

        // Calculate source pointer offset
        let bytesPerPixel = 4 // Assuming ARGB8888
        let sourceOffset = Int(y) * buffer.rowBytes + Int(x) * bytesPerPixel

        // Create output buffer
        var output = vImage_Buffer()
        output.width = side
        output.height = side
        output.rowBytes = Int(side) * bytesPerPixel

        let outputSize = output.rowBytes * Int(output.height)
        output.data = UnsafeMutableRawPointer.allocate(
            byteCount: outputSize,
            alignment: 64
        )

        defer {
            if output.data == nil {
                output.data.deallocate()
            }
        }

        // Copy cropped region row by row
        let sourcePtr = buffer.data.advanced(by: sourceOffset)
        let destPtr = output.data

        for row in 0..<Int(side) {
            let srcRow = sourcePtr.advanced(by: row * buffer.rowBytes)
            let dstRow = destPtr!.advanced(by: row * output.rowBytes)
            memcpy(dstRow, srcRow, output.rowBytes)
        }

        cropLogger.debug("vImage crop complete: \(side)x\(side)")
        return output
    }

    /// Batch crop multiple frames efficiently
    public func cropBatch(_ images: [CGImage]) async -> [CGImage] {
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask { [weak self] in
                    (index, await self?.cropToSquare(image))
                }
            }

            var results = [(Int, CGImage?)]()
            for await result in group {
                results.append(result)
            }

            return results
                .sorted { $0.0 < $1.0 }
                .compactMap { $0.1 }
        }
    }

    // MARK: - Aspect Ratio Preservation

    /// Crop with aspect ratio preservation and padding
    public func cropWithAspectFit(
        _ image: CGImage,
        targetSize: CGSize,
        backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            targetSize.width / imageSize.width,
            targetSize.height / imageSize.height
        )

        let scaledSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let origin = CGPoint(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2
        )

        // Create context with padding
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill background
        context.setFillColor(backgroundColor)
        context.fill(CGRect(origin: .zero, size: targetSize))

        // Draw scaled image centered
        context.draw(
            image,
            in: CGRect(origin: origin, size: scaledSize)
        )

        return context.makeImage()
    }

    // MARK: - Smart Crop (Content-Aware)

    /// Content-aware cropping using saliency detection
    @available(iOS 26.0, *)
    public func smartCrop(_ image: CIImage, targetAspect: CGFloat) -> CIImage {
        // Use Core Image's saliency detection if available
        if let detector = CIDetector(
            ofType: CIDetectorTypeRectangle,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) {
            let features = detector.features(in: image)

            if let rect = features.first?.bounds {
                // Adjust crop to include salient region
                let adjustedRect = expandToAspect(rect, targetAspect: targetAspect, imageSize: image.extent.size)
                return image.cropped(to: adjustedRect)
            }
        }

        // Fallback to center crop
        return cropToSquare(image)
    }

    private func expandToAspect(_ rect: CGRect, targetAspect: CGFloat, imageSize: CGSize) -> CGRect {
        let currentAspect = rect.width / rect.height
        var adjustedRect = rect

        if currentAspect < targetAspect {
            // Need to expand width
            adjustedRect.size.width = rect.height * targetAspect
            adjustedRect.origin.x = max(0, rect.midX - adjustedRect.width / 2)
        } else {
            // Need to expand height
            adjustedRect.size.height = rect.width / targetAspect
            adjustedRect.origin.y = max(0, rect.midY - adjustedRect.height / 2)
        }

        // Ensure within image bounds
        adjustedRect.origin.x = max(0, min(adjustedRect.origin.x, imageSize.width - adjustedRect.width))
        adjustedRect.origin.y = max(0, min(adjustedRect.origin.y, imageSize.height - adjustedRect.height))

        return adjustedRect
    }
}

// MARK: - CVPixelBuffer Extension

@available(iOS 26.0, *)
extension SquareCropper {

    /// Crop a CVPixelBuffer to square (optimized for camera pipeline)
    public func cropToSquare(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let side = min(width, height)
        let x = (width - side) / 2
        let y = (height - side) / 2

        // Create output pixel buffer
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            side, side,
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true as CFBoolean
            ] as CFDictionary,
            &outputBuffer
        )

        guard status == kCVReturnSuccess,
              let output = outputBuffer else { return nil }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        // Copy pixel data
        let sourceBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let destBaseAddress = CVPixelBufferGetBaseAddress(output)!
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let bytesPerPixel = 4 // Assuming BGRA

        for row in 0..<side {
            let sourceRow = sourceBaseAddress
                .advanced(by: (y + row) * sourceBytesPerRow + x * bytesPerPixel)
            let destRow = destBaseAddress
                .advanced(by: row * destBytesPerRow)
            memcpy(destRow, sourceRow, side * bytesPerPixel)
        }

        return output
    }
}