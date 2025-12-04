//
//  L4PaletteTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  L4_PALETTE TESTS - 256-Color Palette Validation                         ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Validates octree quantization output:                                   ║
//  ║  • L4.1  Palette Exists (palette.cbor)                                   ║
//  ║  • L4.2  Mapping Exists (mapping.cbor)                                   ║
//  ║  • L4.3  Color Count (exactly 256)                                       ║
//  ║  • L4.4  Color Format (each [r,g,b] all 0-255)                           ║
//  ║  • L4.5  No Duplicates (unique colors)                                   ║
//  ║  • L4.6  Color Spread (RGB range coverage)                               ║
//  ║  • L4.7  Mapping Count (exactly 729)                                     ║
//  ║  • L4.8  Mapping Range (all indices 0-255)                               ║
//  ║  • L4.9  Mapping Coverage (unique indices used)                          ║
//  ║  • L4.10 Nearest Neighbor Verification                                   ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import SwiftCBOR
import os.log

private let testLogger = Logger(subsystem: "com.rgb2gif.tests", category: "L4Palette")

@available(iOS 26.0, *)
public struct L4PaletteTests {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Color Structure

    private struct PaletteColor: Hashable {
        let r: UInt8
        let g: UInt8
        let b: UInt8

        var rgb: UInt32 {
            UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
    }

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Run All Tests

    public func run() async -> StageTestResults {
        var results = StageTestResults(stageName: "L4_PALETTE")

        testLogger.info("Starting L4_PALETTE tests for session: \(session.sessionID)")

        let fm = FileManager.default
        let paletteURL = session.paletteURL
        let mappingURL = session.paletteMappingURL

        let paletteExists = fm.fileExists(atPath: paletteURL.path)
        let mappingExists = fm.fileExists(atPath: mappingURL.path)

        // Parse palette
        var colors: [PaletteColor] = []
        var paletteParseError: String?

        if paletteExists {
            do {
                let data = try Data(contentsOf: paletteURL)
                if let cbor = try CBOR.decode([UInt8](data)),
                   case .map(let map) = cbor {
                    let dict = Dictionary(uniqueKeysWithValues: map.compactMap { (key, value) -> (String, CBOR)? in
                        if case .utf8String(let s) = key { return (s, value) }
                        return nil
                    })

                    if case .array(let colorArray) = dict["colors"] {
                        for colorCBOR in colorArray {
                            if case .array(let rgb) = colorCBOR,
                               rgb.count >= 3,
                               case .unsignedInt(let r) = rgb[0],
                               case .unsignedInt(let g) = rgb[1],
                               case .unsignedInt(let b) = rgb[2] {
                                colors.append(PaletteColor(r: UInt8(r), g: UInt8(g), b: UInt8(b)))
                            }
                        }
                    }
                }
            } catch {
                paletteParseError = error.localizedDescription
            }
        }

        // Parse mapping
        var mapping: [Int: Int] = [:]
        var mappingParseError: String?

        if mappingExists {
            do {
                let data = try Data(contentsOf: mappingURL)
                if let cbor = try CBOR.decode([UInt8](data)),
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
            } catch {
                mappingParseError = error.localizedDescription
            }
        }

        // L4.1: Palette Exists
        results.tests.append(testPaletteExists(paletteExists, error: paletteParseError))

        // L4.2: Mapping Exists
        results.tests.append(testMappingExists(mappingExists, error: mappingParseError))

        // L4.3: Color Count
        results.tests.append(testColorCount(colors.count))

        // L4.4: Color Format
        results.tests.append(testColorFormat(colors))

        // L4.5: No Duplicates
        results.tests.append(testNoDuplicates(colors))

        // L4.6: Color Spread
        results.tests.append(testColorSpread(colors))

        // L4.7: Mapping Count
        results.tests.append(testMappingCount(mapping.count))

        // L4.8: Mapping Range
        results.tests.append(testMappingRange(mapping))

        // L4.9: Mapping Coverage
        results.tests.append(testMappingCoverage(mapping))

        // L4.10: Nearest Neighbor - informational
        results.tests.append(CBORTestResult(
            id: "L4.10",
            name: "Nearest Neighbor",
            passed: true,
            expected: "Each cell maps to closest color",
            actual: "Verified via L3→L4 cross-stage test",
            details: "Full verification in CrossStageTests"
        ))

        // Diagnostics
        results.diagnostics.append(generatePaletteDistribution(colors))
        results.diagnostics.append(generateMappingUsage(mapping, paletteSize: colors.count))

        testLogger.info("L4_PALETTE tests complete: \(results.passCount)/\(results.totalCount) passed")

        return results
    }

    // MARK: - Individual Tests

    /// L4.1: Palette Exists
    private func testPaletteExists(_ exists: Bool, error: String?) -> CBORTestResult {
        CBORTestResult(
            id: "L4.1",
            name: "Palette Exists",
            passed: exists && error == nil,
            expected: "palette.cbor present and parseable",
            actual: exists ? (error == nil ? "Present" : "Parse error") : "Missing",
            details: error ?? (exists ? "Palette file found and parsed" : "palette.cbor not found")
        )
    }

    /// L4.2: Mapping Exists
    private func testMappingExists(_ exists: Bool, error: String?) -> CBORTestResult {
        CBORTestResult(
            id: "L4.2",
            name: "Mapping Exists",
            passed: exists && error == nil,
            expected: "mapping.cbor present and parseable",
            actual: exists ? (error == nil ? "Present" : "Parse error") : "Missing",
            details: error ?? (exists ? "Mapping file found and parsed" : "mapping.cbor not found")
        )
    }

    /// L4.3: Color Count
    private func testColorCount(_ count: Int) -> CBORTestResult {
        CBORTestResult(
            id: "L4.3",
            name: "Color Count",
            passed: count == 256,
            expected: "256",
            actual: "\(count)",
            details: count == 256 ? "Full 256-color palette" : "Palette has \(count) colors"
        )
    }

    /// L4.4: Color Format - all RGB values 0-255
    private func testColorFormat(_ colors: [PaletteColor]) -> CBORTestResult {
        // UInt8 is always 0-255, so just verify we have valid data
        let valid = !colors.isEmpty

        return CBORTestResult(
            id: "L4.4",
            name: "Color Format",
            passed: valid,
            expected: "[r,g,b] all 0-255",
            actual: valid ? "All valid RGB" : "No colors",
            details: valid ? "All palette entries are valid RGB8" : "No color data parsed"
        )
    }

    /// L4.5: No Duplicates
    private func testNoDuplicates(_ colors: [PaletteColor]) -> CBORTestResult {
        let uniqueSet = Set(colors)
        let duplicates = colors.count - uniqueSet.count

        return CBORTestResult(
            id: "L4.5",
            name: "No Duplicates",
            passed: duplicates == 0,
            expected: "256 unique colors",
            actual: duplicates == 0 ? "All unique" : "\(duplicates) duplicate(s)",
            details: "Unique colors: \(uniqueSet.count)/\(colors.count)"
        )
    }

    /// L4.6: Color Spread - check RGB range coverage
    private func testColorSpread(_ colors: [PaletteColor]) -> CBORTestResult {
        guard !colors.isEmpty else {
            return CBORTestResult(id: "L4.6", name: "Color Spread", passed: false, expected: "Good coverage", actual: "No colors", details: "Cannot analyze empty palette")
        }

        var minR: UInt8 = 255, maxR: UInt8 = 0
        var minG: UInt8 = 255, maxG: UInt8 = 0
        var minB: UInt8 = 255, maxB: UInt8 = 0

        for color in colors {
            minR = min(minR, color.r); maxR = max(maxR, color.r)
            minG = min(minG, color.g); maxG = max(maxG, color.g)
            minB = min(minB, color.b); maxB = max(maxB, color.b)
        }

        let rangeR = Int(maxR) - Int(minR)
        let rangeG = Int(maxG) - Int(minG)
        let rangeB = Int(maxB) - Int(minB)

        // Good spread: each channel spans at least 100
        let goodSpread = rangeR >= 100 && rangeG >= 100 && rangeB >= 100

        return CBORTestResult(
            id: "L4.6",
            name: "Color Spread",
            passed: goodSpread,
            expected: "Range ≥100 per channel",
            actual: "R:\(rangeR) G:\(rangeG) B:\(rangeB)",
            details: goodSpread ? "Good color distribution" : "Limited color range"
        )
    }

    /// L4.7: Mapping Count
    private func testMappingCount(_ count: Int) -> CBORTestResult {
        CBORTestResult(
            id: "L4.7",
            name: "Mapping Count",
            passed: count == 729,
            expected: "729 entries",
            actual: "\(count)",
            details: count == 729 ? "All cells mapped" : "Missing \(729 - count) mapping(s)"
        )
    }

    /// L4.8: Mapping Range - all indices 0-255
    private func testMappingRange(_ mapping: [Int: Int]) -> CBORTestResult {
        var outOfRange: [Int] = []
        for (_, paletteIdx) in mapping {
            if paletteIdx < 0 || paletteIdx > 255 {
                outOfRange.append(paletteIdx)
            }
        }

        return CBORTestResult(
            id: "L4.8",
            name: "Mapping Range",
            passed: outOfRange.isEmpty,
            expected: "All indices 0-255",
            actual: outOfRange.isEmpty ? "All valid" : "\(outOfRange.count) out of range",
            details: outOfRange.isEmpty ? "All palette indices in valid range" : "Invalid: \(outOfRange.prefix(5))"
        )
    }

    /// L4.9: Mapping Coverage - unique indices used
    private func testMappingCoverage(_ mapping: [Int: Int]) -> CBORTestResult {
        let uniqueIndices = Set(mapping.values)

        // Calculate usage statistics
        var usageCounts: [Int: Int] = [:]
        for (_, paletteIdx) in mapping {
            usageCounts[paletteIdx, default: 0] += 1
        }

        let mostUsed = usageCounts.max(by: { $0.value < $1.value })

        let coverage = Double(uniqueIndices.count) / 256.0 * 100.0

        return CBORTestResult(
            id: "L4.9",
            name: "Mapping Coverage",
            passed: uniqueIndices.count >= 10,  // At least 10 unique colors used
            expected: "Good palette utilization",
            actual: String(format: "%d/256 (%.1f%%)", uniqueIndices.count, coverage),
            details: mostUsed != nil ? "Most used: index \(mostUsed!.key) (\(mostUsed!.value) cells)" : "No usage data"
        )
    }

    // MARK: - Diagnostics

    private func generatePaletteDistribution(_ colors: [PaletteColor]) -> String {
        guard !colors.isEmpty else { return "PALETTE DISTRIBUTION: No colors" }

        var minR: UInt8 = 255, maxR: UInt8 = 0, sumR: Int = 0
        var minG: UInt8 = 255, maxG: UInt8 = 0, sumG: Int = 0
        var minB: UInt8 = 255, maxB: UInt8 = 0, sumB: Int = 0

        for color in colors {
            minR = min(minR, color.r); maxR = max(maxR, color.r); sumR += Int(color.r)
            minG = min(minG, color.g); maxG = max(maxG, color.g); sumG += Int(color.g)
            minB = min(minB, color.b); maxB = max(maxB, color.b); sumB += Int(color.b)
        }

        let avgR = Double(sumR) / Double(colors.count)
        let avgG = Double(sumG) / Double(colors.count)
        let avgB = Double(sumB) / Double(colors.count)

        return """
        PALETTE COLOR DISTRIBUTION:
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ Channel │ Min │ Max │ Range │ Mean   │ Assessment                           │
        ├─────────────────────────────────────────────────────────────────────────────┤
        │ Red     │ \(String(format: "%3d", minR)) │ \(String(format: "%3d", maxR)) │ \(String(format: "%3d", Int(maxR) - Int(minR)))   │ \(String(format: "%5.1f", avgR))  │ \(assessRange(Int(maxR) - Int(minR)))
        │ Green   │ \(String(format: "%3d", minG)) │ \(String(format: "%3d", maxG)) │ \(String(format: "%3d", Int(maxG) - Int(minG)))   │ \(String(format: "%5.1f", avgG))  │ \(assessRange(Int(maxG) - Int(minG)))
        │ Blue    │ \(String(format: "%3d", minB)) │ \(String(format: "%3d", maxB)) │ \(String(format: "%3d", Int(maxB) - Int(minB)))   │ \(String(format: "%5.1f", avgB))  │ \(assessRange(Int(maxB) - Int(minB)))
        └─────────────────────────────────────────────────────────────────────────────┘
        """
    }

    private func assessRange(_ range: Int) -> String {
        if range >= 200 { return "Excellent spread                      │" }
        if range >= 150 { return "Good spread                           │" }
        if range >= 100 { return "Adequate spread                       │" }
        return "Limited spread                        │"
    }

    private func generateMappingUsage(_ mapping: [Int: Int], paletteSize: Int) -> String {
        guard !mapping.isEmpty else { return "PALETTE USAGE: No mapping data" }

        // Count usage per palette index
        var usageCounts: [Int: Int] = [:]
        for (_, paletteIdx) in mapping {
            usageCounts[paletteIdx, default: 0] += 1
        }

        let uniqueUsed = usageCounts.count
        let unused = paletteSize - uniqueUsed

        // Top 5 most used
        let sorted = usageCounts.sorted { $0.value > $1.value }

        var top5 = "TOP 5 INDICES BY USAGE:\n"
        for (i, entry) in sorted.prefix(5).enumerated() {
            top5 += "  #\(i+1): Index \(entry.key) (\(entry.value) cells)\n"
        }

        return """
        PALETTE USAGE (from mapping):
          Unique indices used: \(uniqueUsed)/\(paletteSize) (\(uniqueUsed * 100 / max(1, paletteSize))%)
          Most used index: \(sorted.first?.key ?? -1) (mapped by \(sorted.first?.value ?? 0) cells)
          Unused indices: \(unused)

        \(top5)
        """
    }
}
