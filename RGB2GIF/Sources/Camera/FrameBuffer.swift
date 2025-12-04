//
//  FrameBuffer.swift
//  RGB2GIF
//
//  Thread-safe circular buffer for collecting 81 frames
//

import Foundation
import CoreGraphics
import os.log

private let bufferLogger = Logger(subsystem: "com.rgb2gif", category: "FrameBuffer")

// MARK: - FrameBuffer

/// Thread-safe buffer for collecting exactly 81 frames
@available(iOS 26.0, *)
public actor FrameBuffer {

    // MARK: - Constants

    public static let targetCount = 81

    // MARK: - State

    private var frames: [CGImage] = []
    private var isCapturing = false

    // MARK: - Properties

    /// Current number of frames in buffer
    public var count: Int { frames.count }

    /// Whether we have collected all 81 frames
    public var isFull: Bool { frames.count >= Self.targetCount }

    /// Whether capture is currently active
    public var capturing: Bool { isCapturing }

    // MARK: - Control

    /// Start capturing frames (clears any existing frames)
    public func startCapture() {
        frames.removeAll()
        frames.reserveCapacity(Self.targetCount)
        isCapturing = true
        bufferLogger.info("Frame capture started")
    }

    /// Stop capturing frames
    public func stopCapture() {
        isCapturing = false
        bufferLogger.info("Frame capture stopped at \(self.frames.count) frames")
    }

    /// Add a frame to the buffer
    /// - Parameter frame: The CGImage to add
    /// - Returns: Current frame count after adding
    @discardableResult
    public func addFrame(_ frame: CGImage) -> Int {
        guard isCapturing && frames.count < Self.targetCount else {
            return frames.count
        }

        frames.append(frame)

        if frames.count == Self.targetCount {
            isCapturing = false
            bufferLogger.info("Frame buffer full: \(Self.targetCount) frames captured")
        }

        return frames.count
    }

    /// Get a copy of all captured frames
    /// - Returns: Array of CGImages (copy, safe to use across threads)
    public func snapshot() -> [CGImage] {
        return frames
    }

    /// Clear all frames and reset state
    public func reset() {
        frames.removeAll()
        isCapturing = false
        bufferLogger.info("Frame buffer reset")
    }

    /// Progress as a fraction (0.0 to 1.0)
    public var progress: Float {
        Float(frames.count) / Float(Self.targetCount)
    }
}
