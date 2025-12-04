//
//  L2FrameTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L2_FRAMES TESTS - RGB 81×81 Frame Validation                            ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Validates resized RGB frames after BGRA→RGB conversion:                 ║
//  ║  • L2.1  Frame Count (exactly 81)                                        ║
//  ║  • L2.2  File Naming (f00.cbor - f80.cbor)                               ║
//  ║  • L2.3  Dimensions (81×81)                                              ║
//  ║  • L2.4  Format Field ("RGB8")                                           ║
//  ║  • L2.5  Data Size (19,683 bytes = 81×81×3)                              ║
//  ║  • L2.6  Tensor Layer (0-8 = frameIndex / 9)                             ║
//  ║  • L2.7  Tensor Offset (0-8 = frameIndex % 9)                            ║
//  ║  • L2.8  RGB Range (all values 0-255)                                    ║
//  ║  • L2.9  Not All Same (pixel variance check)                             ║
//  ║  • L2.10 First Row Analysis (Y-flip detection)                           ║
//  ║  • L2.11 Last Row Analysis (Y-flip detection)                            ║
//  ║  • L2.12 Corner Pixels (orientation check)                               ║
//  ║                                                                           ║
//  ║  CRITICAL: Detects Y-axis flip bugs that cause GIF corruption!           ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let testLogger = Logger(subsystem: "com.rgb2gif.tests", category: "L2Frames")

@available(iOS 26.0, *)
public struct L2FrameTests {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    public func run() async -> StageTestResults {
        var results = StageTestResults(stageName: "L2_FRAMES")

        testLogger.info("Starting L2_FRAMES tests for session: \(session.sessionID)")

        // Collect all CBOR files
        let fm = FileManager.default
        let l2URL = session.l2FramesURL
        var cborFiles: [URL] = []

        do {
            let contents = try fm.contentsOfDirectory(at: l2URL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            cborFiles = contents.filter { $0.pathExtension == "cbor" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            results.tests.append(CBORTestResult(
                id: "L2.0",
                name: "Directory Access",
                passed: false,
                expected: "L2_frames directory exists",
                actual: "Error: \(error.localizedDescription)",
                details: "Cannot access L2_frames directory at \(l2URL.path)"
            ))
            return results
        }

        // Parse all CBOR files
        var parsedFrames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)] = []
        var parseErrors: [String] = []

        for url in cborFiles {
            do {
                let data = try Data(contentsOf: url)
                if let cbor = try CBOR.decode([UInt8](data)),
                   case .map(let map) = cbor {
                    let stringMap = Dictionary(uniqueKeysWithValues: map.map { (key, value) -> (String, CBOR) in
                        if case .utf8String(let s) = key { return (s, value) }
                        return ("unknown", value)
                    })

                    var idx = -1
                    var rgbData: [UInt8] = []

                    if case .unsignedInt(let i) = stringMap["index"] {
                        idx = Int(i)
                    }
                    if case .byteString(let d) = stringMap["rgb_data"] {
                        rgbData = d
                    }

                    if idx >= 0 {
                        parsedFrames.append((idx, stringMap, rgbData, url))
                    }
                }
            } catch {
                parseErrors.append("Failed to parse \(url.lastPathComponent): \(error)")
            }
        }

        // Sort by index
        parsedFrames.sort { $0.index < $1.index }

        // L2.1: Frame Count
        results.tests.append(testFrameCount(cborFiles.count))

        // L2.2: File Naming
        results.tests.append(testFileNaming(cborFiles))

        // L2.3: Dimensions
        results.tests.append(testDimensions(parsedFrames))

        // L2.4: Format Field
        results.tests.append(testFormatField(parsedFrames))

        // L2.5: Data Size
        results.tests.append(testDataSize(parsedFrames))

        // L2.6: Tensor Layer
        results.tests.append(testTensorLayer(parsedFrames))

        // L2.7: Tensor Offset
        results.tests.append(testTensorOffset(parsedFrames))

        // L2.8: RGB Range
        results.tests.append(testRGBRange(parsedFrames))

        // L2.9: Not All Same
        results.tests.append(testNotAllSame(parsedFrames))

        // L2.10: First Row Analysis
        results.tests.append(testFirstRow(parsedFrames))

        // L2.11: Last Row Analysis
        results.tests.append(testLastRow(parsedFrames))

        // L2.12: Corner Pixels
        results.tests.append(testCornerPixels(parsedFrames))

        // Add detailed diagnostics
        if let first = parsedFrames.first {
            results.diagnostics.append(generateCornerAnalysis(first.rgbData, frameIndex: first.index))
            results.diagnostics.append(generateRowAnalysis(first.rgbData, frameIndex: first.index))
        }

        // Y-Flip diagnosis
        if let first = parsedFrames.first {
            results.diagnostics.append(diagnoseYFlip(first.rgbData))
        }

        // NEW: Quadrant color distribution analysis (shows WHERE colors exist)
        if let middle = parsedFrames.first(where: { $0.index == 40 }) ?? parsedFrames.first {
            results.diagnostics.append(generateQuadrantAnalysis(middle.rgbData, frameIndex: middle.index))
        }

        // NEW: Corruption pattern detection (replaces misleading FLAT detection)
        if let middle = parsedFrames.first(where: { $0.index == 40 }) ?? parsedFrames.first {
            results.diagnostics.append(detectCorruptionPatterns(middle.rgbData, frameIndex: middle.index))
        }

        // Multi-frame sentinel row diagnostics (traces Y=10, 40, 70 across frames 0, 40, 80)
        results.diagnostics.append(generateMultiFrameDiagnostics(parsedFrames))

        testLogger.info("L2_FRAMES tests complete: \(results.passCount)/\(results.totalCount) passed")

        return results
    }

    // MARK: - Individual Tests

    /// L2.1: Frame Count
    private func testFrameCount(_ count: Int) -> CBORTestResult {
        CBORTestResult(
            id: "L2.1",
            name: "Frame Count",
            passed: count == 81,
            expected: "81",
            actual: "\(count)",
            details: count == 81 ? "All 81 RGB frames present" : "Missing \(81 - count) frame(s)"
        )
    }

    /// L2.2: File Naming - f00.cbor through f80.cbor
    private func testFileNaming(_ files: [URL]) -> CBORTestResult {
        var missing: [String] = []
        for i in 0..<81 {
            let expected = String(format: "f%02d.cbor", i)
            if !files.contains(where: { $0.lastPathComponent == expected }) {
                missing.append(expected)
            }
        }

        return CBORTestResult(
            id: "L2.2",
            name: "File Naming",
            passed: missing.isEmpty,
            expected: "f00.cbor - f80.cbor",
            actual: missing.isEmpty ? "All present" : "Missing: \(missing.prefix(5).joined(separator: ", "))",
            details: missing.isEmpty ? "All 81 files named correctly" : "\(missing.count) files missing"
        )
    }

    /// L2.3: Dimensions - all frames 81×81
    private func testDimensions(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        var nonSquare: [String] = []

        for frame in frames {
            if case .map(let dims) = frame.cbor["dimensions"] {
                var w = 0, h = 0
                for (key, value) in dims {
                    if case .utf8String("width") = key, case .unsignedInt(let v) = value { w = Int(v) }
                    if case .utf8String("height") = key, case .unsignedInt(let v) = value { h = Int(v) }
                }
                if w != 81 || h != 81 {
                    nonSquare.append("Frame \(frame.index): \(w)×\(h)")
                }
            }
        }

        return CBORTestResult(
            id: "L2.3",
            name: "Dimensions",
            passed: nonSquare.isEmpty,
            expected: "81×81",
            actual: nonSquare.isEmpty ? "All 81×81" : "\(nonSquare.count) non-standard",
            details: nonSquare.isEmpty ? "All frames exactly 81×81" : nonSquare.prefix(3).joined(separator: "; ")
        )
    }

    /// L2.4: Format Field - all "RGB8"
    private func testFormatField(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        var nonRGB: [Int] = []

        for frame in frames {
            if case .utf8String(let format) = frame.cbor["format"] {
                if format != "RGB8" {
                    nonRGB.append(frame.index)
                }
            } else {
                nonRGB.append(frame.index)
            }
        }

        return CBORTestResult(
            id: "L2.4",
            name: "Format Field",
            passed: nonRGB.isEmpty,
            expected: "All 'RGB8'",
            actual: nonRGB.isEmpty ? "All RGB8" : "\(nonRGB.count) non-RGB8",
            details: nonRGB.isEmpty ? "All frames marked as RGB8" : "Non-RGB8 at: \(nonRGB.prefix(5))"
        )
    }

    /// L2.5: Data Size - 19,683 bytes (81×81×3)
    private func testDataSize(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        let expected = 81 * 81 * 3  // 19,683
        var wrong: [String] = []

        for frame in frames {
            if frame.rgbData.count != expected {
                wrong.append("Frame \(frame.index): \(frame.rgbData.count)")
            }
        }

        return CBORTestResult(
            id: "L2.5",
            name: "Data Size",
            passed: wrong.isEmpty,
            expected: "\(expected) bytes",
            actual: wrong.isEmpty ? "All correct" : "\(wrong.count) wrong size(s)",
            details: wrong.isEmpty ? "All frames have correct RGB data size" : wrong.prefix(3).joined(separator: "; ")
        )
    }

    /// L2.6: Tensor Layer - frameIndex / 9
    private func testTensorLayer(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        var wrong: [String] = []

        for frame in frames {
            let expected = frame.index / 9
            if case .unsignedInt(let layer) = frame.cbor["tensor_layer"] {
                if Int(layer) != expected {
                    wrong.append("Frame \(frame.index): layer=\(layer), expected=\(expected)")
                }
            } else {
                wrong.append("Frame \(frame.index): missing tensor_layer")
            }
        }

        return CBORTestResult(
            id: "L2.6",
            name: "Tensor Layer",
            passed: wrong.isEmpty,
            expected: "frameIndex / 9 (0-8)",
            actual: wrong.isEmpty ? "All correct" : "\(wrong.count) wrong",
            details: wrong.isEmpty ? "All tensor layers correct" : wrong.prefix(3).joined(separator: "; ")
        )
    }

    /// L2.7: Tensor Offset - frameIndex % 9
    private func testTensorOffset(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        var wrong: [String] = []

        for frame in frames {
            let expected = frame.index % 9
            if case .unsignedInt(let offset) = frame.cbor["tensor_offset"] {
                if Int(offset) != expected {
                    wrong.append("Frame \(frame.index): offset=\(offset), expected=\(expected)")
                }
            } else {
                wrong.append("Frame \(frame.index): missing tensor_offset")
            }
        }

        return CBORTestResult(
            id: "L2.7",
            name: "Tensor Offset",
            passed: wrong.isEmpty,
            expected: "frameIndex % 9 (0-8)",
            actual: wrong.isEmpty ? "All correct" : "\(wrong.count) wrong",
            details: wrong.isEmpty ? "All tensor offsets correct" : wrong.prefix(3).joined(separator: "; ")
        )
    }

    /// L2.8: RGB Range - all values 0-255 (automatic for UInt8, but check for truncation)
    private func testRGBRange(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        // All UInt8 values are automatically in range, but check for suspicious patterns
        var suspicious: [String] = []

        for frame in frames.prefix(10) {  // Check first 10 frames
            let data = frame.rgbData
            let zeros = data.filter { $0 == 0 }.count
            let max255 = data.filter { $0 == 255 }.count

            // If more than 90% are 0 or 255, something might be wrong
            if zeros > data.count * 9 / 10 {
                suspicious.append("Frame \(frame.index): \(zeros * 100 / data.count)% zeros")
            }
            if max255 > data.count * 9 / 10 {
                suspicious.append("Frame \(frame.index): \(max255 * 100 / data.count)% saturated (255)")
            }
        }

        return CBORTestResult(
            id: "L2.8",
            name: "RGB Range",
            passed: suspicious.isEmpty,
            expected: "Values 0-255, varied",
            actual: suspicious.isEmpty ? "Normal range" : "Suspicious: \(suspicious.count)",
            details: suspicious.isEmpty ? "RGB values look reasonable" : suspicious.prefix(3).joined(separator: "; ")
        )
    }

    /// L2.9: Not All Same - frames have pixel variance
    private func testNotAllSame(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        var allSame: [Int] = []

        for frame in frames {
            if frame.rgbData.count >= 6 {
                let firstPixel = (frame.rgbData[0], frame.rgbData[1], frame.rgbData[2])
                var allMatch = true

                for i in stride(from: 0, to: min(frame.rgbData.count, 300), by: 3) {
                    if frame.rgbData[i] != firstPixel.0 ||
                       frame.rgbData[i+1] != firstPixel.1 ||
                       frame.rgbData[i+2] != firstPixel.2 {
                        allMatch = false
                        break
                    }
                }

                if allMatch {
                    allSame.append(frame.index)
                }
            }
        }

        return CBORTestResult(
            id: "L2.9",
            name: "Not All Same",
            passed: allSame.isEmpty,
            expected: "Pixel variance > 0",
            actual: allSame.isEmpty ? "All have variance" : "\(allSame.count) solid color(s)",
            details: allSame.isEmpty ? "All frames have pixel variation" : "Solid frames: \(allSame.prefix(5))"
        )
    }

    /// L2.10: First Row Analysis - for Y-flip detection
    private func testFirstRow(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        guard let first = frames.first, first.rgbData.count >= 81 * 3 else {
            return CBORTestResult(
                id: "L2.10",
                name: "First Row Analysis",
                passed: false,
                expected: "Row 0 pixels readable",
                actual: "No data",
                details: "Cannot analyze first row"
            )
        }

        // Calculate average color of first row (top of image)
        let row = first.rgbData.prefix(81 * 3)
        var sumR = 0, sumG = 0, sumB = 0
        for i in stride(from: 0, to: row.count, by: 3) {
            sumR += Int(row[i])
            sumG += Int(row[i+1])
            sumB += Int(row[i+2])
        }

        let avgR = sumR / 81
        let avgG = sumG / 81
        let avgB = sumB / 81

        // First 3 pixels
        let p0 = "(\(row[0]),\(row[1]),\(row[2]))"
        let p1 = "(\(row[3]),\(row[4]),\(row[5]))"
        let p2 = "(\(row[6]),\(row[7]),\(row[8]))"

        return CBORTestResult(
            id: "L2.10",
            name: "First Row Analysis",
            passed: true,  // Informational test
            expected: "Row 0 data for Y-flip check",
            actual: "Avg RGB(\(avgR),\(avgG),\(avgB))",
            details: "First 3 pixels: \(p0) \(p1) \(p2)"
        )
    }

    /// L2.11: Last Row Analysis - for Y-flip detection
    private func testLastRow(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        guard let first = frames.first, first.rgbData.count >= 81 * 81 * 3 else {
            return CBORTestResult(
                id: "L2.11",
                name: "Last Row Analysis",
                passed: false,
                expected: "Row 80 pixels readable",
                actual: "No data",
                details: "Cannot analyze last row"
            )
        }

        // Calculate average color of last row (bottom of image)
        let startOffset = 80 * 81 * 3
        let row = first.rgbData[startOffset..<first.rgbData.count]
        var sumR = 0, sumG = 0, sumB = 0
        for i in stride(from: 0, to: 81 * 3, by: 3) {
            sumR += Int(row[row.startIndex + i])
            sumG += Int(row[row.startIndex + i + 1])
            sumB += Int(row[row.startIndex + i + 2])
        }

        let avgR = sumR / 81
        let avgG = sumG / 81
        let avgB = sumB / 81

        // First 3 pixels of last row
        let p0 = "(\(row[row.startIndex]),\(row[row.startIndex+1]),\(row[row.startIndex+2]))"
        let p1 = "(\(row[row.startIndex+3]),\(row[row.startIndex+4]),\(row[row.startIndex+5]))"
        let p2 = "(\(row[row.startIndex+6]),\(row[row.startIndex+7]),\(row[row.startIndex+8]))"

        return CBORTestResult(
            id: "L2.11",
            name: "Last Row Analysis",
            passed: true,  // Informational test
            expected: "Row 80 data for Y-flip check",
            actual: "Avg RGB(\(avgR),\(avgG),\(avgB))",
            details: "Last row pixels: \(p0) \(p1) \(p2)"
        )
    }

    /// L2.12: Corner Pixels - all 4 corners for orientation
    private func testCornerPixels(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> CBORTestResult {
        guard let first = frames.first, first.rgbData.count >= 81 * 81 * 3 else {
            return CBORTestResult(
                id: "L2.12",
                name: "Corner Pixels",
                passed: false,
                expected: "4 corner pixels readable",
                actual: "No data",
                details: "Cannot read corners"
            )
        }

        let data = first.rgbData
        let width = 81

        // Top-left (0,0)
        let tl = CBORPixelSample(rgbData: Data(data), x: 0, y: 0, width: width)

        // Top-right (80,0)
        let tr = CBORPixelSample(rgbData: Data(data), x: 80, y: 0, width: width)

        // Bottom-left (0,80)
        let bl = CBORPixelSample(rgbData: Data(data), x: 0, y: 80, width: width)

        // Bottom-right (80,80)
        let br = CBORPixelSample(rgbData: Data(data), x: 80, y: 80, width: width)

        let cornerInfo = "TL:\(tl.colorName) TR:\(tr.colorName) BL:\(bl.colorName) BR:\(br.colorName)"

        return CBORTestResult(
            id: "L2.12",
            name: "Corner Pixels",
            passed: true,  // Informational test
            expected: "4 corners for orientation",
            actual: cornerInfo,
            details: "TL=\(tl) TR=\(tr) BL=\(bl) BR=\(br)"
        )
    }

    // MARK: - Diagnostic Helpers

    private func generateCornerAnalysis(_ rgbData: [UInt8], frameIndex: Int) -> String {
        guard rgbData.count >= 81 * 81 * 3 else { return "Insufficient data for corner analysis" }

        let data = Data(rgbData)
        let width = 81

        let tl = CBORPixelSample(rgbData: data, x: 0, y: 0, width: width)
        let tr = CBORPixelSample(rgbData: data, x: 80, y: 0, width: width)
        let bl = CBORPixelSample(rgbData: data, x: 0, y: 80, width: width)
        let br = CBORPixelSample(rgbData: data, x: 80, y: 80, width: width)

        return """
        CORNER PIXEL ANALYSIS (Frame \(frameIndex)):
        ┌────────────────────────────────────────────────────────────────────────────┐
        │  Position    │ Offset   │ R   │ G   │ B   │ Color                          │
        ├────────────────────────────────────────────────────────────────────────────┤
        │  (0,0) TL    │ 0        │ \(String(format: "%3d", tl.r)) │ \(String(format: "%3d", tl.g)) │ \(String(format: "%3d", tl.b)) │ \(tl.colorName.padding(toLength: 30, withPad: " ", startingAt: 0))│
        │  (80,0) TR   │ 240      │ \(String(format: "%3d", tr.r)) │ \(String(format: "%3d", tr.g)) │ \(String(format: "%3d", tr.b)) │ \(tr.colorName.padding(toLength: 30, withPad: " ", startingAt: 0))│
        │  (0,80) BL   │ 19440    │ \(String(format: "%3d", bl.r)) │ \(String(format: "%3d", bl.g)) │ \(String(format: "%3d", bl.b)) │ \(bl.colorName.padding(toLength: 30, withPad: " ", startingAt: 0))│
        │  (80,80) BR  │ 19680    │ \(String(format: "%3d", br.r)) │ \(String(format: "%3d", br.g)) │ \(String(format: "%3d", br.b)) │ \(br.colorName.padding(toLength: 30, withPad: " ", startingAt: 0))│
        └────────────────────────────────────────────────────────────────────────────┘
        """
    }

    private func generateRowAnalysis(_ rgbData: [UInt8], frameIndex: Int) -> String {
        guard rgbData.count >= 81 * 81 * 3 else { return "Insufficient data for row analysis" }

        // Calculate average RGB for first and last rows
        func rowAverage(startRow: Int) -> (r: Int, g: Int, b: Int) {
            let offset = startRow * 81 * 3
            var sumR = 0, sumG = 0, sumB = 0
            for x in 0..<81 {
                let i = offset + x * 3
                sumR += Int(rgbData[i])
                sumG += Int(rgbData[i + 1])
                sumB += Int(rgbData[i + 2])
            }
            return (sumR / 81, sumG / 81, sumB / 81)
        }

        let row0 = rowAverage(startRow: 0)
        let row80 = rowAverage(startRow: 80)

        return """
        ROW ANALYSIS (Frame \(frameIndex)):
          Row 0 (top):     avg RGB = (\(row0.r), \(row0.g), \(row0.b))
          Row 80 (bottom): avg RGB = (\(row80.r), \(row80.g), \(row80.b))
        """
    }

    private func diagnoseYFlip(_ rgbData: [UInt8]) -> String {
        guard rgbData.count >= 81 * 81 * 3 else {
            return "Y-FLIP DIAGNOSIS: Insufficient data"
        }

        // Compare top and bottom row brightness
        func rowBrightness(startRow: Int) -> Double {
            let offset = startRow * 81 * 3
            var sum = 0
            for x in 0..<81 {
                let i = offset + x * 3
                sum += Int(rgbData[i]) + Int(rgbData[i + 1]) + Int(rgbData[i + 2])
            }
            return Double(sum) / Double(81 * 3)
        }

        let topBrightness = rowBrightness(startRow: 0)
        let bottomBrightness = rowBrightness(startRow: 80)

        // In typical camera scenes:
        // - Sky/ceiling (top) tends to be brighter
        // - Floor/ground (bottom) tends to be darker
        // If reversed, Y-axis might be flipped

        let diff = topBrightness - bottomBrightness

        var diagnosis: String
        if abs(diff) < 20 {
            diagnosis = "INCONCLUSIVE - Top and bottom similar brightness"
        } else if diff > 0 {
            diagnosis = "LIKELY CORRECT - Top brighter than bottom (typical scene)"
        } else {
            diagnosis = "POSSIBLE Y-FLIP - Bottom brighter than top (unusual)"
        }

        return """
        Y-FLIP DIAGNOSIS:
          Top row brightness:    \(String(format: "%.1f", topBrightness))
          Bottom row brightness: \(String(format: "%.1f", bottomBrightness))
          Difference:            \(String(format: "%.1f", diff))
          Assessment: \(diagnosis)
        """
    }

    // MARK: - Sentinel Row Diagnostics (NEW)

    /// Generate detailed row-by-row diagnostics at Y=10, Y=40, Y=70
    /// This traces pixel values to find where gray/flat colors appear
    public func generateSentinelRowDiagnostics(_ rgbData: [UInt8], frameIndex: Int) -> String {
        guard rgbData.count >= 81 * 81 * 3 else {
            return "SENTINEL ROW DIAGNOSTICS: Insufficient data (\(rgbData.count) bytes)"
        }

        let sentinelRows = [10, 40, 70]  // Top, middle, bottom thirds
        var output = """
        ═══════════════════════════════════════════════════════════════════════════════
                         SENTINEL ROW DIAGNOSTICS (Frame \(frameIndex))
        ═══════════════════════════════════════════════════════════════════════════════

        """

        for y in sentinelRows {
            let rowStats = analyzeRow(rgbData, y: y)

            // Determine status - INFORMATIONAL only, not alarming
            // Low variance in a single row is NOT necessarily a bug!
            let saturation = calculateSaturation(r: rowStats.avgR, g: rowStats.avgG, b: rowStats.avgB)

            let status: String
            if saturation < 10 {
                status = "ℹ️ Gray/neutral"  // Could be valid ceiling/wall
            } else if saturation < 30 {
                status = "ℹ️ Muted colors"
            } else {
                status = "✓ Colorful"
            }

            output += """
            Row Y=\(String(format: "%2d", y)):
              Average RGB: (\(String(format: "%3d", rowStats.avgR)), \(String(format: "%3d", rowStats.avgG)), \(String(format: "%3d", rowStats.avgB)))
              Variance:    \(String(format: "%.4f", rowStats.variance)) | Saturation: \(String(format: "%3d", saturation))% \(status)
              First 5 px:  \(rowStats.firstPixels)
              Last 5 px:   \(rowStats.lastPixels)

            """
        }

        // Summary - informational, not alarming about low variance
        output += """
        ───────────────────────────────────────────────────────────────────────────────
        NOTE: Gray/low saturation rows may be VALID scene content (ceilings, walls).
              See QUADRANT ANALYSIS for spatial color distribution.
              See CORRUPTION PATTERN DETECTION for actual buffer/stride bugs.
              Compare L0_raw PNGs to L2_frames to verify if gray is in original.
        ───────────────────────────────────────────────────────────────────────────────
        """

        return output
    }

    /// Analyze a single row and return statistics
    private func analyzeRow(_ rgbData: [UInt8], y: Int) -> RowStatistics {
        let width = 81
        let rowOffset = y * width * 3

        var sumR = 0, sumG = 0, sumB = 0
        var pixels: [(r: UInt8, g: UInt8, b: UInt8)] = []

        // Collect all pixels in row
        for x in 0..<width {
            let offset = rowOffset + x * 3
            let r = rgbData[offset]
            let g = rgbData[offset + 1]
            let b = rgbData[offset + 2]
            pixels.append((r, g, b))
            sumR += Int(r)
            sumG += Int(g)
            sumB += Int(b)
        }

        let avgR = sumR / width
        let avgG = sumG / width
        let avgB = sumB / width

        // Calculate variance (normalized 0-1)
        var varianceSum: Double = 0
        for px in pixels {
            let dr = Double(Int(px.r) - avgR)
            let dg = Double(Int(px.g) - avgG)
            let db = Double(Int(px.b) - avgB)
            varianceSum += (dr * dr + dg * dg + db * db)
        }
        let variance = varianceSum / Double(width) / (255.0 * 255.0 * 3.0)  // Normalize to 0-1

        // Format first 5 and last 5 pixels
        let first5 = pixels.prefix(5).map { "(\($0.r),\($0.g),\($0.b))" }.joined(separator: " ")
        let last5 = pixels.suffix(5).map { "(\($0.r),\($0.g),\($0.b))" }.joined(separator: " ")

        return RowStatistics(
            avgR: avgR,
            avgG: avgG,
            avgB: avgB,
            variance: variance,
            firstPixels: first5,
            lastPixels: last5
        )
    }

    /// Statistics for a single row
    private struct RowStatistics {
        let avgR: Int
        let avgG: Int
        let avgB: Int
        let variance: Double
        let firstPixels: String
        let lastPixels: String
    }

    /// Calculate saturation percentage (0-100) from RGB values
    /// Saturation = (max - min) / max * 100
    private func calculateSaturation(r: Int, g: Int, b: Int) -> Int {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))

        guard maxVal > 0 else { return 0 }

        let saturation = Double(maxVal - minVal) / Double(maxVal) * 100.0
        return Int(saturation)
    }

    // MARK: - Quadrant Color Distribution Analysis (NEW)

    /// Analyze color distribution by quadrant to find WHERE colors exist
    public func generateQuadrantAnalysis(_ rgbData: [UInt8], frameIndex: Int) -> String {
        guard rgbData.count >= 81 * 81 * 3 else {
            return "QUADRANT ANALYSIS: Insufficient data"
        }

        // Analyze each quadrant
        let tl = analyzeQuadrant(rgbData, name: "TL", xRange: 0..<41, yRange: 0..<41)
        let tr = analyzeQuadrant(rgbData, name: "TR", xRange: 41..<81, yRange: 0..<41)
        let bl = analyzeQuadrant(rgbData, name: "BL", xRange: 0..<41, yRange: 41..<81)
        let br = analyzeQuadrant(rgbData, name: "BR", xRange: 41..<81, yRange: 41..<81)

        let quadrants = [tl, tr, bl, br]

        // Find which quadrant has the most color (highest variance)
        let sorted = quadrants.sorted { $0.variance > $1.variance }
        let mostColorful = sorted.first!

        // Calculate percentage of frame that is "colorful" (variance > 0.02)
        let colorfulQuadrants = quadrants.filter { $0.variance > 0.02 }
        let colorfulPercent = colorfulQuadrants.count * 25  // Each quadrant is 25%

        var output = """
        ═══════════════════════════════════════════════════════════════════════════════
                            COLOR DISTRIBUTION ANALYSIS (Frame \(frameIndex))
        ═══════════════════════════════════════════════════════════════════════════════

        Quadrant Analysis:
        ┌──────────┬─────────────────────┬──────────┬─────────────────────────────────────┐
        │ Quadrant │ Avg RGB             │ Variance │ Assessment                          │
        ├──────────┼─────────────────────┼──────────┼─────────────────────────────────────┤
        """

        for q in quadrants {
            let assessment = q.variance > 0.02 ? "✓ COLORFUL - varied colors" : q.variance > 0.005 ? "Low saturation (muted)" : "Very low variance (gray/dark)"
            output += """

            │ \(q.name.padding(toLength: 8, withPad: " ", startingAt: 0)) │ (\(String(format: "%3d", q.avgR)), \(String(format: "%3d", q.avgG)), \(String(format: "%3d", q.avgB)))       │ \(String(format: "%.4f", q.variance).padding(toLength: 8, withPad: " ", startingAt: 0)) │ \(assessment.padding(toLength: 35, withPad: " ", startingAt: 0)) │
            """
        }

        output += """

        └──────────┴─────────────────────┴──────────┴─────────────────────────────────────┘

        FINDING: Color is concentrated in \(mostColorful.name) quadrant.
                 \(colorfulPercent)% of frame has actual color variance.

        """

        // Diagnosis based on pattern
        if colorfulPercent == 100 {
            output += "DIAGNOSIS: Color evenly distributed - frame looks normal.\n"
        } else if colorfulPercent == 0 {
            output += "DIAGNOSIS: ⚠️ ENTIRE FRAME IS GRAY - possible input issue or total corruption.\n"
        } else if mostColorful.name == "BR" {
            output += "DIAGNOSIS: ⚠️ Color ONLY in bottom-right - possible crop region offset or Y-flip.\n"
        } else if mostColorful.name == "TL" {
            output += "DIAGNOSIS: ⚠️ Color ONLY in top-left - check FrameFormatConverter origin.\n"
        } else {
            output += "DIAGNOSIS: Color concentrated in \(mostColorful.name) - investigate camera framing.\n"
        }

        return output
    }

    /// Statistics for a quadrant
    private struct QuadrantStats {
        let name: String
        let avgR: Int
        let avgG: Int
        let avgB: Int
        let variance: Double
    }

    /// Analyze a specific quadrant of the frame
    private func analyzeQuadrant(_ rgbData: [UInt8], name: String, xRange: Range<Int>, yRange: Range<Int>) -> QuadrantStats {
        let width = 81
        var sumR = 0, sumG = 0, sumB = 0
        var pixels: [(r: Int, g: Int, b: Int)] = []

        for y in yRange {
            for x in xRange {
                let offset = (y * width + x) * 3
                let r = Int(rgbData[offset])
                let g = Int(rgbData[offset + 1])
                let b = Int(rgbData[offset + 2])
                pixels.append((r, g, b))
                sumR += r
                sumG += g
                sumB += b
            }
        }

        let count = pixels.count
        let avgR = sumR / count
        let avgG = sumG / count
        let avgB = sumB / count

        // Calculate variance (normalized 0-1)
        var varianceSum: Double = 0
        for px in pixels {
            let dr = Double(px.r - avgR)
            let dg = Double(px.g - avgG)
            let db = Double(px.b - avgB)
            varianceSum += (dr * dr + dg * dg + db * db)
        }
        let variance = varianceSum / Double(count) / (255.0 * 255.0 * 3.0)

        return QuadrantStats(name: name, avgR: avgR, avgG: avgG, avgB: avgB, variance: variance)
    }

    // MARK: - Pattern Detection (Replaces misleading FLAT detection)

    /// Detect actual corruption patterns: repeating rows, identical columns
    public func detectCorruptionPatterns(_ rgbData: [UInt8], frameIndex: Int) -> String {
        guard rgbData.count >= 81 * 81 * 3 else {
            return "PATTERN DETECTION: Insufficient data"
        }

        var output = """
        ═══════════════════════════════════════════════════════════════════════════════
                            CORRUPTION PATTERN DETECTION (Frame \(frameIndex))
        ═══════════════════════════════════════════════════════════════════════════════

        """

        let width = 81
        let height = 81

        // Check for identical adjacent rows (buffer stride bug)
        var identicalRowPairs: [(Int, Int)] = []
        for y in 0..<(height - 1) {
            let row1Start = y * width * 3
            let row2Start = (y + 1) * width * 3

            var identical = true
            for x in 0..<(width * 3) {
                if rgbData[row1Start + x] != rgbData[row2Start + x] {
                    identical = false
                    break
                }
            }
            if identical {
                identicalRowPairs.append((y, y + 1))
            }
        }

        // Check for identical adjacent columns (bytesPerRow bug)
        var identicalColPairs: [(Int, Int)] = []
        for x in 0..<(width - 1) {
            var identical = true
            for y in 0..<height {
                let offset1 = (y * width + x) * 3
                let offset2 = (y * width + x + 1) * 3
                if rgbData[offset1] != rgbData[offset2] ||
                   rgbData[offset1 + 1] != rgbData[offset2 + 1] ||
                   rgbData[offset1 + 2] != rgbData[offset2 + 2] {
                    identical = false
                    break
                }
            }
            if identical {
                identicalColPairs.append((x, x + 1))
            }
        }

        // Check for single solid color in large regions
        let firstPixel = (rgbData[0], rgbData[1], rgbData[2])
        var solidColorCount = 0
        for i in stride(from: 0, to: rgbData.count, by: 3) {
            if rgbData[i] == firstPixel.0 && rgbData[i+1] == firstPixel.1 && rgbData[i+2] == firstPixel.2 {
                solidColorCount += 1
            }
        }
        let solidPercent = Double(solidColorCount) / Double(width * height) * 100

        // Report findings
        if identicalRowPairs.count > 5 {
            output += "⚠️ REPEATING ROWS DETECTED: \(identicalRowPairs.count) pairs of identical adjacent rows\n"
            output += "   First occurrences: \(identicalRowPairs.prefix(5).map { "Y\($0.0)-\($0.1)" }.joined(separator: ", "))\n"
            output += "   LIKELY CAUSE: Buffer stride mismatch in FrameFormatConverter\n\n"
        } else if identicalRowPairs.count > 0 {
            output += "ℹ️ Some identical rows: \(identicalRowPairs.count) pairs (may be normal for uniform scenes)\n\n"
        } else {
            output += "✓ No repeating row pattern detected\n\n"
        }

        if identicalColPairs.count > 5 {
            output += "⚠️ REPEATING COLUMNS DETECTED: \(identicalColPairs.count) pairs of identical adjacent columns\n"
            output += "   First occurrences: \(identicalColPairs.prefix(5).map { "X\($0.0)-\($0.1)" }.joined(separator: ", "))\n"
            output += "   LIKELY CAUSE: Wrong bytesPerRow in source data\n\n"
        } else if identicalColPairs.count > 0 {
            output += "ℹ️ Some identical columns: \(identicalColPairs.count) pairs (may be normal for uniform scenes)\n\n"
        } else {
            output += "✓ No repeating column pattern detected\n\n"
        }

        if solidPercent > 50 {
            output += "⚠️ SOLID COLOR DOMINANCE: \(String(format: "%.1f", solidPercent))% of pixels are (\(firstPixel.0),\(firstPixel.1),\(firstPixel.2))\n"
            output += "   LIKELY CAUSE: Data read from wrong memory region or uninitialized buffer\n\n"
        } else if solidPercent > 20 {
            output += "ℹ️ Moderate color repetition: \(String(format: "%.1f", solidPercent))% pixels match first pixel\n\n"
        } else {
            output += "✓ Healthy pixel diversity (only \(String(format: "%.1f", solidPercent))% match first pixel)\n\n"
        }

        // Overall assessment
        let hasCorruption = identicalRowPairs.count > 5 || identicalColPairs.count > 5 || solidPercent > 50
        if hasCorruption {
            output += "───────────────────────────────────────────────────────────────────────────────\n"
            output += "⚠️ CORRUPTION PATTERNS DETECTED - This is NOT normal scene content!\n"
            output += "───────────────────────────────────────────────────────────────────────────────\n"
        } else {
            output += "───────────────────────────────────────────────────────────────────────────────\n"
            output += "✓ No corruption patterns - gray/dark areas are likely real scene content\n"
            output += "───────────────────────────────────────────────────────────────────────────────\n"
        }

        return output
    }

    /// Generate diagnostics for multiple frames (0, 40, 80)
    public func generateMultiFrameDiagnostics(_ frames: [(index: Int, cbor: [String: CBOR], rgbData: [UInt8], url: URL)]) -> String {
        var output = """
        ╔═══════════════════════════════════════════════════════════════════════════════╗
        ║              MULTI-FRAME SENTINEL ROW ANALYSIS                                ║
        ║              Tracing Y=10, Y=40, Y=70 across frames 0, 40, 80                 ║
        ╚═══════════════════════════════════════════════════════════════════════════════╝

        """

        let targetFrames = [0, 40, 80]
        for targetIdx in targetFrames {
            if let frame = frames.first(where: { $0.index == targetIdx }) {
                output += generateSentinelRowDiagnostics(frame.rgbData, frameIndex: frame.index)
                output += "\n\n"
            } else {
                output += "Frame \(targetIdx): NOT FOUND\n\n"
            }
        }

        return output
    }
}
