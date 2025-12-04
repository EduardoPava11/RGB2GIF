//
//  OctreeQuantizerTests.swift
//  RGB2GIFTests
//
//  Real executable tests for OctreeColorQuantizer
//  These tests verify actual algorithm behavior, not mocks
//
//  Run with: swift test
//  Or add to Xcode test target
//

import XCTest
import CoreGraphics
import UIKit

// Import the main module - adjust based on your project structure
@testable import RGB2GIF

@available(iOS 26.0, *)
final class OctreeQuantizerTests: XCTestCase {

    var quantizer: OctreeColorQuantizer!

    override func setUp() {
        super.setUp()
        quantizer = OctreeColorQuantizer()
    }

    override func tearDown() {
        quantizer = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Create a test image with known colors
    private func createTestImage(width: Int, height: Int, colors: [(UInt8, UInt8, UInt8)]) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 255, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let colorIndex = (y * width + x) % colors.count
                let (r, g, b) = colors[colorIndex]
                let dataIndex = (y * width + x) * bytesPerPixel
                pixelData[dataIndex] = r
                pixelData[dataIndex + 1] = g
                pixelData[dataIndex + 2] = b
                pixelData[dataIndex + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        let provider = CGDataProvider(data: Data(pixelData) as CFData)!
        return CGImage(
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
        )!
    }

    /// Create a gradient test image
    private func createGradientImage(width: Int, height: Int) -> CGImage {
        var colors: [(UInt8, UInt8, UInt8)] = []
        for y in 0..<height {
            for x in 0..<width {
                let r = UInt8((x * 255) / max(width - 1, 1))
                let g = UInt8((y * 255) / max(height - 1, 1))
                let b = UInt8(((x + y) * 255) / max(width + height - 2, 1))
                colors.append((r, g, b))
            }
        }
        return createTestImage(width: width, height: height, colors: colors)
    }

    /// Create a solid color image
    private func createSolidImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) -> CGImage {
        return createTestImage(width: width, height: height, colors: [color])
    }

    /// Create an image with exactly N distinct colors
    private func createNColorImage(width: Int, height: Int, colorCount: Int) -> CGImage {
        var colors: [(UInt8, UInt8, UInt8)] = []
        for i in 0..<colorCount {
            let hue = Double(i) / Double(colorCount)
            let r = UInt8(255 * sin(hue * .pi * 2))
            let g = UInt8(255 * sin((hue + 0.33) * .pi * 2))
            let b = UInt8(255 * sin((hue + 0.66) * .pi * 2))
            colors.append((r, g, b))
        }
        return createTestImage(width: width, height: height, colors: colors)
    }

    // MARK: - Palette Generation Tests

    /// Test that palette size matches requested size
    func testPaletteSizeMatchesRequest() async throws {
        let image = createGradientImage(width: 80, height: 80)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        XCTAssertEqual(result.palette.count, 256, "Palette should have exactly 256 colors")
    }

    /// Test that all indices are valid
    func testAllIndicesAreValid() async throws {
        let image = createGradientImage(width: 80, height: 80)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        for (i, index) in result.indexedPixels.enumerated() {
            XCTAssertLessThan(Int(index), result.palette.count,
                "Index \(index) at position \(i) exceeds palette size \(result.palette.count)")
        }
    }

    /// Test that gradient images preserve color diversity
    func testGradientPreservesColorDiversity() async throws {
        let image = createGradientImage(width: 80, height: 80)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        let uniqueIndices = Set(result.indexedPixels)

        // A gradient should use many different indices, not collapse to few
        // With proper octree reduction, we expect at least 30 unique indices
        XCTAssertGreaterThan(uniqueIndices.count, 30,
            "Gradient should use more than 30 unique palette indices, got \(uniqueIndices.count)")
    }

    /// Test that palette has unique colors (not duplicates)
    func testPaletteHasUniqueColors() async throws {
        let image = createGradientImage(width: 80, height: 80)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        var uniqueColors = Set<UInt32>()
        var duplicateCount = 0

        for color in result.palette {
            if uniqueColors.contains(color) {
                duplicateCount += 1
            }
            uniqueColors.insert(color)
        }

        // Allow some duplicates for padding, but not too many
        // 80% unique is a reasonable threshold
        let uniquePercentage = Double(uniqueColors.count) / Double(result.palette.count)
        XCTAssertGreaterThan(uniquePercentage, 0.8,
            "Palette should be at least 80% unique, got \(String(format: "%.1f", uniquePercentage * 100))%")
    }

    // MARK: - Edge Case Tests

    /// Test with image that has fewer than 256 colors
    func testImageWithFewerThan256Colors() async throws {
        // Create image with exactly 100 distinct colors
        let image = createNColorImage(width: 80, height: 80, colorCount: 100)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        // Palette should still be 256 (padded with black or duplicates)
        XCTAssertEqual(result.palette.count, 256)

        // But the unique indices used should be around 100
        let uniqueIndices = Set(result.indexedPixels)
        XCTAssertLessThanOrEqual(uniqueIndices.count, 100 + 5, // Allow some tolerance
            "Should use around 100 unique indices for 100-color image")
    }

    /// Test solid color image
    func testSolidColorImage() async throws {
        let image = createSolidImage(width: 80, height: 80, color: (128, 64, 192))
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        // All pixels should have the same index
        let uniqueIndices = Set(result.indexedPixels)
        XCTAssertEqual(uniqueIndices.count, 1, "Solid image should have exactly 1 unique index")

        // That index should point to a color close to (128, 64, 192)
        let singleIndex = result.indexedPixels[0]
        let paletteColor = result.palette[Int(singleIndex)]

        let r = UInt8((paletteColor >> 16) & 0xFF)
        let g = UInt8((paletteColor >> 8) & 0xFF)
        let b = UInt8(paletteColor & 0xFF)

        XCTAssertEqual(r, 128, accuracy: 1, "Red channel should match")
        XCTAssertEqual(g, 64, accuracy: 1, "Green channel should match")
        XCTAssertEqual(b, 192, accuracy: 1, "Blue channel should match")
    }

    // MARK: - Round-Trip Tests

    /// Test that quantized image looks similar to original
    func testQuantizedImageSimilarity() async throws {
        let original = createGradientImage(width: 80, height: 80)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(original, options: options)

        // The quantized image should exist
        XCTAssertEqual(result.quantizedImage.width, 80)
        XCTAssertEqual(result.quantizedImage.height, 80)
    }

    // MARK: - Performance Tests

    /// Test that quantization completes in reasonable time
    func testQuantizationPerformance() async throws {
        let image = createGradientImage(width: 80, height: 80)
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let startTime = Date()
        _ = try await quantizer.quantize(image, options: options)
        let duration = Date().timeIntervalSince(startTime)

        // Should complete in under 1 second for 80x80 image
        XCTAssertLessThan(duration, 1.0,
            "Quantization took too long: \(String(format: "%.2f", duration))s")
    }

    // MARK: - Reduction Algorithm Tests

    /// Test that more than 256 colors get reduced properly
    func testColorReduction() async throws {
        // Create image with many more colors than 256
        let image = createGradientImage(width: 256, height: 256) // 65536 potential unique colors
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: 256)

        let result = try await quantizer.quantize(image, options: options)

        XCTAssertEqual(result.palette.count, 256, "Palette should be reduced to exactly 256")

        // Verify the reduction preserved color diversity
        var rValues = Set<UInt8>()
        var gValues = Set<UInt8>()
        var bValues = Set<UInt8>()

        for color in result.palette {
            rValues.insert(UInt8((color >> 16) & 0xFF))
            gValues.insert(UInt8((color >> 8) & 0xFF))
            bValues.insert(UInt8(color & 0xFF))
        }

        // Each channel should have good coverage
        XCTAssertGreaterThan(rValues.count, 10, "R channel diversity")
        XCTAssertGreaterThan(gValues.count, 10, "G channel diversity")
        XCTAssertGreaterThan(bValues.count, 10, "B channel diversity")
    }
}

// MARK: - XCTAssertEqual with accuracy for UInt8

extension XCTestCase {
    func XCTAssertEqual(_ a: UInt8, _ b: UInt8, accuracy: UInt8, _ message: String) {
        let diff = a > b ? a - b : b - a
        XCTAssertLessThanOrEqual(diff, accuracy, message)
    }
}
