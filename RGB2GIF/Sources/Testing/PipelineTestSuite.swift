//
//  PipelineTestSuite.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  CBOR-BASED PIPELINE TEST SUITE                                          ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Comprehensive testing for ALL pipeline stages:                          ║
//  ║  • L0_raw:     Raw camera frames (BGRA, any size)                        ║
//  ║  • L2_frames:  RGB 81×81 frames                                          ║
//  ║  • L3_tensor:  729 weighted centroid cells                               ║
//  ║  • L4_palette: 256-color palette + mapping                               ║
//  ║  • L5_indices: Palette indices for all pixels                            ║
//  ║  • Cross-stage: Data consistency validation                              ║
//  ║  • End-to-end: Overall pipeline sanity checks                            ║
//  ║                                                                           ║
//  ║  All tests output TEXT for programmatic analysis.                        ║
//  ║  No GIF viewing required - all diagnostics in text.                      ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import os.log

private let suiteLogger = Logger(subsystem: "com.rgb2gif.tests", category: "PipelineTestSuite")

@available(iOS 26.0, *)
public struct PipelineTestSuite {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    /// Run comprehensive pipeline tests and return full report
    public func runAllTests() async -> PipelineTestReport {
        var report = PipelineTestReport(sessionID: session.sessionID)
        let startTime = Date()

        suiteLogger.info("═══════════════════════════════════════════════════════════════════════════════")
        suiteLogger.info("Starting CBOR-based pipeline test suite for session: \(session.sessionID)")
        suiteLogger.info("═══════════════════════════════════════════════════════════════════════════════")

        // Run each stage's tests
        suiteLogger.info("Running L0_RAW tests...")
        report.l0Results = await L0RawTests(session: session).run()
        suiteLogger.info("L0_RAW: \(report.l0Results.passCount)/\(report.l0Results.totalCount) passed")

        suiteLogger.info("Running L2_FRAMES tests...")
        report.l2Results = await L2FrameTests(session: session).run()
        suiteLogger.info("L2_FRAMES: \(report.l2Results.passCount)/\(report.l2Results.totalCount) passed")

        suiteLogger.info("Running L3_TENSOR tests...")
        report.l3Results = await L3TensorTests(session: session).run()
        suiteLogger.info("L3_TENSOR: \(report.l3Results.passCount)/\(report.l3Results.totalCount) passed")

        suiteLogger.info("Running L4_PALETTE tests...")
        report.l4Results = await L4PaletteTests(session: session).run()
        suiteLogger.info("L4_PALETTE: \(report.l4Results.passCount)/\(report.l4Results.totalCount) passed")

        suiteLogger.info("Running L5_INDICES tests...")
        report.l5Results = await L5IndicesTests(session: session).run()
        suiteLogger.info("L5_INDICES: \(report.l5Results.passCount)/\(report.l5Results.totalCount) passed")

        suiteLogger.info("Running CROSS-STAGE tests...")
        report.crossStageResults = await CrossStageTests(session: session).run()
        suiteLogger.info("CROSS-STAGE: \(report.crossStageResults.passCount)/\(report.crossStageResults.totalCount) passed")

        suiteLogger.info("Running END-TO-END tests...")
        report.e2eResults = await runEndToEndTests()
        suiteLogger.info("END-TO-END: \(report.e2eResults.passCount)/\(report.e2eResults.totalCount) passed")

        // Run synthetic verification tests (V.1, V.2)
        suiteLogger.info("Running VERIFICATION tests (synthetic crop/resize)...")
        report.verificationTestOutput = CropResizeVerificationTests.runAllTests()
        suiteLogger.info("VERIFICATION tests complete")

        // Run GIF structure diagnostic
        suiteLogger.info("Running GIF STRUCTURE DIAGNOSTIC...")
        report.gifDiagnosticOutput = GIFStructureDiagnostic.diagnoseSession(session)
        suiteLogger.info("GIF diagnostic complete")

        // Run LZW encoder diagnostic tests
        suiteLogger.info("Running LZW ENCODER DIAGNOSTIC tests...")
        let lzwReport = LZWDiagnosticTests.runAllTests()
        report.lzwDiagnosticOutput = LZWDiagnosticTests.generateReport(lzwReport)
        suiteLogger.info("LZW DIAGNOSTIC: \(lzwReport.passCount)/\(lzwReport.totalCount) tests passed")

        // Collect warnings
        collectWarnings(&report)

        let duration = Date().timeIntervalSince(startTime)
        suiteLogger.info("═══════════════════════════════════════════════════════════════════════════════")
        suiteLogger.info("Test suite complete in \(String(format: "%.1f", duration)) seconds")
        suiteLogger.info("OVERALL: \(report.totalPassed)/\(report.totalTests) tests passed (\(String(format: "%.1f", report.passPercentage))%)")
        suiteLogger.info("═══════════════════════════════════════════════════════════════════════════════")

        return report
    }

    // MARK: - End-to-End Tests

    private func runEndToEndTests() async -> EndToEndTestResults {
        var results = EndToEndTestResults()
        let fm = FileManager.default

        // E2E.1: Session Integrity
        let l0Exists = fm.fileExists(atPath: session.l0RawURL.path)
        let l2Exists = fm.fileExists(atPath: session.l2FramesURL.path)
        let l3Exists = fm.fileExists(atPath: session.l3TensorURL.path)
        let l4Exists = fm.fileExists(atPath: session.l4PaletteURL.path)
        let l5Exists = fm.fileExists(atPath: session.l5IndicesURL.path)
        let l6Exists = fm.fileExists(atPath: session.l6OutputURL.path)

        let allDirsExist = l0Exists && l2Exists && l3Exists && l4Exists && l5Exists && l6Exists

        results.tests.append(CBORTestResult(
            id: "E2E.1",
            name: "Session Integrity",
            passed: allDirsExist,
            expected: "All stage directories exist",
            actual: allDirsExist ? "All present" : "Missing directories",
            details: "L0:\(l0Exists ? "✓" : "✗") L2:\(l2Exists ? "✓" : "✗") L3:\(l3Exists ? "✓" : "✗") L4:\(l4Exists ? "✓" : "✗") L5:\(l5Exists ? "✓" : "✗") L6:\(l6Exists ? "✓" : "✗")"
        ))

        // E2E.2: File Counts
        let l0Count = countCBORFiles(at: session.l0RawURL)
        let l2Count = countCBORFiles(at: session.l2FramesURL)
        let l3Count = countCBORFiles(at: session.l3TensorCellsURL)
        let l4Count = countCBORFiles(at: session.l4PaletteURL)
        let l5Count = countCBORFiles(at: session.l5IndicesURL)

        let expectedL0 = 81, expectedL2 = 81, expectedL3 = 729, expectedL4 = 2, expectedL5 = 81
        let allCountsCorrect = l0Count == expectedL0 && l2Count == expectedL2 && l3Count >= expectedL3 && l4Count == expectedL4 && l5Count == expectedL5

        results.tests.append(CBORTestResult(
            id: "E2E.2",
            name: "File Counts",
            passed: allCountsCorrect,
            expected: "L0:\(expectedL0) L2:\(expectedL2) L3:≥\(expectedL3) L4:\(expectedL4) L5:\(expectedL5)",
            actual: "L0:\(l0Count) L2:\(l2Count) L3:\(l3Count) L4:\(l4Count) L5:\(l5Count)",
            details: allCountsCorrect ? "All file counts match" : "Some counts incorrect"
        ))

        // E2E.3: Manifest Valid (if exists)
        let manifestExists = fm.fileExists(atPath: session.manifestURL.path)
        results.tests.append(CBORTestResult(
            id: "E2E.3",
            name: "Manifest Valid",
            passed: true,  // Optional
            expected: "manifest.cbor present (optional)",
            actual: manifestExists ? "Present" : "Not present",
            details: "Manifest file is optional but recommended"
        ))

        // E2E.4: GIF Exists
        let gifExists = fm.fileExists(atPath: session.gifOutputURL.path)
        results.tests.append(CBORTestResult(
            id: "E2E.4",
            name: "GIF Exists",
            passed: gifExists,
            expected: "animation.gif in L6_output",
            actual: gifExists ? "Present" : "Missing",
            details: gifExists ? "GIF file found" : "GIF not generated"
        ))

        // E2E.5: GIF Size (if exists)
        if gifExists,
           let attrs = try? fm.attributesOfItem(atPath: session.gifOutputURL.path),
           let size = attrs[.size] as? Int64 {
            let sizeKB = size / 1024
            let reasonable = size > 1000 && size < 50_000_000  // 1KB to 50MB

            results.tests.append(CBORTestResult(
                id: "E2E.5",
                name: "GIF Size",
                passed: reasonable,
                expected: "1KB - 50MB",
                actual: "\(sizeKB) KB",
                details: reasonable ? "GIF size reasonable" : "GIF size unusual"
            ))
        } else {
            results.tests.append(CBORTestResult(
                id: "E2E.5",
                name: "GIF Size",
                passed: false,
                expected: "1KB - 50MB",
                actual: "Cannot read",
                details: "GIF file not accessible"
            ))
        }

        // E2E.6: Session Size
        let sessionSize = session.sessionSize()
        let sizeMB = Double(sessionSize) / (1024 * 1024)

        results.tests.append(CBORTestResult(
            id: "E2E.6",
            name: "Session Size",
            passed: sessionSize > 0,
            expected: "Non-zero size",
            actual: String(format: "%.1f MB", sizeMB),
            details: "Total session storage"
        ))

        // E2E.7: LZW Stats (if exists)
        let lzwStatsExists = fm.fileExists(atPath: session.lzwStatsURL.path)
        results.tests.append(CBORTestResult(
            id: "E2E.7",
            name: "LZW Stats",
            passed: true,  // Informational
            expected: "stats.cbor (optional)",
            actual: lzwStatsExists ? "Present" : "Not present",
            details: "LZW compression statistics"
        ))

        // E2E.8: Overall Pipeline Success
        let pipelineSuccess = allDirsExist && gifExists && allCountsCorrect
        results.tests.append(CBORTestResult(
            id: "E2E.8",
            name: "Pipeline Success",
            passed: pipelineSuccess,
            expected: "All stages complete",
            actual: pipelineSuccess ? "SUCCESS" : "INCOMPLETE",
            details: pipelineSuccess ? "Full pipeline executed successfully" : "Pipeline incomplete"
        ))

        return results
    }

    // MARK: - Helpers

    private func countCBORFiles(at url: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return 0
        }
        return contents.filter { $0.pathExtension == "cbor" }.count
    }

    private func collectWarnings(_ report: inout PipelineTestReport) {
        // Collect failed tests as warnings
        let allTests = [
            report.l0Results.tests,
            report.l2Results.tests,
            report.l3Results.tests,
            report.l4Results.tests,
            report.l5Results.tests,
            report.crossStageResults.tests,
            report.e2eResults.tests
        ].flatMap { $0 }

        for test in allTests where !test.passed {
            report.warnings.append("\(test.id) \(test.name): \(test.actual)")
        }
    }
}

// MARK: - Quick Test Runner

@available(iOS 26.0, *)
public extension PipelineTestSuite {

    /// Run tests for a specific stage only
    enum Stage {
        case l0Raw
        case l2Frames
        case l3Tensor
        case l4Palette
        case l5Indices
        case crossStage
        case e2e
    }

    /// Run a single stage's tests
    func runStageTests(_ stage: Stage) async -> StageTestResults {
        switch stage {
        case .l0Raw:
            return await L0RawTests(session: session).run()
        case .l2Frames:
            return await L2FrameTests(session: session).run()
        case .l3Tensor:
            return await L3TensorTests(session: session).run()
        case .l4Palette:
            return await L4PaletteTests(session: session).run()
        case .l5Indices:
            return await L5IndicesTests(session: session).run()
        case .crossStage:
            let results = await CrossStageTests(session: session).run()
            return StageTestResults(stageName: "CROSS_STAGE")  // Convert
        case .e2e:
            return StageTestResults(stageName: "END_TO_END")  // Run full E2E
        }
    }

    /// Generate a quick summary string
    func quickSummary(from report: PipelineTestReport) -> String {
        """
        ═══════════════════════════════════════════════════════════════════════════════
        RGB2GIF PIPELINE TEST SUMMARY
        Session: \(report.sessionID)
        ═══════════════════════════════════════════════════════════════════════════════

        L0_RAW:       \(report.l0Results.passCount)/\(report.l0Results.totalCount) \(report.l0Results.allPassed ? "✅" : "⚠️")
        L2_FRAMES:    \(report.l2Results.passCount)/\(report.l2Results.totalCount) \(report.l2Results.allPassed ? "✅" : "⚠️")
        L3_TENSOR:    \(report.l3Results.passCount)/\(report.l3Results.totalCount) \(report.l3Results.allPassed ? "✅" : "⚠️")
        L4_PALETTE:   \(report.l4Results.passCount)/\(report.l4Results.totalCount) \(report.l4Results.allPassed ? "✅" : "⚠️")
        L5_INDICES:   \(report.l5Results.passCount)/\(report.l5Results.totalCount) \(report.l5Results.allPassed ? "✅" : "⚠️")
        CROSS-STAGE:  \(report.crossStageResults.passCount)/\(report.crossStageResults.totalCount) \(report.crossStageResults.allPassed ? "✅" : "⚠️")
        END-TO-END:   \(report.e2eResults.passCount)/\(report.e2eResults.totalCount) \(report.e2eResults.allPassed ? "✅" : "⚠️")

        ═══════════════════════════════════════════════════════════════════════════════
        OVERALL: \(report.totalPassed)/\(report.totalTests) (\(String(format: "%.1f", report.passPercentage))%)
        ═══════════════════════════════════════════════════════════════════════════════
        """
    }
}
