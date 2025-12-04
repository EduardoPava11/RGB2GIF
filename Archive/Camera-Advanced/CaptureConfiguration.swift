//
//  CaptureConfiguration.swift
//  RGB2GIF
//
//  Production-oriented capture configuration for 80³ and 128³ voxel cubes
//  Manages cube sizes, frame counts, FPS, and palette selection
//
//  Architecture:
//  - NV12 input from AVFoundation (Y-plane only, no conversion)
//  - Metal downsample to 80×80 or 128×128
//  - Palette LUT application for live preview
//  - GIX frame writing with rawIndices encoding
//  - GIP palette management with content-addressed hashing
//

import Foundation
import AVFoundation

@available(iOS 26.0, *)
public enum CubeSize: String, Codable, CaseIterable {
    case s80 = "80"
    case s128 = "128"

    public var dimension: Int {
        switch self {
        case .s80: return 80
        case .s128: return 128
        }
    }

    public var frameCount: Int {
        // Cube depth matches spatial dimensions (80³ or 128³)
        return dimension
    }

    /// Recommended FPS for smooth capture
    public var recommendedFPS: Int {
        switch self {
        case .s80: return 30   // 80 frames @ 30fps = 2.67 seconds
        case .s128: return 60  // 128 frames @ 60fps = 2.13 seconds
        }
    }

    /// Target capture duration in seconds
    public var captureDuration: Double {
        return Double(frameCount) / Double(recommendedFPS)
    }
}

@available(iOS 26.0, *)
public struct TemporalCubeConfiguration {

    // MARK: - Cube Specifications

    public let cubeSize: CubeSize
    public let paletteExp: UInt8       // 6 for 128 colors, 7 for 256 colors

    // MARK: - Timing & FPS

    public let targetFPS: Int
    public let frameCount: Int         // Derived from cube size

    /// Frame duration for AVCaptureDevice.activeVideoMinFrameDuration
    public var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(targetFPS))
    }

    // MARK: - Palette Selection

    public let gipURL: URL             // Path to GIP palette pack
    public let paletteRef: UInt32      // Index into GIP.palettes[]

    /// Support for mid-capture palette switching
    public let allowPaletteSwitching: Bool

    // MARK: - GIX Encoding Options

    public enum DataEncoding {
        case rawIndices         // Fast capture, no compression
        case lzwSubblocks      // Offline compression after capture
    }

    public let initialEncoding: DataEncoding

    /// Convert to LZW after capture completes (async, saves storage)
    public let compressAfterCapture: Bool

    // MARK: - GIF Export Options

    public let loopCount: UInt16?      // nil = no loop, 0 = loop forever, N = loop N times
    public let defaultDelay: UInt16    // Centiseconds (10 = 100ms = 10 FPS)
    public let disposal: UInt8         // GIF disposal method (0-3)

    // MARK: - Advanced Options

    public let enableInterlace: Bool   // GIF interlace flag (false for cubes)
    public let enableTransparency: Bool // Transparency support
    public let transparentIndex: UInt8? // Index to treat as transparent

    // MARK: - Presets

    /// Standard 80³ cube with 256-color palette
    public static func standard80() -> TemporalCubeConfiguration {
        TemporalCubeConfiguration(
            cubeSize: .s80,
            paletteExp: 7,  // 256 colors
            targetFPS: 30,
            frameCount: 80,
            gipURL: URL(fileURLWithPath: ""), // To be set by caller
            paletteRef: 0,
            allowPaletteSwitching: false,
            initialEncoding: .rawIndices,
            compressAfterCapture: true,
            loopCount: 0,   // Loop forever
            defaultDelay: 3, // 33 FPS playback (30ms)
            disposal: 1,     // Do not dispose
            enableInterlace: false,
            enableTransparency: false,
            transparentIndex: nil
        )
    }

    /// Standard 128³ cube with 256-color palette
    public static func standard128() -> TemporalCubeConfiguration {
        TemporalCubeConfiguration(
            cubeSize: .s128,
            paletteExp: 7,  // 256 colors
            targetFPS: 60,
            frameCount: 128,
            gipURL: URL(fileURLWithPath: ""), // To be set by caller
            paletteRef: 0,
            allowPaletteSwitching: false,
            initialEncoding: .rawIndices,
            compressAfterCapture: true,
            loopCount: 0,   // Loop forever
            defaultDelay: 2, // 50 FPS playback (20ms)
            disposal: 1,     // Do not dispose
            enableInterlace: false,
            enableTransparency: false,
            transparentIndex: nil
        )
    }

    /// High-quality 128³ cube with 256-color palette and slower playback
    public static func highQuality128() -> TemporalCubeConfiguration {
        TemporalCubeConfiguration(
            cubeSize: .s128,
            paletteExp: 7,  // 256 colors
            targetFPS: 60,
            frameCount: 128,
            gipURL: URL(fileURLWithPath: ""),
            paletteRef: 0,
            allowPaletteSwitching: true,  // Allow creative effects
            initialEncoding: .rawIndices,
            compressAfterCapture: true,
            loopCount: 0,
            defaultDelay: 5, // 20 FPS playback (50ms) for smoother viewing
            disposal: 2,     // Restore to background
            enableInterlace: false,
            enableTransparency: false,
            transparentIndex: nil
        )
    }

    /// Fast 80³ cube with 128-color palette for real-time performance
    public static func fast80() -> TemporalCubeConfiguration {
        TemporalCubeConfiguration(
            cubeSize: .s80,
            paletteExp: 6,  // 128 colors (smaller LUT, faster)
            targetFPS: 30,
            frameCount: 80,
            gipURL: URL(fileURLWithPath: ""),
            paletteRef: 0,
            allowPaletteSwitching: false,
            initialEncoding: .rawIndices,
            compressAfterCapture: false,  // Skip compression for speed
            loopCount: 0,
            defaultDelay: 3,
            disposal: 0,     // No disposal specified
            enableInterlace: false,
            enableTransparency: false,
            transparentIndex: nil
        )
    }

    // MARK: - Validation

    /// Validate configuration for capture
    public func validate() throws {
        // Palette exponent must be 1-7 (2-256 colors)
        guard paletteExp >= 1 && paletteExp <= 7 else {
            throw ConfigurationError.invalidPaletteExp(paletteExp)
        }

        // Target FPS must be positive and reasonable
        guard targetFPS > 0 && targetFPS <= 120 else {
            throw ConfigurationError.invalidFPS(targetFPS)
        }

        // Frame count must match cube size
        guard frameCount == cubeSize.frameCount else {
            throw ConfigurationError.frameCountMismatch(expected: cubeSize.frameCount, got: frameCount)
        }

        // GIP file must exist if not switching palettes
        if !allowPaletteSwitching && !FileManager.default.fileExists(atPath: gipURL.path) {
            throw ConfigurationError.gipFileNotFound(gipURL)
        }

        // Disposal method must be 0-3
        guard disposal <= 3 else {
            throw ConfigurationError.invalidDisposal(disposal)
        }

        // Transparent index must be valid for palette size
        if let transparentIdx = transparentIndex {
            let paletteSize = 1 << (Int(paletteExp) + 1)
            guard transparentIdx < paletteSize else {
                throw ConfigurationError.invalidTransparentIndex(transparentIdx, paletteSize: paletteSize)
            }
        }
    }

    // MARK: - AVFoundation Setup

    /// Configure AVCaptureDevice for deterministic frame capture
    /// Reference: Apple TN2445 (AVCaptureDevice pixel formats and frame durations)
    public func configureAVCaptureDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Set active format to one that supports NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        // Note: Actual format selection requires iterating device.formats
        // This is a placeholder for the configuration logic

        // Set frame duration for deterministic timing
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        // Calculate expected capture duration
        let expectedDuration = Double(frameCount) / Double(targetFPS)

        print("📹 AVCaptureDevice configured:")
        print("   Frame duration: \(frameDuration.seconds)s (\(targetFPS) FPS)")
        print("   Expected capture time: \(String(format: "%.2f", expectedDuration))s for \(frameCount) frames")
    }

    /// Configure AVCaptureVideoDataOutput for NV12 pixel format
    /// Reference: Apple TN2445 (Pixel format recommendations)
    public func configureVideoDataOutput(_ output: AVCaptureVideoDataOutput) {
        // Request NV12 (bi-planar 4:2:0 YUV)
        // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = 875704422 ('420f')
        // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = 875704438 ('420v')

        // Use full range for better grayscale preservation
        let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat)
        ]

        print("📹 AVCaptureVideoDataOutput configured:")
        print("   Pixel format: NV12 (420YpCbCr8BiPlanarFullRange)")
        print("   Y-plane: direct Metal texture access (.r8Unorm)")
    }

    // MARK: - Metal LUT Generation

    /// LUT generation strategy for grayscale → palette index mapping
    public enum LUTStrategy {
        case direct             // LUT[y] = y >> (8 - (paletteExp+1))
        case luminanceBased     // Sort palette by luminance, map Y to nearest
        case histogramMatched   // Learn LUT from sample image
    }

    /// Generate 256-byte LUT for Y → palette index mapping
    public func generateLUT(
        from gip: GIP,
        paletteIndex: Int,
        strategy: LUTStrategy = .luminanceBased
    ) -> [UInt8] {
        guard paletteIndex < gip.palettes.count else {
            // Return identity LUT as fallback instead of crashing
            // This should never happen with proper validation, but graceful degradation is better
            assertionFailure("Palette index \(paletteIndex) out of range (GIP has \(gip.palettes.count) palettes)")
            return (0..<256).map { UInt8($0) }
        }

        let palette = gip.palettes[paletteIndex]
        let paletteSize = Int(palette.entryCount)

        var lut = [UInt8](repeating: 0, count: 256)

        switch strategy {
        case .direct:
            // Simple bit-shift mapping
            let shift = 8 - (Int(paletteExp) + 1)
            for y in 0..<256 {
                lut[y] = UInt8(min(y >> shift, paletteSize - 1))
            }

        case .luminanceBased:
            // Sort palette by luminance and map Y to nearest
            let luminances = palette.rgb.map { rgb in
                // Rec.709 luminance: Y = 0.2126*R + 0.7152*G + 0.0722*B
                let r = Double(rgb[0])
                let g = Double(rgb[1])
                let b = Double(rgb[2])
                return 0.2126 * r + 0.7152 * g + 0.0722 * b
            }

            // Sort palette indices by luminance
            _ = luminances.enumerated()
                .sorted { $0.element < $1.element }
                .map { $0.offset }  // Unused sortedIndices removed

            // Map each Y value to nearest luminance bucket
            for y in 0..<256 {
                let targetLuminance = Double(y)
                var closestIndex = 0
                var closestDistance = Double.infinity

                for (paletteIdx, luminance) in luminances.enumerated() {
                    let distance = abs(luminance - targetLuminance)
                    if distance < closestDistance {
                        closestDistance = distance
                        closestIndex = paletteIdx
                    }
                }

                lut[y] = UInt8(closestIndex)
            }

        case .histogramMatched:
            // TODO: Implement histogram matching
            // For now, fall back to luminance-based
            return generateLUT(from: gip, paletteIndex: paletteIndex, strategy: .luminanceBased)
        }

        return lut
    }

    // MARK: - Errors

    public enum ConfigurationError: Error, CustomStringConvertible {
        case invalidPaletteExp(UInt8)
        case invalidFPS(Int)
        case frameCountMismatch(expected: Int, got: Int)
        case gipFileNotFound(URL)
        case invalidDisposal(UInt8)
        case invalidTransparentIndex(UInt8, paletteSize: Int)

        public var description: String {
            switch self {
            case .invalidPaletteExp(let exp):
                return "Invalid palette exponent: \(exp) (must be 1-7 for 2-256 colors)"
            case .invalidFPS(let fps):
                return "Invalid FPS: \(fps) (must be 1-120)"
            case .frameCountMismatch(let expected, let got):
                return "Frame count mismatch: expected \(expected) for cube size, got \(got)"
            case .gipFileNotFound(let url):
                return "GIP file not found: \(url.path)"
            case .invalidDisposal(let disposal):
                return "Invalid disposal method: \(disposal) (must be 0-3)"
            case .invalidTransparentIndex(let idx, let paletteSize):
                return "Invalid transparent index: \(idx) (palette size: \(paletteSize))"
            }
        }
    }
}
