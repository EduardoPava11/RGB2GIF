//
//  CameraManager.swift
//  RGB2GIF
//
//  AVCaptureSession wrapper for frame capture
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import os.log

private let cameraLogger = Logger(subsystem: "com.rgb2gif", category: "CameraManager")

// MARK: - Frame Delegate Protocol

@available(iOS 26.0, *)
public protocol CameraFrameDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didCaptureFrame frame: CGImage)
}

// MARK: - CameraManager

@available(iOS 26.0, *)
public class CameraManager: NSObject {

    // MARK: - Properties

    public private(set) var session: AVCaptureSession
    public weak var frameDelegate: CameraFrameDelegate?

    private var videoOutput: AVCaptureVideoDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.rgb2gif.camera.session")
    private let outputQueue = DispatchQueue(label: "com.rgb2gif.camera.output")

    private var isSessionRunning = false
    // Note: ciContext removed - we now copy directly from CVPixelBuffer for CPU-backed images

    // MARK: - Initialization

    public override init() {
        self.session = AVCaptureSession()
        super.init()
    }

    // MARK: - Authorization

    public func requestAuthorization() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            cameraLogger.info("Camera already authorized")
            return

        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                throw RGB2GIFError.cameraNotAuthorized
            }
            cameraLogger.info("Camera authorization granted")

        case .denied, .restricted:
            throw RGB2GIFError.cameraNotAuthorized

        @unknown default:
            throw RGB2GIFError.cameraNotAuthorized
        }
    }

    // MARK: - Setup

    public func setup() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        // Add video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw RGB2GIFError.cameraSetupFailed("No camera available")
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            throw RGB2GIFError.cameraSetupFailed("Cannot create video input: \(error.localizedDescription)")
        }

        guard session.canAddInput(videoInput) else {
            throw RGB2GIFError.cameraSetupFailed("Cannot add video input to session")
        }
        session.addInput(videoInput)

        // Add video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            throw RGB2GIFError.cameraSetupFailed("Cannot add video output to session")
        }
        session.addOutput(output)
        self.videoOutput = output

        // Configure for portrait orientation
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        cameraLogger.info("Camera setup complete")
    }

    // MARK: - Session Control

    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isSessionRunning else { return }
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            cameraLogger.info("Camera session started")
        }
    }

    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.isSessionRunning else { return }
            self.session.stopRunning()
            self.isSessionRunning = false
            cameraLogger.info("Camera session stopped")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

@available(iOS 26.0, *)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ════════════════════════════════════════════════════════════════════
        // CRITICAL FIX: Bypass CIImage and copy directly from CVPixelBuffer
        // CIImage→CGImage may produce GPU-backed images with partial CPU access
        // Direct copy guarantees 100% CPU-accessible pixel data
        // ════════════════════════════════════════════════════════════════════

        // Lock the pixel buffer for CPU access (forces GPU→CPU sync if needed)
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            cameraLogger.error("Failed to get CVPixelBuffer base address")
            return
        }

        // Copy pixel data to Swift-managed memory (guarantees CPU accessibility)
        let dataSize = bytesPerRow * height
        let pixelData = Data(bytes: baseAddress, count: dataSize)

        // Create CGDataProvider from our copied data
        guard let provider = CGDataProvider(data: pixelData as CFData) else {
            cameraLogger.error("Failed to create CGDataProvider")
            return
        }

        // Camera outputs BGRA (kCVPixelFormatType_32BGRA)
        // byteOrder32Little + premultipliedFirst = BGRA memory layout
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        // Create CGImage backed by our CPU-copied data
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            cameraLogger.error("Failed to create CGImage from pixel data")
            return
        }

        // Debug: Log first frame dimensions
        if frameDelegate != nil {
            print("📷 [CAMERA] Frame captured: \(width)×\(height) bytesPerRow=\(bytesPerRow) dataSize=\(dataSize)")
        }

        // Notify delegate with CPU-backed CGImage
        frameDelegate?.cameraManager(self, didCaptureFrame: cgImage)
    }
}
