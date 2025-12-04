//
//  TemporalCubeCaptureManager.swift
//  RGB2GIF
//
//  Efficient frame capture manager for 80×80 or 128×128 temporal cubes
//  - Stores frames as [CGImage] (not UIImage) for memory efficiency
//  - Reuses single CIContext for all conversions
//  - NV12 Y-plane fast-path for grayscale extraction
//  - Downsamples to target count early to reduce memory pressure
//

import Foundation
import UIKit
import CoreImage
import CoreVideo
import CoreGraphics
import AVFoundation
import os.log

private let captureLogger = Logger(subsystem: "com.rgb2gif", category: "TemporalCapture")

@available(iOS 26.0, *)
public class TemporalCubeCaptureManager {

    // MARK: - Types

    public enum CaptureMode {
        case frames80   // 80×80, 80 frames
        case frames81   // 81×81, 81 frames (MVP0)
        case frames128  // 128×128, 128 frames

        public var dimension: Int {
            switch self {
            case .frames80: return 80
            case .frames81: return 81
            case .frames128: return 128
            }
        }

        public var targetFrameCount: Int {
            switch self {
            case .frames80: return 80
            case .frames81: return 81
            case .frames128: return 128
            }
        }
    }

    public struct CaptureResult {
        public let frames: [CGImage]
        public let mode: CaptureMode
        public let duration: TimeInterval
        public let averageFPS: Double
    }

    public enum CaptureError: LocalizedError {
        case notCapturing
        case alreadyCapturing
        case insufficientFrames(Int, expected: Int)

        public var errorDescription: String? {
            switch self {
            case .notCapturing: return "Not currently capturing"
            case .alreadyCapturing: return "Already capturing"
            case .insufficientFrames(let count, let expected):
                return "Insufficient frames: \(count)/\(expected)"
            }
        }
    }

    // MARK: - Properties

    private let mode: CaptureMode
    private let targetSize: CGSize

    // Reuse single CIContext for performance
    private let ciContext: CIContext

    // Serial queue for thread-safe capture state
    private let captureQueue = DispatchQueue(label: "com.rgb2gif.capture", qos: .userInitiated)

    // Capture state (accessed only on captureQueue)
    private var isCapturing = false
    private var capturedFrames: [CGImage] = []
    private var captureStartTime: Date?
    private var lastFrameTime: Date?
    private var isStopped = false  // Track if stopCapture() was explicitly called

    // Progress callback
    public var progressHandler: ((Int, Int) -> Void)?

    // MARK: - Initialization

    public init(mode: CaptureMode) {
        self.mode = mode
        self.targetSize = CGSize(width: mode.dimension, height: mode.dimension)

        // Create reusable CIContext with optimal settings
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .useSoftwareRenderer: false  // Prefer GPU
        ]
        self.ciContext = CIContext(options: options)

        captureLogger.info("TemporalCubeCaptureManager initialized: \(mode.dimension)×\(mode.dimension), \(mode.targetFrameCount) frames")
    }

    // MARK: - Public API

    /// Start capturing frames
    public func startCapture() throws {
        try captureQueue.sync {
            guard !isCapturing else {
                throw CaptureError.alreadyCapturing
            }

            isCapturing = true
            isStopped = false
            capturedFrames.removeAll(keepingCapacity: true)
            capturedFrames.reserveCapacity(self.mode.targetFrameCount)
            captureStartTime = Date()
            lastFrameTime = Date()

            captureLogger.info("Capture started: target \(self.mode.targetFrameCount) frames")
        }
    }

    /// Stop capturing and return captured frames
    public func stopCapture() throws -> CaptureResult {
        return try captureQueue.sync {
            // Allow calling stopCapture even if target was reached (isCapturing may be false)
            // Just check that we haven't already called stopCapture before
            guard !isStopped else {
                throw CaptureError.notCapturing
            }

            isCapturing = false
            isStopped = true

            let duration = Date().timeIntervalSince(captureStartTime ?? Date())
            let averageFPS = Double(self.capturedFrames.count) / duration

            let result = CaptureResult(
                frames: self.capturedFrames,
                mode: self.mode,
                duration: duration,
                averageFPS: averageFPS
            )

            captureLogger.info("Capture completed: \(self.capturedFrames.count) frames in \(String(format: "%.2f", duration))s (\(String(format: "%.1f", averageFPS)) fps)")

            return result
        }
    }

    /// Cancel capture without returning frames
    public func cancelCapture() {
        captureQueue.sync {
            isCapturing = false
            isStopped = true
            capturedFrames.removeAll()
            captureLogger.info("Capture cancelled")
        }
    }

    /// Add frame from sample buffer (call from camera delegate on output queue)
    /// All completion logic is handled INSIDE this async block to avoid race conditions
    public func addFrame(from sampleBuffer: CMSampleBuffer) {
        // Don't hop to main thread - stay on output queue
        captureQueue.async { [weak self] in
            guard let self = self else { return }

            guard self.isCapturing else { return }
            guard self.capturedFrames.count < self.mode.targetFrameCount else {
                // Already have enough frames
                return
            }

            // Extract CGImage based on pixel format
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                captureLogger.warning("Failed to get pixel buffer")
                return
            }

            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let cgImage: CGImage?

            if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
               pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                // NV12 → RGB conversion with FULL COLOR (YUV→RGB via CIImage)
                cgImage = PixelBufferHelpers.extractNV12ToRGB(from: pixelBuffer, targetSize: self.targetSize)
            } else {
                // BGRA path (already RGB)
                cgImage = PixelBufferHelpers.extractBGRA(from: pixelBuffer, targetSize: self.targetSize)
            }

            guard let image = cgImage else {
                captureLogger.warning("Failed to extract CGImage")
                return
            }

            self.capturedFrames.append(image)

            let count = self.capturedFrames.count
            let target = self.mode.targetFrameCount

            // Calculate FPS
            let now = Date()
            if let lastTime = self.lastFrameTime {
                let delta = now.timeIntervalSince(lastTime)
                if delta > 0 {
                    let currentFPS = 1.0 / delta
                    if count % 10 == 0 {
                        captureLogger.debug("Frame \(count)/\(target) @ \(String(format: "%.1f", currentFPS)) fps")
                    }
                }
            }
            self.lastFrameTime = now

            // Check if capture is complete (INSIDE async block - correct timing!)
            if count >= target {
                captureLogger.info("╔══════════════════════════════════════════════════════════╗")
                captureLogger.info("║  TARGET REACHED: \(count)/\(target) frames captured     ║")
                captureLogger.info("╚══════════════════════════════════════════════════════════╝")

                // Stop accepting more frames
                self.isCapturing = false
                self.isStopped = true

                // Calculate final stats
                let duration = Date().timeIntervalSince(self.captureStartTime ?? Date())
                let averageFPS = Double(count) / max(duration, 0.001)

                captureLogger.info("Capture completed: \(count) frames in \(String(format: "%.2f", duration))s (\(String(format: "%.1f", averageFPS)) fps)")

                // Copy frames before dispatching to main thread
                let frames = self.capturedFrames

                // Notify completion on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.captureManager(self, didFinishWithFrames: frames)
                    self.completionHandler?(frames)
                }
            } else {
                // Notify progress on main thread (only if not complete)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.captureManager(self, didCaptureFrame: count - 1)
                    self.progressHandler?(count, target)
                }
            }
        }
    }

    // MARK: - State Queries

    public var currentFrameCount: Int {
        return captureQueue.sync {
            return capturedFrames.count
        }
    }

    public var isCaptureActive: Bool {
        return captureQueue.sync {
            return isCapturing
        }
    }

    // MARK: - Utility

    /// Convert [CGImage] to [UIImage] if needed (avoid this when possible)
    public static func convertToUIImages(_ cgImages: [CGImage]) -> [UIImage] {
        return cgImages.map { UIImage(cgImage: $0) }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - MVP0 Delegate Support
    // ════════════════════════════════════════════════════════════════════════

    /// Delegate for capture events (alternative to progressHandler)
    public weak var delegate: TemporalCubeCaptureDelegate?

    /// Completion handler for when capture finishes
    public var completionHandler: (([CGImage]) -> Void)?
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - SimpleCameraFrameDelegate Conformance
// ════════════════════════════════════════════════════════════════════════════

@available(iOS 26.0, *)
extension TemporalCubeCaptureManager: SimpleCameraFrameDelegate {
    public func cameraManager(_ manager: SimpleCameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        // All completion logic is handled inside addFrame() to avoid race conditions
        // between async frame processing and sync state queries
        addFrame(from: sampleBuffer)
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - MVP0 Delegate Protocol
// ════════════════════════════════════════════════════════════════════════════

@available(iOS 26.0, *)
public protocol TemporalCubeCaptureDelegate: AnyObject {
    func captureManager(_ manager: TemporalCubeCaptureManager, didCaptureFrame frameIndex: Int)
    func captureManager(_ manager: TemporalCubeCaptureManager, didFinishWithFrames frames: [CGImage])
    func captureManager(_ manager: TemporalCubeCaptureManager, didFailWithError error: Error)
}
