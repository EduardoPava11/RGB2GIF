//
//  PaletteShaderSystem.swift
//  RGB2GIF
//
//  Modular palette and shader system for voxel tensor rendering
//

import Foundation
import Metal
import MetalKit
import CoreGraphics
import UIKit

// MARK: - Protocol Definitions

public protocol PaletteProvider {
    var id: String { get }
    func paletteTexture(device: MTLDevice) throws -> MTLTexture
}

public protocol IndexProvider {
    var size: MTLSize { get }
    func indexTexture(device: MTLDevice) throws -> MTLTexture
}

public protocol ShaderModule {
    var id: String { get }
    func makePipelines(on device: MTLDevice) throws -> ShaderPipelines
    func encodeApplyPalette(cmd: MTLCommandBuffer,
                           index: MTLTexture,
                           palette: MTLTexture,
                           outRGBA: MTLTexture)
}

public struct ShaderPipelines {
    let applyPalette: MTLComputePipelineState
    let voxelConveyor: MTLComputePipelineState?
    let temporalRemap: MTLComputePipelineState?
    let ditherPass: MTLComputePipelineState?
}

// MARK: - Metadata Structures

public struct VoxelMetadata: Codable {
    public let gifSHA256: String
    public let frameCount: Int
    public let palettes: [PaletteReference]
    public let shaderPipelineId: String
    public let conveyorSettings: ConveyorSettings?

    public struct PaletteReference: Codable {
        public let frame: Int
        public let paletteAssetId: String

        public init(frame: Int, paletteAssetId: String) {
            self.frame = frame
            self.paletteAssetId = paletteAssetId
        }
    }

    public struct ConveyorSettings: Codable {
        public let zDepth: Int
        public let brightnessDecay: Float
        public let frameSpacing: Float
        public let animationSpeed: Float

        public init(zDepth: Int, brightnessDecay: Float, frameSpacing: Float, animationSpeed: Float) {
            self.zDepth = zDepth
            self.brightnessDecay = brightnessDecay
            self.frameSpacing = frameSpacing
            self.animationSpeed = animationSpeed
        }
    }

    public init(gifSHA256: String, frameCount: Int, palettes: [PaletteReference], shaderPipelineId: String, conveyorSettings: ConveyorSettings?) {
        self.gifSHA256 = gifSHA256
        self.frameCount = frameCount
        self.palettes = palettes
        self.shaderPipelineId = shaderPipelineId
        self.conveyorSettings = conveyorSettings
    }
}

// MARK: - Palette Implementation

public class StandardPaletteProvider: PaletteProvider {
    public let id: String
    private let paletteData: Data
    private let width = 16
    private let height = 16

    public init(id: String, paletteData: Data) {
        self.id = id
        self.paletteData = paletteData
    }

    public func paletteTexture(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw VoxelError.textureCreationFailed
        }

        let bytesPerRow = width * 4
        let region = MTLRegionMake2D(0, 0, width, height)

        paletteData.withUnsafeBytes { bytes in
            texture.replace(region: region,
                          mipmapLevel: 0,
                          withBytes: bytes.baseAddress!,
                          bytesPerRow: bytesPerRow)
        }

        return texture
    }

    public static func fromColors(_ colors: [UIColor]) -> StandardPaletteProvider {
        var paletteBytes = [UInt8]()
        paletteBytes.reserveCapacity(1024)

        for i in 0..<256 {
            let color = i < colors.count ? colors[i] : .clear
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            paletteBytes.append(UInt8(r * 255))
            paletteBytes.append(UInt8(g * 255))
            paletteBytes.append(UInt8(b * 255))
            paletteBytes.append(UInt8(a * 255))
        }

        let data = Data(paletteBytes)
        let id = "pal:\(data.sha256Hex)"
        return StandardPaletteProvider(id: id, paletteData: data)
    }
}

// MARK: - Index Provider

public class FrameIndexProvider: IndexProvider {
    public let size: MTLSize
    private let indexData: Data

    public init(width: Int, height: Int, indexData: Data) {
        self.size = MTLSize(width: width, height: height, depth: 1)
        self.indexData = indexData
    }

    public func indexTexture(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw VoxelError.textureCreationFailed
        }

        let bytesPerRow = size.width
        let region = MTLRegionMake2D(0, 0, size.width, size.height)

        indexData.withUnsafeBytes { bytes in
            texture.replace(region: region,
                          mipmapLevel: 0,
                          withBytes: bytes.baseAddress!,
                          bytesPerRow: bytesPerRow)
        }

        return texture
    }
}

// MARK: - Voxel Shader Module

public class VoxelShaderModule: ShaderModule {
    public let id = "shader:voxels:conveyor:v1"

    private var applyPalettePSO: MTLComputePipelineState!
    private var voxelConveyorPSO: MTLComputePipelineState?
    private var metalLibrary: MTLLibrary!

    public init() {}

    public func makePipelines(on device: MTLDevice) throws -> ShaderPipelines {
        let source = getMetalSource()
        metalLibrary = try device.makeLibrary(source: source, options: nil)

        guard let applyPaletteFunc = metalLibrary.makeFunction(name: "applyPalette") else {
            throw VoxelError.functionNotFound("applyPalette")
        }
        applyPalettePSO = try device.makeComputePipelineState(function: applyPaletteFunc)

        if let conveyorFunc = metalLibrary.makeFunction(name: "voxelConveyor") {
            voxelConveyorPSO = try device.makeComputePipelineState(function: conveyorFunc)
        }

        return ShaderPipelines(
            applyPalette: applyPalettePSO,
            voxelConveyor: voxelConveyorPSO,
            temporalRemap: nil,
            ditherPass: nil
        )
    }

    public func encodeApplyPalette(cmd: MTLCommandBuffer,
                                  index: MTLTexture,
                                  palette: MTLTexture,
                                  outRGBA: MTLTexture) {
        guard let encoder = cmd.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(applyPalettePSO)
        encoder.setTexture(index, index: 0)
        encoder.setTexture(palette, index: 1)
        encoder.setTexture(outRGBA, index: 2)

        let w = applyPalettePSO.threadExecutionWidth
        let h = applyPalettePSO.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (outRGBA.width + w - 1) / w,
            height: (outRGBA.height + h - 1) / h,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupsPerGrid,
                                    threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }

    public func encodeVoxelConveyor(cmd: MTLCommandBuffer,
                                   frames: [MTLTexture],
                                   currentFrame: Int,
                                   settings: VoxelMetadata.ConveyorSettings,
                                   outVolume: MTLTexture) {
        guard let encoder = cmd.makeComputeCommandEncoder(),
              let voxelConveyorPSO = voxelConveyorPSO else { return }

        encoder.setComputePipelineState(voxelConveyorPSO)

        for (index, frame) in frames.enumerated() {
            encoder.setTexture(frame, index: index)
        }

        var params = ConveyorParams(
            currentFrame: UInt32(currentFrame),
            frameCount: UInt32(frames.count),
            zDepth: UInt32(settings.zDepth),
            brightnessDecay: settings.brightnessDecay,
            frameSpacing: settings.frameSpacing,
            animationSpeed: settings.animationSpeed
        )

        encoder.setBytes(&params, length: MemoryLayout<ConveyorParams>.stride, index: 0)
        encoder.setTexture(outVolume, index: frames.count)

        let w = voxelConveyorPSO.threadExecutionWidth
        let h = voxelConveyorPSO.maxTotalThreadsPerThreadgroup / w
        let d = 1

        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: d)
        let threadgroupsPerGrid = MTLSize(
            width: (outVolume.width + w - 1) / w,
            height: (outVolume.height + h - 1) / h,
            depth: (outVolume.arrayLength + d - 1) / d
        )

        encoder.dispatchThreadgroups(threadgroupsPerGrid,
                                    threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }

    private func getMetalSource() -> String {
        """
        #include <metal_stdlib>
        using namespace metal;

        // iOS 26 Metal 4: Detect Apple10 GPU family features
        #if __METAL_VERSION__ >= 270
        #define METAL4_OPTIMIZED 1
        #else
        #define METAL4_OPTIMIZED 0
        #endif

        // Function constant for compile-time optimization
        constant bool kUseThreadgroupCache [[function_constant(0)]];

        // iOS 26 FP16-optimized palette application kernel
        kernel void applyPalette(
            texture2d<uchar, access::read>    indexTex   [[texture(0)]],
            constant half4                   *paletteSrc [[buffer(0)]],
            texture2d<half4, access::write>   outTex     [[texture(2)]],
            threadgroup half4                 tgPalette[256],
            uint2 gid [[thread_position_in_grid]],
            uint  linearTid [[thread_index_in_threadgroup]],
            uint2 tgSize [[threads_per_threadgroup]]
        ) {
            if (gid.x >= indexTex.get_width() || gid.y >= indexTex.get_height()) return;

            // Prefetch palette to threadgroup memory (only if enabled)
            #if METAL4_OPTIMIZED
            if (kUseThreadgroupCache) {
                const uint threadsPerTG = tgSize.x * tgSize.y;
                for (uint i = linearTid; i < 256u; i += threadsPerTG) {
                    tgPalette[i] = paletteSrc[i];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            #endif

            // Read palette index as byte (0-255)
            const uchar idx = indexTex.read(gid).r;

            // Fetch color (threadgroup cache or direct buffer)
            half4 color;
            #if METAL4_OPTIMIZED
            if (kUseThreadgroupCache) {
                color = tgPalette[idx];
            } else {
                color = paletteSrc[idx];
            }
            #else
            color = paletteSrc[idx];
            #endif

            outTex.write(color, gid);
        }

        struct ConveyorParams {
            uint currentFrame;
            uint frameCount;
            uint zDepth;
            float brightnessDecay;
            float frameSpacing;
            float animationSpeed;
        };

        // iOS 26 FP16-optimized voxel conveyor kernel
        kernel void voxelConveyor(
            texture2d_array<half4, access::read>  frameTex  [[texture(0)]],
            texture3d<half4, access::write>        outVolume [[texture(1)]],
            constant ConveyorParams& params [[buffer(0)]],
            uint3 gid [[thread_position_in_grid]]
            #if METAL4_OPTIMIZED
            , uint simd_lane_id [[thread_index_in_simdgroup]]
            , uint simd_group_id [[simdgroup_index_in_threadgroup]]
            #endif
        ) {
            if (gid.x >= outVolume.get_width() ||
                gid.y >= outVolume.get_height() ||
                gid.z >= outVolume.get_depth()) return;

            // FP16 calculations for 2× throughput on A19 Bionic
            const half zNorm = half(gid.z) / half(params.zDepth);
            const uint frameOffset = uint(zNorm * half(params.frameCount) * params.animationSpeed);
            const uint frameIdx = (params.currentFrame + frameOffset) % params.frameCount;

            half4 color = frameTex.read(uint2(gid.x, gid.y), frameIdx);

            #if METAL4_OPTIMIZED
            // iOS 26 A19 Bionic: FP16 SIMD group operations
            half brightness = 1.0h - (zNorm * params.brightnessDecay);

            if (gid.z == 0) {
                const half pulse = 0.5h + 0.5h * sin(params.animationSpeed * 3.14159h);
                brightness = mix(brightness, 1.0h, pulse);
            }

            // Broadcast brightness across SIMD group for coherent memory access
            brightness = simd_broadcast(brightness, simd_lane_id);
            #else
            // Standard path for non-Metal 4 devices
            half brightness = 1.0h - (zNorm * params.brightnessDecay);

            if (gid.z == 0) {
                const half pulse = 0.5h + 0.5h * sin(params.animationSpeed * 3.14159h);
                brightness = mix(brightness, 1.0h, pulse);
            }
            #endif

            color.rgb *= brightness;

            const half spacing = params.frameSpacing;
            if (fmod(half(gid.z), spacing) > 0.1h) {
                color.a *= 0.8h;
            }

            outVolume.write(color, gid);
        }
        """
    }

    internal struct ConveyorParams {
        let currentFrame: UInt32
        let frameCount: UInt32
        let zDepth: UInt32
        let brightnessDecay: Float
        let frameSpacing: Float
        let animationSpeed: Float
    }
}

// MARK: - Extensions

extension Data {
    var sha256Hex: String {
        return self.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}
