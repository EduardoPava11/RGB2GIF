//
//  CenterCropper.swift
//  RGB2GIF
//
//  ============================================================================
//  CENTER CROPPER - Extract Square Region from Non-Square Frames
//  ============================================================================
//
//  PURPOSE: Camera frames are typically 16:9 or 4:3 (not square).
//           Before quantization, we must crop to a square region.
//
//  WHY CENTER CROP?
//  -----------------
//  1. Camera output is non-square (e.g., 1920×1080, 1280×720)
//  2. Our 81×81 GIF requires square input
//  3. Center crop preserves the most important content
//  4. Alternatives (letterbox, stretch) distort the image
//
//  ALGORITHM
//  ----------
//  1. Find the shorter dimension (usually height for landscape)
//  2. Calculate crop origin to center the square
//  3. Extract the square region
//  4. Resize to 81×81 using high-quality interpolation
//
//  EXAMPLE
//  --------
//  Input: 1920×1080 (16:9 landscape)
//  Short side: 1080
//  Crop origin: ((1920-1080)/2, 0) = (420, 0)
//  Crop region: (420, 0, 1080, 1080)
//  Output: 1080×1080 square
//  Final: 81×81 after resize
//
//  USAGE
//  -----
//  let squareImage = try CenterCropper.cropToSquare(image)
//  let finalImage = try CenterCropper.cropAndResize(image, to: 81)
//
//  ============================================================================

import Foundation
import CoreGraphics
import CoreImage
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "CenterCropper")

// MARK: - Center Cropper

/// Crops images to square aspect ratio from center, then resizes to target dimension.
/// Required preprocessing step for the 81×81×81 GIF pipeline.
///
/// ## Why Center Crop?
/// Camera frames are typically 16:9 (1920×1080) or 4:3 (1280×960).
/// Our GIF format requires exactly 81×81 pixels. Center cropping:
/// - Preserves the most important content (usually centered)
/// - Avoids letterboxing (black bars waste palette entries)
/// - Avoids stretching (distorts content)
///
/// ## Example
/// ```swift
/// // Crop and resize in one step
/// let frame81 = try CenterCropper.cropAndResize(cameraFrame, to: 81)
///
/// // Or crop first, then resize separately
/// let square = try CenterCropper.cropToSquare(cameraFrame)
/// ```
@available(iOS 26.0, *)
public struct CenterCropper {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ════════════════════════════════════════════════════════════════════════

    /// Interpolation quality for resize operation
    public enum InterpolationQuality {
        /// Fastest, lowest quality (nearest neighbor)
        case low
        /// Balanced quality and speed (bilinear)
        case medium
        /// Highest quality, slower (Lanczos)
        case high

        var cgInterpolation: CGInterpolationQuality {
            switch self {
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            }
        }
    }

    /// Default target dimension for RGB2GIF
    public static let defaultTargetDimension: Int = 81

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Public API
    // ════════════════════════════════════════════════════════════════════════

    /// Crop image to square aspect ratio from center.
    ///
    /// This extracts the largest possible square from the center of the image.
    /// The square's side length equals the shorter dimension of the input.
    ///
    /// - Parameter image: Input image (any aspect ratio)
    /// - Returns: Square image (dimension = min(width, height))
    /// - Throws: `CropperError` if operation fails
    public static func cropToSquare(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height

        // Already square? Return as-is
        if width == height {
            logger.debug("CenterCropper: Image already square (\(width)×\(height))")
            return image
        }

        // Calculate crop region
        let sideLength = min(width, height)
        let cropX = (width - sideLength) / 2
        let cropY = (height - sideLength) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: sideLength, height: sideLength)

        logger.debug("CenterCropper: Cropping \(width)×\(height) to \(sideLength)×\(sideLength) at (\(cropX), \(cropY))")

        // Perform crop
        guard let croppedImage = image.cropping(to: cropRect) else {
            throw CropperError.cropFailed(width: width, height: height, rect: cropRect)
        }

        return croppedImage
    }

    /// Crop to square and resize to target dimension in one operation.
    ///
    /// This is the primary function for the RGB2GIF pipeline. It:
    /// 1. Crops the image to a square from center
    /// 2. Resizes to the target dimension (typically 81×81)
    ///
    /// - Parameters:
    ///   - image: Input image (any aspect ratio)
    ///   - targetDimension: Output size (width = height = targetDimension)
    ///   - quality: Interpolation quality for resize (default: high)
    /// - Returns: Square image at target dimension
    /// - Throws: `CropperError` if operation fails
    public static func cropAndResize(
        _ image: CGImage,
        to targetDimension: Int = defaultTargetDimension,
        quality: InterpolationQuality = .high
    ) throws -> CGImage {

        // Step 1: Crop to square
        let squareImage = try cropToSquare(image)

        // If already at target size, return
        if squareImage.width == targetDimension && squareImage.height == targetDimension {
            logger.debug("CenterCropper: Image already at target size (\(targetDimension)×\(targetDimension))")
            return squareImage
        }

        // Step 2: Resize to target dimension
        return try resize(squareImage, to: targetDimension, quality: quality)
    }

    /// Resize an image to the specified dimensions.
    ///
    /// - Parameters:
    ///   - image: Input image
    ///   - targetDimension: Output dimension (square)
    ///   - quality: Interpolation quality
    /// - Returns: Resized image
    /// - Throws: `CropperError` if resize fails
    public static func resize(
        _ image: CGImage,
        to targetDimension: Int,
        quality: InterpolationQuality = .high
    ) throws -> CGImage {

        let targetWidth = targetDimension
        let targetHeight = targetDimension

        // Create context for drawing
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CropperError.colorSpaceCreationFailed
        }

        // Use same bitmap info as source, or default to RGBA
        let bitmapInfo = image.bitmapInfo.rawValue != 0
            ? image.bitmapInfo.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CropperError.contextCreationFailed
        }

        // Set interpolation quality
        context.interpolationQuality = quality.cgInterpolation

        // Draw image scaled to target size
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        // Extract result
        guard let resizedImage = context.makeImage() else {
            throw CropperError.resizeFailed(
                sourceWidth: image.width,
                sourceHeight: image.height,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        }

        logger.debug("CenterCropper: Resized \(image.width)×\(image.height) to \(targetWidth)×\(targetHeight)")

        return resizedImage
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Batch Processing
    // ════════════════════════════════════════════════════════════════════════

    /// Process multiple frames in parallel.
    ///
    /// Uses concurrent execution for better performance on multi-core devices.
    ///
    /// - Parameters:
    ///   - images: Array of input images
    ///   - targetDimension: Output dimension for all images
    ///   - quality: Interpolation quality
    /// - Returns: Array of cropped and resized images
    /// - Throws: `CropperError` if any frame fails
    public static func cropAndResizeBatch(
        _ images: [CGImage],
        to targetDimension: Int = defaultTargetDimension,
        quality: InterpolationQuality = .high
    ) async throws -> [CGImage] {

        logger.info("CenterCropper: Processing batch of \(images.count) frames")

        return try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            // Launch parallel tasks
            for (index, image) in images.enumerated() {
                group.addTask {
                    let result = try cropAndResize(image, to: targetDimension, quality: quality)
                    return (index, result)
                }
            }

            // Collect results in order
            var results = [(Int, CGImage)]()
            results.reserveCapacity(images.count)

            for try await result in group {
                results.append(result)
            }

            // Sort by original index and extract images
            results.sort { $0.0 < $1.0 }
            return results.map { $0.1 }
        }
    }

    /// Process frames from a collection sequentially (for memory-constrained scenarios).
    ///
    /// - Parameters:
    ///   - images: Sequence of input images
    ///   - targetDimension: Output dimension
    ///   - quality: Interpolation quality
    ///   - progress: Optional progress callback (index, total)
    /// - Returns: Array of processed images
    public static func cropAndResizeSequential(
        _ images: [CGImage],
        to targetDimension: Int = defaultTargetDimension,
        quality: InterpolationQuality = .high,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [CGImage] {

        var results = [CGImage]()
        results.reserveCapacity(images.count)

        for (index, image) in images.enumerated() {
            let processed = try cropAndResize(image, to: targetDimension, quality: quality)
            results.append(processed)

            progress?(index + 1, images.count)
        }

        return results
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
extension CenterCropper {

    /// Errors that can occur during cropping operations
    public enum CropperError: Error, LocalizedError {
        case cropFailed(width: Int, height: Int, rect: CGRect)
        case resizeFailed(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int)
        case contextCreationFailed
        case colorSpaceCreationFailed

        public var errorDescription: String? {
            switch self {
            case .cropFailed(let w, let h, let rect):
                return "Failed to crop \(w)×\(h) image at rect \(rect)"
            case .resizeFailed(let sw, let sh, let tw, let th):
                return "Failed to resize \(sw)×\(sh) to \(tw)×\(th)"
            case .contextCreationFailed:
                return "Failed to create graphics context"
            case .colorSpaceCreationFailed:
                return "Failed to create color space"
            }
        }
    }
}

// MARK: - Aspect Ratio Helpers

@available(iOS 26.0, *)
extension CenterCropper {

    /// Calculate the crop rectangle for centering a square within an image.
    ///
    /// - Parameters:
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: CGRect for the centered square crop
    public static func centerCropRect(width: Int, height: Int) -> CGRect {
        let sideLength = min(width, height)
        let x = (width - sideLength) / 2
        let y = (height - sideLength) / 2
        return CGRect(x: x, y: y, width: sideLength, height: sideLength)
    }

    /// Get the aspect ratio of an image.
    ///
    /// - Parameter image: Input image
    /// - Returns: Aspect ratio (width / height)
    public static func aspectRatio(of image: CGImage) -> Double {
        return Double(image.width) / Double(image.height)
    }

    /// Check if an image is already square (within tolerance).
    ///
    /// - Parameters:
    ///   - image: Input image
    ///   - tolerance: Maximum difference in pixels (default: 0)
    /// - Returns: True if width and height are within tolerance
    public static func isSquare(_ image: CGImage, tolerance: Int = 0) -> Bool {
        return abs(image.width - image.height) <= tolerance
    }
}

// MARK: - Debug Visualization

@available(iOS 26.0, *)
extension CenterCropper {

    /// Print crop information for debugging.
    public static func printCropInfo(for image: CGImage, targetDimension: Int = 81) {
        let width = image.width
        let height = image.height
        let aspectRatio = Double(width) / Double(height)

        let cropRect = centerCropRect(width: width, height: height)
        let scaleRatio = Double(min(width, height)) / Double(targetDimension)

        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║  CENTER CROPPER: Crop Analysis                                 ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  Input:  \(String(format: "%4d", width)) × \(String(format: "%4d", height)) pixels (aspect: \(String(format: "%.2f", aspectRatio)))           ║")
        print("║  Crop:   \(String(format: "%4d", Int(cropRect.width))) × \(String(format: "%4d", Int(cropRect.height))) at (\(String(format: "%3d", Int(cropRect.origin.x))), \(String(format: "%3d", Int(cropRect.origin.y))))                  ║")
        print("║  Output: \(String(format: "%4d", targetDimension)) × \(String(format: "%4d", targetDimension)) pixels (scale: \(String(format: "%.2f", scaleRatio))×)           ║")
        print("╚═══════════════════════════════════════════════════════════════╝")
    }
}
