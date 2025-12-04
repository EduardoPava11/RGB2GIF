//
//  PaletteLUTRenderer.swift
//  RGB2GIF
//
//  Metal-based renderer for NV12 Y-plane → palette skinning
//  Uses CVMetalTextureCache for zero-copy buffer access
//

import Foundation
import Metal
import CoreVideo
import CoreImage
import os.log

private let rendererLogger = Logger(subsystem: "com.rgb2gif", category: "PaletteLUTRenderer")

/// Metal-based renderer for NV12 Y-plane palette skinning
/// Thread-safe: Can be used from any thread (Metal commands are GPU-dispatched)
/// Swift 6.2 compliance: No @MainActor isolation needed for GPU work
@available(iOS 26.0, *)
final class PaletteLUTRenderer: Sendable {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache // Immutable after init

    // Device-adaptive threadgroup sizing (Phase 5: Metal optimization)
    // These values are queried from pipelineState after initialization
    private let optimalThreadExecutionWidth: Int
    private let maxThreadsPerThreadgroup: Int

    // Palette and LUT buffers (Swift 6.2: Use let for thread safety after init)
    // These are set once via setPalette/setLUT and then read-only
    private let paletteLock = NSLock()
    private var _paletteTexture: MTLTexture?
    private var _lutBuffer: MTLBuffer?
    private var _currentPaletteSize: Int = 256

    // Thread-safe accessors
    private var paletteTexture: MTLTexture? {
        paletteLock.lock()
        defer { paletteLock.unlock() }
        return _paletteTexture
    }

    private var lutBuffer: MTLBuffer? {
        paletteLock.lock()
        defer { paletteLock.unlock() }
        return _lutBuffer
    }

    private static func makeFunction(
        from library: MTLLibrary,
        preferredNames: [String],
        label: String
    ) throws -> MTLFunction {
        for name in preferredNames {
            if let function = library.makeFunction(name: name) {
                rendererLogger.debug("Using palette shader function \(name) for \(label)")
                return function
            }
        }
        throw RendererError.shaderFunctionNotFound(preferredNames.first ?? label)
    }

    // MARK: - Initialization

    init() throws {
        // Get default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noMetalDevice
        }
        self.device = device

        // Create command queue
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.cannotCreateCommandQueue
        }
        self.commandQueue = queue

        // Load shader library from embedded source so the build does not
        // depend on the `metal` command-line tool (frequently unavailable in
        // sandboxed CI environments).
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSources.palettePreviewKernels, options: nil)
        } catch {
            rendererLogger.error("Failed to compile palette shaders: \(error.localizedDescription)")
            throw RendererError.cannotLoadShaderLibrary
        }

        // Get compute function
        let function = try Self.makeFunction(
            from: library,
            preferredNames: ["palettePreviewOptimized", "palettePreview"],
            label: "palettePreview"
        )

        // Create pipeline state
        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw RendererError.cannotCreatePipelineState(error)
        }

        // Create texture cache for zero-copy CVPixelBuffer access
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )

        guard result == kCVReturnSuccess, let cache = cache else {
            throw RendererError.cannotCreateTextureCache
        }

        self.textureCache = cache

        // Phase 5: Query device-adaptive threadgroup parameters from pipeline state
        // Don't hardcode A19 assumptions - let the device tell us optimal configuration
        self.optimalThreadExecutionWidth = pipelineState.threadExecutionWidth
        self.maxThreadsPerThreadgroup = pipelineState.maxTotalThreadsPerThreadgroup

        rendererLogger.info("""
            ✅ PaletteLUTRenderer initialized on device: \(device.name)
               • threadExecutionWidth: \(self.optimalThreadExecutionWidth)
               • maxTotalThreadsPerThreadgroup: \(self.maxThreadsPerThreadgroup)
               • Supports Apple10 (A19): \(device.supportsFamily(.apple10))
            """)

        // Phase 5: Warmup CVMetalTextureCache to avoid first-frame latency
        warmupTextureCache()
    }

    // MARK: - CVMetalTextureCache Warmup

    /// Pre-warm CVMetalTextureCache to avoid first-frame allocation latency
    /// Phase 5: Keep the cache hot for faster texture creation during capture
    private func warmupTextureCache() {
        // Create a small dummy texture to warm up the cache allocator
        // This avoids first-frame latency in renderNV12ToRGBA()
        let dummyDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 8,
            height: 8,
            mipmapped: false
        )
        dummyDescriptor.usage = [.shaderRead]

        // Create and immediately discard - this warms up Metal's internal allocators
        _ = device.makeTexture(descriptor: dummyDescriptor)

        rendererLogger.debug("CVMetalTextureCache warmed up")
    }

    // MARK: - Metal Threadgroup Optimization

    /// Compute optimal threadgroup size for given texture dimensions
    /// Phase 5: Device-adaptive sizing based on pipelineState properties
    /// - Parameters:
    ///   - width: Texture width
    ///   - height: Texture height
    /// - Returns: (threadsPerThreadgroup, threadgroups) for dispatch
    private func computeOptimalThreadgroupSize(width: Int, height: Int) -> (threadsPerThreadgroup: MTLSize, threadgroups: MTLSize) {
        // Strategy: Build threadsPerThreadgroup from threadExecutionWidth × Y
        // such that width × Y ≤ maxTotalThreadsPerThreadgroup

        // Start with SIMD-optimal width (typically 32 on A19, 16 on older GPUs)
        let threadWidth = min(optimalThreadExecutionWidth, width)

        // Compute maximum Y dimension that fits within maxThreadsPerThreadgroup
        let maxThreadHeight = maxThreadsPerThreadgroup / threadWidth

        // Choose Y dimension: prefer 8, 16, or 32 based on device capabilities
        // Larger Y = better cache locality for 2D textures
        let threadHeight: Int
        if maxThreadHeight >= 32 {
            threadHeight = 32  // Best for A19 and future GPUs
        } else if maxThreadHeight >= 16 {
            threadHeight = 16  // Good for A17/A18
        } else if maxThreadHeight >= 8 {
            threadHeight = 8   // Conservative for older GPUs
        } else {
            threadHeight = 1   // Fallback to 1D dispatch
        }

        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)

        // Calculate number of threadgroups needed to cover the texture
        let threadgroupsX = (width + threadWidth - 1) / threadWidth
        let threadgroupsY = (height + threadHeight - 1) / threadHeight
        let threadgroups = MTLSize(width: threadgroupsX, height: threadgroupsY, depth: 1)

        return (threadsPerThreadgroup, threadgroups)
    }

    // MARK: - Public API

    /// Upload a 256-color palette (256×3 RGB bytes)
    /// - Parameter rgbBytes: Array of RGB triples [[R, G, B], ...]
    func setPalette(rgbBytes: [[UInt8]]) throws {
        guard !rgbBytes.isEmpty, rgbBytes.count <= 256 else {
            throw RendererError.invalidPaletteSize(rgbBytes.count)
        }

        let paletteSize = rgbBytes.count

        // Convert to RGBA (Metal requires 4-byte alignment)
        var rgbaData = [UInt8]()
        rgbaData.reserveCapacity(paletteSize * 4)

        for rgb in rgbBytes {
            guard rgb.count == 3 else {
                throw RendererError.invalidPaletteFormat
            }
            rgbaData.append(rgb[0]) // R
            rgbaData.append(rgb[1]) // G
            rgbaData.append(rgb[2]) // B
            rgbaData.append(255)     // A
        }

        // Pad to 256 entries if needed
        while rgbaData.count < 256 * 4 {
            rgbaData.append(contentsOf: [0, 0, 0, 255])
        }

        // Create 1D texture for palette
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type1D
        textureDescriptor.pixelFormat = .rgba8Unorm
        textureDescriptor.width = 256
        textureDescriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw RendererError.cannotCreateTexture("palette")
        }

        // Upload palette data
        rgbaData.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake1D(0, 256),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: 256 * 4
            )
        }

        paletteLock.lock()
        self._paletteTexture = texture
        self._currentPaletteSize = paletteSize
        paletteLock.unlock()
        rendererLogger.debug("Uploaded palette with \(paletteSize) colors")
    }

    /// Upload a 256-byte LUT mapping luma values (0-255) to palette indices
    /// - Parameter lut: 256-byte array where lut[lumaValue] = paletteIndex
    func setLUT(lut: [UInt8]) throws {
        guard lut.count == 256 else {
            throw RendererError.invalidLUTSize(lut.count)
        }

        // Create Metal buffer for LUT
        guard let buffer = device.makeBuffer(
            bytes: lut,
            length: 256,
            options: .storageModeShared
        ) else {
            throw RendererError.cannotCreateBuffer("LUT")
        }

        paletteLock.lock()
        self._lutBuffer = buffer
        paletteLock.unlock()
        rendererLogger.debug("Uploaded LUT (256 bytes)")
    }

    /// Render NV12 Y-plane to RGBA using palette and LUT
    /// - Parameter pixelBuffer: CVPixelBuffer in NV12 format (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    /// - Returns: MTLTexture with RGBA output
    func renderNV12ToRGBA(pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        // Verify palette and LUT are set
        guard let paletteTexture = paletteTexture else {
            throw RendererError.paletteNotSet
        }

        guard let lutBuffer = lutBuffer else {
            throw RendererError.lutNotSet
        }

        // Get dimensions
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create Y-plane texture from CVPixelBuffer (plane 0)
        var yTexture: CVMetalTexture?
        let yResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0, // plane index for Y-plane
            &yTexture
        )

        guard yResult == kCVReturnSuccess,
              let yTexture = yTexture,
              let yPlaneTexture = CVMetalTextureGetTexture(yTexture) else {
            throw RendererError.cannotCreateTexture("Y-plane from CVPixelBuffer")
        }

        // Create output texture
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderWrite, .shaderRead]

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw RendererError.cannotCreateTexture("output")
        }

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.cannotCreateCommandBuffer
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.cannotCreateComputeEncoder
        }

        // Set pipeline and resources
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(yPlaneTexture, index: 0)
        computeEncoder.setBuffer(lutBuffer, offset: 0, index: 0)
        computeEncoder.setTexture(paletteTexture, index: 1)
        computeEncoder.setTexture(outputTexture, index: 2)

        // Phase 5: Use device-adaptive threadgroup sizing
        let (threadsPerThreadgroup, threadgroups) = computeOptimalThreadgroupSize(width: width, height: height)

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        // Commit and wait
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Check for errors
        if let error = commandBuffer.error {
            throw RendererError.renderFailed(error)
        }

        return outputTexture
    }

    /// Convenience method for BGRA pixel buffers (converts to grayscale first)
    /// - Parameter pixelBuffer: CVPixelBuffer in BGRA format
    /// - Returns: MTLTexture with RGBA output
    func renderBGRAToRGBA(pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        // For BGRA, we need to extract grayscale first
        // This is a simplified version - in production, you might want a separate shader
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Lock pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RendererError.cannotAccessPixelBuffer
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Extract grayscale using rec709 luma
        var grayscaleData = [UInt8]()
        grayscaleData.reserveCapacity(width * height)

        for y in 0..<height {
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow)
            let bgraPtr = rowPtr.assumingMemoryBound(to: UInt8.self)

            for x in 0..<width {
                let b = Float(bgraPtr[x * 4 + 0])
                let g = Float(bgraPtr[x * 4 + 1])
                let r = Float(bgraPtr[x * 4 + 2])

                // rec709 luma: Y = 0.2126*R + 0.7152*G + 0.0722*B
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                grayscaleData.append(UInt8(clamping: Int(luma)))
            }
        }

        // Create grayscale texture
        let grayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        grayDescriptor.usage = [.shaderRead]

        guard let grayTexture = device.makeTexture(descriptor: grayDescriptor) else {
            throw RendererError.cannotCreateTexture("grayscale")
        }

        grayscaleData.withUnsafeBytes { ptr in
            grayTexture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width
            )
        }

        // Now render using the standard pipeline (treat grayscale as Y-plane)
        guard let paletteTexture = paletteTexture, let lutBuffer = lutBuffer else {
            throw RendererError.paletteNotSet
        }

        // Create output texture
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderWrite, .shaderRead]

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw RendererError.cannotCreateTexture("output")
        }

        // Render
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.cannotCreateCommandBuffer
        }

        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(grayTexture, index: 0)
        computeEncoder.setBuffer(lutBuffer, offset: 0, index: 0)
        computeEncoder.setTexture(paletteTexture, index: 1)
        computeEncoder.setTexture(outputTexture, index: 2)

        // Phase 5: Use device-adaptive threadgroup sizing
        let (threadsPerThreadgroup, threadgroups) = computeOptimalThreadgroupSize(width: width, height: height)

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw RendererError.renderFailed(error)
        }

        return outputTexture
    }

    // MARK: - Errors

    enum RendererError: LocalizedError {
        case noMetalDevice
        case cannotCreateCommandQueue
        case cannotLoadShaderLibrary
        case shaderFunctionNotFound(String)
        case cannotCreatePipelineState(Error)
        case cannotCreateTextureCache
        case invalidPaletteSize(Int)
        case invalidPaletteFormat
        case invalidLUTSize(Int)
        case cannotCreateTexture(String)
        case cannotCreateBuffer(String)
        case paletteNotSet
        case lutNotSet
        case cannotCreateCommandBuffer
        case cannotCreateComputeEncoder
        case renderFailed(Error)
        case cannotAccessPixelBuffer

        var errorDescription: String? {
            switch self {
            case .noMetalDevice:
                return "Metal device not available"
            case .cannotCreateCommandQueue:
                return "Cannot create Metal command queue"
            case .cannotLoadShaderLibrary:
                return "Cannot load shader library"
            case .shaderFunctionNotFound(let name):
                return "Shader function '\(name)' not found"
            case .cannotCreatePipelineState(let error):
                return "Cannot create pipeline state: \(error.localizedDescription)"
            case .cannotCreateTextureCache:
                return "Cannot create CVMetalTextureCache"
            case .invalidPaletteSize(let size):
                return "Invalid palette size: \(size) (expected 1-256)"
            case .invalidPaletteFormat:
                return "Invalid palette format (expected [[R, G, B]])"
            case .invalidLUTSize(let size):
                return "Invalid LUT size: \(size) (expected 256)"
            case .cannotCreateTexture(let name):
                return "Cannot create texture: \(name)"
            case .cannotCreateBuffer(let name):
                return "Cannot create buffer: \(name)"
            case .paletteNotSet:
                return "Palette not set - call setPalette() first"
            case .lutNotSet:
                return "LUT not set - call setLUT() first"
            case .cannotCreateCommandBuffer:
                return "Cannot create Metal command buffer"
            case .cannotCreateComputeEncoder:
                return "Cannot create Metal compute encoder"
            case .renderFailed(let error):
                return "Render failed: \(error.localizedDescription)"
            case .cannotAccessPixelBuffer:
                return "Cannot access pixel buffer base address"
            }
        }
    }
}
