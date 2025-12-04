//
//  RGB2GIFErrors.swift
//  RGB2GIF
//
//  Centralized error handling for RGB2GIF pipeline
//  All errors use Swift Result types for proper error handling
//

import Foundation

/// Centralized error types for the RGB2GIF pipeline
enum RGB2GIFError: Error, CustomStringConvertible {

    // MARK: - Container Errors

    case invalidPaletteSize(got: Int, expected: Int = 256)
    case invalidDimensions(width: Int, height: Int, expected: Int = 80)
    case invalidLZWCodeSize(got: UInt8, expected: UInt8 = 8)

    // MARK: - Pipeline Errors

    case cameraCaptureFailed(underlying: Error?)
    case downsamplingFailed(stage: String, underlying: Error?)
    case quantizationFailed(underlying: Error?)
    case lzwEncodingFailed(frame: Int, underlying: Error?)
    case gifMuxingFailed(underlying: Error?)

    // MARK: - Validation Errors

    case gifValidationFailed(errors: [String])
    case containerValidationFailed(container: String, reason: String)

    // MARK: - Configuration Errors

    case unsupportedPaletteSize(size: Int)
    case unsupportedDimensions(width: Int, height: Int)

    // MARK: - CustomStringConvertible

    var description: String {
        switch self {
        // Container errors
        case .invalidPaletteSize(let got, let expected):
            return "Invalid palette size: got \(got) colors, expected \(expected)"
        case .invalidDimensions(let width, let height, let expected):
            return "Invalid dimensions: got \(width)×\(height), expected \(expected)×\(expected)"
        case .invalidLZWCodeSize(let got, let expected):
            return "Invalid LZW code size: got \(got), expected \(expected)"

        // Pipeline errors
        case .cameraCaptureFailed(let underlying):
            if let error = underlying {
                return "Camera capture failed: \(error.localizedDescription)"
            }
            return "Camera capture failed"
        case .downsamplingFailed(let stage, let underlying):
            if let error = underlying {
                return "Downsampling failed at \(stage): \(error.localizedDescription)"
            }
            return "Downsampling failed at \(stage)"
        case .quantizationFailed(let underlying):
            if let error = underlying {
                return "Color quantization failed: \(error.localizedDescription)"
            }
            return "Color quantization failed"
        case .lzwEncodingFailed(let frame, let underlying):
            if let error = underlying {
                return "LZW encoding failed at frame \(frame): \(error.localizedDescription)"
            }
            return "LZW encoding failed at frame \(frame)"
        case .gifMuxingFailed(let underlying):
            if let error = underlying {
                return "GIF muxing failed: \(error.localizedDescription)"
            }
            return "GIF muxing failed"

        // Validation errors
        case .gifValidationFailed(let errors):
            return "GIF validation failed: \(errors.joined(separator: ", "))"
        case .containerValidationFailed(let container, let reason):
            return "\(container) validation failed: \(reason)"

        // Configuration errors
        case .unsupportedPaletteSize(let size):
            return "Unsupported palette size: \(size). RGB2GIF only supports 256-color palettes"
        case .unsupportedDimensions(let width, let height):
            return "Unsupported dimensions: \(width)×\(height). RGB2GIF only supports 80×80 GIFs"
        }
    }
}

// MARK: - Result Type Aliases

typealias RGB2GIFResult<T> = Result<T, RGB2GIFError>

// MARK: - LocalizedError Conformance

extension RGB2GIFError: LocalizedError {
    var errorDescription: String? {
        return description
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - Pipeline Notifications
// ════════════════════════════════════════════════════════════════════════════

extension Notification.Name {
    /// Notification for pipeline log messages (used by OctreeColorQuantizer)
    static let capturePipelineLog = Notification.Name("com.rgb2gif.capturePipelineLog")
}
