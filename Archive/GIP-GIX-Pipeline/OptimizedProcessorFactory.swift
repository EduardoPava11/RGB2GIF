//
//  OptimizedProcessorFactory.swift
//  RGB2GIF
//
//  Factory for creating optimized processor implementations
//  Selects best implementation based on device capabilities
//
//  iOS 26 / iPhone 17 Pro Optimizations:
//  - Detects A19 Bionic chip and Metal 4 support
//  - Uses Swift 6.2 InlineArray when available
//  - Selects GPU-accelerated path for compatible operations
//  - Falls back to CPU implementations gracefully
//

import Foundation
import Darwin
import Metal
import CoreGraphics
import CoreImage
import CoreVideo
import os.log

@available(iOS 26.0, *)
public actor OptimizedProcessorFactory {

    // MARK: - Device Capabilities

    /// Detected device capabilities
    public struct DeviceCapabilities: Sendable {
        public let isA19Bionic: Bool          // iPhone 17 Pro
        public let isA18Bionic: Bool          // iPhone 16 Pro
        public let hasMetalFamily10: Bool     // Metal 4 on iOS 26
        public let hasMetalFamily9: Bool      // Metal 3
        public let systemMemoryGB: Int
        public let thermalState: ThermalState

        public var isIPhone17Pro: Bool { isA19Bionic }
        public var supportsMetalAcceleration: Bool { hasMetalFamily9 || hasMetalFamily10 }
    }

    public enum ThermalState: Sendable, CustomStringConvertible {
        case nominal
        case fair
        case serious
        case critical

        public var description: String {
            switch self {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            }
        }
    }

    // MARK: - Singleton

    public static let shared = OptimizedProcessorFactory()

    private let logger = Logger(subsystem: "com.rgb2gif", category: "ProcessorFactory")
    private var cachedCapabilities: DeviceCapabilities?
    private let metalDevice: MTLDevice?

    private init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        logger.info("ProcessorFactory initialized with Metal device: \(self.metalDevice?.name ?? "none")")
    }

    // MARK: - Capability Detection

    /// Detect device capabilities (cached)
    public func detectCapabilities() -> DeviceCapabilities {
        if let cached = cachedCapabilities {
            return cached
        }

        let capabilities = DeviceCapabilities(
            isA19Bionic: detectA19Bionic(),
            isA18Bionic: detectA18Bionic(),
            hasMetalFamily10: checkMetalFamily(.apple10),
            hasMetalFamily9: checkMetalFamily(.apple9),
            systemMemoryGB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)),
            thermalState: detectThermalState()
        )

        cachedCapabilities = capabilities
        logger.info("""
            Device Capabilities:
            - A19 Bionic: \(capabilities.isA19Bionic)
            - A18 Bionic: \(capabilities.isA18Bionic)
            - Metal Family 10: \(capabilities.hasMetalFamily10)
            - Metal Family 9: \(capabilities.hasMetalFamily9)
            - RAM: \(capabilities.systemMemoryGB) GB
            - Thermal: \(capabilities.thermalState)
            """)

        return capabilities
    }

    private func detectA19Bionic() -> Bool {
        guard let identifier = hardwareIdentifier() else { return false }
        let a19Identifiers: Set<String> = ["iPhone17,1", "iPhone17,2"]
        return a19Identifiers.contains(identifier)
    }

    private func detectA18Bionic() -> Bool {
        guard let identifier = hardwareIdentifier() else { return false }
        let a18Identifiers: Set<String> = ["iPhone16,1", "iPhone16,2"]
        return a18Identifiers.contains(identifier)
    }

    private func checkMetalFamily(_ family: MTLGPUFamily) -> Bool {
        guard let device = metalDevice else { return false }
        return device.supportsFamily(family)
    }

    private func detectThermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    private func hardwareIdentifier() -> String? {
        #if targetEnvironment(simulator)
        if let simIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simIdentifier
        }
        #endif

        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var machine = [CChar](repeating: 0, count: Int(size))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    // MARK: - Factory Methods

    /// Create optimized color quantizer
    public func makeQuantizer() -> any ColorQuantizing {
        let capabilities = detectCapabilities()

        // For iOS 26 + A19, use Metal-accelerated quantization if available
        if capabilities.isA19Bionic && capabilities.hasMetalFamily10 {
            logger.info("Selected: MetalQuantizer (A19 + Metal 4)")
            // TODO: Return MetalColorQuantizer when implemented
            // return MetalColorQuantizer(device: metalDevice!)
        }

        // Fallback to CPU octree quantizer
        logger.info("Selected: OctreeColorQuantizer (CPU fallback)")
        return OctreeQuantizerAdapter()
    }

    /// Create optimized downsampler
    /// Note: Uses Core Image + Metal for CGImage-based workflows (UI preview, quality resampling)
    /// For CVPixelBuffer → [UInt8] workflows (capture pipeline), use VImageDownscaler directly
    public func makeDownsampler() -> any ImageDownsampler {
        let capabilities = detectCapabilities()

        // Metal-accelerated Core Image for GPU path
        if capabilities.supportsMetalAcceleration && metalDevice != nil {
            logger.info("Selected: CoreImageDownsampler (Metal-backed)")
            return CoreImageDownsamplerAdapter(device: metalDevice!)
        }

        // Core Image CPU fallback for high-quality downsampling
        logger.info("Selected: CoreImageDownsampler (CPU)")
        return CoreImageDownsamplerAdapter(device: nil)
    }

    /// Create optimized LZW encoder
    public func makeLZWEncoder() -> any LZWEncoding {
        let capabilities = detectCapabilities()

        // Use Swift 6.2 optimized version on iOS 26+
        #if swift(>=6.2)
        if capabilities.isA19Bionic {
            logger.info("Selected: LZW_Optimized (Swift 6.2 InlineArray)")
            return LZWOptimizedAdapter()
        }
        #endif

        // Fallback to standard implementation
        logger.info("Selected: LZW (Standard)")
        return LZWStandardAdapter()
    }

    /// Create GIF encoder
    public func makeGIFEncoder() -> any GIFEncoder {
        logger.info("Selected: GIF89aMuxer (Standard)")
        return GIFEncoderAdapter()
    }

    /// Create complete processing pipeline
    public func makePipeline() -> any ProcessingPipeline {
        let capabilities = detectCapabilities()

        logger.info("Creating optimized pipeline for device")
        return OptimizedPipelineImpl(
            downsampler: makeDownsampler(),
            quantizer: makeQuantizer(),
            encoder: makeGIFEncoder(),
            lzwEncoder: makeLZWEncoder(),
            capabilities: capabilities
        )
    }

    /// Create workflow coordinator
    public func makeWorkflowCoordinator() -> any CaptureWorkflowCoordinator {
        logger.info("Selected: CaptureWorkflowCoordinatorImpl (Standard)")
        return CaptureWorkflowCoordinatorAdapter()
    }

    /// Create split format composer
    public func makeSplitFormatComposer() -> any SplitFormatComposer {
        logger.info("Selected: GIPGIXComposer (Standard)")
        return SplitFormatComposerAdapter()
    }

    /// Create gallery data source
    public func makeGalleryDataSource() -> any GalleryDataSource {
        logger.info("Selected: LocalGalleryDataSource (File-based)")
        return GalleryDataSourceAdapter()
    }

    /// Create progress notifier
    public func makeProgressNotifier() -> any ProgressNotifier {
        logger.info("Selected: UIProgressNotifier (Main actor dispatch)")
        return ProgressNotifierAdapter()
    }
}

// MARK: - Adapters (bridge existing implementations to protocols)

/// Adapter for OctreeColorQuantizer
@available(iOS 26.0, *)
private struct OctreeQuantizerAdapter: ColorQuantizing {
    private let quantizer = OctreeColorQuantizer()

    func quantize(_ image: CGImage, maxColors: Int) async throws -> QuantizationResult {
        let options = OctreeColorQuantizer.QuantizationOptions(maxColors: maxColors)
        let result = try await quantizer.quantize(image, options: options)

        return QuantizationResult(
            palette: result.palette,
            indexedPixels: result.indexedPixels,
            width: image.width,
            height: image.height,
            processingTimeMs: result.processingTime * 1000
        )
    }

    func quantizeBatch(_ images: [CGImage], maxColors: Int) async throws -> BatchQuantizationResult {
        // Batch quantization not needed - use single-frame quantization via GIPGIXBridge
        throw NSError(domain: "OctreeQuantizerAdapter", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Batch quantization not implemented. Use GIPGIXBridge.convertMultiFrame instead."
        ])
    }
}

/// Unified Core Image downsampler adapter
/// Uses HighFidelityDownsampler internally for quality resampling (Lanczos, Bicubic, etc.)
/// Metal-accelerated when device is provided, CPU fallback otherwise
///
/// Architecture Note:
/// - This adapter is for CGImage-based workflows (UI preview, export)
/// - For CVPixelBuffer → [UInt8] capture pipeline, use VImageDownscaler directly
/// - HighFidelityDownsampler uses Core Image (CIImage), NOT Accelerate vImage
@available(iOS 26.0, *)
private struct CoreImageDownsamplerAdapter: ImageDownsampler {
    private let downsampler: HighFidelityDownsampler
    private let ciContext: CIContext

    init(device: MTLDevice?) {
        self.downsampler = HighFidelityDownsampler()
        if let device = device {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    func downsample(_ image: CGImage, to targetSize: CGSize) async throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let downsampledCI = downsampler.downsample(ciImage, to: targetSize)

        guard let result = ciContext.createCGImage(downsampledCI, from: downsampledCI.extent) else {
            throw NSError(domain: "CoreImageDownsampler", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to convert downsampled CIImage to CGImage"
            ])
        }
        return result
    }

    func downsample(_ pixelBuffer: CVPixelBuffer, to targetSize: CGSize) async throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw NSError(domain: "CoreImageDownsampler", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create CGImage from CVPixelBuffer"
            ])
        }
        return try await downsample(cgImage, to: targetSize)
    }
}

/// Adapter for LZW_Optimized
@available(iOS 26.0, *)
private struct LZWOptimizedAdapter: LZWEncoding {
    func compress(indices: [UInt8], minCodeSize: UInt8) async throws -> [Data] {
        return try LZW_Optimized.compress(indices: indices, minCodeSize: minCodeSize)
    }
}

/// Adapter for standard LZW
@available(iOS 26.0, *)
private struct LZWStandardAdapter: LZWEncoding {
    func compress(indices: [UInt8], minCodeSize: UInt8) async throws -> [Data] {
        // Use same optimized version for now
        return try LZW_Optimized.compress(indices: indices, minCodeSize: minCodeSize)
    }
}

/// Adapter for GIF89aMuxer
@available(iOS 26.0, *)
private struct GIFEncoderAdapter: GIFEncoder {

    enum AdapterError: LocalizedError {
        case noFrames
        case inconsistentDimensions
        case invalidPixelCount(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .noFrames:
                return "No quantized frames supplied for GIF encoding"
            case .inconsistentDimensions:
                return "Quantized frames have inconsistent dimensions"
            case .invalidPixelCount(let expected, let actual):
                return "Indexed pixel buffer length \(actual) does not match expected \(expected)"
            }
        }
    }

    struct PaletteConversion {
        let rgb: [[UInt8]]
        let transparentIndex: UInt8?
    }

    func encode(frames: [QuantizationResult], options: GIFEncodingOptions) async throws -> GIFEncodingArtifacts {
        guard let first = frames.first else {
            throw AdapterError.noFrames
        }

        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw AdapterError.inconsistentDimensions
        }

        let width = UInt16(first.width)
        let height = UInt16(first.height)
        let expectedPixels = first.width * first.height

        // RGB2GIF enforces 256-color palettes (paletteExp = 7)
        let paletteExp: UInt8 = 7
        let requiredPaletteSize = 1 << (Int(paletteExp) + 1) // 256

        let paletteInputs: [[UInt32]]
        if options.useGlobalPalette {
            paletteInputs = [first.palette]
        } else {
            paletteInputs = frames.map { $0.palette }
        }

        let paletteConversions = paletteInputs.map { palette in
            convertPalette(palette, requiredSize: requiredPaletteSize)
        }

        let gipPalettes: [GIPPalette] = try paletteConversions.enumerated().map { index, conversion in
            try makePalette(
                from: conversion.rgb,
                label: options.useGlobalPalette ? "global" : "frame_\(index)",
                requiredSize: requiredPaletteSize,
                transparentIndex: conversion.transparentIndex
            )
        }

        let gip = try GIP(
            paletteExp: paletteExp,
            name: "RGB2GIF",
            palettes: gipPalettes,
            hasGlobal: true,
            hasFrameSet: !options.useGlobalPalette,
            hashAlg: .none,
            backgroundColorIndex: paletteConversions.first?.transparentIndex,
            pixelAspectRatio: nil
        )

        let paletteRefs: [UInt32]
        if options.useGlobalPalette {
            paletteRefs = Array(repeating: 0, count: frames.count)
        } else {
            paletteRefs = frames.enumerated().map { UInt32($0.offset) }
        }

        let minCodeSize = max(2, paletteExp + 1)
        let frameDelayCS = UInt16(max(1, (options.frameDelayMs + 9) / 10))

        var gixFrames: [GIXFrame] = []
        gixFrames.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard frame.indexedPixels.count == expectedPixels else {
                throw AdapterError.invalidPixelCount(expected: expectedPixels, actual: frame.indexedPixels.count)
            }

            let blocks = try LZW_Optimized.compress(indices: frame.indexedPixels, minCodeSize: minCodeSize)
            let payload = blocks.reduce(into: Data()) { $0.append($1) }

            let paletteRef = options.useGlobalPalette ? 0 : Int(paletteRefs[index])
            let conversion = paletteConversions[min(paletteRef, paletteConversions.count - 1)]

            let gixFrame = GIXFrame(
                paletteRef: paletteRefs[index],
                delay: frameDelayCS,
                disposal: options.disposalMethod.rawValue,
                transparency: conversion.transparentIndex != nil,
                transparentIndex: conversion.transparentIndex ?? 0,
                dataEncoding: .lzwSubblocks,
                payload: payload,
                left: 0,
                top: 0,
                frameWidth: width,
                frameHeight: height,
                interlaced: false
            )

            gixFrames.append(gixFrame)
        }

        let loopCountValue: UInt16? = options.loopCount < 0 ? nil : UInt16(clamping: options.loopCount)

        let gix = try GIX(
            width: width,
            height: height,
            lzwMinCodeSize: minCodeSize,
            defaultPaletteRef: 0,
            name: "RGB2GIF",
            frames: gixFrames,
            loopCount: loopCountValue
        )

        let tempURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("rgb2gif_\(UUID().uuidString)")
            .appendingPathExtension("gif")

        try GIF89aMuxer.mux(gip: gip, gix: gix, to: tempURL, loopForever: options.loopCount == 0 ? true : nil)
        let gifData = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        return GIFEncodingArtifacts(gifData: gifData, gip: gip, gix: gix)
    }

    private func convertPalette(_ palette: [UInt32], requiredSize: Int) -> PaletteConversion {
        var rgb: [[UInt8]] = []
        rgb.reserveCapacity(requiredSize)

        var transparentIndex: UInt8? = nil

        for (index, color) in palette.enumerated() {
            let a = UInt8((color >> 24) & 0xFF)
            let r = UInt8((color >> 16) & 0xFF)
            let g = UInt8((color >> 8) & 0xFF)
            let b = UInt8(color & 0xFF)

            rgb.append([r, g, b])

            if a < 255 && transparentIndex == nil {
                transparentIndex = UInt8(clamping: index)
            }
        }

        if rgb.count < requiredSize {
            let padding = requiredSize - rgb.count
            rgb.append(contentsOf: Array(repeating: [0, 0, 0], count: padding))
        } else if rgb.count > requiredSize {
            rgb = Array(rgb.prefix(requiredSize))
            if let transparent = transparentIndex, Int(transparent) >= requiredSize {
                transparentIndex = nil
            }
        }

        return PaletteConversion(rgb: rgb, transparentIndex: transparentIndex)
    }

    private func makePalette(from rgb: [[UInt8]],
                             label: String,
                             requiredSize: Int,
                             transparentIndex: UInt8?) throws -> GIPPalette {
        return GIPPalette(
            entryCount: UInt16(requiredSize),
            dims: 1,
            dimA: UInt16(requiredSize),
            dimB: 1,
            ordering: .rowMajor,
            hasTransparency: transparentIndex != nil,
            transparentIndex: transparentIndex ?? 0,
            label: label,
            rgb: rgb,
            remap: nil,
            hash: nil
        )
    }
}

// MARK: - Optimized Pipeline Implementation

@available(iOS 26.0, *)
private final class OptimizedPipelineImpl: ProcessingPipeline, @unchecked Sendable {
    let downsampler: any ImageDownsampler
    let quantizer: any ColorQuantizing
    let encoder: any GIFEncoder
    let lzwEncoder: any LZWEncoding
    let capabilities: OptimizedProcessorFactory.DeviceCapabilities

    private let logger = Logger(subsystem: "com.rgb2gif", category: "Pipeline")

    init(downsampler: any ImageDownsampler,
         quantizer: any ColorQuantizing,
         encoder: any GIFEncoder,
         lzwEncoder: any LZWEncoding,
         capabilities: OptimizedProcessorFactory.DeviceCapabilities) {
        self.downsampler = downsampler
        self.quantizer = quantizer
        self.encoder = encoder
        self.lzwEncoder = lzwEncoder
        self.capabilities = capabilities
    }

    func process(frames: [CapturedFrame], targetSize: CGSize, maxColors: Int) async throws -> GIFEncodingArtifacts {
        logger.info("Processing \(frames.count) frames to \(Int(targetSize.width))x\(Int(targetSize.height)) with \(maxColors) colors")

        // This code path is deprecated - use CaptureToGIP2Pipeline instead
        throw NSError(domain: "OptimizedPipelineImpl", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "OptimizedPipeline is deprecated. Use CaptureToGIP2Pipeline for GIF creation."
        ])
    }

    var progressStream: AsyncStream<PipelineProgress> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

// MARK: - Workflow Orchestration Adapters

/// Adapter for CaptureWorkflowCoordinator
/// Bridges existing TemporalCubeCaptureManager + CaptureToGIP2Pipeline to protocol
@available(iOS 26.0, *)
private struct CaptureWorkflowCoordinatorAdapter: CaptureWorkflowCoordinator {
    func startWorkflow(config: WorkflowConfiguration) async throws -> WorkflowHandle {
        // TODO: Integrate with TemporalCubeCaptureManager
        // TODO: Wire up stageStream to emit WorkflowStage events
        let handle = WorkflowHandle(id: UUID().uuidString, startedAt: Date())
        return handle
    }

    func cancelWorkflow(_ handle: WorkflowHandle) async {
        // TODO: Cancel running capture/processing
    }

    var currentStage: WorkflowStage {
        get async {
            // TODO: Return actual current stage
            return .idle
        }
    }

    var stageStream: AsyncStream<WorkflowStage> {
        AsyncStream { continuation in
            // TODO: Emit real workflow stages
            continuation.yield(.idle)
            continuation.finish()
        }
    }
}

/// Adapter for SplitFormatComposer
/// Bridges existing GIPGIXComposer to protocol
@available(iOS 26.0, *)
private struct SplitFormatComposerAdapter: SplitFormatComposer {
    func compose(frames: [QuantizationResult], strategy: PaletteStrategy, outputDirectory: URL) async throws -> CompositionResult {
        // TODO: Use existing GIPGIXComposer
        // TODO: Map PaletteStrategy to CaptureToGIP2Pipeline.PaletteStrategy
        // For now, return placeholder
        let gipURL = outputDirectory.appendingPathComponent("output.gip")
        let gixURL = outputDirectory.appendingPathComponent("output.gix")
        let gifURL = outputDirectory.appendingPathComponent("output.gif")

        return CompositionResult(
            gipURL: gipURL,
            gixURL: gixURL,
            gifURL: gifURL,
            paletteCount: 1,
            frameCount: frames.count,
            gipFileSizeBytes: 0,
            gixFileSizeBytes: 0
        )
    }

    var compositionProgress: AsyncStream<CompositionProgress> {
        AsyncStream { continuation in
            // TODO: Emit real composition progress
            continuation.yield(.complete)
            continuation.finish()
        }
    }
}

/// Adapter for GalleryDataSource
/// Bridges file system access to protocol
@available(iOS 26.0, *)
private struct GalleryDataSourceAdapter: GalleryDataSource {
    func fetchGallery() async throws -> [GIFMetadata] {
        // TODO: Scan Documents directory for GIF files
        // TODO: Parse metadata from companion files or embedded metadata
        return []
    }

    func metadata(for id: String) async throws -> GIFMetadata {
        // TODO: Load metadata for specific GIF
        throw NSError(domain: "GalleryDataSource", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }

    func thumbnail(for id: String) async throws -> CGImage {
        // TODO: Generate or load cached thumbnail
        throw NSError(domain: "GalleryDataSource", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }

    func gifData(for id: String) async throws -> Data {
        // TODO: Load GIF data from file
        throw NSError(domain: "GalleryDataSource", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }

    func delete(id: String) async throws {
        // TODO: Delete GIF, GIP, GIX files
        throw NSError(domain: "GalleryDataSource", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not implemented"])
    }
}

/// Adapter for ProgressNotifier
/// Dispatches to main actor for UI updates
@available(iOS 26.0, *)
private struct ProgressNotifierAdapter: ProgressNotifier {
    func notify(stage: String, progress: Double, details: String?) async {
        // TODO: Dispatch to main actor and update UI
        // Example: NotificationCenter.post or MainActor update
        await MainActor.run {
            // Update UI here
        }
    }

    func notifyMilestone(_ milestone: ProcessingMilestone) async {
        // TODO: Show milestone notification (e.g., banner, log, analytics)
        await MainActor.run {
            switch milestone {
            case .gipFileCreated(let url, let paletteCount, let fileSizeBytes):
                print("✅ GIP created: \(url.lastPathComponent), \(paletteCount) palettes, \(fileSizeBytes) bytes")
            case .gixFileCreated(let url, let frameCount, let fileSizeBytes):
                print("✅ GIX created: \(url.lastPathComponent), \(frameCount) frames, \(fileSizeBytes) bytes")
            case .gifMuxed(let url, let frameCount, let fileSizeBytes):
                print("✅ GIF muxed: \(url.lastPathComponent), \(frameCount) frames, \(fileSizeBytes) bytes")
            case .savedToPhotos(let assetID):
                print("✅ Saved to Photos: \(assetID)")
            default:
                break
            }
        }
    }

    func notifyError(_ error: Error, context: String) async {
        // TODO: Show error alert or log
        await MainActor.run {
            print("❌ Error in \(context): \(error.localizedDescription)")
        }
    }
}
