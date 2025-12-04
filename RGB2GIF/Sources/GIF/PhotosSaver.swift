//
//  PhotosSaver.swift
//  RGB2GIF
//
//  Simple Photos library saver for GIF data
//

import Foundation
import Photos
import os.log

private let photosLogger = Logger(subsystem: "com.rgb2gif", category: "PhotosSaver")

// MARK: - PhotosSaver

/// Saves GIF data to the Photos library
@available(iOS 26.0, *)
public struct PhotosSaver {

    // MARK: - Authorization

    /// Request Photos library authorization
    public static func requestAuthorization() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)

        switch status {
        case .authorized, .limited:
            photosLogger.info("Photos authorization granted")
        case .denied, .restricted:
            throw RGB2GIFError.photosNotAuthorized
        case .notDetermined:
            throw RGB2GIFError.photosNotAuthorized
        @unknown default:
            throw RGB2GIFError.photosNotAuthorized
        }
    }

    // MARK: - Save GIF

    /// Save GIF data to Photos library
    /// - Parameters:
    ///   - gifData: The GIF file data
    ///   - filename: Optional filename (default: timestamp-based)
    /// - Returns: Local identifier of the saved asset
    @discardableResult
    public static func save(gifData: Data, filename: String? = nil) async throws -> String {
        photosLogger.info("Saving GIF to Photos: \(gifData.count) bytes")

        // Check authorization first
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status != .authorized && status != .limited {
            try await requestAuthorization()
        }

        // Create temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename ?? "rgb2gif_\(Int(Date().timeIntervalSince1970)).gif")

        do {
            try gifData.write(to: tempURL)
            photosLogger.debug("Wrote temp file: \(tempURL.lastPathComponent)")
        } catch {
            throw RGB2GIFError.fileCreationFailed(tempURL)
        }

        // Save to Photos
        var localIdentifier: String?

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true

                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: tempURL, options: options)

                localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            throw RGB2GIFError.photosSaveFailed(error.localizedDescription)
        }

        guard let identifier = localIdentifier else {
            throw RGB2GIFError.photosSaveFailed("No asset identifier returned")
        }

        photosLogger.info("GIF saved to Photos: \(identifier)")
        return identifier
    }

    /// Save GIF from file URL to Photos library
    @discardableResult
    public static func save(gifURL: URL) async throws -> String {
        let data = try Data(contentsOf: gifURL)
        return try await save(gifData: data, filename: gifURL.lastPathComponent)
    }
}
