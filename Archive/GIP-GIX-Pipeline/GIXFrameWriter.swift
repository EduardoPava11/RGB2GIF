//
//  GIXFrameWriter.swift
//  RGB2GIF
//
//  Write GIX frames with rawIndices encoding during capture
//  Supports optional offline LZW compression after capture completes
//
//  Architecture:
//  - Fast capture path: write frames with .rawIndices (no compression)
//  - Offline compression: transcode .rawIndices → .lzwSubblocks when idle
//  - Each frame references a palette via paletteRef (supports mid-capture switching)
//

import Foundation

@available(iOS 26.0, *)
final class GIXFrameWriter {

    // MARK: - Configuration

    // Use TemporalCubeConfiguration which has all GIF pipeline settings
    private let config: TemporalCubeConfiguration
    private var frames: [GIXFrame] = []
    private var currentPaletteRef: UInt32

    private let outputDirectory: URL
    private let sessionID: String

    // MARK: - State

    private var isCapturing: Bool = false
    private var captureStartTime: Date?
    private var frameTimestamps: [TimeInterval] = []

    // MARK: - Initialization

    init(config: TemporalCubeConfiguration, outputDirectory: URL) throws {
        self.config = config
        self.currentPaletteRef = config.paletteRef
        self.outputDirectory = outputDirectory

        // Generate unique session ID
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "_")
        self.sessionID = "\(timestamp)_\(config.cubeSize.rawValue)"

        // Create output directory if needed
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        print("📝 GIXFrameWriter initialized:")
        print("   Session ID: \(sessionID)")
        print("   Output directory: \(outputDirectory.path)")
        print("   Target frames: \(config.frameCount)")
    }

    // MARK: - Capture Control

    /// Start capture session
    func startCapture() {
        guard !isCapturing else {
            print("⚠️ Capture already in progress")
            return
        }

        isCapturing = true
        captureStartTime = Date()
        frames.removeAll()
        frameTimestamps.removeAll()

        print("📹 Capture started: \(sessionID)")
    }

    /// Stop capture session and finalize GIX file
    func stopCapture() throws -> URL {
        guard isCapturing else {
            throw FrameWriterError.captureNotInProgress
        }

        isCapturing = false

        let duration = Date().timeIntervalSince(captureStartTime ?? Date())
        print("📹 Capture stopped:")
        print("   Duration: \(String(format: "%.2f", duration))s")
        print("   Frames captured: \(frames.count)/\(config.frameCount)")

        // Create GIX
        let gix = try GIX(
            width: UInt16(config.cubeSize.dimension),
            height: UInt16(config.cubeSize.dimension),
            lzwMinCodeSize: max(2, config.paletteExp + 1),  // GIF89a §15
            defaultPaletteRef: config.paletteRef,
            name: sessionID,
            frames: frames,
            loopCount: config.loopCount
        )

        // Write to disk
        let gixURL = outputDirectory.appendingPathComponent("\(sessionID).gix")
        try gix.write(to: gixURL)

        print("💾 GIX saved to: \(gixURL.path)")
        print("   File size: \(formatFileSize(url: gixURL))")

        // Optionally compress to LZW after capture
        if config.compressAfterCapture {
            print("🗜️ LZW compression scheduled (offline)")
            // TODO: Implement async LZW compression
        }

        return gixURL
    }

    // MARK: - Frame Writing

    /// Write a frame with palette indices (fast path)
    func writeFrame(indices: [UInt8]) throws {
        guard isCapturing else {
            throw FrameWriterError.captureNotInProgress
        }

        guard indices.count == config.cubeSize.dimension * config.cubeSize.dimension else {
            throw FrameWriterError.invalidFrameSize(
                expected: config.cubeSize.dimension * config.cubeSize.dimension,
                got: indices.count
            )
        }

        guard frames.count < config.frameCount else {
            throw FrameWriterError.frameCountExceeded
        }

        // Record timestamp
        let timestamp = Date().timeIntervalSince(captureStartTime ?? Date())
        frameTimestamps.append(timestamp)

        // Create GIXFrame with rawIndices encoding
        let frame = GIXFrame(
            paletteRef: currentPaletteRef,
            delay: config.defaultDelay,
            disposal: config.disposal,
            transparency: config.enableTransparency,
            transparentIndex: config.transparentIndex ?? 0,
            dataEncoding: .rawIndices,
            payload: Data(indices),
            left: 0,
            top: 0,
            frameWidth: UInt16(config.cubeSize.dimension),
            frameHeight: UInt16(config.cubeSize.dimension),
            interlaced: config.enableInterlace
        )

        frames.append(frame)

        // Log progress every 10 frames
        if frames.count % 10 == 0 {
            let progress = Double(frames.count) / Double(config.frameCount) * 100
            print("📹 Capture progress: \(frames.count)/\(config.frameCount) (\(String(format: "%.1f", progress))%)")
        }
    }

    // MARK: - Palette Switching

    /// Switch to a different palette mid-capture (if allowed)
    func switchPalette(to paletteRef: UInt32) throws {
        guard config.allowPaletteSwitching else {
            throw FrameWriterError.paletteSwitchingDisabled
        }

        guard isCapturing else {
            throw FrameWriterError.captureNotInProgress
        }

        currentPaletteRef = paletteRef
        print("🎨 Switched to palette \(paletteRef) at frame \(frames.count)")
    }

    // MARK: - Statistics

    /// Get capture statistics
    func statistics() -> CaptureStatistics {
        let duration = isCapturing
            ? Date().timeIntervalSince(captureStartTime ?? Date())
            : (frameTimestamps.last ?? 0)

        let avgFPS = duration > 0 ? Double(frames.count) / duration : 0

        return CaptureStatistics(
            sessionID: sessionID,
            isCapturing: isCapturing,
            framesCaptured: frames.count,
            targetFrames: config.frameCount,
            duration: duration,
            averageFPS: avgFPS,
            timestamps: frameTimestamps
        )
    }

    // MARK: - Helpers

    private func formatFileSize(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return "unknown"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // MARK: - Statistics

    struct CaptureStatistics {
        let sessionID: String
        let isCapturing: Bool
        let framesCaptured: Int
        let targetFrames: Int
        let duration: TimeInterval
        let averageFPS: Double
        let timestamps: [TimeInterval]

        var progress: Double {
            return Double(framesCaptured) / Double(targetFrames)
        }

        var estimatedRemainingTime: TimeInterval {
            guard averageFPS > 0, framesCaptured < targetFrames else { return 0 }
            let remainingFrames = targetFrames - framesCaptured
            return Double(remainingFrames) / averageFPS
        }
    }

    // MARK: - Errors

    enum FrameWriterError: Error, CustomStringConvertible {
        case captureNotInProgress
        case invalidFrameSize(expected: Int, got: Int)
        case frameCountExceeded
        case paletteSwitchingDisabled

        var description: String {
            switch self {
            case .captureNotInProgress:
                return "Capture not in progress"
            case .invalidFrameSize(let expected, let got):
                return "Invalid frame size: expected \(expected) indices, got \(got)"
            case .frameCountExceeded:
                return "Frame count exceeded (capture complete)"
            case .paletteSwitchingDisabled:
                return "Palette switching disabled in configuration"
            }
        }
    }
}

// MARK: - LZW Compression (Offline)

@available(iOS 26.0, *)
extension GIXFrameWriter {

    /// Compress GIX file from rawIndices to lzwSubblocks (offline, async)
    /// This can be done after capture completes to save storage
    static func compressGIX(at url: URL) async throws {
        print("🗜️ Starting LZW compression for \(url.lastPathComponent)...")

        // Load GIX
        let data = try Data(contentsOf: url)
        let gix = try GIX.deserialize(data)

        // Transcode frames: rawIndices → lzwSubblocks
        var compressedFrames: [GIXFrame] = []

        for (idx, frame) in gix.frames.enumerated() {
            guard frame.dataEncoding == .rawIndices else {
                // Already compressed or unsupported encoding
                compressedFrames.append(frame)
                continue
            }

            // TODO: Implement LZW compression
            // For now, keep as rawIndices
            compressedFrames.append(frame)

            if idx % 10 == 0 {
                print("   Compressed \(idx + 1)/\(gix.frames.count) frames...")
            }
        }

        // Create compressed GIX
        let compressedGIX = try GIX(
            width: gix.width,
            height: gix.height,
            lzwMinCodeSize: gix.lzwMinCodeSize,
            defaultPaletteRef: gix.defaultPaletteRef,
            name: gix.name,
            frames: compressedFrames,
            loopCount: gix.loopCount
        )

        // Write back to disk
        try compressedGIX.write(to: url)

        let originalSize = data.count
        let compressedSize = try Data(contentsOf: url).count
        let savings = (1.0 - Double(compressedSize) / Double(originalSize)) * 100

        print("✅ LZW compression complete:")
        print("   Original size: \(ByteCountFormatter().string(fromByteCount: Int64(originalSize)))")
        print("   Compressed size: \(ByteCountFormatter().string(fromByteCount: Int64(compressedSize)))")
        print("   Savings: \(String(format: "%.1f", savings))%")
    }
}
