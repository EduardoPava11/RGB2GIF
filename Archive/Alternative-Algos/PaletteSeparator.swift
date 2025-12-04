//
//  PaletteSeparator.swift
//  RGB2GIF
//
//  Separates GIF89a files into grayscale index arrays and color palettes
//  Enables hot-swappable palette system for marketplace
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@available(iOS 26.0, *)
public class PaletteSeparator {

    // MARK: - Separated GIF Structure

    public struct SeparatedGIF {
        public let width: Int
        public let height: Int
        public let frameCount: Int

        /// Grayscale index arrays - one per frame
        /// Each frame is width×height bytes (8-bit indices into palette)
        public let indexMaps: [Data]

        /// Color palettes - one per frame
        /// Each palette is 256 RGBA colors
        public let palettes: [ColorPalette]

        /// Metadata about the GIF
        public let metadata: GIFSeparationMetadata

        /// Calculate total size savings vs RGBA
        public var compressionRatio: Double {
            let rgbaSize = width * height * frameCount * 4
            let indexedSize = width * height * frameCount + (palettes.count * 256 * 4)
            return Double(rgbaSize) / Double(indexedSize)
        }
    }

    public struct ColorPalette: Codable {
        public let colors: [[UInt8]]  // 256 × [R,G,B,A]
        public let fingerprint: Data  // SHA-256 hash
        public let statistics: PaletteStatistics

        public init(colors: [[UInt8]]) {
            self.colors = colors
            self.fingerprint = Self.computeFingerprint(colors)
            self.statistics = Self.computeStatistics(colors)
        }

        private static func computeFingerprint(_ colors: [[UInt8]]) -> Data {
            var data = Data()
            for color in colors {
                data.append(contentsOf: color)
            }
            return SHA256.hash(data: data)
        }

        private static func computeStatistics(_ colors: [[UInt8]]) -> PaletteStatistics {
            var totalR = 0, totalG = 0, totalB = 0
            for color in colors {
                totalR += Int(color[0])
                totalG += Int(color[1])
                totalB += Int(color[2])
            }

            let count = colors.count
            return PaletteStatistics(
                avgR: Double(totalR) / Double(count),
                avgG: Double(totalG) / Double(count),
                avgB: Double(totalB) / Double(count),
                uniqueColors: Set(colors.map { "\($0[0])-\($0[1])-\($0[2])" }).count
            )
        }
    }

    public struct PaletteStatistics: Codable {
        public let avgR: Double
        public let avgG: Double
        public let avgB: Double
        public let uniqueColors: Int

        public var warmth: Double {
            // Warmer = more red/yellow
            return (avgR - avgB) / 255.0
        }

        public var saturation: Double {
            let max = Swift.max(avgR, avgG, avgB)
            let min = Swift.min(avgR, avgG, avgB)
            return max > 0 ? (max - min) / max : 0
        }
    }

    public struct GIFSeparationMetadata: Codable {
        public let originalSize: Int
        public let separatedSize: Int
        public let compressionRatio: Double
        public let frameCount: Int
        public let dimension: Int
        public let paletteFingerprints: [String]
        public let separatedAt: Date

        public init(originalSize: Int, separatedSize: Int, compressionRatio: Double,
                   frameCount: Int, dimension: Int, paletteFingerprints: [String]) {
            self.originalSize = originalSize
            self.separatedSize = separatedSize
            self.compressionRatio = compressionRatio
            self.frameCount = frameCount
            self.dimension = dimension
            self.paletteFingerprints = paletteFingerprints
            self.separatedAt = Date()
        }
    }

    // MARK: - Separation

    public func separate(gifData: Data) throws -> SeparatedGIF {
        guard let source = CGImageSourceCreateWithData(gifData as CFData, nil) else {
            throw SeparationError.invalidGIFData
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw SeparationError.noFrames
        }

        // Get first frame to determine dimensions
        guard let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SeparationError.invalidFrame(0)
        }

        let width = firstImage.width
        let height = firstImage.height

        var indexMaps: [Data] = []
        var palettes: [ColorPalette] = []

        // Process each frame
        for frameIndex in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, frameIndex, nil) else {
                throw SeparationError.invalidFrame(frameIndex)
            }

            let (indexMap, palette) = try extractIndexAndPalette(from: cgImage)
            indexMaps.append(indexMap)
            palettes.append(palette)
        }

        // Compute metadata
        let originalSize = gifData.count
        let separatedSize = indexMaps.reduce(0) { $0 + $1.count } + (palettes.count * 256 * 4)
        let compressionRatio = Double(originalSize) / Double(separatedSize)
        let fingerprints = palettes.map { $0.fingerprint.hexString }

        let metadata = GIFSeparationMetadata(
            originalSize: originalSize,
            separatedSize: separatedSize,
            compressionRatio: compressionRatio,
            frameCount: frameCount,
            dimension: width,
            paletteFingerprints: fingerprints
        )

        return SeparatedGIF(
            width: width,
            height: height,
            frameCount: frameCount,
            indexMaps: indexMaps,
            palettes: palettes,
            metadata: metadata
        )
    }

    private func extractIndexAndPalette(from cgImage: CGImage) throws -> (Data, ColorPalette) {
        let width = cgImage.width
        let height = cgImage.height

        // Create RGBA bitmap context
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SeparationError.contextCreationFailed
        }

        // Draw image into context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else {
            throw SeparationError.noPixelData
        }

        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Build color histogram
        var colorMap: [String: UInt8] = [:]
        var paletteColors: [[UInt8]] = []

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = pixels[offset]
                let g = pixels[offset + 1]
                let b = pixels[offset + 2]
                let a = pixels[offset + 3]

                let key = "\(r)-\(g)-\(b)-\(a)"

                if colorMap[key] == nil {
                    if paletteColors.count < 256 {
                        colorMap[key] = UInt8(paletteColors.count)
                        paletteColors.append([r, g, b, a])
                    } else {
                        // Find nearest color in palette (if more than 256 colors)
                        let nearestIndex = findNearestColor([r, g, b, a], in: paletteColors)
                        colorMap[key] = UInt8(nearestIndex)
                    }
                }
            }
        }

        // Pad palette to 256 colors if needed
        while paletteColors.count < 256 {
            paletteColors.append([0, 0, 0, 0])
        }

        // Create index map
        var indexMap = Data(count: width * height)
        indexMap.withUnsafeMutableBytes { indexPtr in
            let indices = indexPtr.bindMemory(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let r = pixels[offset]
                    let g = pixels[offset + 1]
                    let b = pixels[offset + 2]
                    let a = pixels[offset + 3]

                    let key = "\(r)-\(g)-\(b)-\(a)"
                    indices[y * width + x] = colorMap[key] ?? 0
                }
            }
        }

        let palette = ColorPalette(colors: paletteColors)

        return (indexMap, palette)
    }

    private func findNearestColor(_ color: [UInt8], in palette: [[UInt8]]) -> Int {
        var minDistance = Int.max
        var nearestIndex = 0

        for (index, paletteColor) in palette.enumerated() {
            let dr = Int(color[0]) - Int(paletteColor[0])
            let dg = Int(color[1]) - Int(paletteColor[1])
            let db = Int(color[2]) - Int(paletteColor[2])
            let distance = dr*dr + dg*dg + db*db

            if distance < minDistance {
                minDistance = distance
                nearestIndex = index
            }
        }

        return nearestIndex
    }

    // MARK: - Recombination

    public func recombine(separated: SeparatedGIF, newPalettes: [ColorPalette]? = nil) throws -> Data {
        let palettesToUse = newPalettes ?? separated.palettes

        guard palettesToUse.count == separated.frameCount else {
            throw SeparationError.paletteMismatch
        }

        // Create GIF destination
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.gif.identifier as CFString,
            separated.frameCount,
            nil
        ) else {
            throw SeparationError.destinationCreationFailed
        }

        // Set GIF properties
        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Add frames
        for frameIndex in 0..<separated.frameCount {
            let indexMap = separated.indexMaps[frameIndex]
            let palette = palettesToUse[frameIndex]

            let cgImage = try createCGImage(
                indexMap: indexMap,
                palette: palette,
                width: separated.width,
                height: separated.height
            )

            CGImageDestinationAddImage(destination, cgImage, nil)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw SeparationError.finalizationFailed
        }

        return mutableData as Data
    }

    private func createCGImage(indexMap: Data, palette: ColorPalette, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SeparationError.contextCreationFailed
        }

        guard let pixelData = context.data else {
            throw SeparationError.noPixelData
        }

        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Apply palette to indices
        indexMap.withUnsafeBytes { indexPtr in
            let indices = indexPtr.bindMemory(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let index = Int(indices[y * width + x])
                    let color = palette.colors[min(index, 255)]

                    let offset = (y * width + x) * 4
                    pixels[offset] = color[0]
                    pixels[offset + 1] = color[1]
                    pixels[offset + 2] = color[2]
                    pixels[offset + 3] = color[3]
                }
            }
        }

        guard let cgImage = context.makeImage() else {
            throw SeparationError.imageCreationFailed
        }

        return cgImage
    }

    // MARK: - Storage

    public func save(separated: SeparatedGIF, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Save index maps
        let indexDirectory = directory.appendingPathComponent("indices")
        try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)

        for (index, indexMap) in separated.indexMaps.enumerated() {
            let filename = String(format: "frame_%03d.idx", index)
            try indexMap.write(to: indexDirectory.appendingPathComponent(filename))
        }

        // Save palettes
        let paletteDirectory = directory.appendingPathComponent("palettes")
        try fileManager.createDirectory(at: paletteDirectory, withIntermediateDirectories: true)

        for (index, palette) in separated.palettes.enumerated() {
            let filename = String(format: "palette_%03d.json", index)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(palette)
            try data.write(to: paletteDirectory.appendingPathComponent(filename))
        }

        // Save metadata
        let metadataURL = directory.appendingPathComponent("separation_metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(separated.metadata)
        try data.write(to: metadataURL)
    }

    // MARK: - Errors

    public enum SeparationError: LocalizedError {
        case invalidGIFData
        case noFrames
        case invalidFrame(Int)
        case contextCreationFailed
        case noPixelData
        case paletteMismatch
        case destinationCreationFailed
        case finalizationFailed
        case imageCreationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidGIFData: return "Invalid GIF data"
            case .noFrames: return "No frames in GIF"
            case .invalidFrame(let index): return "Invalid frame at index \(index)"
            case .contextCreationFailed: return "Failed to create CGContext"
            case .noPixelData: return "No pixel data available"
            case .paletteMismatch: return "Palette count doesn't match frame count"
            case .destinationCreationFailed: return "Failed to create CGImageDestination"
            case .finalizationFailed: return "Failed to finalize GIF"
            case .imageCreationFailed: return "Failed to create CGImage"
            }
        }
    }
}

// MARK: - SHA256 Helper

import CryptoKit

struct SHA256 {
    static func hash(data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }
}

// Note: hexString extension now defined in DataExtensions.swift