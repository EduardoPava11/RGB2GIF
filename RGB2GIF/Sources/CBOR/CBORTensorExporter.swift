//
//  CBORTensorExporter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L1 TENSOR EXPORT - 729 INDIVIDUAL CELL FILES                            ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Exports each of the 9×9×9 tensor cells as individual CBOR files:        ║
//  ║  • c000.cbor - c728.cbor (one per cell)                                  ║
//  ║  • summary.cbor (all 729 centroids in one file)                          ║
//  ║  • grid.png (9×9 visualization per temporal layer)                       ║
//  ║                                                                           ║
//  ║  Cell indexing: linearIndex = t * 81 + y * 9 + x                         ║
//  ║  Coordinate system: X=right, Y=up, Z=time                                ║
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

private let tensorExportLogger = Logger(subsystem: "com.rgb2gif", category: "CBORTensorExporter")

// MARK: - CBORTensorExporter

@available(iOS 26.0, *)
public final class CBORTensorExporter {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Export All Cells

    /// Export all 729 tensor cells as individual CBOR files
    /// - Parameter tensor: The TensorCube729 to export
    /// - Returns: Total bytes written
    public func exportAllCells(from tensor: TensorCube729) throws -> Int64 {
        var totalBytes: Int64 = 0

        for linearIndex in 0..<729 {
            totalBytes += try exportCell(from: tensor, linearIndex: linearIndex)
        }

        // Export summary
        totalBytes += try exportSummary(from: tensor)

        // Export visualization PNG
        try exportGridVisualization(from: tensor)

        tensorExportLogger.info("Exported 729 tensor cells: \(totalBytes) bytes total")
        return totalBytes
    }

    // MARK: - Export Single Cell

    /// Export a single tensor cell to CBOR
    /// - Parameters:
    ///   - tensor: The TensorCube729
    ///   - linearIndex: Linear index (0-728)
    /// - Returns: Bytes written
    public func exportCell(from tensor: TensorCube729, linearIndex: Int) throws -> Int64 {
        let (t, y, x) = Self.cellPosition(for: linearIndex)
        let cell = tensor[t, y, x]
        let centroid = cell.centroidColor()

        // Compute source ranges (which pixels/frames this cell aggregates)
        let frameStart = t * 9
        let frameEnd = frameStart + 8
        let yStart = y * 9
        let yEnd = yStart + 8
        let xStart = x * 9
        let xEnd = xStart + 8

        let cbor: CBOR = .map([
            "cell_index": .unsignedInt(UInt64(linearIndex)),
            "position": .map([
                "t": .unsignedInt(UInt64(t)),
                "y": .unsignedInt(UInt64(y)),
                "x": .unsignedInt(UInt64(x))
            ]),
            "source_ranges": .map([
                "frames": .array([.unsignedInt(UInt64(frameStart)), .unsignedInt(UInt64(frameEnd))]),
                "y_pixels": .array([.unsignedInt(UInt64(yStart)), .unsignedInt(UInt64(yEnd))]),
                "x_pixels": .array([.unsignedInt(UInt64(xStart)), .unsignedInt(UInt64(xEnd))])
            ]),
            "voxel_count": .unsignedInt(729),  // 9×9×9
            "centroid": .map([
                "r": .unsignedInt(UInt64(centroid.r)),
                "g": .unsignedInt(UInt64(centroid.g)),
                "b": .unsignedInt(UInt64(centroid.b)),
                "weight": .double(Double(cell.totalWeight))
            ]),
            "weighted_sums": .map([
                "r": .double(Double(cell.weightedR)),
                "g": .double(Double(cell.weightedG)),
                "b": .double(Double(cell.weightedB))
            ])
        ])

        let data = Data(cbor.encode())
        let url = session.tensorCellURL(index: linearIndex)
        try data.write(to: url)

        return Int64(data.count)
    }

    // MARK: - Export Summary

    /// Export summary.cbor with all 729 centroids
    public func exportSummary(from tensor: TensorCube729) throws -> Int64 {
        var cellsArray: [CBOR] = []
        cellsArray.reserveCapacity(729)

        let stats = tensor.statistics()

        for linearIndex in 0..<729 {
            let (t, y, x) = Self.cellPosition(for: linearIndex)
            let cell = tensor[t, y, x]
            let centroid = cell.centroidColor()

            cellsArray.append(.map([
                "index": .unsignedInt(UInt64(linearIndex)),
                "pos": .array([
                    .unsignedInt(UInt64(t)),
                    .unsignedInt(UInt64(y)),
                    .unsignedInt(UInt64(x))
                ]),
                "rgb": .array([
                    .unsignedInt(UInt64(centroid.r)),
                    .unsignedInt(UInt64(centroid.g)),
                    .unsignedInt(UInt64(centroid.b))
                ]),
                "weight": .double(Double(cell.totalWeight))
            ]))
        }

        let cbor: CBOR = .map([
            "grid_dimension": .unsignedInt(9),
            "total_cells": .unsignedInt(729),
            "coordinate_system": CoordinateSystem.toCBOR(),
            "cells": .array(cellsArray),
            "statistics": .map([
                "non_zero_cells": .unsignedInt(UInt64(stats.nonZeroCells)),
                "total_weight": .double(Double(stats.totalWeight)),
                "average_weight": .double(Double(stats.averageWeight)),
                "weight_range": .array([
                    .double(Double(stats.minWeight)),
                    .double(Double(stats.maxWeight))
                ])
            ])
        ])

        let data = Data(cbor.encode())
        try data.write(to: session.tensorSummaryURL)

        tensorExportLogger.debug("Exported tensor summary: \(data.count) bytes")
        return Int64(data.count)
    }

    // MARK: - Grid Visualization

    /// Export PNG visualization of tensor grid (9×9 per temporal layer, stacked)
    public func exportGridVisualization(from tensor: TensorCube729) throws {
        #if canImport(UIKit)
        // Create 9×9 grid for each of 9 temporal layers, arranged 3×3
        let cellSize = 20  // pixels per cell
        let padding = 2
        let gridSize = cellSize * 9 + padding * 10
        let totalWidth = gridSize * 3
        let totalHeight = gridSize * 3

        UIGraphicsBeginImageContext(CGSize(width: totalWidth, height: totalHeight))
        guard let context = UIGraphicsGetCurrentContext() else {
            tensorExportLogger.warning("Failed to create graphics context for tensor grid")
            return
        }

        // Black background
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        // Draw each temporal layer in a 3×3 arrangement
        for t in 0..<9 {
            let gridX = (t % 3) * gridSize
            let gridY = (t / 3) * gridSize

            for y in 0..<9 {
                for x in 0..<9 {
                    let cell = tensor[t, y, x]
                    let centroid = cell.centroidColor()

                    let color = UIColor(
                        red: CGFloat(centroid.r) / 255.0,
                        green: CGFloat(centroid.g) / 255.0,
                        blue: CGFloat(centroid.b) / 255.0,
                        alpha: 1.0
                    )

                    context.setFillColor(color.cgColor)

                    // Y is flipped in screen coordinates (Y=up in our system, but Y=down on screen)
                    let screenY = 8 - y
                    let rect = CGRect(
                        x: gridX + padding + x * (cellSize + padding),
                        y: gridY + padding + screenY * (cellSize + padding),
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(rect)
                }
            }

            // Label for temporal layer
            let label = "t=\(t)"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 12)
            ]
            (label as NSString).draw(at: CGPoint(x: gridX + 5, y: gridY + 5), withAttributes: attrs)
        }

        guard let image = UIGraphicsGetImageFromCurrentImageContext(),
              let pngData = image.pngData() else {
            UIGraphicsEndImageContext()
            tensorExportLogger.warning("Failed to generate tensor grid PNG")
            return
        }

        UIGraphicsEndImageContext()
        try pngData.write(to: session.tensorGridPNGURL)
        tensorExportLogger.debug("Exported tensor grid visualization")
        #else
        tensorExportLogger.warning("PNG export skipped on non-UIKit platform")
        #endif
    }

    // MARK: - Cell Indexing

    /// Convert linear index to (t, y, x) position
    public static func cellPosition(for linearIndex: Int) -> (t: Int, y: Int, x: Int) {
        let t = linearIndex / 81
        let remainder = linearIndex % 81
        let y = remainder / 9
        let x = remainder % 9
        return (t, y, x)
    }

    /// Convert (t, y, x) position to linear index
    public static func linearIndex(t: Int, y: Int, x: Int) -> Int {
        return t * 81 + y * 9 + x
    }
}

// MARK: - TensorCube729 Subscript Extension

@available(iOS 26.0, *)
extension TensorCube729 {

    /// Access cell by linear index (0-728)
    public func cell(at linearIndex: Int) -> Cell {
        let t = linearIndex / 81
        let remainder = linearIndex % 81
        let y = remainder / 9
        let x = remainder % 9
        return self[t, y, x]
    }
}
