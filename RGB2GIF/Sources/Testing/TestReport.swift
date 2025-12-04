//
//  TestReport.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  PIPELINE TEST REPORT - TEXT-BASED DIAGNOSTIC OUTPUT                     ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  All test results output as TEXT for programmatic analysis:              ║
//  ║  • No GIF viewing required                                               ║
//  ║  • Clear pass/fail indicators                                            ║
//  ║  • Detailed diagnostic information                                       ║
//  ║  • Self-diagnosing failure modes                                         ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation

// MARK: - CBOR Test Result

@available(iOS 26.0, *)
public struct CBORTestResult {
    /// Test identifier (e.g., "L0.1", "L2.5", "X.3")
    public let id: String

    /// Short test name (e.g., "Frame Count", "Dimensions")
    public let name: String

    /// Whether the test passed
    public var passed: Bool

    /// Expected value/outcome
    public let expected: String

    /// Actual value/outcome
    public var actual: String

    /// Detailed diagnostic information
    public var details: String

    public init(
        id: String,
        name: String,
        passed: Bool = false,
        expected: String,
        actual: String = "",
        details: String = ""
    ) {
        self.id = id
        self.name = name
        self.passed = passed
        self.expected = expected
        self.actual = actual
        self.details = details
    }

    /// Format as a single line for summary
    public func summaryLine() -> String {
        let status = passed ? "✅ PASS" : "❌ FAIL"
        let paddedId = id.padding(toLength: 8, withPad: " ", startingAt: 0)
        let paddedName = name.padding(toLength: 30, withPad: " ", startingAt: 0)
        return "\(paddedId) \(paddedName) \(actual.padding(toLength: 30, withPad: " ", startingAt: 0)) \(status)"
    }
}

// MARK: - Stage Test Results

@available(iOS 26.0, *)
public struct StageTestResults {
    /// Stage name (e.g., "L0_RAW", "L2_FRAMES")
    public let stageName: String

    /// All test results for this stage
    public var tests: [CBORTestResult]

    /// Additional diagnostic text (corner analysis, pixel dumps, etc.)
    public var diagnostics: [String]

    public init(stageName: String) {
        self.stageName = stageName
        self.tests = []
        self.diagnostics = []
    }

    /// Number of passed tests
    public var passCount: Int { tests.filter { $0.passed }.count }

    /// Number of failed tests
    public var failCount: Int { tests.filter { !$0.passed }.count }

    /// Total number of tests
    public var totalCount: Int { tests.count }

    /// Whether all tests passed
    public var allPassed: Bool { failCount == 0 }

    /// Generate formatted text report for this stage
    public func generateReport() -> String {
        var lines: [String] = []

        // Header
        lines.append("═══════════════════════════════════════════════════════════════════════════════")
        lines.append("\(stageName) TEST RESULTS")
        lines.append("═══════════════════════════════════════════════════════════════════════════════")
        lines.append("")

        // Test results
        for test in tests {
            lines.append(test.summaryLine())
        }

        lines.append("")
        lines.append("SUMMARY: \(passCount)/\(totalCount) tests passed")

        // Diagnostics
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("───────────────────────────────────────────────────────────────────────────────")
            lines.append("DIAGNOSTICS:")
            lines.append("───────────────────────────────────────────────────────────────────────────────")
            for diagnostic in diagnostics {
                lines.append(diagnostic)
            }
        }

        lines.append("───────────────────────────────────────────────────────────────────────────────")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Cross-Stage Test Results

@available(iOS 26.0, *)
public struct CrossStageTestResults {
    public var tests: [CBORTestResult]
    public var diagnostics: [String]

    public init() {
        self.tests = []
        self.diagnostics = []
    }

    public var passCount: Int { tests.filter { $0.passed }.count }
    public var failCount: Int { tests.filter { !$0.passed }.count }
    public var totalCount: Int { tests.count }
    public var allPassed: Bool { failCount == 0 }

    public func generateReport() -> String {
        var lines: [String] = []

        lines.append("═══════════════════════════════════════════════════════════════════════════════")
        lines.append("CROSS-STAGE VALIDATION TESTS")
        lines.append("═══════════════════════════════════════════════════════════════════════════════")
        lines.append("")

        for test in tests {
            lines.append(test.summaryLine())
        }

        lines.append("")
        lines.append("SUMMARY: \(passCount)/\(totalCount) tests passed")

        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("───────────────────────────────────────────────────────────────────────────────")
            for diagnostic in diagnostics {
                lines.append(diagnostic)
            }
        }

        lines.append("───────────────────────────────────────────────────────────────────────────────")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}

// MARK: - End-to-End Test Results

@available(iOS 26.0, *)
public struct EndToEndTestResults {
    public var tests: [CBORTestResult]
    public var diagnostics: [String]

    public init() {
        self.tests = []
        self.diagnostics = []
    }

    public var passCount: Int { tests.filter { $0.passed }.count }
    public var failCount: Int { tests.filter { !$0.passed }.count }
    public var totalCount: Int { tests.count }
    public var allPassed: Bool { failCount == 0 }

    public func generateReport() -> String {
        var lines: [String] = []

        lines.append("═══════════════════════════════════════════════════════════════════════════════")
        lines.append("END-TO-END SANITY TESTS")
        lines.append("═══════════════════════════════════════════════════════════════════════════════")
        lines.append("")

        for test in tests {
            lines.append(test.summaryLine())
        }

        lines.append("")
        lines.append("SUMMARY: \(passCount)/\(totalCount) tests passed")

        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("───────────────────────────────────────────────────────────────────────────────")
            for diagnostic in diagnostics {
                lines.append(diagnostic)
            }
        }

        lines.append("───────────────────────────────────────────────────────────────────────────────")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Complete Pipeline Test Report

@available(iOS 26.0, *)
public struct PipelineTestReport {
    /// Session identifier
    public var sessionID: String

    /// Timestamp of test run
    public var timestamp: Date

    /// Stage results
    public var l0Results: StageTestResults
    public var l2Results: StageTestResults
    public var l3Results: StageTestResults
    public var l4Results: StageTestResults
    public var l5Results: StageTestResults

    /// Cross-stage validation
    public var crossStageResults: CrossStageTestResults

    /// End-to-end sanity tests
    public var e2eResults: EndToEndTestResults

    /// Warnings and errors
    public var warnings: [String]
    public var errors: [String]

    /// Verification test results (synthetic crop/resize tests)
    public var verificationTestOutput: String

    /// GIF structure diagnostic output
    public var gifDiagnosticOutput: String

    /// LZW encoder diagnostic output
    public var lzwDiagnosticOutput: String

    public init(sessionID: String = "") {
        self.sessionID = sessionID
        self.timestamp = Date()
        self.l0Results = StageTestResults(stageName: "L0_RAW")
        self.l2Results = StageTestResults(stageName: "L2_FRAMES")
        self.l3Results = StageTestResults(stageName: "L3_TENSOR")
        self.l4Results = StageTestResults(stageName: "L4_PALETTE")
        self.l5Results = StageTestResults(stageName: "L5_INDICES")
        self.crossStageResults = CrossStageTestResults()
        self.e2eResults = EndToEndTestResults()
        self.warnings = []
        self.errors = []
        self.verificationTestOutput = ""
        self.gifDiagnosticOutput = ""
        self.lzwDiagnosticOutput = ""
    }

    /// Total tests across all stages
    public var totalTests: Int {
        l0Results.totalCount +
        l2Results.totalCount +
        l3Results.totalCount +
        l4Results.totalCount +
        l5Results.totalCount +
        crossStageResults.totalCount +
        e2eResults.totalCount
    }

    /// Total passed tests
    public var totalPassed: Int {
        l0Results.passCount +
        l2Results.passCount +
        l3Results.passCount +
        l4Results.passCount +
        l5Results.passCount +
        crossStageResults.passCount +
        e2eResults.passCount
    }

    /// Overall pass percentage
    public var passPercentage: Double {
        guard totalTests > 0 else { return 0 }
        return Double(totalPassed) / Double(totalTests) * 100
    }

    /// Generate complete text report for analysis
    public func generateTextReport() -> String {
        var lines: [String] = []

        // Header
        lines.append("╔═══════════════════════════════════════════════════════════════════════════════╗")
        lines.append("║                    RGB2GIF PIPELINE TEST REPORT                               ║")
        lines.append("║                    Session: \(sessionID.padding(toLength: 40, withPad: " ", startingAt: 0))║")
        lines.append("╠═══════════════════════════════════════════════════════════════════════════════╣")
        lines.append("")

        // Summary line for each stage
        func stageSummary(name: String, pass: Int, total: Int) -> String {
            let status = pass == total ? "✅" : "⚠️"
            return "\(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(pass)/\(total) passed \(status)"
        }

        lines.append(stageSummary(name: "L0_RAW TESTS:", pass: l0Results.passCount, total: l0Results.totalCount))
        lines.append(stageSummary(name: "L2_FRAMES TESTS:", pass: l2Results.passCount, total: l2Results.totalCount))
        lines.append(stageSummary(name: "L3_TENSOR TESTS:", pass: l3Results.passCount, total: l3Results.totalCount))
        lines.append(stageSummary(name: "L4_PALETTE TESTS:", pass: l4Results.passCount, total: l4Results.totalCount))
        lines.append(stageSummary(name: "L5_INDICES TESTS:", pass: l5Results.passCount, total: l5Results.totalCount))
        lines.append(stageSummary(name: "CROSS-STAGE TESTS:", pass: crossStageResults.passCount, total: crossStageResults.totalCount))
        lines.append(stageSummary(name: "END-TO-END TESTS:", pass: e2eResults.passCount, total: e2eResults.totalCount))
        lines.append("")
        lines.append("OVERALL: \(totalPassed)/\(totalTests) tests passed (\(String(format: "%.1f", passPercentage))%)")
        lines.append("")

        // Warnings
        if !warnings.isEmpty {
            lines.append("╠═══════════════════════════════════════════════════════════════════════════════╣")
            lines.append("║ WARNINGS (\(warnings.count))")
            lines.append("╠═══════════════════════════════════════════════════════════════════════════════╣")
            for warning in warnings {
                lines.append(warning)
            }
            lines.append("")
        }

        // Errors
        if !errors.isEmpty {
            lines.append("╠═══════════════════════════════════════════════════════════════════════════════╣")
            lines.append("║ ERRORS (\(errors.count))")
            lines.append("╠═══════════════════════════════════════════════════════════════════════════════╣")
            for error in errors {
                lines.append(error)
            }
            lines.append("")
        }

        lines.append("╚═══════════════════════════════════════════════════════════════════════════════╝")
        lines.append("")

        // Detailed stage reports
        lines.append(l0Results.generateReport())
        lines.append(l2Results.generateReport())
        lines.append(l3Results.generateReport())
        lines.append(l4Results.generateReport())
        lines.append(l5Results.generateReport())
        lines.append(crossStageResults.generateReport())
        lines.append(e2eResults.generateReport())

        // Synthetic verification tests (V.1, V.2)
        if !verificationTestOutput.isEmpty {
            lines.append("")
            lines.append(verificationTestOutput)
        }

        // GIF structure diagnostic
        if !gifDiagnosticOutput.isEmpty {
            lines.append("")
            lines.append(gifDiagnosticOutput)
        }

        // LZW encoder diagnostic
        if !lzwDiagnosticOutput.isEmpty {
            lines.append("")
            lines.append(lzwDiagnosticOutput)
        }

        // Visual verification prompt
        lines.append(generateVisualVerificationPrompt())

        return lines.joined(separator: "\n")
    }

    /// Generate visual verification prompt section
    private func generateVisualVerificationPrompt() -> String {
        """
        ╔═══════════════════════════════════════════════════════════════════════════════╗
        ║                    VISUAL VERIFICATION CHECKLIST                              ║
        ╠═══════════════════════════════════════════════════════════════════════════════╣
        ║                                                                               ║
        ║  Open these files in Finder/Preview to visually inspect the pipeline:        ║
        ║                                                                               ║
        ╠═══════════════════════════════════════════════════════════════════════════════╣
        ║  CHECK 1: Original Camera Input                                              ║
        ║  ─────────────────────────────────────────────────────────────────────────    ║
        ║  File: L0_raw/r40.png  (middle frame from raw capture)                        ║
        ║                                                                               ║
        ║  QUESTION: Is this image colorful or gray?                                    ║
        ║                                                                               ║
        ║  • If COLORFUL → The camera captured good input                               ║
        ║  • If GRAY → Scene/lighting issue OR camera bug (not pipeline)                ║
        ║                                                                               ║
        ╠═══════════════════════════════════════════════════════════════════════════════╣
        ║  CHECK 2: Crop & Resize Output                                                ║
        ║  ─────────────────────────────────────────────────────────────────────────    ║
        ║  File: L2_frames/f40.png  (after crop to 81×81)                               ║
        ║                                                                               ║
        ║  QUESTION: Does this match the center of r40.png?                             ║
        ║                                                                               ║
        ║  • If MATCHES → Crop/resize is working correctly                              ║
        ║  • If GRAY when r40 was colorful → BUG IN FrameFormatConverter                ║
        ║  • If DIFFERENT REGION → Crop offset calculation is wrong                     ║
        ║                                                                               ║
        ╠═══════════════════════════════════════════════════════════════════════════════╣
        ║  CHECK 3: Final GIF Output                                                    ║
        ║  ─────────────────────────────────────────────────────────────────────────    ║
        ║  File: L6_output/animation.gif                                                ║
        ║                                                                               ║
        ║  QUESTION: Does the GIF show the expected colors from r40.png?                ║
        ║                                                                               ║
        ║  • If MATCHES L2 → GIF encoding is correct                                    ║
        ║  • If GRAY when L2 was colorful → Bug in GIF palette/encoding                 ║
        ║                                                                               ║
        ╠═══════════════════════════════════════════════════════════════════════════════╣
        ║                                                                               ║
        ║  DIAGNOSIS FLOWCHART:                                                         ║
        ║                                                                               ║
        ║  r40.png gray? ──YES──> Camera/scene issue (not pipeline bug)                 ║
        ║       │                                                                       ║
        ║       NO                                                                      ║
        ║       ↓                                                                       ║
        ║  f40.png gray? ──YES──> BUG: FrameFormatConverter.swift                       ║
        ║       │                  (Check Y-flip, buffer stride, BGRA order)            ║
        ║       NO                                                                      ║
        ║       ↓                                                                       ║
        ║  GIF gray? ──YES──> BUG: GIF89aWriter or PaletteQuantizer                     ║
        ║       │              (Check palette generation, index mapping)                ║
        ║       NO                                                                      ║
        ║       ↓                                                                       ║
        ║  ✓ Pipeline is working correctly!                                             ║
        ║                                                                               ║
        ╚═══════════════════════════════════════════════════════════════════════════════╝

        """
    }
}

// MARK: - CBOR Pixel Sample (for diagnostic output)

@available(iOS 26.0, *)
public struct CBORPixelSample: CustomStringConvertible {
    public let x: Int
    public let y: Int
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
        self.x = x
        self.y = y
        self.r = r
        self.g = g
        self.b = b
    }

    /// Create from RGB data at given position
    public init(rgbData: Data, x: Int, y: Int, width: Int) {
        let offset = (y * width + x) * 3
        self.x = x
        self.y = y
        self.r = offset < rgbData.count ? rgbData[offset] : 0
        self.g = offset + 1 < rgbData.count ? rgbData[offset + 1] : 0
        self.b = offset + 2 < rgbData.count ? rgbData[offset + 2] : 0
    }

    public var description: String {
        "(\(x),\(y))=RGB(\(r),\(g),\(b))"
    }

    /// Color distance to another pixel (Euclidean in RGB space)
    public func distance(to other: CBORPixelSample) -> Double {
        let dr = Double(r) - Double(other.r)
        let dg = Double(g) - Double(other.g)
        let db = Double(b) - Double(other.b)
        return sqrt(dr*dr + dg*dg + db*db)
    }

    /// Approximate color name based on RGB values
    public var colorName: String {
        let max = Swift.max(r, g, b)
        let min = Swift.min(r, g, b)
        let brightness = (Double(r) + Double(g) + Double(b)) / 3.0

        if brightness < 30 { return "black" }
        if brightness > 225 && (max - min) < 30 { return "white" }
        if (max - min) < 30 { return "gray" }

        if r > g && r > b {
            if g > b * 2 { return "orange" }
            return "red"
        }
        if g > r && g > b { return "green" }
        if b > r && b > g { return "blue" }
        if r > 150 && g > 150 { return "yellow" }
        if r > 150 && b > 150 { return "magenta" }
        if g > 150 && b > 150 { return "cyan" }

        return "mixed"
    }
}

// MARK: - RGB Statistics

@available(iOS 26.0, *)
public struct RGBStatistics {
    public let minR: UInt8, maxR: UInt8, meanR: Double, stdDevR: Double
    public let minG: UInt8, maxG: UInt8, meanG: Double, stdDevG: Double
    public let minB: UInt8, maxB: UInt8, meanB: Double, stdDevB: Double
    public let uniqueColors: Int

    public init(rgbData: Data) {
        guard rgbData.count >= 3 else {
            self.minR = 0; self.maxR = 0; self.meanR = 0; self.stdDevR = 0
            self.minG = 0; self.maxG = 0; self.meanG = 0; self.stdDevG = 0
            self.minB = 0; self.maxB = 0; self.meanB = 0; self.stdDevB = 0
            self.uniqueColors = 0
            return
        }

        let pixelCount = rgbData.count / 3
        var sumR: Double = 0, sumG: Double = 0, sumB: Double = 0
        var minR: UInt8 = 255, maxR: UInt8 = 0
        var minG: UInt8 = 255, maxG: UInt8 = 0
        var minB: UInt8 = 255, maxB: UInt8 = 0
        var colors = Set<UInt32>()

        for i in 0..<pixelCount {
            let r = rgbData[i * 3]
            let g = rgbData[i * 3 + 1]
            let b = rgbData[i * 3 + 2]

            sumR += Double(r)
            sumG += Double(g)
            sumB += Double(b)

            minR = Swift.min(minR, r); maxR = Swift.max(maxR, r)
            minG = Swift.min(minG, g); maxG = Swift.max(maxG, g)
            minB = Swift.min(minB, b); maxB = Swift.max(maxB, b)

            colors.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
        }

        let meanR = sumR / Double(pixelCount)
        let meanG = sumG / Double(pixelCount)
        let meanB = sumB / Double(pixelCount)

        var varR: Double = 0, varG: Double = 0, varB: Double = 0
        for i in 0..<pixelCount {
            let r = Double(rgbData[i * 3])
            let g = Double(rgbData[i * 3 + 1])
            let b = Double(rgbData[i * 3 + 2])
            varR += (r - meanR) * (r - meanR)
            varG += (g - meanG) * (g - meanG)
            varB += (b - meanB) * (b - meanB)
        }

        self.minR = minR; self.maxR = maxR; self.meanR = meanR
        self.stdDevR = sqrt(varR / Double(pixelCount))
        self.minG = minG; self.maxG = maxG; self.meanG = meanG
        self.stdDevG = sqrt(varG / Double(pixelCount))
        self.minB = minB; self.maxB = maxB; self.meanB = meanB
        self.stdDevB = sqrt(varB / Double(pixelCount))
        self.uniqueColors = colors.count
    }

    public func diagnosticString() -> String {
        """
        RGB STATISTICS:
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ Channel │ Min │ Max │ Range │ Mean   │ StdDev │
        ├─────────────────────────────────────────────────────────────────────────────┤
        │ Red     │ \(String(format: "%3d", minR)) │ \(String(format: "%3d", maxR)) │ \(String(format: "%3d", Int(maxR) - Int(minR)))   │ \(String(format: "%6.1f", meanR)) │ \(String(format: "%5.1f", stdDevR))  │
        │ Green   │ \(String(format: "%3d", minG)) │ \(String(format: "%3d", maxG)) │ \(String(format: "%3d", Int(maxG) - Int(minG)))   │ \(String(format: "%6.1f", meanG)) │ \(String(format: "%5.1f", stdDevG))  │
        │ Blue    │ \(String(format: "%3d", minB)) │ \(String(format: "%3d", maxB)) │ \(String(format: "%3d", Int(maxB) - Int(minB)))   │ \(String(format: "%6.1f", meanB)) │ \(String(format: "%5.1f", stdDevB))  │
        └─────────────────────────────────────────────────────────────────────────────┘
        Unique colors: \(uniqueColors)
        """
    }
}
