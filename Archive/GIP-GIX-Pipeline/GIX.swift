//
//  GIX.swift
//  RGB2GIF
//
//  GiX2 Index Stream format
//  Magic: "GiX2" (4 bytes)
//  Version: u8 (currently 1)
//  Supports per-frame palette references, multiple data encodings, LZW min code size
//  Reference: GIF89a spec §15 (LZW), §16 (sub-blocks), §23 (GCE timing)
//

import Foundation

/// Data encoding for frame payload
/// Note: Only lzwSubblocks is valid for GIF export. rawIndices is for 3D visualization only.
@available(iOS 26.0, *)
public enum GIXDataEncoding: UInt8 {
    case lzwSubblocks = 0     // LZW + sub-blocks (GIF-ready for export)
    case rawIndices = 1        // Uncompressed index raster (for 3D voxel visualization)
}

/// GIX2 Frame - represents one frame with palette reference and timing
@available(iOS 26.0, *)
public struct GIXFrame {
    let paletteRef: UInt32      // Which GIP2 palette this frame uses
    let delay: UInt16           // centiseconds (1/100 sec)
    let disposal: UInt8         // 0=none, 1=keep, 2=restore bg, 3=restore prev
    let transparency: Bool
    let transparentIndex: UInt8
    let dataEncoding: GIXDataEncoding
    let payload: Data           // Frame data (format depends on dataEncoding)

    // MARK: - V2 Fields (GIF89a Round-Trip Support)
    // GIF89a Image Descriptor §20

    let left: UInt16            // §20 bytes 1-2 - frame X offset
    let top: UInt16             // §20 bytes 3-4 - frame Y offset
    let frameWidth: UInt16      // §20 bytes 5-6 - frame width (defaults to canvas width)
    let frameHeight: UInt16     // §20 bytes 7-8 - frame height (defaults to canvas height)
    let interlaced: Bool        // §20 byte 9 bit 6 - interlace flag

    var isValid: Bool {
        switch dataEncoding {
        case .lzwSubblocks:
            // For LZW, payload must be non-empty and contain at least the minimum:
            // - CLEAR code + EOI code = minimum 2 bytes after encoding
            // FIX: Previously returned true always, missing empty payload check!
            guard !payload.isEmpty else { return false }
            // Minimum valid LZW stream is ~2-3 bytes (CLEAR + EOI encoded)
            return payload.count >= 2
        case .rawIndices:
            // For raw, payload is width×height bytes
            return payload.count > 0
        }
    }
}

/// GIX2 Index Stream Container
/// Stores per-frame index streams with palette references and timing
@available(iOS 26.0, *)
public struct GIX {

    // MARK: - Properties

    let version: UInt8
    let width: UInt16
    let height: UInt16
    let lzwMinCodeSize: UInt8   // LZW initial code size (GIF §15: min 2, max 12)
    let defaultPaletteRef: UInt32 // Default palette (typically for Global Color Table)
    let name: String
    let frames: [GIXFrame]

    // MARK: - V2 Fields (GIF89a Round-Trip Support)
    // NETSCAPE2.0 Application Extension

    let loopCount: UInt16?      // nil = no loop, 0 = forever, 1+ = repeat count

    // MARK: - Computed Properties

    var frameCount: Int {
        return frames.count
    }

    var isValid: Bool {
        guard lzwMinCodeSize >= 2 && lzwMinCodeSize <= 12 else { return false }
        return frames.allSatisfy { $0.isValid }
    }

    // MARK: - Constants

    static let magic: [UInt8] = [0x47, 0x69, 0x58, 0x32] // "GiX2"
    static let currentVersion: UInt8 = 2  // V2: adds GIF89a round-trip fields

    // MARK: - Initialization

    /// Initialize with GIX2 format (full control)
    init(
        width: UInt16,
        height: UInt16,
        lzwMinCodeSize: UInt8,
        defaultPaletteRef: UInt32 = 0,
        name: String,
        frames: [GIXFrame],
        loopCount: UInt16? = nil
    ) throws {
        guard width > 0 && height > 0 else {
            throw GIXError.invalidDimensions(Int(width), Int(height))
        }

        guard lzwMinCodeSize >= 2 && lzwMinCodeSize <= 12 else {
            throw GIXError.invalidLZWMinCodeSize(lzwMinCodeSize)
        }

        guard !frames.isEmpty else {
            throw GIXError.noFrames
        }

        guard frames.allSatisfy({ $0.isValid }) else {
            throw GIXError.invalidFrameData
        }

        self.version = Self.currentVersion
        self.width = width
        self.height = height
        self.lzwMinCodeSize = lzwMinCodeSize
        self.defaultPaletteRef = defaultPaletteRef
        self.name = name
        self.frames = frames
        self.loopCount = loopCount  // V2 field
    }

    /// Backwards-compatible init (GIX v1 style, converts to GIX2)
    init(width: UInt16, height: UInt16, paletteExp: UInt8, frames oldFrames: [(delay: UInt16, disposal: UInt8, transparency: Bool, transparentIndex: UInt8, subBlocks: [Data])]) throws {
        guard width > 0 && height > 0 else {
            throw GIXError.invalidDimensions(Int(width), Int(height))
        }

        guard paletteExp <= 7 else {
            throw GIXError.invalidPaletteExp(paletteExp)
        }

        guard !oldFrames.isEmpty else {
            throw GIXError.noFrames
        }

        // Convert old-style frames to GIX2 frames
        var frames: [GIXFrame] = []
        for oldFrame in oldFrames {
            // Concatenate sub-blocks into single payload (GIX2 dataEncoding=0)
            let payload = oldFrame.subBlocks.reduce(Data()) { $0 + $1 }

            let frame = GIXFrame(
                paletteRef: 0,
                delay: oldFrame.delay,
                disposal: oldFrame.disposal,
                transparency: oldFrame.transparency,
                transparentIndex: oldFrame.transparentIndex,
                dataEncoding: .lzwSubblocks,
                payload: payload,
                left: 0,              // V2: default to origin
                top: 0,               // V2: default to origin
                frameWidth: width,    // V2: default to canvas size
                frameHeight: height,  // V2: default to canvas size
                interlaced: false     // V2: non-interlaced by default
            )
            frames.append(frame)
        }

        // LZW min code size = bits needed for palette (GIF §15)
        let lzwMinCodeSize = max(2, UInt8(paletteExp) + 1)

        self.version = Self.currentVersion
        self.width = width
        self.height = height
        self.lzwMinCodeSize = lzwMinCodeSize
        self.defaultPaletteRef = 0
        self.name = "GIX2"
        self.frames = frames
        self.loopCount = 0  // V2: loop forever by default
    }

    // MARK: - File I/O

    /// Load GIX from file
    static func load(from url: URL) throws -> GIX {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parse GIX2 from data
    static func parse(data: Data) throws -> GIX {
        guard data.count >= 20 else {
            throw GIXError.fileTooSmall(data.count)
        }

        var offset = 0

        // Check magic header
        let header = Array(data[offset..<offset+4])
        offset += 4
        guard header == magic else {
            throw GIXError.invalidMagic(header)
        }

        // Read header fields (little-endian)
        let version = data[offset]; offset += 1

        let width = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        offset += 2
        let height = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        offset += 2
        let frameCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        offset += 2

        let lzwMinCodeSize = data[offset]; offset += 1
        let _ = data[offset]; offset += 1 // reserved

        let defaultPaletteRef = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4

        let nameLen = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4

        guard offset + Int(nameLen) <= data.count else {
            throw GIXError.unexpectedEndOfFile
        }

        let nameData = data[offset..<offset+Int(nameLen)]
        let name = String(data: nameData, encoding: .utf8) ?? "unnamed"
        offset += Int(nameLen)

        // Parse frames
        var frames: [GIXFrame] = []
        for _ in 0..<frameCount {
            guard offset + 12 <= data.count else {
                throw GIXError.unexpectedEndOfFile
            }

            let paletteRef = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            let delay = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            let disposal = data[offset]; offset += 1
            let transpUsed = data[offset] != 0; offset += 1
            let transparentIndex = data[offset]; offset += 1
            let dataEncodingRaw = data[offset]; offset += 1

            guard let dataEncoding = GIXDataEncoding(rawValue: dataEncodingRaw) else {
                throw GIXError.invalidDataEncoding(dataEncodingRaw)
            }

            let payloadLen = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4

            guard offset + Int(payloadLen) <= data.count else {
                throw GIXError.unexpectedEndOfFile
            }

            let payload = data[offset..<offset+Int(payloadLen)]
            offset += Int(payloadLen)

            // V2 fields (optional, for backward compatibility)
            var left: UInt16 = 0
            var top: UInt16 = 0
            var frameWidth: UInt16 = width
            var frameHeight: UInt16 = height
            var interlaced: Bool = false

            if version >= 2 && offset + 9 <= data.count {
                left = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
                offset += 2
                top = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
                offset += 2
                frameWidth = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
                offset += 2
                frameHeight = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
                offset += 2
                interlaced = data[offset] != 0
                offset += 1
            }

            let frame = GIXFrame(
                paletteRef: paletteRef,
                delay: delay,
                disposal: disposal,
                transparency: transpUsed,
                transparentIndex: transparentIndex,
                dataEncoding: dataEncoding,
                payload: Data(payload),
                left: left,
                top: top,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                interlaced: interlaced
            )
            frames.append(frame)
        }

        // V2 field: loopCount (optional)
        var loopCount: UInt16? = nil
        if version >= 2 && offset + 2 <= data.count {
            let loopFlag = data[offset]; offset += 1
            if loopFlag != 0 {
                loopCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
                offset += 2
            } else {
                offset += 2  // Skip reserved bytes
            }
        }

        return try GIX(
            width: width,
            height: height,
            lzwMinCodeSize: lzwMinCodeSize,
            defaultPaletteRef: defaultPaletteRef,
            name: name,
            frames: frames,
            loopCount: loopCount
        )
    }

    /// Write GIX to file
    func write(to url: URL) throws {
        let data = try serialize()
        try data.write(to: url, options: .atomic)
    }

    /// Serialize GIX2 to data
    func serialize() throws -> Data {
        guard isValid else {
            throw GIXError.invalidFrameData
        }

        var data = Data()

        // Write magic header
        data.append(contentsOf: Self.magic)

        // Write header fields (little-endian)
        data.append(version)

        var width = self.width
        data.append(contentsOf: withUnsafeBytes(of: &width) { Data($0) })
        var height = self.height
        data.append(contentsOf: withUnsafeBytes(of: &height) { Data($0) })
        var frameCount = UInt16(frames.count)
        data.append(contentsOf: withUnsafeBytes(of: &frameCount) { Data($0) })

        data.append(lzwMinCodeSize)
        data.append(0) // reserved

        var defaultPaletteRef = self.defaultPaletteRef
        data.append(contentsOf: withUnsafeBytes(of: &defaultPaletteRef) { Data($0) })

        // Write name
        let nameData = name.data(using: .utf8) ?? Data()
        var nameLen = UInt32(nameData.count)
        data.append(contentsOf: withUnsafeBytes(of: &nameLen) { Data($0) })
        data.append(nameData)

        // Write frames
        for frame in frames {
            var paletteRef = frame.paletteRef
            data.append(contentsOf: withUnsafeBytes(of: &paletteRef) { Data($0) })

            var delay = frame.delay
            data.append(contentsOf: withUnsafeBytes(of: &delay) { Data($0) })

            data.append(frame.disposal)
            data.append(frame.transparency ? 1 : 0)
            data.append(frame.transparentIndex)
            data.append(frame.dataEncoding.rawValue)

            var payloadLen = UInt32(frame.payload.count)
            data.append(contentsOf: withUnsafeBytes(of: &payloadLen) { Data($0) })
            data.append(frame.payload)

            // Write V2 frame fields (for version 2+)
            if version >= 2 {
                var left = frame.left
                data.append(contentsOf: withUnsafeBytes(of: &left) { Data($0) })
                var top = frame.top
                data.append(contentsOf: withUnsafeBytes(of: &top) { Data($0) })
                var frameWidth = frame.frameWidth
                data.append(contentsOf: withUnsafeBytes(of: &frameWidth) { Data($0) })
                var frameHeight = frame.frameHeight
                data.append(contentsOf: withUnsafeBytes(of: &frameHeight) { Data($0) })
                data.append(frame.interlaced ? 1 : 0)
            }
        }

        // Write V2 loopCount field (for version 2+)
        if version >= 2 {
            if let loopCount = loopCount {
                data.append(1)  // Loop flag present
                var count = loopCount
                data.append(contentsOf: withUnsafeBytes(of: &count) { Data($0) })
            } else {
                data.append(0)  // No loop
                data.append(contentsOf: [0, 0])  // Reserved
            }
        }

        return data
    }

    // MARK: - Errors

    public enum GIXError: LocalizedError {
        case invalidDimensions(Int, Int)
        case invalidPaletteExp(UInt8)
        case invalidLZWMinCodeSize(UInt8)
        case noFrames
        case invalidFrameData
        case fileTooSmall(Int)
        case invalidMagic([UInt8])
        case unexpectedEndOfFile
        case frameCountMismatch(Int, expected: Int)
        case subBlockTooLarge(Int)
        case invalidDataEncoding(UInt8)

        public var errorDescription: String? {
            switch self {
            case .invalidDimensions(let w, let h):
                return "Invalid dimensions: \(w)×\(h)"
            case .invalidPaletteExp(let exp):
                return "Invalid palette exponent: \(exp) (must be 0-7)"
            case .invalidLZWMinCodeSize(let size):
                return "Invalid LZW min code size: \(size) (must be 2-12)"
            case .noFrames:
                return "No frames provided"
            case .invalidFrameData:
                return "Invalid frame data"
            case .fileTooSmall(let size):
                return "File too small: \(size) bytes (minimum 20 bytes for GIX2)"
            case .invalidMagic(let header):
                return "Invalid magic header: \(header.map { String(format: "%02X", $0) }.joined()) (expected GiX2)"
            case .unexpectedEndOfFile:
                return "Unexpected end of file"
            case .frameCountMismatch(let actual, let expected):
                return "Frame count mismatch: \(actual) (expected \(expected))"
            case .subBlockTooLarge(let size):
                return "Sub-block too large: \(size) bytes (maximum 255)"
            case .invalidDataEncoding(let enc):
                return "Invalid data encoding: \(enc)"
            }
        }
    }
}