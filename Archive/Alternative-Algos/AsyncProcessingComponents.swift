//
//  AsyncProcessingComponents.swift
//  RGB2GIF
//
//  Async implementations of downscaler and quantizer
//  Sendable-compliant for Swift 6 strict concurrency
//

import Foundation
import Accelerate
import CoreVideo
import CoreGraphics
import os.log

private let processingLogger = Logger(subsystem: "com.rgb2gif", category: "AsyncProcessing")

// MARK: - Async vImage Downscaler

/// High-performance async downscaler using vImage
@available(iOS 26.0, *)
public struct VImageDownscalerAsync: FrameDownscalerAsync {

    public enum Quality: Sendable {
        case fast       // Box filter
        case balanced   // High-quality resampling
        case maximum    // Lanczos-equivalent
    }

    private let quality: Quality

    public init(quality: Quality = .balanced) {
        self.quality = quality
    }

    // MARK: - FrameDownscalerAsync Implementation

    public func downsample(_ pixelBuffer: CVPixelBuffer, to size: Int) async throws -> [UInt8] {
        // Perform CPU-intensive work off main thread
        return try await Task.detached {
            try self.downsampleSync(pixelBuffer, to: size)
        }.value
    }

    // MARK: - Synchronous Implementation (Isolated to Task)

    private func downsampleSync(_ pixelBuffer: CVPixelBuffer, to size: Int) throws -> [UInt8] {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Fast path for NV12
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return try downsampleNV12(pixelBuffer, to: size)
        }

        // BGRA fallback
        if pixelFormat == kCVPixelFormatType_32BGRA {
            return try downsampleBGRA(pixelBuffer, to: size)
        }

        throw ProcessingError.unsupportedPixelFormat(pixelFormat)
    }

    // MARK: - NV12 Path

    private func downsampleNV12(_ pixelBuffer: CVPixelBuffer, to size: Int) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbCrBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw ProcessingError.invalidPixelBuffer
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbCrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        // Calculate center square crop
        let squareSize = min(width, height)
        let cropX = (width - squareSize) / 2
        let cropY = (height - squareSize) / 2

        // Crop Y-plane
        let croppedYData = yBaseAddress.advanced(by: cropY * yBytesPerRow + cropX)
        var croppedYBuffer = vImage_Buffer(
            data: croppedYData,
            height: vImagePixelCount(squareSize),
            width: vImagePixelCount(squareSize),
            rowBytes: yBytesPerRow
        )

        // Crop CbCr-plane
        let croppedCbCrData = cbCrBaseAddress.advanced(by: (cropY / 2) * cbCrBytesPerRow + cropX)
        var croppedCbCrBuffer = vImage_Buffer(
            data: croppedCbCrData,
            height: vImagePixelCount(squareSize / 2),
            width: vImagePixelCount(squareSize / 2),
            rowBytes: cbCrBytesPerRow
        )

        // Allocate destination ARGB buffer
        let argbBytesPerRow = squareSize * 4
        let argbData = UnsafeMutableRawPointer.allocate(
            byteCount: squareSize * argbBytesPerRow,
            alignment: 64
        )
        defer { argbData.deallocate() }

        var destARGBBuffer = vImage_Buffer(
            data: argbData,
            height: vImagePixelCount(squareSize),
            width: vImagePixelCount(squareSize),
            rowBytes: argbBytesPerRow
        )

        // Convert YCbCr → ARGB
        var infoYpCbCrToARGB = vImage_YpCbCrToARGB()

        let error = vImageConvert_420Yp8_CbCr8BiPlanarToARGB8888(
            &croppedYBuffer,
            &croppedCbCrBuffer,
            &destARGBBuffer,
            &infoYpCbCrToARGB,
            nil,
            255,
            vImage_Flags(kvImagePrintDiagnosticsToConsole)
        )

        guard error == kvImageNoError else {
            throw ProcessingError.conversionFailed(Int(error))
        }

        // Downscale ARGB to target size
        return try downscaleARGB(buffer: destARGBBuffer, sourceSize: squareSize, targetSize: size)
    }

    // MARK: - BGRA Path

    private func downsampleBGRA(_ pixelBuffer: CVPixelBuffer, to size: Int) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ProcessingError.invalidPixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Center crop
        let squareSize = min(width, height)
        let cropX = (width - squareSize) / 2
        let cropY = (height - squareSize) / 2

        let croppedData = baseAddress.advanced(by: cropY * bytesPerRow + cropX * 4)
        var srcBuffer = vImage_Buffer(
            data: croppedData,
            height: vImagePixelCount(squareSize),
            width: vImagePixelCount(squareSize),
            rowBytes: bytesPerRow
        )

        return try downscaleBGRAToRGBA(buffer: srcBuffer, sourceSize: squareSize, targetSize: size)
    }

    // MARK: - Downscaling Helpers

    private func downscaleARGB(buffer: vImage_Buffer, sourceSize: Int, targetSize: Int) throws -> [UInt8] {
        var srcBuffer = buffer
        let destBytesPerRow = targetSize * 4
        var rgba = [UInt8](repeating: 0, count: targetSize * destBytesPerRow)

        try rgba.withUnsafeMutableBytes { destPointer in
            var destBuffer = vImage_Buffer(
                data: destPointer.baseAddress,
                height: vImagePixelCount(targetSize),
                width: vImagePixelCount(targetSize),
                rowBytes: destBytesPerRow
            )

            let error = vImageScale_ARGB8888(
                &srcBuffer,
                &destBuffer,
                nil,
                vImage_Flags(kvImageHighQualityResampling)
            )

            guard error == kvImageNoError else {
                throw ProcessingError.scaleFailed(Int(error))
            }
        }

        // Convert ARGB → RGBA
        return argbToRGBA(rgba)
    }

    private func downscaleBGRAToRGBA(buffer: vImage_Buffer, sourceSize: Int, targetSize: Int) throws -> [UInt8] {
        var srcBuffer = buffer
        let destBytesPerRow = targetSize * 4
        var bgra = [UInt8](repeating: 0, count: targetSize * destBytesPerRow)

        try bgra.withUnsafeMutableBytes { destPointer in
            var destBuffer = vImage_Buffer(
                data: destPointer.baseAddress,
                height: vImagePixelCount(targetSize),
                width: vImagePixelCount(targetSize),
                rowBytes: destBytesPerRow
            )

            let error = vImageScale_ARGB8888(
                &srcBuffer,
                &destBuffer,
                nil,
                vImage_Flags(kvImageHighQualityResampling)
            )

            guard error == kvImageNoError else {
                throw ProcessingError.scaleFailed(Int(error))
            }
        }

        // Convert BGRA → RGBA
        return bgraToRGBA(bgra)
    }

    // MARK: - Color Space Conversions

    private func argbToRGBA(_ argb: [UInt8]) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: argb.count)

        for i in stride(from: 0, to: argb.count, by: 4) {
            rgba[i + 0] = argb[i + 1]  // R
            rgba[i + 1] = argb[i + 2]  // G
            rgba[i + 2] = argb[i + 3]  // B
            rgba[i + 3] = argb[i + 0]  // A
        }

        return rgba
    }

    private func bgraToRGBA(_ bgra: [UInt8]) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: bgra.count)

        for i in stride(from: 0, to: bgra.count, by: 4) {
            rgba[i + 0] = bgra[i + 2]  // R
            rgba[i + 1] = bgra[i + 1]  // G
            rgba[i + 2] = bgra[i + 0]  // B
            rgba[i + 3] = bgra[i + 3]  // A
        }

        return rgba
    }
}

// MARK: - Async Median-Cut Quantizer

/// Simple median-cut quantizer with async processing
@available(iOS 26.0, *)
public struct MedianCutQuantizerAsync: PaletteQuantizerAsync {

    public init() {}

    // MARK: - PaletteQuantizerAsync Implementation

    public func quantizeRGBA(
        _ rgba: [UInt8],
        width: Int,
        height: Int,
        maxColors: Int
    ) async throws -> QuantizedFrameV2 {
        // Perform CPU-intensive quantization off main thread
        return try await Task.detached {
            try self.quantizeSync(rgba, width: width, height: height, maxColors: maxColors, sequenceNumber: 0)
        }.value
    }

    // MARK: - Synchronous Implementation (Isolated to Task)

    private func quantizeSync(
        _ rgba: [UInt8],
        width: Int,
        height: Int,
        maxColors: Int,
        sequenceNumber: Int
    ) throws -> QuantizedFrameV2 {

        let pixelCount = width * height
        guard rgba.count == pixelCount * 4 else {
            throw ProcessingError.invalidDataSize
        }

        // Extract unique colors
        var colorSet = Set<UInt32>()
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = UInt32(rgba[offset + 0])
            let g = UInt32(rgba[offset + 1])
            let b = UInt32(rgba[offset + 2])
            let a = UInt32(rgba[offset + 3])
            let color = (a << 24) | (b << 16) | (g << 8) | r
            colorSet.insert(color)
        }

        // If already ≤ maxColors, use as-is
        var palette = Array(colorSet)
        if palette.count > maxColors {
            // Simple uniform sampling (TODO: implement proper median-cut)
            palette = uniformSample(palette, count: maxColors)
        }

        // Pad to 256 colors
        while palette.count < 256 {
            palette.append(0x000000FF)  // Opaque black
        }

        // Convert palette to RGBA bytes
        var paletteRGBA256 = [UInt8](repeating: 0, count: 1024)
        for (i, color) in palette.enumerated() {
            paletteRGBA256[i * 4 + 0] = UInt8((color >> 0) & 0xFF)   // R
            paletteRGBA256[i * 4 + 1] = UInt8((color >> 8) & 0xFF)   // G
            paletteRGBA256[i * 4 + 2] = UInt8((color >> 16) & 0xFF)  // B
            paletteRGBA256[i * 4 + 3] = UInt8((color >> 24) & 0xFF)  // A
        }

        // Map pixels to palette indices
        var indexHW = [UInt8](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = UInt32(rgba[offset + 0])
            let g = UInt32(rgba[offset + 1])
            let b = UInt32(rgba[offset + 2])
            let a = UInt32(rgba[offset + 3])
            let color = (a << 24) | (b << 16) | (g << 8) | r

            let paletteIndex = findNearest(color: color, in: palette)
            indexHW[i] = UInt8(paletteIndex)
        }

        return QuantizedFrameV2(
            paletteRGBA256: paletteRGBA256,
            indexHW: indexHW,
            sequenceNumber: sequenceNumber
        )
    }

    // MARK: - Helpers

    private func uniformSample(_ colors: [UInt32], count: Int) -> [UInt32] {
        guard colors.count > count else { return colors }

        var sampled: [UInt32] = []
        let step = Double(colors.count) / Double(count)

        for i in 0..<count {
            let index = Int(Double(i) * step)
            sampled.append(colors[min(index, colors.count - 1)])
        }

        return sampled
    }

    private func findNearest(color: UInt32, in palette: [UInt32]) -> Int {
        let r1 = Int((color >> 0) & 0xFF)
        let g1 = Int((color >> 8) & 0xFF)
        let b1 = Int((color >> 16) & 0xFF)

        var minDist = Int.max
        var bestIndex = 0

        for (idx, paletteColor) in palette.enumerated() {
            let r2 = Int((paletteColor >> 0) & 0xFF)
            let g2 = Int((paletteColor >> 8) & 0xFF)
            let b2 = Int((paletteColor >> 16) & 0xFF)

            let dr = r1 - r2
            let dg = g1 - g2
            let db = b1 - b2
            let dist = dr*dr + dg*dg + db*db

            if dist < minDist {
                minDist = dist
                bestIndex = idx
            }
        }

        return bestIndex
    }
}

// MARK: - Async Y-Plane Grayscale Quantizer

/// Direct Y-plane → grayscale indices quantizer (bypasses color quantization)
/// Perfect for GIF89a grayscale-first workflow with palette swapping
@available(iOS 26.0, *)
public struct YPlaneGrayscaleQuantizerAsync: PaletteQuantizerAsync {

    public enum GrayscalePaletteMode: Sendable {
        case linear256        // 0→255 linear ramp
        case perceptual       // Gamma-corrected for human vision (gamma 2.2)
        case highContrast     // Expanded dynamic range for middle tones
    }

    private let paletteMode: GrayscalePaletteMode

    public init(paletteMode: GrayscalePaletteMode = .linear256) {
        self.paletteMode = paletteMode
    }

    // MARK: - PaletteQuantizerAsync Implementation

    public func quantizeRGBA(
        _ rgba: [UInt8],
        width: Int,
        height: Int,
        maxColors: Int
    ) async throws -> QuantizedFrameV2 {
        return try await Task.detached {
            try self.quantizeGrayscaleSync(rgba, width: width, height: height, sequenceNumber: 0)
        }.value
    }

    // MARK: - Grayscale Quantization (Y-plane extraction)

    private func quantizeGrayscaleSync(
        _ rgba: [UInt8],
        width: Int,
        height: Int,
        sequenceNumber: Int
    ) throws -> QuantizedFrameV2 {

        let pixelCount = width * height
        guard rgba.count == pixelCount * 4 else {
            throw ProcessingError.invalidDataSize
        }

        // Generate grayscale palette (256 shades)
        let paletteRGBA256 = generateGrayscalePalette()

        // Extract luma from RGBA and map to indices
        var indexHW = [UInt8](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let offset = i * 4
            let r = rgba[offset + 0]
            let g = rgba[offset + 1]
            let b = rgba[offset + 2]

            // ITU-R BT.709 luma coefficients (same as NV12 Y-plane)
            let luma = UInt8(
                (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded()
            )

            indexHW[i] = luma  // Direct mapping: luma value = palette index
        }

        processingLogger.info("Y-plane grayscale quantization: \(width)×\(height), mode: \(String(describing: self.paletteMode))")

        return QuantizedFrameV2(
            paletteRGBA256: paletteRGBA256,
            indexHW: indexHW,
            sequenceNumber: sequenceNumber
        )
    }

    // MARK: - Palette Generation

    private func generateGrayscalePalette() -> [UInt8] {
        var palette = [UInt8](repeating: 0, count: 1024)  // 256 colors × 4 channels

        for i in 0..<256 {
            let gray: UInt8

            switch paletteMode {
            case .linear256:
                gray = UInt8(i)

            case .perceptual:
                // Gamma 2.2 for perceptual uniformity
                let normalized = Double(i) / 255.0
                let gammaCorrected = pow(normalized, 1.0 / 2.2)
                gray = UInt8((gammaCorrected * 255.0).rounded())

            case .highContrast:
                // Expand middle tones, compress shadows/highlights
                let normalized = Double(i) / 255.0
                let expanded = (normalized - 0.5) * 1.5 + 0.5
                gray = UInt8(max(0, min(255, expanded * 255.0)).rounded())
            }

            palette[i * 4 + 0] = gray  // R
            palette[i * 4 + 1] = gray  // G
            palette[i * 4 + 2] = gray  // B
            palette[i * 4 + 3] = 255   // A (opaque)
        }

        return palette
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
public enum ProcessingError: Error, LocalizedError {
    case unsupportedPixelFormat(OSType)
    case invalidPixelBuffer
    case conversionFailed(Int)
    case scaleFailed(Int)
    case invalidDataSize

    public var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let format):
            let fourCC = String(format: "%c%c%c%c",
                               (format >> 24) & 0xFF,
                               (format >> 16) & 0xFF,
                               (format >> 8) & 0xFF,
                               format & 0xFF)
            return "Unsupported pixel format: \(fourCC)"
        case .invalidPixelBuffer:
            return "Invalid pixel buffer"
        case .conversionFailed(let code):
            return "YCbCr conversion failed with error code: \(code)"
        case .scaleFailed(let code):
            return "Scaling failed with error code: \(code)"
        case .invalidDataSize:
            return "Invalid data size"
        }
    }
}
