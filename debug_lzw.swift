#!/usr/bin/env swift
//
// debug_lzw.swift - Detailed LZW encoding/decoding trace
//
// This script implements a reference LZW encoder and decoder with detailed
// logging to identify exactly where the code size transition mismatch occurs.
//

import Foundation

// MARK: - Reference LZW Encoder

struct LZWEncoder {
    let minCodeSize: Int
    let clearCode: Int
    let eoiCode: Int

    var codeSize: Int
    var nextCode: Int
    var maxCode: Int

    var dictionary: [[UInt8]: Int] = [:]
    var bitBuffer: UInt32 = 0
    var bitCount: Int = 0
    var output: [UInt8] = []

    var log: [String] = []

    init(minCodeSize: Int) {
        self.minCodeSize = minCodeSize
        self.clearCode = 1 << minCodeSize
        self.eoiCode = clearCode + 1
        self.codeSize = minCodeSize + 1
        self.nextCode = eoiCode + 1
        self.maxCode = (1 << codeSize) - 1

        // Initialize dictionary
        for i in 0..<clearCode {
            dictionary[[UInt8(i)]] = i
        }
    }

    mutating func encode(_ input: [UInt8]) -> [UInt8] {
        log.append("=== ENCODER START ===")
        log.append("minCodeSize=\(minCodeSize), clearCode=\(clearCode), eoiCode=\(eoiCode)")
        log.append("Initial codeSize=\(codeSize), nextCode=\(nextCode), maxCode=\(maxCode)")

        // Emit CLEAR
        emitCode(clearCode, label: "CLEAR")

        guard !input.isEmpty else {
            emitCode(eoiCode, label: "EOI")
            flushBits()
            return output
        }

        var currentSequence = [input[0]]

        for i in 1..<input.count {
            let byte = input[i]
            var extendedSequence = currentSequence
            extendedSequence.append(byte)

            if dictionary[extendedSequence] != nil {
                currentSequence = extendedSequence
            } else {
                // Emit code for current sequence
                if let code = dictionary[currentSequence] {
                    emitCode(code, label: "dict[\(currentSequence)]")
                }

                // Add extended sequence to dictionary
                if nextCode < 4096 {
                    dictionary[extendedSequence] = nextCode
                    log.append("  + Add dict[\(extendedSequence)] = \(nextCode)")
                    nextCode += 1

                    // Check for code size increase
                    if nextCode > maxCode && codeSize < 12 {
                        let oldSize = codeSize
                        codeSize += 1
                        maxCode = (1 << codeSize) - 1
                        log.append("  ⚡ CODE SIZE: \(oldSize) → \(codeSize) (nextCode=\(nextCode), maxCode=\(maxCode))")
                    }
                }

                currentSequence = [byte]
            }
        }

        // Emit remaining sequence
        if let code = dictionary[currentSequence] {
            emitCode(code, label: "final: dict[\(currentSequence)]")
        }

        // Emit EOI
        emitCode(eoiCode, label: "EOI")
        flushBits()

        log.append("=== ENCODER END: \(output.count) bytes ===")
        return output
    }

    mutating func emitCode(_ code: Int, label: String) {
        log.append("  EMIT \(code) (\(codeSize) bits) - \(label)")

        bitBuffer |= UInt32(code) << bitCount
        bitCount += codeSize

        while bitCount >= 8 {
            let byte = UInt8(bitBuffer & 0xFF)
            output.append(byte)
            bitBuffer >>= 8
            bitCount -= 8
        }
    }

    mutating func flushBits() {
        if bitCount > 0 {
            output.append(UInt8(bitBuffer & 0xFF))
        }
    }
}

// MARK: - Reference LZW Decoder

struct LZWDecoder {
    let minCodeSize: Int
    let clearCode: Int
    let eoiCode: Int

    var codeSize: Int
    var nextCode: Int
    var maxCode: Int

    var dictionary: [Int: [UInt8]] = [:]

    var log: [String] = []

    init(minCodeSize: Int) {
        self.minCodeSize = minCodeSize
        self.clearCode = 1 << minCodeSize
        self.eoiCode = clearCode + 1
        self.codeSize = minCodeSize + 1
        self.nextCode = eoiCode + 1
        self.maxCode = (1 << codeSize) - 1

        // Initialize dictionary
        for i in 0..<clearCode {
            dictionary[i] = [UInt8(i)]
        }
    }

    mutating func decode(_ input: [UInt8]) -> [UInt8]? {
        log.append("=== DECODER START ===")
        log.append("minCodeSize=\(minCodeSize), clearCode=\(clearCode), eoiCode=\(eoiCode)")
        log.append("Initial codeSize=\(codeSize), nextCode=\(nextCode), maxCode=\(maxCode)")

        var output: [UInt8] = []
        var bitBuffer: UInt32 = 0
        var bitsInBuffer = 0
        var byteIndex = 0

        var prevCode: Int = -1
        var codeCount = 0

        while true {
            // Load more bytes
            while bitsInBuffer < codeSize && byteIndex < input.count {
                bitBuffer |= UInt32(input[byteIndex]) << bitsInBuffer
                bitsInBuffer += 8
                byteIndex += 1
            }

            guard bitsInBuffer >= codeSize else {
                log.append("  ! Insufficient bits, breaking")
                break
            }

            // Extract code
            let code = Int(bitBuffer) & maxCode
            bitBuffer >>= codeSize
            bitsInBuffer -= codeSize
            codeCount += 1

            log.append("  READ \(code) (\(codeSize) bits) [code #\(codeCount)]")

            if code == clearCode {
                log.append("    CLEAR - resetting")
                // Reset
                codeSize = minCodeSize + 1
                maxCode = (1 << codeSize) - 1
                nextCode = eoiCode + 1
                dictionary.removeAll()
                for i in 0..<clearCode {
                    dictionary[i] = [UInt8(i)]
                }
                prevCode = -1
                continue
            }

            if code == eoiCode {
                log.append("    EOI - done")
                break
            }

            // Get sequence for this code
            var sequence: [UInt8]
            if let entry = dictionary[code] {
                sequence = entry
            } else if code == nextCode && prevCode >= 0 {
                // Special case: code = nextCode
                if let prevSeq = dictionary[prevCode] {
                    sequence = prevSeq + [prevSeq[0]]
                } else {
                    log.append("    ! ERROR: prevCode \(prevCode) not in dictionary")
                    return nil
                }
            } else {
                log.append("    ! ERROR: code \(code) not in dictionary (nextCode=\(nextCode))")
                return nil
            }

            output.append(contentsOf: sequence)
            log.append("    Output \(sequence.count) bytes, total=\(output.count)")

            // Add new entry
            if prevCode >= 0 && nextCode < 4096 {
                if let prevSeq = dictionary[prevCode] {
                    let newEntry = prevSeq + [sequence[0]]
                    dictionary[nextCode] = newEntry
                    log.append("    + Add dict[\(nextCode)] = \(newEntry)")
                    nextCode += 1

                    // Check for code size increase
                    if nextCode > maxCode && codeSize < 12 {
                        let oldSize = codeSize
                        codeSize += 1
                        maxCode = (1 << codeSize) - 1
                        log.append("    ⚡ CODE SIZE: \(oldSize) → \(codeSize) (nextCode=\(nextCode), maxCode=\(maxCode))")
                    }
                }
            }

            prevCode = code
        }

        log.append("=== DECODER END: \(output.count) bytes ===")
        return output
    }
}

// MARK: - Test

print("LZW Debug Test")
print("==============")

// Test with sequential data
var input: [UInt8] = []
for i in 0..<100 {
    input.append(UInt8(i % 256))
}

print("\nInput: \(input.count) bytes")
print("First 20: \(Array(input.prefix(20)))")

// Encode
var encoder = LZWEncoder(minCodeSize: 8)
let encoded = encoder.encode(input)

print("\nEncoded: \(encoded.count) bytes")
print("First 20: \(Array(encoded.prefix(20)))")

// Print encoder log (first 50 lines)
print("\n--- Encoder Log (first 50 lines) ---")
for (i, line) in encoder.log.prefix(50).enumerated() {
    print("\(i): \(line)")
}

// Decode
var decoder = LZWDecoder(minCodeSize: 8)
if let decoded = decoder.decode(encoded) {
    print("\nDecoded: \(decoded.count) bytes")
    print("First 20: \(Array(decoded.prefix(20)))")
    print("Match: \(decoded == input ? "YES ✓" : "NO ❌")")
} else {
    print("\nDecode FAILED!")
}

// Print decoder log (first 50 lines)
print("\n--- Decoder Log (first 50 lines) ---")
for (i, line) in decoder.log.prefix(50).enumerated() {
    print("\(i): \(line)")
}

// If there's a mismatch, show where
if let decoded = decoder.decode(encoded), decoded != input {
    print("\n--- MISMATCH DETAILS ---")
    for i in 0..<min(input.count, decoded.count) {
        if input[i] != decoded[i] {
            print("First mismatch at index \(i): expected \(input[i]), got \(decoded[i])")
            break
        }
    }
    if decoded.count != input.count {
        print("Length mismatch: expected \(input.count), got \(decoded.count)")
    }
}
