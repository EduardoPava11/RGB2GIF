//
//  CBORPaletteExporter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L2 PALETTE EXPORT - 256-COLOR PALETTE FROM OCTREE QUANTIZATION          ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Exports the quantized 256-color palette:                                ║
//  ║  • palette.cbor - 256 RGB colors + histogram                             ║
//  ║  • mapping.cbor - Which tensor cells map to which palette colors         ║
//  ║  • palette.png - 16×16 color swatch visualization                        ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import SwiftCBOR
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let paletteExportLogger = Logger(subsystem: "com.rgb2gif", category: "CBORPaletteExporter")

// MARK: - CBORPaletteExporter

@available(iOS 26.0, *)
public final class CBORPaletteExporter {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Export Palette

    /// Export the 256-color palette to CBOR
    /// - Parameters:
    ///   - palette: Array of 256 ARGB colors (UInt32)
    ///   - histogram: Optional usage counts per color
    ///   - algorithm: Quantization algorithm used
    /// - Returns: Bytes written
    public func exportPalette(
        _ palette: [UInt32],
        histogram: [Int]? = nil,
        algorithm: String = "octree_v1"
    ) throws -> Int64 {
        // Convert ARGB to RGB arrays
        var colorsArray: [CBOR] = []
        for color in palette.prefix(256) {
            let r = (color >> 16) & 0xFF
            let g = (color >> 8) & 0xFF
            let b = color & 0xFF
            colorsArray.append(.array([
                .unsignedInt(UInt64(r)),
                .unsignedInt(UInt64(g)),
                .unsignedInt(UInt64(b))
            ]))
        }

        // Pad to 256 if needed
        while colorsArray.count < 256 {
            colorsArray.append(.array([.unsignedInt(0), .unsignedInt(0), .unsignedInt(0)]))
        }

        // Build histogram CBOR
        let histogramCBOR: CBOR
        if let hist = histogram {
            histogramCBOR = .array(hist.map { .unsignedInt(UInt64($0)) })
        } else {
            histogramCBOR = .null
        }

        let cbor: CBOR = .map([
            "color_count": .unsignedInt(256),
            "format": .utf8String("RGB8"),
            "algorithm": .utf8String(algorithm),
            "colors": .array(colorsArray),
            "histogram": histogramCBOR
        ])

        let data = Data(cbor.encode())
        try data.write(to: session.paletteURL)

        // Export PNG visualization
        try exportPaletteVisualization(palette)

        paletteExportLogger.debug("Exported palette: \(data.count) bytes")
        return Int64(data.count)
    }

    // MARK: - Export Mapping

    /// Export cell-to-palette mapping
    /// - Parameter mapping: Dictionary of cell index → palette index
    /// - Returns: Bytes written
    public func exportMapping(_ mapping: [Int: Int]) throws -> Int64 {
        var mappingCBOR: [CBOR: CBOR] = [:]
        for (cellIndex, paletteIndex) in mapping {
            mappingCBOR[.utf8String(String(cellIndex))] = .unsignedInt(UInt64(paletteIndex))
        }

        let cbor: CBOR = .map([
            "cell_count": .unsignedInt(729),
            "palette_size": .unsignedInt(256),
            "mapping": .map(mappingCBOR)
        ])

        let data = Data(cbor.encode())
        try data.write(to: session.paletteMappingURL)

        paletteExportLogger.debug("Exported palette mapping: \(data.count) bytes")
        return Int64(data.count)
    }

    // MARK: - Compute Mapping from Tensor

    /// Compute which palette index each tensor cell maps to
    /// - Parameters:
    ///   - tensor: Source tensor
    ///   - palette: Target palette
    /// - Returns: Dictionary mapping cell index → palette index
    public func computeMapping(tensor: TensorCube729, palette: [UInt32]) -> [Int: Int] {
        var mapping: [Int: Int] = [:]

        for linearIndex in 0..<729 {
            let cell = tensor.cell(at: linearIndex)
            let centroid = cell.centroidColor()

            // Find nearest palette color
            var bestIndex = 0
            var bestDistance = Int.max

            for (paletteIndex, argb) in palette.enumerated() {
                let pr = Int((argb >> 16) & 0xFF)
                let pg = Int((argb >> 8) & 0xFF)
                let pb = Int(argb & 0xFF)

                let dr = Int(centroid.r) - pr
                let dg = Int(centroid.g) - pg
                let db = Int(centroid.b) - pb

                // Squared Euclidean distance
                let distance = dr * dr + dg * dg + db * db

                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = paletteIndex
                }
            }

            mapping[linearIndex] = bestIndex
        }

        return mapping
    }

    // MARK: - Palette Visualization

    /// Export 16×16 palette swatch PNG
    private func exportPaletteVisualization(_ palette: [UInt32]) throws {
        #if canImport(UIKit)
        let swatchSize = 20  // pixels per swatch
        let padding = 1
        let gridSize = 16
        let totalSize = swatchSize * gridSize + padding * (gridSize + 1)

        UIGraphicsBeginImageContext(CGSize(width: totalSize, height: totalSize))
        guard let context = UIGraphicsGetCurrentContext() else {
            paletteExportLogger.warning("Failed to create graphics context for palette")
            return
        }

        // Dark gray background
        context.setFillColor(UIColor.darkGray.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: totalSize, height: totalSize))

        // Draw each color swatch
        for i in 0..<min(256, palette.count) {
            let x = i % gridSize
            let y = i / gridSize

            let argb = palette[i]
            let r = CGFloat((argb >> 16) & 0xFF) / 255.0
            let g = CGFloat((argb >> 8) & 0xFF) / 255.0
            let b = CGFloat(argb & 0xFF) / 255.0

            let color = UIColor(red: r, green: g, blue: b, alpha: 1.0)
            context.setFillColor(color.cgColor)

            let rect = CGRect(
                x: padding + x * (swatchSize + padding),
                y: padding + y * (swatchSize + padding),
                width: swatchSize,
                height: swatchSize
            )
            context.fill(rect)
        }

        guard let image = UIGraphicsGetImageFromCurrentImageContext(),
              let pngData = image.pngData() else {
            UIGraphicsEndImageContext()
            paletteExportLogger.warning("Failed to generate palette PNG")
            return
        }

        UIGraphicsEndImageContext()
        try pngData.write(to: session.palettePNGURL)
        paletteExportLogger.debug("Exported palette visualization")
        #else
        paletteExportLogger.warning("PNG export skipped on non-UIKit platform")
        #endif
    }

    // MARK: - Palette Statistics

    /// Compute palette statistics
    public func computeStatistics(for palette: [UInt32]) -> PaletteStats {
        var totalR: Int = 0
        var totalG: Int = 0
        var totalB: Int = 0
        var uniqueColors = Set<UInt32>()

        for color in palette.prefix(256) {
            let rgb = color & 0x00FFFFFF  // Mask off alpha
            uniqueColors.insert(rgb)

            let r = Int((color >> 16) & 0xFF)
            let g = Int((color >> 8) & 0xFF)
            let b = Int(color & 0xFF)

            totalR += r
            totalG += g
            totalB += b
        }

        let count = min(256, palette.count)
        return PaletteStats(
            colorCount: count,
            uniqueColors: uniqueColors.count,
            averageR: Double(totalR) / Double(count),
            averageG: Double(totalG) / Double(count),
            averageB: Double(totalB) / Double(count)
        )
    }
}

// MARK: - PaletteStats

@available(iOS 26.0, *)
public struct PaletteStats {
    public let colorCount: Int
    public let uniqueColors: Int
    public let averageR: Double
    public let averageG: Double
    public let averageB: Double
}
