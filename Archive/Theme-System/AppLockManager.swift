//
//  AppLockManager.swift
//  RGB2GIF
//
//  First-Capture Gate System
//  Unlocks main menu only after user creates their first GIP+GIX+GIF89a cartridge
//

import Foundation
import OSLog

/// Manages app unlock state (first-capture gate)
/// User MUST create first cartridge to access main menu gallery
final class AppLockManager {
    // MARK: - Singleton

    static let shared = AppLockManager()

    // MARK: - Properties

    /// User defaults key for unlock state
    private let unlockKey = "com.rgb2gif.mainMenuUnlocked"

    /// User defaults key for first cartridge path
    private let firstCartridgeKey = "com.rgb2gif.firstCartridgePath"

    /// Logger
    private let logger = Logger(subsystem: "com.rgb2gif", category: "AppLockManager")

    /// Is main menu unlocked?
    private(set) var isUnlocked: Bool {
        get {
            UserDefaults.standard.bool(forKey: unlockKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: unlockKey)
            logger.info("Main menu unlock state changed: \(newValue)")

            // Post notification for UI updates
            NotificationCenter.default.post(
                name: .appUnlockStateChanged,
                object: nil,
                userInfo: ["isUnlocked": newValue]
            )
        }
    }

    /// Path to first cartridge that unlocked the app
    var firstCartridgePath: String? {
        get {
            UserDefaults.standard.string(forKey: firstCartridgeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: firstCartridgeKey)
        }
    }

    // MARK: - Initialization

    private init() {
        let unlockState = isUnlocked
        logger.info("AppLockManager initialized - Main menu \(unlockState ? "unlocked" : "locked")")

        if let firstPath = firstCartridgePath {
            logger.info("First cartridge: \(firstPath)")
        }
    }

    // MARK: - Unlock Logic

    /// Unlock main menu with first cartridge
    /// Called after successful GIP+GIX+GIF89a creation
    func unlockWithCartridge(at path: String) {
        guard !isUnlocked else {
            logger.warning("Attempted to unlock already unlocked app")
            return
        }

        logger.info("🔓 UNLOCKING MAIN MENU with cartridge: \(path)")

        firstCartridgePath = path
        isUnlocked = true

        // Schedule unlock celebration (handled by UI layer)
        NotificationCenter.default.post(
            name: .firstCartridgeCreated,
            object: nil,
            userInfo: ["cartridgePath": path]
        )
    }

    /// Reset unlock state (for testing/debugging only)
    func resetUnlockState() {
        logger.warning("⚠️ RESETTING UNLOCK STATE (testing mode)")
        isUnlocked = false
        firstCartridgePath = nil

        // Reset theme to B&W
        ThemeManager.shared.resetToBlackAndWhite()
    }

    // MARK: - Validation

    /// Verify that first cartridge still exists
    func validateFirstCartridge() -> Bool {
        guard let path = firstCartridgePath else { return false }

        let fileExists = FileManager.default.fileExists(atPath: path)

        if !fileExists {
            logger.error("First cartridge missing at: \(path)")
        }

        return fileExists
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when app unlock state changes
    static let appUnlockStateChanged = Notification.Name("com.rgb2gif.appUnlockStateChanged")

    /// Posted when first cartridge is created (unlock celebration trigger)
    static let firstCartridgeCreated = Notification.Name("com.rgb2gif.firstCartridgeCreated")
}

// MARK: - Cartridge Structure

/// Represents a complete GIP+GIX+GIF89a cartridge
struct Cartridge {
    /// Root directory path (contains all cartridge files)
    let rootPath: String

    /// GIP file path (palette)
    var gipPath: String { "\(rootPath)/palette.gip" }

    /// GIX file path (index stream)
    var gixPath: String { "\(rootPath)/frames.gix" }

    /// GIF89a file path (final output)
    var gifPath: String { "\(rootPath)/output.gif" }

    /// UI theme JSON path
    var themePath: String { "\(rootPath)/ui_theme.json" }

    /// Metadata JSON path
    var metadataPath: String { "\(rootPath)/metadata.json" }

    /// Timestamp when cartridge was created
    let createdAt: Date

    /// Display name (auto-generated from GIP mood)
    let name: String

    /// SHA256 hash of GIP palette
    let paletteHash: String

    // MARK: - Validation

    /// Check if all required files exist
    func validate() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: gipPath) &&
               fm.fileExists(atPath: gixPath) &&
               fm.fileExists(atPath: gifPath)
    }

    // MARK: - File Operations

    /// Load GIP palette from cartridge
    func loadGIP() throws -> GIPPalette {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: gipPath)) else {
            throw CartridgeError.missingGIP
        }

        let gip = try GIP.parse(data: data)
        guard let palette = gip.palettes.first else {
            throw CartridgeError.invalidGIP
        }
        return palette
    }

    /// Load UI theme JSON
    func loadTheme() throws -> UITheme {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: themePath)) else {
            throw CartridgeError.missingTheme
        }

        // Verify it's valid JSON (unused result)
        _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Parse JSON to UITheme (simplified - full implementation would deserialize all fields)
        // For now, re-extract theme from GIP
        let gip = try loadGIP()
        return ThemeManager.shared.extractUITheme(from: gip)
    }
}

// MARK: - Errors

enum CartridgeError: Error {
    case missingGIP
    case missingGIX
    case missingGIF
    case missingTheme
    case missingPaletteData
    case invalidStructure
    case corruptedData
    case invalidGIP
}
