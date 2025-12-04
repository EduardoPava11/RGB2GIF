//
//  SessionCoordinator.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  SESSION COORDINATOR - ORCHESTRATES FULL CBOR EXPORT                     ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Main entry point for CBOR debug data export:                            ║
//  ║  • Creates session directory structure                                   ║
//  ║  • Coordinates L0-L4 exporters                                           ║
//  ║  • Computes and writes checksums                                         ║
//  ║  • Generates manifest.cbor with verification chain                       ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import QuartzCore
import SwiftCBOR
import os.log

private let coordinatorLogger = Logger(subsystem: "com.rgb2gif", category: "SessionCoordinator")

// MARK: - Export Options

@available(iOS 26.0, *)
public struct CBORExportOptions {
    /// Export L0 frames (default: true)
    public var exportFrames: Bool = true
    /// Export L1 tensor cells (default: true)
    public var exportTensorCells: Bool = true
    /// Export L2 palette (default: true)
    public var exportPalette: Bool = true
    /// Export L3 indices (default: true)
    public var exportIndices: Bool = true
    /// Generate PNG verification files (default: true)
    public var generatePNGs: Bool = true
    /// Compute SHA-256 checksums (default: true)
    public var computeChecksums: Bool = true

    public init() {}

    /// Full export (all layers)
    public static let full = CBORExportOptions()

    /// Minimal export (frames only)
    public static var framesOnly: CBORExportOptions {
        var opts = CBORExportOptions()
        opts.exportTensorCells = false
        opts.exportPalette = false
        opts.exportIndices = false
        opts.generatePNGs = false
        return opts
    }
}

// MARK: - Export Result

@available(iOS 26.0, *)
public struct CBORExportResult {
    public let sessionID: String
    public let sessionURL: URL
    public let totalBytes: Int64
    public let fileCount: Int
    public let exportDurationMS: Double

    public var formattedSize: String {
        CBORSessionManager.formatBytes(totalBytes)
    }
}

// MARK: - SessionCoordinator

@available(iOS 26.0, *)
public final class SessionCoordinator {

    // MARK: - Properties

    public let session: CBORSessionManager
    public let manifest: CBORManifest

    private let frameExporter: CBORFrameExporter
    private let tensorExporter: CBORTensorExporter
    private let paletteExporter: CBORPaletteExporter
    private let indicesExporter: CBORIndicesExporter

    // MARK: - Initialization

    /// Create a new session coordinator with a fresh session
    public init() throws {
        self.session = try CBORSessionManager()
        self.manifest = CBORManifest(sessionID: session.sessionID)

        self.frameExporter = CBORFrameExporter(session: session)
        self.tensorExporter = CBORTensorExporter(session: session)
        self.paletteExporter = CBORPaletteExporter(session: session)
        self.indicesExporter = CBORIndicesExporter(session: session)

        coordinatorLogger.info("Created SessionCoordinator: \(self.session.sessionID)")
    }

    /// Create coordinator for an existing session
    public init(existingSessionID: String) throws {
        self.session = try CBORSessionManager(existingSessionID: existingSessionID)
        self.manifest = CBORManifest(sessionID: session.sessionID)

        self.frameExporter = CBORFrameExporter(session: session)
        self.tensorExporter = CBORTensorExporter(session: session)
        self.paletteExporter = CBORPaletteExporter(session: session)
        self.indicesExporter = CBORIndicesExporter(session: session)

        coordinatorLogger.info("Loaded SessionCoordinator: \(self.session.sessionID)")
    }

    // MARK: - Full Export

    /// Export complete pipeline data to CBOR
    /// - Parameters:
    ///   - frames: 81 CGImages (each 81×81)
    ///   - tensor: TensorCube729
    ///   - palette: 256-color palette (ARGB UInt32)
    ///   - frameIndices: 81 arrays of 6,561 indices each
    ///   - options: Export options
    /// - Returns: Export result with statistics
    public func exportFull(
        frames: [CGImage],
        tensor: TensorCube729,
        palette: [UInt32],
        frameIndices: [[UInt8]],
        gifData: Data? = nil,
        options: CBORExportOptions = .full
    ) throws -> CBORExportResult {
        let startTime = CACurrentMediaTime()
        var totalBytes: Int64 = 0
        var fileCount = 0

        coordinatorLogger.info("Starting full CBOR export...")

        // L0: Frames
        if options.exportFrames {
            let l0Bytes = try frameExporter.exportAllFrames(frames)
            manifest.l0Frames.fileCount = 81
            manifest.l0Frames.totalBytes = l0Bytes
            if options.computeChecksums {
                manifest.l0Frames.sha256 = try CBORManifest.sha256(filesIn: session.l0FramesURL)
            }
            totalBytes += l0Bytes
            fileCount += 81
            if options.generatePNGs { fileCount += 81 }  // PNGs
            coordinatorLogger.debug("L0 frames exported: \(l0Bytes) bytes")
        }

        // L1: Tensor cells
        if options.exportTensorCells {
            let l1Bytes = try tensorExporter.exportAllCells(from: tensor)
            manifest.l1Tensor.fileCount = 729 + 1  // 729 cells + summary
            manifest.l1Tensor.totalBytes = l1Bytes
            manifest.l1Tensor.algorithm = AlgorithmVersions.tensorBuilder
            manifest.l1Tensor.inputSHA256 = manifest.l0Frames.sha256
            if options.computeChecksums {
                manifest.l1Tensor.sha256 = try CBORManifest.sha256(filesIn: session.l1TensorCellsURL)
            }
            totalBytes += l1Bytes
            fileCount += 730
            if options.generatePNGs { fileCount += 1 }  // Grid PNG
            coordinatorLogger.debug("L1 tensor cells exported: \(l1Bytes) bytes")
        }

        // L2: Palette
        if options.exportPalette {
            let l2Bytes = try paletteExporter.exportPalette(palette)
            let mapping = paletteExporter.computeMapping(tensor: tensor, palette: palette)
            let mappingBytes = try paletteExporter.exportMapping(mapping)

            manifest.l2Palette.fileCount = 2
            manifest.l2Palette.totalBytes = l2Bytes + mappingBytes
            manifest.l2Palette.algorithm = AlgorithmVersions.quantizer
            manifest.l2Palette.inputSHA256 = manifest.l1Tensor.sha256
            if options.computeChecksums {
                manifest.l2Palette.sha256 = try CBORManifest.sha256(filesIn: session.l2PaletteURL)
            }
            totalBytes += l2Bytes + mappingBytes
            fileCount += 2
            if options.generatePNGs { fileCount += 1 }  // Palette PNG
            coordinatorLogger.debug("L2 palette exported: \(l2Bytes + mappingBytes) bytes")
        }

        // L3: Indices
        if options.exportIndices {
            let l3Bytes = try indicesExporter.exportAllFrameIndices(frameIndices)
            manifest.l3Indices.fileCount = 81
            manifest.l3Indices.totalBytes = l3Bytes
            if options.computeChecksums {
                manifest.l3Indices.sha256 = try CBORManifest.sha256(filesIn: session.l3IndicesURL)
            }
            totalBytes += l3Bytes
            fileCount += 81
            coordinatorLogger.debug("L3 indices exported: \(l3Bytes) bytes")
        }

        // L4: GIF output
        if let gif = gifData {
            try gif.write(to: session.gifOutputURL)
            manifest.l4Compressed.fileCount = 1
            manifest.l4Compressed.totalBytes = Int64(gif.count)
            manifest.l4Compressed.algorithm = AlgorithmVersions.lzwEncoder
            totalBytes += Int64(gif.count)
            fileCount += 1
            coordinatorLogger.debug("L4 GIF saved: \(gif.count) bytes")
        }

        // Write manifest
        try manifest.write(to: session.manifestURL)
        totalBytes += Int64(manifest.encode().count)
        fileCount += 1

        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        coordinatorLogger.info("CBOR export complete: \(fileCount) files, \(CBORSessionManager.formatBytes(totalBytes)), \(String(format: "%.1f", elapsed))ms")

        return CBORExportResult(
            sessionID: session.sessionID,
            sessionURL: session.sessionURL,
            totalBytes: totalBytes,
            fileCount: fileCount,
            exportDurationMS: elapsed
        )
    }

    // MARK: - Incremental Export

    /// Export just L0 frames (for early capture stage)
    public func exportFrames(_ frames: [CGImage]) throws -> Int64 {
        let bytes = try frameExporter.exportAllFrames(frames)
        manifest.l0Frames.fileCount = 81
        manifest.l0Frames.totalBytes = bytes
        return bytes
    }

    /// Export L1 tensor (after tensor computation)
    public func exportTensor(_ tensor: TensorCube729) throws -> Int64 {
        return try tensorExporter.exportAllCells(from: tensor)
    }

    /// Export L2 palette (after quantization)
    public func exportPalette(_ palette: [UInt32], tensor: TensorCube729) throws -> Int64 {
        let bytes = try paletteExporter.exportPalette(palette)
        let mapping = paletteExporter.computeMapping(tensor: tensor, palette: palette)
        let mappingBytes = try paletteExporter.exportMapping(mapping)
        return bytes + mappingBytes
    }

    /// Export L3 indices (after palette mapping)
    public func exportIndices(_ frameIndices: [[UInt8]]) throws -> Int64 {
        return try indicesExporter.exportAllFrameIndices(frameIndices)
    }

    /// Export final GIF (after LZW compression)
    public func exportGIF(_ gifData: Data) throws {
        try gifData.write(to: session.gifOutputURL)
    }

    // MARK: - Finalize

    /// Write manifest and compute final checksums
    public func finalize() throws {
        // Compute checksums for all layers
        if FileManager.default.fileExists(atPath: session.l0FramesURL.path) {
            manifest.l0Frames.sha256 = try CBORManifest.sha256(filesIn: session.l0FramesURL)
        }
        if FileManager.default.fileExists(atPath: session.l1TensorCellsURL.path) {
            manifest.l1Tensor.sha256 = try CBORManifest.sha256(filesIn: session.l1TensorCellsURL)
            manifest.l1Tensor.inputSHA256 = manifest.l0Frames.sha256
        }
        if FileManager.default.fileExists(atPath: session.l2PaletteURL.path) {
            manifest.l2Palette.sha256 = try CBORManifest.sha256(filesIn: session.l2PaletteURL)
            manifest.l2Palette.inputSHA256 = manifest.l1Tensor.sha256
        }
        if FileManager.default.fileExists(atPath: session.l3IndicesURL.path) {
            manifest.l3Indices.sha256 = try CBORManifest.sha256(filesIn: session.l3IndicesURL)
        }

        // Write manifest
        try manifest.write(to: session.manifestURL)
        coordinatorLogger.info("Session finalized: \(self.session.sessionID)")
    }
}

// MARK: - Session Discovery

@available(iOS 26.0, *)
extension SessionCoordinator {

    /// List all available sessions
    public static func listSessions() -> [String] {
        CBORSessionManager.listSessions()
    }

    /// Get total storage used by all sessions
    public static func totalStorageUsed() -> Int64 {
        var total: Int64 = 0
        for sessionID in listSessions() {
            if let session = try? CBORSessionManager(existingSessionID: sessionID) {
                total += session.sessionSize()
            }
        }
        return total
    }

    /// Delete old sessions to free space (keeps most recent N)
    public static func pruneOldSessions(keepMostRecent: Int = 5) throws {
        let sessions = listSessions()  // Already sorted most recent first
        for sessionID in sessions.dropFirst(keepMostRecent) {
            if let session = try? CBORSessionManager(existingSessionID: sessionID) {
                try session.deleteSession()
                coordinatorLogger.info("Pruned old session: \(sessionID)")
            }
        }
    }
}
