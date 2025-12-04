//
//  GIP.swift
//  RGB2GIF
//
//  GiP2 Palette Container Format (Simplified for RGB2GIF)
//  Magic: "GiP2" (4 bytes)
//  Version: u8 (currently 2)
//  RGB2GIF Mode: Locked to 256-color palettes only (paletteExp = 7)
//  Reference: GIF89a spec §18-20 (color tables), §23 (image descriptor)
//

import Foundation
import CryptoKit

/// Palette ordering for tensor-to-index flattening
@available(iOS 26.0, *)
enum PaletteOrdering: UInt8 {
    case rowMajor = 0
    case columnMajor = 1
}

/// Hash algorithm for content-addressing palettes
@available(iOS 26.0, *)
enum HashAlgorithm: UInt8 {
    case none = 0
    case sha256 = 1
    case blake3 = 2  // Reserved for future
}

/// Single palette entry in GIP2 (can represent tensor shapes)
@available(iOS 26.0, *)
public struct GIPPalette {
    let entryCount: UInt16        // Must equal 2^(paletteExp+1)
    let dims: UInt8               // 1 or 2 (number of dimensions)
    let dimA: UInt16              // e.g., 256 for 1D or 16 for 2D
    let dimB: UInt16              // e.g., 1 for 1D or 16 for 2D
    let ordering: PaletteOrdering // How to flatten dims to indices
    let hasTransparency: Bool
    let transparentIndex: UInt8
    let label: String             // UTF-8 label for this palette
    let rgb: [[UInt8]]            // RGB triples (entryCount × 3)
    let remap: [UInt8]?           // Optional 256-byte permutation
    let hash: Data?               // Content hash

    var isValid: Bool {
        guard rgb.count == Int(entryCount) else { return false }
        guard rgb.allSatisfy({ $0.count == 3 }) else { return false }
        if let remap = remap, remap.count != 256 { return false }
        return true
    }
}

/// GIP2 Palette Container
/// Stores one or more palettes with tensor metadata
@available(iOS 26.0, *)
public struct GIP {

    // MARK: - Properties

    let version: UInt8
    let paletteExp: UInt8      // 0-7 => 2^(exp+1) colors (2-256)
    let hashAlg: HashAlgorithm
    let hasGlobal: Bool        // First palette is suggested Global Color Table
    let hasFrameSet: Bool      // Contains per-frame palettes
    let name: String           // Container name
    let palettes: [GIPPalette] // One or more palettes

    // MARK: - V2 Fields (GIF89a Round-Trip Support)
    // GIF89a Logical Screen Descriptor §18

    let backgroundColorIndex: UInt8?  // §18 byte 11 - background color index
    let pixelAspectRatio: UInt8?      // §18 byte 12 - pixel aspect ratio

    // MARK: - Computed Properties

    var paletteSize: Int {
        return 1 << (Int(paletteExp) + 1)
    }

    var isValid: Bool {
        guard !palettes.isEmpty else { return false }
        guard palettes.allSatisfy({ $0.isValid }) else { return false }
        guard palettes.allSatisfy({ Int($0.entryCount) == paletteSize }) else { return false }
        return true
    }

    /// Primary RGB palette (backwards compat with GIP v1)
    var rgb: [[UInt8]] {
        return palettes.first?.rgb ?? []
    }

    // MARK: - Constants

    static let magic: [UInt8] = [0x47, 0x69, 0x50, 0x32] // "GiP2"
    static let currentVersion: UInt8 = 2  // V2: adds GIF89a round-trip fields

    // MARK: - Initialization

    /// Initialize with single palette (backwards compat with GIP v1)
    init(paletteExp: UInt8, rgb: [[UInt8]]) throws {
        guard paletteExp <= 7 else {
            throw GIPError.invalidPaletteExp(paletteExp)
        }

        let expectedSize = 1 << (Int(paletteExp) + 1)
        guard rgb.count == expectedSize else {
            throw GIPError.invalidPaletteSize(rgb.count, expected: expectedSize)
        }

        guard rgb.allSatisfy({ $0.count == 3 }) else {
            throw GIPError.invalidColorFormat
        }

        // Create single flat palette
        let palette = GIPPalette(
            entryCount: UInt16(expectedSize),
            dims: 1,
            dimA: UInt16(expectedSize),
            dimB: 1,
            ordering: .rowMajor,
            hasTransparency: false,
            transparentIndex: 0,
            label: "default",
            rgb: rgb,
            remap: nil,
            hash: nil
        )

        self.version = Self.currentVersion
        self.paletteExp = paletteExp
        self.hashAlg = .none
        self.hasGlobal = true
        self.hasFrameSet = false
        self.name = "GIP2"
        self.palettes = [palette]
        self.backgroundColorIndex = nil  // V2 field
        self.pixelAspectRatio = nil      // V2 field
    }

    /// Initialize with multiple palettes (GIP2 full format)
    init(
        paletteExp: UInt8,
        name: String,
        palettes: [GIPPalette],
        hasGlobal: Bool = true,
        hasFrameSet: Bool = false,
        hashAlg: HashAlgorithm = .sha256,
        backgroundColorIndex: UInt8? = nil,
        pixelAspectRatio: UInt8? = nil
    ) throws {
        guard paletteExp <= 7 else {
            throw GIPError.invalidPaletteExp(paletteExp)
        }

        guard !palettes.isEmpty else {
            throw GIPError.emptyPaletteSet
        }

        let expectedSize = 1 << (Int(paletteExp) + 1)
        guard palettes.allSatisfy({ Int($0.entryCount) == expectedSize }) else {
            throw GIPError.inconsistentPaletteSizes
        }

        self.version = Self.currentVersion
        self.paletteExp = paletteExp
        self.hashAlg = hashAlg
        self.hasGlobal = hasGlobal
        self.hasFrameSet = hasFrameSet
        self.name = name
        self.palettes = palettes
        self.backgroundColorIndex = backgroundColorIndex  // V2 field
        self.pixelAspectRatio = pixelAspectRatio          // V2 field
    }

    // MARK: - File I/O

    /// Load GIP from file
    static func load(from url: URL) throws -> GIP {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parse GIP2 from data
    static func parse(data: Data) throws -> GIP {
        guard data.count >= 16 else {
            throw GIPError.fileTooSmall(data.count)
        }

        var offset = 0

        // Check magic header
        let header = Array(data[offset..<offset+4])
        offset += 4
        guard header == magic else {
            throw GIPError.invalidMagic(header)
        }

        // Read header fields (little-endian)
        let version = data[offset]; offset += 1
        let paletteExp = data[offset]; offset += 1
        let hashAlgRaw = data[offset]; offset += 1
        let flags = data[offset]; offset += 1

        guard let hashAlg = HashAlgorithm(rawValue: hashAlgRaw) else {
            throw GIPError.invalidHashAlgorithm(hashAlgRaw)
        }

        let hasGlobal = (flags & 0x01) != 0
        let hasFrameSet = (flags & 0x02) != 0

        // CRITICAL FIX: Use loadUnaligned to handle arbitrary byte offsets
        // Data from files may not be aligned to type boundaries
        let paletteSetCount = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        let nameLen = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        guard offset + Int(nameLen) <= data.count else {
            throw GIPError.truncatedData
        }

        let nameData = data[offset..<offset+Int(nameLen)]
        let name = String(data: nameData, encoding: .utf8) ?? "unnamed"
        offset += Int(nameLen)

        // Parse each palette
        var palettes: [GIPPalette] = []
        for _ in 0..<paletteSetCount {
            guard offset + 16 <= data.count else {
                throw GIPError.truncatedData
            }

            let entryCount = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            offset += 2
            let dims = data[offset]; offset += 1
            let _ = data[offset]; offset += 1 // reserved
            let dimA = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            offset += 2
            let dimB = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            offset += 2
            let orderingRaw = data[offset]; offset += 1
            let hasTransparency = data[offset] != 0; offset += 1
            let transparentIndex = data[offset]; offset += 1
            let _ = data[offset]; offset += 1 // reserved2

            guard let ordering = PaletteOrdering(rawValue: orderingRaw) else {
                throw GIPError.invalidOrdering(orderingRaw)
            }

            let labelLen = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4

            guard offset + Int(labelLen) <= data.count else {
                throw GIPError.truncatedData
            }

            let labelData = data[offset..<offset+Int(labelLen)]
            let label = String(data: labelData, encoding: .utf8) ?? ""
            offset += Int(labelLen)

            let rgbLen = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4

            guard offset + Int(rgbLen) <= data.count else {
                throw GIPError.truncatedData
            }

            var rgb: [[UInt8]] = []
            for i in 0..<Int(entryCount) {
                let idx = offset + i * 3
                rgb.append([data[idx], data[idx+1], data[idx+2]])
            }
            offset += Int(rgbLen)

            // Optional remap
            let remapLen = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4
            var remap: [UInt8]? = nil
            if remapLen > 0 {
                remap = Array(data[offset..<offset+Int(remapLen)])
                offset += Int(remapLen)
            }

            // Optional hash
            let hashLen = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4
            var hash: Data? = nil
            if hashLen > 0 {
                hash = data[offset..<offset+Int(hashLen)]
                offset += Int(hashLen)
            }

            let palette = GIPPalette(
                entryCount: entryCount,
                dims: dims,
                dimA: dimA,
                dimB: dimB,
                ordering: ordering,
                hasTransparency: hasTransparency,
                transparentIndex: transparentIndex,
                label: label,
                rgb: rgb,
                remap: remap,
                hash: hash
            )
            palettes.append(palette)
        }

        // V2 fields (optional, for backward compatibility)
        var backgroundColorIndex: UInt8? = nil
        var pixelAspectRatio: UInt8? = nil

        if version >= 2 && offset + 2 <= data.count {
            backgroundColorIndex = data[offset]; offset += 1
            pixelAspectRatio = data[offset]; offset += 1
        }

        return try GIP(
            paletteExp: paletteExp,
            name: name,
            palettes: palettes,
            hasGlobal: hasGlobal,
            hasFrameSet: hasFrameSet,
            hashAlg: hashAlg,
            backgroundColorIndex: backgroundColorIndex,
            pixelAspectRatio: pixelAspectRatio
        )
    }

    /// Write GIP to file
    func write(to url: URL) throws {
        let data = try serialize()
        try data.write(to: url, options: .atomic)
    }

    /// Serialize GIP2 to data
    func serialize() throws -> Data {
        guard isValid else {
            throw GIPError.invalidPalette
        }

        var data = Data()

        // Write magic header
        data.append(contentsOf: Self.magic)

        // Write header fields (little-endian)
        data.append(version)
        data.append(paletteExp)
        data.append(hashAlg.rawValue)

        var flags: UInt8 = 0
        if hasGlobal { flags |= 0x01 }
        if hasFrameSet { flags |= 0x02 }
        data.append(flags)

        // Write palette set count
        var paletteSetCount = UInt32(palettes.count)
        data.append(contentsOf: withUnsafeBytes(of: &paletteSetCount) { Data($0) })

        // Write name
        let nameData = name.data(using: .utf8) ?? Data()
        var nameLen = UInt32(nameData.count)
        data.append(contentsOf: withUnsafeBytes(of: &nameLen) { Data($0) })
        data.append(nameData)

        // Write each palette
        for palette in palettes {
            var entryCount = palette.entryCount
            data.append(contentsOf: withUnsafeBytes(of: &entryCount) { Data($0) })
            data.append(palette.dims)
            data.append(0) // reserved
            var dimA = palette.dimA
            data.append(contentsOf: withUnsafeBytes(of: &dimA) { Data($0) })
            var dimB = palette.dimB
            data.append(contentsOf: withUnsafeBytes(of: &dimB) { Data($0) })
            data.append(palette.ordering.rawValue)
            data.append(palette.hasTransparency ? 1 : 0)
            data.append(palette.transparentIndex)
            data.append(0) // reserved2

            // Write label
            let labelData = palette.label.data(using: .utf8) ?? Data()
            var labelLen = UInt32(labelData.count)
            data.append(contentsOf: withUnsafeBytes(of: &labelLen) { Data($0) })
            data.append(labelData)

            // Write RGB data
            let rgbData = palette.rgb.flatMap { $0 }
            var rgbLen = UInt32(rgbData.count)
            data.append(contentsOf: withUnsafeBytes(of: &rgbLen) { Data($0) })
            data.append(contentsOf: rgbData)

            // Write optional remap
            if let remap = palette.remap {
                var remapLen = UInt32(remap.count)
                data.append(contentsOf: withUnsafeBytes(of: &remapLen) { Data($0) })
                data.append(contentsOf: remap)
            } else {
                var remapLen: UInt32 = 0
                data.append(contentsOf: withUnsafeBytes(of: &remapLen) { Data($0) })
            }

            // Write optional hash (or compute if needed)
            let hash: Data
            if let existingHash = palette.hash {
                hash = existingHash
            } else if hashAlg == .sha256 {
                let rgbDataForHash = Data(rgbData)
                hash = Data(SHA256.hash(data: rgbDataForHash))
            } else {
                hash = Data()
            }

            var hashLen = UInt32(hash.count)
            data.append(contentsOf: withUnsafeBytes(of: &hashLen) { Data($0) })
            data.append(hash)
        }

        // Write V2 fields (for version 2+)
        if version >= 2 {
            data.append(backgroundColorIndex ?? 0)
            data.append(pixelAspectRatio ?? 0)
        }

        return data
    }

    // MARK: - Errors

    enum GIPError: LocalizedError {
        case invalidPaletteExp(UInt8)
        case invalidPaletteSize(Int, expected: Int)
        case invalidColorFormat
        case fileTooSmall(Int)
        case invalidMagic([UInt8])
        case incorrectFileSize(Int, expected: Int)
        case invalidPalette
        case emptyPaletteSet
        case inconsistentPaletteSizes
        case invalidHashAlgorithm(UInt8)
        case invalidOrdering(UInt8)
        case truncatedData

        var errorDescription: String? {
            switch self {
            case .invalidPaletteExp(let exp):
                return "Invalid palette exponent: \(exp) (must be 0-7)"
            case .invalidPaletteSize(let size, let expected):
                return "Invalid palette size: \(size) (expected \(expected))"
            case .invalidColorFormat:
                return "Invalid color format (expected [R, G, B] triples)"
            case .fileTooSmall(let size):
                return "File too small: \(size) bytes (minimum 16 bytes for GIP2)"
            case .invalidMagic(let header):
                return "Invalid magic header: \(header.map { String(format: "%02X", $0) }.joined()) (expected GiP2)"
            case .incorrectFileSize(let size, let expected):
                return "Incorrect file size: \(size) bytes (expected \(expected))"
            case .invalidPalette:
                return "Invalid palette data"
            case .emptyPaletteSet:
                return "Palette set cannot be empty"
            case .inconsistentPaletteSizes:
                return "All palettes must have same entry count"
            case .invalidHashAlgorithm(let alg):
                return "Invalid hash algorithm: \(alg)"
            case .invalidOrdering(let ord):
                return "Invalid ordering: \(ord)"
            case .truncatedData:
                return "File truncated unexpectedly"
            }
        }
    }
}

// MARK: - Convenience Initializers

@available(iOS 26.0, *)
extension GIP {

    /// Create GIP from color palette (auto-calculates paletteExp)
    static func create(rgb: [[UInt8]]) throws -> GIP {
        let count = rgb.count
        guard count >= 2 && count <= 256 else {
            throw GIPError.invalidPaletteSize(count, expected: 256)
        }

        // Find smallest power of 2 >= count
        var paletteExp: UInt8 = 0
        while (1 << (Int(paletteExp) + 1)) < count {
            paletteExp += 1
        }

        let requiredSize = 1 << (Int(paletteExp) + 1)

        // Pad with black if needed
        var paddedRGB = rgb
        while paddedRGB.count < requiredSize {
            paddedRGB.append([0, 0, 0])
        }

        return try GIP(paletteExp: paletteExp, rgb: paddedRGB)
    }

    /// Create identity grayscale palette (for testing)
    static func grayscale256() throws -> GIP {
        var rgb: [[UInt8]] = []
        for i in 0..<256 {
            let gray = UInt8(i)
            rgb.append([gray, gray, gray])
        }
        return try GIP(paletteExp: 7, rgb: rgb)
    }
}