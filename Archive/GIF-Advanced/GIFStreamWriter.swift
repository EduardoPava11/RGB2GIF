//
//  GIFStreamWriter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  GIF STREAM WRITER - BYTE-LEVEL GIF89a OUTPUT                             ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║  PURPOSE: Write GIF89a binary format to disk incrementally                ║
//  ║                                                                           ║
//  ║  GIF FILE STRUCTURE:                                                      ║
//  ║  ┌────────────────────────────────────────────────────────────────────┐  ║
//  ║  │ Header: "GIF89a" (6 bytes)                                         │  ║
//  ║  ├────────────────────────────────────────────────────────────────────┤  ║
//  ║  │ Logical Screen Descriptor (7 bytes)                                │  ║
//  ║  │   - Width (2), Height (2), Packed (1), BgColor (1), Aspect (1)    │  ║
//  ║  ├────────────────────────────────────────────────────────────────────┤  ║
//  ║  │ Global Color Table (3 × 2^(paletteExp+1) bytes)                    │  ║
//  ║  ├────────────────────────────────────────────────────────────────────┤  ║
//  ║  │ Netscape Loop Extension (19 bytes, optional)                       │  ║
//  ║  ├────────────────────────────────────────────────────────────────────┤  ║
//  ║  │ FOR EACH FRAME:                                                    │  ║
//  ║  │   ├─ Graphic Control Extension (8 bytes)                           │  ║
//  ║  │   ├─ Image Descriptor (10 bytes)                                   │  ║
//  ║  │   ├─ [Local Color Table, if present]                               │  ║
//  ║  │   └─ Image Data: minCodeSize + sub-blocks + terminator             │  ║
//  ║  ├────────────────────────────────────────────────────────────────────┤  ║
//  ║  │ Trailer: 0x3B (1 byte)                                             │  ║
//  ║  └────────────────────────────────────────────────────────────────────┘  ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//
//  DEBUG FLAGS:
//  - DEBUG_GIF_WRITER: Log file structure as it's written
//  - DEBUG_SUBBLOCKS: Log sub-block sizes during image data write
//

import Foundation
import os.log

// ════════════════════════════════════════════════════════════════════════════
// DEBUG FLAGS - Set to true to enable GIF writer tracing
// ════════════════════════════════════════════════════════════════════════════
private let DEBUG_GIF_WRITER = true      // Log file structure
private let DEBUG_SUBBLOCKS = true       // Log sub-block writes (verbose)

private let writerLogger = Logger(subsystem: "com.rgb2gif", category: "GIFStreamWriter")

/// Streaming GIF writer - writes frames incrementally to disk
@available(iOS 26.0, *)
struct GIFStreamWriter {

    // MARK: - Properties

    private let fileHandle: FileHandle
    private let url: URL

    private var width: UInt16 = 0
    private var height: UInt16 = 0
    private var paletteExp: UInt8 = 0
    private var hasBegun = false
    private var framesWritten = 0

    // MARK: - Initialization

    /// Initialize writer with output URL
    /// - Parameter url: Output file URL
    init(outputURL: URL) throws {
        self.url = outputURL

        // Create empty file
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw WriterError.cannotOpenFile(url)
        }

        self.fileHandle = handle
    }

    // MARK: - Public API

    /// Begin GIF file - write header and global color table
    /// - Parameters:
    ///   - width: Image width
    ///   - height: Image height
    ///   - paletteExp: Palette exponent (0-7, size = 2^(exp+1))
    ///   - globalPaletteRGB: Global color table as [[R, G, B]]
    ///   - loopForever: Whether to add Netscape loop extension (defaults to true)
    ///   - loopCount: Loop count for Netscape extension (0 = forever, V2 field)
    ///   - backgroundColorIndex: Background color index (V2 field, GIP §18 byte 11)
    ///   - pixelAspectRatio: Pixel aspect ratio (V2 field, GIP §18 byte 12)
    mutating func begin(width: UInt16, height: UInt16,
                       paletteExp: UInt8,
                       globalPaletteRGB: [[UInt8]],
                       loopForever: Bool = true,
                       loopCount: UInt16 = 0,
                       backgroundColorIndex: UInt8? = nil,
                       pixelAspectRatio: UInt8? = nil) throws {
        guard !hasBegun else {
            throw WriterError.alreadyBegun
        }

        guard width > 0 && height > 0 else {
            throw WriterError.invalidDimensions(Int(width), Int(height))
        }

        guard paletteExp <= 7 else {
            throw WriterError.invalidPaletteExp(paletteExp)
        }

        let paletteSize = 1 << (Int(paletteExp) + 1)
        guard globalPaletteRGB.count == paletteSize else {
            throw WriterError.invalidPaletteSize(globalPaletteRGB.count, expected: paletteSize)
        }

        self.width = width
        self.height = height
        self.paletteExp = paletteExp

        // Write header
        try writeHeader()

        // Write logical screen descriptor (with V2 fields)
        try writeLogicalScreenDescriptor(
            paletteExp: paletteExp,
            backgroundColorIndex: backgroundColorIndex,
            pixelAspectRatio: pixelAspectRatio
        )

        // Write global color table
        try writeGlobalColorTable(rgb: globalPaletteRGB)

        // Write Netscape loop extension immediately after GCT (required position)
        // V2: Use explicit loopCount
        if loopForever {
            try writeNetscapeLoopExtension(loopCount: loopCount)
        }

        hasBegun = true
        writerLogger.info("GIF stream begun: \(width)×\(height), palette=\(paletteSize) colors, loop=\(loopForever)")
    }

    // ┌─────────────────────────────────────────────────────────────────┐
    // │ ADD FRAME: Write GCE + Image Descriptor + Image Data             │
    // └─────────────────────────────────────────────────────────────────┘
    /// Add a frame to the GIF
    /// - Parameters:
    ///   - frame: GIXFrame with delay, disposal, transparency, and LZW data
    ///   - useLocalCT: Whether to use local color table (defaults to false)
    ///   - localCT: Local color table if useLocalCT is true
    mutating func addFrame(_ frame: GIXFrame,
                          lzwMinCodeSize: UInt8,
                          useLocalCT: Bool = false,
                          localCT: [[UInt8]]? = nil) throws {
        guard hasBegun else {
            throw WriterError.notBegun
        }

        guard frame.isValid else {
            if DEBUG_GIF_WRITER {
                writerLogger.error("❌ Invalid frame: payload=\(frame.payload.count) bytes, \(frame.frameWidth)×\(frame.frameHeight)")
            }
            throw WriterError.invalidFrameData
        }

        if DEBUG_GIF_WRITER {
            let frameNum = framesWritten + 1
            writerLogger.debug("┌─ addFrame #\(frameNum) ─────────────────────────")
            writerLogger.debug("│ Frame size: \(frame.frameWidth)×\(frame.frameHeight)")
            writerLogger.debug("│ Position: (\(frame.left), \(frame.top))")
            writerLogger.debug("│ Payload: \(frame.payload.count) bytes")
            writerLogger.debug("│ LZW minCodeSize: \(lzwMinCodeSize)")
        }

        // Write graphic control extension
        try writeGraphicControlExtension(
            delay: frame.delay,
            disposal: frame.disposal,
            transparency: frame.transparency,
            transparentIndex: frame.transparentIndex
        )

        // Write image descriptor (with V2 frame rect/interlace fields)
        try writeImageDescriptor(
            left: frame.left,
            top: frame.top,
            width: frame.frameWidth,
            height: frame.frameHeight,
            interlaced: frame.interlaced,
            useLocalCT: useLocalCT,
            localPaletteExp: useLocalCT ? paletteExp : nil
        )

        // Write local color table if specified
        if useLocalCT, let localCT = localCT {
            try writeColorTable(rgb: localCT)
            if DEBUG_GIF_WRITER {
                writerLogger.debug("│ Local CT: \(localCT.count) colors")
            }
        }

        // Write image data (LZW from GIX2 payload)
        // GIX2 dataEncoding=0 means payload is already LZW sub-block data
        switch frame.dataEncoding {
        case .lzwSubblocks:
            // Payload is raw sub-block data - split into ≤255B chunks
            try writeImageDataFromPayload(
                payload: frame.payload,
                minCodeSize: lzwMinCodeSize
            )
        case .rawIndices:
            // rawIndices is for 3D visualization only, not valid for GIF export
            throw WriterError.unsupportedEncoding("rawIndices is for 3D visualization only - use lzwSubblocks for GIF export")
        }

        framesWritten += 1
        let count = framesWritten

        if DEBUG_GIF_WRITER {
            writerLogger.debug("└─ Frame \(count) complete ─────────────────────────")
        } else {
            writerLogger.debug("Frame \(count) written")
        }
    }

    /// End GIF file - write trailer
    mutating func end() throws {
        guard hasBegun else {
            throw WriterError.notBegun
        }

        // Write trailer
        try write([0x3B])

        // Close file
        try fileHandle.close()

        let total = framesWritten
        writerLogger.info("GIF completed: \(total) frames written")
    }

    // MARK: - Private Writing Methods

    private func writeHeader() throws {
        // "GIF89a"
        let header: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        try write(header)
    }

    private func writeLogicalScreenDescriptor(
        paletteExp: UInt8,
        backgroundColorIndex: UInt8? = nil,
        pixelAspectRatio: UInt8? = nil
    ) throws {
        var bytes: [UInt8] = []

        // Width (2 bytes, little-endian)
        bytes.append(UInt8(width & 0xFF))
        bytes.append(UInt8(width >> 8))

        // Height (2 bytes, little-endian)
        bytes.append(UInt8(height & 0xFF))
        bytes.append(UInt8(height >> 8))

        // Packed byte: GCT flag (1), color res (3), sort flag (1), GCT size (3)
        let gctFlag: UInt8 = 0b1000_0000  // GCT present
        let colorRes: UInt8 = 0b0111_0000  // 8 bits per channel
        let sortFlag: UInt8 = 0b0000_0000  // Not sorted
        let gctSize: UInt8 = paletteExp    // Size = 2^(N+1)
        let packed = gctFlag | colorRes | sortFlag | gctSize
        bytes.append(packed)

        // Background color index (V2: use from GIP if available)
        bytes.append(backgroundColorIndex ?? 0)

        // Pixel aspect ratio (V2: use from GIP if available)
        // 0 = no aspect ratio info
        bytes.append(pixelAspectRatio ?? 0)

        try write(bytes)
    }

    private func writeGlobalColorTable(rgb: [[UInt8]]) throws {
        try writeColorTable(rgb: rgb)
    }

    private func writeColorTable(rgb: [[UInt8]]) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rgb.count * 3)

        for color in rgb {
            guard color.count == 3 else {
                throw WriterError.invalidColorFormat
            }
            bytes.append(color[0]) // R
            bytes.append(color[1]) // G
            bytes.append(color[2]) // B
        }

        try write(bytes)
    }

    /// Write Netscape looping extension (NETSCAPE2.0 with configurable loop count)
    /// Must be written immediately after Global Color Table, before any frames
    /// Reference: http://www.vurdalakov.net/misc/gif/netscape-looping-application-extension
    /// - Parameter loopCount: Loop count (0 = infinite, V2 field from GIX)
    private func writeNetscapeLoopExtension(loopCount: UInt16 = 0) throws {
        var bytes: [UInt8] = []

        // Extension introducer
        bytes.append(0x21)

        // Application extension label
        bytes.append(0xFF)

        // Block size (always 11 for NETSCAPE2.0)
        bytes.append(11)

        // Application identifier: "NETSCAPE" (8 bytes)
        bytes.append(contentsOf: [0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45])

        // Application authentication code: "2.0" (3 bytes)
        bytes.append(contentsOf: [0x32, 0x2E, 0x30])

        // Sub-block: data sub-block with loop count
        bytes.append(3)  // Sub-block size

        // Index (always 1 for loop count)
        bytes.append(1)

        // Loop count (0 = infinite, little-endian UInt16) - V2: use explicit count
        bytes.append(UInt8(loopCount & 0xFF))       // Low byte
        bytes.append(UInt8((loopCount >> 8) & 0xFF)) // High byte

        // Block terminator
        bytes.append(0)

        try write(bytes)
    }

    private func writeGraphicControlExtension(delay: UInt16, disposal: UInt8,
                                             transparency: Bool,
                                             transparentIndex: UInt8) throws {
        var bytes: [UInt8] = []

        // Extension introducer
        bytes.append(0x21)

        // Graphic control label
        bytes.append(0xF9)

        // Block size (always 4)
        bytes.append(4)

        // Packed byte: reserved (3), disposal (3), user input (1), transparent (1)
        let disposalBits = (disposal & 0x07) << 2
        let transparentBit: UInt8 = transparency ? 0x01 : 0x00
        let packed = disposalBits | transparentBit
        bytes.append(packed)

        // Delay time (2 bytes, little-endian, in centiseconds)
        bytes.append(UInt8(delay & 0xFF))
        bytes.append(UInt8(delay >> 8))

        // Transparent color index
        bytes.append(transparentIndex)

        // Block terminator
        bytes.append(0)

        try write(bytes)
    }

    private func writeImageDescriptor(
        left: UInt16 = 0,
        top: UInt16 = 0,
        width: UInt16,
        height: UInt16,
        interlaced: Bool = false,
        useLocalCT: Bool,
        localPaletteExp: UInt8?
    ) throws {
        var bytes: [UInt8] = []

        // Image separator
        bytes.append(0x2C)

        // Left position (2 bytes, little-endian) - V2: from GIXFrame
        bytes.append(UInt8(left & 0xFF))
        bytes.append(UInt8((left >> 8) & 0xFF))

        // Top position (2 bytes, little-endian) - V2: from GIXFrame
        bytes.append(UInt8(top & 0xFF))
        bytes.append(UInt8((top >> 8) & 0xFF))

        // Width (2 bytes, little-endian) - V2: from GIXFrame
        bytes.append(UInt8(width & 0xFF))
        bytes.append(UInt8((width >> 8) & 0xFF))

        // Height (2 bytes, little-endian) - V2: from GIXFrame
        bytes.append(UInt8(height & 0xFF))
        bytes.append(UInt8((height >> 8) & 0xFF))

        // Packed byte: LCT flag (1), interlace (1), sort (1), reserved (2), LCT size (3)
        var packed: UInt8 = 0

        if useLocalCT, let exp = localPaletteExp {
            packed |= 0b1000_0000  // LCT present
            packed |= (exp & 0x07)  // LCT size
        }

        // V2: Set interlace flag from GIXFrame
        if interlaced {
            packed |= 0b0100_0000  // Interlace flag (bit 6)
        }

        bytes.append(packed)

        try write(bytes)
    }

    private func writeImageData(subBlocks: [Data], minCodeSize: UInt8) throws {
        // Write LZW minimum code size
        try write([minCodeSize])

        // Write sub-blocks
        for block in subBlocks {
            guard block.count <= 255 else {
                throw WriterError.subBlockTooLarge(block.count)
            }

            // Write block size
            try write([UInt8(block.count)])

            // Write block data
            try write([UInt8](block))
        }

        // Write block terminator
        try write([0])
    }

    // ┌─────────────────────────────────────────────────────────────────┐
    // │ CRITICAL: Write LZW-compressed image data as sub-blocks          │
    // │ This is where the "1/4 renders" bug likely manifests!            │
    // └─────────────────────────────────────────────────────────────────┘
    /// Write image data from GIX2 payload (already LZW-compressed)
    private func writeImageDataFromPayload(payload: Data, minCodeSize: UInt8) throws {

        if DEBUG_GIF_WRITER {
            writerLogger.debug("═══════════════════════════════════════════════")
            writerLogger.debug("writeImageDataFromPayload: \(payload.count) bytes, minCodeSize=\(minCodeSize)")
        }

        // ⚠️ CRITICAL CHECK: Empty payload = corrupt frame
        if payload.isEmpty {
            writerLogger.error("❌ EMPTY PAYLOAD - frame will not render!")
        }

        // Write LZW minimum code size
        try write([minCodeSize])

        // Split payload into ≤255 byte sub-blocks
        var offset = 0
        var subBlockCount = 0

        while offset < payload.count {
            let remaining = payload.count - offset
            let blockSize = min(remaining, 255)

            // Write block size
            try write([UInt8(blockSize)])

            // Write block data
            let blockData = payload[offset..<offset+blockSize]
            try write([UInt8](blockData))

            subBlockCount += 1

            if DEBUG_SUBBLOCKS && (subBlockCount <= 3 || remaining <= 255) {
                writerLogger.debug("  Sub-block \(subBlockCount): \(blockSize) bytes (offset \(offset)/\(payload.count))")
            }

            offset += blockSize
        }

        // Write block terminator
        try write([0])

        if DEBUG_GIF_WRITER {
            writerLogger.debug("  Total: \(subBlockCount) sub-blocks written")
            writerLogger.debug("═══════════════════════════════════════════════")
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        let data = Data(bytes)
        fileHandle.write(data)
    }

    // MARK: - Errors

    enum WriterError: LocalizedError {
        case cannotOpenFile(URL)
        case alreadyBegun
        case notBegun
        case invalidDimensions(Int, Int)
        case invalidPaletteExp(UInt8)
        case invalidPaletteSize(Int, expected: Int)
        case invalidFrameData
        case invalidColorFormat
        case subBlockTooLarge(Int)
        case unsupportedEncoding(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let url):
                return "Cannot open file for writing: \(url.path)"
            case .alreadyBegun:
                return "GIF stream already begun"
            case .notBegun:
                return "GIF stream not begun - call begin() first"
            case .invalidDimensions(let w, let h):
                return "Invalid dimensions: \(w)×\(h)"
            case .invalidPaletteExp(let exp):
                return "Invalid palette exponent: \(exp) (must be 0-7)"
            case .invalidPaletteSize(let size, let expected):
                return "Invalid palette size: \(size) (expected \(expected))"
            case .invalidFrameData:
                return "Invalid frame data (sub-block >255 bytes)"
            case .invalidColorFormat:
                return "Invalid color format (expected [R, G, B])"
            case .subBlockTooLarge(let size):
                return "Sub-block too large: \(size) bytes (maximum 255)"
            case .unsupportedEncoding(let desc):
                return "Unsupported data encoding: \(desc)"
            }
        }
    }
}

// MARK: - Convenience Wrapper

@available(iOS 26.0, *)
extension GIFStreamWriter {

    /// Write complete GIF from GIX and GIP
    /// - Parameters:
    ///   - gix: Index stream
    ///   - gip: Palette
    ///   - outputURL: Output file URL
    ///   - loopForever: Whether to loop animation
    static func write(gix: GIX, gip: GIP, to outputURL: URL, loopForever: Bool = true) throws {
        var writer = try GIFStreamWriter(outputURL: outputURL)

        try writer.begin(
            width: gix.width,
            height: gix.height,
            paletteExp: gip.paletteExp,
            globalPaletteRGB: gip.rgb
        )

        for frame in gix.frames {
            try writer.addFrame(frame, lzwMinCodeSize: gix.lzwMinCodeSize)
        }

        try writer.end()
    }
}