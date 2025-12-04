//
//  GIFCatalogueManager.swift
//  RGB2GIF
//
//  Manages local GIF catalogue and metadata for app persistence
//

import Foundation
import Combine
import UIKit
import Photos

@available(iOS 26.0, *)
public class GIFCatalogueManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = GIFCatalogueManager()

    // MARK: - Published Properties

    @Published public var catalogueItems: [GIFCatalogueItem] = []
    @Published public var isLoading: Bool = false

    // MARK: - Storage

    private let fileManager = FileManager.default
    private let catalogueDirectory: URL
    private let metadataFileName = "catalogue_metadata.json"

    // MARK: - Initialization

    private init() {
        // Create catalogue directory in Documents
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        catalogueDirectory = documentsURL.appendingPathComponent("GIFCatalogue", isDirectory: true)

        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: catalogueDirectory, withIntermediateDirectories: true)

        // Load existing catalogue
        loadCatalogue()
    }

    // MARK: - Public API

    /// Save a GIF to the catalogue with metadata
    public func saveGIF(
        gifData: Data,
        dimension: VoxelGIFConfiguration.CubeDimension,
        tensorData: Data?,
        paletteData: Data?,
        metadata: CatalogueMetadata
    ) async throws -> GIFCatalogueItem {

        let itemID = UUID().uuidString
        let timestamp = Date()

        // Create item directory
        let itemDirectory = catalogueDirectory.appendingPathComponent(itemID, isDirectory: true)
        try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)

        // Save GIF
        let gifURL = itemDirectory.appendingPathComponent("animation.gif")
        try gifData.write(to: gifURL)

        // Save tensor if provided
        var tensorURL: URL?
        if let tensorData = tensorData {
            tensorURL = itemDirectory.appendingPathComponent("tensor.json")
            try tensorData.write(to: tensorURL!)
        }

        // Save palette if provided
        var paletteURL: URL?
        if let paletteData = paletteData {
            paletteURL = itemDirectory.appendingPathComponent("palette.json")
            try paletteData.write(to: paletteURL!)
        }

        // Generate thumbnail
        let thumbnailURL = itemDirectory.appendingPathComponent("thumbnail.jpg")
        if let thumbnail = generateThumbnail(from: gifData) {
            if let jpegData = thumbnail.jpegData(compressionQuality: 0.8) {
                try jpegData.write(to: thumbnailURL)
            }
        }

        // Create catalogue item
        let item = GIFCatalogueItem(
            id: itemID,
            gifURL: gifURL,
            thumbnailURL: thumbnailURL,
            tensorURL: tensorURL,
            paletteURL: paletteURL,
            dimension: dimension.rawValue,
            frameCount: metadata.frameCount,
            fileSize: gifData.count,
            createdAt: timestamp,
            metadata: metadata,
            photosAssetID: nil
        )

        // Add to catalogue
        await MainActor.run {
            catalogueItems.insert(item, at: 0)
        }

        // Persist catalogue
        try saveCatalogueMetadata()

        return item
    }

    /// Save GIF to Photos and update catalogue item
    public func saveToPhotos(item: GIFCatalogueItem) async throws -> String {
        let config = PhotosGIFSaver.SaveConfiguration(
            dimension: item.dimension == 80 ? .small80 : .large128,
            includeTensor: item.tensorURL != nil
        )

        let assetID = try await PhotosGIFSaver.saveGIF(
            at: item.gifURL,
            title: "VoxelGIF_\(item.dimension)x\(item.dimension)",
            configuration: config
        )

        // Update item with Photos asset ID
        if let index = catalogueItems.firstIndex(where: { $0.id == item.id }) {
            await MainActor.run {
                catalogueItems[index].photosAssetID = assetID
            }
            try saveCatalogueMetadata()
        }

        return assetID
    }

    /// Delete item from catalogue
    public func deleteItem(_ item: GIFCatalogueItem) throws {
        // Delete files
        let itemDirectory = item.gifURL.deletingLastPathComponent()
        try fileManager.removeItem(at: itemDirectory)

        // Remove from catalogue
        catalogueItems.removeAll { $0.id == item.id }

        // Persist
        try saveCatalogueMetadata()
    }

    /// Load catalogue from disk
    public func loadCatalogue() {
        isLoading = true

        let metadataURL = catalogueDirectory.appendingPathComponent(metadataFileName)

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            isLoading = false
            return
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([GIFCatalogueItem].self, from: data)

            catalogueItems = items.sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("Failed to load catalogue: \(error)")
        }

        isLoading = false
    }

    // MARK: - Private Helpers

    private func saveCatalogueMetadata() throws {
        let metadataURL = catalogueDirectory.appendingPathComponent(metadataFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(catalogueItems)
        try data.write(to: metadataURL)
    }

    private func generateThumbnail(from gifData: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(gifData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - Filtering & Sorting

    public func filterByDimension(_ dimension: Int?) -> [GIFCatalogueItem] {
        guard let dimension = dimension else { return catalogueItems }
        return catalogueItems.filter { $0.dimension == dimension }
    }

    public func sortedBy(_ sortOption: SortOption) -> [GIFCatalogueItem] {
        switch sortOption {
        case .dateNewest:
            return catalogueItems.sorted { $0.createdAt > $1.createdAt }
        case .dateOldest:
            return catalogueItems.sorted { $0.createdAt < $1.createdAt }
        case .sizeSmallest:
            return catalogueItems.sorted { $0.fileSize < $1.fileSize }
        case .sizeLargest:
            return catalogueItems.sorted { $0.fileSize > $1.fileSize }
        }
    }

    public enum SortOption: String, CaseIterable {
        case dateNewest = "Date (Newest)"
        case dateOldest = "Date (Oldest)"
        case sizeSmallest = "Size (Smallest)"
        case sizeLargest = "Size (Largest)"
    }
}

// MARK: - Models

@available(iOS 26.0, *)
public struct GIFCatalogueItem: Codable, Identifiable {
    public let id: String
    public let gifURL: URL
    public let thumbnailURL: URL
    public let tensorURL: URL?
    public let paletteURL: URL?
    public let dimension: Int
    public let frameCount: Int
    public let fileSize: Int
    public let createdAt: Date
    public let metadata: CatalogueMetadata
    public var photosAssetID: String?

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

@available(iOS 26.0, *)
public struct CatalogueMetadata: Codable {
    public let frameCount: Int
    public let fps: Double
    public let colorCount: Int
    public let usedDithering: Bool
    public let conveyorEnabled: Bool
    public let captureDevice: String?

    public init(
        frameCount: Int,
        fps: Double = 24.0,
        colorCount: Int = 256,
        usedDithering: Bool = false,
        conveyorEnabled: Bool = false,
        captureDevice: String? = nil
    ) {
        self.frameCount = frameCount
        self.fps = fps
        self.colorCount = colorCount
        self.usedDithering = usedDithering
        self.conveyorEnabled = conveyorEnabled
        self.captureDevice = captureDevice
    }
}