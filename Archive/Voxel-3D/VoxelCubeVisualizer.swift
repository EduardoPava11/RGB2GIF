//
//  VoxelCubeVisualizer.swift
//  RGB2GIF
//
//  Interactive 3D voxel cube visualization for GIF preview
//

import Foundation
import SceneKit
import UIKit

@available(iOS 26.0, *)
public class VoxelCubeVisualizer {

    // MARK: - Configuration

    public struct VisualizationConfig {
        public let dimension: Int
        public let voxelSize: Float
        public let spacing: Float
        public let samplingStride: Int  // Show every Nth voxel for performance

        public static func optimized(dimension: Int) -> VisualizationConfig {
            // For 128³, show every 4th voxel = 32³ = 32,768 cubes (reasonable)
            // For 80³, show every 2nd voxel = 40³ = 64,000 cubes
            let stride = dimension == 128 ? 4 : 2
            let voxelSize: Float = dimension == 128 ? 0.005 : 0.008

            return VisualizationConfig(
                dimension: dimension,
                voxelSize: voxelSize,
                spacing: 0.001,
                samplingStride: stride
            )
        }
    }

    // MARK: - Scene Creation

    public func createScene(from separatedGIF: PaletteSeparator.SeparatedGIF,
                           config: VisualizationConfig = .optimized(dimension: 128)) -> SCNScene {
        let scene = SCNScene()

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 2)
        scene.rootNode.addChildNode(cameraNode)

        // Light
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.position = SCNVector3(x: 0, y: 10, z: 10)
        scene.rootNode.addChildNode(lightNode)

        // Ambient light
        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = UIColor.darkGray
        scene.rootNode.addChildNode(ambientNode)

        // Create voxel cube
        let cubeNode = createVoxelCube(from: separatedGIF, config: config)
        scene.rootNode.addChildNode(cubeNode)

        return scene
    }

    private func createVoxelCube(from separatedGIF: PaletteSeparator.SeparatedGIF,
                                 config: VisualizationConfig) -> SCNNode {
        let containerNode = SCNNode()

        let samplingStride = config.samplingStride
        let voxelSize = config.voxelSize
        let spacing = config.spacing

        let dimension = separatedGIF.width
        let frameCount = separatedGIF.frameCount

        // Center the cube
        let offset = Float(dimension) * (voxelSize + spacing) / 2.0

        // Create voxel geometry (reuse for performance)
        let box = SCNBox(width: CGFloat(voxelSize),
                        height: CGFloat(voxelSize),
                        length: CGFloat(voxelSize),
                        chamferRadius: 0)

        var voxelCount = 0

        // Iterate through frames (Z axis)
        for z in stride(from: 0, to: frameCount, by: samplingStride) {
            let indexMap = separatedGIF.indexMaps[z]
            let palette = separatedGIF.palettes[z]

            indexMap.withUnsafeBytes { indexPtr in
                let indices = indexPtr.bindMemory(to: UInt8.self)

                // Iterate through pixels (X, Y)
                for y in stride(from: 0, to: dimension, by: samplingStride) {
                    for x in stride(from: 0, to: dimension, by: samplingStride) {
                        let index = y * dimension + x
                        let paletteIndex = Int(indices[index])

                        // Get color from palette
                        let color = palette.colors[min(paletteIndex, 255)]
                        let r = CGFloat(color[0]) / 255.0
                        let g = CGFloat(color[1]) / 255.0
                        let b = CGFloat(color[2]) / 255.0
                        let a = CGFloat(color[3]) / 255.0

                        // Skip transparent voxels for performance
                        guard a > 0.1 else { continue }

                        // Create voxel
                        let voxelNode = SCNNode(geometry: box)
                        voxelNode.geometry?.firstMaterial?.diffuse.contents = UIColor(
                            red: r, green: g, blue: b, alpha: a
                        )

                        // Position
                        let posX = Float(x) * (voxelSize + spacing) - offset
                        let posY = Float(y) * (voxelSize + spacing) - offset
                        let posZ = Float(z) * (voxelSize + spacing) - offset

                        voxelNode.position = SCNVector3(posX, posY, posZ)
                        containerNode.addChildNode(voxelNode)

                        voxelCount += 1
                    }
                }
            }
        }

        print("Created voxel cube with \(voxelCount) voxels")

        return containerNode
    }

    // MARK: - Animation

    public func addRotationAnimation(to node: SCNNode, duration: TimeInterval = 20.0) {
        let rotation = CABasicAnimation(keyPath: "rotation")
        rotation.toValue = NSValue(scnVector4: SCNVector4(x: 0, y: 1, z: 0, w: Float.pi * 2))
        rotation.duration = duration
        rotation.repeatCount = .infinity
        node.addAnimation(rotation, forKey: "rotation")
    }

    // MARK: - Slice View

    public func createSliceView(from separatedGIF: PaletteSeparator.SeparatedGIF,
                               sliceIndex: Int,
                               axis: SliceAxis) -> UIImage? {
        let dimension = separatedGIF.width

        guard sliceIndex >= 0 && sliceIndex < dimension else { return nil }

        let size = CGSize(width: dimension, height: dimension)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let ctx = context.cgContext

            switch axis {
            case .z:  // XY plane (frame view)
                guard sliceIndex < separatedGIF.frameCount else { return }
                let indexMap = separatedGIF.indexMaps[sliceIndex]
                let palette = separatedGIF.palettes[sliceIndex]

                drawSlice(ctx: ctx, indexMap: indexMap, palette: palette,
                         width: dimension, height: dimension)

            case .y:  // XZ plane
                for z in 0..<separatedGIF.frameCount {
                    let indexMap = separatedGIF.indexMaps[z]
                    let palette = separatedGIF.palettes[z]

                    indexMap.withUnsafeBytes { indexPtr in
                        let indices = indexPtr.bindMemory(to: UInt8.self)

                        for x in 0..<dimension {
                            let index = sliceIndex * dimension + x
                            let paletteIndex = Int(indices[index])
                            let color = palette.colors[min(paletteIndex, 255)]

                            let rect = CGRect(x: x, y: z, width: 1, height: 1)
                            ctx.setFillColor(UIColor(
                                red: CGFloat(color[0]) / 255.0,
                                green: CGFloat(color[1]) / 255.0,
                                blue: CGFloat(color[2]) / 255.0,
                                alpha: CGFloat(color[3]) / 255.0
                            ).cgColor)
                            ctx.fill(rect)
                        }
                    }
                }

            case .x:  // YZ plane
                for z in 0..<separatedGIF.frameCount {
                    let indexMap = separatedGIF.indexMaps[z]
                    let palette = separatedGIF.palettes[z]

                    indexMap.withUnsafeBytes { indexPtr in
                        let indices = indexPtr.bindMemory(to: UInt8.self)

                        for y in 0..<dimension {
                            let index = y * dimension + sliceIndex
                            let paletteIndex = Int(indices[index])
                            let color = palette.colors[min(paletteIndex, 255)]

                            let rect = CGRect(x: y, y: z, width: 1, height: 1)
                            ctx.setFillColor(UIColor(
                                red: CGFloat(color[0]) / 255.0,
                                green: CGFloat(color[1]) / 255.0,
                                blue: CGFloat(color[2]) / 255.0,
                                alpha: CGFloat(color[3]) / 255.0
                            ).cgColor)
                            ctx.fill(rect)
                        }
                    }
                }
            }
        }
    }

    private func drawSlice(ctx: CGContext, indexMap: Data,
                          palette: PaletteSeparator.ColorPalette,
                          width: Int, height: Int) {
        indexMap.withUnsafeBytes { indexPtr in
            let indices = indexPtr.bindMemory(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let paletteIndex = Int(indices[index])
                    let color = palette.colors[min(paletteIndex, 255)]

                    let rect = CGRect(x: x, y: y, width: 1, height: 1)
                    ctx.setFillColor(UIColor(
                        red: CGFloat(color[0]) / 255.0,
                        green: CGFloat(color[1]) / 255.0,
                        blue: CGFloat(color[2]) / 255.0,
                        alpha: CGFloat(color[3]) / 255.0
                    ).cgColor)
                    ctx.fill(rect)
                }
            }
        }
    }

    public enum SliceAxis {
        case x  // YZ plane
        case y  // XZ plane
        case z  // XY plane (frames)
    }
}

// MARK: - Interactive View Controller

@available(iOS 26.0, *)
public class VoxelCubeViewController: UIViewController {

    private let separatedGIF: PaletteSeparator.SeparatedGIF
    private let visualizer = VoxelCubeVisualizer()
    private var scnView: SCNView!

    public init(separatedGIF: PaletteSeparator.SeparatedGIF) {
        self.separatedGIF = separatedGIF
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Create SCNView
        scnView = SCNView(frame: view.bounds)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.allowsCameraControl = true
        scnView.showsStatistics = true
        scnView.backgroundColor = .black
        view.addSubview(scnView)

        // Load scene
        let config = VoxelCubeVisualizer.VisualizationConfig.optimized(dimension: separatedGIF.width)
        let scene = visualizer.createScene(from: separatedGIF, config: config)
        scnView.scene = scene

        // Add rotation animation
        if let cubeNode = scene.rootNode.childNodes.last {
            visualizer.addRotationAnimation(to: cubeNode, duration: 30.0)
        }

        // Add controls
        setupControls()
    }

    private func setupControls() {
        // Slice viewer button
        let sliceButton = UIButton(type: .system)
        sliceButton.setTitle("View Slices", for: .normal)
        sliceButton.backgroundColor = .systemBlue
        sliceButton.setTitleColor(.white, for: .normal)
        sliceButton.layer.cornerRadius = 8
        sliceButton.frame = CGRect(x: 20, y: view.bounds.height - 70, width: 120, height: 44)
        sliceButton.addTarget(self, action: #selector(showSliceViewer), for: .touchUpInside)
        view.addSubview(sliceButton)

        // Info label
        let infoLabel = UILabel(frame: CGRect(x: 20, y: 50, width: view.bounds.width - 40, height: 80))
        infoLabel.numberOfLines = 0
        infoLabel.textColor = .white
        infoLabel.font = .systemFont(ofSize: 14)
        infoLabel.text = """
        Dimension: \(separatedGIF.width)×\(separatedGIF.height)×\(separatedGIF.frameCount)
        Frames: \(separatedGIF.frameCount)
        Compression: \(String(format: "%.1fx", separatedGIF.compressionRatio))
        Pinch to zoom • Drag to rotate
        """
        view.addSubview(infoLabel)
    }

    @objc private func showSliceViewer() {
        let sliceVC = SliceViewerViewController(separatedGIF: separatedGIF, visualizer: visualizer)
        let navController = UINavigationController(rootViewController: sliceVC)
        present(navController, animated: true)
    }
}

@available(iOS 26.0, *)
class SliceViewerViewController: UIViewController {
    private let separatedGIF: PaletteSeparator.SeparatedGIF
    private let visualizer: VoxelCubeVisualizer
    private var imageView: UIImageView!
    private var slider: UISlider!
    private var axisSegment: UISegmentedControl!

    init(separatedGIF: PaletteSeparator.SeparatedGIF, visualizer: VoxelCubeVisualizer) {
        self.separatedGIF = separatedGIF
        self.visualizer = visualizer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Slice Viewer"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismiss(_:))
        )

        setupUI()
        updateSlice()
    }

    private func setupUI() {
        // Image view
        imageView = UIImageView(frame: CGRect(
            x: 20,
            y: 100,
            width: view.bounds.width - 40,
            height: view.bounds.width - 40
        ))
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .darkGray
        view.addSubview(imageView)

        // Axis selector
        axisSegment = UISegmentedControl(items: ["Z (Frames)", "Y", "X"])
        axisSegment.selectedSegmentIndex = 0
        axisSegment.frame = CGRect(
            x: 20,
            y: imageView.frame.maxY + 20,
            width: view.bounds.width - 40,
            height: 32
        )
        axisSegment.addTarget(self, action: #selector(axisChanged), for: .valueChanged)
        view.addSubview(axisSegment)

        // Slider
        slider = UISlider(frame: CGRect(
            x: 20,
            y: axisSegment.frame.maxY + 20,
            width: view.bounds.width - 40,
            height: 32
        ))
        slider.minimumValue = 0
        slider.maximumValue = Float(separatedGIF.frameCount - 1)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        view.addSubview(slider)
    }

    @objc private func axisChanged() {
        updateSlice()
    }

    @objc private func sliderChanged() {
        updateSlice()
    }

    private func updateSlice() {
        let sliceIndex = Int(slider.value)
        let axis: VoxelCubeVisualizer.SliceAxis

        switch axisSegment.selectedSegmentIndex {
        case 0: axis = .z
        case 1: axis = .y
        case 2: axis = .x
        default: axis = .z
        }

        if let image = visualizer.createSliceView(
            from: separatedGIF,
            sliceIndex: sliceIndex,
            axis: axis
        ) {
            imageView.image = image
        }
    }

    @objc private func dismiss(_ sender: Any) {
        dismiss(animated: true)
    }
}