//
//  VoxelRenderer.swift
//  RGB2GIF
//
//  Metal-powered 3D voxel renderer for temporal GIF cube visualization
//  Renders 80×80×80 or 128×128×128 voxel cubes with conveyor animation
//

import Foundation
import Metal
import MetalKit
import simd
import CoreGraphics
import os.log

private let voxelRenderLogger = Logger(subsystem: "com.rgb2gif", category: "VoxelRenderer")

/// Metal-powered 3D voxel renderer for GIF cube visualization
@available(iOS 26.0, *)
public final class VoxelRenderer: MTKView {

    // MARK: - Types

    /// Voxel instance data for GPU
    struct VoxelInstance {
        var position: SIMD3<Float>  // Position in voxel space
        var color: SIMD4<Float>     // RGBA color
        var scale: Float             // Scale factor for LOD
        var opacity: Float           // Opacity for fading
        var frameIndex: UInt32       // Which frame this voxel belongs to
        var padding: UInt32          // Alignment padding
    }

    /// Camera state for viewing
    struct CameraState {
        var viewMatrix: float4x4
        var projectionMatrix: float4x4
        var position: SIMD3<Float>
        var rotation: SIMD2<Float>  // Pitch and yaw
        var distance: Float
        var fov: Float

        init() {
            self.viewMatrix = float4x4.identity
            self.projectionMatrix = float4x4.identity
            self.position = SIMD3<Float>(0, 0, -200)
            self.rotation = SIMD2<Float>(0.3, 0.5)  // Slight angle for better view
            self.distance = 200.0
            self.fov = 65.0
        }
    }

    /// Animation state for conveyor effect
    struct AnimationState {
        var time: Double = 0
        var conveyorOffset: Float = 0
        var frameAdvanceSpeed: Float = 1.0  // Frames per second along Z
        var rotationSpeed: Float = 0.2      // Auto-rotation speed
        var pulsePhase: Float = 0            // For subtle pulsing effect
    }

    /// Render configuration
    public struct RenderConfig {
        var voxelSize: Float = 0.9          // Size of each voxel (0-1 of grid spacing)
        var voxelSpacing: Float = 1.0       // Grid spacing between voxels
        var fadeDistance: Float = 80.0      // Distance at which voxels fade
        var fadeRange: Float = 20.0         // Range over which fading occurs
        var ambientIntensity: Float = 0.3   // Ambient lighting
        var diffuseIntensity: Float = 0.7   // Diffuse lighting
        var specularIntensity: Float = 0.5  // Specular highlights
        var enableGlow: Bool = true         // Glow effect for voxels
        var enableShadows: Bool = false     // Simplified shadows (performance)
    }

    // MARK: - Properties

    // Metal resources
    private var commandQueue: MTLCommandQueue!
    private var renderPipelineState: MTLRenderPipelineState!
    private var depthStencilState: MTLDepthStencilState!
    private var instanceBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var textureArray: MTLTexture?

    // Voxel data
    private var voxelCube: VoxelGIFProcessor.VoxelCube?
    private var voxelInstances: [VoxelInstance] = []
    private var instanceCount: Int = 0

    // State
    private var camera = CameraState()
    private var animation = AnimationState()
    private var config = RenderConfig()

    // Performance monitoring
    private var frameCounter: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var averageFPS: Double = 0

    // Display link for ProMotion
    private var displayLink: CADisplayLink?
    private let targetFPS: Int = 120  // ProMotion target

    // iOS 26 Metal 4 feature detection
    private struct Metal4Features {
        let supportsRayTracing: Bool
        let supportsMeshShaders: Bool
        let supportsAsyncCompute: Bool

        init(device: MTLDevice) {
            if #available(iOS 26.0, *) {
                let isApple10 = device.supportsFamily(.apple10)
                self.supportsRayTracing = device.supportsRaytracing
                self.supportsMeshShaders = isApple10
                self.supportsAsyncCompute = isApple10
            } else {
                self.supportsRayTracing = false
                self.supportsMeshShaders = false
                self.supportsAsyncCompute = false
            }
        }
    }

    private var metal4Features: Metal4Features!
    private var supportsA19: Bool = false

    // MARK: - Initialization

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            voxelRenderLogger.error("Metal not available")
            return
        }

        self.device = device

        // iOS 26: Detect Metal 4 features on A19 Bionic
        self.metal4Features = Metal4Features(device: device)
        if #available(iOS 26.0, *) {
            self.supportsA19 = device.supportsFamily(.apple10)
            if supportsA19 {
                voxelRenderLogger.info("✅ VoxelRenderer: A19 Bionic detected with Metal 4 features")
                voxelRenderLogger.info("  Ray Tracing: \(self.metal4Features.supportsRayTracing ? "✅" : "❌")")
                voxelRenderLogger.info("  Mesh Shaders: \(self.metal4Features.supportsMeshShaders ? "✅" : "❌")")
            }
        }

        self.colorPixelFormat = .bgra8Unorm
        self.depthStencilPixelFormat = .depth32Float
        self.sampleCount = 1
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1.0)

        // Enable ProMotion (120Hz on iPhone 17 Pro)
        self.preferredFramesPerSecond = targetFPS
        self.isPaused = false
        self.enableSetNeedsDisplay = false

        setupMetal()
        setupDisplayLink()

        // Set delegate to self
        self.delegate = self

        voxelRenderLogger.info("VoxelRenderer initialized with Metal 4 support (iOS 26)")
    }

    // MARK: - Setup

    private func setupMetal() {
        guard let device = self.device else { return }

        // Create command queue
        commandQueue = device.makeCommandQueue()

        // Load shaders and create pipeline
        setupRenderPipeline()

        // Create depth stencil state
        setupDepthStencil()

        // Allocate buffers
        allocateBuffers()
    }

    private func setupRenderPipeline() {
        guard let device = self.device else { return }

        // Create shader library from embedded Metal code
        let shaderSource = getVoxelShaderSource()

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "voxelVertexShader")
            let fragmentFunction = library.makeFunction(name: "voxelFragmentShader")

            // Create pipeline descriptor
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = depthStencilPixelFormat

            // Enable blending for transparency
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        } catch {
            voxelRenderLogger.error("Failed to create render pipeline: \(error)")
        }
    }

    private func setupDepthStencil() {
        guard let device = self.device else { return }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
    }

    private func allocateBuffers() {
        guard let device = self.device else { return }

        // Allocate instance buffer for maximum voxels (128^3 = 2,097,152)
        let maxVoxels = 128 * 128 * 128
        let bufferSize = MemoryLayout<VoxelInstance>.stride * maxVoxels
        instanceBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)

        // Allocate uniform buffer
        let uniformSize = MemoryLayout<float4x4>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride * 4
        uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared)

        voxelRenderLogger.info("Allocated buffers: instances=\(bufferSize / 1024 / 1024)MB")
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback))
        displayLink?.add(to: .current, forMode: .default)

        // Set preferred frame rate for ProMotion (iPhone 17 Pro default)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 120,
            preferred: 120
        )
    }

    // MARK: - Public API

    /// Load voxel cube for rendering
    public func loadVoxelCube(_ cube: VoxelGIFProcessor.VoxelCube) {
        self.voxelCube = cube

        // Generate voxel instances
        generateVoxelInstances()

        // Create texture array from frames
        createTextureArray()

        voxelRenderLogger.info("Loaded voxel cube: \(cube.dimension.rawValue)³, \(cube.frames.count) frames")
    }

    /// Update render configuration
    public func updateConfig(_ config: RenderConfig) {
        self.config = config
    }

    /// Set camera rotation
    public func setCameraRotation(pitch: Float, yaw: Float) {
        camera.rotation = SIMD2<Float>(pitch, yaw)
        updateCameraMatrices()
    }

    /// Set camera distance
    public func setCameraDistance(_ distance: Float) {
        camera.distance = max(50, min(500, distance))
        updateCameraMatrices()
    }

    /// Set animation speed
    public func setAnimationSpeed(_ speed: Float) {
        animation.frameAdvanceSpeed = max(0, min(10, speed))
    }

    /// Pause/resume animation
    public func setPaused(_ paused: Bool) {
        self.isPaused = paused
    }

    // MARK: - Voxel Generation

    private func generateVoxelInstances() {
        guard let cube = voxelCube else { return }

        voxelInstances.removeAll()

        let dimension = cube.dimension.rawValue
        let halfDim = Float(dimension) / 2.0

        // Generate instances for each voxel
        for t in 0..<cube.frames.count {
            for y in 0..<dimension {
                for x in 0..<dimension {
                    if let color = cube.voxelAt(x: x, y: y, t: t) {
                        // Convert color to float4
                        let r = Float((color >> 24) & 0xFF) / 255.0
                        let g = Float((color >> 16) & 0xFF) / 255.0
                        let b = Float((color >> 8) & 0xFF) / 255.0
                        let a = Float(color & 0xFF) / 255.0

                        // Skip transparent voxels
                        if a < 0.01 { continue }

                        // Create instance
                        let instance = VoxelInstance(
                            position: SIMD3<Float>(
                                Float(x) - halfDim,
                                Float(y) - halfDim,
                                Float(t) * config.voxelSpacing
                            ),
                            color: SIMD4<Float>(r, g, b, a),
                            scale: config.voxelSize,
                            opacity: a,
                            frameIndex: UInt32(t),
                            padding: 0
                        )

                        voxelInstances.append(instance)
                    }
                }
            }
        }

        instanceCount = voxelInstances.count

        // Upload to GPU
        if let buffer = instanceBuffer {
            let pointer = buffer.contents().bindMemory(
                to: VoxelInstance.self,
                capacity: voxelInstances.count
            )
            pointer.update(from: voxelInstances, count: voxelInstances.count)
        }

        voxelRenderLogger.info("Generated \(self.instanceCount) voxel instances")
    }

    private func createTextureArray() {
        guard let device = self.device,
              let cube = voxelCube else { return }

        let dimension = cube.dimension.rawValue

        // Create texture descriptor for array
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2DArray
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.width = dimension
        textureDescriptor.height = dimension
        textureDescriptor.arrayLength = cube.frames.count
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared

        textureArray = device.makeTexture(descriptor: textureDescriptor)

        // Upload each frame to texture array
        for (index, frame) in cube.frames.enumerated() {
            uploadFrameToTexture(frame.image, slice: index)
        }

        voxelRenderLogger.info("Created texture array: \(dimension)×\(dimension)×\(cube.frames.count)")
    }

    private func uploadFrameToTexture(_ image: CGImage, slice: Int) {
        guard let texture = textureArray else { return }

        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        // Create bitmap context
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw image into context
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Upload to texture
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            slice: slice,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow,
            bytesPerImage: 0
        )
    }

    // MARK: - Camera

    private func updateCameraMatrices() {
        // Calculate view matrix
        let rotationMatrix = float4x4.rotation(
            pitch: camera.rotation.x,
            yaw: camera.rotation.y,
            roll: 0
        )

        let translationMatrix = float4x4.translation(
            x: 0,
            y: 0,
            z: -camera.distance
        )

        camera.viewMatrix = translationMatrix * rotationMatrix

        // Calculate projection matrix
        let aspect = Float(bounds.width / bounds.height)
        camera.projectionMatrix = float4x4.perspective(
            fovY: camera.fov * .pi / 180,
            aspect: aspect,
            near: 0.1,
            far: 1000.0
        )
    }

    // MARK: - Animation

    @objc private func displayLinkCallback() {
        // Update animation state
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime
        lastFrameTime = currentTime

        if !isPaused {
            updateAnimation(deltaTime: Float(deltaTime))
        }

        // Update FPS counter
        frameCounter += 1
        if frameCounter % 60 == 0 {
            averageFPS = 1.0 / deltaTime
        }
    }

    private func updateAnimation(deltaTime: Float) {
        // Update conveyor offset
        animation.conveyorOffset += animation.frameAdvanceSpeed * deltaTime

        // Wrap around when reaching the end
        if let cube = voxelCube {
            let maxOffset = Float(cube.frames.count) * config.voxelSpacing
            if animation.conveyorOffset > maxOffset {
                animation.conveyorOffset -= maxOffset
            }
        }

        // Update rotation
        animation.time += Double(deltaTime)
        camera.rotation.y += animation.rotationSpeed * deltaTime

        // Update pulse phase
        animation.pulsePhase += deltaTime * 2.0
        if animation.pulsePhase > .pi * 2 {
            animation.pulsePhase -= .pi * 2
        }

        // Update camera matrices
        updateCameraMatrices()

        // Update voxel fade based on distance
        updateVoxelFading()
    }

    private func updateVoxelFading() {
        // Update opacity based on Z distance for conveyor effect
        for i in 0..<instanceCount {
            let z = voxelInstances[i].position.z - animation.conveyorOffset

            // Calculate fade based on distance
            let fadeStart = config.fadeDistance
            let fadeEnd = fadeStart + config.fadeRange

            if z < fadeStart {
                voxelInstances[i].opacity = voxelInstances[i].color.w
            } else if z < fadeEnd {
                let fadeAmount = (z - fadeStart) / config.fadeRange
                voxelInstances[i].opacity = voxelInstances[i].color.w * (1.0 - fadeAmount)
            } else {
                voxelInstances[i].opacity = 0
            }

            // Apply pulse effect
            let pulse = 0.95 + 0.05 * sin(animation.pulsePhase)
            voxelInstances[i].scale = config.voxelSize * pulse
        }

        // Upload updated instances to GPU
        if let buffer = instanceBuffer {
            let pointer = buffer.contents().bindMemory(
                to: VoxelInstance.self,
                capacity: instanceCount
            )
            pointer.update(from: voxelInstances, count: instanceCount)
        }
    }

    // MARK: - Shader Source

    private func getVoxelShaderSource() -> String {
        // iOS 26 Metal 4: Include ray tracing and advanced lighting features
        let metal4Extensions = supportsA19 && metal4Features.supportsRayTracing ? """
        // Metal 4 Ray Tracing Extensions (iOS 26, A19 Bionic)
        #if __METAL_VERSION__ >= 270
        #define METAL4_RAY_TRACING_ENABLED 1
        #else
        #define METAL4_RAY_TRACING_ENABLED 0
        #endif
        """ : ""

        return """
        #include <metal_stdlib>
        using namespace metal;

        \(metal4Extensions)

        struct VoxelInstance {
            float3 position;
            float4 color;
            float scale;
            float opacity;
            uint frameIndex;
            uint padding;
        };

        struct Uniforms {
            float4x4 viewMatrix;
            float4x4 projectionMatrix;
            float4 lightPosition;
            float4 lightColor;
            float4 ambientColor;
            float4 config; // x: time, y: fadeDistance, z: fadeRange, w: metal4Features
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
            float3 normal;
            float3 worldPos;
            float opacity;
        };

        // Cube vertices for voxel
        constant float3 cubeVertices[] = {
            // Front face
            {-0.5, -0.5,  0.5}, { 0.5, -0.5,  0.5}, { 0.5,  0.5,  0.5}, {-0.5,  0.5,  0.5},
            // Back face
            {-0.5, -0.5, -0.5}, { 0.5, -0.5, -0.5}, { 0.5,  0.5, -0.5}, {-0.5,  0.5, -0.5}
        };

        constant uint cubeIndices[] = {
            0,1,2, 2,3,0,  // Front
            4,6,5, 6,4,7,  // Back
            0,4,5, 5,1,0,  // Bottom
            2,3,7, 7,6,2,  // Top
            0,3,7, 7,4,0,  // Left
            1,5,6, 6,2,1   // Right
        };

        vertex VertexOut voxelVertexShader(
            uint vertexID [[vertex_id]],
            uint instanceID [[instance_id]],
            constant VoxelInstance* instances [[buffer(0)]],
            constant Uniforms& uniforms [[buffer(1)]]
        ) {
            // Get instance data
            VoxelInstance instance = instances[instanceID];

            // Calculate vertex position
            uint triangleIndex = vertexID / 3;
            uint vertexInTriangle = vertexID % 3;
            uint index = cubeIndices[vertexID];
            float3 vertex = cubeVertices[index % 8];

            // Scale and position vertex
            float3 worldPos = vertex * instance.scale + instance.position;

            // Apply conveyor offset
            worldPos.z -= uniforms.config.x;

            // Transform to clip space
            float4 viewPos = uniforms.viewMatrix * float4(worldPos, 1.0);
            float4 clipPos = uniforms.projectionMatrix * viewPos;

            // Calculate normal (simplified for cube)
            float3 normal = normalize(vertex);

            VertexOut out;
            out.position = clipPos;
            out.color = instance.color;
            out.normal = normal;
            out.worldPos = worldPos;
            out.opacity = instance.opacity;

            return out;
        }

        fragment float4 voxelFragmentShader(
            VertexOut in [[stage_in]],
            constant Uniforms& uniforms [[buffer(1)]]
        ) {
            // iOS 26 Metal 4: Enhanced lighting with optional ray-traced ambient occlusion
            float3 lightDir = normalize(uniforms.lightPosition.xyz - in.worldPos);
            float diffuse = max(dot(in.normal, lightDir), 0.0);

            // Combine lighting
            float3 ambient = uniforms.ambientColor.rgb * in.color.rgb;
            float3 diffuseColor = uniforms.lightColor.rgb * in.color.rgb * diffuse;

            #if METAL4_RAY_TRACING_ENABLED
            // iOS 26 A19 Bionic: Use hardware ray tracing for enhanced ambient occlusion
            // This provides more realistic shadowing between voxels
            float ao = 1.0; // Placeholder for ray-traced AO
            // Future: Implement actual ray-traced AO for A19 Bionic
            float3 finalColor = (ambient + diffuseColor) * ao;
            #else
            // Standard lighting without ray tracing
            float3 finalColor = ambient + diffuseColor;
            #endif

            // iOS 26: Enhanced glow effect for A19 Bionic
            bool metal4Enabled = uniforms.config.w > 0.5;
            if (metal4Enabled) {
                // Subtle emissive glow on voxels for depth perception
                float3 emissive = in.color.rgb * 0.1 * smoothstep(0.7, 1.0, in.color.a);
                finalColor += emissive;
            }

            // Apply opacity with fade
            float alpha = in.color.a * in.opacity;

            return float4(finalColor, alpha);
        }
        """
    }
}

// MARK: - MTKViewDelegate

@available(iOS 26.0, *)
extension VoxelRenderer: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateCameraMatrices()
    }

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              instanceCount > 0 else { return }

        // Set pipeline state
        encoder.setRenderPipelineState(renderPipelineState)
        encoder.setDepthStencilState(depthStencilState)

        // Set buffers
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)

        // Set uniforms
        updateUniforms()
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)

        // Draw instanced voxels
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 36, // 6 faces * 2 triangles * 3 vertices
            instanceCount: instanceCount
        )

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateUniforms() {
        guard let buffer = uniformBuffer else { return }

        let pointer = buffer.contents()

        // Write matrices
        var matrices = [camera.viewMatrix, camera.projectionMatrix]
        memcpy(pointer, &matrices, MemoryLayout<float4x4>.stride * 2)

        // Write light data
        var lightPosition = SIMD4<Float>(100, 100, -100, 1)
        var lightColor = SIMD4<Float>(1, 1, 1, 1)
        var ambientColor = SIMD4<Float>(
            config.ambientIntensity,
            config.ambientIntensity,
            config.ambientIntensity,
            1
        )
        // iOS 26: Pass Metal 4 feature availability to shader
        let metal4FeaturesEnabled = metal4Features.supportsRayTracing || metal4Features.supportsMeshShaders ? Float(1.0) : Float(0.0)

        var configData = SIMD4<Float>(
            animation.conveyorOffset,
            config.fadeDistance,
            config.fadeRange,
            metal4FeaturesEnabled
        )

        memcpy(pointer.advanced(by: MemoryLayout<float4x4>.stride * 2),
               &lightPosition, MemoryLayout<SIMD4<Float>>.stride)
        memcpy(pointer.advanced(by: MemoryLayout<float4x4>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride),
               &lightColor, MemoryLayout<SIMD4<Float>>.stride)
        memcpy(pointer.advanced(by: MemoryLayout<float4x4>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride * 2),
               &ambientColor, MemoryLayout<SIMD4<Float>>.stride)
        memcpy(pointer.advanced(by: MemoryLayout<float4x4>.stride * 2 + MemoryLayout<SIMD4<Float>>.stride * 3),
               &configData, MemoryLayout<SIMD4<Float>>.stride)
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    static var identity: float4x4 {
        return float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func translation(x: Float, y: Float, z: Float) -> float4x4 {
        return float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1)
        )
    }

    static func rotation(pitch: Float, yaw: Float, roll: Float) -> float4x4 {
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let cosRoll = cos(roll)
        let sinRoll = sin(roll)

        let pitchMatrix = float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cosPitch, sinPitch, 0),
            SIMD4<Float>(0, -sinPitch, cosPitch, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let yawMatrix = float4x4(
            SIMD4<Float>(cosYaw, 0, -sinYaw, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sinYaw, 0, cosYaw, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let rollMatrix = float4x4(
            SIMD4<Float>(cosRoll, sinRoll, 0, 0),
            SIMD4<Float>(-sinRoll, cosRoll, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        return yawMatrix * pitchMatrix * rollMatrix
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (far - near)
        let w = -near * z

        return float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, 1),
            SIMD4<Float>(0, 0, w, 0)
        )
    }
}
