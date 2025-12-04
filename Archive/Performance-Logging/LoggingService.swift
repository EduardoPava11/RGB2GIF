//
//  LoggingService.swift
//  RGB2GIF
//
//  Structured logging service using os.log for the RGB2GIF pipeline
//  Provides comprehensive logging at each pipeline step
//

import Foundation
import os.log
import CoreVideo

/// Structured logging service for RGB2GIF pipeline
@available(iOS 14.0, *)
final class RGB2GIFLogger {

    // MARK: - Singleton

    static let shared = RGB2GIFLogger()

    // MARK: - Properties

    private let subsystem = "com.rgb2gif"

    // Category-specific loggers
    let camera: Logger
    let downsampler: Logger
    let quantizer: Logger
    let lzwEncoder: Logger
    let gifMuxer: Logger
    let validator: Logger
    let pipeline: Logger

    // MARK: - Initialization

    private init() {
        self.camera = Logger(subsystem: subsystem, category: "camera")
        self.downsampler = Logger(subsystem: subsystem, category: "downsampler")
        self.quantizer = Logger(subsystem: subsystem, category: "quantizer")
        self.lzwEncoder = Logger(subsystem: subsystem, category: "lzwEncoder")
        self.gifMuxer = Logger(subsystem: subsystem, category: "gifMuxer")
        self.validator = Logger(subsystem: subsystem, category: "validator")
        self.pipeline = Logger(subsystem: subsystem, category: "pipeline")
    }

    // MARK: - Pipeline Logging

    /// Log pipeline start with session ID
    func logPipelineStart(sessionID: String) {
        pipeline.info("🚀 Pipeline started - Session: \(sessionID)")
    }

    /// Log individual pipeline step with timing
    func logPipelineStep(step: String, duration: TimeInterval, success: Bool) {
        let status = success ? "✅" : "❌"
        let durationMs = Int(duration * 1000)
        pipeline.info("\(status) \(step) completed in \(durationMs)ms")
    }

    /// Log pipeline completion with total duration and frame count
    func logPipelineComplete(totalDuration: TimeInterval, frameCount: Int) {
        let durationMs = Int(totalDuration * 1000)
        pipeline.info("🎉 Pipeline complete - \(frameCount) frames in \(durationMs)ms")
    }

    /// Log error with context
    func logError(_ error: RGB2GIFError, context: String) {
        pipeline.error("❌ Error in \(context): \(error.description)")
    }

    // MARK: - Camera Logging

    func logCameraCapture(frameIndex: Int, pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        camera.debug("📷 Captured frame \(frameIndex): \(width)×\(height)")
    }

    func logCameraConfiguration(targetSize: Int) {
        camera.info("⚙️ Camera configured for \(targetSize)×\(targetSize) capture")
    }

    // MARK: - Downsampler Logging

    func logDownsampleStart(inputSize: CGSize, outputSize: Int) {
        downsampler.debug("⬇️ Downsampling from \(Int(inputSize.width))×\(Int(inputSize.height)) to \(outputSize)×\(outputSize)")
    }

    func logDownsampleComplete(outputSize: Int, duration: TimeInterval) {
        let durationMs = Int(duration * 1000)
        downsampler.info("✅ Downsampled to \(outputSize)×\(outputSize) in \(durationMs)ms")
    }

    // MARK: - Quantizer Logging

    func logQuantizationStart(paletteSize: Int) {
        quantizer.debug("🎨 Starting quantization to \(paletteSize) colors")
    }

    func logQuantizationComplete(paletteSize: Int, uniqueColors: Int, duration: TimeInterval) {
        let durationMs = Int(duration * 1000)
        quantizer.info("✅ Quantized \(uniqueColors) unique colors to \(paletteSize)-color palette in \(durationMs)ms")
    }

    func logColorDistribution(histogram: [Int: Int]) {
        let topColors = histogram.sorted { $0.value > $1.value }.prefix(5)
        let distribution = topColors.map { "idx\($0.key): \($0.value)px" }.joined(separator: ", ")
        quantizer.debug("📊 Top colors: \(distribution)")
    }

    // MARK: - LZW Encoder Logging

    func logLZWEncodeStart(frame: Int, width: Int, height: Int, minCodeSize: UInt8) {
        lzwEncoder.debug("🗜️ Encoding frame \(frame) (\(width)×\(height), minCodeSize=\(minCodeSize))")
    }

    func logLZWEncodeComplete(frame: Int, inputBytes: Int, outputBytes: Int, duration: TimeInterval) {
        let durationMs = Int(duration * 1000)
        let ratio = Double(inputBytes) / Double(outputBytes)
        lzwEncoder.info("✅ Frame \(frame) encoded: \(inputBytes)→\(outputBytes) bytes (ratio: \(String(format: "%.2f", ratio)):1) in \(durationMs)ms")
    }

    // MARK: - GIF Muxer Logging

    func logMuxingStart(frameCount: Int, paletteSize: Int, dimensions: Int) {
        gifMuxer.info("📦 Muxing \(frameCount) frames with \(paletteSize)-color palette (\(dimensions)×\(dimensions))")
    }

    func logMuxingProgress(frame: Int, totalFrames: Int) {
        if frame % 10 == 0 || frame == totalFrames - 1 {
            gifMuxer.debug("⏳ Muxing progress: \(frame + 1)/\(totalFrames)")
        }
    }

    func logMuxingComplete(outputSize: Int, duration: TimeInterval) {
        let durationMs = Int(duration * 1000)
        let sizeMB = Double(outputSize) / (1024.0 * 1024.0)
        gifMuxer.info("✅ GIF muxed: \(String(format: "%.2f", sizeMB))MB in \(durationMs)ms")
    }

    // MARK: - Validator Logging

    func logValidationStart(fileSize: Int) {
        let sizeMB = Double(fileSize) / (1024.0 * 1024.0)
        validator.info("🔍 Validating GIF89a (\(String(format: "%.2f", sizeMB))MB)")
    }

    func logValidationCheck(check: String, passed: Bool) {
        let status = passed ? "✅" : "❌"
        validator.debug("\(status) \(check)")
    }

    func logValidationComplete(passed: Bool, errors: [String]) {
        if passed {
            validator.info("✅ GIF validation passed")
        } else {
            validator.error("❌ GIF validation failed: \(errors.joined(separator: "; "))")
        }
    }

    // MARK: - Container Logging

    func logGIPCreation(paletteSize: Int) {
        pipeline.info("📦 Created GIP2 container with \(paletteSize)-color palette")
    }

    func logGIXCreation(frameCount: Int, dimensions: Int, lzwCodeSize: UInt8) {
        pipeline.info("📦 Created GIX2 container: \(frameCount) frames, \(dimensions)×\(dimensions), LZW code size \(lzwCodeSize)")
    }
}

// MARK: - Convenience Extensions

@available(iOS 14.0, *)
extension RGB2GIFLogger {

    /// Measure and log execution time of a block
    func measure<T>(category: Logger, operation: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        category.debug("▶️ \(operation)...")
        defer {
            let duration = CFAbsoluteTimeGetCurrent() - start
            let durationMs = Int(duration * 1000)
            category.debug("⏱️ \(operation) took \(durationMs)ms")
        }
        return try block()
    }
}
