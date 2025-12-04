//
//  FrameFormatConverter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  EXPLICIT FORMAT CONVERSION - BGRA→RGB                                    ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Camera outputs BGRA (byteOrder32Little, premultipliedFirst):             ║
//  ║    Memory: [B G R A] [B G R A] [B G R A] ...                             ║
//  ║                                                                           ║
//  ║  We need RGB (3 bytes per pixel, no alpha):                              ║
//  ║    Memory: [R G B] [R G B] [R G B] ...                                   ║
//  ║                                                                           ║
//  ║  CGContext.draw() DOES NOT correctly convert byte order!                 ║
//  ║  We must explicitly read B,G,R bytes and write R,G,B.                    ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import os.log

private let formatLogger = Logger(subsystem: "com.rgb2gif", category: "FrameFormatConverter")

@available(iOS 26.0, *)
public struct FrameFormatConverter {

    // MARK: - BGRA → RGB Conversion

    /// Extract pure RGB data from a BGRA CGImage
    /// Camera frames are BGRA (byteOrder32Little, premultipliedFirst)
    /// Output: 3 bytes per pixel (R, G, B), no alpha
    ///
    /// - Parameter image: Source CGImage in BGRA format
    /// - Returns: RGB Data (width × height × 3 bytes)
    public static func bgraToRGB(image: CGImage) -> Data {
        guard let provider = image.dataProvider,
              let pixelData = provider.data,
              let bytes = CFDataGetBytePtr(pixelData) else {
            formatLogger.error("Failed to get pixel data from CGImage")
            return Data()
        }

        let width = image.width
        let height = image.height
        let srcBytesPerRow = image.bytesPerRow
        let srcBytesPerPixel = image.bitsPerPixel / 8
        let dataLength = CFDataGetLength(pixelData)

        formatLogger.debug("bgraToRGB: \(width)×\(height), bytesPerRow=\(srcBytesPerRow), bpp=\(srcBytesPerPixel), dataLen=\(dataLength)")

        var rgb = Data(capacity: width * height * 3)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * srcBytesPerRow + x * srcBytesPerPixel
                guard offset + 3 <= dataLength else {
                    // Pad with black if data is truncated
                    rgb.append(contentsOf: [0, 0, 0])
                    continue
                }

                // BGRA layout (little-endian with premultiplied first alpha):
                // Byte 0 = Blue
                // Byte 1 = Green
                // Byte 2 = Red
                // Byte 3 = Alpha (discarded)
                let b = bytes[offset + 0]
                let g = bytes[offset + 1]
                let r = bytes[offset + 2]

                // Output as RGB
                rgb.append(r)
                rgb.append(g)
                rgb.append(b)
            }
        }

        return rgb
    }

    // MARK: - RGB → CGImage Conversion (for PNG export)

    /// Create a CGImage from RGB data (for verification PNGs)
    /// - Parameters:
    ///   - rgb: RGB data (3 bytes per pixel)
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: CGImage or nil on failure
    public static func rgbToCGImage(rgb: Data, width: Int, height: Int) -> CGImage? {
        guard rgb.count == width * height * 3 else {
            formatLogger.error("RGB data size mismatch: got \(rgb.count), expected \(width * height * 3)")
            return nil
        }

        // Convert RGB to RGBA (add alpha = 255)
        var rgba = Data(capacity: width * height * 4)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            rgba.append(rgb[i])     // R
            rgba.append(rgb[i + 1]) // G
            rgba.append(rgb[i + 2]) // B
            rgba.append(255)        // A
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard let provider = CGDataProvider(data: rgba as CFData) else {
            formatLogger.error("Failed to create CGDataProvider")
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Center Crop to Square (LEGACY - DO NOT USE)

    /// Center-crop an image to a square
    /// - Parameter image: Source image (any aspect ratio)
    /// - Returns: Square CGImage (cropped to center)
    ///
    /// ⚠️ WARNING: This uses `CGImage.cropping(to:)` which creates a CGImage that
    /// SHARES pixel data with the original. This can cause issues when the cropped
    /// image is later drawn to a context - CoreGraphics may misinterpret the data layout.
    ///
    /// **PREFER `safeCropAndResizeToRGB()` instead** which does crop+resize in one step.
    @available(*, deprecated, message: "Use safeCropAndResizeToRGB instead - CGImage.cropping() causes data corruption")
    public static func centerCropToSquare(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let size = min(width, height)

        let cropX = (width - size) / 2
        let cropY = (height - size) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: size, height: size)

        return image.cropping(to: cropRect)
    }

    // MARK: - Safe Crop + Resize (Single Operation)

    /// Crop to center square AND resize to target size in ONE operation
    /// Uses UIGraphicsImageRenderer for reliable coordinate handling.
    ///
    /// - Parameters:
    ///   - image: Source CGImage (any size, any format)
    ///   - targetSize: Output size (both width and height)
    /// - Returns: RGB Data (targetSize × targetSize × 3 bytes), top-to-bottom row order
    ///
    /// ## How it works:
    /// 1. Convert to UIImage (handles all coordinate system issues)
    /// 2. Use UIGraphicsImageRenderer to crop+resize in one pass
    /// 3. Extract RGB from result (UIKit uses top-left origin, no flipping needed)
    ///
    /// This approach avoids CGContext coordinate confusion that caused the
    /// "thin strip at top, gray below" bug.
    public static func safeCropAndResizeToRGB(_ image: CGImage, targetSize: Int) -> Data {
        // Use manual pixel mapping - bypasses all CGContext coordinate confusion
        // This approach directly reads source pixels and writes to output buffer
        // with explicit, verifiable coordinate math that matches the test expectations
        return manualCropAndResizeToRGB(image, targetSize: targetSize)
    }

    /// Fixed implementation using CGContext with correct coordinate handling
    ///
    /// ## BUG FIX (2024-12-03): Edge Interpolation Artifacts
    /// Previous approach: Draw full image at fractional offset, causing CoreGraphics to
    /// interpolate with pixels OUTSIDE the crop region (e.g., bright sky bleeds into top edge).
    ///
    /// New approach: First crop to exact pixel boundaries using CGImage.cropping(), then
    /// render the cropped image to a SEPARATE context to get clean pixel data (avoiding the
    /// data-sharing issue with cropping), then resize that clean crop.
    private static func safeCropAndResizeToRGB_Fixed(_ image: CGImage, targetSize: Int) -> Data {
        let srcWidth = image.width
        let srcHeight = image.height
        let cropSize = min(srcWidth, srcHeight)
        let cropX = (srcWidth - cropSize) / 2
        let cropY = (srcHeight - cropSize) / 2

        formatLogger.debug("safeCropAndResize: \(srcWidth)×\(srcHeight) → crop \(cropSize)×\(cropSize) at (\(cropX),\(cropY)) → \(targetSize)×\(targetSize)")

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 1: Crop to exact pixel boundaries
        // This ensures no interpolation with pixels outside the crop region
        // ═══════════════════════════════════════════════════════════════════════
        let cropRect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize)
        guard let croppedImage = image.cropping(to: cropRect) else {
            formatLogger.error("Failed to crop image")
            return Data()
        }

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 2: Create output context and draw cropped image scaled to fit
        // The cropped image has no pixels outside the crop region, so interpolation
        // at edges will only blend within the valid crop area
        // ═══════════════════════════════════════════════════════════════════════
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = targetSize * 4
        var pixelBuffer = [UInt8](repeating: 0, count: bytesPerRow * targetSize)

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard let context = CGContext(
            data: &pixelBuffer,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            formatLogger.error("Failed to create context for safeCropAndResize")
            return Data()
        }

        context.interpolationQuality = .high

        // Flip context to top-left origin (like UIKit)
        context.translateBy(x: 0, y: CGFloat(targetSize))
        context.scaleBy(x: 1, y: -1)

        // Draw the cropped image scaled to fill the entire context
        // Position (0,0), size (targetSize, targetSize) - no fractional offsets!
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        // Extract RGB from RGBA buffer
        // IMPORTANT: Even with the context flip, the pixel buffer layout is:
        //   buffer row 0 = device Y=0 = bottom of rendered image
        //   buffer row H-1 = device Y=H-1 = top of rendered image
        // So we MUST read rows in reverse order to get top-to-bottom output!
        var rgb = Data(capacity: targetSize * targetSize * 3)

        for y in (0..<targetSize).reversed() {  // Read bottom-to-top from buffer → top-to-bottom in output
            for x in 0..<targetSize {
                let offset = y * bytesPerRow + x * 4
                // RGBA layout (big-endian byte order):
                let r = pixelBuffer[offset + 0]
                let g = pixelBuffer[offset + 1]
                let b = pixelBuffer[offset + 2]

                rgb.append(r)
                rgb.append(g)
                rgb.append(b)
            }
        }

        // Debug: log some pixels
        if rgb.count >= 15 {
            let p0 = "(\(rgb[0]),\(rgb[1]),\(rgb[2]))"
            let pMid = "(\(rgb[rgb.count/2]),\(rgb[rgb.count/2+1]),\(rgb[rgb.count/2+2]))"
            let pEnd = "(\(rgb[rgb.count-3]),\(rgb[rgb.count-2]),\(rgb[rgb.count-1]))"
            formatLogger.debug("safeCropAndResize result: first=\(p0) mid=\(pMid) last=\(pEnd)")
        }

        return rgb
    }

    // MARK: - Resize with Explicit RGB Output (LEGACY)

    /// Resize a BGRA image to target size and output as pure RGB Data
    /// - Parameters:
    ///   - image: Source CGImage (BGRA format from camera OR pre-cropped square)
    ///   - targetSize: Target width and height
    ///   - alreadyCropped: If true, skip the centerCrop step (image is already square)
    /// - Returns: RGB Data (targetSize × targetSize × 3 bytes)
    ///
    /// ⚠️ DEPRECATED: This function has issues with CGImage.cropping() data corruption.
    /// Use `safeCropAndResizeToRGB()` instead for new code.
    @available(*, deprecated, message: "Use safeCropAndResizeToRGB instead")
    public static func resizeBGRAToRGB(_ image: CGImage, targetSize: Int, alreadyCropped: Bool = false) -> Data {
        // REDIRECT to safe implementation
        return safeCropAndResizeToRGB(image, targetSize: targetSize)
    }

    // MARK: - Save RGB as PNG

    /// Save RGB data as a PNG file for verification
    /// - Parameters:
    ///   - rgb: RGB data
    ///   - width: Image width
    ///   - height: Image height
    ///   - url: Destination URL
    public static func saveRGBAsPNG(rgb: Data, width: Int, height: Int, to url: URL) throws {
        guard let cgImage = rgbToCGImage(rgb: rgb, width: width, height: height) else {
            throw RGB2GIFError.cborExportFailed("Failed to create CGImage from RGB data")
        }

        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else {
            throw RGB2GIFError.cborExportFailed("Failed to create PNG data")
        }
        try pngData.write(to: url)
        #else
        formatLogger.warning("PNG export not available without UIKit")
        #endif
    }

    // MARK: - Manual Pixel Mapping (Bypasses CGContext Complexity)

    /// Manual crop and resize - NO CGContext, NO coordinate transforms
    /// Directly reads source pixels and writes to output buffer
    ///
    /// This implementation bypasses all CGContext coordinate system complexity by:
    /// 1. Reading pixels directly from the CGImage's dataProvider
    /// 2. Calculating source coordinates explicitly for each output pixel
    /// 3. Using the same coordinate system as the test expects (row 0 = top)
    ///
    /// - Parameters:
    ///   - image: Source CGImage (BGRA format from camera)
    ///   - targetSize: Output size (e.g., 81 for 81x81)
    /// - Returns: RGB Data (targetSize * targetSize * 3 bytes), row 0 = visual top
    public static func manualCropAndResizeToRGB(_ image: CGImage, targetSize: Int) -> Data {
        guard let provider = image.dataProvider,
              let cfData = provider.data,
              let srcBytes = CFDataGetBytePtr(cfData) else {
            formatLogger.error("manualCropAndResize: Failed to get source pixel data")
            return Data(repeating: 0, count: targetSize * targetSize * 3)
        }

        let srcWidth = image.width
        let srcHeight = image.height
        let srcBytesPerRow = image.bytesPerRow  // CRITICAL: actual stride (may have padding)
        let dataLength = CFDataGetLength(cfData)

        // Calculate crop region (center square)
        let cropSize = min(srcWidth, srcHeight)
        let cropX = (srcWidth - cropSize) / 2
        let cropY = (srcHeight - cropSize) / 2

        // Scale factor: how many source pixels per output pixel
        let scale = Double(cropSize) / Double(targetSize)

        formatLogger.debug("manualCropAndResize: \(srcWidth)×\(srcHeight) → crop \(cropSize)×\(cropSize) at (\(cropX),\(cropY)) → \(targetSize)×\(targetSize), scale=\(String(format: "%.3f", scale))")

        var rgb = Data(capacity: targetSize * targetSize * 3)

        // Map each output pixel to source pixel (nearest-neighbor with center sampling)
        // Output row 0 = visual TOP of image
        // Source row 0 = visual TOP of image (camera frames store top-to-bottom)
        for outY in 0..<targetSize {
            for outX in 0..<targetSize {
                // Map output coordinate to source coordinate within crop region
                // Using center of output pixel (+0.5) for better sampling
                let srcXf = Double(cropX) + (Double(outX) + 0.5) * scale
                let srcYf = Double(cropY) + (Double(outY) + 0.5) * scale

                // Clamp to valid source range
                let srcX = min(max(Int(srcXf), 0), srcWidth - 1)
                let srcY = min(max(Int(srcYf), 0), srcHeight - 1)

                // Calculate source byte offset using actual bytesPerRow (handles row padding)
                let srcOffset = srcY * srcBytesPerRow + srcX * 4

                // Bounds check
                guard srcOffset + 2 < dataLength else {
                    rgb.append(contentsOf: [0, 0, 0])  // Black for out-of-bounds
                    continue
                }

                // Read BGRA (camera format: byteOrder32Little + premultipliedFirst)
                // Byte order in memory: B=0, G=1, R=2, A=3
                let b = srcBytes[srcOffset + 0]
                let g = srcBytes[srcOffset + 1]
                let r = srcBytes[srcOffset + 2]

                // Write RGB
                rgb.append(r)
                rgb.append(g)
                rgb.append(b)
            }
        }

        // Debug: log corner pixels for verification
        if rgb.count >= targetSize * targetSize * 3 {
            let tl = "TL:(\(rgb[0]),\(rgb[1]),\(rgb[2]))"
            let trOffset = (targetSize - 1) * 3
            let tr = "TR:(\(rgb[trOffset]),\(rgb[trOffset+1]),\(rgb[trOffset+2]))"
            let blOffset = (targetSize - 1) * targetSize * 3
            let bl = "BL:(\(rgb[blOffset]),\(rgb[blOffset+1]),\(rgb[blOffset+2]))"
            let brOffset = blOffset + (targetSize - 1) * 3
            let br = "BR:(\(rgb[brOffset]),\(rgb[brOffset+1]),\(rgb[brOffset+2]))"
            formatLogger.debug("manualCropAndResize corners: \(tl) \(tr) \(bl) \(br)")
        }

        return rgb
    }

    // MARK: - Debug: Dump First Pixels

    /// Log first few pixels for debugging
    public static func logFirstPixels(rgb: Data, label: String, count: Int = 5) {
        guard rgb.count >= count * 3 else { return }
        var pixels: [String] = []
        for i in 0..<count {
            let r = rgb[i * 3]
            let g = rgb[i * 3 + 1]
            let b = rgb[i * 3 + 2]
            pixels.append("(\(r),\(g),\(b))")
        }
        formatLogger.debug("\(label) first \(count) pixels: \(pixels.joined(separator: " "))")
    }
}
