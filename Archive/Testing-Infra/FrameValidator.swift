import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import os

/// Frame validation and metadata extraction
public class FrameValidator {
    private let logger = Logger(subsystem: "com.rgb2gif", category: "validator")

    public struct FrameInfo {
        let fileSize: Int64
        let width: Int?
        let height: Int?
        let bitsPerSample: Int?
        let make: String?
        let model: String?
        let software: String?
        let iso: Int?
        let exposureTime: Double?
        let fNumber: Double?
        let timestamp: Date?
        let isValid: Bool
    }

    /// Validate a saved DNG file
    func validateFrame(at url: URL) -> FrameInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Frame file does not exist: \(url.lastPathComponent)")
            return nil
        }

        // Get file size
        var fileSize: Int64 = 0
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            logger.error("Failed to get file size: \(error.localizedDescription)")
            return nil
        }

        // Extract metadata using ImageIO
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.error("Failed to create image source for: \(url.lastPathComponent)")
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        let exifDict = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiffDict = properties?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dngDict = properties?[kCGImagePropertyDNGDictionary as String] as? [String: Any]

        // Extract dimensions
        let width = properties?[kCGImagePropertyPixelWidth as String] as? Int
        let height = properties?[kCGImagePropertyPixelHeight as String] as? Int

        // Set a dynamic minimum size:
        // - 48MP RAW/ProRAW often > 50MB
        // - 12MP RAW can be ~20–30MB
        let minSize: Int64 = {
            if let w = width, let h = height, max(w, h) >= 8000 {
                return 50 * 1024 * 1024 // ~48MP
            } else {
                return 20 * 1024 * 1024 // smaller RAWs
            }
        }()

        guard fileSize > minSize else {
            logger.error("Frame too small: \(fileSize) bytes, expected > \(minSize)")
            return nil
        }

        // Extract camera info
        let make = tiffDict?[kCGImagePropertyTIFFMake as String] as? String
        let model = tiffDict?[kCGImagePropertyTIFFModel as String] as? String
        let software = tiffDict?[kCGImagePropertyTIFFSoftware as String] as? String

        // Extract EXIF data
        let iso = exifDict?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]
        let exposureTime = exifDict?[kCGImagePropertyExifExposureTime as String] as? Double
        let fNumber = exifDict?[kCGImagePropertyExifFNumber as String] as? Double

        // Extract bits per sample (DNG dictionary preferred)
        let bitsPerSample = dngDict?["BitsPerSample"] as? [Int] ??
                            properties?["BitsPerPixel"] as? [Int]

        // Timestamp
        let timestamp = (properties?[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap { dateString in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return formatter.date(from: dateString)
        }

        // Validate DNG
        let isValidDNG = (dngDict != nil) || (url.pathExtension.lowercased() == "dng")

        if isValidDNG {
            logger.info("Valid DNG: \(url.lastPathComponent) - \(fileSize / 1024 / 1024)MB, \(width ?? 0)x\(height ?? 0)")
        } else {
            logger.error("Invalid DNG format: \(url.lastPathComponent)")
        }

        return FrameInfo(
            fileSize: fileSize,
            width: width,
            height: height,
            bitsPerSample: bitsPerSample?.first,
            make: make,
            model: model,
            software: software,
            iso: iso?.first,
            exposureTime: exposureTime,
            fNumber: fNumber,
            timestamp: timestamp,
            isValid: isValidDNG && fileSize > minSize
        )
    }

    /// Validate all frames in a session
    func validateSession(at directory: URL) -> (valid: Int, invalid: Int, totalSize: Int64) {
        var validCount = 0
        var invalidCount = 0
        var totalSize: Int64 = 0

        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "dng" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for file in files {
                if let info = validateFrame(at: file) {
                    if info.isValid {
                        validCount += 1
                        totalSize += info.fileSize
                    } else {
                        invalidCount += 1
                    }
                } else {
                    invalidCount += 1
                }
            }
        } catch {
            logger.error("Failed to validate session: \(error.localizedDescription)")
        }

        logger.info("Session validation: \(validCount) valid, \(invalidCount) invalid, total size: \(totalSize / 1024 / 1024) MB")
        return (validCount, invalidCount, totalSize)
    }

    /// Create session manifest JSON
    func createManifest(for directory: URL) {
        var frames: [[String: Any]] = []

        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "dng" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for (index, file) in files.enumerated() {
                if let info = validateFrame(at: file) {
                    frames.append([
                        "index": index + 1,
                        "filename": file.lastPathComponent,
                        "fileSize": info.fileSize,
                        "width": info.width ?? 0,
                        "height": info.height ?? 0,
                        "bitsPerSample": info.bitsPerSample ?? 0,
                        "iso": info.iso ?? 0,
                        "exposureTime": info.exposureTime ?? 0,
                        "fNumber": info.fNumber ?? 0,
                        "isValid": info.isValid
                    ])
                }
            }

            let manifest: [String: Any] = [
                "sessionId": directory.lastPathComponent,
                "frameCount": frames.count,
                "captureDate": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "osVersion": UIDevice.current.systemVersion,
                "frames": frames
            ]

            let manifestURL = directory.appendingPathComponent("manifest.json")
            let jsonData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
            try jsonData.write(to: manifestURL)

            logger.info("Created manifest with \(frames.count) frames")
        } catch {
            logger.error("Failed to create manifest: \(error.localizedDescription)")
        }
    }
}
