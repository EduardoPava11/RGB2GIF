//
//  CBORFrameExporter.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  FRAME EXPORT - ALL STAGES (L0_raw, L1_cropped, L2_frames)              ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Exports frames at each pipeline stage for step-by-step debugging:       ║
//  ║  • L0_raw:     Original camera frames (BGRA, any size)                   ║
//  ║  • L1_cropped: Center-cropped squares (BGRA)                             ║
//  ║  • L2_frames:  Resized 81×81 RGB frames (explicit BGRA→RGB conversion)  ║
//  ║                                                                           ║
//  ║  Each stage includes CBOR data + PNG for visual verification.            ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import SwiftCBOR
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let frameLogger = Logger(subsystem: "com.rgb2gif", category: "CBORFrameExporter")

// MARK: - CBORFrameExporter

@available(iOS 26.0, *)
public final class CBORFrameExporter {

    // MARK: - Properties

    private let session: CBORSessionManager

    // MARK: - Initialization

    public init(session: CBORSessionManager) {
        self.session = session
    }

    // MARK: - Export Single Frame

    /// Export a single 81×81 frame to CBOR and PNG
    /// - Parameters:
    ///   - frame: The CGImage to export (must be exactly 81×81)
    ///   - index: Frame index (0-80)
    ///   - timestamp: Capture timestamp in milliseconds
    /// - Returns: Size of the exported CBOR file in bytes
    public func exportFrame(_ frame: CGImage, index: Int, timestamp: Int64 = 0) throws -> Int64 {
        guard frame.width == 81 && frame.height == 81 else {
            throw RGB2GIFError.cborExportFailed("Frame \(index) is \(frame.width)×\(frame.height), expected 81×81")
        }

        // Extract RGB bytes from CGImage
        let rgbData = try extractRGBData(from: frame)

        // Build CBOR structure
        let tensorLayer = index / 9  // Which temporal layer (0-8)
        let layerOffset = index % 9   // Offset within layer (0-8)
        let contributedCells = Self.contributedCells(for: index)

        let cbor: CBOR = .map([
            "index": .unsignedInt(UInt64(index)),
            "timestamp_ms": .unsignedInt(UInt64(timestamp)),
            "dimensions": .map([
                "width": .unsignedInt(81),
                "height": .unsignedInt(81)
            ]),
            "format": .utf8String("RGB8"),
            "tensor_layer": .unsignedInt(UInt64(tensorLayer)),
            "tensor_offset": .unsignedInt(UInt64(layerOffset)),
            "contributed_cells": .array(contributedCells.map { cell in
                .array([
                    .unsignedInt(UInt64(cell.t)),
                    .unsignedInt(UInt64(cell.y)),
                    .unsignedInt(UInt64(cell.x))
                ])
            }),
            "rgb_data": .byteString(Array(rgbData))
        ])

        // Write CBOR file
        let cborData = Data(cbor.encode())
        let cborURL = session.frameURL(index: index, extension: "cbor")
        try cborData.write(to: cborURL)

        // Write PNG for visual verification
        try exportPNG(from: frame, index: index)

        frameLogger.debug("Exported frame \(index): \(cborData.count) bytes CBOR")
        return Int64(cborData.count)
    }

    // MARK: - Export All Frames

    /// Export all 81 frames to CBOR and PNG files
    /// - Parameter frames: Array of exactly 81 CGImages (each 81×81)
    /// - Returns: Total bytes written
    public func exportAllFrames(_ frames: [CGImage]) throws -> Int64 {
        guard frames.count == 81 else {
            throw RGB2GIFError.cborExportFailed("Expected 81 frames, got \(frames.count)")
        }

        var totalBytes: Int64 = 0
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        for (index, frame) in frames.enumerated() {
            let frameTimestamp = timestamp + Int64(index * 33)  // ~30fps
            totalBytes += try exportFrame(frame, index: index, timestamp: frameTimestamp)
        }

        frameLogger.info("Exported all 81 frames: \(totalBytes) bytes total")
        return totalBytes
    }

    // MARK: - RGB Extraction

    /// Extract RGB bytes from CGImage (strips alpha)
    private func extractRGBData(from image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4  // BGRA
        let bytesPerRow = width * bytesPerPixel

        // Create bitmap context to draw the image
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw RGB2GIFError.cborExportFailed("Cannot create sRGB color space")
        }

        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw RGB2GIFError.cborExportFailed("Cannot create bitmap context")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert BGRA to RGB (strip alpha, swap B and R)
        var rgbData = Data(capacity: width * height * 3)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                // BGRA format: B=0, G=1, R=2, A=3
                let b = pixelData[offset]
                let g = pixelData[offset + 1]
                let r = pixelData[offset + 2]
                // Store as RGB
                rgbData.append(r)
                rgbData.append(g)
                rgbData.append(b)
            }
        }

        return rgbData
    }

    // MARK: - PNG Export

    /// Export frame as PNG for visual verification
    private func exportPNG(from image: CGImage, index: Int) throws {
        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: image)
        guard let pngData = uiImage.pngData() else {
            throw RGB2GIFError.cborExportFailed("Failed to create PNG data for frame \(index)")
        }
        let pngURL = session.frameURL(index: index, extension: "png")
        try pngData.write(to: pngURL)
        #else
        // macOS fallback - skip PNG export
        frameLogger.warning("PNG export skipped on non-UIKit platform")
        #endif
    }

    // MARK: - Tensor Cell Mapping

    /// Cell coordinate (t, y, x)
    public struct CellCoord {
        public let t: Int  // Temporal layer (0-8)
        public let y: Int  // Spatial Y (0-8)
        public let x: Int  // Spatial X (0-8)

        /// Linear index: t * 81 + y * 9 + x
        public var linearIndex: Int { t * 81 + y * 9 + x }
    }

    /// Which tensor cells does this frame contribute to?
    /// Each frame contributes to 81 cells (all cells in its temporal layer)
    public static func contributedCells(for frameIndex: Int) -> [CellCoord] {
        let t = frameIndex / 9  // Temporal layer

        var cells: [CellCoord] = []
        cells.reserveCapacity(81)

        for y in 0..<9 {
            for x in 0..<9 {
                cells.append(CellCoord(t: t, y: y, x: x))
            }
        }

        return cells
    }

    /// Tensor layer (0-8) for a given frame
    public static func tensorLayer(for frameIndex: Int) -> Int {
        frameIndex / 9
    }

    /// Offset within temporal layer (0-8)
    public static func layerOffset(for frameIndex: Int) -> Int {
        frameIndex % 9
    }
}

// MARK: - Frame Statistics

@available(iOS 26.0, *)
extension CBORFrameExporter {

    /// Compute statistics for a frame's RGB data
    public struct FrameStats {
        public let index: Int
        public let meanR: Double
        public let meanG: Double
        public let meanB: Double
        public let stdDevR: Double
        public let stdDevG: Double
        public let stdDevB: Double
        public let uniqueColors: Int
    }

    /// Compute statistics for a frame
    public func computeStats(for frame: CGImage, index: Int) throws -> FrameStats {
        let rgbData = try extractRGBData(from: frame)
        let pixelCount = rgbData.count / 3

        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var uniqueColors = Set<UInt32>()

        for i in 0..<pixelCount {
            let r = Double(rgbData[i * 3])
            let g = Double(rgbData[i * 3 + 1])
            let b = Double(rgbData[i * 3 + 2])

            sumR += r
            sumG += g
            sumB += b

            let color = (UInt32(rgbData[i * 3]) << 16) |
                        (UInt32(rgbData[i * 3 + 1]) << 8) |
                        UInt32(rgbData[i * 3 + 2])
            uniqueColors.insert(color)
        }

        let meanR = sumR / Double(pixelCount)
        let meanG = sumG / Double(pixelCount)
        let meanB = sumB / Double(pixelCount)

        // Compute standard deviation
        var varR: Double = 0
        var varG: Double = 0
        var varB: Double = 0

        for i in 0..<pixelCount {
            let r = Double(rgbData[i * 3])
            let g = Double(rgbData[i * 3 + 1])
            let b = Double(rgbData[i * 3 + 2])

            varR += (r - meanR) * (r - meanR)
            varG += (g - meanG) * (g - meanG)
            varB += (b - meanB) * (b - meanB)
        }

        let stdDevR = sqrt(varR / Double(pixelCount))
        let stdDevG = sqrt(varG / Double(pixelCount))
        let stdDevB = sqrt(varB / Double(pixelCount))

        return FrameStats(
            index: index,
            meanR: meanR,
            meanG: meanG,
            meanB: meanB,
            stdDevR: stdDevR,
            stdDevG: stdDevG,
            stdDevB: stdDevB,
            uniqueColors: uniqueColors.count
        )
    }
}

// MARK: - L0_raw Export (Original Camera Frames)

@available(iOS 26.0, *)
extension CBORFrameExporter {

    /// Export a raw camera frame to L0_raw (original size, BGRA format)
    /// - Parameters:
    ///   - frame: Original camera CGImage (any size, BGRA format)
    ///   - index: Frame index (0-80)
    ///   - timestamp: Capture timestamp in milliseconds
    /// - Returns: Size of the exported CBOR file in bytes
    public func exportRawFrame(_ frame: CGImage, index: Int, timestamp: Int64 = 0) throws -> Int64 {
        // Extract BGRA bytes directly from the CGImage
        let bgraData = try extractBGRAData(from: frame)

        // Store the actual bytesPerRow - camera buffers may have padding for alignment
        let actualBytesPerRow = frame.bytesPerRow

        let cbor: CBOR = .map([
            "stage": .utf8String("L0_raw"),
            "index": .unsignedInt(UInt64(index)),
            "timestamp_ms": .unsignedInt(UInt64(timestamp)),
            "dimensions": .map([
                "width": .unsignedInt(UInt64(frame.width)),
                "height": .unsignedInt(UInt64(frame.height))
            ]),
            "format": .utf8String("BGRA8"),
            "bytes_per_pixel": .unsignedInt(4),
            "bytes_per_row": .unsignedInt(UInt64(actualBytesPerRow)),  // NEW: Store actual stride
            "bgra_data": .byteString(Array(bgraData))
        ])

        let cborData = Data(cbor.encode())
        let cborURL = session.l0RawURL.appendingPathComponent(rawFileName(index: index, extension: "cbor"))
        try cborData.write(to: cborURL)

        // Write PNG for visual verification
        try exportRawPNG(from: frame, index: index)

        frameLogger.debug("L0_raw: Exported frame \(index) (\(frame.width)×\(frame.height)): \(cborData.count) bytes")
        return Int64(cborData.count)
    }

    /// Export all raw camera frames to L0_raw
    public func exportAllRawFrames(_ frames: [CGImage]) throws -> Int64 {
        guard frames.count == 81 else {
            throw RGB2GIFError.cborExportFailed("Expected 81 raw frames, got \(frames.count)")
        }

        var totalBytes: Int64 = 0
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        for (index, frame) in frames.enumerated() {
            let frameTimestamp = timestamp + Int64(index * 33)
            totalBytes += try exportRawFrame(frame, index: index, timestamp: frameTimestamp)
        }

        frameLogger.info("L0_raw: Exported all 81 raw frames: \(totalBytes) bytes total")
        return totalBytes
    }

    /// Extract BGRA bytes from a CGImage (for L0_raw and L1_cropped)
    ///
    /// ## IMPORTANT NOTE
    /// `CGImage.cropping(to:)` creates an image that shares pixel data with the original.
    /// Calling `dataProvider.data` on a cropped image returns the FULL original data.
    /// For cropped images, we must draw to a new context to get the correct pixel subset.
    ///
    /// - Parameter image: Source CGImage
    /// - Parameter isCropped: If true, the image was created via `.cropping()` and needs re-rendering
    private func extractBGRAData(from image: CGImage, isCropped: Bool = false) throws -> Data {
        if !isCropped {
            // For uncropped images, we can use the data directly
            guard let provider = image.dataProvider,
                  let pixelData = provider.data else {
                throw RGB2GIFError.cborExportFailed("Cannot get pixel data from CGImage")
            }
            return pixelData as Data
        }

        // For cropped images, we must render to a new context to get correct pixel data
        // because CGImage.cropping() shares data with the original
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        var pixelBuffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &pixelBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw RGB2GIFError.cborExportFailed("Cannot create context for BGRA extraction")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return Data(pixelBuffer)
    }

    /// File name for raw frames: r00.cbor - r80.cbor
    private func rawFileName(index: Int, extension ext: String) -> String {
        String(format: "r%02d.\(ext)", index)
    }

    /// Export raw frame as PNG
    private func exportRawPNG(from image: CGImage, index: Int) throws {
        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: image)
        guard let pngData = uiImage.pngData() else {
            throw RGB2GIFError.cborExportFailed("Failed to create PNG for raw frame \(index)")
        }
        let pngURL = session.l0RawURL.appendingPathComponent(rawFileName(index: index, extension: "png"))
        try pngData.write(to: pngURL)
        #endif
    }
}

// MARK: - L1_cropped Export (Center-Cropped Squares)

@available(iOS 26.0, *)
extension CBORFrameExporter {

    /// Export a center-cropped square frame to L1_cropped
    /// - Parameters:
    ///   - frame: Original camera CGImage
    ///   - index: Frame index (0-80)
    /// - Returns: Tuple of (cropped CGImage, bytes written)
    ///
    /// ## CRITICAL NOTE
    /// The cropped CGImage shares pixel data with the original.
    /// We must pass `isCropped: true` to `extractBGRAData` to get correct data.
    public func exportCroppedFrame(_ frame: CGImage, index: Int) throws -> (CGImage, Int64) {
        guard let cropped = FrameFormatConverter.centerCropToSquare(frame) else {
            throw RGB2GIFError.cborExportFailed("Failed to crop frame \(index) to square")
        }

        // Extract BGRA bytes from cropped image
        // CRITICAL: Pass isCropped: true because CGImage.cropping() shares data with original
        let bgraData = try extractBGRAData(from: cropped, isCropped: true)

        let cbor: CBOR = .map([
            "stage": .utf8String("L1_cropped"),
            "index": .unsignedInt(UInt64(index)),
            "original_dimensions": .map([
                "width": .unsignedInt(UInt64(frame.width)),
                "height": .unsignedInt(UInt64(frame.height))
            ]),
            "cropped_dimensions": .map([
                "width": .unsignedInt(UInt64(cropped.width)),
                "height": .unsignedInt(UInt64(cropped.height))
            ]),
            "format": .utf8String("BGRA8"),
            "bgra_data": .byteString(Array(bgraData))
        ])

        let cborData = Data(cbor.encode())
        let cborURL = session.l1CroppedURL.appendingPathComponent(croppedFileName(index: index, extension: "cbor"))
        try cborData.write(to: cborURL)

        // Write PNG
        try exportCroppedPNG(from: cropped, index: index)

        frameLogger.debug("L1_cropped: Exported frame \(index) (\(cropped.width)×\(cropped.height)): \(cborData.count) bytes")
        return (cropped, Int64(cborData.count))
    }

    /// Export all cropped frames and return them for the next stage
    public func exportAllCroppedFrames(_ frames: [CGImage]) throws -> ([CGImage], Int64) {
        guard frames.count == 81 else {
            throw RGB2GIFError.cborExportFailed("Expected 81 frames for cropping, got \(frames.count)")
        }

        var croppedFrames: [CGImage] = []
        croppedFrames.reserveCapacity(81)
        var totalBytes: Int64 = 0

        for (index, frame) in frames.enumerated() {
            let (cropped, bytes) = try exportCroppedFrame(frame, index: index)
            croppedFrames.append(cropped)
            totalBytes += bytes
        }

        frameLogger.info("L1_cropped: Exported all 81 cropped frames: \(totalBytes) bytes total")
        return (croppedFrames, totalBytes)
    }

    /// File name for cropped frames: c00.cbor - c80.cbor
    private func croppedFileName(index: Int, extension ext: String) -> String {
        String(format: "c%02d.\(ext)", index)
    }

    /// Export cropped frame as PNG
    private func exportCroppedPNG(from image: CGImage, index: Int) throws {
        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: image)
        guard let pngData = uiImage.pngData() else {
            throw RGB2GIFError.cborExportFailed("Failed to create PNG for cropped frame \(index)")
        }
        let pngURL = session.l1CroppedURL.appendingPathComponent(croppedFileName(index: index, extension: "png"))
        try pngData.write(to: pngURL)
        #endif
    }
}

// MARK: - L2_frames Export (Resized 81×81 RGB - Explicit Conversion)

@available(iOS 26.0, *)
extension CBORFrameExporter {

    /// Export a resized 81×81 RGB frame using explicit BGRA→RGB conversion
    /// This is the CRITICAL conversion point - uses FrameFormatConverter
    /// - Parameters:
    ///   - frame: ORIGINAL camera CGImage (any size) - NOT pre-cropped!
    ///   - index: Frame index (0-80)
    ///   - timestamp: Capture timestamp in milliseconds
    /// - Returns: Tuple of (RGB Data, bytes written)
    ///
    /// ## CRITICAL FIX (2024-12-03 v2)
    /// DO NOT pass pre-cropped images! `CGImage.cropping()` creates corrupted data.
    /// This function accepts the ORIGINAL camera frame and does crop+resize in ONE step
    /// using `safeCropAndResizeToRGB()` which avoids CGImage.cropping() entirely.
    public func exportResizedRGBFrame(_ frame: CGImage, index: Int, timestamp: Int64 = 0) throws -> (Data, Int64) {
        // CRITICAL: Use safeCropAndResizeToRGB which does crop+resize in ONE operation
        // This avoids CGImage.cropping() which causes data corruption!
        let rgbData = FrameFormatConverter.safeCropAndResizeToRGB(frame, targetSize: 81)

        guard rgbData.count == 81 * 81 * 3 else {
            throw RGB2GIFError.cborExportFailed("RGB data size mismatch: got \(rgbData.count), expected \(81 * 81 * 3)")
        }

        // Log first pixels for debugging
        FrameFormatConverter.logFirstPixels(rgb: rgbData, label: "L2_frames[\(index)]", count: 3)

        let tensorLayer = index / 9
        let layerOffset = index % 9
        let contributedCells = Self.contributedCells(for: index)

        let cbor: CBOR = .map([
            "stage": .utf8String("L2_frames"),
            "index": .unsignedInt(UInt64(index)),
            "timestamp_ms": .unsignedInt(UInt64(timestamp)),
            "dimensions": .map([
                "width": .unsignedInt(81),
                "height": .unsignedInt(81)
            ]),
            "format": .utf8String("RGB8"),
            "bytes_per_pixel": .unsignedInt(3),
            "tensor_layer": .unsignedInt(UInt64(tensorLayer)),
            "tensor_offset": .unsignedInt(UInt64(layerOffset)),
            "contributed_cells": .array(contributedCells.map { cell in
                .array([
                    .unsignedInt(UInt64(cell.t)),
                    .unsignedInt(UInt64(cell.y)),
                    .unsignedInt(UInt64(cell.x))
                ])
            }),
            "rgb_data": .byteString(Array(rgbData))
        ])

        let cborData = Data(cbor.encode())
        let cborURL = session.l2FramesURL.appendingPathComponent(session.frameFileName(index: index, extension: "cbor"))
        try cborData.write(to: cborURL)

        // Write PNG for visual verification
        try FrameFormatConverter.saveRGBAsPNG(
            rgb: rgbData,
            width: 81,
            height: 81,
            to: session.l2FramesURL.appendingPathComponent(session.frameFileName(index: index, extension: "png"))
        )

        frameLogger.debug("L2_frames: Exported frame \(index) (81×81 RGB): \(cborData.count) bytes")
        return (rgbData, Int64(cborData.count))
    }

    /// Export all resized RGB frames and return the RGB data for tensor building
    /// - Parameter croppedFrames: 81 cropped CGImages from L1_cropped
    /// - Returns: Tuple of (array of RGB Data, total bytes)
    public func exportAllResizedRGBFrames(_ croppedFrames: [CGImage]) throws -> ([Data], Int64) {
        guard croppedFrames.count == 81 else {
            throw RGB2GIFError.cborExportFailed("Expected 81 cropped frames, got \(croppedFrames.count)")
        }

        var rgbFrames: [Data] = []
        rgbFrames.reserveCapacity(81)
        var totalBytes: Int64 = 0
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        for (index, frame) in croppedFrames.enumerated() {
            let frameTimestamp = timestamp + Int64(index * 33)
            let (rgbData, bytes) = try exportResizedRGBFrame(frame, index: index, timestamp: frameTimestamp)
            rgbFrames.append(rgbData)
            totalBytes += bytes
        }

        frameLogger.info("L2_frames: Exported all 81 RGB frames: \(totalBytes) bytes total")
        return (rgbFrames, totalBytes)
    }
}
