//
//  PaletteLibrary.swift
//  RGB2GIF
//
//  Palette Library Manager - enables palette capture, storage, sharing, and swapping
//  Users can:
//  1. Capture palettes from camera (128 or 80 frames)
//  2. Store palettes as GIP2 files with metadata
//  3. Browse and preview palettes
//  4. Apply palettes to existing GIX2 (greyscale) data
//  5. Share palettes with other users
//

import Foundation
import os.log

private let libraryLogger = Logger(subsystem: "com.rgb2gif", category: "PaletteLibrary")

/// Palette Library Entry - metadata for stored palette
@available(iOS 26.0, *)
struct PaletteEntry: Codable, Identifiable {
    let id: UUID
    let name: String
    let created: Date
    let paletteExp: UInt8
    let paletteSize: Int
    let dims: (UInt16, UInt16)  // e.g., (16, 16) for 256-color tensor
    let thumbnail: Data?        // Optional 64×64 preview image
    let gipURL: URL             // Path to GIP2 file
    let tags: [String]
    let creator: String?
    let notes: String?

    var colorCount: Int {
        return 1 << (Int(paletteExp) + 1)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, created, paletteExp, paletteSize
        case dimsA, dimsB, thumbnail, gipURL, tags, creator, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        created = try container.decode(Date.self, forKey: .created)
        paletteExp = try container.decode(UInt8.self, forKey: .paletteExp)
        paletteSize = try container.decode(Int.self, forKey: .paletteSize)
        let dimA = try container.decode(UInt16.self, forKey: .dimsA)
        let dimB = try container.decode(UInt16.self, forKey: .dimsB)
        dims = (dimA, dimB)
        thumbnail = try container.decodeIfPresent(Data.self, forKey: .thumbnail)
        gipURL = try container.decode(URL.self, forKey: .gipURL)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(created, forKey: .created)
        try container.encode(paletteExp, forKey: .paletteExp)
        try container.encode(paletteSize, forKey: .paletteSize)
        try container.encode(dims.0, forKey: .dimsA)
        try container.encode(dims.1, forKey: .dimsB)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encode(gipURL, forKey: .gipURL)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(creator, forKey: .creator)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    init(id: UUID = UUID(), name: String, created: Date = Date(),
         paletteExp: UInt8, paletteSize: Int, dims: (UInt16, UInt16),
         thumbnail: Data?, gipURL: URL, tags: [String] = [],
         creator: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.paletteExp = paletteExp
        self.paletteSize = paletteSize
        self.dims = dims
        self.thumbnail = thumbnail
        self.gipURL = gipURL
        self.tags = tags
        self.creator = creator
        self.notes = notes
    }
}

/// Palette Library - manages palette collection
@available(iOS 26.0, *)
class PaletteLibrary {

    // MARK: - Properties

    private let libraryURL: URL
    private let indexURL: URL
    private var entries: [PaletteEntry] = []

    // MARK: - Initialization

    init(libraryURL: URL? = nil) throws {
        // Default: Documents/PaletteLibrary/
        if let url = libraryURL {
            self.libraryURL = url
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.libraryURL = docs.appendingPathComponent("PaletteLibrary", isDirectory: true)
        }

        self.indexURL = self.libraryURL.appendingPathComponent("index.json")

        // Create directory if needed
        try FileManager.default.createDirectory(at: self.libraryURL, withIntermediateDirectories: true)

        // Load index
        try loadIndex()

        libraryLogger.info("Palette library initialized: \(self.libraryURL.path)")
    }

    // MARK: - Public API

    /// Add palette to library
    /// - Parameters:
    ///   - gip: Palette (GIP2)
    ///   - name: Display name
    ///   - tags: Optional tags
    ///   - thumbnail: Optional thumbnail image
    /// - Returns: Entry ID
    func addPalette(_ gip: GIP, name: String, tags: [String] = [], thumbnail: Data? = nil) throws -> UUID {
        let id = UUID()
        let filename = "\(id.uuidString).gip2"
        let gipURL = libraryURL.appendingPathComponent(filename)

        // Save GIP2 file
        try gip.write(to: gipURL)

        // Create entry
        let entry = PaletteEntry(
            id: id,
            name: name,
            created: Date(),
            paletteExp: gip.paletteExp,
            paletteSize: gip.paletteSize,
            dims: (gip.palettes.first?.dimA ?? 256, gip.palettes.first?.dimB ?? 1),
            thumbnail: thumbnail,
            gipURL: gipURL,
            tags: tags
        )

        entries.append(entry)
        try saveIndex()

        libraryLogger.info("Added palette: \(name) (\(gip.paletteSize) colors)")
        return id
    }

    /// Get palette by ID
    /// - Parameter id: Entry ID
    /// - Returns: GIP2 palette
    func getPalette(id: UUID) throws -> GIP {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw LibraryError.paletteNotFound(id)
        }
        return try GIP.load(from: entry.gipURL)
    }

    /// Get all entries
    var allEntries: [PaletteEntry] {
        return entries
    }

    /// Search palettes
    /// - Parameter query: Search query (matches name and tags)
    /// - Returns: Matching entries
    func search(query: String) -> [PaletteEntry] {
        let lower = query.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(lower) ||
            $0.tags.contains(where: { $0.lowercased().contains(lower) })
        }
    }

    /// Delete palette
    /// - Parameter id: Entry ID
    func deletePalette(id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw LibraryError.paletteNotFound(id)
        }

        let entry = entries[index]

        // Delete file
        try FileManager.default.removeItem(at: entry.gipURL)

        // Remove from index
        entries.remove(at: index)
        try saveIndex()

        libraryLogger.info("Deleted palette: \(entry.name)")
    }

    /// Export palette for sharing
    /// - Parameter id: Entry ID
    /// - Returns: Shareable GIP2 data
    func exportPalette(id: UUID) throws -> Data {
        let gip = try getPalette(id: id)
        return try gip.serialize()
    }

    /// Import palette from data
    /// - Parameters:
    ///   - data: GIP2 data
    ///   - name: Display name
    /// - Returns: Entry ID
    func importPalette(data: Data, name: String) throws -> UUID {
        let gip = try GIP.parse(data: data)
        return try addPalette(gip, name: name)
    }

    // MARK: - Private Methods

    private func loadIndex() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            entries = []
            return
        }

        let data = try Data(contentsOf: indexURL)
        entries = try JSONDecoder().decode([PaletteEntry].self, from: data)
    }

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Errors

    enum LibraryError: LocalizedError {
        case paletteNotFound(UUID)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .paletteNotFound(let id):
                return "Palette not found: \(id)"
            case .invalidData:
                return "Invalid palette data"
            }
        }
    }
}

// MARK: - Palette Swapping

@available(iOS 26.0, *)
extension PaletteLibrary {

    /// Apply palette to GIX2 (swap palettes without touching indices)
    /// - Parameters:
    ///   - paletteID: Palette ID from library
    ///   - gix: Index stream (GIX2)
    ///   - outputURL: Output GIF URL
    func applyPalette(paletteID: UUID, to gix: GIX, outputURL: URL) throws {
        libraryLogger.info("Applying palette \(paletteID) to GIX2")

        let gip = try getPalette(id: paletteID)

        // Verify compatibility
        _ = 1 << (Int(gip.paletteExp) + 1)  // Unused expectedSize removed
        let lzwCodeSize = max(2, UInt8(gip.paletteExp) + 1)

        guard gix.lzwMinCodeSize == lzwCodeSize else {
            throw LibraryError.invalidData
        }

        // Mux to GIF
        try GIF89aMuxer.mux(gip: gip, gix: gix, to: outputURL)

        libraryLogger.info("Applied palette successfully")
    }
}
