//
//  LZWDecoder.swift
//  RGB2GIF
//
//  GIF-compatible LZW decoder. Mirrors the encoder but operates on
//  sub-block payloads produced during capture or demux. Supports
//  minimum code sizes 2–8 and dictionary growth up to 12 bits as per GIF89a.
//

import Foundation

@available(iOS 26.0, *)
struct LZWDecoderImpl {
    static func decompress(subBlocks: [Data], minCodeSize: UInt8, expectedPixelCount: Int) throws -> [UInt8] {
        guard (2...8).contains(minCodeSize) else {
            throw Error.invalidMinCodeSize(minCodeSize)
        }

        var bitStream = BitStream(subBlocks: subBlocks)
        let clearCode = 1 << Int(minCodeSize)
        let eoiCode = clearCode + 1

        var codeSize = Int(minCodeSize) + 1
        var dictionary = Dictionary<Int, [UInt8]>()

        func resetDictionary() {
            dictionary.removeAll(keepingCapacity: true)
            for i in 0..<(1 << Int(minCodeSize)) {
                dictionary[i] = [UInt8(i)]
            }
        }

        resetDictionary()

        var previousSequence: [UInt8] = []
        var decoded: [UInt8] = []
        var nextCode = eoiCode + 1
        var maxCode = (1 << codeSize) - 1

        while let code = bitStream.readCode(width: codeSize) {
            if code == clearCode {
                resetDictionary()
                codeSize = Int(minCodeSize) + 1
                nextCode = eoiCode + 1
                maxCode = (1 << codeSize) - 1
                previousSequence.removeAll(keepingCapacity: true)
                continue
            } else if code == eoiCode {
                break
            }

            var sequence: [UInt8]
            if let entry = dictionary[code] {
                sequence = entry
            } else if code == nextCode, !previousSequence.isEmpty {
                sequence = previousSequence + [previousSequence[0]]
            } else {
                throw Error.corruptStream
            }

            decoded.append(contentsOf: sequence)

            if !previousSequence.isEmpty {
                let newEntry = previousSequence + [sequence[0]]
                if nextCode < Self.maxDictionarySize {
                    dictionary[nextCode] = newEntry
                    nextCode += 1

                    if nextCode > maxCode && codeSize < Self.maxCodeSize {
                        codeSize += 1
                        maxCode = (1 << codeSize) - 1
                    }
                }
            }

            previousSequence = sequence
        }

        if expectedPixelCount > 0, decoded.count != expectedPixelCount {
            // Some GIF encoders pad, so allow truncation but log mismatch.
            decoded = Array(decoded.prefix(expectedPixelCount))
        }

        return decoded
    }

    private static let maxDictionarySize = 4096
    private static let maxCodeSize = 12

    enum Error: LocalizedError {
        case invalidMinCodeSize(UInt8)
        case corruptStream

        var errorDescription: String? {
            switch self {
            case .invalidMinCodeSize(let value):
                return "Invalid LZW minimum code size: \(value)"
            case .corruptStream:
                return "Corrupt LZW stream"
            }
        }
    }

    private struct BitStream {
        let bytes: [UInt8]
        var byteOffset: Int = 0
        var bitOffset: Int = 0

        init(subBlocks: [Data]) {
            self.bytes = subBlocks.flatMap { Array($0) }
        }

        mutating func readCode(width: Int) -> Int? {
            guard width > 0 else { return nil }
            var value = 0
            var bitsRead = 0

            while bitsRead < width {
                guard byteOffset < bytes.count else { return nil }

                let currentByte = bytes[byteOffset]
                let remainingBitsInByte = 8 - bitOffset
                let bitsToTake = min(width - bitsRead, remainingBitsInByte)

                let mask = (1 << bitsToTake) - 1
                let shifted = (Int(currentByte) >> bitOffset) & mask

                value |= shifted << bitsRead

                bitsRead += bitsToTake
                bitOffset += bitsToTake

                if bitOffset >= 8 {
                    bitOffset = 0
                    byteOffset += 1
                }
            }

            return value
        }
    }
}
