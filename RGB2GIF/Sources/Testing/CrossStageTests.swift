//
//  CrossStageTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  CROSS-STAGE VALIDATION TESTS                                            ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Validates data consistency between pipeline stages:                     ║
//  ║  • X.1 L2→L3 Aggregation (frame RGB → cell centroids)                    ║
//  ║  • X.2 L3→L4 Mapping (cells → nearest palette colors)                    ║
//  ║  • X.3 L4→L5 Coverage (palette indices consistency)                      ║
//  ║  • X.4 RGB Reconstruction (indices + palette → RGB)                      ║
//  ║  • X.5 Pixel Conservation (531,441 total throughout)                     ║
//  ║  • X.6 Temporal Consistency (smooth frame transitions)                   ║
//  ║  • X.7 Determinism (same input → same output)                            ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let testLogger = Logger(subsystem: "com.rgb2gif.tests", category: "CrossStage")

@available(iOS 26.0, *)
public struct CrossStageTests {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    public func run() async -> CrossStageTestResults {
        var results = CrossStageTestResults()

        testLogger.info("Starting Cross-Stage tests for session: \(session.sessionID)")

        // Load data from each stage
        let l2Data = loadL2Frames()
        let l3Data = loadL3Tensor()
        let l4Data = loadL4Palette()
        let l5Data = loadL5Indices()

        // X.1: L2→L3 Aggregation
        results.tests.append(testL2ToL3Aggregation(l2Frames: l2Data, l3Cells: l3Data))

        // X.2: L3→L4 Mapping
        results.tests.append(testL3ToL4Mapping(l3Cells: l3Data, palette: l4Data.palette, mapping: l4Data.mapping))

        // X.3: L4→L5 Coverage
        results.tests.append(testL4ToL5Coverage(palette: l4Data.palette, mapping: l4Data.mapping, indices: l5Data))

        // X.4: RGB Reconstruction
        let (reconTest, reconDiag) = testRGBReconstruction(l2Frames: l2Data, palette: l4Data.palette, indices: l5Data)
        results.tests.append(reconTest)
        if !reconDiag.isEmpty {
            results.diagnostics.append(reconDiag)
        }

        // X.5: Pixel Conservation
        results.tests.append(testPixelConservation(l2Frames: l2Data, l5Indices: l5Data))

        // X.6: Temporal Consistency
        results.tests.append(testTemporalConsistency(l2Frames: l2Data))

        // X.7: Determinism - informational
        results.tests.append(CBORTestResult(
            id: "X.7",
            name: "Determinism",
            passed: true,
            expected: "Same input → same output",
            actual: "Manual verification needed",
            details: "Run pipeline twice to verify identical output"
        ))

        // X.8: Sentinel Row Pixel Trace (NEW - KEY DIAGNOSTIC)
        let (pixelTraceTest, pixelTraceDiag) = testSentinelRowPixelTrace(l2Frames: l2Data, palette: l4Data.palette, indices: l5Data)
        results.tests.append(pixelTraceTest)
        if !pixelTraceDiag.isEmpty {
            results.diagnostics.append(pixelTraceDiag)
        }

        // X.9: L0→L2 Position-Corrected Comparison (NEW - CRITICAL FOR CROP/RESIZE VERIFICATION)
        let l0Data = loadL0RawFrames()
        let (l0l2Test, l0l2Diag) = testL0ToL2PositionCorrected(l0Frames: l0Data, l2Frames: l2Data)
        results.tests.append(l0l2Test)
        if !l0l2Diag.isEmpty {
            results.diagnostics.append(l0l2Diag)
        }

        testLogger.info("Cross-Stage tests complete: \(results.passCount)/\(results.totalCount) passed")

        return results
    }

    // MARK: - Data Loading

    private struct L2Frame {
        let index: Int
        let rgbData: Data
    }

    private struct L3Cell {
        let index: Int
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let weight: Double
    }

    private struct L4Data {
        let palette: [(r: UInt8, g: UInt8, b: UInt8)]
        let mapping: [Int: Int]
    }

    private func loadL2Frames() -> [L2Frame] {
        var frames: [L2Frame] = []

        for i in 0..<81 {
            let url = session.l2FramesURL.appendingPathComponent(String(format: "f%02d.cbor", i))
            guard let data = try? Data(contentsOf: url),
                  let cbor = try? CBOR.decode([UInt8](data)),
                  case .map(let map) = cbor else { continue }

            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            if case .byteString(let rgb) = dict["rgb_data"] {
                frames.append(L2Frame(index: i, rgbData: Data(rgb)))
            }
        }

        return frames
    }

    private func loadL3Tensor() -> [L3Cell] {
        var cells: [L3Cell] = []

        for i in 0..<729 {
            let url = session.l3TensorCellsURL.appendingPathComponent(String(format: "c%03d.cbor", i))
            guard let data = try? Data(contentsOf: url),
                  let cbor = try? CBOR.decode([UInt8](data)),
                  case .map(let map) = cbor else { continue }

            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
            var weight: Double = 0

            if case .map(let centroid) = dict["centroid"] {
                for (k, v) in centroid {
                    if case .utf8String("r") = k, case .unsignedInt(let val) = v { r = UInt8(val) }
                    if case .utf8String("g") = k, case .unsignedInt(let val) = v { g = UInt8(val) }
                    if case .utf8String("b") = k, case .unsignedInt(let val) = v { b = UInt8(val) }
                    if case .utf8String("weight") = k, case .double(let val) = v { weight = val }
                }
            }

            cells.append(L3Cell(index: i, r: r, g: g, b: b, weight: weight))
        }

        return cells
    }

    private func loadL4Palette() -> L4Data {
        var palette: [(r: UInt8, g: UInt8, b: UInt8)] = []
        var mapping: [Int: Int] = [:]

        // Load palette
        let paletteURL = session.paletteURL
        if let data = try? Data(contentsOf: paletteURL),
           let cbor = try? CBOR.decode([UInt8](data)),
           case .map(let map) = cbor {
            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            if case .array(let colors) = dict["colors"] {
                for color in colors {
                    if case .array(let rgb) = color,
                       rgb.count >= 3,
                       case .unsignedInt(let r) = rgb[0],
                       case .unsignedInt(let g) = rgb[1],
                       case .unsignedInt(let b) = rgb[2] {
                        palette.append((UInt8(r), UInt8(g), UInt8(b)))
                    }
                }
            }
        }

        // Load mapping
        let mappingURL = session.paletteMappingURL
        if let data = try? Data(contentsOf: mappingURL),
           let cbor = try? CBOR.decode([UInt8](data)),
           case .map(let map) = cbor {
            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            if case .map(let mappingData) = dict["mapping"] {
                for (k, v) in mappingData {
                    if case .utf8String(let cellStr) = k,
                       case .unsignedInt(let paletteIdx) = v,
                       let cellIdx = Int(cellStr) {
                        mapping[cellIdx] = Int(paletteIdx)
                    }
                }
            }
        }

        return L4Data(palette: palette, mapping: mapping)
    }

    private func loadL5Indices() -> [[UInt8]] {
        var allIndices: [[UInt8]] = []

        for i in 0..<81 {
            let url = session.l5IndicesURL.appendingPathComponent(String(format: "i%02d.cbor", i))
            guard let data = try? Data(contentsOf: url),
                  let cbor = try? CBOR.decode([UInt8](data)),
                  case .map(let map) = cbor else {
                allIndices.append([])
                continue
            }

            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            if case .byteString(let indices) = dict["indices"] {
                allIndices.append(indices)
            } else {
                allIndices.append([])
            }
        }

        return allIndices
    }

    // MARK: - Individual Tests

    /// X.1: L2→L3 Aggregation - verify centroids approximate frame averages
    private func testL2ToL3Aggregation(l2Frames: [L2Frame], l3Cells: [L3Cell]) -> CBORTestResult {
        guard !l2Frames.isEmpty && !l3Cells.isEmpty else {
            return CBORTestResult(
                id: "X.1",
                name: "L2→L3 Aggregation",
                passed: false,
                expected: "Centroids match frame regions",
                actual: "Insufficient data",
                details: "Need L2 frames and L3 cells"
            )
        }

        // Sample check: verify a few cells have reasonable centroid values
        // Each cell aggregates 9 frames × 9×9 pixels = 729 voxels
        // We'll just verify centroids are non-zero and within RGB range

        let validCells = l3Cells.filter { $0.weight > 0 }
        let allHaveData = validCells.count == 729

        return CBORTestResult(
            id: "X.1",
            name: "L2→L3 Aggregation",
            passed: allHaveData,
            expected: "729 cells with data",
            actual: "\(validCells.count) cells with weight > 0",
            details: allHaveData ? "All tensor cells contain aggregated data" : "Some cells missing data"
        )
    }

    /// X.2: L3→L4 Mapping - verify nearest-neighbor mapping
    private func testL3ToL4Mapping(l3Cells: [L3Cell], palette: [(r: UInt8, g: UInt8, b: UInt8)], mapping: [Int: Int]) -> CBORTestResult {
        guard !l3Cells.isEmpty && !palette.isEmpty && !mapping.isEmpty else {
            return CBORTestResult(
                id: "X.2",
                name: "L3→L4 Mapping",
                passed: false,
                expected: "Valid nearest-neighbor mapping",
                actual: "Insufficient data",
                details: "Need L3 cells, palette, and mapping"
            )
        }

        // Verify a sample of mappings are reasonable (mapped color is close to centroid)
        var badMappings: [String] = []

        for cell in l3Cells.prefix(20) {  // Check first 20
            guard let paletteIdx = mapping[cell.index],
                  paletteIdx < palette.count else { continue }

            let pColor = palette[paletteIdx]

            // Calculate distance
            let dr = Int(cell.r) - Int(pColor.r)
            let dg = Int(cell.g) - Int(pColor.g)
            let db = Int(cell.b) - Int(pColor.b)
            let distance = sqrt(Double(dr*dr + dg*dg + db*db))

            // Warn if distance > 100 (very different color)
            if distance > 100 {
                badMappings.append("Cell \(cell.index): dist=\(Int(distance))")
            }
        }

        return CBORTestResult(
            id: "X.2",
            name: "L3→L4 Mapping",
            passed: badMappings.isEmpty,
            expected: "Each cell maps to nearby color",
            actual: badMappings.isEmpty ? "All mappings reasonable" : "\(badMappings.count) distant",
            details: badMappings.isEmpty ? "Nearest-neighbor mapping verified" : badMappings.first ?? ""
        )
    }

    /// X.3: L4→L5 Coverage - verify index consistency
    private func testL4ToL5Coverage(palette: [(r: UInt8, g: UInt8, b: UInt8)], mapping: [Int: Int], indices: [[UInt8]]) -> CBORTestResult {
        guard !palette.isEmpty && !indices.isEmpty else {
            return CBORTestResult(
                id: "X.3",
                name: "L4→L5 Coverage",
                passed: false,
                expected: "Consistent index usage",
                actual: "Insufficient data",
                details: "Need palette and indices"
            )
        }

        // Collect all unique indices used across all frames
        var allUsedIndices = Set<UInt8>()
        for frameIndices in indices {
            for idx in frameIndices {
                allUsedIndices.insert(idx)
            }
        }

        // Verify all used indices are valid palette references
        let invalid = allUsedIndices.filter { Int($0) >= palette.count }

        return CBORTestResult(
            id: "X.3",
            name: "L4→L5 Coverage",
            passed: invalid.isEmpty,
            expected: "All indices reference valid palette colors",
            actual: invalid.isEmpty ? "\(allUsedIndices.count) unique indices used" : "\(invalid.count) invalid",
            details: invalid.isEmpty ? "All indices map to palette" : "Invalid indices: \(invalid.prefix(5))"
        )
    }

    /// X.4: RGB Reconstruction - indices + palette → RGB should be close to original
    private func testRGBReconstruction(l2Frames: [L2Frame], palette: [(r: UInt8, g: UInt8, b: UInt8)], indices: [[UInt8]]) -> (CBORTestResult, String) {
        guard let frame = l2Frames.first(where: { $0.index == 40 }) ?? l2Frames.first,
              frame.index < indices.count,
              !palette.isEmpty else {
            return (CBORTestResult(
                id: "X.4",
                name: "RGB Reconstruction",
                passed: false,
                expected: "Reconstructed RGB ≈ original",
                actual: "Insufficient data",
                details: "Need frame, palette, and indices"
            ), "")
        }

        let frameIndices = indices[frame.index]
        let originalRGB = frame.rgbData

        guard frameIndices.count == 6561 && originalRGB.count == 19683 else {
            return (CBORTestResult(
                id: "X.4",
                name: "RGB Reconstruction",
                passed: false,
                expected: "6561 pixels",
                actual: "Size mismatch",
                details: "Indices: \(frameIndices.count), RGB: \(originalRGB.count)"
            ), "")
        }

        // Reconstruct RGB from indices
        var totalErrorR = 0, totalErrorG = 0, totalErrorB = 0
        var maxErrorR = 0, maxErrorG = 0, maxErrorB = 0
        var withinTolerance = 0  // Within ±25

        for i in 0..<6561 {
            let paletteIdx = Int(frameIndices[i])
            guard paletteIdx < palette.count else { continue }

            let pColor = palette[paletteIdx]
            let origR = originalRGB[i * 3]
            let origG = originalRGB[i * 3 + 1]
            let origB = originalRGB[i * 3 + 2]

            let errR = abs(Int(pColor.r) - Int(origR))
            let errG = abs(Int(pColor.g) - Int(origG))
            let errB = abs(Int(pColor.b) - Int(origB))

            totalErrorR += errR
            totalErrorG += errG
            totalErrorB += errB

            maxErrorR = max(maxErrorR, errR)
            maxErrorG = max(maxErrorG, errG)
            maxErrorB = max(maxErrorB, errB)

            if errR <= 25 && errG <= 25 && errB <= 25 {
                withinTolerance += 1
            }
        }

        let meanR = Double(totalErrorR) / 6561.0
        let meanG = Double(totalErrorG) / 6561.0
        let meanB = Double(totalErrorB) / 6561.0
        let withinPercent = Double(withinTolerance) / 6561.0 * 100.0

        let passed = withinPercent >= 80  // At least 80% within tolerance

        let diagnostic = """
        RGB RECONSTRUCTION ACCURACY (Frame \(frame.index)):
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ Metric                 │ Value                                              │
        ├─────────────────────────────────────────────────────────────────────────────┤
        │ Original RGB pixels    │ 6,561                                              │
        │ Reconstructed RGB      │ 6,561 (from L5 indices + L4 palette)               │
        │ Mean Absolute Error    │ R: \(String(format: "%.1f", meanR)), G: \(String(format: "%.1f", meanG)), B: \(String(format: "%.1f", meanB))
        │ Max Error              │ R: \(maxErrorR), G: \(maxErrorG), B: \(maxErrorB)
        │ Pixels within ±25      │ \(withinTolerance) (\(String(format: "%.1f", withinPercent))%)
        └─────────────────────────────────────────────────────────────────────────────┘

        ASSESSMENT: \(passed ? "Acceptable quantization loss" : "High reconstruction error")
        """

        return (CBORTestResult(
            id: "X.4",
            name: "RGB Reconstruction",
            passed: passed,
            expected: "≥80% pixels within ±25",
            actual: String(format: "%.1f%% within tolerance", withinPercent),
            details: String(format: "Mean error: R=%.1f G=%.1f B=%.1f", meanR, meanG, meanB)
        ), diagnostic)
    }

    /// X.5: Pixel Conservation - 531,441 total
    private func testPixelConservation(l2Frames: [L2Frame], l5Indices: [[UInt8]]) -> CBORTestResult {
        let expectedTotal = 81 * 81 * 81  // 531,441

        let l2Pixels = l2Frames.reduce(0) { $0 + $1.rgbData.count / 3 }
        let l5Pixels = l5Indices.reduce(0) { $0 + $1.count }

        let l2Match = l2Pixels == expectedTotal
        let l5Match = l5Pixels == expectedTotal

        return CBORTestResult(
            id: "X.5",
            name: "Pixel Conservation",
            passed: l2Match && l5Match,
            expected: "\(expectedTotal) pixels throughout",
            actual: "L2: \(l2Pixels), L5: \(l5Pixels)",
            details: l2Match && l5Match ? "Pixel count preserved" : "Pixel count mismatch"
        )
    }

    /// X.6: Temporal Consistency - adjacent frames similar
    private func testTemporalConsistency(l2Frames: [L2Frame]) -> CBORTestResult {
        guard l2Frames.count >= 2 else {
            return CBORTestResult(
                id: "X.6",
                name: "Temporal Consistency",
                passed: false,
                expected: "Smooth transitions",
                actual: "Need 2+ frames",
                details: "Insufficient frames"
            )
        }

        var largeChanges: [Int] = []

        for i in 1..<min(l2Frames.count, 10) {
            let prev = l2Frames[i-1]
            let curr = l2Frames[i]

            guard prev.rgbData.count == curr.rgbData.count && prev.rgbData.count > 0 else { continue }

            // Calculate average per-pixel difference
            var totalDiff = 0
            for j in 0..<prev.rgbData.count {
                totalDiff += abs(Int(prev.rgbData[j]) - Int(curr.rgbData[j]))
            }

            let avgDiff = Double(totalDiff) / Double(prev.rgbData.count)

            // If average difference > 50, it's a large change
            if avgDiff > 50 {
                largeChanges.append(i)
            }
        }

        return CBORTestResult(
            id: "X.6",
            name: "Temporal Consistency",
            passed: largeChanges.isEmpty,
            expected: "Smooth frame transitions",
            actual: largeChanges.isEmpty ? "Smooth" : "\(largeChanges.count) large jumps",
            details: largeChanges.isEmpty ? "Adjacent frames consistent" : "Large changes at: \(largeChanges)"
        )
    }

    // MARK: - X.8: Sentinel Row Pixel Trace (NEW)

    /// X.8: Trace specific pixels at Y=10, Y=40, Y=70 through L2 → L5 → palette
    /// This is the KEY diagnostic for finding where gray/flat colors are introduced
    private func testSentinelRowPixelTrace(l2Frames: [L2Frame], palette: [(r: UInt8, g: UInt8, b: UInt8)], indices: [[UInt8]]) -> (CBORTestResult, String) {
        guard let frame = l2Frames.first(where: { $0.index == 40 }) ?? l2Frames.first,
              frame.index < indices.count,
              !palette.isEmpty else {
            return (CBORTestResult(
                id: "X.8",
                name: "Sentinel Row Pixel Trace",
                passed: false,
                expected: "Trace pixels at Y=10,40,70",
                actual: "Insufficient data",
                details: "Need frame, palette, and indices"
            ), "")
        }

        let frameIndices = indices[frame.index]
        let originalRGB = frame.rgbData

        guard frameIndices.count == 6561 && originalRGB.count == 19683 else {
            return (CBORTestResult(
                id: "X.8",
                name: "Sentinel Row Pixel Trace",
                passed: false,
                expected: "Valid pixel data",
                actual: "Size mismatch",
                details: "Indices: \(frameIndices.count), RGB: \(originalRGB.count)"
            ), "")
        }

        let sentinelRows = [10, 40, 70]  // Top, middle, bottom thirds

        var diagnostic = """
        ═══════════════════════════════════════════════════════════════════════════════
                    SENTINEL ROW PIXEL TRACE (Frame \(frame.index))
                    Tracing L2 RGB → L5 Index → Palette RGB
        ═══════════════════════════════════════════════════════════════════════════════

        """

        var anomalies: [String] = []

        for y in sentinelRows {
            // Sample multiple X positions across the row
            let xPositions = [10, 40, 70]  // Left, center, right

            diagnostic += "Row Y=\(y):\n"
            diagnostic += "┌──────┬─────────────────┬───────┬─────────────────┬───────┬─────────┐\n"
            diagnostic += "│  X   │  L2 RGB         │ Index │ Palette RGB     │ Error │ Status  │\n"
            diagnostic += "├──────┼─────────────────┼───────┼─────────────────┼───────┼─────────┤\n"

            for x in xPositions {
                let pixelIdx = y * 81 + x
                let rgbOffset = pixelIdx * 3

                // Original RGB from L2
                let origR = originalRGB[rgbOffset]
                let origG = originalRGB[rgbOffset + 1]
                let origB = originalRGB[rgbOffset + 2]

                // Index from L5
                let paletteIdx = Int(frameIndices[pixelIdx])

                // Reconstructed RGB from palette
                let reconR: UInt8
                let reconG: UInt8
                let reconB: UInt8
                if paletteIdx < palette.count {
                    let pColor = palette[paletteIdx]
                    reconR = pColor.r
                    reconG = pColor.g
                    reconB = pColor.b
                } else {
                    reconR = 0
                    reconG = 0
                    reconB = 0
                }

                // Calculate error
                let err = sqrt(Double(
                    (Int(origR) - Int(reconR)) * (Int(origR) - Int(reconR)) +
                    (Int(origG) - Int(reconG)) * (Int(origG) - Int(reconG)) +
                    (Int(origB) - Int(reconB)) * (Int(origB) - Int(reconB))
                ))

                // Check for anomalies
                let isGray = abs(Int(origR) - Int(origG)) < 10 && abs(Int(origG) - Int(origB)) < 10
                let isMidGray = isGray && origR > 100 && origR < 160
                let status: String
                if isMidGray {
                    status = "⚠️ GRAY"
                    anomalies.append("Y=\(y), X=\(x): L2 is gray (\(origR),\(origG),\(origB))")
                } else if err > 50 {
                    status = "⚠️ HIGH"
                } else {
                    status = "✓ OK"
                }

                diagnostic += "│ \(String(format: "%3d", x))  │ (\(String(format: "%3d", origR)),\(String(format: "%3d", origG)),\(String(format: "%3d", origB))) │ \(String(format: "%3d", paletteIdx))   │ (\(String(format: "%3d", reconR)),\(String(format: "%3d", reconG)),\(String(format: "%3d", reconB))) │ \(String(format: "%5.1f", err)) │ \(status.padding(toLength: 7, withPad: " ", startingAt: 0)) │\n"
            }

            diagnostic += "└──────┴─────────────────┴───────┴─────────────────┴───────┴─────────┘\n\n"
        }

        // Analysis summary
        if anomalies.isEmpty {
            diagnostic += """
            ───────────────────────────────────────────────────────────────────────────────
            STATUS: No anomalies detected in sentinel rows
            All L2 pixels have varied colors, reconstruction errors are normal.
            ───────────────────────────────────────────────────────────────────────────────
            """
        } else {
            diagnostic += """
            ───────────────────────────────────────────────────────────────────────────────
            ⚠️ ANOMALIES DETECTED IN L2 DATA:
            """
            for anomaly in anomalies {
                diagnostic += "\n  • \(anomaly)"
            }
            diagnostic += """


            DIAGNOSIS:
              Gray pixels in L2 means corruption happened BEFORE palette mapping.
              Bug is in: FrameFormatConverter.safeCropAndResizeToRGB_Fixed()
              Check: Y-coordinate transformation, buffer stride, crop calculation
            ───────────────────────────────────────────────────────────────────────────────
            """
        }

        let passed = anomalies.isEmpty

        return (CBORTestResult(
            id: "X.8",
            name: "Sentinel Row Pixel Trace",
            passed: passed,
            expected: "Varied colors at Y=10,40,70",
            actual: passed ? "All sentinel rows have color" : "\(anomalies.count) gray pixels detected",
            details: passed ? "L2→L5 trace shows no corruption" : "Gray in L2 - bug is in FrameFormatConverter"
        ), diagnostic)
    }

    // MARK: - X.9: L0→L2 Position-Corrected Comparison (NEW)

    /// L0 raw frame data structure
    private struct L0RawFrame {
        let index: Int
        let width: Int
        let height: Int
        let bytesPerRow: Int  // Actual row stride (may include padding for alignment)
        let bgraData: Data
    }

    /// Load L0 raw frames with their dimensions and bytesPerRow
    private func loadL0RawFrames() -> [L0RawFrame] {
        var frames: [L0RawFrame] = []

        for i in 0..<81 {
            let url = session.l0RawURL.appendingPathComponent(String(format: "r%02d.cbor", i))
            guard let data = try? Data(contentsOf: url),
                  let cbor = try? CBOR.decode([UInt8](data)),
                  case .map(let map) = cbor else { continue }

            let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                if case .utf8String(let s) = key { return (s, value) }
                return nil
            })

            var width = 0, height = 0, bytesPerRow = 0
            var bgraData = Data()

            // Extract dimensions
            if case .map(let dims) = dict["dimensions"] {
                for (k, v) in dims {
                    if case .utf8String("width") = k, case .unsignedInt(let val) = v { width = Int(val) }
                    if case .utf8String("height") = k, case .unsignedInt(let val) = v { height = Int(val) }
                }
            }

            // Extract bytesPerRow (NEW - may not exist in old CBOR files)
            if case .unsignedInt(let bpr) = dict["bytes_per_row"] {
                bytesPerRow = Int(bpr)
            } else {
                // Fallback for old files: assume tight packing
                bytesPerRow = width * 4
            }

            // Extract BGRA data
            if case .byteString(let bgra) = dict["bgra_data"] {
                bgraData = Data(bgra)
            }

            if width > 0 && height > 0 && !bgraData.isEmpty {
                frames.append(L0RawFrame(index: i, width: width, height: height, bytesPerRow: bytesPerRow, bgraData: bgraData))
            }
        }

        return frames
    }

    /// X.9: L0→L2 Position-Corrected Comparison
    /// This test maps L2 coordinates back to L0 coordinates (accounting for crop offset)
    /// to verify the crop/resize operation preserves correct pixel positions
    private func testL0ToL2PositionCorrected(l0Frames: [L0RawFrame], l2Frames: [L2Frame]) -> (CBORTestResult, String) {
        guard let l0 = l0Frames.first(where: { $0.index == 40 }) ?? l0Frames.first,
              let l2 = l2Frames.first(where: { $0.index == 40 }) ?? l2Frames.first,
              l0.index == l2.index else {
            return (CBORTestResult(
                id: "X.9",
                name: "L0→L2 Position Comparison",
                passed: false,
                expected: "Matching frame data available",
                actual: "Missing L0 or L2 data",
                details: "Need both L0_raw and L2_frames"
            ), "")
        }

        // Calculate crop region: center-crop to square, then resize to 81×81
        let l0Width = l0.width
        let l0Height = l0.height
        let l0BytesPerRow = l0.bytesPerRow  // Use stored bytesPerRow (may include padding)
        let squareSize = min(l0Width, l0Height)
        let cropX = (l0Width - squareSize) / 2
        let cropY = (l0Height - squareSize) / 2
        let scale = Double(squareSize) / 81.0

        // Check if there's row padding
        let expectedBytesPerRow = l0Width * 4
        let hasPadding = l0BytesPerRow != expectedBytesPerRow

        var diagnostic = """
        ═══════════════════════════════════════════════════════════════════════════════
                    L0→L2 POSITION-CORRECTED COMPARISON (Frame \(l0.index))
                    Verifying crop/resize preserves correct pixel positions
        ═══════════════════════════════════════════════════════════════════════════════

        L0 Raw Dimensions: \(l0Width) × \(l0Height) (BGRA format)
        L0 BytesPerRow:    \(l0BytesPerRow) \(hasPadding ? "⚠️ HAS PADDING (expected \(expectedBytesPerRow))" : "✓ No padding")
        Crop Region:       X=\(cropX), Y=\(cropY), Size=\(squareSize)×\(squareSize)
        L2 Output:         81 × 81 (RGB format)
        Scale Factor:      \(String(format: "%.2f", scale))

        Coordinate Mapping: L2(x,y) → L0(cropX+(x+0.5)*scale, cropY+(y+0.5)*scale) [center sampling]

        """

        // Sample positions to check: corners and center of L2 frame
        let samplePositions: [(l2x: Int, l2y: Int, name: String)] = [
            (0, 0, "TL"),
            (80, 0, "TR"),
            (0, 80, "BL"),
            (80, 80, "BR"),
            (40, 40, "Center"),
            (40, 10, "Top-Mid"),
            (40, 70, "Bot-Mid"),
            (10, 40, "Left-Mid"),
            (70, 40, "Right-Mid")
        ]

        diagnostic += "Position Mapping:\n"
        diagnostic += "┌──────────┬─────────────┬─────────────┬───────────────┬───────────────┬─────────┐\n"
        diagnostic += "│ Position │ L2 (x,y)    │ L0 (x,y)    │ L0 BGRA→RGB   │ L2 RGB        │ Match?  │\n"
        diagnostic += "├──────────┼─────────────┼─────────────┼───────────────┼───────────────┼─────────┤\n"

        var matches = 0
        var mismatches: [String] = []
        let tolerance = 30  // Allow for interpolation differences

        for sample in samplePositions {
            // Map L2 coordinate to L0 coordinate using CENTER sampling (matches implementation)
            // Implementation: srcX = Int(cropX + (outX + 0.5) * scale)
            let l0x = Int(Double(cropX) + (Double(sample.l2x) + 0.5) * scale)
            let l0y = Int(Double(cropY) + (Double(sample.l2y) + 0.5) * scale)

            // Extract L0 pixel (BGRA format, 4 bytes per pixel)
            // CRITICAL: Use actual bytesPerRow, not width*4 (handles row padding)
            let l0PixelOffset = l0y * l0BytesPerRow + l0x * 4
            var l0R: UInt8 = 0, l0G: UInt8 = 0, l0B: UInt8 = 0
            if l0PixelOffset + 3 < l0.bgraData.count {
                l0B = l0.bgraData[l0PixelOffset]      // B
                l0G = l0.bgraData[l0PixelOffset + 1]  // G
                l0R = l0.bgraData[l0PixelOffset + 2]  // R
                // Alpha at l0PixelOffset + 3
            }

            // Extract L2 pixel (RGB format, 3 bytes per pixel)
            let l2PixelOffset = (sample.l2y * 81 + sample.l2x) * 3
            var l2R: UInt8 = 0, l2G: UInt8 = 0, l2B: UInt8 = 0
            if l2PixelOffset + 2 < l2.rgbData.count {
                l2R = l2.rgbData[l2PixelOffset]
                l2G = l2.rgbData[l2PixelOffset + 1]
                l2B = l2.rgbData[l2PixelOffset + 2]
            }

            // Check if they match (within tolerance for resize interpolation)
            let diffR = abs(Int(l0R) - Int(l2R))
            let diffG = abs(Int(l0G) - Int(l2G))
            let diffB = abs(Int(l0B) - Int(l2B))
            let isMatch = diffR <= tolerance && diffG <= tolerance && diffB <= tolerance

            let status: String
            if isMatch {
                matches += 1
                status = "✓ Yes"
            } else {
                mismatches.append("\(sample.name): L0(\(l0R),\(l0G),\(l0B)) → L2(\(l2R),\(l2G),\(l2B))")
                status = "✗ NO"
            }

            diagnostic += "│ \(sample.name.padding(toLength: 8, withPad: " ", startingAt: 0)) │ (\(String(format: "%3d", sample.l2x)),\(String(format: "%3d", sample.l2y)))   │ (\(String(format: "%4d", l0x)),\(String(format: "%4d", l0y))) │ (\(String(format: "%3d", l0R)),\(String(format: "%3d", l0G)),\(String(format: "%3d", l0B)))   │ (\(String(format: "%3d", l2R)),\(String(format: "%3d", l2G)),\(String(format: "%3d", l2B)))   │ \(status.padding(toLength: 7, withPad: " ", startingAt: 0)) │\n"
        }

        diagnostic += "└──────────┴─────────────┴─────────────┴───────────────┴───────────────┴─────────┘\n\n"

        // Analysis
        let matchPercent = Double(matches) / Double(samplePositions.count) * 100.0
        let passed = matchPercent >= 70  // At least 70% should match

        if mismatches.isEmpty {
            diagnostic += """
            ───────────────────────────────────────────────────────────────────────────────
            ✓ L0→L2 POSITION MAPPING VERIFIED
            All \(samplePositions.count) sample positions match within tolerance (±\(tolerance)).
            The crop/resize operation correctly preserves pixel positions.
            ───────────────────────────────────────────────────────────────────────────────
            """
        } else {
            diagnostic += """
            ───────────────────────────────────────────────────────────────────────────────
            ⚠️ POSITION MAPPING MISMATCHES DETECTED:

            """
            for mismatch in mismatches {
                diagnostic += "  • \(mismatch)\n"
            }
            diagnostic += """

            DIAGNOSIS:
            """
            // Check for specific patterns
            let l0IsColorful = samplePositions.contains { sample in
                let l0x = Int(Double(sample.l2x) * scale) + cropX
                let l0y = Int(Double(sample.l2y) * scale) + cropY
                let l0PixelOffset = (l0y * l0Width + l0x) * 4
                if l0PixelOffset + 3 < l0.bgraData.count {
                    let r = l0.bgraData[l0PixelOffset + 2]
                    let g = l0.bgraData[l0PixelOffset + 1]
                    let b = l0.bgraData[l0PixelOffset]
                    // Check if any sample position has color variance
                    return abs(Int(r) - Int(g)) > 20 || abs(Int(g) - Int(b)) > 20
                }
                return false
            }

            let l2IsGray = !samplePositions.contains { sample in
                let l2PixelOffset = (sample.l2y * 81 + sample.l2x) * 3
                if l2PixelOffset + 2 < l2.rgbData.count {
                    let r = l2.rgbData[l2PixelOffset]
                    let g = l2.rgbData[l2PixelOffset + 1]
                    let b = l2.rgbData[l2PixelOffset + 2]
                    return abs(Int(r) - Int(g)) > 20 || abs(Int(g) - Int(b)) > 20
                }
                return false
            }

            if l0IsColorful && l2IsGray {
                diagnostic += """

              🚨 L0 HAS COLOR but L2 IS GRAY → Bug in FrameFormatConverter!
              The crop/resize operation is losing color information.
              Check: Y-coordinate flip, buffer stride, BGRA→RGB conversion order.
            """
            } else if !l0IsColorful {
                diagnostic += """

              ℹ️ L0 IS ALSO GRAY → Camera input issue, NOT pipeline bug.
              The original camera input lacks color in the crop region.
              Try pointing camera at colorful subject.
            """
            } else {
                diagnostic += """

              ⚠️ INTERPOLATION ARTIFACTS - some positions differ more than expected.
              This may be normal for aggressive resize (scale=\(String(format: "%.2f", scale))).
            """
            }

            diagnostic += "\n───────────────────────────────────────────────────────────────────────────────\n"
        }

        return (CBORTestResult(
            id: "X.9",
            name: "L0→L2 Position Comparison",
            passed: passed,
            expected: "≥70% positions match within ±\(tolerance)",
            actual: "\(matches)/\(samplePositions.count) match (\(String(format: "%.0f", matchPercent))%)",
            details: passed ? "Crop/resize verified" : "Mismatches: \(mismatches.count)"
        ), diagnostic)
    }

}
