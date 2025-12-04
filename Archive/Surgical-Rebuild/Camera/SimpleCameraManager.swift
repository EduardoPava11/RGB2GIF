//
//  SimpleCameraManager.swift
//  RGB2GIF
//
//  Production-hardened camera manager with deterministic capture
//  - Serial sessionQueue for all AVFoundation operations
//  - Enforced FPS via activeVideoMin/MaxFrameDuration
//  - Orientation tracking and front-camera mirroring
//  - NV12/BGRA format selection
//

import AVFoundation
import UIKit
import Combine
import os.log
import Foundation

private let simpleLogger = Logger(subsystem: "com.rgb2gif", category: "SimpleCamera")

// ════════════════════════════════════════════════════════════════════════════
// MARK: - MVP0 Stub Types (81×81×81 Only)
// ════════════════════════════════════════════════════════════════════════════

/// MVP0: Fixed 81×81×81 cube size
@available(iOS 26.0, *)
public enum CubeSize: Int, CaseIterable {
    case s80 = 80
    case s81 = 81  // MVP0 default
    case s128 = 128

    public var dimension: Int { rawValue }
    public var frameCount: Int { rawValue }
    public var pixelCount: Int { rawValue * rawValue * rawValue }
}

/// MVP0: Minimal temporal config stub (not used in MVP0 pipeline)
@available(iOS 26.0, *)
public struct TemporalCubeConfiguration {
    public enum InitialEncoding { case rawIndices }
    public let cubeSize: CubeSize
    public let paletteExp: UInt8
    public let targetFPS: Int
    public let frameCount: Int
    public let gipURL: URL
    public let paletteRef: UInt32
    public let allowPaletteSwitching: Bool
    public let initialEncoding: InitialEncoding
    public let compressAfterCapture: Bool
    public let loopCount: UInt16?
    public let defaultDelay: UInt16
    public let disposal: UInt8
    public let enableInterlace: Bool
    public let enableTransparency: Bool
    public let transparentIndex: UInt8?

    public init(
        cubeSize: CubeSize, paletteExp: UInt8, targetFPS: Int, frameCount: Int,
        gipURL: URL, paletteRef: UInt32, allowPaletteSwitching: Bool,
        initialEncoding: InitialEncoding, compressAfterCapture: Bool,
        loopCount: UInt16?, defaultDelay: UInt16, disposal: UInt8,
        enableInterlace: Bool, enableTransparency: Bool, transparentIndex: UInt8?
    ) {
        self.cubeSize = cubeSize; self.paletteExp = paletteExp; self.targetFPS = targetFPS
        self.frameCount = frameCount; self.gipURL = gipURL; self.paletteRef = paletteRef
        self.allowPaletteSwitching = allowPaletteSwitching; self.initialEncoding = initialEncoding
        self.compressAfterCapture = compressAfterCapture; self.loopCount = loopCount
        self.defaultDelay = defaultDelay; self.disposal = disposal
        self.enableInterlace = enableInterlace; self.enableTransparency = enableTransparency
        self.transparentIndex = transparentIndex
    }
}

/// Capture format options
@available(iOS 26.0, *)
public enum CaptureFormat: CustomStringConvertible {
    case bgra  // 32-bit BGRA (default)
    case nv12  // NV12 YUV (for Y-plane grayscale extraction)

    public var description: String {
        switch self {
        case .bgra: return "BGRA"
        case .nv12: return "NV12"
        }
    }
}

/// Production camera manager with robust session handling
/// NOTE: Class is NOT @MainActor - AVFoundation callbacks run on outputQueue
/// Only @Published UI properties are isolated to @MainActor
@available(iOS 26.0, *)
public class SimpleCameraManager: NSObject, ObservableObject {

    // MARK: - Nested Types

    /// Capture mode with associated values
    public enum CaptureMode {
        case burst(count: Int)
        case video(duration: Double)
        case continuous

        var targetFrameCount: Int? {
            switch self {
            case .burst(let count): return count
            case .video(let duration): return Int(duration * 30) // Estimate at 30fps
            case .continuous: return nil
            }
        }
    }

    /// Unified configuration for camera capture and GIF pipeline
    /// Extends basic camera settings with GIF-specific properties
    public struct CaptureConfiguration {
        // MARK: - Camera Settings (existing)
        public let mode: CaptureMode
        public let targetFPS: Double
        public let resolution: CGSize
        public let format: CaptureFormat

        // MARK: - GIF Pipeline Settings (new - from TemporalCubeConfiguration)
        public let cubeSize: CubeSize?           // Inferred from mode if nil
        public let paletteExp: UInt8             // 6 for 128 colors, 7 for 256 colors
        public let paletteRef: UInt32            // Index into GIP.palettes[]
        public let loopCount: UInt16?            // nil = no loop, 0 = loop forever, N = loop N times
        public let gipURL: URL?                  // Path to GIP palette pack (created if nil)
        public let compressAfterCapture: Bool    // Convert to LZW after capture
        public let defaultDelay: UInt16          // Frame delay in centiseconds (10 = 100ms)
        public let disposal: UInt8               // GIF disposal method (0-3)
        public let allowPaletteSwitching: Bool   // Support mid-capture palette switching
        public let enableInterlace: Bool         // GIF interlace flag
        public let enableTransparency: Bool      // Transparency support
        public let transparentIndex: UInt8?      // Index to treat as transparent

        public init(
            mode: CaptureMode,
            targetFPS: Double = 30.0,
            resolution: CGSize? = nil,  // Inferred from cubeSize if nil
            format: CaptureFormat = .nv12,
            // GIF pipeline parameters with sensible defaults
            cubeSize: CubeSize? = nil,  // Inferred from mode if nil
            paletteExp: UInt8 = 7,      // Default 256 colors
            paletteRef: UInt32 = 0,
            loopCount: UInt16? = 0,     // Loop forever by default
            gipURL: URL? = nil,
            compressAfterCapture: Bool = true,
            defaultDelay: UInt16? = nil,  // Computed from FPS if nil
            disposal: UInt8 = 1,          // Do not dispose
            allowPaletteSwitching: Bool = false,
            enableInterlace: Bool = false,
            enableTransparency: Bool = false,
            transparentIndex: UInt8? = nil
        ) {
            self.mode = mode
            self.targetFPS = targetFPS
            self.format = format

            // Infer cube size from mode if not specified
            let inferredCubeSize: CubeSize?
            if let explicitCubeSize = cubeSize {
                inferredCubeSize = explicitCubeSize
            } else {
                // Infer from mode
                switch mode {
                case .burst(let count) where count <= 80:
                    inferredCubeSize = .s80
                case .burst(let count) where count <= 128:
                    inferredCubeSize = .s128
                default:
                    inferredCubeSize = nil
                }
            }
            self.cubeSize = inferredCubeSize

            // Set resolution (use explicit value, or infer from cube size, or use default)
            if let explicitResolution = resolution {
                self.resolution = explicitResolution
            } else if let cube = inferredCubeSize {
                self.resolution = CGSize(width: cube.dimension, height: cube.dimension)
            } else {
                self.resolution = CGSize(width: 1280, height: 1280)
            }

            // GIF pipeline settings
            self.paletteExp = paletteExp
            self.paletteRef = paletteRef
            self.loopCount = loopCount
            self.gipURL = gipURL
            self.compressAfterCapture = compressAfterCapture
            self.allowPaletteSwitching = allowPaletteSwitching
            self.disposal = disposal
            self.enableInterlace = enableInterlace
            self.enableTransparency = enableTransparency
            self.transparentIndex = transparentIndex

            // Compute default delay from FPS if not specified
            if let explicitDelay = defaultDelay {
                self.defaultDelay = explicitDelay
            } else {
                // Convert FPS to centiseconds: delay = 100 / FPS
                self.defaultDelay = UInt16(max(1, 100.0 / targetFPS))
            }
        }

        // MARK: - Conversion to TemporalCubeConfiguration

        /// Convert to TemporalCubeConfiguration for GIX writer
        public func asTemporalConfig() -> TemporalCubeConfiguration {
            let cube = cubeSize ?? .s80

            return TemporalCubeConfiguration(
                cubeSize: cube,
                paletteExp: paletteExp,
                targetFPS: Int(targetFPS),
                frameCount: cube.frameCount,
                gipURL: gipURL ?? URL(fileURLWithPath: ""),
                paletteRef: paletteRef,
                allowPaletteSwitching: allowPaletteSwitching,
                initialEncoding: .rawIndices,
                compressAfterCapture: compressAfterCapture,
                loopCount: loopCount,
                defaultDelay: defaultDelay,
                disposal: disposal,
                enableInterlace: enableInterlace,
                enableTransparency: enableTransparency,
                transparentIndex: transparentIndex
            )
        }

        // MARK: - Convenience Factory Methods

        /// Standard 80³ cube configuration
        public static func cube80(
            targetFPS: Double = 30.0,
            paletteExp: UInt8 = 7,
            gipURL: URL? = nil
        ) -> CaptureConfiguration {
            CaptureConfiguration(
                mode: .burst(count: 80),
                targetFPS: targetFPS,
                cubeSize: .s80,
                paletteExp: paletteExp,
                gipURL: gipURL
            )
        }

        /// Standard 128³ cube configuration
        public static func cube128(
            targetFPS: Double = 60.0,
            paletteExp: UInt8 = 7,
            gipURL: URL? = nil
        ) -> CaptureConfiguration {
            CaptureConfiguration(
                mode: .burst(count: 128),
                targetFPS: targetFPS,
                cubeSize: .s128,
                paletteExp: paletteExp,
                gipURL: gipURL
            )
        }
    }

    public enum CaptureState: Equatable {
        case idle
        case capturing(target: Int)
        case processing
        case completed

        public static func == (lhs: CaptureState, rhs: CaptureState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.processing, .processing), (.completed, .completed):
                return true
            case (.capturing(let l), .capturing(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    public enum CameraError: LocalizedError {
        case noCameraAvailable
        case cannotAddInput
        case cannotAddOutput
        case notAuthorized
        case configurationFailed

        public var errorDescription: String? {
            switch self {
            case .noCameraAvailable: return "No camera available"
            case .cannotAddInput: return "Cannot add camera input"
            case .cannotAddOutput: return "Cannot add camera output"
            case .notAuthorized: return "Camera access not authorized"
            case .configurationFailed: return "Camera configuration failed"
            }
        }
    }

    // MARK: - Properties

    public let session = AVCaptureSession()

    // Serial queue for all session operations
    private let sessionQueue = DispatchQueue(label: "camera.session.queue", qos: .userInitiated)

    // Output queue for frame callbacks
    private let outputQueue = DispatchQueue(label: "camera.output.queue", qos: .userInitiated)

    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()

    public weak var frameDelegate: SimpleCameraFrameDelegate?

    public private(set) var currentConfiguration: CaptureConfiguration?
    private var deviceOrientation: UIDeviceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?

    // Resource monitors (from RAW80 integration)
    private let systemMonitor = SystemMonitor()
    // MVP0: FrameValidator removed - not needed for direct GIF pipeline

    // MARK: - Published Properties
    // These are @MainActor isolated for SwiftUI binding

    @MainActor @Published public var isRunning: Bool = false
    @MainActor @Published public var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @MainActor @Published public var lastError: Error?
    @MainActor @Published public var isCapturing: Bool = false
    @MainActor @Published public var capturedFrameCount: Int = 0
    @MainActor @Published public var captureStatus: String = "Ready"
    @MainActor @Published public var currentFPS: Double = 0.0
    @MainActor @Published public var captureState: CaptureState = .idle
    @MainActor @Published public var thermalState: ProcessInfo.ThermalState = .nominal

    // Resource monitoring (from RAW80 integration)
    @MainActor @Published public var availableMemoryMB: Int = 0
    @MainActor @Published public var availableDiskSpaceGB: Int = 0
    @MainActor @Published public var memoryPressure: Float = 0.0
    @MainActor @Published public var isResourcesSufficient: Bool = true

    // MARK: - Initialization

    public override init() {
        super.init()

        // Monitor thermal state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        // Monitor orientation changes
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deviceOrientation = UIDevice.current.orientation
            self?.updateOrientation()
        }

        // Thermal state and auth status will be set on first use
        // (avoiding @MainActor access in init)

        // Initialize resource monitoring
        updateResourceMetrics()

        simpleLogger.info("SimpleCameraManager initialized")
    }

    deinit {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Authorization

    public func requestAuthorization() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        await MainActor.run {
            self.authorizationStatus = status
        }

        switch status {
        case .authorized:
            return

        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                self.authorizationStatus = granted ? .authorized : .denied
            }
            if !granted {
                throw CameraError.notAuthorized
            }

        case .denied, .restricted:
            throw CameraError.notAuthorized

        @unknown default:
            throw CameraError.notAuthorized
        }
    }

    // MARK: - Setup

    public func setup(configuration: CaptureConfiguration) throws {
        self.currentConfiguration = configuration

        // Perform all session configuration on sessionQueue
        try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Set session preset based on resolution
            if configuration.resolution.width >= 1920 {
                if session.canSetSessionPreset(.hd4K3840x2160) {
                    session.sessionPreset = .hd4K3840x2160
                } else {
                    session.sessionPreset = .hd1920x1080
                }
            } else if configuration.resolution.width >= 1280 {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }

            // Get back camera
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                throw CameraError.noCameraAvailable
            }

            // Configure device for target FPS
            do {
                try configureDevice(camera, for: configuration)
            } catch {
                simpleLogger.error("Failed to configure device: \(error)")
                throw CameraError.configurationFailed
            }

            // Create and add input
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw CameraError.cannotAddInput
            }
            session.addInput(input)
            videoDeviceInput = input

            // Configure output
            configureOutput(for: configuration.format)

            guard session.canAddOutput(videoOutput) else {
                throw CameraError.cannotAddOutput
            }
            session.addOutput(videoOutput)

            // Set connection properties (orientation, stabilization, mirroring)
            configureConnection()

            simpleLogger.info("✅ Camera setup complete: \(configuration.targetFPS)fps, \(configuration.format)")
        }
    }

    /// Configure device for deterministic frame rate
    /// IMPORTANT: Format must be selected BEFORE setting frame duration
    private func configureDevice(_ device: AVCaptureDevice, for config: CaptureConfiguration) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // STEP 1: Select optimal format FIRST (must happen before setting frame duration)
        let selectedFPS = selectOptimalFormat(for: device, config: config)

        // STEP 2: Set frame duration AFTER format is selected
        // Use the actual FPS that the selected format supports
        let actualFPS = min(config.targetFPS, selectedFPS)
        let frameDuration = CMTime(value: 1, timescale: Int32(actualFPS))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        simpleLogger.info("Device configured: \(actualFPS)fps (requested: \(config.targetFPS)fps)")
    }

    /// Select optimal capture format based on resolution, pixel format, and frame rate support
    /// Returns the maximum FPS supported by the selected format
    @discardableResult
    private func selectOptimalFormat(for device: AVCaptureDevice, config: CaptureConfiguration) -> Double {
        let targetPixelFormat: OSType = config.format == .nv12 ?
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange :
            kCVPixelFormatType_32BGRA

        let targetWidth = Int(config.resolution.width)
        let targetHeight = Int(config.resolution.height)
        let targetFPS = config.targetFPS

        // Find best matching format that supports the target FPS
        var bestFormat: AVCaptureDevice.Format?
        var bestScore = Int.max
        var bestMaxFPS: Double = 30.0  // Default fallback

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)

            // Check if this format supports the target FPS
            let maxFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30.0

            // Skip formats that don't support at least 30fps
            guard maxFPS >= 30.0 else { continue }

            // Calculate score (prefer exact pixel format match, closest resolution, and FPS support)
            var score = abs(Int(dimensions.width) - targetWidth) + abs(Int(dimensions.height) - targetHeight)

            if pixelFormat != targetPixelFormat {
                score += 10000 // Penalize pixel format mismatch
            }

            // Penalize formats that don't support target FPS
            if maxFPS < targetFPS {
                score += Int(targetFPS - maxFPS) * 100
            }

            if score < bestScore {
                bestScore = score
                bestFormat = format
                bestMaxFPS = maxFPS
            }
        }

        if let format = bestFormat {
            device.activeFormat = format
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            simpleLogger.info("Selected format: \(dims.width)×\(dims.height), max FPS: \(bestMaxFPS)")
            return bestMaxFPS
        }

        simpleLogger.warning("No optimal format found, using default")
        return 30.0  // Fallback
    }

    /// Configure video output for BGRA or NV12
    private func configureOutput(for format: CaptureFormat) {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        let pixelFormat: OSType = format == .nv12 ?
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange :
            kCVPixelFormatType_32BGRA

        if videoOutput.availableVideoPixelFormatTypes.contains(pixelFormat) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ]
            simpleLogger.info("Output configured: \(format)")
        } else {
            // Fallback to BGRA
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            simpleLogger.warning("\(format) not available, using BGRA")
        }
    }

    /// Configure connection orientation and mirroring
    private func configureConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .standard
        }

        updateConnectionOrientation(connection)

        // Mirror front camera
        if let input = videoDeviceInput, input.device.position == .front {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }

    /// Update connection orientation based on device orientation
    private func updateConnectionOrientation(_ connection: AVCaptureConnection) {
        // Use modern rotation angle API on iOS 17+, fallback to orientation enum on older versions
        if #available(iOS 17.0, *) {
            // iOS 17+: Use videoRotationAngle (continuous 0-360° values)
            let rotationAngle: Double
            switch deviceOrientation {
            case .portrait: rotationAngle = 90
            case .portraitUpsideDown: rotationAngle = 270
            case .landscapeLeft: rotationAngle = 180  // Compensate for rotation
            case .landscapeRight: rotationAngle = 0
            default: rotationAngle = 90
            }
            connection.videoRotationAngle = rotationAngle
        } else {
            // iOS 16 and earlier: Use discrete orientation enum
            guard connection.isVideoOrientationSupported else { return }

            let videoOrientation: AVCaptureVideoOrientation
            switch deviceOrientation {
            case .portrait: videoOrientation = .portrait
            case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
            case .landscapeLeft: videoOrientation = .landscapeRight // Compensate for rotation
            case .landscapeRight: videoOrientation = .landscapeLeft
            default: videoOrientation = .portrait
            }

            connection.videoOrientation = videoOrientation
        }
    }

    // MARK: - Session Control

    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.session.isRunning else { return }
            self.session.startRunning()

            Task { @MainActor in
                self.isRunning = true
                simpleLogger.info("Camera session started")
            }
        }
    }

    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()

            Task { @MainActor in
                self.isRunning = false
                simpleLogger.info("Camera session stopped")
            }
        }
    }

    // MARK: - Camera Switch

    public func switchCamera() throws {
        try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            // Remove current input
            if let currentInput = videoDeviceInput {
                session.removeInput(currentInput)
            }

            // Get opposite camera
            let newPosition: AVCaptureDevice.Position = videoDeviceInput?.device.position == .back ? .front : .back

            guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
                throw CameraError.noCameraAvailable
            }

            // Configure new device
            if let config = currentConfiguration {
                try? configureDevice(newCamera, for: config)
            }

            // Create new input
            let newInput = try AVCaptureDeviceInput(device: newCamera)
            guard session.canAddInput(newInput) else {
                throw CameraError.cannotAddInput
            }

            session.addInput(newInput)
            videoDeviceInput = newInput

            // Update connection for new camera
            configureConnection()

            simpleLogger.info("Switched to \(newPosition == .back ? "back" : "front") camera")
        }
    }

    // MARK: - Orientation Updates

    @objc private func updateOrientation() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        updateConnectionOrientation(connection)
    }

    // MARK: - Thermal Monitoring

    @objc private func thermalStateChanged() {
        Task { @MainActor in
            self.thermalState = ProcessInfo.processInfo.thermalState
            simpleLogger.info("Thermal state: \(self.thermalState.rawValue)")
        }
    }

    // MARK: - Resource Monitoring (RAW80 Integration)

    /// Update resource monitoring metrics (call periodically during capture)
    public func updateResourceMetrics() {
        Task { @MainActor in
            // Update memory metrics
            let availableBytes = systemMonitor.availableMemory()
            self.availableMemoryMB = Int(availableBytes / 1024 / 1024)
            self.memoryPressure = systemMonitor.memoryPressure()

            // Update disk space metrics
            if let diskBytes = systemMonitor.availableDiskSpace() {
                self.availableDiskSpaceGB = Int(diskBytes / 1024 / 1024 / 1024)
            }

            // Check if resources are sufficient
            let validation = systemMonitor.validateForCapture()
            self.isResourcesSufficient = validation.isValid

            if !validation.isValid {
                simpleLogger.warning("Resource validation failed: \(validation.errorMessage ?? "Unknown")")
            }
        }
    }

    /// Validate resources before starting capture
    public func validateResourcesForCapture() -> (isValid: Bool, message: String?) {
        let validation = systemMonitor.validateForCapture()
        return (validation.isValid, validation.errorMessage)
    }

    // MVP0: Frame validation methods removed - using direct GIF pipeline

    // MARK: - Lifecycle (Foreground/Background)

    public func handleAppWillResignActive() {
        stopSession()
    }

    @MainActor
    public func handleAppDidBecomeActive() {
        if authorizationStatus == .authorized {
            startSession()
        }
    }
}

// MARK: - Sample Buffer Delegate

@available(iOS 26.0, *)
extension SimpleCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Forward to delegate on OUTPUT queue (not main thread)
        // Delegate decides when to hop to main
        frameDelegate?.cameraManager(self, didOutput: sampleBuffer)
    }
}

// MARK: - Delegate Protocol

@available(iOS 26.0, *)
public protocol SimpleCameraFrameDelegate: AnyObject {
    func cameraManager(_ manager: SimpleCameraManager, didOutput sampleBuffer: CMSampleBuffer)
}
