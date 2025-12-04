//
//  RGB2GIFErrors.swift
//  RGB2GIF
//
//  Unified error types for MVP0 pipeline
//

import Foundation

/// All errors that can occur in the RGB2GIF pipeline
@available(iOS 26.0, *)
public enum RGB2GIFError: LocalizedError, Sendable {

    // MARK: - Camera Errors
    case cameraNotAuthorized
    case cameraSetupFailed(String)
    case captureSessionFailed

    // MARK: - Frame Errors
    case wrongFrameCount(got: Int, expected: Int)
    case frameResizeFailed
    case pixelExtractionFailed

    // MARK: - Quantization Errors
    case quantizationFailed(String)
    case paletteEmpty

    // MARK: - Compression Errors
    case compressionFailed(String)

    // MARK: - GIF Errors
    case gifWriteFailed(String)
    case fileCreationFailed(URL)

    // MARK: - Photos Errors
    case photosSaveFailed(String)
    case photosNotAuthorized

    // MARK: - CBOR Export Errors
    case cborExportFailed(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .cameraNotAuthorized:
            return "Camera access not authorized"
        case .cameraSetupFailed(let reason):
            return "Camera setup failed: \(reason)"
        case .captureSessionFailed:
            return "Capture session failed to start"
        case .wrongFrameCount(let got, let expected):
            return "Wrong frame count: got \(got), expected \(expected)"
        case .frameResizeFailed:
            return "Failed to resize frame to 81x81"
        case .pixelExtractionFailed:
            return "Failed to extract pixels from frame"
        case .quantizationFailed(let reason):
            return "Color quantization failed: \(reason)"
        case .paletteEmpty:
            return "Generated palette is empty"
        case .compressionFailed(let reason):
            return "LZW compression failed: \(reason)"
        case .gifWriteFailed(let reason):
            return "GIF writing failed: \(reason)"
        case .fileCreationFailed(let url):
            return "Failed to create file at: \(url.path)"
        case .photosSaveFailed(let reason):
            return "Failed to save to Photos: \(reason)"
        case .photosNotAuthorized:
            return "Photos access not authorized"
        case .cborExportFailed(let reason):
            return "CBOR export failed: \(reason)"
        }
    }
}
