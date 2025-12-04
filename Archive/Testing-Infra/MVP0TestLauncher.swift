//
//  MVP0TestLauncher.swift
//  RGB2GIF
//
//  ============================================================================
//  MVP0 TEST LAUNCHER: App-Integrated Test Runner
//  ============================================================================
//
//  PURPOSE: Launch MVP0 tests from within the app and output results to files
//           that can be retrieved from the simulator for review.
//
//  HOW TO USE:
//  ───────────
//  1. Build and run the app on the simulator
//  2. The tests will run automatically on launch
//  3. Results are written to the app's Documents directory
//  4. Use `xcrun simctl get_app_container` to find the path
//  5. Or check the console logs for the exact path
//
//  OUTPUT FILES:
//  ─────────────
//  - mvp0_test_results.json    → Full JSON report
//  - mvp0_test_summary.txt     → Human-readable summary
//  - output.gif                → Generated GIF file (per pattern)
//
//  ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "MVP0TestLauncher")

@available(iOS 26.0, *)
public final class MVP0TestLauncher {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Singleton
    // ════════════════════════════════════════════════════════════════════════

    public static let shared = MVP0TestLauncher()

    private init() {}

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Properties
    // ════════════════════════════════════════════════════════════════════════

    private let executor = MVP0PipelineExecutor()

    /// Documents directory for output
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Test output directory
    private var testOutputDirectory: URL {
        documentsDirectory.appendingPathComponent("MVP0_Tests")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Launch Tests
    // ════════════════════════════════════════════════════════════════════════

    /// Run all MVP0 tests and write results to documents.
    ///
    /// Call this from AppDelegate.didFinishLaunching or SceneDelegate.
    public func launchTests() {
        Task {
            await runAllTests()
        }
    }

    /// Run all tests asynchronously
    private func runAllTests() async {
        // Create output directory
        try? FileManager.default.createDirectory(
            at: testOutputDirectory,
            withIntermediateDirectories: true
        )

        print("""

        ╔═══════════════════════════════════════════════════════════════════════════╗
        ║                                                                           ║
        ║   ██████╗  ██████╗ ██████╗ ██████╗  ██████╗ ██╗███████╗                   ║
        ║   ██╔══██╗██╔════╝ ██╔══██╗╚════██╗██╔════╝ ██║██╔════╝                   ║
        ║   ██████╔╝██║  ███╗██████╔╝ █████╔╝██║  ███╗██║█████╗                     ║
        ║   ██╔══██╗██║   ██║██╔══██╗██╔═══╝ ██║   ██║██║██╔══╝                     ║
        ║   ██║  ██║╚██████╔╝██████╔╝███████╗╚██████╔╝██║██║                        ║
        ║   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚═╝╚═╝                        ║
        ║                                                                           ║
        ║   MVP0 TEST SUITE STARTING                                                ║
        ║                                                                           ║
        ║   Output directory:                                                       ║
        ║   \(testOutputDirectory.path.padding(toLength: 67, withPad: " ", startingAt: 0))║
        ║                                                                           ║
        ╚═══════════════════════════════════════════════════════════════════════════╝

        """)

        logger.info("MVP0 Test Suite starting. Output: \(self.testOutputDirectory.path)")

        var allResults = [MVP0PipelineExecutor.TestResult]()

        // Run tests for each pattern
        for pattern in SyntheticFrameGenerator.Pattern.allCases {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  TESTING: \(pattern.rawValue)")
            print("  Description: \(pattern.description)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

            let patternOutputDir = testOutputDirectory.appendingPathComponent(pattern.rawValue)

            let result = await executor.execute(
                pattern: pattern,
                outputDirectory: patternOutputDir
            )

            allResults.append(result)

            // Print stage results
            for stage in result.stages {
                let status = stage.success ? "✓" : "✗"
                let time = String(format: "%.1f ms", stage.durationMs)
                print("  \(status) \(stage.name.padding(toLength: 35, withPad: " ", startingAt: 0)) \(time)")
            }

            // Print test result
            let testStatus = result.success ? "✅ PASSED" : "❌ FAILED"
            print("  ─────────────────────────────────────────────────────────────────")
            print("  Result: \(testStatus)")
            print("")

            // Export JSON for this pattern
            let jsonURL = patternOutputDir.appendingPathComponent("result.json")
            try? await executor.exportJSON(result, to: jsonURL)
        }

        // Write combined results
        await writeCombinedResults(allResults)

        // Print summary
        printSummary(allResults)
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Output Writers
    // ════════════════════════════════════════════════════════════════════════

    private func writeCombinedResults(_ results: [MVP0PipelineExecutor.TestResult]) async {
        // Write JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let jsonData = try? encoder.encode(results) {
            let jsonURL = testOutputDirectory.appendingPathComponent("mvp0_test_results.json")
            try? jsonData.write(to: jsonURL)
            print("📄 JSON results: \(jsonURL.path)")
        }

        // Write human-readable summary
        var summary = """
        ═══════════════════════════════════════════════════════════════════════════
        RGB2GIF MVP0 TEST RESULTS
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        ═══════════════════════════════════════════════════════════════════════════


        """

        for result in results {
            summary += "PATTERN: \(result.pattern)\n"
            summary += "Status: \(result.success ? "PASSED" : "FAILED")\n"
            summary += "Total Time: \(String(format: "%.1f", result.summary.totalTimeMs)) ms\n"
            summary += "\n"

            summary += "STAGES:\n"
            for stage in result.stages {
                let status = stage.success ? "✓" : "✗"
                summary += "  \(status) \(stage.name): \(String(format: "%.1f", stage.durationMs)) ms\n"
            }
            summary += "\n"

            summary += "CELL ORGANIZATION:\n"
            summary += "  Cells: \(result.cellOrganization.totalCells)/\(result.cellOrganization.expectedCells)\n"
            summary += "  Feature Dimension: \(result.cellOrganization.featureDimension)\n"
            summary += "  Valid: \(result.cellOrganization.cellsValid && result.cellOrganization.featuresValid)\n"
            summary += "\n"

            summary += "COLOR STATISTICS:\n"
            summary += "  Unique Colors: \(result.colorStatistics.uniqueColorsFound)\n"
            summary += "  Global Colors: \(result.colorStatistics.globalColors)\n"
            summary += "  Localized Colors: \(result.colorStatistics.localizedColors)\n"
            summary += "  Exact Matches: \(result.colorStatistics.exactMatches)\n"
            summary += "  Similar Merges: \(result.colorStatistics.similarMerges)\n"
            summary += "\n"

            summary += "GIF VALIDATION:\n"
            summary += "  File Size: \(result.gifValidation.fileSize) bytes\n"
            summary += "  Dimensions: \(result.gifValidation.width)×\(result.gifValidation.height)\n"
            summary += "  Frame Count: \(result.gifValidation.frameCount)\n"
            summary += "  Valid: \(result.gifValidation.overallValid)\n"
            if !result.gifValidation.issues.isEmpty {
                summary += "  Issues: \(result.gifValidation.issues.joined(separator: ", "))\n"
            }
            summary += "\n"

            summary += "NN COMPATIBILITY:\n"
            summary += "  Digest Ready: \(result.nnCompatibility.digestReady)\n"
            summary += "  Cells Addressable: \(result.nnCompatibility.cellsAddressable)\n"
            summary += "  Spatial Slices: \(result.nnCompatibility.spatialSlicesWork)\n"
            summary += "  Temporal Slices: \(result.nnCompatibility.temporalSlicesWork)\n"
            summary += "  Weights Applicable: \(result.nnCompatibility.weightsApplicable)\n"
            summary += "  Projection Works: \(result.nnCompatibility.projectionWorks)\n"
            summary += "  Ready for MVP1: \(result.nnCompatibility.overallCompatible)\n"
            summary += "\n"
            summary += "───────────────────────────────────────────────────────────────────────────\n\n"
        }

        // Overall summary
        let passed = results.filter { $0.success }.count
        let total = results.count

        summary += """

        ═══════════════════════════════════════════════════════════════════════════
        OVERALL SUMMARY
        ═══════════════════════════════════════════════════════════════════════════

        Tests Passed: \(passed)/\(total)
        All NN Compatible: \(results.allSatisfy { $0.nnCompatibility.overallCompatible })
        Ready for MVP1: \(passed == total && results.allSatisfy { $0.nnCompatibility.overallCompatible })

        Output Directory: \(testOutputDirectory.path)

        TO RETRIEVE FILES FROM SIMULATOR:
          xcrun simctl get_app_container booted com.rgb2gif data

        ═══════════════════════════════════════════════════════════════════════════
        """

        let summaryURL = testOutputDirectory.appendingPathComponent("mvp0_test_summary.txt")
        try? summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        print("📄 Summary: \(summaryURL.path)")
    }

    private func printSummary(_ results: [MVP0PipelineExecutor.TestResult]) {
        let passed = results.filter { $0.success }.count
        let total = results.count

        print("""

        ╔═══════════════════════════════════════════════════════════════════════════╗
        ║                          TEST SUITE COMPLETE                              ║
        ╠═══════════════════════════════════════════════════════════════════════════╣
        ║                                                                           ║
        """)

        for result in results {
            let status = result.success ? "✅" : "❌"
            let pattern = result.pattern.padding(toLength: 20, withPad: " ", startingAt: 0)
            let time = String(format: "%6.0f ms", result.summary.totalTimeMs)
            print("║  \(status) \(pattern) \(time)                                       ║")
        }

        print("""
        ║                                                                           ║
        ╠═══════════════════════════════════════════════════════════════════════════╣
        ║                                                                           ║
        ║  PASSED: \(passed)/\(total)                                                            ║
        ║                                                                           ║
        ║  Output: \(testOutputDirectory.path.padding(toLength: 61, withPad: " ", startingAt: 0))║
        ║                                                                           ║
        ║  To retrieve from simulator:                                              ║
        ║    xcrun simctl get_app_container booted com.rgb2gif data                 ║
        ║                                                                           ║
        ╚═══════════════════════════════════════════════════════════════════════════╝

        """)

        // Log for easy copy-paste
        logger.info("""
        MVP0 Tests Complete. Results at:
        \(self.testOutputDirectory.path)
        """)
    }
}
