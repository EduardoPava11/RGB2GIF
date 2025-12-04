//
//  PixelBufferHelpers.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  PIXEL BUFFER HELPERS - CAMERA FRAME EXTRACTION                           ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║  PURPOSE: Convert camera pixel buffers to CGImage for GIF pipeline        ║
//  ║                                                                           ║
//  ║  INPUT:  CVPixelBuffer from AVCaptureSession (NV12 or BGRA format)        ║
//  ║  OUTPUT: CGImage cropped and scaled to target dimensions                  ║
//  ║                                                                           ║
//  ║  KEY FUNCTIONS:                                                           ║
//  ║  - extractNV12ToRGB(): YUV→RGB via CIImage (GPU-accelerated)              ║
//  ║  - extractBGRA(): Direct BGRA extraction (already RGB)                    ║
//  ║  - cropAndScale(): Center crop + resize to target size                    ║
//  ║                                                                           ║
//  ║  ⚠️ POTENTIAL BUG LOCATION: "1/4 renders" issue could originate here      ║
//  ║  if CIContext.createCGImage returns wrong dimensions or pixel data        ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//
//  DEBUG FLAGS:
//  - DEBUG_PIXEL_BUFFER: Log buffer dimensions and format
//  - DEBUG_CGIMAGE_OUTPUT: Log output CGImage properties
//

import Foundation
import CoreVideo
import CoreGraphics
import CoreImage
import UIKit
import os.log

// ════════════════════════════════════════════════════════════════════════════
// DEBUG FLAGS - Set to true to enable pixel buffer tracing
// ════════════════════════════════════════════════════════════════════════════
private let DEBUG_PIXEL_BUFFER = true     // Log input buffer dimensions
private let DEBUG_CGIMAGE_OUTPUT = true   // Log output CGImage properties

private let pixelLogger = Logger(subsystem: "com.rgb2gif", category: "PixelBufferHelpers")

@available(iOS 26.0, *)
internal enum PixelBufferHelpers {

    // MARK: - Shared CIContext for efficient GPU rendering

    /// Reusable CIContext for NV12→RGB conversion (GPU-accelerated)
    private static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .useSoftwareRenderer: false,  // Prefer GPU
            .cacheIntermediates: false    // Reduce memory for streaming
        ]
        return CIContext(options: options)
    }()

    // MARK: - NV12 → RGB (Color Extraction)

    // ┌─────────────────────────────────────────────────────────────────┐
    // │ CRITICAL: NV12 → RGB conversion via CIImage                      │
    // │ This is the main path for camera frame extraction                │
    // │ ⚠️ "1/4 renders" bug could be caused by CIContext issues here    │
    // └─────────────────────────────────────────────────────────────────┘
    /// Extract CGImage from NV12 YUV buffer with PROPER COLOR conversion
    /// Uses CIImage to handle YUV→RGB matrix conversion on GPU
    /// - Parameters:
    ///   - pixelBuffer: NV12 format pixel buffer (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    ///   - targetSize: Desired output size (will be center-cropped and scaled)
    /// - Returns: CGImage with full RGB color
    static func extractNV12ToRGB(from pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> CGImage? {

        // DEBUG: Log input buffer dimensions
        if DEBUG_PIXEL_BUFFER {
            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            pixelLogger.debug("extractNV12ToRGB input: \(bufferWidth)×\(bufferHeight), format=\(String(format: "0x%08X", pixelFormat))")
        }

        // CIImage handles NV12 YUV→RGB conversion automatically via correct color matrix
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Calculate center crop rect (square crop from center)
        let sourceWidth = ciImage.extent.width
        let sourceHeight = ciImage.extent.height
        let cropDimension = min(sourceWidth, sourceHeight)
        let cropX = (sourceWidth - cropDimension) / 2
        let cropY = (sourceHeight - cropDimension) / 2

        if DEBUG_PIXEL_BUFFER {
            pixelLogger.debug("  CIImage extent: \(sourceWidth)×\(sourceHeight)")
            pixelLogger.debug("  Crop: (\(cropX), \(cropY)) \(cropDimension)×\(cropDimension)")
            pixelLogger.debug("  Target: \(targetSize.width)×\(targetSize.height)")
        }

        let cropRect = CGRect(x: cropX, y: cropY, width: cropDimension, height: cropDimension)
        let croppedImage = ciImage.cropped(to: cropRect)

        // Scale to target size
        let scaleX = targetSize.width / cropDimension
        let scaleY = targetSize.height / cropDimension
        let scaledImage = croppedImage
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Render to CGImage using shared context (GPU path)
        // IMPORTANT: Explicitly specify RGB colorspace to ensure color output (not grayscale)
        let outputRect = CGRect(origin: .zero, size: targetSize)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let result = sharedContext.createCGImage(
            scaledImage,
            from: outputRect,
            format: .RGBA8,
            colorSpace: rgbColorSpace
        )

        // ⚠️ CRITICAL CHECK: Verify output dimensions match target
        if DEBUG_CGIMAGE_OUTPUT {
            if let cgImage = result {
                if cgImage.width != Int(targetSize.width) || cgImage.height != Int(targetSize.height) {
                    pixelLogger.error("❌ SIZE MISMATCH: CGImage \(cgImage.width)×\(cgImage.height) ≠ target \(Int(targetSize.width))×\(Int(targetSize.height))")
                }
                pixelLogger.debug("  Output CGImage: \(cgImage.width)×\(cgImage.height), bytesPerRow=\(cgImage.bytesPerRow)")
            } else {
                pixelLogger.error("❌ createCGImage returned nil!")
            }
        }

        return result
    }

    /// Extract CGImage from NV12 YUV buffer using Y-plane ONLY (grayscale)
    /// NOTE: This produces GRAYSCALE output! Use extractNV12ToRGB() for color.
    /// Kept for backwards compatibility or intentional grayscale mode.
    /// - Parameters:
    ///   - pixelBuffer: NV12 format pixel buffer (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    ///   - targetSize: Desired output size (will be cropped/scaled from center)
    /// - Returns: CGImage from Y-plane luminance data (GRAYSCALE)
    static func extractYPlane(from pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Get Y-plane (plane 0 = luminance)
        guard let yPlaneAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }

        let yPlaneWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yPlaneHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yPlaneBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Create grayscale image from Y-plane
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        guard let context = CGContext(
            data: yPlaneAddress,
            width: yPlaneWidth,
            height: yPlaneHeight,
            bitsPerComponent: 8,
            bytesPerRow: yPlaneBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        guard let yPlaneImage = context.makeImage() else {
            return nil
        }

        // Crop and scale to target size (center crop)
        return cropAndScale(yPlaneImage, to: targetSize)
    }

    /// Extract CGImage from BGRA pixel buffer with center crop
    /// - Parameters:
    ///   - pixelBuffer: BGRA format pixel buffer
    ///   - targetSize: Desired output size
    /// - Returns: CGImage cropped and scaled to target size
    static func extractBGRA(from pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        guard let fullImage = context.makeImage() else {
            return nil
        }

        return cropAndScale(fullImage, to: targetSize)
    }

    /// Center-crop and scale image to target size
    /// - Parameters:
    ///   - image: Source CGImage
    ///   - targetSize: Desired square output size
    /// - Returns: Cropped and scaled CGImage
    private static func cropAndScale(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let sourceWidth = image.width
        let sourceHeight = image.height

        // Calculate center crop rect (square)
        let cropDimension = min(sourceWidth, sourceHeight)
        let cropX = (sourceWidth - cropDimension) / 2
        let cropY = (sourceHeight - cropDimension) / 2

        let cropRect = CGRect(x: cropX, y: cropY, width: cropDimension, height: cropDimension)

        guard let croppedImage = image.cropping(to: cropRect) else {
            return nil
        }

        // Scale to target size if needed
        if cropDimension != Int(targetSize.width) || cropDimension != Int(targetSize.height) {
            return scaleImage(croppedImage, to: targetSize)
        }

        return croppedImage
    }

    /// Scale CGImage to target size using high-quality interpolation
    private static func scaleImage(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo

        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))

        return context.makeImage()
    }
}
