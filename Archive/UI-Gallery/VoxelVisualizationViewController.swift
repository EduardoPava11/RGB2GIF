//
//  VoxelVisualizationViewController.swift
//  RGB2GIF
//
//  View controller for 3D voxel cube visualization with interactive controls
//

import UIKit
import Metal
import MetalKit
import CoreGraphics
import os.log
import UniformTypeIdentifiers

private let voxelViewLogger = Logger(subsystem: "com.rgb2gif", category: "VoxelVisualization")

/// View controller for 3D voxel cube visualization
@available(iOS 26.0, *)
public final class VoxelVisualizationViewController: UIViewController {

    // MARK: - Properties

    private var voxelRenderer: VoxelRenderer!
    private var controlsView: UIView!
    private var infoLabel: UILabel!
    private var speedSlider: UISlider!
    private var distanceSlider: UISlider!
    private var playPauseButton: UIButton!
    private var exportButton: UIButton!
    private var closeButton: UIButton!

    private var voxelCube: VoxelGIFProcessor.VoxelCube?
    private var isPlaying = true

    // Gesture recognition
    private var panGesture: UIPanGestureRecognizer!
    private var pinchGesture: UIPinchGestureRecognizer!
    private var lastPanTranslation = CGPoint.zero
    private var currentRotation = CGPoint(x: 0.3, y: 0.5)
    private var currentDistance: Float = 200.0

    // Performance monitoring
    private var fpsLabel: UILabel!
    private var frameTimer: Timer?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupGestures()
        setupRenderer()
        startPerformanceMonitoring()

        voxelViewLogger.info("VoxelVisualizationViewController loaded")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voxelRenderer?.setPaused(false)
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        voxelRenderer?.setPaused(true)
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Controls container
        controlsView = UIView()
        controlsView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        controlsView.layer.cornerRadius = 16
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsView)

        // Info label
        infoLabel = UILabel()
        infoLabel.text = "🎯 Voxel Cube Visualization"
        infoLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        infoLabel.textAlignment = .center
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(infoLabel)

        // Speed control
        let speedLabel = UILabel()
        speedLabel.text = "Animation Speed"
        speedLabel.font = .systemFont(ofSize: 14)
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(speedLabel)

        speedSlider = UISlider()
        speedSlider.minimumValue = 0.0
        speedSlider.maximumValue = 5.0
        speedSlider.value = 1.0
        speedSlider.addTarget(self, action: #selector(speedChanged), for: .valueChanged)
        speedSlider.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(speedSlider)

        // Distance control
        let distanceLabel = UILabel()
        distanceLabel.text = "View Distance"
        distanceLabel.font = .systemFont(ofSize: 14)
        distanceLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(distanceLabel)

        distanceSlider = UISlider()
        distanceSlider.minimumValue = 100
        distanceSlider.maximumValue = 400
        distanceSlider.value = 200
        distanceSlider.addTarget(self, action: #selector(distanceChanged), for: .valueChanged)
        distanceSlider.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(distanceSlider)

        // Play/Pause button
        playPauseButton = UIButton(type: .system)
        playPauseButton.setTitle("⏸", for: .normal)
        playPauseButton.titleLabel?.font = .systemFont(ofSize: 30)
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(playPauseButton)

        // Export button
        exportButton = UIButton(type: .system)
        exportButton.setTitle("💾 Export", for: .normal)
        exportButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        exportButton.addTarget(self, action: #selector(exportVoxels), for: .touchUpInside)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(exportButton)

        // Close button
        closeButton = UIButton(type: .system)
        closeButton.setTitle("✕", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        // FPS label
        fpsLabel = UILabel()
        fpsLabel.text = "120 FPS"
        fpsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        fpsLabel.textColor = .systemGreen
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        // Setup constraints
        NSLayoutConstraint.activate([
            // Controls view
            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controlsView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            controlsView.heightAnchor.constraint(equalToConstant: 200),

            // Info label
            infoLabel.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 16),
            infoLabel.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -16),

            // Speed controls
            speedLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 16),
            speedLabel.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),

            speedSlider.topAnchor.constraint(equalTo: speedLabel.bottomAnchor, constant: 4),
            speedSlider.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),
            speedSlider.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -16),

            // Distance controls
            distanceLabel.topAnchor.constraint(equalTo: speedSlider.bottomAnchor, constant: 12),
            distanceLabel.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),

            distanceSlider.topAnchor.constraint(equalTo: distanceLabel.bottomAnchor, constant: 4),
            distanceSlider.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),
            distanceSlider.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -16),

            // Buttons
            playPauseButton.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor, constant: -16),
            playPauseButton.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 16),
            playPauseButton.widthAnchor.constraint(equalToConstant: 60),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            exportButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -16),
            exportButton.widthAnchor.constraint(equalToConstant: 100),
            exportButton.heightAnchor.constraint(equalToConstant: 44),

            // Close button
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // FPS label
            fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            fpsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
        ])
    }

    private func setupRenderer() {
        // Create Metal view
        voxelRenderer = VoxelRenderer(frame: view.bounds)
        voxelRenderer.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(voxelRenderer, at: 0)

        NSLayoutConstraint.activate([
            voxelRenderer.topAnchor.constraint(equalTo: view.topAnchor),
            voxelRenderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            voxelRenderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            voxelRenderer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Load voxel cube if available
        if let cube = voxelCube {
            voxelRenderer.loadVoxelCube(cube)
            updateInfoLabel(for: cube)
        }
    }

    private func setupGestures() {
        // Pan gesture for rotation
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        view.addGestureRecognizer(panGesture)

        // Pinch gesture for zoom
        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        view.addGestureRecognizer(pinchGesture)
    }

    private func startPerformanceMonitoring() {
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateFPSLabel()
        }
    }

    // MARK: - Public API

    /// Load voxel cube for visualization
    public func loadVoxelCube(_ cube: VoxelGIFProcessor.VoxelCube) {
        self.voxelCube = cube

        if isViewLoaded {
            voxelRenderer?.loadVoxelCube(cube)
            updateInfoLabel(for: cube)
        }

        voxelViewLogger.info("Loaded voxel cube: \(cube.dimension.rawValue)³")
    }

    // MARK: - Actions

    @objc private func speedChanged() {
        voxelRenderer?.setAnimationSpeed(speedSlider.value)
    }

    @objc private func distanceChanged() {
        currentDistance = distanceSlider.value
        voxelRenderer?.setCameraDistance(currentDistance)
    }

    @objc private func togglePlayPause() {
        isPlaying.toggle()
        voxelRenderer?.setPaused(!isPlaying)
        playPauseButton.setTitle(isPlaying ? "⏸" : "▶️", for: .normal)
    }

    @objc private func exportVoxels() {
        guard let cube = voxelCube else { return }

        // Create activity indicator
        let alert = UIAlertController(title: "Exporting", message: "Creating GIF...", preferredStyle: .alert)
        let indicator = UIActivityIndicatorView(frame: CGRect(x: 10, y: 5, width: 50, height: 50))
        indicator.style = .medium
        indicator.startAnimating()
        alert.view.addSubview(indicator)
        present(alert, animated: true)

        Task {
            do {
                // Export as GIF
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let gifURL = documentsURL.appendingPathComponent("voxel_cube.gif")

                let processor = VoxelGIFProcessor()
                try await processor.exportAsGIF(cube, to: gifURL)

                await MainActor.run {
                    alert.dismiss(animated: true) {
                        self.shareFile(at: gifURL)
                    }
                }

                voxelViewLogger.info("Exported voxel cube to GIF")

            } catch {
                await MainActor.run {
                    alert.dismiss(animated: true) {
                        self.showError("Export failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func close() {
        frameTimer?.invalidate()
        dismiss(animated: true)
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        if gesture.state == .began {
            lastPanTranslation = .zero
        } else if gesture.state == .changed {
            let deltaX = translation.x - lastPanTranslation.x
            let deltaY = translation.y - lastPanTranslation.y

            // Update rotation
            currentRotation.x += CGFloat(deltaY) * 0.01
            currentRotation.y += CGFloat(deltaX) * 0.01

            // Clamp pitch to prevent flipping
            currentRotation.x = max(-1.5, min(1.5, currentRotation.x))

            voxelRenderer?.setCameraRotation(
                pitch: Float(currentRotation.x),
                yaw: Float(currentRotation.y)
            )

            lastPanTranslation = translation
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            currentDistance /= Float(gesture.scale)
            currentDistance = max(100, min(400, currentDistance))
            distanceSlider.value = currentDistance
            voxelRenderer?.setCameraDistance(currentDistance)
            gesture.scale = 1.0
        }
    }

    // MARK: - Helpers

    private func updateInfoLabel(for cube: VoxelGIFProcessor.VoxelCube) {
        let dimension = cube.dimension.rawValue
        let frameCount = cube.frames.count
        let voxelCount = cube.dimension.totalVoxels
        let sizeText = ByteCountFormatter.string(fromByteCount: cube.metadata.totalSize, countStyle: .binary)

        infoLabel.text = "📊 \(dimension)³ cube • \(frameCount) frames • \(voxelCount.formatted()) voxels • \(sizeText)"
    }

    private func updateFPSLabel() {
        // This would be updated with actual FPS from renderer
        let fps = 120 // Placeholder
        fpsLabel.text = "\(fps) FPS"

        // Color code based on performance
        if fps >= 100 {
            fpsLabel.textColor = .systemGreen
        } else if fps >= 60 {
            fpsLabel.textColor = .systemYellow
        } else {
            fpsLabel.textColor = .systemRed
        }
    }

    private func shareFile(at url: URL) {
        // Use NSItemProvider with proper UTI for GIF files
        let itemProvider = NSItemProvider()
        itemProvider.registerFileRepresentation(
            forTypeIdentifier: UTType.gif.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }

        let activityVC = UIActivityViewController(
            activityItems: [itemProvider],
            applicationActivities: nil
        )

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = exportButton
            popover.sourceRect = exportButton.bounds
        }

        present(activityVC, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Presentation

@available(iOS 26.0, *)
extension VoxelVisualizationViewController {

    /// Present voxel visualization modally
    public static func present(
        cube: VoxelGIFProcessor.VoxelCube,
        from viewController: UIViewController
    ) {
        let voxelVC = VoxelVisualizationViewController()
        voxelVC.loadVoxelCube(cube)
        voxelVC.modalPresentationStyle = .fullScreen
        voxelVC.modalTransitionStyle = .crossDissolve
        viewController.present(voxelVC, animated: true)
    }
}