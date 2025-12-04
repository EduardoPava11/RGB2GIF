//
//  CartridgeManager.swift
//  RGB2GIF
//
//  Manages cartridge directory structure and file organization
//  Cartridge = GIP + GIX + GIF89a + metadata + ui_theme.json
//

import Foundation
import OSLog
import UIKit

/// Manages cartridge creation and storage
final class CartridgeManager {
    // MARK: - Singleton

    static let shared = CartridgeManager()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.rgb2gif", category: "CartridgeManager")

    /// Root directory for all cartridges
    private let cartridgesDirectory: URL = {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDir.appendingPathComponent("Cartridges", isDirectory: true)
    }()

    // MARK: - Initialization

    private init() {
        // Create cartridges directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cartridgesDirectory, withIntermediateDirectories: true)
        logger.info("CartridgeManager initialized - Cartridges directory: \(self.cartridgesDirectory.path)")
    }

    // MARK: - Cartridge Creation

    /// Create a new cartridge from GIP/GIX/GIF files
    /// Returns the cartridge root path
    func createCartridge(
        gipURL: URL,
        gixURL: URL,
        gifURL: URL,
        name: String,
        metadata: CaptureToGIP2Pipeline.CaptureMetadata
    ) throws -> Cartridge {
        // Create timestamped cartridge directory
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let cartridgeName = "\(name)_\(timestamp)"
        let cartridgeDir = cartridgesDirectory.appendingPathComponent(cartridgeName, isDirectory: true)

        logger.info("Creating cartridge at: \(cartridgeDir.path)")

        // Create directory
        try FileManager.default.createDirectory(at: cartridgeDir, withIntermediateDirectories: true)

        // Copy GIP file
        let gipDest = cartridgeDir.appendingPathComponent("palette.gip")
        try FileManager.default.copyItem(at: gipURL, to: gipDest)
        logger.debug("Copied GIP: \(gipDest.lastPathComponent)")

        // Copy GIX file
        let gixDest = cartridgeDir.appendingPathComponent("frames.gix")
        try FileManager.default.copyItem(at: gixURL, to: gixDest)
        logger.debug("Copied GIX: \(gixDest.lastPathComponent)")

        // Copy GIF file
        let gifDest = cartridgeDir.appendingPathComponent("output.gif")
        try FileManager.default.copyItem(at: gifURL, to: gifDest)
        logger.debug("Copied GIF: \(gifDest.lastPathComponent)")

        // Load GIP to extract theme and palette hash
        let gipData = try Data(contentsOf: gipDest)
        let gip = try GIP.parse(data: gipData)

        guard let firstPalette = gip.palettes.first else {
            throw CartridgeError.missingPaletteData
        }

        // Extract UI theme
        let theme = ThemeManager.shared.extractUITheme(from: firstPalette)

        // Save UI theme JSON
        let themeJSON = try encodeThemeToJSON(theme)
        let themeDest = cartridgeDir.appendingPathComponent("ui_theme.json")
        try themeJSON.write(to: themeDest)
        logger.debug("Saved ui_theme.json")

        // Create cartridge metadata
        let cartridgeMetadata = CartridgeMetadata(
            name: name,
            createdAt: Date(),
            paletteHash: theme.gipHash ?? "unknown",
            paletteName: theme.name,
            paletteMood: theme.mood,
            frameCount: metadata.frameCount,
            dimension: metadata.dimension,
            duration: metadata.duration,
            fps: metadata.fps
        )

        // Save metadata JSON
        let metadataJSON = try JSONEncoder().encode(cartridgeMetadata)
        let metadataDest = cartridgeDir.appendingPathComponent("metadata.json")
        try metadataJSON.write(to: metadataDest)
        logger.debug("Saved metadata.json")

        logger.info("✅ Cartridge created successfully: \(cartridgeName)")

        // Create Cartridge struct
        let cartridge = Cartridge(
            rootPath: cartridgeDir.path,
            createdAt: Date(),
            name: theme.name,
            paletteHash: theme.gipHash ?? ""
        )

        return cartridge
    }

    // MARK: - Helper Functions

    /// Encode UITheme to JSON
    private func encodeThemeToJSON(_ theme: UITheme) throws -> Data {
        // Convert UITheme to dictionary for JSON encoding
        let themeDict: [String: Any] = [
            "name": theme.name,
            "mood": theme.mood,
            "paletteHash": theme.gipHash ?? "",
            "colors": [
                "primary": uiColorToHex(theme.primary),
                "secondary": uiColorToHex(theme.secondary),
                "background": uiColorToHex(theme.background),
                "text": uiColorToHex(theme.text),
                "accent": uiColorToHex(theme.accent),
                "success": uiColorToHex(theme.success),
                "warning": uiColorToHex(theme.warning),
                "error": uiColorToHex(theme.error),
                "gradientStart": uiColorToHex(theme.gradientStart),
                "gradientEnd": uiColorToHex(theme.gradientEnd)
            ]
        ]

        return try JSONSerialization.data(withJSONObject: themeDict, options: [.prettyPrinted])
    }

    /// Convert UIColor to hex string
    private func uiColorToHex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        let red = Int(r * 255)
        let green = Int(g * 255)
        let blue = Int(b * 255)

        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    // MARK: - Cartridge Listing

    /// List all cartridges
    func listCartridges() throws -> [Cartridge] {
        let contents = try FileManager.default.contentsOfDirectory(at: cartridgesDirectory, includingPropertiesForKeys: nil)

        return contents.compactMap { url -> Cartridge? in
            guard url.hasDirectoryPath else { return nil }

            // Load metadata
            let metadataURL = url.appendingPathComponent("metadata.json")
            guard let metadataData = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(CartridgeMetadata.self, from: metadataData) else {
                return nil
            }

            return Cartridge(
                rootPath: url.path,
                createdAt: metadata.createdAt,
                name: metadata.paletteName,
                paletteHash: metadata.paletteHash
            )
        }
    }
}

// MARK: - Cartridge Metadata

struct CartridgeMetadata: Codable {
    let name: String
    let createdAt: Date
    let paletteHash: String
    let paletteName: String
    let paletteMood: String
    let frameCount: Int
    let dimension: Int
    let duration: TimeInterval
    let fps: Double
}

// MARK: - Errors

enum CartridgeManagerError: Error {
    case missingPaletteData
    case invalidDirectory
    case fileOperationFailed(String)
}
