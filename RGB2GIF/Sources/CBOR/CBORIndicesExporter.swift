//
//  CBORIndicesExporter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L3 INDICES EXPORT - 81 FRAME INDEX FILES                                ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Exports palette indices for each frame:                                 ║
//  ║  • i00.cbor - i80.cbor (one per frame)                                   ║
//  ║  • Each file contains 6,561 indices (81×81 pixels)                       ║
//  ║  • Index values 0-255 reference the 256-color palette                    ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let indicesLogger = Logger(subsystem: "com.rgb2gif", category: "CBORIndicesExporter")

// MARK: - CBORIndicesExporter

@available(iOS 26.0, *)
public final class CBORIndicesExporter {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Export Single Frame Indices

    /// Export palette indices for a single frame
    /// - Parameters:
    ///   - indices: Array of 6,561 palette indices (81×81 pixels)
    ///   - frameIndex: Frame index (0-80)
    /// - Returns: Bytes written
    public func exportFrameIndices(_ indices: [UInt8], frameIndex: Int) throws -> Int64 {
        guard indices.count == 6561 else {
            throw RGB2GIFError.cborExportFailed("Frame \(frameIndex) has \(indices.count) indices, expected 6561")
        }

        let cbor: CBOR = .map([
            "frame_index": .unsignedInt(UInt64(frameIndex)),
            "dimensions": .map([
                "width": .unsignedInt(81),
                "height": .unsignedInt(81)
            ]),
            "pixel_count": .unsignedInt(6561),
            "indices": .byteString(indices)
        ])

        let data = Data(cbor.encode())
        let url = session.indicesURL(index: frameIndex)
        try data.write(to: url)

        indicesLogger.debug("Exported frame \(frameIndex) indices: \(data.count) bytes")
        return Int64(data.count)
    }

    // MARK: - Export All Frames

    /// Export palette indices for all 81 frames
    /// - Parameter allIndices: Array of 81 arrays, each containing 6,561 indices
    /// - Returns: Total bytes written
    public func exportAllFrameIndices(_ allIndices: [[UInt8]]) throws -> Int64 {
        guard allIndices.count == 81 else {
            throw RGB2GIFError.cborExportFailed("Expected 81 frames, got \(allIndices.count)")
        }

        var totalBytes: Int64 = 0

        for (frameIndex, indices) in allIndices.enumerated() {
            totalBytes += try exportFrameIndices(indices, frameIndex: frameIndex)
        }

        indicesLogger.info("Exported 81 frame indices: \(totalBytes) bytes total")
        return totalBytes
    }

    // MARK: - Compute Indices from Frames

    /// Compute palette indices for a frame by nearest-neighbor matching
    /// - Parameters:
    ///   - rgbData: RGB pixel data (19,683 bytes = 81×81×3)
    ///   - palette: 256-color palette (ARGB UInt32)
    /// - Returns: Array of 6,561 palette indices
    public func computeIndices(rgbData: Data, palette: [UInt32]) -> [UInt8] {
        let pixelCount = rgbData.count / 3
        var indices = [UInt8](repeating: 0, count: pixelCount)

        // Build fast lookup from palette
        let paletteRGB: [(r: Int, g: Int, b: Int)] = palette.prefix(256).map { argb in
            (
                r: Int((argb >> 16) & 0xFF),
                g: Int((argb >> 8) & 0xFF),
                b: Int(argb & 0xFF)
            )
        }

        // Process each pixel
        for i in 0..<pixelCount {
            let r = Int(rgbData[i * 3])
            let g = Int(rgbData[i * 3 + 1])
            let b = Int(rgbData[i * 3 + 2])

            // Find nearest palette color
            var bestIndex: UInt8 = 0
            var bestDistance = Int.max

            for (index, pColor) in paletteRGB.enumerated() {
                let dr = r - pColor.r
                let dg = g - pColor.g
                let db = b - pColor.b
                let distance = dr * dr + dg * dg + db * db

                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = UInt8(index)
                }
            }

            indices[i] = bestIndex
        }

        return indices
    }

    // MARK: - Index Statistics

    /// Compute usage statistics for frame indices
    public func computeStatistics(_ indices: [UInt8]) -> IndexStats {
        var histogram = [Int](repeating: 0, count: 256)
        var usedColors = Set<UInt8>()

        for index in indices {
            histogram[Int(index)] += 1
            usedColors.insert(index)
        }

        let maxUsage = histogram.max() ?? 0
        let minUsage = histogram.filter { $0 > 0 }.min() ?? 0

        return IndexStats(
            pixelCount: indices.count,
            uniqueIndices: usedColors.count,
            maxUsage: maxUsage,
            minUsage: minUsage,
            histogram: histogram
        )
    }
}

// MARK: - IndexStats

@available(iOS 26.0, *)
public struct IndexStats {
    public let pixelCount: Int
    public let uniqueIndices: Int
    public let maxUsage: Int
    public let minUsage: Int
    public let histogram: [Int]
}

// MARK: - LZW Statistics Exporter

@available(iOS 26.0, *)
extension CBORIndicesExporter {

    /// Export LZW compression statistics to L4
    public func exportLZWStats(
        inputBytes: Int,
        outputBytes: Int,
        compressionRatio: Double,
        framesCompressed: Int
    ) throws -> Int64 {
        let cbor: CBOR = .map([
            "algorithm": .utf8String("lzw_gif89a"),
            "minimum_code_size": .unsignedInt(8),
            "input_bytes": .unsignedInt(UInt64(inputBytes)),
            "output_bytes": .unsignedInt(UInt64(outputBytes)),
            "compression_ratio": .double(compressionRatio),
            "frames_compressed": .unsignedInt(UInt64(framesCompressed))
        ])

        let data = Data(cbor.encode())
        try data.write(to: session.lzwStatsURL)

        indicesLogger.debug("Exported LZW stats: \(data.count) bytes")
        return Int64(data.count)
    }
}
