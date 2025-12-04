//
//  SpatialIndexer.swift
//  RGB2GIF
//
//  ============================================================================
//  SPATIAL COLOR INDEXER - Luminance-Ordered 8x8x4 RGB Cube
//  ============================================================================
//
//  PURPOSE: Map any RGB color to a deterministic palette index (0-255)
//
//  WHY SPATIAL INDEXING?
//  ----------------------
//  Traditional quantizers (like Octree) assign indices arbitrarily:
//    - GIF A: Index 0 = #FF0000 (red)
//    - GIF B: Index 0 = #0000FF (blue)
//    - Swapping palettes produces NONSENSE
//
//  Spatial indexing uses a FIXED mapping:
//    - Index 0 = darkest bucket (always)
//    - Index 127 = mid-gray bucket (always)
//    - Index 255 = brightest bucket (always)
//    - Swapping palettes produces MEANINGFUL color shifts
//
//  THE 8x8x4 RGB CUBE
//  ------------------
//  We divide the RGB color space into 256 buckets:
//    - Red: 8 levels (3 bits, values 0-7)
//    - Green: 8 levels (3 bits, values 0-7)
//    - Blue: 4 levels (2 bits, values 0-3)
//    - Total: 8 x 8 x 4 = 256 buckets EXACTLY
//
//  Blue has fewer levels because:
//    1. Human vision is least sensitive to blue
//    2. 8x8x8 = 512 (too many)
//    3. 6x6x7 = 252 (doesn't fill palette)
//    4. 8x8x4 = 256 (perfect fit!)
//
//  LUMINANCE ORDERING
//  ------------------
//  Instead of ordering buckets by raw bit values (000→111), we sort by
//  perceived brightness using the luminance formula:
//
//    Y = 0.299*R + 0.587*G + 0.114*B
//
//  This ensures:
//    - Dark colors get low indices
//    - Bright colors get high indices
//    - Palette swaps maintain relative brightness
//    - LZW compresses better (smooth gradients = similar indices)
//
//  USAGE
//  -----
//  1. Collect all 531,441 pixels from 81 frames
//  2. For each pixel: bucket = SpatialIndexer.bucketFor(r, g, b)
//  3. For each bucket: palette[index] = average of all pixels in bucket
//  4. For each pixel: index = SpatialIndexer.indexFor(r, g, b)
//  5. Write GIF with the palette and indexed frames
//
//  THE PALETTE IS PER-GIF, BUT THE INDEX MAPPING IS UNIVERSAL
//
//  ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "SpatialIndexer")

// MARK: - Spatial Indexer

/// Maps RGB colors to luminance-ordered palette indices using an 8x8x4 cube.
/// This enables composable GIFs where palette swaps produce meaningful results.
///
/// ## Design Philosophy
/// Traditional GIF quantizers (Octree, Median Cut) produce per-GIF index mappings
/// that are arbitrary and incompatible. Spatial indexing uses a FIXED mapping
/// where index 0 is always "darkest" and index 255 is always "brightest".
///
/// ## Example
/// ```swift
/// // Index a pixel
/// let index = SpatialIndexer.indexFor(r: 128, g: 64, b: 192)
///
/// // Build palette from video frames
/// let palette = try SpatialIndexer.buildPalette(from: frames)
/// ```
@available(iOS 26.0, *)
public struct SpatialIndexer: Sendable {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ════════════════════════════════════════════════════════════════════════

    /// Number of levels per color channel (8x8x4 = 256 buckets)
    public static let redLevels: Int = 8
    public static let greenLevels: Int = 8
    public static let blueLevels: Int = 4

    /// Total number of buckets (must equal 256 for GIF)
    public static let totalBuckets: Int = redLevels * greenLevels * blueLevels

    /// Precomputed luminance-to-index lookup table
    /// bucket[rawBucketIndex] → sorted palette index (0-255)
    public static let bucketToIndex: [UInt8] = buildLuminanceTable()

    /// Inverse table: index[paletteIndex] → raw bucket
    /// Used when you need to know which bucket a palette index represents
    public static let indexToBucket: [UInt8] = buildInverseTable()

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Core Indexing Functions
    // ════════════════════════════════════════════════════════════════════════

    /// Convert RGB color to raw bucket number (not luminance-ordered)
    ///
    /// The raw bucket uses direct bit encoding:
    /// - R: bits 5-7 (values 0-7)
    /// - G: bits 2-4 (values 0-7)
    /// - B: bits 0-1 (values 0-3)
    ///
    /// - Parameters:
    ///   - r: Red component (0-255)
    ///   - g: Green component (0-255)
    ///   - b: Blue component (0-255)
    /// - Returns: Raw bucket number (0-255)
    @inlinable
    public static func rawBucketFor(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        // Quantize: divide 256 levels into 8/8/4 buckets
        let rBucket = r >> 5  // 0-7 (top 3 bits)
        let gBucket = g >> 5  // 0-7 (top 3 bits)
        let bBucket = b >> 6  // 0-3 (top 2 bits)

        // Pack into single byte: RRR_GGG_BB
        return (rBucket << 5) | (gBucket << 2) | bBucket
    }

    /// Convert RGB color to luminance-ordered palette index
    ///
    /// This is the PRIMARY indexing function. Use this when writing GIF pixels.
    ///
    /// The returned index is sorted by luminance:
    /// - Index 0 = darkest possible color (black region)
    /// - Index 255 = brightest possible color (white region)
    ///
    /// - Parameters:
    ///   - r: Red component (0-255)
    ///   - g: Green component (0-255)
    ///   - b: Blue component (0-255)
    /// - Returns: Luminance-ordered palette index (0-255)
    @inlinable
    public static func indexFor(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let rawBucket = rawBucketFor(r: r, g: g, b: b)
        return bucketToIndex[Int(rawBucket)]
    }

    /// Convert palette index back to bucket center color
    ///
    /// Returns the "representative" RGB color for a palette index.
    /// Useful for generating default palettes or debugging.
    ///
    /// - Parameter index: Palette index (0-255)
    /// - Returns: Tuple of (R, G, B) center values for the bucket
    public static func centerColorFor(index: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        let rawBucket = indexToBucket[Int(index)]

        // Extract bucket components
        let rBucket = (rawBucket >> 5) & 0x07  // 0-7
        let gBucket = (rawBucket >> 2) & 0x07  // 0-7
        let bBucket = rawBucket & 0x03          // 0-3

        // Convert to center values (middle of each bucket range)
        // R bucket 0 → values 0-31, center = 16
        // R bucket 7 → values 224-255, center = 240
        let r = UInt8(Int(rBucket) * 32 + 16)
        let g = UInt8(Int(gBucket) * 32 + 16)
        let b = UInt8(Int(bBucket) * 64 + 32)

        return (r, g, b)
    }

    /// Calculate luminance (perceived brightness) of an RGB color
    ///
    /// Uses ITU-R BT.601 coefficients:
    /// - Red: 0.299 (human eye is moderately sensitive)
    /// - Green: 0.587 (human eye is MOST sensitive)
    /// - Blue: 0.114 (human eye is LEAST sensitive)
    ///
    /// - Parameters:
    ///   - r: Red component (0-255)
    ///   - g: Green component (0-255)
    ///   - b: Blue component (0-255)
    /// - Returns: Luminance value (0.0 - 255.0)
    @inlinable
    public static func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        return 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Building
    // ════════════════════════════════════════════════════════════════════════

    /// Accumulator for collecting pixels per bucket
    public struct BucketAccumulator: Sendable {
        /// Sum of red values for all pixels in this bucket
        public var redSum: UInt64 = 0
        /// Sum of green values for all pixels in this bucket
        public var greenSum: UInt64 = 0
        /// Sum of blue values for all pixels in this bucket
        public var blueSum: UInt64 = 0
        /// Number of pixels in this bucket
        public var count: UInt64 = 0

        /// Calculate average color for this bucket
        public var averageColor: (r: UInt8, g: UInt8, b: UInt8)? {
            guard count > 0 else { return nil }
            return (
                r: UInt8(redSum / count),
                g: UInt8(greenSum / count),
                b: UInt8(blueSum / count)
            )
        }

        /// Add a pixel to this bucket
        public mutating func add(r: UInt8, g: UInt8, b: UInt8) {
            redSum += UInt64(r)
            greenSum += UInt64(g)
            blueSum += UInt64(b)
            count += 1
        }
    }

    /// Build a 256-color palette from image pixel data
    ///
    /// This function:
    /// 1. Assigns each pixel to its spatial bucket
    /// 2. Computes the average color for each bucket
    /// 3. For empty buckets, uses the bucket center color
    /// 4. Returns palette in luminance order
    ///
    /// - Parameter pixels: Array of (R, G, B) tuples
    /// - Returns: Array of 256 RGB colors in luminance order
    public static func buildPalette(from pixels: [(r: UInt8, g: UInt8, b: UInt8)]) -> [(r: UInt8, g: UInt8, b: UInt8)] {

        // Step 1: Create accumulators for each raw bucket
        var buckets = [BucketAccumulator](repeating: BucketAccumulator(), count: 256)

        // Step 2: Assign each pixel to its bucket
        for pixel in pixels {
            let rawBucket = Int(rawBucketFor(r: pixel.r, g: pixel.g, b: pixel.b))
            buckets[rawBucket].add(r: pixel.r, g: pixel.g, b: pixel.b)
        }

        // Step 3: Build palette in luminance order
        var palette = [(r: UInt8, g: UInt8, b: UInt8)](repeating: (0, 0, 0), count: 256)

        for paletteIndex in 0..<256 {
            // Find the raw bucket for this luminance-ordered index
            let rawBucket = Int(indexToBucket[paletteIndex])

            // Use average color if bucket has pixels, otherwise use center
            if let avgColor = buckets[rawBucket].averageColor {
                palette[paletteIndex] = avgColor
            } else {
                // Empty bucket: use theoretical center color
                palette[paletteIndex] = centerColorFor(index: UInt8(paletteIndex))
            }
        }

        #if DEBUG
        let filledBuckets = buckets.filter { $0.count > 0 }.count
        logger.debug("Built palette from \(pixels.count) pixels, \(filledBuckets)/256 buckets used")
        #endif

        return palette
    }

    /// Convert RGB pixel data to indexed pixels
    ///
    /// - Parameter pixels: Array of (R, G, B) tuples
    /// - Returns: Array of palette indices (0-255)
    public static func indexPixels(_ pixels: [(r: UInt8, g: UInt8, b: UInt8)]) -> [UInt8] {
        return pixels.map { indexFor(r: $0.r, g: $0.g, b: $0.b) }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Private: Lookup Table Generation
    // ════════════════════════════════════════════════════════════════════════

    /// Build the luminance-ordered lookup table (computed once at load time)
    ///
    /// This precomputes the mapping from raw bucket → luminance-sorted index
    private static func buildLuminanceTable() -> [UInt8] {
        // Step 1: Calculate luminance for each of 256 raw buckets
        var bucketLuminances: [(rawBucket: Int, luminance: Double)] = []

        for rawBucket in 0..<256 {
            // Extract bucket components from raw encoding
            let rBucket = (rawBucket >> 5) & 0x07  // 0-7
            let gBucket = (rawBucket >> 2) & 0x07  // 0-7
            let bBucket = rawBucket & 0x03          // 0-3

            // Calculate center color for this bucket
            let r = rBucket * 32 + 16  // Center of range (e.g., 0-31 → 16)
            let g = gBucket * 32 + 16
            let b = bBucket * 64 + 32  // Larger range for blue (0-63 → 32)

            // Calculate luminance
            let lum = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            bucketLuminances.append((rawBucket, lum))
        }

        // Step 2: Sort by luminance (darkest first)
        bucketLuminances.sort { $0.luminance < $1.luminance }

        // Step 3: Build lookup table: rawBucket → sorted index
        var table = [UInt8](repeating: 0, count: 256)
        for (sortedIndex, item) in bucketLuminances.enumerated() {
            table[item.rawBucket] = UInt8(sortedIndex)
        }

        return table
    }

    /// Build the inverse table: sorted index → raw bucket
    private static func buildInverseTable() -> [UInt8] {
        var inverse = [UInt8](repeating: 0, count: 256)
        for (rawBucket, sortedIndex) in bucketToIndex.enumerated() {
            inverse[Int(sortedIndex)] = UInt8(rawBucket)
        }
        return inverse
    }
}

// MARK: - Debug Visualization

@available(iOS 26.0, *)
extension SpatialIndexer {

    /// Print the luminance-ordered bucket table for debugging
    public static func printBucketTable() {
        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║  SPATIAL INDEXER: Luminance-Ordered Bucket Table              ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  Index │ Raw Bucket │ Center RGB       │ Luminance           ║")
        print("╠════════╪════════════╪══════════════════╪═════════════════════╣")

        for i in stride(from: 0, to: 256, by: 16) {
            let center = centerColorFor(index: UInt8(i))
            let lum = luminance(r: center.r, g: center.g, b: center.b)
            let rawBucket = indexToBucket[i]
            print(String(format: "║  %3d   │    0x%02X    │ (%3d, %3d, %3d)   │ %6.1f              ║",
                        i, rawBucket, center.r, center.g, center.b, lum))
        }

        print("╚═══════════════════════════════════════════════════════════════╝")
    }

    /// Generate a grayscale palette (for testing palette swap)
    public static func grayscalePalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let gray = UInt8(i)
            return (gray, gray, gray)
        }
    }

    /// Generate a "sepia" palette (for testing palette swap)
    public static func sepiaPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let lum = Double(i)
            let r = UInt8(min(255, lum * 1.2))
            let g = UInt8(lum * 0.9)
            let b = UInt8(lum * 0.6)
            return (r, g, b)
        }
    }

    /// Generate an "inverted" palette (bright becomes dark)
    public static func invertedPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let center = centerColorFor(index: UInt8(255 - i))
            return center
        }
    }
}

// MARK: - CGImage Extension

import CoreGraphics

@available(iOS 26.0, *)
extension SpatialIndexer {

    /// Extract RGB pixels from a CGImage
    ///
    /// - Parameter image: Source image
    /// - Returns: Array of (R, G, B) tuples
    /// - Throws: If image data cannot be accessed
    public static func extractPixels(from image: CGImage) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        // Create buffer for pixel data
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        // Create context and draw image
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw IndexerError.contextCreationFailed
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to RGB tuples
        var pixels = [(r: UInt8, g: UInt8, b: UInt8)]()
        pixels.reserveCapacity(width * height)

        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = pixelData[i]
            let g = pixelData[i + 1]
            let b = pixelData[i + 2]
            // Alpha at pixelData[i + 3] is ignored
            pixels.append((r, g, b))
        }

        return pixels
    }

    /// Index a CGImage directly
    ///
    /// - Parameter image: Source image (will be quantized to 256 colors)
    /// - Returns: Tuple of (palette, indexed pixels)
    public static func indexImage(_ image: CGImage) throws -> (palette: [(r: UInt8, g: UInt8, b: UInt8)], indices: [UInt8]) {
        let pixels = try extractPixels(from: image)
        let palette = buildPalette(from: pixels)
        let indices = indexPixels(pixels)
        return (palette, indices)
    }

    /// Errors that can occur during indexing
    public enum IndexerError: Error, LocalizedError {
        case contextCreationFailed
        case invalidImageData

        public var errorDescription: String? {
            switch self {
            case .contextCreationFailed:
                return "Failed to create graphics context for pixel extraction"
            case .invalidImageData:
                return "Image data could not be read"
            }
        }
    }
}
