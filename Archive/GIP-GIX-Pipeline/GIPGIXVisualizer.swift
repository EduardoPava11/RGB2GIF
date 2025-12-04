//
//  GIPGIXVisualizer.swift
//  RGB2GIF
//
//  Utilities to generate human-friendly visuals for GIP2 palettes and
//  GIX2 index frames. Visuals are written into the app's Documents
//  folder so they can be inspected via Files.app or the Finder when the
//  device is connected. All work is synchronous for now because the
//  pipeline already performs heavy work off the main thread.
//

import Foundation
import CoreGraphics
import UIKit

import os.log

private let visualizerLogger = Logger(subsystem: "com.rgb2gif", category: "Visualizer")

@available(iOS 26.0, *)
struct GIPGIXVisualizer {
    struct VisualArtifacts {
        let palettePreviewURL: URL
        let paletteWithLabelsURL: URL?
        let indexMapURLs: [URL]
        let framePreviewURLs: [URL]
        let csvURL: URL?
    }

    /// Quality metrics for debugging palette issues
    struct PaletteQualityMetrics {
        let uniqueColors: Int          // Distinct RGB values in palette
        let indicesUsed: Int           // How many of 256 indices are used
        let dominantColor: (r: UInt8, g: UInt8, b: UInt8)
        let colorSpaceCoverage: Double // 0-1, how much of RGB cube is covered
        let gradientDiversity: Double  // 0-1, for gradient images

        var passesThreshold: Bool {
            Double(uniqueColors) / 256.0 > 0.5 && Double(indicesUsed) / 256.0 > 0.3
        }
    }

    /// Generate PNG previews for the supplied GIP+GIX pair.
    /// - Parameter baseName: Folder name inside Documents/GIPVisuals.
    static func generateVisuals(gip: GIP, gix: GIX, baseName: String) throws -> VisualArtifacts {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("GIPVisuals", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let outputDir = root.appendingPathComponent(baseName, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Basic palette preview
        let paletteURL = outputDir.appendingPathComponent("\(baseName)_palette.png")
        try renderPalette(gip: gip, destination: paletteURL)

        // Palette with labels (16x16 grid with index numbers)
        let paletteWithLabelsURL = outputDir.appendingPathComponent("\(baseName)_palette_labeled.png")
        try? renderPaletteWithLabels(gip: gip, destination: paletteWithLabelsURL)

        // Index maps for each frame (grayscale visualization)
        var indexMapURLs: [URL] = []
        for (index, frame) in gix.frames.enumerated() {
            let indexMapURL = outputDir.appendingPathComponent(String(format: "indexmap_%03d.png", index))
            if let _ = try? renderIndexMap(frame: frame, gix: gix, destination: indexMapURL) {
                indexMapURLs.append(indexMapURL)
            }
        }

        // Colorized frames
        let frameURLs = try renderFrames(gip: gip, gix: gix, destinationDirectory: outputDir)

        // CSV export with frequency data
        let csvURL = outputDir.appendingPathComponent("\(baseName)_palette.csv")
        try? exportPaletteCSV(gip: gip, gix: gix, destination: csvURL)

        // Console output for debugging
        printPaletteSummary(gip: gip, gix: gix)

        return VisualArtifacts(
            palettePreviewURL: paletteURL,
            paletteWithLabelsURL: paletteWithLabelsURL,
            indexMapURLs: indexMapURLs,
            framePreviewURLs: frameURLs,
            csvURL: csvURL
        )
    }

    // MARK: - Console Output

    /// Print palette and index summary to console for debugging
    static func printPaletteSummary(gip: GIP, gix: GIX) {
        visualizerLogger.info("════════════════════════════════════════════════════════════")
        visualizerLogger.info("  PALETTE & INDEX SUMMARY")
        visualizerLogger.info("════════════════════════════════════════════════════════════")

        // Palette info
        let palette = gip.rgb
        let uniqueColors = Set(palette.map { "\($0[0]),\($0[1]),\($0[2])" }).count
        visualizerLogger.info("Palette size: \(palette.count) entries, \(uniqueColors) unique RGB values")

        // Color range analysis
        var minR: UInt8 = 255, maxR: UInt8 = 0
        var minG: UInt8 = 255, maxG: UInt8 = 0
        var minB: UInt8 = 255, maxB: UInt8 = 0

        for color in palette where color.count == 3 {
            minR = min(minR, color[0]); maxR = max(maxR, color[0])
            minG = min(minG, color[1]); maxG = max(maxG, color[1])
            minB = min(minB, color[2]); maxB = max(maxB, color[2])
        }

        visualizerLogger.info("Red range:   \(minR) - \(maxR)")
        visualizerLogger.info("Green range: \(minG) - \(maxG)")
        visualizerLogger.info("Blue range:  \(minB) - \(maxB)")

        // First 10 palette colors
        visualizerLogger.info("First 10 palette colors:")
        for (i, color) in palette.prefix(10).enumerated() where color.count == 3 {
            let hex = String(format: "#%02X%02X%02X", color[0], color[1], color[2])
            visualizerLogger.info("  [\(i)]: \(hex) (R=\(color[0]) G=\(color[1]) B=\(color[2]))")
        }

        // Index usage for first frame
        if let firstFrame = gix.frames.first {
            do {
                let indices = try decodeFrame(
                    firstFrame,
                    width: Int(gix.width),
                    height: Int(gix.height),
                    lzwMinCodeSize: gix.lzwMinCodeSize
                )

                var histogram = [Int](repeating: 0, count: 256)
                for idx in indices { histogram[Int(idx)] += 1 }

                let usedIndices = histogram.enumerated().filter { $0.element > 0 }.count
                visualizerLogger.info("Frame 0: \(usedIndices) unique indices used out of 256")

                // Top 5 most used indices
                let topIndices = histogram.enumerated()
                    .sorted { $0.element > $1.element }
                    .prefix(5)

                visualizerLogger.info("Top 5 most used indices:")
                for (idx, count) in topIndices {
                    let pct = Double(count) / Double(indices.count) * 100
                    if idx < palette.count, palette[idx].count == 3 {
                        let color = palette[idx]
                        let hex = String(format: "#%02X%02X%02X", color[0], color[1], color[2])
                        visualizerLogger.info("  [\(idx)]: \(count) pixels (\(String(format: "%.1f", pct))%) - \(hex)")
                    }
                }
            } catch {
                visualizerLogger.error("Failed to decode frame for analysis: \(error.localizedDescription)")
            }
        }

        visualizerLogger.info("════════════════════════════════════════════════════════════")
    }

    /// Compute quality metrics for the palette
    static func computeQualityMetrics(gip: GIP, gix: GIX) -> PaletteQualityMetrics {
        let palette = gip.rgb
        let uniqueColors = Set(palette.map { "\($0[0]),\($0[1]),\($0[2])" }).count

        // Analyze first frame for index usage
        var usedIndices = 0
        var dominantColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)

        if let firstFrame = gix.frames.first {
            if let indices = try? decodeFrame(
                firstFrame,
                width: Int(gix.width),
                height: Int(gix.height),
                lzwMinCodeSize: gix.lzwMinCodeSize
            ) {
                var histogram = [Int](repeating: 0, count: 256)
                for idx in indices { histogram[Int(idx)] += 1 }
                usedIndices = histogram.filter { $0 > 0 }.count

                if let maxIdx = histogram.enumerated().max(by: { $0.element < $1.element })?.offset,
                   maxIdx < palette.count, palette[maxIdx].count == 3 {
                    let c = palette[maxIdx]
                    dominantColor = (c[0], c[1], c[2])
                }
            }
        }

        // Color space coverage: check how many octants of RGB cube have colors
        var octants = Set<Int>()
        for color in palette where color.count == 3 {
            let octant = ((color[0] > 127 ? 4 : 0) + (color[1] > 127 ? 2 : 0) + (color[2] > 127 ? 1 : 0))
            octants.insert(Int(octant))
        }

        return PaletteQualityMetrics(
            uniqueColors: uniqueColors,
            indicesUsed: usedIndices,
            dominantColor: dominantColor,
            colorSpaceCoverage: Double(octants.count) / 8.0,
            gradientDiversity: Double(uniqueColors) / Double(palette.count)
        )
    }

    // MARK: - Palette Rendering

    /// Render 16x16 palette grid with index labels (0-255)
    private static func renderPaletteWithLabels(gip: GIP, destination: URL) throws {
        let swatchSize: CGFloat = 32  // Larger to fit labels
        let columns = 16
        let rows = 16
        let size = CGSize(width: CGFloat(columns) * swatchSize, height: CGFloat(rows) * swatchSize)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let palette = gip.rgb
            for index in 0..<256 {
                let row = index / columns
                let column = index % columns

                let rect = CGRect(
                    x: CGFloat(column) * swatchSize,
                    y: CGFloat(row) * swatchSize,
                    width: swatchSize,
                    height: swatchSize
                )

                // Draw color swatch
                if index < palette.count, palette[index].count == 3 {
                    let color = palette[index]
                    UIColor(
                        red: CGFloat(color[0]) / 255.0,
                        green: CGFloat(color[1]) / 255.0,
                        blue: CGFloat(color[2]) / 255.0,
                        alpha: 1.0
                    ).setFill()
                } else {
                    UIColor.darkGray.setFill()
                }
                context.fill(rect)

                // Draw index label with contrasting color
                let labelText = "\(index)"
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center

                // Calculate luminance to choose black or white text
                var luminance: CGFloat = 0.5
                if index < palette.count, palette[index].count == 3 {
                    let color = palette[index]
                    luminance = (0.299 * CGFloat(color[0]) + 0.587 * CGFloat(color[1]) + 0.114 * CGFloat(color[2])) / 255.0
                }
                let textColor: UIColor = luminance > 0.5 ? .black : .white

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ]

                let labelRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + (swatchSize - 10) / 2,
                    width: swatchSize,
                    height: 10
                )
                labelText.draw(in: labelRect, withAttributes: attributes)
            }
        }

        try image.pngData()?.write(to: destination, options: .atomic)
    }

    /// Render index map as grayscale image (index 0 = black, 255 = white)
    private static func renderIndexMap(frame: GIXFrame, gix: GIX, destination: URL) throws {
        let width = Int(gix.width)
        let height = Int(gix.height)

        let indices = try decodeFrame(
            frame,
            width: width,
            height: height,
            lzwMinCodeSize: gix.lzwMinCodeSize
        )

        // Create grayscale image from indices
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<indices.count {
            let gray = indices[i]  // Index value IS the grayscale value
            let offset = i * 4
            pixels[offset] = gray      // R
            pixels[offset + 1] = gray  // G
            pixels[offset + 2] = gray  // B
            pixels[offset + 3] = 255   // A
        }

        let image = makeImage(width: width, height: height, pixels: pixels)
        try image.pngData()?.write(to: destination, options: .atomic)
    }

    /// Export palette as CSV with frequency data
    private static func exportPaletteCSV(gip: GIP, gix: GIX, destination: URL) throws {
        var csv = "index,r,g,b,hex,frequency,percentage\n"

        // Build histogram from all frames
        var histogram = [Int](repeating: 0, count: 256)
        var totalPixels = 0

        for frame in gix.frames {
            if let indices = try? decodeFrame(
                frame,
                width: Int(gix.width),
                height: Int(gix.height),
                lzwMinCodeSize: gix.lzwMinCodeSize
            ) {
                for idx in indices {
                    histogram[Int(idx)] += 1
                    totalPixels += 1
                }
            }
        }

        let palette = gip.rgb
        for i in 0..<256 {
            let freq = histogram[i]
            let pct = totalPixels > 0 ? Double(freq) / Double(totalPixels) * 100 : 0

            if i < palette.count, palette[i].count == 3 {
                let color = palette[i]
                let hex = String(format: "#%02X%02X%02X", color[0], color[1], color[2])
                csv += "\(i),\(color[0]),\(color[1]),\(color[2]),\(hex),\(freq),\(String(format: "%.2f", pct))\n"
            } else {
                csv += "\(i),0,0,0,#000000,\(freq),\(String(format: "%.2f", pct))\n"
            }
        }

        try csv.write(to: destination, atomically: true, encoding: .utf8)
    }

    private static func renderPalette(gip: GIP, destination: URL) throws {
        let swatchSize: CGFloat = 24
        let columns = Int(sqrt(Double(gip.paletteSize)).rounded(.up))
        let rows = max(1, Int(ceil(Double(gip.paletteSize) / Double(columns))))
        let size = CGSize(width: CGFloat(columns) * swatchSize, height: CGFloat(rows) * swatchSize)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let palette = gip.rgb
            for (index, color) in palette.enumerated() {
                guard color.count == 3 else { continue }
                let row = index / columns
                let column = index % columns

                let rect = CGRect(x: CGFloat(column) * swatchSize,
                                  y: CGFloat(row) * swatchSize,
                                  width: swatchSize,
                                  height: swatchSize)

                UIColor(red: CGFloat(color[0]) / 255.0,
                        green: CGFloat(color[1]) / 255.0,
                        blue: CGFloat(color[2]) / 255.0,
                        alpha: 1.0).setFill()
                context.fill(rect)
            }
        }

        try image.pngData()?.write(to: destination, options: .atomic)
    }

    // MARK: - Frame Rendering

    private static func renderFrames(gip: GIP, gix: GIX, destinationDirectory: URL) throws -> [URL] {
        var urls: [URL] = []

        for (index, frame) in gix.frames.enumerated() {
            let indices = try decodeFrame(
                frame,
                width: Int(gix.width),
                height: Int(gix.height),
                lzwMinCodeSize: gix.lzwMinCodeSize
            )
            let pixels = try colorize(indices: indices, frame: frame, gip: gip)
            let image = makeImage(width: Int(gix.width), height: Int(gix.height), pixels: pixels)

            let url = destinationDirectory.appendingPathComponent(String(format: "frame_%03d.png", index))
            if let data = image.pngData() {
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
        }

        return urls
    }

    private static func decodeFrame(
        _ frame: GIXFrame,
        width: Int,
        height: Int,
        lzwMinCodeSize: UInt8
    ) throws -> [UInt8] {
        let pixelCount = width * height
        switch frame.dataEncoding {
        case .rawIndices:
            guard frame.payload.count == pixelCount else {
                throw VisualizationError.unexpectedIndexCount(expected: pixelCount, actual: frame.payload.count)
            }
            return Array(frame.payload)

        case .lzwSubblocks:
            // Payload already concatenated; treat as single sub-block list.
            let subBlock = Data(frame.payload)
            let indices = try LZWDecoderImpl.decompress(subBlocks: [subBlock],
                                                    minCodeSize: lzwMinCodeSize,
                                                    expectedPixelCount: pixelCount)
            guard indices.count == pixelCount else {
                throw VisualizationError.unexpectedIndexCount(expected: pixelCount, actual: indices.count)
            }
            return indices
        }
    }

    private static func colorize(indices: [UInt8], frame: GIXFrame, gip: GIP) throws -> [UInt8] {
        guard frame.paletteRef < gip.palettes.count else {
            throw VisualizationError.paletteOutOfRange(frame.paletteRef)
        }

        let palette = gip.palettes[Int(frame.paletteRef)].rgb
        return indices.flatMap { index -> [UInt8] in
            let idx = Int(index)
            if idx < palette.count {
                let color = palette[idx]
                if color.count == 3 {
                    return [color[0], color[1], color[2], 0xFF]
                }
            }
            return [0, 0, 0, 0xFF]
        }
    }

    private static func makeImage(width: Int, height: Int, pixels: [UInt8]) -> UIImage {
        let bytesPerRow = width * 4
        let data = Data(pixels)
        return data.withUnsafeBytes { ptr -> UIImage in
            let provider = CGDataProvider(data: data as CFData)!
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
            return UIImage(cgImage: cgImage)
        }
    }

    // MARK: - Errors

    enum VisualizationError: LocalizedError {
        case unexpectedIndexCount(expected: Int, actual: Int)
        case paletteOutOfRange(UInt32)
        case unsupportedEncoding

        var errorDescription: String? {
            switch self {
            case .unexpectedIndexCount(let expected, let actual):
                return "Expected \(expected) indices but found \(actual)."
            case .paletteOutOfRange(let index):
                return "Frame references palette \(index) which is out of range."
            case .unsupportedEncoding:
                return "GIX frame encoding not supported for visualization."
            }
        }
    }
}

@available(iOS 26.0, *)
private extension GIXFrame {
    var lzwMinCodeSizeCandidate: UInt8 {
        // The frame itself doesn't store min code size; rely on GIF default 8 when missing
        return 8
    }
}
