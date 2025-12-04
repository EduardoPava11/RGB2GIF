//
//  SplitFormatWriter.swift
//  RGB2GIF
//
//  Option A: Separate .gix (indices) + .gip (palettes) + .gim (manifest)
//  Supports hot-swapping palettes and independent file manipulation
//
//  File Format Specifications:
//
//  .gix (Grayscale/Index Stream):
//    Header: "GIX1" + uint16 width + uint16 height + uint16 frames + uint16 flags
//    Payload: frames × (width*height) bytes, sequential
//
//  .gip (Palette Stream):
//    Header: "GIP1" + uint16 entriesPerFrame(256) + uint16 bytesPerEntry(4) + uint16 frames + uint16 flags
//    Payload: frames × (256*4) bytes, as 16×16 RGBA8 grid per frame
//
//  .gim (Manifest, JSON):
//    magic, version, dims, delay_cs, loop, hashes(SHA256), binding, metadata
//

import Foundation
import UIKit
import CryptoKit
import os.log

private let writerLogger = Logger(subsystem: "com.rgb2gif", category: "SplitWriter")

// MARK: - File Headers

@available(iOS 26.0, *)
private struct GIXHeader {
    static let magic: [UInt8] = [0x47, 0x49, 0x58, 0x31]  // "GIX1"
    let width: UInt16
    let height: UInt16
    let frames: UInt16
    let flags: UInt16  // 0 = raw, 1 = LZW (future)

    func encode() -> Data {
        var data = Data(GIXHeader.magic)
        data.append(contentsOf: withUnsafeBytes(of: width.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: height.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: frames.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Data($0) })
        return data
    }

    static func decode(from data: Data) throws -> GIXHeader {
        guard data.count >= 12 else {
            throw SplitFormatError.invalidHeader
        }

        guard data[0..<4] == Data(magic) else {
            throw SplitFormatError.invalidMagic
        }

        // CRITICAL FIX: Use loadUnaligned to handle arbitrary byte offsets
        let width = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian }
        let height = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian }
        let frames = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).littleEndian }
        let flags = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: UInt16.self).littleEndian }

        return GIXHeader(width: width, height: height, frames: frames, flags: flags)
    }
}

@available(iOS 26.0, *)
private struct GIPHeader {
    static let magic: [UInt8] = [0x47, 0x49, 0x50, 0x31]  // "GIP1"
    let entriesPerFrame: UInt16 = 256
    let bytesPerEntry: UInt16 = 4  // RGBA8
    let frames: UInt16
    let flags: UInt16

    func encode() -> Data {
        var data = Data(GIPHeader.magic)
        data.append(contentsOf: withUnsafeBytes(of: entriesPerFrame.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: bytesPerEntry.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: frames.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Data($0) })
        return data
    }

    static func decode(from data: Data) throws -> GIPHeader {
        guard data.count >= 12 else {
            throw SplitFormatError.invalidHeader
        }

        guard data[0..<4] == Data(magic) else {
            throw SplitFormatError.invalidMagic
        }

        // CRITICAL FIX: Use loadUnaligned to handle arbitrary byte offsets
        let entriesPerFrame = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian }
        let bytesPerEntry = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian }
        let frames = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self).littleEndian }
        let flags = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: UInt16.self).littleEndian }

        return GIPHeader(entriesPerFrame: entriesPerFrame, bytesPerEntry: bytesPerEntry, frames: frames, flags: flags)
    }
}

// MARK: - Manifest Structure

@available(iOS 26.0, *)
public struct GIM: Codable {
    public let magic: String = "GIM1"
    public let version: Int = 1
    public let width: Int
    public let height: Int
    public let frames: Int
    public let delay_cs: Int   // Centiseconds (10 = 100ms)
    public let loop: Int       // 0 = infinite
    public let hashes: Hashes
    public let binding: [Int]  // palette_frame[index_frame]
    public let meta: Metadata?

    public struct Hashes: Codable {
        public let gix_sha256: String
        public let gip_sha256: String
    }

    public struct Metadata: Codable {
        public let author: String?
        public let title: String?
        public let createdAt: String
        public let device: String
        public let orientation: String  // "up", "down", "left", "right"
    }

    public init(
        width: Int,
        height: Int,
        frames: Int,
        delay_cs: Int,
        loop: Int,
        gix_sha256: String,
        gip_sha256: String,
        binding: [Int],
        meta: Metadata? = nil
    ) {
        self.width = width
        self.height = height
        self.frames = frames
        self.delay_cs = delay_cs
        self.loop = loop
        self.hashes = Hashes(gix_sha256: gix_sha256, gip_sha256: gip_sha256)
        self.binding = binding
        self.meta = meta
    }
}

// MARK: - Split Format Writer

/// Writes separate .gix, .gip, .gim files (Option A)
@available(iOS 26.0, *)
public final class SplitFormatWriter: FrameWriter {

    private let baseURL: URL
    private let width: Int
    private let height: Int
    private let frames: Int

    private let gixURL: URL
    private let gipURL: URL
    private let gimURL: URL

    private var gixHandle: FileHandle?
    private var gipHandle: FileHandle?

    private var gixHasher = SHA256()
    private var gipHasher = SHA256()

    private var framesWritten = 0

    // MARK: - Initialization

    public init(baseURL: URL, width: Int, height: Int, frames: Int) throws {
        self.baseURL = baseURL
        self.width = width
        self.height = height
        self.frames = frames

        // Generate file URLs
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")

        let basename = "\(timestamp)_\(width)x\(height)"
        self.gixURL = baseURL.appendingPathComponent("\(basename).gix")
        self.gipURL = baseURL.appendingPathComponent("\(basename).gip")
        self.gimURL = baseURL.appendingPathComponent("\(basename).gim")

        // Create output directory
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        // Write headers and open files
        try writeHeaders()

        writerLogger.info("SplitFormatWriter initialized: \(basename)")
    }

    // MARK: - Header Writing

    private func writeHeaders() throws {
        // Write GIX header
        let gixHeader = GIXHeader(
            width: UInt16(width),
            height: UInt16(height),
            frames: UInt16(frames),
            flags: 0
        )
        try gixHeader.encode().write(to: gixURL)

        // Open GIX for appending
        gixHandle = try FileHandle(forWritingTo: gixURL)
        try gixHandle?.seekToEnd()

        // Update hash with header
        let gixHeaderData = gixHeader.encode()
        gixHasher.update(data: gixHeaderData)

        // Write GIP header
        let gipHeader = GIPHeader(frames: UInt16(frames), flags: 0)
        try gipHeader.encode().write(to: gipURL)

        // Open GIP for appending
        gipHandle = try FileHandle(forWritingTo: gipURL)
        try gipHandle?.seekToEnd()

        // Update hash with header
        let gipHeaderData = gipHeader.encode()
        gipHasher.update(data: gipHeaderData)
    }

    // MARK: - FrameWriter Implementation

    public func append(indexHW: [UInt8], paletteRGBA256: [UInt8]) throws {
        guard framesWritten < frames else {
            throw SplitFormatError.tooManyFrames
        }

        // Validate sizes
        guard indexHW.count == width * height else {
            throw SplitFormatError.invalidIndexSize(expected: width * height, got: indexHW.count)
        }

        guard paletteRGBA256.count == 1024 else {
            throw SplitFormatError.invalidPaletteSize(expected: 1024, got: paletteRGBA256.count)
        }

        // Write index frame to .gix
        let indexData = Data(indexHW)
        try gixHandle?.write(contentsOf: indexData)
        gixHasher.update(data: indexData)

        // Write palette frame to .gip
        let paletteData = Data(paletteRGBA256)
        try gipHandle?.write(contentsOf: paletteData)
        gipHasher.update(data: paletteData)

        framesWritten += 1

        if framesWritten % 10 == 0 {
            writerLogger.debug("Written \(self.framesWritten)/\(self.frames) frames")
        }
    }

    public func close(config: ClipConfig) throws -> URL {
        // Close file handles
        try gixHandle?.close()
        try gipHandle?.close()

        // Finalize hashes
        let gixHash = gixHasher.finalize().hexString
        let gipHash = gipHasher.finalize().hexString

        // Create manifest
        let binding = Array(0..<framesWritten)  // 1:1 mapping by default

        let manifest = GIM(
            width: width,
            height: height,
            frames: framesWritten,
            delay_cs: Int(100.0 / Double(config.fps)),  // Convert fps to centiseconds
            loop: 0,  // Infinite loop
            gix_sha256: gixHash,
            gip_sha256: gipHash,
            binding: binding,
            meta: GIM.Metadata(
                author: nil,
                title: nil,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                device: UIDevice.current.model,
                orientation: "up"
            )
        )

        // Write manifest as JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: gimURL, options: .atomic)

        writerLogger.info("Split format files written:")
        writerLogger.info("  .gix: \(self.gixURL.lastPathComponent) (\(self.formatSize(self.gixURL)))")
        writerLogger.info("  .gip: \(self.gipURL.lastPathComponent) (\(self.formatSize(self.gipURL)))")
        writerLogger.info("  .gim: \(self.gimURL.lastPathComponent) (\(self.formatSize(self.gimURL)))")

        return gimURL
    }

    public func cancel() throws {
        try gixHandle?.close()
        try gipHandle?.close()

        try? FileManager.default.removeItem(at: gixURL)
        try? FileManager.default.removeItem(at: gipURL)
        try? FileManager.default.removeItem(at: gimURL)

        writerLogger.info("Split format write cancelled, files deleted")
    }

    // MARK: - Utilities

    private func formatSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return "unknown"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - Split Format Reader

/// Reads .gix + .gip + .gim files
@available(iOS 26.0, *)
public final class SplitFormatReader {

    private let gimURL: URL
    private let gixURL: URL
    private let gipURL: URL

    private let manifest: GIM

    public init(gimURL: URL) throws {
        self.gimURL = gimURL

        // Load manifest
        let manifestData = try Data(contentsOf: gimURL)
        self.manifest = try JSONDecoder().decode(GIM.self, from: manifestData)

        // Derive .gix and .gip paths from .gim
        let dir = gimURL.deletingLastPathComponent()
        let basename = gimURL.deletingPathExtension().lastPathComponent

        self.gixURL = dir.appendingPathComponent("\(basename).gix")
        self.gipURL = dir.appendingPathComponent("\(basename).gip")

        // Validate files exist
        guard FileManager.default.fileExists(atPath: gixURL.path) else {
            throw SplitFormatError.missingFile(gixURL)
        }

        guard FileManager.default.fileExists(atPath: gipURL.path) else {
            throw SplitFormatError.missingFile(gipURL)
        }

        writerLogger.info("SplitFormatReader initialized: \(basename)")
    }

    // MARK: - Reading

    /// Read a specific frame
    public func readFrame(at index: Int) throws -> (indices: [UInt8], palette: [UInt8]) {
        guard index < manifest.frames else {
            throw SplitFormatError.frameIndexOutOfRange
        }

        // Read .gix
        let gixData = try Data(contentsOf: gixURL)
        let gixHeader = try GIXHeader.decode(from: gixData)

        let indexOffset = 12 + index * Int(gixHeader.width) * Int(gixHeader.height)
        let indexSize = Int(gixHeader.width) * Int(gixHeader.height)
        let indexRange = indexOffset..<(indexOffset + indexSize)

        guard indexRange.upperBound <= gixData.count else {
            throw SplitFormatError.corruptedFile
        }

        let indices = [UInt8](gixData[indexRange])

        // Read .gip
        let gipData = try Data(contentsOf: gipURL)
        let gipHeader = try GIPHeader.decode(from: gipData)

        let paletteIndex = manifest.binding[index]
        let paletteOffset = 12 + paletteIndex * 1024
        let paletteRange = paletteOffset..<(paletteOffset + 1024)

        guard paletteRange.upperBound <= gipData.count else {
            throw SplitFormatError.corruptedFile
        }

        let palette = [UInt8](gipData[paletteRange])

        return (indices: indices, palette: palette)
    }

    /// Read all frames
    public func readAllFrames() throws -> [(indices: [UInt8], palette: [UInt8])] {
        var frames: [(indices: [UInt8], palette: [UInt8])] = []

        for i in 0..<manifest.frames {
            let frame = try readFrame(at: i)
            frames.append(frame)
        }

        return frames
    }

    /// Get manifest
    public func getManifest() -> GIM {
        return manifest
    }

    /// Verify file integrity
    public func verifyIntegrity() throws -> Bool {
        // Read files
        let gixData = try Data(contentsOf: gixURL)
        let gipData = try Data(contentsOf: gipURL)

        // Compute hashes
        let gixHash = SHA256.hash(data: gixData).hexString
        let gipHash = SHA256.hash(data: gipData).hexString

        // Compare with manifest
        return gixHash == manifest.hashes.gix_sha256 &&
               gipHash == manifest.hashes.gip_sha256
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
public enum SplitFormatError: LocalizedError {
    case invalidHeader
    case invalidMagic
    case tooManyFrames
    case invalidIndexSize(expected: Int, got: Int)
    case invalidPaletteSize(expected: Int, got: Int)
    case missingFile(URL)
    case frameIndexOutOfRange
    case corruptedFile

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid file header"
        case .invalidMagic:
            return "Invalid magic number"
        case .tooManyFrames:
            return "Too many frames written"
        case .invalidIndexSize(let expected, let got):
            return "Invalid index size: expected \(expected), got \(got)"
        case .invalidPaletteSize(let expected, let got):
            return "Invalid palette size: expected \(expected), got \(got)"
        case .missingFile(let url):
            return "Missing file: \(url.lastPathComponent)"
        case .frameIndexOutOfRange:
            return "Frame index out of range"
        case .corruptedFile:
            return "Corrupted file"
        }
    }
}

// MARK: - Crypto Extensions

@available(iOS 26.0, *)
extension SHA256Digest {
    var hexString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}
