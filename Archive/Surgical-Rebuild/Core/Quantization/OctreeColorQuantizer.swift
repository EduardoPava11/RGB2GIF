//
//  OctreeColorQuantizer.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  OCTREE COLOR QUANTIZER - iOS 26 / Swift 6.2 Actor-Based                  ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  SWIFT 6.2 COMPLIANCE:                                                    ║
//  ║  • Uses Actor for thread-safe state isolation (no NSLock!)                ║
//  ║  • Proper async/await patterns without locks across awaits                ║
//  ║  • Sendable conformance via actor isolation                               ║
//  ║                                                                           ║
//  ║  ALGORITHM: Octree-based median-cut color quantization                    ║
//  ║  • Build octree from all input pixels                                     ║
//  ║  • Reduce tree until ≤256 leaf nodes remain                               ║
//  ║  • Each leaf becomes a palette color                                      ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import UIKit
import os.log

private let quantizerLogger = Logger(subsystem: "com.rgb2gif", category: "ColorQuantizer")

// MARK: - Octree Node (Value Type for Actor Safety)

/// Internal octree node - used only within the actor
private final class OctreeNode {
    var red: Int = 0
    var green: Int = 0
    var blue: Int = 0
    var pixelCount: Int = 0
    var paletteIndex: Int = -1
    var children: [OctreeNode?] = Array(repeating: nil, count: 8)
    var isInLeafList: Bool = false

    var isLeaf: Bool {
        children.allSatisfy { $0 == nil }
    }

    func getColor() -> UInt32 {
        guard pixelCount > 0 else { return 0 }
        let r = UInt32(red / pixelCount) & 0xFF
        let g = UInt32(green / pixelCount) & 0xFF
        let b = UInt32(blue / pixelCount) & 0xFF
        return (0xFF << 24) | (r << 16) | (g << 8) | b
    }
}

// MARK: - Quantization Result

@available(iOS 26.0, *)
public struct QuantizationResult: Sendable {
    public let palette: [UInt32]
    public let indexedPixels: [UInt8]
    public let originalImage: CGImage
    public let quantizedImage: CGImage
    public let processingTime: TimeInterval

    public var stats: QuantizationStats {
        QuantizationStats(
            paletteSize: palette.count,
            pixelCount: indexedPixels.count,
            processingTimeMs: processingTime * 1000,
            memoryUsedBytes: palette.count * 4 + indexedPixels.count
        )
    }
}

@available(iOS 26.0, *)
public struct QuantizationStats: Sendable {
    public let paletteSize: Int
    public let pixelCount: Int
    public let processingTimeMs: Double
    public let memoryUsedBytes: Int
}

@available(iOS 26.0, *)
public struct QuantizationOptions: Sendable {
    public let maxColors: Int
    public let dithering: Bool
    public let enhanceContrast: Bool

    public init(maxColors: Int = 256, dithering: Bool = false, enhanceContrast: Bool = false) {
        self.maxColors = min(256, max(2, maxColors))
        self.dithering = dithering
        self.enhanceContrast = enhanceContrast
    }

    public static var balanced: QuantizationOptions {
        QuantizationOptions(maxColors: 256, dithering: false, enhanceContrast: false)
    }

    public static var quality: QuantizationOptions {
        QuantizationOptions(maxColors: 256, dithering: true, enhanceContrast: true)
    }

    public static var fast: QuantizationOptions {
        QuantizationOptions(maxColors: 128, dithering: false, enhanceContrast: false)
    }
}

// MARK: - Quantization Errors

public enum QuantizationError: LocalizedError, Sendable {
    case invalidImageData
    case imageCreationFailed
    case paletteGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImageData: return "Invalid image data for quantization"
        case .imageCreationFailed: return "Failed to create quantized image"
        case .paletteGenerationFailed: return "Failed to generate color palette"
        }
    }
}

// MARK: - OctreeColorQuantizer Actor (Swift 6.2 Compliant)

/// Actor-based color quantizer - thread-safe without locks
/// iOS 26 / Swift 6.2: Uses actor isolation instead of NSLock
@available(iOS 26.0, *)
public actor OctreeColorQuantizer {

    // MARK: - Private State (Actor-Isolated)
    // Swift 6.2: Initialize directly to avoid actor-isolation issues in init

    private let maxDepth = 8
    private var root: OctreeNode? = OctreeNode()
    private var leafNodes: [OctreeNode] = []
    private var levelNodes: [[OctreeNode]] = Array(repeating: [], count: 9)

    // MARK: - Initialization
    // Swift 6.2: Default init - properties are initialized inline above

    public init() {
        // No reset() call needed - properties initialized at declaration
        // This avoids "actor-isolated method from nonisolated context" warning
    }

    // MARK: - Public API

    /// Quantize image to specified number of colors
    /// Swift 6.2: No locks needed - actor isolation handles thread safety
    public func quantize(
        _ image: CGImage,
        options: QuantizationOptions = QuantizationOptions()
    ) async throws -> QuantizationResult {
        let startTime = CACurrentMediaTime()

        quantizerLogger.info("Starting quantization for \(image.width)×\(image.height) image")

        // Reset octree
        reset()

        // Build octree from image pixels
        try buildOctree(from: image)
        quantizerLogger.info("Octree built: \(self.leafNodes.count) leaf nodes")

        // Reduce colors to target count
        reducePalette(to: options.maxColors)
        quantizerLogger.info("Palette reduced to \(self.leafNodes.count) colors")

        // Generate palette
        let palette = generatePalette(maxColors: options.maxColors)

        // Map pixels to palette indices
        let indexedPixels = try mapPixelsToPalette(image, palette: palette)

        // Apply dithering if requested
        let finalIndexedPixels: [UInt8]
        if options.dithering {
            finalIndexedPixels = applyDithering(
                indexedPixels,
                width: image.width,
                height: image.height,
                palette: palette
            )
        } else {
            finalIndexedPixels = indexedPixels
        }

        // Create quantized image
        let quantizedImage = try createQuantizedImage(
            indexedPixels: finalIndexedPixels,
            palette: palette,
            width: image.width,
            height: image.height
        )

        let processingTime = CACurrentMediaTime() - startTime
        quantizerLogger.info("Quantized to \(palette.count) colors in \(String(format: "%.2f", processingTime * 1000))ms")

        return QuantizationResult(
            palette: palette,
            indexedPixels: finalIndexedPixels,
            originalImage: image,
            quantizedImage: quantizedImage,
            processingTime: processingTime
        )
    }

    /// Quantize directly from RGB pixel array (for GIF81Pipeline)
    /// Processes all pixels from all frames into a single global palette
    public func quantizeFromPixels(
        _ pixels: [(r: UInt8, g: UInt8, b: UInt8)],
        maxColors: Int = 256
    ) async -> [UInt32] {
        quantizerLogger.info("Quantizing \(pixels.count) pixels to \(maxColors) colors...")

        reset()

        // Build octree from all pixels
        for pixel in pixels {
            addColor(red: pixel.r, green: pixel.g, blue: pixel.b)
        }

        quantizerLogger.info("Built octree with \(self.leafNodes.count) unique colors")

        // Reduce to max colors
        reducePalette(to: maxColors)

        quantizerLogger.info("Reduced to \(self.leafNodes.count) colors")

        return generatePalette(maxColors: maxColors)
    }

    /// Fast quantization for real-time preview (samples every 4th pixel)
    public func quantizeFast(
        _ pixelData: Data,
        width: Int,
        height: Int,
        maxColors: Int = 256
    ) -> [UInt32] {
        reset()

        let bytesPerPixel = 4
        let stride = 4

        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let offset = (y * width + x) * bytesPerPixel
                guard offset + 3 < pixelData.count else { continue }

                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]

                addColor(red: r, green: g, blue: b)
            }
        }

        reducePalette(to: maxColors)
        return generatePalette(maxColors: maxColors)
    }

    // MARK: - Private Methods (Actor-Isolated)

    private func reset() {
        root = OctreeNode()
        leafNodes.removeAll()
        for i in 0..<levelNodes.count {
            levelNodes[i].removeAll()
        }
    }

    private func buildOctree(from image: CGImage) throws {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw QuantizationError.invalidImageData
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                addColor(red: data[offset], green: data[offset + 1], blue: data[offset + 2])
            }
        }
    }

    private func addColor(red: UInt8, green: UInt8, blue: UInt8) {
        guard let root = root else { return }

        var node = root
        var currentDepth = 0

        for level in (0..<maxDepth).reversed() {
            let index = getOctreeIndex(red: red, green: green, blue: blue, level: level)

            if node.children[index] == nil {
                node.children[index] = OctreeNode()
                if level < maxDepth - 1 && level > 0 {
                    levelNodes[level + 1].append(node.children[index]!)
                }
            }

            node = node.children[index]!
            currentDepth += 1

            if currentDepth >= maxDepth { break }
        }

        node.red += Int(red)
        node.green += Int(green)
        node.blue += Int(blue)
        node.pixelCount += 1

        if node.isLeaf && !node.isInLeafList {
            node.isInLeafList = true
            leafNodes.append(node)
        }
    }

    private func getOctreeIndex(red: UInt8, green: UInt8, blue: UInt8, level: Int) -> Int {
        var index = 0
        let mask: UInt8 = 0x80 >> level

        if (red & mask) != 0 { index |= 4 }
        if (green & mask) != 0 { index |= 2 }
        if (blue & mask) != 0 { index |= 1 }

        return index
    }

    private func reducePalette(to maxColors: Int) {
        guard leafNodes.count > maxColors else { return }

        let maxIterations = leafNodes.count * 2
        var iterations = 0

        while leafNodes.count > maxColors && iterations < maxIterations {
            iterations += 1

            var reduced = false

            for level in (1..<maxDepth).reversed() {
                if !levelNodes[level].isEmpty {
                    if let nodeToReduce = findBestNodeToReduce(at: level) {
                        reduceNode(nodeToReduce, atLevel: level)
                        reduced = true
                        break
                    }
                }
            }

            if !reduced {
                removeLeastImportantLeaf()
            }
        }

        compactLeafNodes()
    }

    private func perceptualImportance(_ node: OctreeNode) -> Double {
        guard node.pixelCount > 0 else { return 0 }

        let avgR = Double(node.red) / Double(node.pixelCount)
        let avgG = Double(node.green) / Double(node.pixelCount)
        let avgB = Double(node.blue) / Double(node.pixelCount)

        let luminance = 0.299 * avgR + 0.587 * avgG + 0.114 * avgB
        return luminance * Double(node.pixelCount)
    }

    private func findBestNodeToReduce(at level: Int) -> OctreeNode? {
        let reducibleNodes = levelNodes[level].filter { node in
            node.children.contains { $0?.isInLeafList == true }
        }

        guard !reducibleNodes.isEmpty else { return nil }
        return reducibleNodes.min { perceptualImportance($0) < perceptualImportance($1) }
    }

    private func removeLeastImportantLeaf() {
        guard let minNode = leafNodes.min(by: { perceptualImportance($0) < perceptualImportance($1) }) else { return }
        minNode.isInLeafList = false
    }

    private func compactLeafNodes() {
        leafNodes.removeAll { !$0.isInLeafList }
    }

    private func reduceNode(_ node: OctreeNode, atLevel level: Int) {
        if level > 0 && level < levelNodes.count {
            levelNodes[level].removeAll { $0 === node }
        }

        var red = 0, green = 0, blue = 0, pixelCount = 0
        var actualLeafChildren = 0

        for child in node.children where child != nil {
            if child!.isInLeafList {
                red += child!.red
                green += child!.green
                blue += child!.blue
                pixelCount += child!.pixelCount
                actualLeafChildren += 1
                child!.isInLeafList = false
            }
        }

        guard actualLeafChildren > 0 else { return }

        leafNodes.removeAll { !$0.isInLeafList }

        node.red = red
        node.green = green
        node.blue = blue
        node.pixelCount = pixelCount
        node.children = Array(repeating: nil, count: 8)

        if !node.isInLeafList {
            node.isInLeafList = true
            leafNodes.append(node)
        }
    }

    private func generatePalette(maxColors: Int) -> [UInt32] {
        var palette: [UInt32] = []

        let sortedLeaves = leafNodes.sorted { $0.pixelCount > $1.pixelCount }

        for (index, node) in sortedLeaves.prefix(maxColors).enumerated() {
            node.paletteIndex = index
            palette.append(node.getColor())
        }

        while palette.count < maxColors && palette.count < 256 {
            palette.append(0xFF000000)
        }

        return palette
    }

    private func mapPixelsToPalette(_ image: CGImage, palette: [UInt32]) throws -> [UInt8] {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw QuantizationError.invalidImageData
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        let totalPixels = width * height

        var indexedPixels = [UInt8](repeating: 0, count: totalPixels)
        var colorCache: [UInt32: UInt8] = [:]
        colorCache.reserveCapacity(min(totalPixels, 65536))

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]

                let colorKey = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)

                let paletteIndex: UInt8
                if let cachedIndex = colorCache[colorKey] {
                    paletteIndex = cachedIndex
                } else {
                    let index = findClosestPaletteIndex(red: r, green: g, blue: b, palette: palette)
                    paletteIndex = UInt8(index)
                    colorCache[colorKey] = paletteIndex
                }

                indexedPixels[y * width + x] = paletteIndex
            }
        }

        return indexedPixels
    }

    private func findClosestPaletteIndex(red: UInt8, green: UInt8, blue: UInt8, palette: [UInt32]) -> Int {
        var minDistance = Int.max
        var closestIndex = 0

        for (index, color) in palette.enumerated() {
            let pr = Int((color >> 16) & 0xFF)
            let pg = Int((color >> 8) & 0xFF)
            let pb = Int(color & 0xFF)

            let dr = Int(red) - pr
            let dg = Int(green) - pg
            let db = Int(blue) - pb
            let distance = dr * dr + dg * dg + db * db

            if distance < minDistance {
                minDistance = distance
                closestIndex = index
            }
        }

        return closestIndex
    }

    private func applyDithering(
        _ indexedPixels: [UInt8],
        width: Int,
        height: Int,
        palette: [UInt32]
    ) -> [UInt8] {
        var ditheredPixels = indexedPixels

        var errorR = Array(repeating: Array(repeating: 0, count: width + 2), count: height)
        var errorG = Array(repeating: Array(repeating: 0, count: width + 2), count: height)
        var errorB = Array(repeating: Array(repeating: 0, count: width + 2), count: height)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let paletteIndex = Int(indexedPixels[index])
                let paletteColor = palette[paletteIndex]

                let r = Int((paletteColor >> 16) & 0xFF) + errorR[y][x + 1]
                let g = Int((paletteColor >> 8) & 0xFF) + errorG[y][x + 1]
                let b = Int(paletteColor & 0xFF) + errorB[y][x + 1]

                let newIndex = findClosestPaletteIndex(
                    red: UInt8(max(0, min(255, r))),
                    green: UInt8(max(0, min(255, g))),
                    blue: UInt8(max(0, min(255, b))),
                    palette: palette
                )

                ditheredPixels[index] = UInt8(newIndex)

                let newColor = palette[newIndex]
                let errR = r - Int((newColor >> 16) & 0xFF)
                let errG = g - Int((newColor >> 8) & 0xFF)
                let errB = b - Int(newColor & 0xFF)

                if x < width - 1 {
                    errorR[y][x + 2] += errR * 7 / 16
                    errorG[y][x + 2] += errG * 7 / 16
                    errorB[y][x + 2] += errB * 7 / 16
                }
                if y < height - 1 {
                    if x > 0 {
                        errorR[y + 1][x] += errR * 3 / 16
                        errorG[y + 1][x] += errG * 3 / 16
                        errorB[y + 1][x] += errB * 3 / 16
                    }
                    errorR[y + 1][x + 1] += errR * 5 / 16
                    errorG[y + 1][x + 1] += errG * 5 / 16
                    errorB[y + 1][x + 1] += errB * 5 / 16
                    if x < width - 1 {
                        errorR[y + 1][x + 2] += errR / 16
                        errorG[y + 1][x + 2] += errG / 16
                        errorB[y + 1][x + 2] += errB / 16
                    }
                }
            }
        }

        return ditheredPixels
    }

    private func createQuantizedImage(
        indexedPixels: [UInt8],
        palette: [UInt32],
        width: Int,
        height: Int
    ) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * width + x
                let paletteIndex = Int(indexedPixels[pixelIndex])
                let color = palette[paletteIndex]

                let dataIndex = (y * width + x) * bytesPerPixel
                pixelData[dataIndex] = UInt8((color >> 16) & 0xFF)
                pixelData[dataIndex + 1] = UInt8((color >> 8) & 0xFF)
                pixelData[dataIndex + 2] = UInt8(color & 0xFF)
                pixelData[dataIndex + 3] = UInt8((color >> 24) & 0xFF)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
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
            throw QuantizationError.imageCreationFailed
        }

        return cgImage
    }
}
