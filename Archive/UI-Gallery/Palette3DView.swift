//
//  Palette3DView.swift
//  RGB2GIF
//
//  3D palette visualization using Metal for temporal color analysis
//

import SwiftUI
import MetalKit
import simd
import os.log
import UIKit

private let palette3DLogger = Logger(subsystem: "com.rgb2gif", category: "Palette3D")

// MARK: - 3D Palette View

@available(iOS 26.0, *)
struct Palette3DView: UIViewRepresentable {
    let palettes: [[Color]]
    @Binding var currentFrame: Int

    func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.device = MTLCreateSystemDefaultDevice()
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60
        metalView.backgroundColor = .clear

        context.coordinator.setup(metalView: metalView, palettes: palettes)
        return metalView
    }

    func updateUIView(_ metalView: MTKView, context: Context) {
        context.coordinator.updateCurrentFrame(currentFrame)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        private var renderer: Palette3DRenderer?
        private var metalView: MTKView?

        func setup(metalView: MTKView, palettes: [[Color]]) {
            self.metalView = metalView
            guard let device = metalView.device else { return }

            renderer = Palette3DRenderer(device: device, palettes: palettes)
            metalView.delegate = self
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.depthStencilPixelFormat = .depth32Float
            metalView.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1.0)
        }

        func updateCurrentFrame(_ frame: Int) {
            renderer?.currentFrame = frame
        }

        // MARK: - MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.updateProjection(for: size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}

// MARK: - 3D Renderer

@available(iOS 26.0, *)
class Palette3DRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var paletteTexture: MTLTexture!
    private var vertexBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var rotation: Float = 0
    private var cameraDistance: Float = 3.0

    var currentFrame: Int = 0
    private let palettes: [[Color]]
    private let gridSize = 16

    struct Uniforms {
        var modelMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var projectionMatrix: matrix_float4x4
        var currentFrame: Int32
        var totalFrames: Int32
        var padding: simd_float2 = .zero
    }

    struct Vertex {
        var position: simd_float3
        var texCoord: simd_float2
        var paletteIndex: Int32
    }

    init(device: MTLDevice, palettes: [[Color]]) {
        self.device = device
        self.palettes = palettes
        self.commandQueue = device.makeCommandQueue()!

        setupPipeline()
        setupBuffers()
        setupTextures()
    }

    private func setupPipeline() {
        // Create shader library from source
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Vertex {
            float3 position [[attribute(0)]];
            float2 texCoord [[attribute(1)]];
            int paletteIndex [[attribute(2)]];
        };

        struct Uniforms {
            float4x4 modelMatrix;
            float4x4 viewMatrix;
            float4x4 projectionMatrix;
            int currentFrame;
            int totalFrames;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
            int paletteIndex;
            float depth;
        };

        vertex VertexOut vertexShader(Vertex in [[stage_in]],
                                      constant Uniforms& uniforms [[buffer(1)]]) {
            VertexOut out;
            float4x4 mvp = uniforms.projectionMatrix * uniforms.viewMatrix * uniforms.modelMatrix;
            out.position = mvp * float4(in.position, 1.0);
            out.texCoord = in.texCoord;
            out.paletteIndex = in.paletteIndex;

            // Calculate depth for transparency sorting
            float4 viewPos = uniforms.viewMatrix * uniforms.modelMatrix * float4(in.position, 1.0);
            out.depth = viewPos.z;

            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d_array<float> paletteTexture [[texture(0)]],
                                       sampler paletteSampler [[sampler(0)]],
                                       constant Uniforms& uniforms [[buffer(1)]]) {
            // Sample from the 2D texture array (each slice is a frame's palette)
            float3 color = paletteTexture.sample(paletteSampler, in.texCoord, uniforms.currentFrame).rgb;

            // Add depth-based alpha for 3D effect
            float alpha = 0.8 + 0.2 * (1.0 - saturate(in.depth / 10.0));

            return float4(color, alpha);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "vertexShader")
            let fragmentFunction = library.makeFunction(name: "fragmentShader")

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            // Enable alpha blending
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

            // Create depth stencil state
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        } catch {
            palette3DLogger.error("Failed to setup pipeline: \(error)")
        }
    }

    private func setupBuffers() {
        // Create vertices for a 16x16xF cube structure
        var vertices: [Vertex] = []

        // Create layers for temporal depth (one per frame)
        let layerCount = min(palettes.count, 32) // Limit for performance
        let layerSpacing: Float = 0.1

        for layer in 0..<layerCount {
            let z = Float(layer) * layerSpacing

            // Create 16x16 grid for this layer
            for row in 0..<gridSize {
                for col in 0..<gridSize {
                    let x = Float(col - gridSize/2) * 0.1
                    let y = Float(row - gridSize/2) * 0.1
                    let paletteIndex = row * gridSize + col

                    // Create a small cube for each palette entry
                    let size: Float = 0.08

                    // Front face
                    vertices.append(Vertex(position: simd_float3(x - size/2, y - size/2, z),
                                         texCoord: simd_float2(Float(col)/16, Float(row)/16),
                                         paletteIndex: Int32(paletteIndex)))
                    vertices.append(Vertex(position: simd_float3(x + size/2, y - size/2, z),
                                         texCoord: simd_float2(Float(col+1)/16, Float(row)/16),
                                         paletteIndex: Int32(paletteIndex)))
                    vertices.append(Vertex(position: simd_float3(x + size/2, y + size/2, z),
                                         texCoord: simd_float2(Float(col+1)/16, Float(row+1)/16),
                                         paletteIndex: Int32(paletteIndex)))
                    vertices.append(Vertex(position: simd_float3(x - size/2, y + size/2, z),
                                         texCoord: simd_float2(Float(col)/16, Float(row+1)/16),
                                         paletteIndex: Int32(paletteIndex)))
                }
            }
        }

        vertexBuffer = device.makeBuffer(bytes: vertices,
                                        length: vertices.count * MemoryLayout<Vertex>.stride)

        // Create uniform buffer
        var uniforms = Uniforms(
            modelMatrix: matrix_identity_float4x4,
            viewMatrix: matrix_identity_float4x4,
            projectionMatrix: matrix_identity_float4x4,
            currentFrame: 0,
            totalFrames: Int32(palettes.count)
        )

        uniformBuffer = device.makeBuffer(bytes: &uniforms,
                                         length: MemoryLayout<Uniforms>.stride,
                                         options: [])
    }

    private func setupTextures() {
        // Create 2D texture array for palettes
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2DArray
        textureDescriptor.pixelFormat = .rgba8Unorm
        textureDescriptor.width = gridSize
        textureDescriptor.height = gridSize
        textureDescriptor.arrayLength = palettes.count
        textureDescriptor.usage = [.shaderRead]

        paletteTexture = device.makeTexture(descriptor: textureDescriptor)

        // Upload palette data
        for (frameIndex, palette) in palettes.enumerated() {
            var pixels = [UInt32](repeating: 0, count: gridSize * gridSize)

            for (index, color) in palette.enumerated() {
                if index < pixels.count {
                    // Convert SwiftUI Color to RGBA8
                    let uiColor = UIColor(color)
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

                    let red = UInt32(r * 255) & 0xFF
                    let green = UInt32(g * 255) & 0xFF
                    let blue = UInt32(b * 255) & 0xFF
                    let alpha = UInt32(a * 255) & 0xFF

                    pixels[index] = (alpha << 24) | (blue << 16) | (green << 8) | red
                }
            }

            pixels.withUnsafeBytes { ptr in
                paletteTexture.replace(
                    region: MTLRegionMake2D(0, 0, gridSize, gridSize),
                    mipmapLevel: 0,
                    slice: frameIndex,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: gridSize * 4,
                    bytesPerImage: 0
                )
            }
        }
    }

    func updateProjection(for size: CGSize) {
        let aspect = Float(size.width / size.height)
        let fovRadians = Float.pi / 4
        let near: Float = 0.1
        let far: Float = 100.0

        // Create perspective projection matrix
        let projectionMatrix = matrix_perspective_projection(
            fov: fovRadians,
            aspect: aspect,
            near: near,
            far: far
        )

        // Update uniform buffer
        updateUniforms(projectionMatrix: projectionMatrix)
    }

    private func updateUniforms(projectionMatrix: matrix_float4x4? = nil) {
        rotation += 0.01

        // Create rotation matrix
        let modelMatrix = matrix_rotation(angle: rotation, axis: simd_float3(0, 1, 0))

        // Create view matrix (camera looking at origin)
        let eye = simd_float3(0, 0, cameraDistance)
        let center = simd_float3(0, 0, 0)
        let up = simd_float3(0, 1, 0)
        let viewMatrix = matrix_look_at(eye: eye, center: center, up: up)

        // Update uniforms
        var uniforms = Uniforms(
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix ?? matrix_identity_float4x4,
            currentFrame: Int32(currentFrame),
            totalFrames: Int32(palettes.count)
        )

        uniformBuffer.contents().copyMemory(from: &uniforms,
                                           byteCount: MemoryLayout<Uniforms>.stride)
    }

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        updateUniforms()

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(paletteTexture, index: 0)

        // Draw with quads
        let vertexCount = (vertexBuffer.length / MemoryLayout<Vertex>.stride)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)

        encoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }
}

// MARK: - Matrix Helpers

func matrix_perspective_projection(fov: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
    let yScale = 1 / tan(fov * 0.5)
    let xScale = yScale / aspect
    let zRange = far - near
    let zScale = -(far + near) / zRange
    let wzScale = -2 * far * near / zRange

    return matrix_float4x4(columns: (
        simd_float4(xScale, 0, 0, 0),
        simd_float4(0, yScale, 0, 0),
        simd_float4(0, 0, zScale, -1),
        simd_float4(0, 0, wzScale, 0)
    ))
}

func matrix_look_at(eye: simd_float3, center: simd_float3, up: simd_float3) -> matrix_float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)

    return matrix_float4x4(columns: (
        simd_float4(x.x, y.x, z.x, 0),
        simd_float4(x.y, y.y, z.y, 0),
        simd_float4(x.z, y.z, z.z, 0),
        simd_float4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    ))
}

func matrix_rotation(angle: Float, axis: simd_float3) -> matrix_float4x4 {
    let normalizedAxis = normalize(axis)
    let ct = cos(angle)
    let st = sin(angle)
    let ci = 1 - ct
    let x = normalizedAxis.x
    let y = normalizedAxis.y
    let z = normalizedAxis.z

    return matrix_float4x4(columns: (
        simd_float4(ct + x * x * ci, x * y * ci - z * st, x * z * ci + y * st, 0),
        simd_float4(y * x * ci + z * st, ct + y * y * ci, y * z * ci - x * st, 0),
        simd_float4(z * x * ci - y * st, z * y * ci + x * st, ct + z * z * ci, 0),
        simd_float4(0, 0, 0, 1)
    ))
}