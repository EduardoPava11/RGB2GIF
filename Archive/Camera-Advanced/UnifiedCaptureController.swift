//
//  UnifiedCaptureController.swift
//  RGB2GIF
//
//  Unified camera capture controller for both Option A (.gix/.gip/.gim)
//  and existing formats. Standardizes 80×80 and 128×128 capture.
//
//  Usage:
//    let controller = try UnifiedCaptureController()
//    let config = ClipConfig(dim: .d128, fps: 24)
//    let processor = ClipProcessor(...)  // Your choice of writer
//    try controller.start(config: config, sink: processor)
//    // ... capture runs ...
//    try controller.stop()
//

import Foundation
import AVFoundation
import UIKit
import os.log

private let captureLogger = Logger(subsystem: "com.rgb2gif", category: "UnifiedCapture")

// MARK: - Capture Controller

@available(iOS 26.0, *)
public final class UnifiedCaptureController: NSObject {

    // MARK: - Properties

    private let captureSession: AVCaptureSession
    private let videoOutput: AVCaptureVideoDataOutput
    private let videoQueue: DispatchQueue

    private weak var currentSink: FrameSink?
    private var currentConfig: ClipConfig?

    private var isSessionRunning = false

    // MARK: - Initialization

    public override init() throws {
        self.captureSession = AVCaptureSession()
        self.videoOutput = AVCaptureVideoDataOutput()
        self.videoQueue = DispatchQueue(label: "com.rgb2gif.videoQueue", qos: .userInitiated)

        super.init()

        try setupCaptureSession()

        captureLogger.info("UnifiedCaptureController initialized")
    }

    // MARK: - Setup

    private func setupCaptureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Set preset for best quality
        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }

        // Add video input (back camera)
        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CaptureError.cameraNotAvailable
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)

        guard captureSession.canAddInput(videoInput) else {
            throw CaptureError.cannotAddInput
        }

        captureSession.addInput(videoInput)

        // Configure device for stable frame rate
        try configureDevice(videoDevice, targetFPS: 30)

        // Configure video output
        videoOutput.alwaysDiscardsLateVideoFrames = true  // Keep UI smooth
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw CaptureError.cannotAddOutput
        }

        captureSession.addOutput(videoOutput)

        // Set orientation to portrait
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        captureLogger.info("Capture session configured:")
        captureLogger.info("  Preset: \(self.captureSession.sessionPreset.rawValue)")
        captureLogger.info("  Pixel format: NV12 (420YpCbCr8BiPlanarFullRange)")
    }

    private func configureDevice(_ device: AVCaptureDevice, targetFPS: Int) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Find format that supports target FPS
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRate: AVFrameRateRange?

        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= Double(targetFPS) && range.minFrameRate <= Double(targetFPS) {
                    // Prefer highest resolution format
                    if bestFormat == nil {
                        bestFormat = format
                        bestFrameRate = range
                    } else if let currentBest = bestFormat {
                        let currentDims = CMVideoFormatDescriptionGetDimensions(currentBest.formatDescription)
                        let newDims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        if newDims.width * newDims.height > currentDims.width * currentDims.height {
                            bestFormat = format
                            bestFrameRate = range
                        }
                    }
                }
            }
        }

        if let format = bestFormat, let frameRate = bestFrameRate {
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            captureLogger.info("Device configured:")
            captureLogger.info("  Format: \(dims.width)×\(dims.height)")
            captureLogger.info("  Frame rate: \(targetFPS) fps")
        } else {
            captureLogger.warning("Could not find format supporting \(targetFPS) fps, using default")
        }

        // Set focus mode
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        // Set exposure mode
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        // Set white balance mode
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    // MARK: - Public API

    /// Start capture with given configuration and sink
    public func start(config: ClipConfig, sink: FrameSink) throws {
        guard !isSessionRunning else {
            throw CaptureError.alreadyCapturing
        }

        self.currentConfig = config
        self.currentSink = sink

        // Start session on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            self?.isSessionRunning = true

            captureLogger.info("Capture started: \(config.dim.rawValue)×\(config.dim.rawValue), \(config.frames) frames @ \(config.fps)fps")
        }
    }

    /// Stop capture
    public func stop() throws {
        guard isSessionRunning else {
            throw CaptureError.notCapturing
        }

        captureSession.stopRunning()
        isSessionRunning = false

        captureLogger.info("Capture stopped")
    }

    /// Cancel capture without finalizing
    public func cancel() {
        if isSessionRunning {
            captureSession.stopRunning()
            isSessionRunning = false
        }

        currentSink?.cancel()
        currentSink = nil
        currentConfig = nil

        captureLogger.info("Capture cancelled")
    }

    // MARK: - State Queries

    public var isCapturing: Bool {
        return isSessionRunning
    }

    public func currentProgress() -> (current: Int, total: Int)? {
        return currentSink?.progress
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

@available(iOS 26.0, *)
extension UnifiedCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Forward to sink
        currentSink?.consume(pixelBuffer: pixelBuffer, timestamp: timestamp)

        // Auto-stop when target reached
        if let progress = currentSink?.progress,
           progress.current >= progress.total {
            DispatchQueue.main.async { [weak self] in
                try? self?.stop()
                try? self?.currentSink?.finish()
            }
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        captureLogger.warning("Dropped frame")
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
public enum CaptureError: LocalizedError {
    case cameraNotAvailable
    case cannotAddInput
    case cannotAddOutput
    case alreadyCapturing
    case notCapturing

    public var errorDescription: String? {
        switch self {
        case .cameraNotAvailable:
            return "Camera not available"
        case .cannotAddInput:
            return "Cannot add video input"
        case .cannotAddOutput:
            return "Cannot add video output"
        case .alreadyCapturing:
            return "Already capturing"
        case .notCapturing:
            return "Not currently capturing"
        }
    }
}

// MARK: - Factory Methods

@available(iOS 26.0, *)
extension UnifiedCaptureController {

    /// Create capture controller with Option A writer (.gix/.gip/.gim)
    public static func createWithSplitFormat(
        config: ClipConfig,
        outputDirectory: URL,
        quantizer: PaletteQuantizer? = nil,
        downscaler: FrameDownscaler? = nil
    ) throws -> (controller: UnifiedCaptureController, processor: ClipProcessor) {
        let controller = try UnifiedCaptureController()

        let downscalerImpl = downscaler ?? VImageDownscaler(quality: .balanced)
        let quantizerImpl = quantizer ?? MedianCutQuantizer()

        let writer = try SplitFormatWriter(
            baseURL: outputDirectory,
            width: config.dim.rawValue,
            height: config.dim.rawValue,
            frames: config.frames
        )

        let processor = ClipProcessor(
            config: config,
            downscaler: downscalerImpl,
            quantizer: quantizerImpl,
            writer: writer
        )

        return (controller: controller, processor: processor)
    }

    /// Create capture controller with existing format (for compatibility)
    /// - Note: Legacy format is deprecated. Use CaptureToGIP2Pipeline instead.
    public static func createWithLegacyFormat(
        config: ClipConfig,
        outputDirectory: URL,
        quantizer: PaletteQuantizer? = nil,
        downscaler: FrameDownscaler? = nil
    ) throws -> (controller: UnifiedCaptureController, processor: ClipProcessor) {
        // Legacy format is deprecated - use CaptureToGIP2Pipeline for new captures
        throw NSError(domain: "UnifiedCaptureController", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Legacy format is deprecated. Use CaptureToGIP2Pipeline instead."
        ])
    }
}
