//
//  L3TensorTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L3_TENSOR TESTS - 729-Cell Tensor Validation                            ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Validates the 9×9×9 tensor aggregated from 81 frames:                   ║
//  ║  • L3.1  Cell Count (exactly 729)                                        ║
//  ║  • L3.2  File Naming (c000.cbor - c728.cbor)                             ║
//  ║  • L3.3  Summary Exists (summary.cbor)                                   ║
//  ║  • L3.4  Cell Index (0-728)                                              ║
//  ║  • L3.5  Position Valid (t,y,x all 0-8)                                  ║
//  ║  • L3.6  Index Formula (t×81+y×9+x = cell_index)                         ║
//  ║  • L3.7  Centroid Range (r,g,b all 0-255)                                ║
//  ║  • L3.8  Weight Positive (weight > 0)                                    ║
//  ║  • L3.9  Source Ranges (valid 9×9×9 regions)                             ║
//  ║  • L3.10 Spatial Coherence (adjacent cells similar)                      ║
//  ║  • L3.11 Non-Zero Cells (count cells with weight > 0)                    ║
//  ║  • L3.12 Weight Distribution (min/max/avg)                               ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let testLogger = Logger(subsystem: "com.rgb2gif.tests", category: "L3Tensor")

@available(iOS 26.0, *)
public struct L3TensorTests {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Cell Data Structure

    private struct ParsedCell {
        let index: Int
        let t: Int
        let y: Int
        let x: Int
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let weight: Double
    }

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    public func run() async -> StageTestResults {
        var results = StageTestResults(stageName: "L3_TENSOR")

        testLogger.info("Starting L3_TENSOR tests for session: \(session.sessionID)")

        let fm = FileManager.default
        let cellsURL = session.l3TensorCellsURL

        // Collect all cell CBOR files
        var cborFiles: [URL] = []
        do {
            let contents = try fm.contentsOfDirectory(at: cellsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            cborFiles = contents.filter { $0.pathExtension == "cbor" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            results.tests.append(CBORTestResult(
                id: "L3.0",
                name: "Directory Access",
                passed: false,
                expected: "L3_tensor/cells directory exists",
                actual: "Error: \(error.localizedDescription)",
                details: "Cannot access tensor cells at \(cellsURL.path)"
            ))
            return results
        }

        // Parse all cell files
        var parsedCells: [ParsedCell] = []
        var parseErrors: [String] = []

        for url in cborFiles {
            if let cell = parseCell(from: url) {
                parsedCells.append(cell)
            } else {
                parseErrors.append("Failed to parse \(url.lastPathComponent)")
            }
        }

        // Sort by index
        parsedCells.sort { $0.index < $1.index }

        // Check summary file
        let summaryURL = session.tensorSummaryURL
        let summaryExists = fm.fileExists(atPath: summaryURL.path)

        // L3.1: Cell Count
        results.tests.append(testCellCount(cborFiles.count))

        // L3.2: File Naming
        results.tests.append(testFileNaming(cborFiles))

        // L3.3: Summary Exists
        results.tests.append(testSummaryExists(summaryExists))

        // L3.4: Cell Index
        results.tests.append(testCellIndex(parsedCells))

        // L3.5: Position Valid
        results.tests.append(testPositionValid(parsedCells))

        // L3.6: Index Formula
        results.tests.append(testIndexFormula(parsedCells))

        // L3.7: Centroid Range
        results.tests.append(testCentroidRange(parsedCells))

        // L3.8: Weight Positive
        results.tests.append(testWeightPositive(parsedCells))

        // L3.9: Source Ranges - check a sample
        results.tests.append(testSourceRanges(cborFiles))

        // L3.10: Spatial Coherence
        let (coherenceTest, outliers) = testSpatialCoherence(parsedCells)
        results.tests.append(coherenceTest)

        // L3.11: Non-Zero Cells
        results.tests.append(testNonZeroCells(parsedCells))

        // L3.12: Weight Distribution
        results.tests.append(testWeightDistribution(parsedCells))

        // Diagnostics
        results.diagnostics.append(generateSpatialCoherenceGrid(parsedCells, layer: 4))

        if !outliers.isEmpty {
            results.diagnostics.append("SPATIAL OUTLIERS: \(outliers.prefix(5).joined(separator: "; "))")
        }

        testLogger.info("L3_TENSOR tests complete: \(results.passCount)/\(results.totalCount) passed")

        return results
    }

    // MARK: - Parsing

    private func parseCell(from url: URL) -> ParsedCell? {
        do {
            let data = try Data(contentsOf: url)
            guard let cbor = try CBOR.decode([UInt8](data)),
                  case .map(let map) = cbor else {
                return nil
            }

            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            var index = -1
            var t = -1, y = -1, x = -1
            var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
            var weight: Double = 0

            if case .unsignedInt(let i) = dict["cell_index"] {
                index = Int(i)
            }

            if case .map(let pos) = dict["position"] {
                for (k, v) in pos {
                    if case .utf8String("t") = k, case .unsignedInt(let val) = v { t = Int(val) }
                    if case .utf8String("y") = k, case .unsignedInt(let val) = v { y = Int(val) }
                    if case .utf8String("x") = k, case .unsignedInt(let val) = v { x = Int(val) }
                }
            }

            if case .map(let centroid) = dict["centroid"] {
                for (k, v) in centroid {
                    if case .utf8String("r") = k, case .unsignedInt(let val) = v { r = UInt8(val) }
                    if case .utf8String("g") = k, case .unsignedInt(let val) = v { g = UInt8(val) }
                    if case .utf8String("b") = k, case .unsignedInt(let val) = v { b = UInt8(val) }
                    if case .utf8String("weight") = k, case .double(let val) = v { weight = val }
                }
            }

            return ParsedCell(index: index, t: t, y: y, x: x, r: r, g: g, b: b, weight: weight)
        } catch {
            return nil
        }
    }

    // MARK: - Individual Tests

    /// L3.1: Cell Count
    private func testCellCount(_ count: Int) -> CBORTestResult {
        CBORTestResult(
            id: "L3.1",
            name: "Cell Count",
            passed: count == 729,
            expected: "729",
            actual: "\(count)",
            details: count == 729 ? "All 729 cells present" : "Missing \(729 - count) cell(s)"
        )
    }

    /// L3.2: File Naming - c000.cbor through c728.cbor
    private func testFileNaming(_ files: [URL]) -> CBORTestResult {
        var missing: [String] = []
        for i in 0..<729 {
            let expected = String(format: "c%03d.cbor", i)
            if !files.contains(where: { $0.lastPathComponent == expected }) {
                missing.append(expected)
            }
        }

        return CBORTestResult(
            id: "L3.2",
            name: "File Naming",
            passed: missing.isEmpty,
            expected: "c000.cbor - c728.cbor",
            actual: missing.isEmpty ? "All present" : "\(missing.count) missing",
            details: missing.isEmpty ? "All files named correctly" : "Missing: \(missing.prefix(5).joined(separator: ", "))"
        )
    }

    /// L3.3: Summary Exists
    private func testSummaryExists(_ exists: Bool) -> CBORTestResult {
        CBORTestResult(
            id: "L3.3",
            name: "Summary Exists",
            passed: exists,
            expected: "summary.cbor present",
            actual: exists ? "Present" : "Missing",
            details: exists ? "Summary file found" : "summary.cbor not found in L3_tensor"
        )
    }

    /// L3.4: Cell Index - all indices 0-728
    private func testCellIndex(_ cells: [ParsedCell]) -> CBORTestResult {
        var outOfRange: [Int] = []
        for cell in cells {
            if cell.index < 0 || cell.index > 728 {
                outOfRange.append(cell.index)
            }
        }

        return CBORTestResult(
            id: "L3.4",
            name: "Cell Index",
            passed: outOfRange.isEmpty,
            expected: "0-728",
            actual: outOfRange.isEmpty ? "All valid" : "\(outOfRange.count) out of range",
            details: outOfRange.isEmpty ? "All indices in range" : "Invalid: \(outOfRange.prefix(5))"
        )
    }

    /// L3.5: Position Valid - t,y,x all 0-8
    private func testPositionValid(_ cells: [ParsedCell]) -> CBORTestResult {
        var invalid: [String] = []
        for cell in cells {
            if cell.t < 0 || cell.t > 8 ||
               cell.y < 0 || cell.y > 8 ||
               cell.x < 0 || cell.x > 8 {
                invalid.append("Cell \(cell.index): (\(cell.t),\(cell.y),\(cell.x))")
            }
        }

        return CBORTestResult(
            id: "L3.5",
            name: "Position Valid",
            passed: invalid.isEmpty,
            expected: "t,y,x all 0-8",
            actual: invalid.isEmpty ? "All valid" : "\(invalid.count) invalid",
            details: invalid.isEmpty ? "All positions in range" : invalid.prefix(3).joined(separator: "; ")
        )
    }

    /// L3.6: Index Formula - t×81+y×9+x = cell_index
    private func testIndexFormula(_ cells: [ParsedCell]) -> CBORTestResult {
        var mismatches: [String] = []
        for cell in cells {
            let computed = cell.t * 81 + cell.y * 9 + cell.x
            if computed != cell.index {
                mismatches.append("Cell \(cell.index): computed=\(computed)")
            }
        }

        return CBORTestResult(
            id: "L3.6",
            name: "Index Formula",
            passed: mismatches.isEmpty,
            expected: "t×81+y×9+x = index",
            actual: mismatches.isEmpty ? "All match" : "\(mismatches.count) mismatch",
            details: mismatches.isEmpty ? "Index formula verified" : mismatches.prefix(3).joined(separator: "; ")
        )
    }

    /// L3.7: Centroid Range - r,g,b all 0-255
    private func testCentroidRange(_ cells: [ParsedCell]) -> CBORTestResult {
        // UInt8 is always 0-255, but check for suspicious patterns
        var suspicious: [String] = []
        var allBlack = 0
        var allWhite = 0

        for cell in cells {
            if cell.r == 0 && cell.g == 0 && cell.b == 0 {
                allBlack += 1
            }
            if cell.r == 255 && cell.g == 255 && cell.b == 255 {
                allWhite += 1
            }
        }

        if allBlack > 700 {
            suspicious.append("\(allBlack) cells are pure black")
        }
        if allWhite > 700 {
            suspicious.append("\(allWhite) cells are pure white")
        }

        return CBORTestResult(
            id: "L3.7",
            name: "Centroid Range",
            passed: suspicious.isEmpty,
            expected: "Varied RGB values",
            actual: suspicious.isEmpty ? "Normal distribution" : suspicious.joined(separator: ", "),
            details: "Black cells: \(allBlack), White cells: \(allWhite)"
        )
    }

    /// L3.8: Weight Positive
    private func testWeightPositive(_ cells: [ParsedCell]) -> CBORTestResult {
        var zeroWeight: [Int] = []
        for cell in cells {
            if cell.weight <= 0 {
                zeroWeight.append(cell.index)
            }
        }

        return CBORTestResult(
            id: "L3.8",
            name: "Weight Positive",
            passed: zeroWeight.isEmpty,
            expected: "All weights > 0",
            actual: zeroWeight.isEmpty ? "All positive" : "\(zeroWeight.count) zero/negative",
            details: zeroWeight.isEmpty ? "All cells have positive weight" : "Zero weight at: \(zeroWeight.prefix(5))"
        )
    }

    /// L3.9: Source Ranges - sample check
    private func testSourceRanges(_ files: [URL]) -> CBORTestResult {
        guard let first = files.first else {
            return CBORTestResult(
                id: "L3.9",
                name: "Source Ranges",
                passed: false,
                expected: "Valid 9×9×9 regions",
                actual: "No files to check",
                details: "Cannot verify source ranges"
            )
        }

        do {
            let data = try Data(contentsOf: first)
            guard let cbor = try CBOR.decode([UInt8](data)),
                  case .map(let map) = cbor else {
                return CBORTestResult(id: "L3.9", name: "Source Ranges", passed: false, expected: "Valid ranges", actual: "Parse error", details: "Cannot parse first cell")
            }

            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            if case .map(let ranges) = dict["source_ranges"] {
                // Verify structure exists
                var hasFrames = false, hasY = false, hasX = false

                for (k, _) in ranges {
                    if case .utf8String("frames") = k { hasFrames = true }
                    if case .utf8String("y_pixels") = k { hasY = true }
                    if case .utf8String("x_pixels") = k { hasX = true }
                }

                return CBORTestResult(
                    id: "L3.9",
                    name: "Source Ranges",
                    passed: hasFrames && hasY && hasX,
                    expected: "frames, y_pixels, x_pixels",
                    actual: hasFrames && hasY && hasX ? "All present" : "Missing fields",
                    details: "Source range structure verified"
                )
            }
        } catch {
            return CBORTestResult(id: "L3.9", name: "Source Ranges", passed: false, expected: "Valid ranges", actual: "Error: \(error)", details: "Exception during verification")
        }

        return CBORTestResult(id: "L3.9", name: "Source Ranges", passed: false, expected: "Valid ranges", actual: "Missing source_ranges", details: "source_ranges not found in CBOR")
    }

    /// L3.10: Spatial Coherence - adjacent cells should have similar colors
    private func testSpatialCoherence(_ cells: [ParsedCell]) -> (CBORTestResult, [String]) {
        let threshold: Double = 100  // RGB distance threshold
        var outliers: [String] = []

        // Build lookup by position
        var cellMap: [String: ParsedCell] = [:]
        for cell in cells {
            cellMap["\(cell.t),\(cell.y),\(cell.x)"] = cell
        }

        // Check each cell against its neighbors
        for cell in cells {
            var neighborColors: [(r: UInt8, g: UInt8, b: UInt8)] = []

            // Check 6 neighbors (±t, ±y, ±x)
            let neighbors = [
                (cell.t-1, cell.y, cell.x), (cell.t+1, cell.y, cell.x),
                (cell.t, cell.y-1, cell.x), (cell.t, cell.y+1, cell.x),
                (cell.t, cell.y, cell.x-1), (cell.t, cell.y, cell.x+1)
            ]

            for (nt, ny, nx) in neighbors {
                if let neighbor = cellMap["\(nt),\(ny),\(nx)"] {
                    neighborColors.append((neighbor.r, neighbor.g, neighbor.b))
                }
            }

            if neighborColors.isEmpty { continue }

            // Calculate average neighbor color
            let avgR = Double(neighborColors.map { Int($0.r) }.reduce(0, +)) / Double(neighborColors.count)
            let avgG = Double(neighborColors.map { Int($0.g) }.reduce(0, +)) / Double(neighborColors.count)
            let avgB = Double(neighborColors.map { Int($0.b) }.reduce(0, +)) / Double(neighborColors.count)

            // Calculate distance
            let dr = Double(cell.r) - avgR
            let dg = Double(cell.g) - avgG
            let db = Double(cell.b) - avgB
            let distance = sqrt(dr*dr + dg*dg + db*db)

            if distance > threshold {
                outliers.append("Cell \(cell.index) (t=\(cell.t),y=\(cell.y),x=\(cell.x)): dist=\(Int(distance))")
            }
        }

        return (CBORTestResult(
            id: "L3.10",
            name: "Spatial Coherence",
            passed: outliers.count < 10,  // Allow a few outliers
            expected: "Adjacent cells similar (threshold: \(Int(threshold)))",
            actual: outliers.isEmpty ? "All coherent" : "\(outliers.count) outlier(s)",
            details: outliers.isEmpty ? "All cells spatially coherent" : "First outlier: \(outliers.first ?? "")"
        ), outliers)
    }

    /// L3.11: Non-Zero Cells
    private func testNonZeroCells(_ cells: [ParsedCell]) -> CBORTestResult {
        let nonZero = cells.filter { $0.weight > 0 }.count

        return CBORTestResult(
            id: "L3.11",
            name: "Non-Zero Cells",
            passed: nonZero == 729,
            expected: "729 (all)",
            actual: "\(nonZero)",
            details: nonZero == 729 ? "All cells have data" : "\(729 - nonZero) cells have zero weight"
        )
    }

    /// L3.12: Weight Distribution
    private func testWeightDistribution(_ cells: [ParsedCell]) -> CBORTestResult {
        let weights = cells.map { $0.weight }
        let minW = weights.min() ?? 0
        let maxW = weights.max() ?? 0
        let avgW = weights.reduce(0, +) / Double(weights.count)

        // Check for reasonable distribution
        let reasonable = minW > 0 && maxW > 0 && (maxW / minW) < 1000

        return CBORTestResult(
            id: "L3.12",
            name: "Weight Distribution",
            passed: reasonable,
            expected: "Reasonable distribution",
            actual: String(format: "Min=%.0f, Max=%.0f, Avg=%.0f", minW, maxW, avgW),
            details: reasonable ? "Weight distribution looks normal" : "Unusual weight variance"
        )
    }

    // MARK: - Diagnostics

    private func generateSpatialCoherenceGrid(_ cells: [ParsedCell], layer: Int) -> String {
        var lines: [String] = []
        lines.append("TENSOR SPATIAL COHERENCE (Layer t=\(layer), middle):")
        lines.append("┌─────────────────────────────────────────────────────────────────────────────┐")

        // Build lookup
        var cellMap: [String: ParsedCell] = [:]
        for cell in cells where cell.t == layer {
            cellMap["\(cell.y),\(cell.x)"] = cell
        }

        // Header row
        var header = "│     │"
        for x in 0..<9 {
            header += "  x=\(x)    │"
        }
        lines.append(header)
        lines.append("├─────────────────────────────────────────────────────────────────────────────┤")

        // Data rows
        for y in 0..<9 {
            var row = "│ y=\(y) │"
            for x in 0..<9 {
                if let cell = cellMap["\(y),\(x)"] {
                    row += String(format: "(%3d,%3d,%3d)", cell.r, cell.g, cell.b)
                } else {
                    row += "   N/A   "
                }
                row += "│"
            }
            lines.append(row)
        }

        lines.append("└─────────────────────────────────────────────────────────────────────────────┘")

        return lines.joined(separator: "\n")
    }
}
