//
//  LZWDiagnosticTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  COMPREHENSIVE LZW ENCODER DIAGNOSTIC TESTS                              ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  These tests verify the LZW encoder produces CORRECT GIF-compatible      ║
//  ║  output. They decode the output and verify:                              ║
//  ║                                                                           ║
//  ║  1. ROUND-TRIP: encode → decode → original data                         ║
//  ║  2. CODE SIZE TRANSITIONS: at 512, 1024, 2048 boundaries                ║
//  ║  3. CLEAR CODE HANDLING: dictionary reset behavior                       ║
//  ║  4. SPECIFIC PATTERNS: all zeros, sequential, repeating                  ║
//  ║  5. REAL DATA: 6561-byte arrays simulating 81×81 frames                  ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import os.log

private let lzwTestLogger = Logger(subsystem: "com.rgb2gif.tests", category: "LZWDiagnostic")

@available(iOS 26.0, *)
public struct LZWDiagnosticTests {

    // MARK: - Test Results

    public struct TestResult {
        public let testID: String
        public let testName: String
        public let passed: Bool
        public let expected: String
        public let actual: String
        public let details: String
    }

    public struct DiagnosticReport {
        public var tests: [TestResult] = []
        public var criticalFailure: String? = nil

        public var passCount: Int { tests.filter { $0.passed }.count }
        public var totalCount: Int { tests.count }
        public var allPassed: Bool { tests.allSatisfy { $0.passed } }
    }

    // MARK: - Run All Tests

    public static func runAllTests() -> DiagnosticReport {
        var report = DiagnosticReport()

        lzwTestLogger.info("═══════════════════════════════════════════════════════════════════════════════")
        lzwTestLogger.info("STARTING LZW DIAGNOSTIC TESTS")
        lzwTestLogger.info("═══════════════════════════════════════════════════════════════════════════════")

        // Test 1: Simple round-trip with small data
        report.tests.append(testSimpleRoundTrip())

        // Test 2: All zeros (maximum compression)
        report.tests.append(testAllZeros())

        // Test 3: Sequential values (no repetition)
        report.tests.append(testSequentialValues())

        // Test 4: Repeating pattern
        report.tests.append(testRepeatingPattern())

        // Test 5: 81×81 = 6561 byte array (real frame size)
        report.tests.append(testRealFrameSize())

        // Test 6: Code size transition at 512
        report.tests.append(testCodeSizeTransition512())

        // Test 7: Multiple dictionary resets
        report.tests.append(testDictionaryReset())

        // Test 8: Random data round-trip
        report.tests.append(testRandomData())

        // Test 9: Verify first code is CLEAR
        report.tests.append(testFirstCodeIsClear())

        // Test 10: Verify last code is EOI
        report.tests.append(testLastCodeIsEOI())

        lzwTestLogger.info("═══════════════════════════════════════════════════════════════════════════════")
        lzwTestLogger.info("LZW DIAGNOSTIC COMPLETE: \(report.passCount)/\(report.totalCount) tests passed")
        lzwTestLogger.info("═══════════════════════════════════════════════════════════════════════════════")

        return report
    }

    // MARK: - Individual Tests

    /// Test 1: Simple round-trip with small data
    private static func testSimpleRoundTrip() -> TestResult {
        let testID = "LZW.1"
        let testName = "Simple Round-Trip"

        // Create simple test data: [0, 1, 2, 3, ..., 255, 0, 1, 2, ...]
        var input = [UInt8](repeating: 0, count: 1000)
        for i in 0..<1000 {
            input[i] = UInt8(i % 256)
        }

        do {
            // Encode
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)

            // Decode
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            // Verify
            if decoded == input {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "\(input.count) bytes",
                    actual: "\(decoded.count) bytes (match)",
                    details: "Round-trip successful"
                )
            } else {
                let firstMismatch = zip(input, decoded).enumerated().first { $0.element.0 != $0.element.1 }
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "\(input.count) bytes",
                    actual: "\(decoded.count) bytes",
                    details: firstMismatch.map { "First mismatch at index \($0.offset): expected \($0.element.0), got \($0.element.1)" } ?? "Length mismatch"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Successful encode/decode",
                actual: "Error: \(error.localizedDescription)",
                details: "Exception during test"
            )
        }
    }

    /// Test 2: All zeros (maximum compression)
    private static func testAllZeros() -> TestResult {
        let testID = "LZW.2"
        let testName = "All Zeros"

        let input = [UInt8](repeating: 0, count: 6561)  // 81×81

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            if decoded == input {
                let totalBytes = subBlocks.reduce(0) { $0 + $1.count }
                let ratio = Double(totalBytes) / Double(input.count) * 100
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "6561 zeros",
                    actual: "Decoded \(decoded.count) bytes correctly",
                    details: String(format: "Compressed to %.1f%% (%d bytes)", ratio, totalBytes)
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "6561 zeros",
                    actual: "\(decoded.count) bytes decoded",
                    details: "Data mismatch after decode"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Successful compression",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    /// Test 3: Sequential values (minimal compression opportunity)
    private static func testSequentialValues() -> TestResult {
        let testID = "LZW.3"
        let testName = "Sequential Values"

        // 256 unique values, no repetition for first 256 bytes
        var input = [UInt8]()
        for i in 0..<6561 {
            input.append(UInt8(i % 256))
        }

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            if decoded == input {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "6561 sequential bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Round-trip successful"
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "6561 sequential bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Mismatch at decode"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Successful",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    /// Test 4: Repeating pattern (good compression)
    private static func testRepeatingPattern() -> TestResult {
        let testID = "LZW.4"
        let testName = "Repeating Pattern"

        // Pattern: [1, 2, 3, 1, 2, 3, 1, 2, 3, ...]
        var input = [UInt8](repeating: 0, count: 6561)
        for i in 0..<6561 {
            input[i] = UInt8((i % 3) + 1)
        }

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            if decoded == input {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "6561 bytes [1,2,3] pattern",
                    actual: "\(decoded.count) bytes decoded",
                    details: "Pattern preserved"
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "Pattern match",
                    actual: "Mismatch",
                    details: "Decoded data doesn't match input"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Success",
                actual: "Error",
                details: "\(error)"
            )
        }
    }

    /// Test 5: Real frame size (81×81 = 6561 bytes)
    private static func testRealFrameSize() -> TestResult {
        let testID = "LZW.5"
        let testName = "Real Frame Size (6561 bytes)"

        // Simulate real frame data with various patterns
        var input = [UInt8](repeating: 0, count: 6561)
        for i in 0..<6561 {
            // Mix of patterns to simulate real image
            input[i] = UInt8((i * 17 + i / 81) % 256)
        }

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            let match = (decoded.count == input.count) && zip(decoded, input).allSatisfy { $0 == $1 }

            if match {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "6561 pixels",
                    actual: "\(decoded.count) pixels",
                    details: "81×81 frame round-trip OK"
                )
            } else {
                let mismatchCount = zip(decoded.prefix(6561), input).filter { $0 != $1 }.count
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "6561 matching pixels",
                    actual: "\(decoded.count) pixels, \(mismatchCount) mismatches",
                    details: "Decoded count: \(decoded.count), Expected: \(input.count)"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Success",
                actual: "Error: \(error)",
                details: "Exception during encode/decode"
            )
        }
    }

    /// Test 6: Code size transition at 512 entries
    private static func testCodeSizeTransition512() -> TestResult {
        let testID = "LZW.6"
        let testName = "Code Size Transition (9→10 bits)"

        // Create data that will generate exactly 254 dictionary entries (258-511)
        // then continue to generate more, triggering code size increase
        //
        // For minCodeSize=8: clearCode=256, eoiCode=257, first entry=258
        // Code 511 is the last 9-bit code, code 512+ needs 10 bits
        //
        // Each unique 2-byte sequence adds one entry. After 254 unique pairs,
        // nextCode will be 512 and we need 10 bits.

        var input = [UInt8]()
        // Generate pattern that forces many dictionary entries
        for i in 0..<2000 {
            input.append(UInt8(i % 256))
            input.append(UInt8((i / 256) % 256))
        }

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            if decoded == input {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "\(input.count) bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Code size transition handled correctly"
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "\(input.count) bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Code size transition may be incorrect"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Success",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    /// Test 7: Multiple dictionary resets
    private static func testDictionaryReset() -> TestResult {
        let testID = "LZW.7"
        let testName = "Dictionary Reset (CLEAR codes)"

        // Large enough to trigger multiple dictionary resets
        // Dictionary fills at 4096 entries
        var input = [UInt8](repeating: 0, count: 50000)
        for i in 0..<50000 {
            // Pattern that generates many unique sequences
            input[i] = UInt8((i * 7 + i / 100) % 256)
        }

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            if decoded == input {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "\(input.count) bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Multiple CLEAR codes handled"
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "\(input.count) bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Dictionary reset handling may be incorrect"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Success",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    /// Test 8: Random data round-trip
    private static func testRandomData() -> TestResult {
        let testID = "LZW.8"
        let testName = "Random Data"

        // Pseudo-random but deterministic
        var input = [UInt8](repeating: 0, count: 6561)
        var seed: UInt32 = 12345
        for i in 0..<6561 {
            seed = seed &* 1103515245 &+ 12345
            input[i] = UInt8((seed >> 16) % 256)
        }

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: 8)
            let decoded = try decodeLZW(subBlocks: subBlocks, minCodeSize: 8)

            if decoded == input {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "6561 random bytes",
                    actual: "Match",
                    details: "Random data round-trip OK"
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "6561 bytes",
                    actual: "\(decoded.count) bytes",
                    details: "Random data failed"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "Success",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    /// Test 9: Verify first code is CLEAR
    private static func testFirstCodeIsClear() -> TestResult {
        let testID = "LZW.9"
        let testName = "First Code is CLEAR"

        let input: [UInt8] = [1, 2, 3, 4, 5]
        let minCodeSize: UInt8 = 8
        let clearCode = 1 << Int(minCodeSize)  // 256

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: minCodeSize)

            // Parse first code from bit stream
            let bytes = subBlocks.flatMap { Array($0) }
            guard bytes.count >= 2 else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "CLEAR code (\(clearCode))",
                    actual: "Output too short",
                    details: "No data to parse"
                )
            }

            // First code is 9 bits starting at bit 0
            // byte[0] has bits 0-7, byte[1] has bit 8
            let codeSize = Int(minCodeSize) + 1  // 9
            let mask = (1 << codeSize) - 1  // 511
            let firstCode = (Int(bytes[0]) | (Int(bytes[1]) << 8)) & mask

            if firstCode == clearCode {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: true,
                    expected: "CLEAR code (\(clearCode))",
                    actual: "\(firstCode)",
                    details: "First code is correct"
                )
            } else {
                return TestResult(
                    testID: testID,
                    testName: testName,
                    passed: false,
                    expected: "CLEAR code (\(clearCode))",
                    actual: "\(firstCode)",
                    details: "CRITICAL: Wrong first code!"
                )
            }
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "CLEAR",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    /// Test 10: Verify last code is EOI
    private static func testLastCodeIsEOI() -> TestResult {
        let testID = "LZW.10"
        let testName = "Last Code is EOI"

        let input: [UInt8] = [1, 2, 3, 4, 5]
        let minCodeSize: UInt8 = 8
        let eoiCode = (1 << Int(minCodeSize)) + 1  // 257

        do {
            let subBlocks = try LZW_Optimized.compress(indices: input, minCodeSize: minCodeSize)

            // Parse all codes and find the last one before EOI
            let bytes = subBlocks.flatMap { Array($0) }
            var bitOffset = 0
            var lastCode = -1
            var codeSize = Int(minCodeSize) + 1
            let clearCode = 1 << Int(minCodeSize)
            var nextCode = (1 << Int(minCodeSize)) + 2
            var maxCode = (1 << codeSize) - 1

            while bitOffset + codeSize <= bytes.count * 8 {
                // Read code
                var code = 0
                for i in 0..<codeSize {
                    let byteIdx = (bitOffset + i) / 8
                    let bitIdx = (bitOffset + i) % 8
                    if byteIdx < bytes.count && (bytes[byteIdx] & (1 << bitIdx)) != 0 {
                        code |= (1 << i)
                    }
                }
                bitOffset += codeSize

                if code == eoiCode {
                    if lastCode == eoiCode || bitOffset > bytes.count * 8 - codeSize {
                        return TestResult(
                            testID: testID,
                            testName: testName,
                            passed: true,
                            expected: "EOI code (\(eoiCode))",
                            actual: "Found EOI",
                            details: "Stream terminates correctly"
                        )
                    }
                }

                lastCode = code

                // Track code size changes
                if code == clearCode {
                    codeSize = Int(minCodeSize) + 1
                    nextCode = (1 << Int(minCodeSize)) + 2
                    maxCode = (1 << codeSize) - 1
                } else if code != eoiCode {
                    nextCode += 1
                    if nextCode > maxCode && codeSize < 12 {
                        codeSize += 1
                        maxCode = (1 << codeSize) - 1
                    }
                }
            }

            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "EOI code (\(eoiCode))",
                actual: "Not found or parsing error",
                details: "Stream may not terminate correctly"
            )
        } catch {
            return TestResult(
                testID: testID,
                testName: testName,
                passed: false,
                expected: "EOI",
                actual: "Error: \(error)",
                details: "Exception"
            )
        }
    }

    // MARK: - LZW Decoder (for verification)

    /// Decode LZW compressed data back to original indices
    private static func decodeLZW(subBlocks: [Data], minCodeSize: UInt8) throws -> [UInt8] {
        let bytes = subBlocks.flatMap { Array($0) }
        guard !bytes.isEmpty else { return [] }

        let clearCode = 1 << Int(minCodeSize)
        let eoiCode = clearCode + 1

        var codeSize = Int(minCodeSize) + 1
        var dictionary = [Int: [UInt8]]()

        func resetDictionary() {
            dictionary.removeAll()
            for i in 0..<(1 << Int(minCodeSize)) {
                dictionary[i] = [UInt8(i)]
            }
        }

        resetDictionary()

        var previousSequence = [UInt8]()
        var decoded = [UInt8]()
        var nextCode = eoiCode + 1
        var maxCode = (1 << codeSize) - 1

        var bitOffset = 0

        func readCode() -> Int? {
            guard bitOffset + codeSize <= bytes.count * 8 else { return nil }

            var code = 0
            for i in 0..<codeSize {
                let byteIdx = (bitOffset + i) / 8
                let bitIdx = (bitOffset + i) % 8
                if byteIdx < bytes.count && (bytes[byteIdx] & (1 << bitIdx)) != 0 {
                    code |= (1 << i)
                }
            }
            bitOffset += codeSize
            return code
        }

        while let code = readCode() {
            if code == clearCode {
                resetDictionary()
                codeSize = Int(minCodeSize) + 1
                nextCode = eoiCode + 1
                maxCode = (1 << codeSize) - 1
                previousSequence.removeAll()
                continue
            } else if code == eoiCode {
                break
            }

            var sequence: [UInt8]
            if let entry = dictionary[code] {
                sequence = entry
            } else if code == nextCode && !previousSequence.isEmpty {
                sequence = previousSequence + [previousSequence[0]]
            } else {
                // Corrupt stream
                throw DecodingError.corruptStream(code: code, nextCode: nextCode)
            }

            decoded.append(contentsOf: sequence)

            if !previousSequence.isEmpty && nextCode < 4096 {
                let newEntry = previousSequence + [sequence[0]]
                dictionary[nextCode] = newEntry
                nextCode += 1

                if nextCode > maxCode && codeSize < 12 {
                    codeSize += 1
                    maxCode = (1 << codeSize) - 1
                }
            }

            previousSequence = sequence
        }

        return decoded
    }

    enum DecodingError: LocalizedError {
        case corruptStream(code: Int, nextCode: Int)

        var errorDescription: String? {
            switch self {
            case .corruptStream(let code, let nextCode):
                return "Corrupt LZW stream: code \(code) not in dictionary (nextCode=\(nextCode))"
            }
        }
    }

    // MARK: - Generate Text Report

    public static func generateReport(_ report: DiagnosticReport) -> String {
        var output = """
        ═══════════════════════════════════════════════════════════════════════════════
        LZW DIAGNOSTIC TEST REPORT
        ═══════════════════════════════════════════════════════════════════════════════

        """

        for test in report.tests {
            let status = test.passed ? "✓ PASS" : "✗ FAIL"
            output += """

            [\(test.testID)] \(test.testName): \(status)
                Expected: \(test.expected)
                Actual:   \(test.actual)
                Details:  \(test.details)

            """
        }

        output += """

        ═══════════════════════════════════════════════════════════════════════════════
        SUMMARY: \(report.passCount)/\(report.totalCount) tests passed
        ═══════════════════════════════════════════════════════════════════════════════
        """

        if let critical = report.criticalFailure {
            output += "\n\n⚠️ CRITICAL FAILURE: \(critical)"
        }

        return output
    }
}
