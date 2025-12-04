//
//  CBORFrameStorage.swift
//  RGB2GIF
//
//  CBOR serialization for frame arrays with efficient storage
//

import Foundation
import CoreGraphics
import UIKit
import QuartzCore
import os.log

private let cborLogger = Logger(subsystem: "com.rgb2gif", category: "CBORStorage")

/// CBOR frame storage manager for efficient serialization
@available(iOS 26.0, *)
@MainActor
public final class CBORFrameStorage {

    // MARK: - Types

    public struct FrameData: Codable {
        let width: Int
        let height: Int
        let pixelData: Data
        let timestamp: TimeInterval
        let palette: [UInt32]? // Optional 256-color palette
        let thumbnailData80: Data? // Pre-computed 80x80 thumbnail
        let thumbnailData128: Data? // Pre-computed 128x128 thumbnail

        enum CodingKeys: String, CodingKey {
            case width = "w"
            case height = "h"
            case pixelData = "px"
            case timestamp = "ts"
            case palette = "pal"
            case thumbnailData80 = "th80"
            case thumbnailData128 = "th128"
        }
    }

    public struct VoxelCube: Codable {
        let dimension: Int // 80 or 128
        let frameCount: Int
        let frames: [FrameData]
        let globalPalette: [UInt32]? // Optional global palette
        let metadata: Metadata

        struct Metadata: Codable {
            let captureDate: Date
            let deviceModel: String
            let fps: Double
            let colorSpace: String
        }
    }

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let compressionLevel: Int

    // Storage paths
    private var storageURL: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("CBORFrames", isDirectory: true)
    }

    // MARK: - Initialization

    public init(compressionLevel: Int = 6) {
        self.compressionLevel = compressionLevel

        // Create storage directory
        try? fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    // MARK: - Frame Encoding

    /// Convert CGImage to CBOR frame data
    public func encodeFrame(
        _ image: CGImage,
        timestamp: TimeInterval,
        palette: [UInt32]? = nil,
        thumbnail80: CGImage? = nil,
        thumbnail128: CGImage? = nil
    ) throws -> Data {
        // Extract pixel data
        let width = image.width
        let height = image.height
        let pixelData = try extractPixelData(from: image)

        // Extract thumbnail data if provided
        let thumbnailData80 = try thumbnail80.map { try extractPixelData(from: $0) }
        let thumbnailData128 = try thumbnail128.map { try extractPixelData(from: $0) }

        // Create frame structure
        let frameData = FrameData(
            width: width,
            height: height,
            pixelData: pixelData,
            timestamp: timestamp,
            palette: palette,
            thumbnailData80: thumbnailData80,
            thumbnailData128: thumbnailData128
        )

        // Encode to CBOR
        let encoder = CBORFrameEncoder()
        let cborData = try encoder.encode(frameData)

        // Optional compression
        if compressionLevel > 0 {
            return try compress(cborData)
        }

        return cborData
    }

    /// Batch encode multiple frames
    public func encodeBatch(
        frames: [CGImage],
        dimension: Int,
        fps: Double = 10.0
    ) async throws -> Data {
        cborLogger.info("Encoding \(frames.count) frames to CBOR voxel cube")

        var frameDataArray: [FrameData] = []
        let startTime = CACurrentMediaTime()

        for (index, frame) in frames.enumerated() {
            let timestamp = Double(index) / fps

            let pixelData = try extractPixelData(from: frame)
            let frameData = FrameData(
                width: frame.width,
                height: frame.height,
                pixelData: pixelData,
                timestamp: timestamp,
                palette: nil,
                thumbnailData80: nil,
                thumbnailData128: nil
            )

            frameDataArray.append(frameData)
        }

        // Create voxel cube structure
        let voxelCube = VoxelCube(
            dimension: dimension,
            frameCount: frames.count,
            frames: frameDataArray,
            globalPalette: nil,
            metadata: VoxelCube.Metadata(
                captureDate: Date(),
                deviceModel: UIDevice.current.model,
                fps: fps,
                colorSpace: "sRGB"
            )
        )

        // Encode to CBOR
        let encoder = CBORFrameEncoder()
        let cborData = try encoder.encode(voxelCube)

        let encodingTime = CACurrentMediaTime() - startTime
        cborLogger.info("CBOR encoding completed in \(String(format: "%.2f", encodingTime))s")

        return cborData
    }

    // MARK: - Frame Decoding

    /// Decode CBOR data to frame
    public func decodeFrame(from data: Data) throws -> (CGImage, FrameData) {
        // Decompress if needed
        let cborData = isCompressed(data) ? try decompress(data) : data

        // Decode CBOR
        let decoder = CBORFrameDecoder()
        let frameData = try decoder.decode(FrameData.self, from: cborData)

        // Reconstruct CGImage
        let image = try createImage(
            from: frameData.pixelData,
            width: frameData.width,
            height: frameData.height
        )

        return (image, frameData)
    }

    /// Decode voxel cube
    public func decodeVoxelCube(from data: Data) throws -> VoxelCube {
        let cborData = isCompressed(data) ? try decompress(data) : data
        let decoder = CBORFrameDecoder()
        return try decoder.decode(VoxelCube.self, from: cborData)
    }

    // MARK: - Storage Operations

    /// Save frame to disk
    public func saveFrame(_ data: Data, identifier: String) throws -> URL {
        let fileURL = storageURL.appendingPathComponent("\(identifier).cbor")
        try data.write(to: fileURL)
        cborLogger.debug("Saved CBOR frame to \(fileURL.lastPathComponent)")
        return fileURL
    }

    /// Load frame from disk
    public func loadFrame(identifier: String) throws -> Data {
        let fileURL = storageURL.appendingPathComponent("\(identifier).cbor")
        return try Data(contentsOf: fileURL)
    }

    /// Save voxel cube
    public func saveVoxelCube(_ data: Data, name: String) throws -> URL {
        let fileURL = storageURL.appendingPathComponent("\(name)_voxel.cbor")
        try data.write(to: fileURL)

        let sizeInMB = Double(data.count) / 1_048_576
        cborLogger.info("Saved voxel cube: \(String(format: "%.2f", sizeInMB)) MB")

        return fileURL
    }

    /// List all stored frames
    public func listStoredFrames() throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        )
        return contents.filter { $0.pathExtension == "cbor" }
    }

    /// Clean up old frames
    public func cleanupOldFrames(olderThan days: Int = 7) throws {
        let cutoffDate = Date().addingTimeInterval(-Double(days * 86400))
        let files = try listStoredFrames()

        for fileURL in files {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let creationDate = attributes[.creationDate] as? Date,
               creationDate < cutoffDate {
                try fileManager.removeItem(at: fileURL)
                cborLogger.debug("Removed old CBOR file: \(fileURL.lastPathComponent)")
            }
        }
    }

    // MARK: - Private Helpers

    private func extractPixelData(from image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var pixelData = Data(count: totalBytes)

        pixelData.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return pixelData
    }

    private func createImage(from pixelData: Data, width: Int, height: Int) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard let provider = CGDataProvider(data: pixelData as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: bytesPerPixel * 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw CBORError.imageCreationFailed
        }

        return image
    }

    private func compress(_ data: Data) throws -> Data {
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    private func decompress(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }

    private func isCompressed(_ data: Data) -> Bool {
        // Check for zlib magic header
        return data.count > 2 && data[0] == 0x78
    }
}

// MARK: - CBOR Encoder/Decoder

@available(iOS 26.0, *)
private class CBORFrameEncoder {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        // Using JSONEncoder as fallback - in production, use SwiftCBOR library
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
}

@available(iOS 26.0, *)
private class CBORFrameDecoder {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Using JSONDecoder as fallback - in production, use SwiftCBOR library
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
}

// MARK: - Errors

public enum CBORError: LocalizedError {
    case imageCreationFailed
    case compressionFailed
    case decompressionFailed
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .imageCreationFailed:
            return "Failed to create image from pixel data"
        case .compressionFailed:
            return "Failed to compress CBOR data"
        case .decompressionFailed:
            return "Failed to decompress CBOR data"
        case .invalidFormat:
            return "Invalid CBOR format"
        }
    }
}
