//
//  CBORSessionManager.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  CBOR SESSION DIRECTORY MANAGEMENT                                        ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Creates and manages the hierarchical capture session directories:        ║
//  ║  • L0_frames/  - 81 individual 81×81 RGB frames + PNGs                   ║
//  ║  • L1_tensor/  - 729 tensor cell files + summary                         ║
//  ║  • L2_palette/ - 256-color palette + mapping                             ║
//  ║  • L3_indices/ - 81 frame index files                                    ║
//  ║  • L4_compressed/ - Final GIF + stats                                    ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import os.log

private let sessionLogger = Logger(subsystem: "com.rgb2gif", category: "CBORSession")

// MARK: - Session Path Constants

@available(iOS 26.0, *)
public enum CBORSessionPath {
    public static let rootFolder = "RGB2GIF"
    public static let capturesFolder = "captures"

    // Step-by-step pipeline stages:
    public static let l0Raw = "L0_raw"           // Raw camera frames (BGRA, any size)
    public static let l1Cropped = "L1_cropped"   // Center-cropped squares (BGRA)
    public static let l2Frames = "L2_frames"     // Resized 81×81 RGB frames
    public static let l3Tensor = "L3_tensor"     // 729 tensor cells
    public static let l3TensorCells = "cells"
    public static let l4Palette = "L4_palette"   // 256-color palette
    public static let l5Indices = "L5_indices"   // Palette indices
    public static let l6Output = "L6_output"     // Final GIF + stats

    public static let manifestFile = "manifest.cbor"
    public static let verificationFile = "verification.cbor"
}

// MARK: - CBORSessionManager

@available(iOS 26.0, *)
public final class CBORSessionManager {

    // MARK: - Properties

    /// Session identifier (timestamp-based)
    public let sessionID: String

    /// Root URL for this session
    public let sessionURL: URL

    /// Date formatter for session naming
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    // MARK: - Computed Paths

    // L0: Raw camera frames (BGRA, any size)
    public var l0RawURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l0Raw) }

    // L1: Center-cropped squares (BGRA)
    public var l1CroppedURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l1Cropped) }

    // L2: Resized 81×81 RGB frames (formerly L0_frames)
    public var l2FramesURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l2Frames) }

    // L3: Tensor cells (729 files)
    public var l3TensorURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l3Tensor) }
    public var l3TensorCellsURL: URL { l3TensorURL.appendingPathComponent(CBORSessionPath.l3TensorCells) }

    // L4: Palette
    public var l4PaletteURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l4Palette) }

    // L5: Indices
    public var l5IndicesURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l5Indices) }

    // L6: Output
    public var l6OutputURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.l6Output) }

    // Manifest and verification
    public var manifestURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.manifestFile) }
    public var verificationURL: URL { sessionURL.appendingPathComponent(CBORSessionPath.verificationFile) }

    // Legacy aliases for backward compatibility
    public var l0FramesURL: URL { l2FramesURL }
    public var l1TensorURL: URL { l3TensorURL }
    public var l1TensorCellsURL: URL { l3TensorCellsURL }
    public var l2PaletteURL: URL { l4PaletteURL }
    public var l3IndicesURL: URL { l5IndicesURL }
    public var l4CompressedURL: URL { l6OutputURL }

    // MARK: - Initialization

    /// Create a new session with timestamp-based ID
    public init() throws {
        let timestamp = Date()
        self.sessionID = "session_\(Self.dateFormatter.string(from: timestamp))"

        // Get Documents directory
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw RGB2GIFError.cborExportFailed("Cannot access Documents directory")
        }

        // Create session path: Documents/RGB2GIF/captures/session_YYYYMMDD_HHMMSS/
        let capturesURL = documentsURL
            .appendingPathComponent(CBORSessionPath.rootFolder)
            .appendingPathComponent(CBORSessionPath.capturesFolder)

        self.sessionURL = capturesURL.appendingPathComponent(sessionID)

        try createDirectoryStructure()

        sessionLogger.info("Created session: \(self.sessionID)")
    }

    /// Load an existing session by ID
    public init(existingSessionID: String) throws {
        self.sessionID = existingSessionID

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw RGB2GIFError.cborExportFailed("Cannot access Documents directory")
        }

        let capturesURL = documentsURL
            .appendingPathComponent(CBORSessionPath.rootFolder)
            .appendingPathComponent(CBORSessionPath.capturesFolder)

        self.sessionURL = capturesURL.appendingPathComponent(existingSessionID)

        // Verify session exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RGB2GIFError.cborExportFailed("Session not found: \(existingSessionID)")
        }

        sessionLogger.info("Loaded existing session: \(self.sessionID)")
    }

    // MARK: - Directory Management

    /// Creates the full directory structure for a capture session
    /// 7-stage pipeline: L0_raw → L1_cropped → L2_frames → L3_tensor → L4_palette → L5_indices → L6_output
    private func createDirectoryStructure() throws {
        let fm = FileManager.default

        let directories = [
            sessionURL,
            l0RawURL,         // L0: Raw camera frames (BGRA, any size)
            l1CroppedURL,     // L1: Center-cropped squares (BGRA)
            l2FramesURL,      // L2: Resized 81×81 RGB frames
            l3TensorURL,      // L3: Tensor container
            l3TensorCellsURL, // L3: 729 tensor cells
            l4PaletteURL,     // L4: 256-color palette
            l5IndicesURL,     // L5: Palette indices
            l6OutputURL       // L6: Final GIF output
        ]

        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        sessionLogger.debug("Created 7-stage directory structure at: \(self.sessionURL.path)")
    }

    // MARK: - File Naming Helpers

    /// Frame file name: f00.cbor - f80.cbor
    public func frameFileName(index: Int, extension ext: String = "cbor") -> String {
        String(format: "f%02d.\(ext)", index)
    }

    /// Frame file URL
    public func frameURL(index: Int, extension ext: String = "cbor") -> URL {
        l0FramesURL.appendingPathComponent(frameFileName(index: index, extension: ext))
    }

    /// Tensor cell file name: c000.cbor - c728.cbor
    public func tensorCellFileName(index: Int) -> String {
        String(format: "c%03d.cbor", index)
    }

    /// Tensor cell file URL
    public func tensorCellURL(index: Int) -> URL {
        l1TensorCellsURL.appendingPathComponent(tensorCellFileName(index: index))
    }

    /// Tensor summary file URL
    public var tensorSummaryURL: URL {
        l1TensorURL.appendingPathComponent("summary.cbor")
    }

    /// Tensor grid visualization PNG URL
    public var tensorGridPNGURL: URL {
        l1TensorURL.appendingPathComponent("grid.png")
    }

    /// Palette file URL
    public var paletteURL: URL {
        l2PaletteURL.appendingPathComponent("palette.cbor")
    }

    /// Palette mapping file URL
    public var paletteMappingURL: URL {
        l2PaletteURL.appendingPathComponent("mapping.cbor")
    }

    /// Palette PNG visualization URL
    public var palettePNGURL: URL {
        l2PaletteURL.appendingPathComponent("palette.png")
    }

    /// Index file name: i00.cbor - i80.cbor
    public func indicesFileName(index: Int) -> String {
        String(format: "i%02d.cbor", index)
    }

    /// Index file URL
    public func indicesURL(index: Int) -> URL {
        l3IndicesURL.appendingPathComponent(indicesFileName(index: index))
    }

    /// LZW stats file URL
    public var lzwStatsURL: URL {
        l4CompressedURL.appendingPathComponent("stats.cbor")
    }

    /// Final GIF output URL
    public var gifOutputURL: URL {
        l4CompressedURL.appendingPathComponent("animation.gif")
    }

    // MARK: - Session Discovery

    /// List all available capture sessions
    public static func listSessions() -> [String] {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }

        let capturesURL = documentsURL
            .appendingPathComponent(CBORSessionPath.rootFolder)
            .appendingPathComponent(CBORSessionPath.capturesFolder)

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: capturesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return contents
                .filter { url in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                }
                .map { $0.lastPathComponent }
                .filter { $0.hasPrefix("session_") }
                .sorted()
                .reversed()  // Most recent first
                .map { $0 }
        } catch {
            sessionLogger.error("Failed to list sessions: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Session Cleanup

    /// Delete this session's directory
    public func deleteSession() throws {
        try FileManager.default.removeItem(at: sessionURL)
        sessionLogger.info("Deleted session: \(self.sessionID)")
    }

    /// Calculate total session size in bytes
    public func sessionSize() -> Int64 {
        var totalSize: Int64 = 0

        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: sessionURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    /// Format bytes as human-readable string
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
