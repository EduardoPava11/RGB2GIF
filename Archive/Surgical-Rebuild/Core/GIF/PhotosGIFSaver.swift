import Foundation
import Photos
import UniformTypeIdentifiers
import CoreGraphics

@available(iOS 26.0, *)
public enum PhotosGIFSaverError: LocalizedError {
    case notAuthorized
    case saveFailed(Error?)
    case resourceUnavailable

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Photos access not authorized"
        case .saveFailed(let err): return "Failed to save GIF to Photos: \(err?.localizedDescription ?? "unknown error")"
        case .resourceUnavailable: return "GIF resource data is unavailable"
        }
    }
}

@available(iOS 26.0, *)
public struct PhotosGIFSaver {

    /// Configuration for saving GIFs with proper orientation
    public struct SaveConfiguration {
        public let dimension: GIFDimension
        public let includeTensor: Bool
        public let orientation: CGImagePropertyOrientation

        public enum GIFDimension: Int {
            case small80 = 80
            case large128 = 128
        }

        public init(dimension: GIFDimension = .small80,
                   includeTensor: Bool = false,
                   orientation: CGImagePropertyOrientation = .up) {
            self.dimension = dimension
            self.includeTensor = includeTensor
            self.orientation = orientation
        }
    }

    public static func requestAuthorizationIfNeeded() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotosGIFSaverError.notAuthorized
        }
    }

    public static func saveGIF(at fileURL: URL,
                               title: String? = nil,
                               configuration: SaveConfiguration = SaveConfiguration()) async throws -> String {
        try await requestAuthorizationIfNeeded()

        return try await withCheckedThrowingContinuation { continuation in
            var localIdentifier: String?
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = UTType.gif.identifier

                // Include dimension in filename
                var filename = title ?? "voxel_gif"
                if !filename.hasSuffix(".gif") {
                    filename = "\(filename)_\(configuration.dimension.rawValue)x\(configuration.dimension.rawValue).gif"
                }
                options.originalFilename = filename

                // Apply orientation metadata if needed
                if configuration.orientation != .up {
                    options.shouldMoveFile = false // Preserve original with metadata
                }

                creationRequest.addResource(with: .photo, fileURL: fileURL, options: options)
                localIdentifier = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                if success, let id = localIdentifier {
                    continuation.resume(returning: id)
                } else {
                    continuation.resume(throwing: PhotosGIFSaverError.saveFailed(error))
                }
            })
        }
    }

    /// Save both GIF and tensor data to Photos
    public static func saveGIFWithTensor(gifURL: URL,
                                        tensorURL: URL?,
                                        title: String? = nil,
                                        configuration: SaveConfiguration = SaveConfiguration()) async throws -> (gifID: String, tensorID: String?) {
        // Save GIF
        let gifID = try await saveGIF(at: gifURL, title: title, configuration: configuration)

        // Save tensor if provided
        var tensorID: String?
        if let tensorURL = tensorURL, configuration.includeTensor {
            tensorID = try await saveTensorData(at: tensorURL, title: "\(title ?? "tensor")_data")
        }

        return (gifID: gifID, tensorID: tensorID)
    }

    /// Save tensor data as a document
    private static func saveTensorData(at fileURL: URL, title: String) async throws -> String {
        try await requestAuthorizationIfNeeded()

        return try await withCheckedThrowingContinuation { continuation in
            var localIdentifier: String?
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = UTType.json.identifier // Or custom UTI for tensor
                options.originalFilename = title.hasSuffix(".json") ? title : "\(title).json"
                creationRequest.addResource(with: .alternatePhoto, fileURL: fileURL, options: options)
                localIdentifier = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, error in
                if success, let id = localIdentifier {
                    continuation.resume(returning: id)
                } else {
                    continuation.resume(throwing: PhotosGIFSaverError.saveFailed(error))
                }
            })
        }
    }

    public static func fetchGIFData(for asset: PHAsset) async throws -> Data {
        try await requestAuthorizationIfNeeded()

        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            throw PhotosGIFSaverError.resourceUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            var collected = Data()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                collected.append(chunk)
            } completionHandler: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: collected)
                }
            }
        }
    }

    public static func fetchAsset(localIdentifier: String) -> PHAsset? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return fetchResult.firstObject
    }
}
