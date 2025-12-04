//
//  SimpleRealCameraViewController.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  MVP0: MINIMAL CAMERA → 81×81×81 GIF PIPELINE                             ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║  - Camera preview with square frame guide                                 ║
//  ║  - Single capture button                                                  ║
//  ║  - Direct pipeline: CGImage → SimpleGIF81Pipeline → Photos                ║
//  ║  - No GIP/GIX intermediate formats                                        ║
//  ║  - No theme system                                                        ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import UIKit
import AVFoundation
import Photos
import os.log
import CoreGraphics

private let logger = Logger(subsystem: "com.rgb2gif", category: "MVP0Camera")

@available(iOS 26.0, *)
class SimpleRealCameraViewController: UIViewController {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants (81 = 3⁴)
    // ════════════════════════════════════════════════════════════════════════

    private static let frameCount = 81
    private static let dimension = 81
    private static let targetFPS: Double = 30.0

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - UI Components
    // ════════════════════════════════════════════════════════════════════════

    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var squareFrameOverlay: UIView!
    private var captureButton: UIButton!
    private var statusLabel: UILabel!
    private var frameCountLabel: UILabel!
    private var progressView: UIProgressView!

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Camera & Capture State
    // ════════════════════════════════════════════════════════════════════════

    private var cameraManager: SimpleCameraManager!
    private var captureManager: TemporalCubeCaptureManager!
    private var isCapturing = false
    private var isProcessing = false

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ════════════════════════════════════════════════════════════════════════

    override func viewDidLoad() {
        super.viewDidLoad()

        logger.info("╔══════════════════════════════════════════════════════════╗")
        logger.info("║  MVP0 Camera View Controller - Loading                   ║")
        logger.info("╚══════════════════════════════════════════════════════════╝")

        view.backgroundColor = .black
        setupUI()

        Task {
            await setupCamera()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        cameraManager?.startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraManager?.stopSession()
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - UI Setup
    // ════════════════════════════════════════════════════════════════════════

    private func setupUI() {
        // Status label at top
        statusLabel = UILabel()
        statusLabel.text = "Ready • 81×81×81"
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 18)
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Frame count label
        frameCountLabel = UILabel()
        frameCountLabel.text = "0 / \(Self.frameCount) frames"
        frameCountLabel.textColor = .lightGray
        frameCountLabel.font = .systemFont(ofSize: 14)
        frameCountLabel.textAlignment = .center
        frameCountLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        frameCountLabel.layer.cornerRadius = 6
        frameCountLabel.clipsToBounds = true
        frameCountLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameCountLabel)

        // Progress view (hidden until capture starts)
        progressView = UIProgressView(progressViewStyle: .default)
        progressView.progressTintColor = .systemGreen
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        view.addSubview(progressView)

        // Capture button (large circular button)
        captureButton = UIButton(type: .system)
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 40
        captureButton.layer.borderWidth = 4
        captureButton.layer.borderColor = UIColor.systemGreen.cgColor
        captureButton.setTitle("●", for: .normal)
        captureButton.titleLabel?.font = .systemFont(ofSize: 50, weight: .bold)
        captureButton.setTitleColor(.systemRed, for: .normal)
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        view.addSubview(captureButton)

        // Square frame overlay (visual guide for 81×81 capture area)
        squareFrameOverlay = UIView()
        squareFrameOverlay.backgroundColor = .clear
        squareFrameOverlay.layer.borderWidth = 2
        squareFrameOverlay.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        squareFrameOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(squareFrameOverlay)

        // Constraints
        NSLayoutConstraint.activate([
            // Status label at top
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusLabel.heightAnchor.constraint(equalToConstant: 36),

            // Frame count below status
            frameCountLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            frameCountLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            frameCountLabel.heightAnchor.constraint(equalToConstant: 28),

            // Progress view
            progressView.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -20),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            // Capture button at bottom center
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 80),
            captureButton.heightAnchor.constraint(equalToConstant: 80),

            // Square frame overlay (centered, square)
            squareFrameOverlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            squareFrameOverlay.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            squareFrameOverlay.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
            squareFrameOverlay.heightAnchor.constraint(equalTo: squareFrameOverlay.widthAnchor),
        ])

        logger.info("✓ UI setup complete")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Camera Setup
    // ════════════════════════════════════════════════════════════════════════

    private func setupCamera() async {
        logger.info("Setting up camera...")

        cameraManager = SimpleCameraManager()

        do {
            try await cameraManager.requestAuthorization()

            let config = SimpleCameraManager.CaptureConfiguration(
                mode: .burst(count: Self.frameCount),
                targetFPS: Self.targetFPS,
                resolution: CGSize(width: Self.dimension, height: Self.dimension),
                format: .bgra
            )
            try cameraManager.setup(configuration: config)

            await MainActor.run {
                setupPreviewLayer()
            }

            cameraManager.startSession()
            logger.info("✓ Camera ready")

            await MainActor.run {
                statusLabel.text = "Ready • 81×81×81"
            }

        } catch {
            logger.error("Camera setup failed: \(error)")
            await MainActor.run {
                statusLabel.text = "Camera Error"
                statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.6)
            }
        }
    }

    private func setupPreviewLayer() {
        previewLayer = AVCaptureVideoPreviewLayer(session: cameraManager.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        logger.info("✓ Preview layer configured")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Capture Button Action
    // ════════════════════════════════════════════════════════════════════════

    @objc private func captureButtonTapped() {
        guard !isCapturing && !isProcessing else {
            logger.warning("Capture/processing already in progress")
            return
        }

        logger.info("╔══════════════════════════════════════════════════════════╗")
        logger.info("║  CAPTURE STARTED - Recording 81 frames                   ║")
        logger.info("╚══════════════════════════════════════════════════════════╝")

        isCapturing = true

        // Update UI
        statusLabel.text = "Capturing..."
        statusLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.6)
        captureButton.isEnabled = false
        captureButton.alpha = 0.5
        progressView.isHidden = false
        progressView.progress = 0

        // Initialize capture manager with MVP0 mode (81×81×81)
        captureManager = TemporalCubeCaptureManager(mode: .frames81)
        captureManager.delegate = self
        cameraManager.frameDelegate = captureManager

        do {
            try captureManager.startCapture()
        } catch {
            logger.error("Failed to start capture: \(error)")
            resetUI()
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - GIF Processing
    // ════════════════════════════════════════════════════════════════════════

    private func processCapturedFrames(_ frames: [CGImage]) {
        guard frames.count == Self.frameCount else {
            logger.error("Wrong frame count: \(frames.count) (expected \(Self.frameCount))")
            resetUI()
            return
        }

        isProcessing = true
        statusLabel.text = "Creating GIF..."
        statusLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.6)

        Task {
            do {
                // Create output URL in temp directory
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mvp0_\(Int(Date().timeIntervalSince1970)).gif")

                logger.info("Processing \(frames.count) frames → \(outputURL.lastPathComponent)")

                // Use GIF81Pipeline for direct GIF creation with VoxelCube729
                let result = try await GIF81Pipeline.process(
                    frames: frames,
                    outputURL: outputURL
                )

                logger.info("✓ GIF created: \(result.fileSizeString) in \(String(format: "%.1f", result.processingTimeMs))ms")

                // Log VoxelCube729 stats if built
                if let cube = result.voxelCube {
                    let stats = cube.statistics()
                    logger.info("✓ VoxelCube729 built: \(stats.uniqueGroupCount) groups")
                }

                // Save to Photos
                try await PhotosGIFSaver.saveGIF(at: result.gifURL)
                logger.info("✓ Saved to Photos")

                await MainActor.run {
                    showSuccessToast(fileSize: result.fileSize)
                    resetUI()
                }

            } catch {
                logger.error("GIF processing failed: \(error)")
                await MainActor.run {
                    statusLabel.text = "Error: \(error.localizedDescription)"
                    statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.6)
                    resetUI()
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - UI Helpers
    // ════════════════════════════════════════════════════════════════════════

    private func resetUI() {
        isCapturing = false
        isProcessing = false
        captureButton.isEnabled = true
        captureButton.alpha = 1.0
        progressView.isHidden = true
        frameCountLabel.text = "0 / \(Self.frameCount) frames"

        // Reset status after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.statusLabel.text = "Ready • 81×81×81"
            self.statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        }
    }

    private func showSuccessToast(fileSize: Int) {
        let sizeKB = Double(fileSize) / 1024.0

        let toast = UIView()
        toast.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
        toast.layer.cornerRadius = 12
        toast.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "✓ GIF Saved! (\(String(format: "%.1f", sizeKB)) KB)"
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 16)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        toast.addSubview(label)
        view.addSubview(toast)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: toast.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: toast.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16),

            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            toast.heightAnchor.constraint(equalToConstant: 50),
        ])

        toast.alpha = 0
        UIView.animate(withDuration: 0.3) {
            toast.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.3, animations: {
                toast.alpha = 0
            }) { _ in
                toast.removeFromSuperview()
            }
        }

        logger.info("╔══════════════════════════════════════════════════════════╗")
        logger.info("║  GIF SAVED TO PHOTOS                                     ║")
        logger.info("║  Size: \(String(format: "%.1f", sizeKB)) KB                                         ║")
        logger.info("╚══════════════════════════════════════════════════════════╝")
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - TemporalCubeCaptureDelegate
// ════════════════════════════════════════════════════════════════════════════

@available(iOS 26.0, *)
extension SimpleRealCameraViewController: TemporalCubeCaptureDelegate {

    func captureManager(_ manager: TemporalCubeCaptureManager, didCaptureFrame frameIndex: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let count = frameIndex + 1
            self.frameCountLabel.text = "\(count) / \(Self.frameCount) frames"
            self.progressView.progress = Float(count) / Float(Self.frameCount)
        }
    }

    func captureManager(_ manager: TemporalCubeCaptureManager, didFinishWithFrames frames: [CGImage]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.cameraManager.frameDelegate = nil
            self.isCapturing = false

            logger.info("✓ Capture complete: \(frames.count) frames")
            self.processCapturedFrames(frames)
        }
    }

    func captureManager(_ manager: TemporalCubeCaptureManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            logger.error("Capture failed: \(error)")
            self.statusLabel.text = "Capture Failed"
            self.statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.6)
            self.resetUI()
        }
    }
}
