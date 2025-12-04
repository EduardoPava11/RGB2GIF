//
//  ProcessingProtocols.swift
//  RGB2GIF
//
//  Protocol abstractions for processing pipeline components
//  Enables dependency injection, testing, and iOS 26 optimization
//
//  Architecture Pattern: Protocol-Oriented Design + Dependency Injection
//  - Each stage of pipeline has protocol interface
//  - Concrete implementations can be swapped (Metal, CPU, etc.)
//  - Enables testing with mocks
//  - Optimized implementations selected at runtime
//

import Foundation
import CoreGraphics
import AVFoundation
import CoreVideo

// MARK: - Swift 6 Sendable Conformance

/// CVPixelBuffer is thread-safe when properly retained/released
extension CVPixelBuffer: @unchecked Sendable {}

/// CVMetalTextureCache is thread-safe
extension CVMetalTextureCache: @unchecked Sendable {}

// MARK: - Core Processing Protocols

/// Protocol for frame capture from camera
@available(iOS 26.0, *)
public protocol CaptureDevice: Sendable {
    /// Start capturing frames
    func startCapture(configuration: CaptureConfiguration) async throws

    /// Stop capturing
    func stopCapture() async

    /// Current capture state
    var state: CaptureState { get async }

    /// Stream of captured frames
    var frameStream: AsyncStream<CapturedFrame> { get }
}

/// Captured frame data
@available(iOS 26.0, *)
public struct CapturedFrame: Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: CMTime
    public let frameIndex: Int

    public init(pixelBuffer: CVPixelBuffer, timestamp: CMTime, frameIndex: Int) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.frameIndex = frameIndex
    }
}

/// Configuration for capture
@available(iOS 26.0, *)
public struct CaptureConfiguration: Sendable {
    public let targetFPS: Double
    public let resolution: CGSize
    public let frameCount: Int
    public let pixelFormat: OSType  // kCVPixelFormatType_32BGRA or kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    public init(targetFPS: Double = 30.0,
                resolution: CGSize = CGSize(width: 1280, height: 1280),
                frameCount: Int = 128,
                pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.targetFPS = targetFPS
        self.resolution = resolution
        self.frameCount = frameCount
        self.pixelFormat = pixelFormat
    }
}

/// Capture state
@available(iOS 26.0, *)
public enum CaptureState: Sendable, Equatable {
    case idle
    case capturing(progress: Int, total: Int)
    case completed
    case failed(error: String)
}

// MARK: - Image Processing Protocols

/// Protocol for image downsampling
@available(iOS 26.0, *)
public protocol ImageDownsampler: Sendable {
    /// Downsample image to target size
    /// - Parameters:
    ///   - image: Source image
    ///   - targetSize: Desired output size (square)
    /// - Returns: Downsampled image
    func downsample(_ image: CGImage, to targetSize: CGSize) async throws -> CGImage

    /// Downsample pixel buffer to target size
    /// - Parameters:
    ///   - pixelBuffer: Source pixel buffer
    ///   - targetSize: Desired output size (square)
    /// - Returns: Downsampled image
    func downsample(_ pixelBuffer: CVPixelBuffer, to targetSize: CGSize) async throws -> CGImage
}

/// Protocol for color quantization
@available(iOS 26.0, *)
public protocol ColorQuantizing: Sendable {
    /// Quantize image to palette
    /// - Parameters:
    ///   - image: Source image
    ///   - maxColors: Maximum palette size (typically 256)
    /// - Returns: Palette and indexed pixels
    func quantize(_ image: CGImage, maxColors: Int) async throws -> QuantizationResult

    /// Quantize batch of images with shared palette
    /// - Parameters:
    ///   - images: Array of source images
    ///   - maxColors: Maximum palette size
    /// - Returns: Shared palette and indexed pixels for each image
    func quantizeBatch(_ images: [CGImage], maxColors: Int) async throws -> BatchQuantizationResult
}

/// Result of color quantization
@available(iOS 26.0, *)
public struct QuantizationResult: Sendable {
    public let palette: [UInt32]          // ARGB colors
    public let indexedPixels: [UInt8]     // Palette indices
    public let width: Int
    public let height: Int
    public let processingTimeMs: Double

    public init(palette: [UInt32], indexedPixels: [UInt8], width: Int, height: Int, processingTimeMs: Double) {
        self.palette = palette
        self.indexedPixels = indexedPixels
        self.width = width
        self.height = height
        self.processingTimeMs = processingTimeMs
    }
}

/// Result of batch quantization
@available(iOS 26.0, *)
public struct BatchQuantizationResult: Sendable {
    public let sharedPalette: [UInt32]           // Shared palette across all frames
    public let frames: [QuantizationResult]       // Per-frame indexed data
    public let totalProcessingTimeMs: Double

    public init(sharedPalette: [UInt32], frames: [QuantizationResult], totalProcessingTimeMs: Double) {
        self.sharedPalette = sharedPalette
        self.frames = frames
        self.totalProcessingTimeMs = totalProcessingTimeMs
    }
}

// MARK: - Compression Protocols

/// Protocol for LZW compression
@available(iOS 26.0, *)
public protocol LZWEncoding: Sendable {
    /// Compress indexed pixel data
    /// - Parameters:
    ///   - indices: Palette indices (0-255)
    ///   - minCodeSize: Minimum code size (typically log2(paletteSize))
    /// - Returns: Array of compressed sub-blocks
    func compress(indices: [UInt8], minCodeSize: UInt8) async throws -> [Data]
}

/// Protocol for LZW decompression
@available(iOS 26.0, *)
public protocol LZWDecoding: Sendable {
    /// Decompress LZW data
    /// - Parameters:
    ///   - data: Compressed data stream
    ///   - minCodeSize: Minimum code size
    /// - Returns: Decompressed indices
    func decompress(data: Data, minCodeSize: UInt8) async throws -> [UInt8]
}

// MARK: - GIF Format Protocols

/// Protocol for GIF encoding
@available(iOS 26.0, *)
public struct GIFEncodingArtifacts: Sendable {
    public let gifData: Data
    public let gip: GIP
    public let gix: GIX

    public init(gifData: Data, gip: GIP, gix: GIX) {
        self.gifData = gifData
        self.gip = gip
        self.gix = gix
    }
}

public protocol GIFEncoder: Sendable {
    /// Encode frames to GIF89a format using GIP (palette) + GIX (indices)
    /// - Parameters:
    ///   - frames: Array of quantized frames
    ///   - options: Encoding options
    /// - Returns: GIF data along with the intermediate GIP/GIX artifacts
    func encode(frames: [QuantizationResult], options: GIFEncodingOptions) async throws -> GIFEncodingArtifacts
}

/// GIF encoding options
@available(iOS 26.0, *)
public struct GIFEncodingOptions: Sendable {
    public let loopCount: Int              // 0 = infinite
    public let frameDelayMs: Int           // Delay between frames
    public let useGlobalPalette: Bool      // true = one palette for all frames
    public let disposalMethod: DisposalMethod

    public init(loopCount: Int = 0,
                frameDelayMs: Int = 40,
                useGlobalPalette: Bool = false,
                disposalMethod: DisposalMethod = .restoreToBackground) {
        self.loopCount = loopCount
        self.frameDelayMs = frameDelayMs
        self.useGlobalPalette = useGlobalPalette
        self.disposalMethod = disposalMethod
    }
}

@available(iOS 26.0, *)
public enum DisposalMethod: UInt8, Sendable {
    case none = 0
    case doNotDispose = 1
    case restoreToBackground = 2
    case restoreToPrevious = 3
}

/// Protocol for GIF validation
@available(iOS 26.0, *)
public protocol GIFValidator: Sendable {
    /// Validate GIF data structure
    /// - Parameter data: GIF data to validate
    /// - Returns: Validation result with errors if any
    func validate(_ data: Data) async throws -> ValidationResult
}

@available(iOS 26.0, *)
public struct ValidationResult: Sendable {
    public let isValid: Bool
    public let errors: [String]
    public let warnings: [String]

    public init(isValid: Bool, errors: [String] = [], warnings: [String] = []) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }
}

// MARK: - Logging Protocol

/// Protocol for structured logging
@available(iOS 26.0, *)
public protocol StructuredLogger: Sendable {
    func log(level: LogLevel, category: String, message: String, metadata: [String: String])
}

@available(iOS 26.0, *)
public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case critical
}

// MARK: - Pipeline Orchestration

/// Protocol for complete processing pipeline
@available(iOS 26.0, *)
public protocol ProcessingPipeline: Sendable {
    /// Process captured frames into GIF
    /// - Parameters:
    ///   - frames: Captured frames
    ///   - targetSize: Target frame size
    ///   - maxColors: Maximum palette colors
    /// - Returns: GIF encoding artifacts (GIF data + GIP/GIX containers)
    func process(frames: [CapturedFrame], targetSize: CGSize, maxColors: Int) async throws -> GIFEncodingArtifacts

    /// Progress stream
    var progressStream: AsyncStream<PipelineProgress> { get }
}

@available(iOS 26.0, *)
public struct PipelineProgress: Sendable {
    public let stage: String
    public let progress: Double  // 0.0 to 1.0
    public let message: String

    public init(stage: String, progress: Double, message: String) {
        self.stage = stage
        self.progress = progress
        self.message = message
    }
}

// MARK: - Workflow Orchestration (High-Level User Story)

/// Protocol for coordinating complete capture-to-GIF workflow
/// Maps to user story steps 2-5:
/// - User taps capture → frames captured → processing stages → Photos save
@available(iOS 26.0, *)
public protocol CaptureWorkflowCoordinator: Sendable {
    /// Start complete workflow from capture to Photos save
    /// - Parameter config: Workflow configuration (frame count, palette strategy, etc.)
    /// - Returns: Handle for monitoring workflow progress
    func startWorkflow(config: WorkflowConfiguration) async throws -> WorkflowHandle

    /// Cancel running workflow
    func cancelWorkflow(_ handle: WorkflowHandle) async

    /// Current workflow stage (for immediate UI queries)
    var currentStage: WorkflowStage { get async }

    /// Real-time progress stream for UI updates
    var stageStream: AsyncStream<WorkflowStage> { get }
}

/// Workflow configuration
@available(iOS 26.0, *)
public struct WorkflowConfiguration: Sendable {
    public let frameCount: Int               // 80 or 128
    public let targetDimension: Int          // Output size (e.g., 256)
    public let paletteStrategy: PaletteStrategy
    public let saveToCameraRoll: Bool
    public let generateThumbnails: Bool

    public init(frameCount: Int, targetDimension: Int, paletteStrategy: PaletteStrategy,
                saveToCameraRoll: Bool = true, generateThumbnails: Bool = true) {
        self.frameCount = frameCount
        self.targetDimension = targetDimension
        self.paletteStrategy = paletteStrategy
        self.saveToCameraRoll = saveToCameraRoll
        self.generateThumbnails = generateThumbnails
    }
}

/// Palette strategy for GIP/GIX composition
@available(iOS 26.0, *)
public enum PaletteStrategy: Sendable, Equatable {
    case global                                      // One palette for all frames
    case perFrame                                    // Unique palette per frame
    case hybrid(maxOverrides: Int, errorThreshold: Double)  // Global + selective overrides
}

/// Handle for tracking workflow
@available(iOS 26.0, *)
public struct WorkflowHandle: Sendable, Equatable {
    public let id: String
    public let startedAt: Date

    public init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

/// Workflow stages mapped to user story
@available(iOS 26.0, *)
public enum WorkflowStage: Sendable, Equatable {
    case idle
    case capturingFrames(current: Int, total: Int)
    case downsamplingFrames(current: Int, total: Int, timeRemainingMs: Int?)
    case extractingColors(progress: Double, framesProcessed: Int, totalFrames: Int)
    case buildingGlobalPalette(progress: Double, colorsFound: Int)
    case generatingGIP(progress: Double, palettesWritten: Int)   // Creating GIP palette file
    case generatingGIX(progress: Double, framesWritten: Int)     // Creating GIX index file
    case muxingGIF(progress: Double, bytesWritten: Int)          // Merging GIP + GIX → GIF
    case savingToPhotos(progress: Double)
    case complete(result: WorkflowResult)
    case failed(error: Error)

    public static func == (lhs: WorkflowStage, rhs: WorkflowStage) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.capturingFrames(let l1, let l2), .capturingFrames(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.downsamplingFrames(let l1, let l2, let l3), .downsamplingFrames(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.extractingColors(let l1, let l2, let l3), .extractingColors(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.buildingGlobalPalette(let l1, let l2), .buildingGlobalPalette(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.generatingGIP(let l1, let l2), .generatingGIP(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.generatingGIX(let l1, let l2), .generatingGIX(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.muxingGIF(let l1, let l2), .muxingGIF(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.savingToPhotos(let l1), .savingToPhotos(let r1)):
            return l1 == r1
        case (.complete, .complete): return true
        case (.failed, .failed): return true
        default: return false
        }
    }
}

/// Workflow completion result
@available(iOS 26.0, *)
public struct WorkflowResult: Sendable {
    public let gifURL: URL
    public let gipURL: URL
    public let gixURL: URL
    public let photosAssetID: String?
    public let metadata: WorkflowMetadata

    public init(gifURL: URL, gipURL: URL, gixURL: URL, photosAssetID: String?, metadata: WorkflowMetadata) {
        self.gifURL = gifURL
        self.gipURL = gipURL
        self.gixURL = gixURL
        self.photosAssetID = photosAssetID
        self.metadata = metadata
    }
}

/// Workflow metadata for analytics/debugging
@available(iOS 26.0, *)
public struct WorkflowMetadata: Sendable {
    public let frameCount: Int
    public let dimension: Int
    public let paletteSize: Int
    public let totalProcessingTimeMs: Double
    public let gifFileSizeBytes: Int
    public let captureStartedAt: Date
    public let captureCompletedAt: Date

    public init(frameCount: Int, dimension: Int, paletteSize: Int, totalProcessingTimeMs: Double,
                gifFileSizeBytes: Int, captureStartedAt: Date, captureCompletedAt: Date) {
        self.frameCount = frameCount
        self.dimension = dimension
        self.paletteSize = paletteSize
        self.totalProcessingTimeMs = totalProcessingTimeMs
        self.gifFileSizeBytes = gifFileSizeBytes
        self.captureStartedAt = captureStartedAt
        self.captureCompletedAt = captureCompletedAt
    }
}

// MARK: - GIP/GIX Split Format Composition

/// Protocol for composing GIP (palette) + GIX (index) split format files
/// Enables visibility into GIP/GIX file creation (user story step 4)
@available(iOS 26.0, *)
public protocol SplitFormatComposer: Sendable {
    /// Compose GIP and GIX files from quantized frames
    /// - Parameters:
    ///   - frames: Array of quantized frames with palettes
    ///   - strategy: Palette strategy (global, per-frame, hybrid)
    ///   - outputDirectory: Directory for GIP/GIX files
    /// - Returns: Composition result with URLs
    func compose(frames: [QuantizationResult], strategy: PaletteStrategy, outputDirectory: URL) async throws -> CompositionResult

    /// Real-time composition progress
    var compositionProgress: AsyncStream<CompositionProgress> { get }
}

/// Composition progress stages
@available(iOS 26.0, *)
public enum CompositionProgress: Sendable, Equatable {
    case analyzingPalettes(frameIndex: Int, totalFrames: Int)
    case buildingGlobalPalette(progress: Double)
    case writingGIPHeader(paletteCount: Int)
    case writingGIPPalette(paletteIndex: Int, totalPalettes: Int)
    case writingGIXHeader(frameCount: Int)
    case writingGIXFrame(frameIndex: Int, totalFrames: Int, bytesWritten: Int)
    case complete

    public static func == (lhs: CompositionProgress, rhs: CompositionProgress) -> Bool {
        switch (lhs, rhs) {
        case (.analyzingPalettes(let l1, let l2), .analyzingPalettes(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.buildingGlobalPalette(let l), .buildingGlobalPalette(let r)):
            return l == r
        case (.writingGIPHeader(let l), .writingGIPHeader(let r)):
            return l == r
        case (.writingGIPPalette(let l1, let l2), .writingGIPPalette(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.writingGIXHeader(let l), .writingGIXHeader(let r)):
            return l == r
        case (.writingGIXFrame(let l1, let l2, let l3), .writingGIXFrame(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.complete, .complete): return true
        default: return false
        }
    }
}

/// Result of GIP/GIX composition
@available(iOS 26.0, *)
public struct CompositionResult: Sendable {
    public let gipURL: URL              // Palette file
    public let gixURL: URL              // Index file
    public let gifURL: URL              // Merged GIF (if requested)
    public let paletteCount: Int        // Number of palettes in GIP
    public let frameCount: Int          // Number of frames in GIX
    public let gipFileSizeBytes: Int
    public let gixFileSizeBytes: Int

    public init(gipURL: URL, gixURL: URL, gifURL: URL, paletteCount: Int, frameCount: Int,
                gipFileSizeBytes: Int, gixFileSizeBytes: Int) {
        self.gipURL = gipURL
        self.gixURL = gixURL
        self.gifURL = gifURL
        self.paletteCount = paletteCount
        self.frameCount = frameCount
        self.gipFileSizeBytes = gipFileSizeBytes
        self.gixFileSizeBytes = gixFileSizeBytes
    }
}

// MARK: - Gallery Data Management

/// Protocol for gallery data source (user story step 6)
/// Provides list of saved GIFs and metadata
@available(iOS 26.0, *)
public protocol GalleryDataSource: Sendable {
    /// Fetch all saved GIF captures
    /// - Returns: Array of GIF metadata sorted by creation date (newest first)
    func fetchGallery() async throws -> [GIFMetadata]

    /// Fetch specific GIF metadata by ID
    func metadata(for id: String) async throws -> GIFMetadata

    /// Get thumbnail image for gallery grid
    /// - Parameter id: GIF identifier
    /// - Returns: Thumbnail image (typically first frame)
    func thumbnail(for id: String) async throws -> CGImage

    /// Get full GIF data for playback
    func gifData(for id: String) async throws -> Data

    /// Delete GIF and associated files (GIP, GIX)
    func delete(id: String) async throws
}

/// GIF metadata for gallery display
@available(iOS 26.0, *)
public struct GIFMetadata: Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let title: String?
    public let frameCount: Int
    public let dimension: Int           // 80, 128, or 256
    public let paletteSize: Int
    public let paletteStrategy: String  // "global", "perFrame", "hybrid"
    public let gifURL: URL
    public let gipURL: URL?
    public let gixURL: URL?
    public let gifFileSizeBytes: Int
    public let photosAssetID: String?

    public init(id: String, createdAt: Date, title: String?, frameCount: Int, dimension: Int,
                paletteSize: Int, paletteStrategy: String, gifURL: URL, gipURL: URL?, gixURL: URL?,
                gifFileSizeBytes: Int, photosAssetID: String?) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.frameCount = frameCount
        self.dimension = dimension
        self.paletteSize = paletteSize
        self.paletteStrategy = paletteStrategy
        self.gifURL = gifURL
        self.gipURL = gipURL
        self.gixURL = gixURL
        self.gifFileSizeBytes = gifFileSizeBytes
        self.photosAssetID = photosAssetID
    }
}

// MARK: - Progress Notification

/// Protocol for UI progress notifications
/// Decouples progress reporting from UI implementation
@available(iOS 26.0, *)
public protocol ProgressNotifier: Sendable {
    /// Notify generic progress update
    /// - Parameters:
    ///   - stage: Stage name (e.g., "Downsampling", "Building Palette")
    ///   - progress: Progress value 0.0-1.0
    ///   - details: Optional detailed message
    func notify(stage: String, progress: Double, details: String?) async

    /// Notify processing milestone reached
    /// - Parameter milestone: Milestone event (GIP created, GIX created, etc.)
    func notifyMilestone(_ milestone: ProcessingMilestone) async

    /// Notify error occurred
    func notifyError(_ error: Error, context: String) async
}

/// Processing milestones for user notifications
@available(iOS 26.0, *)
public enum ProcessingMilestone: Sendable, Equatable {
    case captureStarted(frameCount: Int)
    case captureComplete(frameCount: Int, durationMs: Double)
    case downsamplingComplete(frameCount: Int, avgTimePerFrameMs: Double)
    case globalPaletteBuilt(paletteSize: Int, uniqueColors: Int)
    case gipFileCreated(url: URL, paletteCount: Int, fileSizeBytes: Int)
    case gixFileCreated(url: URL, frameCount: Int, fileSizeBytes: Int)
    case gifMuxed(url: URL, frameCount: Int, fileSizeBytes: Int)
    case savedToPhotos(assetID: String)
    case workflowComplete(totalTimeMs: Double)

    public static func == (lhs: ProcessingMilestone, rhs: ProcessingMilestone) -> Bool {
        switch (lhs, rhs) {
        case (.captureStarted(let l), .captureStarted(let r)):
            return l == r
        case (.captureComplete(let l1, let l2), .captureComplete(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.downsamplingComplete(let l1, let l2), .downsamplingComplete(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.globalPaletteBuilt(let l1, let l2), .globalPaletteBuilt(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.gipFileCreated(let l1, let l2, let l3), .gipFileCreated(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.gixFileCreated(let l1, let l2, let l3), .gixFileCreated(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.gifMuxed(let l1, let l2, let l3), .gifMuxed(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.savedToPhotos(let l), .savedToPhotos(let r)):
            return l == r
        case (.workflowComplete(let l), .workflowComplete(let r)):
            return l == r
        default: return false
        }
    }
}
