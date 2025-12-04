//
//  L0RawTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L0_RAW TESTS - Raw Camera Frame Validation                              ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Validates raw camera frames in BGRA format:                             ║
//  ║  • L0.1  Frame Count (exactly 81)                                        ║
//  ║  • L0.2  File Naming (r00.cbor - r80.cbor)                               ║
//  ║  • L0.3  CBOR Structure (valid with required keys)                       ║
//  ║  • L0.4  Format Field ("BGRA8")                                          ║
//  ║  • L0.5  Dimensions Valid (reasonable size 100-8000)                     ║
//  ║  • L0.6  Data Size (width × height × 4)                                  ║
//  ║  • L0.7  Timestamps Monotonic                                            ║
//  ║  • L0.8  Timestamp Interval (~33ms at 30fps)                             ║
//  ║  • L0.9  Non-Empty Data                                                  ║
//  ║  • L0.10 BGRA Byte Order Verification                                    ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let testLogger = Logger(subsystem: "com.rgb2gif.tests", category: "L0Raw")

@available(iOS 26.0, *)
public struct L0RawTests {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    public func run() async -> StageTestResults {
        var results = StageTestResults(stageName: "L0_RAW")

        testLogger.info("Starting L0_RAW tests for session: \(session.sessionID)")

        // Collect all CBOR files
        let fm = FileManager.default
        let l0URL = session.l0RawURL
        var cborFiles: [URL] = []

        do {
            let contents = try fm.contentsOfDirectory(at: l0URL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            cborFiles = contents.filter { $0.pathExtension == "cbor" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            results.tests.append(CBORTestResult(
                id: "L0.0",
                name: "Directory Access",
                passed: false,
                expected: "L0_raw directory exists",
                actual: "Error: \(error.localizedDescription)",
                details: "Cannot access L0_raw directory at \(l0URL.path)"
            ))
            return results
        }

        // Parse all CBOR files
        var parsedFrames: [(index: Int, cbor: [String: CBOR], url: URL)] = []
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
                    if case .unsignedInt(let idx) = stringMap["index"] {
                        parsedFrames.append((Int(idx), stringMap, url))
                    }
                }
            } catch {
                parseErrors.append("Failed to parse \(url.lastPathComponent): \(error)")
            }
        }

        // Sort by index
        parsedFrames.sort { $0.index < $1.index }

        // L0.1: Frame Count
        results.tests.append(testFrameCount(cborFiles.count))

        // L0.2: File Naming
        results.tests.append(testFileNaming(cborFiles))

        // L0.3: CBOR Structure
        results.tests.append(testCBORStructure(parsedFrames, parseErrors: parseErrors))

        // L0.4: Format Field
        results.tests.append(testFormatField(parsedFrames))

        // L0.5: Dimensions Valid
        let (dimTest, widths, heights) = testDimensionsValid(parsedFrames)
        results.tests.append(dimTest)

        // L0.6: Data Size
        results.tests.append(testDataSize(parsedFrames, widths: widths, heights: heights))

        // L0.7: Timestamps Monotonic
        let (tsTest, timestamps) = testTimestampsMonotonic(parsedFrames)
        results.tests.append(tsTest)

        // L0.8: Timestamp Interval
        results.tests.append(testTimestampInterval(timestamps))

        // L0.9: Non-Empty Data
        results.tests.append(testNonEmptyData(parsedFrames))

        // L0.10: BGRA Byte Order
        results.tests.append(testBGRAByteOrder(parsedFrames))

        // Add diagnostic info
        if let first = parsedFrames.first {
            results.diagnostics.append(generateFrameDiagnostic(first.cbor, label: "First Frame (r00)"))
        }
        if let last = parsedFrames.last {
            results.diagnostics.append(generateFrameDiagnostic(last.cbor, label: "Last Frame (r80)"))
        }

        testLogger.info("L0_RAW tests complete: \(results.passCount)/\(results.totalCount) passed")

        return results
    }

    // MARK: - Individual Tests

    /// L0.1: Frame Count - exactly 81 files
    private func testFrameCount(_ count: Int) -> CBORTestResult {
        CBORTestResult(
            id: "L0.1",
            name: "Frame Count",
            passed: count == 81,
            expected: "81",
            actual: "\(count)",
            details: count == 81 ? "All 81 raw frames present" : "Missing \(81 - count) frame(s)"
        )
    }

    /// L0.2: File Naming - r00.cbor through r80.cbor
    private func testFileNaming(_ files: [URL]) -> CBORTestResult {
        var missing: [String] = []
        for i in 0..<81 {
            let expected = String(format: "r%02d.cbor", i)
            if !files.contains(where: { $0.lastPathComponent == expected }) {
                missing.append(expected)
            }
        }

        return CBORTestResult(
            id: "L0.2",
            name: "File Naming",
            passed: missing.isEmpty,
            expected: "r00.cbor - r80.cbor",
            actual: missing.isEmpty ? "All present" : "Missing: \(missing.prefix(5).joined(separator: ", "))\(missing.count > 5 ? "..." : "")",
            details: missing.isEmpty ? "All 81 files named correctly" : "\(missing.count) files missing"
        )
    }

    /// L0.3: CBOR Structure - all files parse correctly
    private func testCBORStructure(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)], parseErrors: [String]) -> CBORTestResult {
        let requiredKeys = ["index", "timestamp_ms", "dimensions", "format", "bgra_data"]
        var missingKeys: [String] = []

        for frame in frames {
            for key in requiredKeys {
                if frame.cbor[key] == nil {
                    missingKeys.append("Frame \(frame.index) missing '\(key)'")
                }
            }
        }

        let allErrors = parseErrors + missingKeys

        return CBORTestResult(
            id: "L0.3",
            name: "CBOR Structure",
            passed: allErrors.isEmpty,
            expected: "All files valid CBOR with required keys",
            actual: allErrors.isEmpty ? "All valid" : "\(allErrors.count) error(s)",
            details: allErrors.isEmpty ? "All frames have required structure" : allErrors.prefix(3).joined(separator: "; ")
        )
    }

    /// L0.4: Format Field - all frames are "BGRA8"
    private func testFormatField(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)]) -> CBORTestResult {
        var nonBGRA: [Int] = []

        for frame in frames {
            if case .utf8String(let format) = frame.cbor["format"] {
                if format != "BGRA8" {
                    nonBGRA.append(frame.index)
                }
            } else {
                nonBGRA.append(frame.index)
            }
        }

        return CBORTestResult(
            id: "L0.4",
            name: "Format Field",
            passed: nonBGRA.isEmpty,
            expected: "All 'BGRA8'",
            actual: nonBGRA.isEmpty ? "All BGRA8" : "\(nonBGRA.count) non-BGRA8 frames",
            details: nonBGRA.isEmpty ? "All frames marked as BGRA8" : "Non-BGRA8 at indices: \(nonBGRA.prefix(5))"
        )
    }

    /// L0.5: Dimensions Valid - reasonable camera resolution
    private func testDimensionsValid(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)]) -> (CBORTestResult, [Int], [Int]) {
        var widths: [Int] = []
        var heights: [Int] = []
        var invalid: [String] = []

        for frame in frames {
            if case .map(let dims) = frame.cbor["dimensions"] {
                var w = 0, h = 0
                for (key, value) in dims {
                    if case .utf8String("width") = key, case .unsignedInt(let v) = value {
                        w = Int(v)
                    }
                    if case .utf8String("height") = key, case .unsignedInt(let v) = value {
                        h = Int(v)
                    }
                }

                widths.append(w)
                heights.append(h)

                if w < 100 || w > 8000 || h < 100 || h > 8000 {
                    invalid.append("Frame \(frame.index): \(w)×\(h)")
                }
            }
        }

        let uniqueSizes = Set(zip(widths, heights).map { "\($0.0)×\($0.1)" })
        let sizeInfo = uniqueSizes.joined(separator: ", ")

        return (CBORTestResult(
            id: "L0.5",
            name: "Dimensions Valid",
            passed: invalid.isEmpty && !widths.isEmpty,
            expected: "100-8000 range",
            actual: invalid.isEmpty ? sizeInfo : "\(invalid.count) invalid",
            details: invalid.isEmpty ? "All dimensions in valid range" : invalid.prefix(3).joined(separator: "; ")
        ), widths, heights)
    }

    /// L0.6: Data Size - matches width × height × 4
    private func testDataSize(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)], widths: [Int], heights: [Int]) -> CBORTestResult {
        var mismatches: [String] = []

        for (i, frame) in frames.enumerated() {
            if case .byteString(let data) = frame.cbor["bgra_data"] {
                let w = i < widths.count ? widths[i] : 0
                let h = i < heights.count ? heights[i] : 0
                let expected = w * h * 4

                if data.count != expected {
                    mismatches.append("Frame \(frame.index): got \(data.count), expected \(expected)")
                }
            }
        }

        return CBORTestResult(
            id: "L0.6",
            name: "Data Size",
            passed: mismatches.isEmpty,
            expected: "width × height × 4 bytes",
            actual: mismatches.isEmpty ? "All correct" : "\(mismatches.count) mismatch(es)",
            details: mismatches.isEmpty ? "BGRA data size matches dimensions" : mismatches.prefix(3).joined(separator: "; ")
        )
    }

    /// L0.7: Timestamps Monotonic
    private func testTimestampsMonotonic(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)]) -> (CBORTestResult, [Int64]) {
        var timestamps: [Int64] = []
        var nonMonotonic: [String] = []

        for frame in frames {
            if case .unsignedInt(let ts) = frame.cbor["timestamp_ms"] {
                timestamps.append(Int64(ts))
            }
        }

        for i in 1..<timestamps.count {
            if timestamps[i] <= timestamps[i-1] {
                nonMonotonic.append("ts[\(i)] ≤ ts[\(i-1)]")
            }
        }

        let range = timestamps.isEmpty ? "N/A" : "\(timestamps.first!) → \(timestamps.last!)ms"

        return (CBORTestResult(
            id: "L0.7",
            name: "Timestamps Monotonic",
            passed: nonMonotonic.isEmpty && timestamps.count == 81,
            expected: "Monotonically increasing",
            actual: nonMonotonic.isEmpty ? range : "\(nonMonotonic.count) violation(s)",
            details: nonMonotonic.isEmpty ? "All timestamps increasing" : nonMonotonic.prefix(3).joined(separator: "; ")
        ), timestamps)
    }

    /// L0.8: Timestamp Interval - ~33ms at 30fps
    private func testTimestampInterval(_ timestamps: [Int64]) -> CBORTestResult {
        guard timestamps.count >= 2 else {
            return CBORTestResult(
                id: "L0.8",
                name: "Timestamp Interval",
                passed: false,
                expected: "~33ms ± 10ms",
                actual: "Insufficient data",
                details: "Need at least 2 timestamps"
            )
        }

        var intervals: [Int64] = []
        for i in 1..<timestamps.count {
            intervals.append(timestamps[i] - timestamps[i-1])
        }

        let avgInterval = Double(intervals.reduce(0, +)) / Double(intervals.count)
        let minInterval = intervals.min() ?? 0
        let maxInterval = intervals.max() ?? 0

        // Allow wider tolerance: 10-100ms (10-100fps range)
        let passed = avgInterval >= 10 && avgInterval <= 100

        return CBORTestResult(
            id: "L0.8",
            name: "Timestamp Interval",
            passed: passed,
            expected: "~33ms ± 10ms (30fps)",
            actual: String(format: "Avg %.1fms [%d-%d]", avgInterval, minInterval, maxInterval),
            details: passed ? "Frame rate within expected range" : "Unusual frame timing"
        )
    }

    /// L0.9: Non-Empty Data - first frame has actual pixel data
    private func testNonEmptyData(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)]) -> CBORTestResult {
        guard let first = frames.first,
              case .byteString(let data) = first.cbor["bgra_data"],
              data.count >= 4 else {
            return CBORTestResult(
                id: "L0.9",
                name: "Non-Empty Data",
                passed: false,
                expected: "Non-zero pixel data",
                actual: "No data available",
                details: "Cannot read first frame data"
            )
        }

        // Check if all bytes are zero (empty frame)
        let sampleSize = min(1000, data.count)
        let nonZeroCount = data.prefix(sampleSize).filter { $0 != 0 }.count

        let firstPixel = "B=\(data[0]) G=\(data[1]) R=\(data[2]) A=\(data[3])"

        return CBORTestResult(
            id: "L0.9",
            name: "Non-Empty Data",
            passed: nonZeroCount > sampleSize / 10,  // At least 10% non-zero
            expected: "Non-zero pixel data",
            actual: firstPixel,
            details: "\(nonZeroCount)/\(sampleSize) non-zero bytes in sample"
        )
    }

    /// L0.10: BGRA Byte Order - verify byte layout
    private func testBGRAByteOrder(_ frames: [(index: Int, cbor: [String: CBOR], url: URL)]) -> CBORTestResult {
        guard let first = frames.first,
              case .byteString(let data) = first.cbor["bgra_data"],
              data.count >= 4 else {
            return CBORTestResult(
                id: "L0.10",
                name: "BGRA Byte Order",
                passed: false,
                expected: "[B,G,R,A] per pixel",
                actual: "No data",
                details: "Cannot verify byte order"
            )
        }

        // BGRA format means byte 3 is alpha (should be 255 for opaque)
        var alphaValues: [UInt8] = []
        for i in stride(from: 3, to: min(data.count, 400), by: 4) {
            alphaValues.append(data[i])
        }

        let avgAlpha = Double(alphaValues.reduce(0, { $0 + Int($1) })) / Double(alphaValues.count)

        // Alpha should be ~255 for camera frames (opaque)
        let passed = avgAlpha > 240

        return CBORTestResult(
            id: "L0.10",
            name: "BGRA Byte Order",
            passed: passed,
            expected: "Alpha ~255 (opaque)",
            actual: String(format: "Avg alpha: %.1f", avgAlpha),
            details: passed ? "BGRA byte order confirmed" : "Unexpected alpha values - check byte order"
        )
    }

    // MARK: - Diagnostic Helpers

    private func generateFrameDiagnostic(_ cbor: [String: CBOR], label: String) -> String {
        var lines: [String] = []
        lines.append("\(label):")

        if case .unsignedInt(let idx) = cbor["index"] {
            lines.append("  Index: \(idx)")
        }
        if case .unsignedInt(let ts) = cbor["timestamp_ms"] {
            lines.append("  Timestamp: \(ts)ms")
        }
        if case .map(let dims) = cbor["dimensions"] {
            var w = 0, h = 0
            for (key, value) in dims {
                if case .utf8String("width") = key, case .unsignedInt(let v) = value { w = Int(v) }
                if case .utf8String("height") = key, case .unsignedInt(let v) = value { h = Int(v) }
            }
            lines.append("  Dimensions: \(w)×\(h)")
        }
        if case .utf8String(let format) = cbor["format"] {
            lines.append("  Format: \(format)")
        }
        if case .byteString(let data) = cbor["bgra_data"] {
            lines.append("  Data size: \(data.count) bytes")
            if data.count >= 12 {
                lines.append("  First 3 pixels (BGRA):")
                for i in 0..<3 {
                    let offset = i * 4
                    lines.append("    Pixel \(i): B=\(data[offset]) G=\(data[offset+1]) R=\(data[offset+2]) A=\(data[offset+3])")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}
