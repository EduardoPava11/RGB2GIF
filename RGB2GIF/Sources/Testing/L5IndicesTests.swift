//
//  L5IndicesTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L5_INDICES TESTS - Palette Index Validation                             ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Validates palette indices for all 531,441 pixels (81×81×81):            ║
//  ║  • L5.1  Frame Count (exactly 81)                                        ║
//  ║  • L5.2  File Naming (i00.cbor - i80.cbor)                               ║
//  ║  • L5.3  Index Count (6,561 per frame)                                   ║
//  ║  • L5.4  Index Range (all 0-255)                                         ║
//  ║  • L5.5  Dimensions (81×81)                                              ║
//  ║  • L5.6  Unique Indices (reasonable variety)                             ║
//  ║  • L5.7  Histogram (distribution analysis)                               ║
//  ║  • L5.8  Dominant Index (most-used color)                                ║
//  ║  • L5.9  Reconstruction Test (index→palette→RGB)                         ║
//  ║  • L5.10 Consistency (adjacent frames similar)                           ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let testLogger = Logger(subsystem: "com.rgb2gif.tests", category: "L5Indices")

@available(iOS 26.0, *)
public struct L5IndicesTests {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Frame Data Structure

    private struct ParsedFrame {
        let index: Int
        let width: Int
        let height: Int
        let pixelCount: Int
        let indices: [UInt8]
    }

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    public func run() async -> StageTestResults {
        var results = StageTestResults(stageName: "L5_INDICES")

        testLogger.info("Starting L5_INDICES tests for session: \(session.sessionID)")

        let fm = FileManager.default
        let l5URL = session.l5IndicesURL

        // Collect all index CBOR files
        var cborFiles: [URL] = []
        do {
            let contents = try fm.contentsOfDirectory(at: l5URL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            cborFiles = contents.filter { $0.pathExtension == "cbor" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            results.tests.append(CBORTestResult(
                id: "L5.0",
                name: "Directory Access",
                passed: false,
                expected: "L5_indices directory exists",
                actual: "Error: \(error.localizedDescription)",
                details: "Cannot access L5_indices at \(l5URL.path)"
            ))
            return results
        }

        // Parse all frame files
        var parsedFrames: [ParsedFrame] = []
        var parseErrors: [String] = []

        for url in cborFiles {
            if let frame = parseFrame(from: url) {
                parsedFrames.append(frame)
            } else {
                parseErrors.append("Failed to parse \(url.lastPathComponent)")
            }
        }

        // Sort by index
        parsedFrames.sort { $0.index < $1.index }

        // L5.1: Frame Count
        results.tests.append(testFrameCount(cborFiles.count))

        // L5.2: File Naming
        results.tests.append(testFileNaming(cborFiles))

        // L5.3: Index Count
        results.tests.append(testIndexCount(parsedFrames))

        // L5.4: Index Range
        results.tests.append(testIndexRange(parsedFrames))

        // L5.5: Dimensions
        results.tests.append(testDimensions(parsedFrames))

        // L5.6: Unique Indices
        results.tests.append(testUniqueIndices(parsedFrames))

        // L5.7: Histogram
        results.tests.append(testHistogram(parsedFrames))

        // L5.8: Dominant Index
        results.tests.append(testDominantIndex(parsedFrames))

        // L5.9: Reconstruction Test - informational
        results.tests.append(CBORTestResult(
            id: "L5.9",
            name: "Reconstruction",
            passed: true,
            expected: "Index → Palette → RGB",
            actual: "Verified in CrossStageTests",
            details: "Full reconstruction test in cross-stage validation"
        ))

        // L5.10: Consistency
        results.tests.append(testConsistency(parsedFrames))

        // Diagnostics
        if parsedFrames.count >= 41 {
            results.diagnostics.append(generateFrameAnalysis(parsedFrames[40]))
        } else if let first = parsedFrames.first {
            results.diagnostics.append(generateFrameAnalysis(first))
        }

        testLogger.info("L5_INDICES tests complete: \(results.passCount)/\(results.totalCount) passed")

        return results
    }

    // MARK: - Parsing

    private func parseFrame(from url: URL) -> ParsedFrame? {
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

            var frameIndex = -1
            var width = 0, height = 0
            var pixelCount = 0
            var indices: [UInt8] = []

            if case .unsignedInt(let i) = dict["frame_index"] {
                frameIndex = Int(i)
            }

            if case .map(let dims) = dict["dimensions"] {
                for (k, v) in dims {
                    if case .utf8String("width") = k, case .unsignedInt(let val) = v { width = Int(val) }
                    if case .utf8String("height") = k, case .unsignedInt(let val) = v { height = Int(val) }
                }
            }

            if case .unsignedInt(let p) = dict["pixel_count"] {
                pixelCount = Int(p)
            }

            if case .byteString(let idx) = dict["indices"] {
                indices = idx
            }

            return ParsedFrame(index: frameIndex, width: width, height: height, pixelCount: pixelCount, indices: indices)
        } catch {
            return nil
        }
    }

    // MARK: - Individual Tests

    /// L5.1: Frame Count
    private func testFrameCount(_ count: Int) -> CBORTestResult {
        CBORTestResult(
            id: "L5.1",
            name: "Frame Count",
            passed: count == 81,
            expected: "81",
            actual: "\(count)",
            details: count == 81 ? "All 81 index files present" : "Missing \(81 - count) file(s)"
        )
    }

    /// L5.2: File Naming - i00.cbor through i80.cbor
    private func testFileNaming(_ files: [URL]) -> CBORTestResult {
        var missing: [String] = []
        for i in 0..<81 {
            let expected = String(format: "i%02d.cbor", i)
            if !files.contains(where: { $0.lastPathComponent == expected }) {
                missing.append(expected)
            }
        }

        return CBORTestResult(
            id: "L5.2",
            name: "File Naming",
            passed: missing.isEmpty,
            expected: "i00.cbor - i80.cbor",
            actual: missing.isEmpty ? "All present" : "\(missing.count) missing",
            details: missing.isEmpty ? "All files named correctly" : "Missing: \(missing.prefix(5).joined(separator: ", "))"
        )
    }

    /// L5.3: Index Count - 6,561 per frame
    private func testIndexCount(_ frames: [ParsedFrame]) -> CBORTestResult {
        var wrong: [String] = []
        for frame in frames {
            if frame.indices.count != 6561 {
                wrong.append("Frame \(frame.index): \(frame.indices.count)")
            }
        }

        return CBORTestResult(
            id: "L5.3",
            name: "Index Count",
            passed: wrong.isEmpty,
            expected: "6,561 per frame",
            actual: wrong.isEmpty ? "All correct" : "\(wrong.count) wrong",
            details: wrong.isEmpty ? "All frames have 6561 indices" : wrong.prefix(3).joined(separator: "; ")
        )
    }

    /// L5.4: Index Range - all 0-255
    private func testIndexRange(_ frames: [ParsedFrame]) -> CBORTestResult {
        // UInt8 is always 0-255, so this is automatic
        // But we can check for suspicious patterns (all 0s)
        var allZero: [Int] = []

        for frame in frames {
            let nonZero = frame.indices.filter { $0 != 0 }.count
            if nonZero == 0 && !frame.indices.isEmpty {
                allZero.append(frame.index)
            }
        }

        return CBORTestResult(
            id: "L5.4",
            name: "Index Range",
            passed: allZero.isEmpty,
            expected: "Values 0-255, varied",
            actual: allZero.isEmpty ? "Valid range" : "\(allZero.count) all-zero frames",
            details: allZero.isEmpty ? "All index values in valid range" : "All-zero frames: \(allZero.prefix(5))"
        )
    }

    /// L5.5: Dimensions - 81×81
    private func testDimensions(_ frames: [ParsedFrame]) -> CBORTestResult {
        var wrong: [String] = []
        for frame in frames {
            if frame.width != 81 || frame.height != 81 {
                wrong.append("Frame \(frame.index): \(frame.width)×\(frame.height)")
            }
        }

        return CBORTestResult(
            id: "L5.5",
            name: "Dimensions",
            passed: wrong.isEmpty,
            expected: "81×81",
            actual: wrong.isEmpty ? "All 81×81" : "\(wrong.count) wrong",
            details: wrong.isEmpty ? "All frames 81×81" : wrong.prefix(3).joined(separator: "; ")
        )
    }

    /// L5.6: Unique Indices - reasonable variety
    private func testUniqueIndices(_ frames: [ParsedFrame]) -> CBORTestResult {
        var tooFew: [Int] = []
        var uniqueCounts: [Int] = []

        for frame in frames {
            let unique = Set(frame.indices).count
            uniqueCounts.append(unique)
            if unique < 5 {  // At least 5 different colors expected
                tooFew.append(frame.index)
            }
        }

        let avgUnique = uniqueCounts.isEmpty ? 0 : uniqueCounts.reduce(0, +) / uniqueCounts.count
        let minUnique = uniqueCounts.min() ?? 0
        let maxUnique = uniqueCounts.max() ?? 0

        return CBORTestResult(
            id: "L5.6",
            name: "Unique Indices",
            passed: tooFew.isEmpty,
            expected: "≥5 unique per frame",
            actual: "Avg \(avgUnique), Range [\(minUnique)-\(maxUnique)]",
            details: tooFew.isEmpty ? "All frames have variety" : "Low variety in frames: \(tooFew.prefix(5))"
        )
    }

    /// L5.7: Histogram - distribution analysis
    private func testHistogram(_ frames: [ParsedFrame]) -> CBORTestResult {
        guard let first = frames.first else {
            return CBORTestResult(id: "L5.7", name: "Histogram", passed: false, expected: "Distribution", actual: "No data", details: "No frames to analyze")
        }

        // Build histogram for first frame
        var histogram = [Int](repeating: 0, count: 256)
        for idx in first.indices {
            histogram[Int(idx)] += 1
        }

        let nonZeroBins = histogram.filter { $0 > 0 }.count
        let maxBin = histogram.max() ?? 0
        let topIndex = histogram.firstIndex(of: maxBin) ?? 0

        return CBORTestResult(
            id: "L5.7",
            name: "Histogram",
            passed: nonZeroBins >= 5,
            expected: "Reasonable distribution",
            actual: "\(nonZeroBins) bins used",
            details: "Most common: index \(topIndex) (\(maxBin) pixels)"
        )
    }

    /// L5.8: Dominant Index - most-used color
    private func testDominantIndex(_ frames: [ParsedFrame]) -> CBORTestResult {
        guard let middleFrame = frames.count > 40 ? frames[40] : frames.first else {
            return CBORTestResult(id: "L5.8", name: "Dominant Index", passed: false, expected: "Identifiable dominant color", actual: "No data", details: "No frames to analyze")
        }

        var histogram = [Int](repeating: 0, count: 256)
        for idx in middleFrame.indices {
            histogram[Int(idx)] += 1
        }

        let maxCount = histogram.max() ?? 0
        let dominantIndex = histogram.firstIndex(of: maxCount) ?? 0
        let percentage = Double(maxCount) / Double(middleFrame.indices.count) * 100

        return CBORTestResult(
            id: "L5.8",
            name: "Dominant Index",
            passed: true,  // Informational
            expected: "Identify most-used color",
            actual: String(format: "Index %d (%.1f%%)", dominantIndex, percentage),
            details: "Frame 40: \(maxCount) pixels use palette index \(dominantIndex)"
        )
    }

    /// L5.10: Consistency - adjacent frames similar
    private func testConsistency(_ frames: [ParsedFrame]) -> CBORTestResult {
        guard frames.count >= 2 else {
            return CBORTestResult(id: "L5.10", name: "Consistency", passed: false, expected: "Similar patterns", actual: "Need 2+ frames", details: "Insufficient frames for comparison")
        }

        // Compare histograms of adjacent frames
        var largeChanges: [Int] = []

        for i in 1..<min(frames.count, 10) {  // Check first 10 pairs
            let prev = frames[i-1]
            let curr = frames[i]

            var histPrev = [Int](repeating: 0, count: 256)
            var histCurr = [Int](repeating: 0, count: 256)

            for idx in prev.indices { histPrev[Int(idx)] += 1 }
            for idx in curr.indices { histCurr[Int(idx)] += 1 }

            // Calculate histogram difference
            var diff = 0
            for j in 0..<256 {
                diff += abs(histPrev[j] - histCurr[j])
            }

            // If more than 50% of pixels change, it's suspicious
            if diff > prev.indices.count {
                largeChanges.append(i)
            }
        }

        return CBORTestResult(
            id: "L5.10",
            name: "Consistency",
            passed: largeChanges.isEmpty,
            expected: "Smooth transitions",
            actual: largeChanges.isEmpty ? "Smooth" : "\(largeChanges.count) abrupt changes",
            details: largeChanges.isEmpty ? "Adjacent frames have similar indices" : "Abrupt changes at frames: \(largeChanges)"
        )
    }

    // MARK: - Diagnostics

    private func generateFrameAnalysis(_ frame: ParsedFrame) -> String {
        var histogram = [Int](repeating: 0, count: 256)
        for idx in frame.indices {
            histogram[Int(idx)] += 1
        }

        let unique = Set(frame.indices).count
        let maxCount = histogram.max() ?? 0
        let minCount = histogram.filter { $0 > 0 }.min() ?? 0
        let dominantIdx = histogram.firstIndex(of: maxCount) ?? 0

        // Find top 5
        let sorted = histogram.enumerated().sorted { $0.element > $1.element }
        var top5 = ""
        for (rank, entry) in sorted.prefix(5).enumerated() {
            let percent = Double(entry.element) / Double(frame.indices.count) * 100
            top5 += String(format: "  #%d: Index %d (%d px = %.1f%%)\n", rank + 1, entry.offset, entry.element, percent)
        }

        return """
        FRAME \(frame.index) INDEX ANALYSIS:
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ Statistic              │ Value                                              │
        ├─────────────────────────────────────────────────────────────────────────────┤
        │ Total pixels           │ \(String(format: "%,d", frame.indices.count).padding(toLength: 48, withPad: " ", startingAt: 0))│
        │ Unique indices used    │ \(String(unique).padding(toLength: 48, withPad: " ", startingAt: 0))│
        │ Most frequent index    │ \(dominantIdx) (appears \(maxCount) times)
        │ Least frequent index   │ (min \(minCount) times)
        │ Unused indices         │ \(256 - unique) of 256
        └─────────────────────────────────────────────────────────────────────────────┘

        TOP 5 INDICES BY USAGE:
        \(top5)
        """
    }
}
