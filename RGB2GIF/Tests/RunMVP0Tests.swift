//
//  RunMVP0Tests.swift
//  RGB2GIF Tests
//
//  ============================================================================
//  MVP0 TEST RUNNER: Execute Pipeline Validation Tests
//  ============================================================================
//
//  This is a standalone test runner that can be executed to validate the
//  entire MVP0 pipeline without requiring a full app build.
//
//  HOW TO RUN:
//  -----------
//  Option 1: From Xcode
//    - Add this file to the test target
//    - Run the test target
//
//  Option 2: From command line (Swift 6.2 required)
//    cd /Users/daniel/RGB2GIF
//    swift run RGB2GIFTests
//
//  WHAT IT TESTS:
//  --------------
//  1. Frame generation (synthetic patterns)
//  2. MacroCellDigest computation (729 embeddings)
//  3. Weighted palette building (256 colors)
//  4. GIF writing and validation
//  5. Compatibility check for future NN games
//
//  ============================================================================

import Foundation

@available(iOS 26.0, macOS 15.0, *)
@main
struct MVP0TestRunner {

    static func main() async {
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
        ║   MVP0 PIPELINE VALIDATION TEST SUITE                                     ║
        ║                                                                           ║
        ║   Testing: Frame Generation → Digest → Palette → GIF                      ║
        ║                                                                           ║
        ╚═══════════════════════════════════════════════════════════════════════════╝

        """)

        // Create output directory
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RGB2GIF_MVP0_Tests")
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()))

        do {
            try FileManager.default.createDirectory(
                at: outputDir,
                withIntermediateDirectories: true
            )
            print("📁 Output directory: \(outputDir.path)\n")
        } catch {
            print("❌ Failed to create output directory: \(error)")
            return
        }

        // Run all tests
        do {
            let reports = try await GIF81TestHarness.runAllTests(outputDirectory: outputDir)

            // Summary
            let passed = reports.filter { $0.isSuccess }.count
            let total = reports.count

            print("\n")
            if passed == total {
                print("✅ ALL TESTS PASSED (\(passed)/\(total))")
                print("\n📁 Output files saved to:")
                print("   \(outputDir.path)")
                print("\n🔍 To view in Safari, run:")
                print("   open \(outputDir.path)")
            } else {
                print("⚠️ SOME TESTS FAILED (\(passed)/\(total) passed)")
                for report in reports where !report.isSuccess {
                    print("   ❌ \(report.pattern.rawValue)")
                }
            }

        } catch {
            print("❌ Test suite failed: \(error)")
        }
    }
}

// MARK: - Alternative Entry Point for XCTest

#if canImport(XCTest)
import XCTest

@available(iOS 26.0, macOS 15.0, *)
final class MVP0PipelineTests: XCTestCase {

    var outputDirectory: URL!

    override func setUp() async throws {
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RGB2GIF_MVP0_Tests")
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        // Optionally clean up test output
        // try? FileManager.default.removeItem(at: outputDirectory)
    }

    func testGradientPattern() async throws {
        let report = try await GIF81TestHarness.runPipelineTest(
            pattern: .gradient,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(report.isSuccess, "Gradient pattern should produce valid GIF")
        XCTAssertEqual(report.frameCount, 81)
        XCTAssertEqual(report.cellCount, 729)
        XCTAssertTrue(report.digestValidForNN)
    }

    func testCheckerboardPattern() async throws {
        let report = try await GIF81TestHarness.runPipelineTest(
            pattern: .checkerboard,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(report.isSuccess)
    }

    func testSolidColorsPattern() async throws {
        let report = try await GIF81TestHarness.runPipelineTest(
            pattern: .solidColors,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(report.isSuccess)
    }

    func testConcentricRingsPattern() async throws {
        let report = try await GIF81TestHarness.runPipelineTest(
            pattern: .concentricRings,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(report.isSuccess)
    }

    func testTemporalWavePattern() async throws {
        let report = try await GIF81TestHarness.runPipelineTest(
            pattern: .temporalWave,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(report.isSuccess)
    }

    func testRainbowTilesPattern() async throws {
        let report = try await GIF81TestHarness.runPipelineTest(
            pattern: .rainbowTiles,
            outputDirectory: outputDirectory
        )
        XCTAssertTrue(report.isSuccess)
        // This pattern specifically tests macro-cell boundaries
        XCTAssertTrue(report.uniqueColorsInPalette >= 80, "Rainbow tiles should have diverse palette")
    }

    func testDigestCompatibilityForNNGames() async throws {
        // Generate frames
        let frames = try GIF81TestHarness.generateFrames(pattern: .gradient)

        // Compute digest
        let digest = try MacroCellDigest.compute(from: frames)

        // Verify digest structure
        XCTAssertEqual(digest.cells.count, 729, "Must have exactly 729 macro-cells")

        // Verify each cell has valid features
        for cell in digest.cells {
            let vector = cell.toVector()
            XCTAssertEqual(vector.count, MacroCellDigest.featureDimension)

            // No NaN or Inf
            XCTAssertFalse(vector.contains { $0.isNaN || $0.isInfinite })

            // All histograms should sum to ~1.0
            let lumSum = cell.luminanceHistogram.reduce(0, +)
            XCTAssertEqual(lumSum, 1.0, accuracy: 0.01, "Luminance histogram should sum to 1")
        }

        // Verify we can query by address (required for GO game integration)
        let centerCell = digest.cell(tileRow: 4, tileCol: 4, timeGroup: 4)
        XCTAssertEqual(centerCell.tileRow, 4)
        XCTAssertEqual(centerCell.tileCol, 4)
        XCTAssertEqual(centerCell.timeGroup, 4)

        // Verify slicing works (required for temporal/spatial game separation)
        let spatialSlice = digest.spatialSlice(tileRow: 4, tileCol: 4)
        XCTAssertEqual(spatialSlice.count, 9, "Spatial slice should have 9 time groups")

        let temporalSlice = digest.temporalSlice(timeGroup: 4)
        XCTAssertEqual(temporalSlice.count, 81, "Temporal slice should have 81 tiles")
    }

    func testUniformWeightsForMVP0() async throws {
        // MVP0 uses uniform weights (no games)
        let weights = DualGameWeights(strategy: .geometric)

        // All weights should be 0.5
        for row in 0..<9 {
            for col in 0..<9 {
                XCTAssertEqual(weights.spatialWeights[row][col], 0.5)
                XCTAssertEqual(weights.temporalWeights[row][col], 0.5)
            }
        }

        // Merged weight with geometric should also be 0.5
        let merged = weights.weight(tileRow: 4, tileCol: 4, timeGroup: 4)
        XCTAssertEqual(merged, 0.5, accuracy: 0.01)
    }
}
#endif
