//
//  MVP0PipelineExecutor.swift
//  RGB2GIF
//
//  ============================================================================
//  MVP0 PIPELINE EXECUTOR: Complete Test Runner with JSON Output
//  ============================================================================
//
//  PURPOSE: Execute the full MVP0 pipeline and output detailed results that
//           can be captured and reviewed by Claude Code or other tools.
//
//  EXECUTION FLOW
//  ──────────────
//  1. Generate synthetic frames (81 frames × 81×81 pixels)
//  2. Compute MacroCellDigest (729 cells × 81 features = 59,049 total)
//  3. Build ColorVectorSpace (732D per unique color)
//  4. Select dual palettes (256 spatial + 256 temporal)
//  5. Merge via CIEDE2000 → final 256 colors
//  6. Write GIF89a file
//  7. Validate structure
//  8. Output JSON report
//
//  OUTPUT FORMAT
//  ─────────────
//  The executor outputs a JSON report containing:
//  - Pattern used
//  - Timing for each stage
//  - Cell organization validation
//  - Color statistics
//  - GIF validation results
//  - NN compatibility check
//
//  This JSON can be read by Claude Code to verify correctness.
//
//  ============================================================================

import Foundation
import CoreGraphics

@available(iOS 26.0, *)
public actor MVP0PipelineExecutor {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Result Types
    // ════════════════════════════════════════════════════════════════════════

    /// Complete test result for JSON output
    public struct TestResult: Codable {
        public let testId: String
        public let timestamp: String
        public let pattern: String
        public let success: Bool
        public let stages: [StageResult]
        public let cellOrganization: CellOrganizationReport
        public let colorStatistics: ColorStatisticsReport
        public let gifValidation: GIFValidationReport
        public let nnCompatibility: NNCompatibilityReport
        public let summary: SummaryReport
    }

    public struct StageResult: Codable {
        public let name: String
        public let durationMs: Double
        public let success: Bool
        public let details: [String: String]
    }

    public struct CellOrganizationReport: Codable {
        public let totalCells: Int
        public let expectedCells: Int
        public let cellsValid: Bool
        public let featureDimension: Int
        public let expectedFeatureDimension: Int
        public let featuresValid: Bool
        public let sampleCells: [CellSample]
    }

    public struct CellSample: Codable {
        public let timeGroup: Int
        public let tileRow: Int
        public let tileCol: Int
        public let cellIndex: Int
        public let featureCount: Int
        public let luminanceHistogramSum: Float
        public let hueHistogramSum: Float
    }

    public struct ColorStatisticsReport: Codable {
        public let uniqueColorsFound: Int
        public let maxPossibleColors: Int
        public let colorDensity: Float
        public let globalColors: Int
        public let localizedColors: Int
        public let stableColors: Int
        public let transientColors: Int
        public let spatialPaletteSize: Int
        public let temporalPaletteSize: Int
        public let finalPaletteSize: Int
        public let exactMatches: Int
        public let similarMerges: Int
    }

    public struct GIFValidationReport: Codable {
        public let fileSize: Int
        public let headerValid: Bool
        public let dimensionsValid: Bool
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let paletteSize: Int
        public let hasNetscapeExtension: Bool
        public let hasTrailer: Bool
        public let overallValid: Bool
        public let issues: [String]
    }

    public struct NNCompatibilityReport: Codable {
        public let digestReady: Bool
        public let cellsAddressable: Bool
        public let spatialSlicesWork: Bool
        public let temporalSlicesWork: Bool
        public let weightsApplicable: Bool
        public let projectionWorks: Bool
        public let overallCompatible: Bool
        public let issues: [String]
    }

    public struct SummaryReport: Codable {
        public let totalTimeMs: Double
        public let allStagesSucceeded: Bool
        public let gifWritten: Bool
        public let gifPath: String
        public let testPassed: Bool
        public let readyForMVP1: Bool
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Execution
    // ════════════════════════════════════════════════════════════════════════

    /// Execute the complete MVP0 pipeline and return detailed results.
    public func execute(
        pattern: SyntheticFrameGenerator.Pattern,
        outputDirectory: URL
    ) async -> TestResult {
        let testId = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var stages = [StageResult]()
        let overallStart = Date()

        // Create output directory
        let testOutputDir = outputDirectory.appendingPathComponent(testId)
        try? FileManager.default.createDirectory(at: testOutputDir, withIntermediateDirectories: true)

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 1: Generate Frames
        // ──────────────────────────────────────────────────────────────────────
        let stage1Start = Date()
        var frames: [CGImage] = []
        var stage1Success = false
        var stage1Details = [String: String]()

        do {
            frames = try SyntheticFrameGenerator.generateFrames(pattern: pattern)
            stage1Success = frames.count == 81
            stage1Details["frameCount"] = "\(frames.count)"
            stage1Details["frameSize"] = "81x81"
            stage1Details["pattern"] = pattern.rawValue
        } catch {
            stage1Details["error"] = error.localizedDescription
        }

        stages.append(StageResult(
            name: "Frame Generation",
            durationMs: Date().timeIntervalSince(stage1Start) * 1000,
            success: stage1Success,
            details: stage1Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 2: Compute MacroCellDigest
        // ──────────────────────────────────────────────────────────────────────
        let stage2Start = Date()
        var digest: MacroCellDigest?
        var stage2Success = false
        var stage2Details = [String: String]()

        if stage1Success {
            do {
                digest = try MacroCellDigest.compute(from: frames)
                stage2Success = digest?.cells.count == 729
                stage2Details["cellCount"] = "\(digest?.cells.count ?? 0)"
                stage2Details["featureDimension"] = "\(MacroCellDigest.featureDimension)"
                stage2Details["totalFeatures"] = "\(729 * MacroCellDigest.featureDimension)"
            } catch {
                stage2Details["error"] = error.localizedDescription
            }
        } else {
            stage2Details["skipped"] = "Previous stage failed"
        }

        stages.append(StageResult(
            name: "MacroCellDigest Computation",
            durationMs: Date().timeIntervalSince(stage2Start) * 1000,
            success: stage2Success,
            details: stage2Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 3: Build ColorVectorSpace
        // ──────────────────────────────────────────────────────────────────────
        let stage3Start = Date()
        var colorSpace: ColorVectorSpace?
        var stage3Success = false
        var stage3Details = [String: String]()

        if stage1Success {
            do {
                colorSpace = try ColorVectorSpace.build(from: frames)
                stage3Success = colorSpace != nil
                stage3Details["uniqueColors"] = "\(colorSpace?.uniqueColorCount ?? 0)"
                stage3Details["dimensions"] = "732 (3 RGB + 729 cell presence)"
            } catch {
                stage3Details["error"] = error.localizedDescription
            }
        } else {
            stage3Details["skipped"] = "Stage 1 failed"
        }

        stages.append(StageResult(
            name: "ColorVectorSpace Construction",
            durationMs: Date().timeIntervalSince(stage3Start) * 1000,
            success: stage3Success,
            details: stage3Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 4: Select Dual Palettes
        // ──────────────────────────────────────────────────────────────────────
        let stage4Start = Date()
        var spatialPalette: ColorVectorSpace.ScoredPalette = []
        var temporalPalette: ColorVectorSpace.ScoredPalette = []
        var stage4Success = false
        var stage4Details = [String: String]()

        if let cs = colorSpace {
            // MVP0: Uniform weights (0.5 everywhere)
            let uniformWeights = [[Float]](
                repeating: [Float](repeating: 0.5, count: 9),
                count: 9
            )

            let palettes = cs.selectBothPalettes(
                spatialWeights: uniformWeights,
                temporalWeights: uniformWeights
            )
            spatialPalette = palettes.spatial
            temporalPalette = palettes.temporal
            stage4Success = spatialPalette.count == 256 && temporalPalette.count == 256
            stage4Details["spatialPaletteSize"] = "\(spatialPalette.count)"
            stage4Details["temporalPaletteSize"] = "\(temporalPalette.count)"
            stage4Details["weightStrategy"] = "uniform (0.5)"
        } else {
            stage4Details["skipped"] = "ColorVectorSpace not available"
        }

        stages.append(StageResult(
            name: "Dual Palette Selection",
            durationMs: Date().timeIntervalSince(stage4Start) * 1000,
            success: stage4Success,
            details: stage4Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 5: Merge Palettes (CIEDE2000)
        // ──────────────────────────────────────────────────────────────────────
        let stage5Start = Date()
        var finalPalette: [(UInt8, UInt8, UInt8)] = []
        var exactMatches = 0
        var similarMerges = 0
        var stage5Success = false
        var stage5Details = [String: String]()

        if stage4Success {
            let mergeStats = ColorMerger.analyzeMerge(
                spatialPalette: spatialPalette,
                temporalPalette: temporalPalette
            )
            exactMatches = mergeStats.exactMatches
            similarMerges = mergeStats.similarMerges

            finalPalette = ColorMerger.merge(
                spatialPalette: spatialPalette,
                temporalPalette: temporalPalette
            )

            stage5Success = finalPalette.count == 256
            stage5Details["finalPaletteSize"] = "\(finalPalette.count)"
            stage5Details["exactMatches"] = "\(exactMatches)"
            stage5Details["similarMerges"] = "\(similarMerges)"
            stage5Details["agreementRate"] = String(format: "%.1f%%", mergeStats.agreementRate * 100)
        } else {
            stage5Details["skipped"] = "Dual palettes not available"
        }

        stages.append(StageResult(
            name: "Palette Merge (CIEDE2000)",
            durationMs: Date().timeIntervalSince(stage5Start) * 1000,
            success: stage5Success,
            details: stage5Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 6: Index Frames to Palette
        // ──────────────────────────────────────────────────────────────────────
        let stage6Start = Date()
        var indexedFrames: [[UInt8]] = []
        var stage6Success = false
        var stage6Details = [String: String]()

        if stage5Success && stage1Success {
            indexedFrames = indexFramesToPalette(frames: frames, palette: finalPalette)
            stage6Success = indexedFrames.count == 81 && indexedFrames.allSatisfy { $0.count == 6561 }
            stage6Details["indexedFrameCount"] = "\(indexedFrames.count)"
            stage6Details["pixelsPerFrame"] = "\(indexedFrames.first?.count ?? 0)"
        } else {
            stage6Details["skipped"] = "Palette or frames not available"
        }

        stages.append(StageResult(
            name: "Frame Indexing",
            durationMs: Date().timeIntervalSince(stage6Start) * 1000,
            success: stage6Success,
            details: stage6Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // STAGE 7: Write GIF
        // ──────────────────────────────────────────────────────────────────────
        let stage7Start = Date()
        let gifURL = testOutputDir.appendingPathComponent("output.gif")
        var stage7Success = false
        var stage7Details = [String: String]()

        if stage6Success {
            do {
                let gifPalette = finalPalette.map { (r: $0.0, g: $0.1, b: $0.2) }
                try GIF81Writer.write(
                    frames: indexedFrames,
                    palette: gifPalette,
                    to: gifURL,
                    frameDelay: 3
                )
                stage7Success = FileManager.default.fileExists(atPath: gifURL.path)
                stage7Details["outputPath"] = gifURL.path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: gifURL.path),
                   let size = attrs[.size] as? Int {
                    stage7Details["fileSize"] = "\(size) bytes"
                }
            } catch {
                stage7Details["error"] = error.localizedDescription
            }
        } else {
            stage7Details["skipped"] = "Indexed frames not available"
        }

        stages.append(StageResult(
            name: "GIF Writing",
            durationMs: Date().timeIntervalSince(stage7Start) * 1000,
            success: stage7Success,
            details: stage7Details
        ))

        // ──────────────────────────────────────────────────────────────────────
        // BUILD REPORTS
        // ──────────────────────────────────────────────────────────────────────

        let cellReport = buildCellOrganizationReport(digest: digest)
        let colorReport = buildColorStatisticsReport(
            colorSpace: colorSpace,
            spatialPalette: spatialPalette,
            temporalPalette: temporalPalette,
            finalPalette: finalPalette,
            exactMatches: exactMatches,
            similarMerges: similarMerges
        )
        let gifReport = buildGIFValidationReport(gifURL: gifURL)
        let nnReport = buildNNCompatibilityReport(digest: digest, colorSpace: colorSpace)

        let totalTimeMs = Date().timeIntervalSince(overallStart) * 1000
        let allStagesSucceeded = stages.allSatisfy { $0.success }

        let summary = SummaryReport(
            totalTimeMs: totalTimeMs,
            allStagesSucceeded: allStagesSucceeded,
            gifWritten: stage7Success,
            gifPath: gifURL.path,
            testPassed: allStagesSucceeded && gifReport.overallValid && nnReport.overallCompatible,
            readyForMVP1: nnReport.overallCompatible
        )

        return TestResult(
            testId: testId,
            timestamp: timestamp,
            pattern: pattern.rawValue,
            success: summary.testPassed,
            stages: stages,
            cellOrganization: cellReport,
            colorStatistics: colorReport,
            gifValidation: gifReport,
            nnCompatibility: nnReport,
            summary: summary
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Report Builders
    // ════════════════════════════════════════════════════════════════════════

    private func buildCellOrganizationReport(digest: MacroCellDigest?) -> CellOrganizationReport {
        guard let digest = digest else {
            return CellOrganizationReport(
                totalCells: 0,
                expectedCells: 729,
                cellsValid: false,
                featureDimension: 0,
                expectedFeatureDimension: 81,
                featuresValid: false,
                sampleCells: []
            )
        }

        var sampleCells = [CellSample]()

        // Sample cells at key positions: corners and center of the cube
        let samplePositions = [
            (0, 0, 0), (0, 0, 8), (0, 8, 0), (0, 8, 8),
            (4, 4, 4),  // Center
            (8, 0, 0), (8, 0, 8), (8, 8, 0), (8, 8, 8)
        ]

        for (tg, tr, tc) in samplePositions {
            let cell = digest.cell(tileRow: tr, tileCol: tc, timeGroup: tg)
            let cellIndex = tg * 81 + tr * 9 + tc
            sampleCells.append(CellSample(
                timeGroup: tg,
                tileRow: tr,
                tileCol: tc,
                cellIndex: cellIndex,
                featureCount: cell.toVector().count,
                luminanceHistogramSum: cell.luminanceHistogram.reduce(0, +),
                hueHistogramSum: cell.hueHistogram.reduce(0, +)
            ))
        }

        return CellOrganizationReport(
            totalCells: digest.cells.count,
            expectedCells: 729,
            cellsValid: digest.cells.count == 729,
            featureDimension: MacroCellDigest.featureDimension,
            expectedFeatureDimension: 81,
            featuresValid: MacroCellDigest.featureDimension == 81,
            sampleCells: sampleCells
        )
    }

    private func buildColorStatisticsReport(
        colorSpace: ColorVectorSpace?,
        spatialPalette: ColorVectorSpace.ScoredPalette,
        temporalPalette: ColorVectorSpace.ScoredPalette,
        finalPalette: [(UInt8, UInt8, UInt8)],
        exactMatches: Int,
        similarMerges: Int
    ) -> ColorStatisticsReport {
        guard let cs = colorSpace else {
            return ColorStatisticsReport(
                uniqueColorsFound: 0,
                maxPossibleColors: 59049,
                colorDensity: 0,
                globalColors: 0,
                localizedColors: 0,
                stableColors: 0,
                transientColors: 0,
                spatialPaletteSize: 0,
                temporalPaletteSize: 0,
                finalPaletteSize: 0,
                exactMatches: 0,
                similarMerges: 0
            )
        }

        return ColorStatisticsReport(
            uniqueColorsFound: cs.uniqueColorCount,
            maxPossibleColors: 59049,
            colorDensity: Float(cs.uniqueColorCount) / 59049.0,
            globalColors: cs.globalColors.count,
            localizedColors: cs.localizedColors.count,
            stableColors: cs.stableColors.count,
            transientColors: cs.transientColors.count,
            spatialPaletteSize: spatialPalette.count,
            temporalPaletteSize: temporalPalette.count,
            finalPaletteSize: finalPalette.count,
            exactMatches: exactMatches,
            similarMerges: similarMerges
        )
    }

    private func buildGIFValidationReport(gifURL: URL) -> GIFValidationReport {
        guard FileManager.default.fileExists(atPath: gifURL.path),
              let data = try? Data(contentsOf: gifURL) else {
            return GIFValidationReport(
                fileSize: 0,
                headerValid: false,
                dimensionsValid: false,
                width: 0,
                height: 0,
                frameCount: 0,
                paletteSize: 0,
                hasNetscapeExtension: false,
                hasTrailer: false,
                overallValid: false,
                issues: ["File not found or unreadable"]
            )
        }

        var issues = [String]()

        // Check header
        let headerValid = data.count >= 6 && data.prefix(6) == Data("GIF89a".utf8)
        if !headerValid { issues.append("Invalid header (expected GIF89a)") }

        // Check dimensions
        var width = 0
        var height = 0
        if data.count >= 10 {
            width = Int(data[6]) | (Int(data[7]) << 8)
            height = Int(data[8]) | (Int(data[9]) << 8)
        }
        let dimensionsValid = width == 81 && height == 81
        if !dimensionsValid { issues.append("Invalid dimensions (expected 81x81, got \(width)x\(height))") }

        // Check GCT
        var paletteSize = 0
        if data.count >= 11 {
            let packed = data[10]
            if (packed & 0x80) != 0 {
                paletteSize = 1 << ((packed & 0x07) + 1)
            }
        }
        if paletteSize != 256 { issues.append("Invalid palette size (expected 256, got \(paletteSize))") }

        // Check Netscape extension
        let hasNetscape = data.count >= 32 &&
            data[13 + 768] == 0x21 &&
            data[14 + 768] == 0xFF

        // Check trailer
        let hasTrailer = data.last == 0x3B
        if !hasTrailer { issues.append("Missing trailer byte") }

        // Count frames (rough estimate based on image separators)
        var frameCount = 0
        for i in 0..<data.count where data[i] == 0x2C {
            frameCount += 1
        }

        return GIFValidationReport(
            fileSize: data.count,
            headerValid: headerValid,
            dimensionsValid: dimensionsValid,
            width: width,
            height: height,
            frameCount: frameCount,
            paletteSize: paletteSize,
            hasNetscapeExtension: hasNetscape,
            hasTrailer: hasTrailer,
            overallValid: headerValid && dimensionsValid && paletteSize == 256 && hasTrailer,
            issues: issues
        )
    }

    private func buildNNCompatibilityReport(
        digest: MacroCellDigest?,
        colorSpace: ColorVectorSpace?
    ) -> NNCompatibilityReport {
        var issues = [String]()

        guard let digest = digest else {
            return NNCompatibilityReport(
                digestReady: false,
                cellsAddressable: false,
                spatialSlicesWork: false,
                temporalSlicesWork: false,
                weightsApplicable: false,
                projectionWorks: false,
                overallCompatible: false,
                issues: ["Digest not available"]
            )
        }

        // Check digest
        let digestReady = digest.cells.count == 729
        if !digestReady { issues.append("Digest cell count incorrect") }

        // Check addressability
        let testCell = digest.cell(tileRow: 4, tileCol: 4, timeGroup: 4)
        let cellsAddressable = testCell.tileRow == 4 && testCell.tileCol == 4 && testCell.timeGroup == 4
        if !cellsAddressable { issues.append("Cells not addressable by (row, col, timeGroup)") }

        // Check spatial slices
        let spatialSlice = digest.spatialSlice(tileRow: 4, tileCol: 4)
        let spatialSlicesWork = spatialSlice.count == 9
        if !spatialSlicesWork { issues.append("Spatial slices don't return 9 time groups") }

        // Check temporal slices
        let temporalSlice = digest.temporalSlice(timeGroup: 4)
        let temporalSlicesWork = temporalSlice.count == 81
        if !temporalSlicesWork { issues.append("Temporal slices don't return 81 tiles") }

        // Check weight applicability
        let weightsApplicable = MacroCellDigest.featureDimension == 81
        if !weightsApplicable { issues.append("Feature dimension not 81 (GO board compatible)") }

        // Check projection
        var projectionWorks = false
        if let cs = colorSpace, cs.uniqueColorCount > 0 {
            if let firstColor = cs.colors.values.first {
                let tilePresence = firstColor.tilePresence
                let framePresence = firstColor.framePresence
                projectionWorks = tilePresence.count == 81 && framePresence.count == 81
            }
        }
        if !projectionWorks { issues.append("729D → 81D projection not working") }

        let overallCompatible = digestReady && cellsAddressable && spatialSlicesWork &&
                               temporalSlicesWork && weightsApplicable && projectionWorks

        return NNCompatibilityReport(
            digestReady: digestReady,
            cellsAddressable: cellsAddressable,
            spatialSlicesWork: spatialSlicesWork,
            temporalSlicesWork: temporalSlicesWork,
            weightsApplicable: weightsApplicable,
            projectionWorks: projectionWorks,
            overallCompatible: overallCompatible,
            issues: issues
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Frame Indexing
    // ════════════════════════════════════════════════════════════════════════

    private func indexFramesToPalette(
        frames: [CGImage],
        palette: [(UInt8, UInt8, UInt8)]
    ) -> [[UInt8]] {
        var indexedFrames = [[UInt8]]()
        indexedFrames.reserveCapacity(frames.count)

        // Build lookup table
        var exactLookup = [UInt32: UInt8]()
        for (idx, color) in palette.enumerated() {
            let packed = (UInt32(color.0) << 16) | (UInt32(color.1) << 8) | UInt32(color.2)
            exactLookup[packed] = UInt8(idx)
        }

        for frame in frames {
            guard let pixels = extractPixels(from: frame) else {
                indexedFrames.append([UInt8](repeating: 0, count: 81 * 81))
                continue
            }

            var indexed = [UInt8]()
            indexed.reserveCapacity(81 * 81)

            for y in 0..<81 {
                for x in 0..<81 {
                    let offset = (y * 81 + x) * 4
                    let r = pixels[offset]
                    let g = pixels[offset + 1]
                    let b = pixels[offset + 2]

                    let packed = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                    if let exactIdx = exactLookup[packed] {
                        indexed.append(exactIdx)
                        continue
                    }

                    // Find nearest
                    var bestIdx: UInt8 = 0
                    var bestDist = Int.max

                    for (idx, color) in palette.enumerated() {
                        let dr = Int(r) - Int(color.0)
                        let dg = Int(g) - Int(color.1)
                        let db = Int(b) - Int(color.2)
                        let dist = dr * dr + dg * dg + db * db

                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = UInt8(idx)
                        }
                        if dist == 0 { break }
                    }

                    indexed.append(bestIdx)
                }
            }

            indexedFrames.append(indexed)
        }

        return indexedFrames
    }

    private func extractPixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - JSON Export
    // ════════════════════════════════════════════════════════════════════════

    /// Export test result as JSON file
    public func exportJSON(_ result: TestResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: url)
    }
}
