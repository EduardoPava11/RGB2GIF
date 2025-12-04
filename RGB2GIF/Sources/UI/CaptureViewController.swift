//
//  CaptureViewController.swift
//  RGB2GIF
//
//  Main camera capture UI with single capture button
//

import UIKit
import AVFoundation
import os.log

private let uiLogger = Logger(subsystem: "com.rgb2gif", category: "CaptureVC")

// MARK: - CaptureViewController

@available(iOS 26.0, *)
public class CaptureViewController: UIViewController {

    // MARK: - Constants

    private static let frameCount = 81
    private static let dimension = 81

    // MARK: - UI Elements

    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var captureButton: UIButton!
    private var statusLabel: UILabel!
    private var progressView: UIProgressView!
    private var debugButton: UIButton!

    // MARK: - State

    private var cameraManager: CameraManager!
    private var frameBuffer: FrameBuffer!
    private var isCapturing = false
    private var isProcessing = false

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        uiLogger.info("CaptureViewController loaded")

        view.backgroundColor = .black
        setupUI()

        frameBuffer = FrameBuffer()

        Task {
            await setupCamera()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        cameraManager?.startSession()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraManager?.stopSession()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Status label
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

        // Progress view
        progressView = UIProgressView(progressViewStyle: .default)
        progressView.progressTintColor = .systemGreen
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        view.addSubview(progressView)

        // Capture button
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

        // Debug button (top-right corner)
        debugButton = UIButton(type: .system)
        debugButton.setTitle("📤 Debug", for: .normal)
        debugButton.titleLabel?.font = .boldSystemFont(ofSize: 14)
        debugButton.setTitleColor(.white, for: .normal)
        debugButton.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.8)
        debugButton.layer.cornerRadius = 8
        debugButton.translatesAutoresizingMaskIntoConstraints = false
        debugButton.addTarget(self, action: #selector(debugButtonTapped), for: .touchUpInside)
        view.addSubview(debugButton)

        // Square frame overlay
        let frameOverlay = UIView()
        frameOverlay.backgroundColor = .clear
        frameOverlay.layer.borderWidth = 2
        frameOverlay.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        frameOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameOverlay)

        // Constraints
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusLabel.heightAnchor.constraint(equalToConstant: 36),

            debugButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            debugButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            debugButton.widthAnchor.constraint(equalToConstant: 80),
            debugButton.heightAnchor.constraint(equalToConstant: 32),

            progressView.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -20),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 80),
            captureButton.heightAnchor.constraint(equalToConstant: 80),

            frameOverlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameOverlay.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            frameOverlay.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
            frameOverlay.heightAnchor.constraint(equalTo: frameOverlay.widthAnchor),
        ])
    }

    // MARK: - Camera Setup

    private func setupCamera() async {
        cameraManager = CameraManager()

        do {
            try await cameraManager.requestAuthorization()
            try cameraManager.setup()

            await MainActor.run {
                setupPreviewLayer()
            }

            cameraManager.startSession()
            uiLogger.info("Camera ready")

        } catch {
            uiLogger.error("Camera setup failed: \(error)")
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
    }

    // MARK: - Capture

    @objc private func captureButtonTapped() {
        guard !isCapturing && !isProcessing else {
            uiLogger.warning("Already capturing or processing")
            return
        }

        uiLogger.info("Capture started")
        isCapturing = true

        // Update UI
        statusLabel.text = "Capturing..."
        statusLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.6)
        captureButton.isEnabled = false
        captureButton.alpha = 0.5
        progressView.isHidden = false
        progressView.progress = 0

        // Start capture
        Task {
            await frameBuffer.startCapture()
        }

        cameraManager.frameDelegate = self
    }

    // MARK: - Processing

    private func processFrames() async {
        isProcessing = true

        await MainActor.run {
            statusLabel.text = "Creating GIF..."
            statusLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.6)
        }

        do {
            let frames = await frameBuffer.snapshot()
            uiLogger.info("Processing \(frames.count) frames")

            // Process through pipeline
            let result = try await GIF81Pipeline.process(frames: frames)

            uiLogger.info("GIF created: \(String(format: "%.1f", result.fileSizeKB))KB in \(String(format: "%.0f", result.processingTimeMs))ms")

            // Save to Photos
            try await PhotosSaver.save(gifData: result.gifData)
            uiLogger.info("Saved to Photos")

            await MainActor.run {
                showSuccess(fileSize: result.fileSize)
            }

        } catch {
            uiLogger.error("Processing failed: \(error)")
            await MainActor.run {
                statusLabel.text = "Error: \(error.localizedDescription)"
                statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.6)
            }
        }

        await MainActor.run {
            resetUI()
        }
    }

    // MARK: - Debug Export

    @objc private func debugButtonTapped() {
        uiLogger.info("Debug button tapped")

        // Find the most recent session
        let sessions = CBORSessionManager.listSessions()
        guard let latestSession = sessions.first else {
            showAlert(title: "No Sessions", message: "No CBOR sessions found. Capture a GIF first!")
            return
        }

        // Show action sheet
        let alert = UIAlertController(
            title: "Export Debug Data",
            message: "Session: \(latestSession)",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "🧪 Run Pipeline Tests", style: .default) { [weak self] _ in
            self?.runPipelineTests(sessionID: latestSession)
        })

        alert.addAction(UIAlertAction(title: "Share Session Folder", style: .default) { [weak self] _ in
            self?.shareSession(sessionID: latestSession)
        })

        alert.addAction(UIAlertAction(title: "Share Latest GIF", style: .default) { [weak self] _ in
            self?.shareLatestGIF(sessionID: latestSession)
        })

        alert.addAction(UIAlertAction(title: "Show Session Path", style: .default) { [weak self] _ in
            self?.showSessionPath(sessionID: latestSession)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    private func shareSession(sessionID: String) {
        do {
            let session = try CBORSessionManager(existingSessionID: sessionID)
            let sessionURL = session.sessionURL

            // Share the folder directly via UIActivityViewController
            let activityVC = UIActivityViewController(
                activityItems: [sessionURL],
                applicationActivities: nil
            )

            // For iPad
            activityVC.popoverPresentationController?.sourceView = debugButton
            activityVC.popoverPresentationController?.sourceRect = debugButton.bounds

            present(activityVC, animated: true)
            uiLogger.info("Sharing session: \(sessionURL.path)")

        } catch {
            showAlert(title: "Error", message: "Failed to load session: \(error.localizedDescription)")
        }
    }

    private func shareLatestGIF(sessionID: String) {
        do {
            let session = try CBORSessionManager(existingSessionID: sessionID)
            let gifURL = session.gifOutputURL

            guard FileManager.default.fileExists(atPath: gifURL.path) else {
                showAlert(title: "No GIF", message: "No GIF found in session. Run capture first!")
                return
            }

            let activityVC = UIActivityViewController(
                activityItems: [gifURL],
                applicationActivities: nil
            )

            activityVC.popoverPresentationController?.sourceView = debugButton
            activityVC.popoverPresentationController?.sourceRect = debugButton.bounds

            present(activityVC, animated: true)
            uiLogger.info("Sharing GIF: \(gifURL.path)")

        } catch {
            showAlert(title: "Error", message: "Failed to load session: \(error.localizedDescription)")
        }
    }

    private func showSessionPath(sessionID: String) {
        do {
            let session = try CBORSessionManager(existingSessionID: sessionID)

            // Log all paths
            uiLogger.info("=== SESSION PATHS ===")
            uiLogger.info("Session URL: \(session.sessionURL.path)")
            uiLogger.info("L0_raw: \(session.l0RawURL.path)")
            uiLogger.info("L1_cropped: \(session.l1CroppedURL.path)")
            uiLogger.info("L2_frames: \(session.l2FramesURL.path)")
            uiLogger.info("L3_tensor: \(session.l3TensorURL.path)")
            uiLogger.info("L4_palette: \(session.l4PaletteURL.path)")
            uiLogger.info("L5_indices: \(session.l5IndicesURL.path)")
            uiLogger.info("L6_output: \(session.l6OutputURL.path)")
            uiLogger.info("=====================")

            // Show path in alert
            showAlert(
                title: "Session Path",
                message: """
                Session: \(sessionID)

                Access via Files app:
                On My iPhone → RGB2GIF → RGB2GIF → captures → \(sessionID)

                Or use Xcode:
                Window → Devices → Download Container
                """
            )

        } catch {
            showAlert(title: "Error", message: "Failed to load session: \(error.localizedDescription)")
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - CBOR Pipeline Tests (TEXT output only - no GIF files)

    private func runPipelineTests(sessionID: String) {
        uiLogger.info("🧪 Starting CBOR Pipeline Tests for session: \(sessionID)")

        // Update UI
        statusLabel.text = "Running Pipeline Tests..."
        statusLabel.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.6)
        captureButton.isEnabled = false
        captureButton.alpha = 0.5

        Task {
            do {
                // Open existing session
                let session = try CBORSessionManager(existingSessionID: sessionID)
                uiLogger.info("📁 Testing session: \(session.sessionURL.path)")

                // Run CBOR-based pipeline tests (TEXT output only)
                let testSuite = PipelineTestSuite(session: session)
                let report = await testSuite.runAllTests()

                // Generate TEXT report
                let textReport = report.generateTextReport()
                let quickSummary = testSuite.quickSummary(from: report)

                // Log full report
                uiLogger.info("\n\(textReport)")

                await MainActor.run {
                    // Show summary in alert
                    let message = """
                        \(report.totalPassed)/\(report.totalTests) tests passed (\(String(format: "%.1f", report.passPercentage))%)

                        L0_RAW:      \(report.l0Results.passCount)/\(report.l0Results.totalCount) \(report.l0Results.allPassed ? "✅" : "⚠️")
                        L2_FRAMES:   \(report.l2Results.passCount)/\(report.l2Results.totalCount) \(report.l2Results.allPassed ? "✅" : "⚠️")
                        L3_TENSOR:   \(report.l3Results.passCount)/\(report.l3Results.totalCount) \(report.l3Results.allPassed ? "✅" : "⚠️")
                        L4_PALETTE:  \(report.l4Results.passCount)/\(report.l4Results.totalCount) \(report.l4Results.allPassed ? "✅" : "⚠️")
                        L5_INDICES:  \(report.l5Results.passCount)/\(report.l5Results.totalCount) \(report.l5Results.allPassed ? "✅" : "⚠️")
                        CROSS-STAGE: \(report.crossStageResults.passCount)/\(report.crossStageResults.totalCount) \(report.crossStageResults.allPassed ? "✅" : "⚠️")
                        END-TO-END:  \(report.e2eResults.passCount)/\(report.e2eResults.totalCount) \(report.e2eResults.allPassed ? "✅" : "⚠️")

                        \(report.warnings.isEmpty ? "" : "⚠️ \(report.warnings.count) warning(s)")
                        """

                    self.showTextReport(
                        title: report.totalPassed == report.totalTests ? "✅ All Tests Passed!" : "⚠️ Issues Found",
                        summary: message,
                        fullReport: textReport
                    )

                    self.resetUI()
                }

            } catch {
                uiLogger.error("❌ Pipeline tests failed: \(error)")
                await MainActor.run {
                    self.showAlert(title: "Test Error", message: "Pipeline tests failed: \(error.localizedDescription)")
                    self.resetUI()
                }
            }
        }
    }

    private func showTextReport(title: String, summary: String, fullReport: String) {
        let alert = UIAlertController(title: title, message: summary, preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Share Full Report", style: .default) { [weak self] _ in
            // Share the text report
            let activityVC = UIActivityViewController(
                activityItems: [fullReport],
                applicationActivities: nil
            )
            activityVC.popoverPresentationController?.sourceView = self?.debugButton
            self?.present(activityVC, animated: true)
        })

        alert.addAction(UIAlertAction(title: "Copy to Clipboard", style: .default) { _ in
            UIPasteboard.general.string = fullReport
        })

        alert.addAction(UIAlertAction(title: "OK", style: .cancel))

        present(alert, animated: true)
    }

    private func showResultsAndShare(title: String, message: String, outputDirectory: URL) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "Share Results", style: .default) { [weak self] _ in
            let activityVC = UIActivityViewController(
                activityItems: [outputDirectory],
                applicationActivities: nil
            )
            activityVC.popoverPresentationController?.sourceView = self?.debugButton
            self?.present(activityVC, animated: true)
        })

        alert.addAction(UIAlertAction(title: "OK", style: .cancel))

        present(alert, animated: true)
    }

    // MARK: - UI Helpers

    private func resetUI() {
        isCapturing = false
        isProcessing = false
        captureButton.isEnabled = true
        captureButton.alpha = 1.0
        progressView.isHidden = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusLabel.text = "Ready • 81×81×81"
            self?.statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        }
    }

    private func showSuccess(fileSize: Int) {
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
    }
}

// MARK: - CameraFrameDelegate

@available(iOS 26.0, *)
extension CaptureViewController: CameraFrameDelegate {

    public func cameraManager(_ manager: CameraManager, didCaptureFrame frame: CGImage) {
        guard isCapturing else { return }

        Task {
            let count = await frameBuffer.addFrame(frame)
            let progress = await frameBuffer.progress
            let isFull = await frameBuffer.isFull

            await MainActor.run {
                progressView.progress = progress
                statusLabel.text = "\(count) / \(Self.frameCount) frames"
            }

            if isFull {
                isCapturing = false
                cameraManager.frameDelegate = nil
                await processFrames()
            }
        }
    }
}
