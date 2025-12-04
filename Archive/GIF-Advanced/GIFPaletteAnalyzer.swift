//
//  GIFPaletteAnalyzer.swift
//  RGB2GIF
//
//  Analyzes GIF palettes for visualization and optimization
//

import Foundation
import SwiftUI
import ImageIO
import CoreGraphics
import Accelerate
import os.log

private let paletteLogger = Logger(subsystem: "com.rgb2gif", category: "PaletteAnalyzer")

// MARK: - Palette Analyzer

@available(iOS 26.0, *)
public class GIFPaletteAnalyzer {
    private let url: URL
    private var source: CGImageSource?
    private var frameCount: Int = 0

    public init?(url: URL) {
        self.url = url
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        self.source = source
        self.frameCount = CGImageSourceGetCount(source)
    }

    // MARK: - Extract Palettes

    public func extractPalettes() async -> [[Color]] {
        guard let source = source else { return [] }

        return await withTaskGroup(of: (Int, [Color]).self) { group in
            for index in 0..<frameCount {
                group.addTask { @MainActor in
                    let palette = self.extractPalette(at: index, from: source)
                    return (index, palette)
                }
            }

            var palettes = [(Int, [Color])]()
            for await result in group {
                palettes.append(result)
            }

            // Sort by frame index and extract palettes
            return palettes
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
        }
    }

    private func extractPalette(at index: Int, from source: CGImageSource) -> [Color] {
        // Check for GIF-specific color table
        if let palette = extractGIFPalette(at: index, from: source) {
            return palette
        }

        // Fallback: extract palette from image pixels
        if let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) {
            return extractPaletteFromImage(cgImage)
        }

        return []
    }

    private func extractGIFPalette(at index: Int, from source: CGImageSource) -> [Color]? {
        // Get frame properties
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let _ = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return nil
        }

        // Check for local color table
        // Note: kCGImagePropertyGIFHasLocalColorMap is not available in iOS
        // We'll check if we can extract a palette from the image instead
        if true {
            // Note: iOS doesn't directly expose the raw color table
            // We need to extract it from the image data
            if let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) {
                return extractIndexedPalette(from: cgImage)
            }
        }

        // Check global color table
        if let globalProperties = CGImageSourceCopyProperties(source, nil) as? [String: Any],
           let _ = globalProperties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            // Extract from first frame if using global table
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return extractIndexedPalette(from: cgImage)
            }
        }

        return nil
    }

    private func extractIndexedPalette(from image: CGImage) -> [Color] {
        // For indexed color GIFs, we need to quantize to find the palette
        let quantizer = GIFColorQuantizer(maxColors: 256)
        return quantizer.extractPalette(from: image)
    }

    private func extractPaletteFromImage(_ image: CGImage) -> [Color] {
        // Use color quantization to extract dominant colors
        let quantizer = GIFColorQuantizer(maxColors: 256)
        return quantizer.extractPalette(from: image)
    }

    // MARK: - Analyze Temporal Changes

    public func analyzeTemporalChanges() async -> TemporalAnalysis {
        let palettes = await extractPalettes()
        guard !palettes.isEmpty else {
            return TemporalAnalysis(
                totalUniqueColors: 0,
                colorStability: 0,
                paletteChanges: [],
                dominantColors: []
            )
        }

        // Count unique colors across all frames
        var allColors = Set<String>()
        for palette in palettes {
            for color in palette {
                allColors.insert(colorToHex(color))
            }
        }

        // Calculate palette changes
        var changes: [Int] = []
        for i in 1..<palettes.count {
            let change = calculatePaletteDistance(palettes[i-1], palettes[i])
            changes.append(change)
        }

        // Find dominant colors
        var colorFrequency: [String: Int] = [:]
        for palette in palettes {
            for color in palette {
                let hex = colorToHex(color)
                colorFrequency[hex, default: 0] += 1
            }
        }

        let dominantColors = colorFrequency
            .sorted { $0.value > $1.value }
            .prefix(10)
            .compactMap { hexToColor($0.key) }

        // Calculate stability (lower is more stable)
        let avgChange = changes.isEmpty ? 0 : changes.reduce(0, +) / changes.count
        let stability = 1.0 - Double(avgChange) / 256.0

        return TemporalAnalysis(
            totalUniqueColors: allColors.count,
            colorStability: stability,
            paletteChanges: changes,
            dominantColors: dominantColors
        )
    }

    private func calculatePaletteDistance(_ palette1: [Color], _ palette2: [Color]) -> Int {
        // Count how many colors changed
        let set1 = Set(palette1.map { colorToHex($0) })
        let set2 = Set(palette2.map { colorToHex($0) })
        return set1.symmetricDifference(set2).count
    }

    private func colorToHex(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "#%02X%02X%02X",
                     Int(r * 255),
                     Int(g * 255),
                     Int(b * 255))
    }

    private func hexToColor(_ hex: String) -> Color? {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let int = Int(hex, radix: 16) else { return nil }

        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0

        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Color Quantizer

@available(iOS 26.0, *)
class GIFColorQuantizer {
    let maxColors: Int

    init(maxColors: Int) {
        self.maxColors = min(256, max(2, maxColors))
    }

    func extractPalette(from image: CGImage) -> [Color] {
        // Get pixel data
        guard let pixelData = image.dataProvider?.data as Data? else {
            return []
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = 4 // Assuming RGBA

        // Sample pixels (subsample for performance)
        let sampleRate = max(1, (width * height) / 10000) // Sample ~10k pixels max
        var pixels: [(r: UInt8, g: UInt8, b: UInt8)] = []

        for y in stride(from: 0, to: height, by: sampleRate) {
            for x in stride(from: 0, to: width, by: sampleRate) {
                let offset = (y * width + x) * bytesPerPixel
                if offset + 2 < pixelData.count {
                    pixels.append((
                        r: pixelData[offset],
                        g: pixelData[offset + 1],
                        b: pixelData[offset + 2]
                    ))
                }
            }
        }

        // Use median cut algorithm
        return medianCutQuantize(pixels: pixels, colorCount: maxColors)
    }

    private func medianCutQuantize(pixels: [(r: UInt8, g: UInt8, b: UInt8)], colorCount: Int) -> [Color] {
        guard !pixels.isEmpty else { return [] }

        // Create initial box containing all pixels
        var boxes = [PaletteColorBox(pixels: pixels)]

        // Split boxes until we have enough colors
        while boxes.count < colorCount && boxes.count < pixels.count {
            // Find box with largest volume to split
            guard let largestBox = boxes.max(by: { $0.volume < $1.volume }),
                  largestBox.canSplit else {
                break
            }

            // Remove and split the largest box
            if let index = boxes.firstIndex(where: { $0 === largestBox }) {
                boxes.remove(at: index)
                let (box1, box2) = largestBox.split()
                boxes.append(box1)
                boxes.append(box2)
            }
        }

        // Extract average color from each box
        return boxes.map { box in
            let avgR = box.pixels.reduce(0) { $0 + Int($1.r) } / box.pixels.count
            let avgG = box.pixels.reduce(0) { $0 + Int($1.g) } / box.pixels.count
            let avgB = box.pixels.reduce(0) { $0 + Int($1.b) } / box.pixels.count

            return Color(
                red: Double(avgR) / 255.0,
                green: Double(avgG) / 255.0,
                blue: Double(avgB) / 255.0
            )
        }
    }
}

// MARK: - Color Box for Median Cut

class PaletteColorBox {
    var pixels: [(r: UInt8, g: UInt8, b: UInt8)]
    var minR: UInt8 = 255, maxR: UInt8 = 0
    var minG: UInt8 = 255, maxG: UInt8 = 0
    var minB: UInt8 = 255, maxB: UInt8 = 0

    init(pixels: [(r: UInt8, g: UInt8, b: UInt8)]) {
        self.pixels = pixels
        updateBounds()
    }

    var volume: Int {
        Int(maxR - minR) * Int(maxG - minG) * Int(maxB - minB)
    }

    var canSplit: Bool {
        pixels.count > 1
    }

    private func updateBounds() {
        for pixel in pixels {
            minR = min(minR, pixel.r)
            maxR = max(maxR, pixel.r)
            minG = min(minG, pixel.g)
            maxG = max(maxG, pixel.g)
            minB = min(minB, pixel.b)
            maxB = max(maxB, pixel.b)
        }
    }

    func split() -> (PaletteColorBox, PaletteColorBox) {
        // Find longest dimension
        let rangeR = Int(maxR - minR)
        let rangeG = Int(maxG - minG)
        let rangeB = Int(maxB - minB)

        // Sort along longest dimension
        if rangeR >= rangeG && rangeR >= rangeB {
            pixels.sort { $0.r < $1.r }
        } else if rangeG >= rangeB {
            pixels.sort { $0.g < $1.g }
        } else {
            pixels.sort { $0.b < $1.b }
        }

        // Split at median
        let mid = pixels.count / 2
        let box1 = PaletteColorBox(pixels: Array(pixels[0..<mid]))
        let box2 = PaletteColorBox(pixels: Array(pixels[mid..<pixels.count]))

        return (box1, box2)
    }
}

// MARK: - Analysis Results

@available(iOS 26.0, *)
public struct TemporalAnalysis {
    public let totalUniqueColors: Int
    public let colorStability: Double // 0-1, higher is more stable
    public let paletteChanges: [Int] // Number of color changes per frame transition
    public let dominantColors: [Color] // Most frequently occurring colors
}