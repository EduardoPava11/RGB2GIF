//
//  ThemeManager.swift
//  RGB2GIF
//
//  Global Theme Management for GIP-Driven UI System
//  Coordinates theme application across all UI components
//

import UIKit
import OSLog
import CryptoKit

/// Global theme manager singleton
/// Coordinates theme loading, extraction, and application across the app
final class ThemeManager {
    // MARK: - Singleton

    static let shared = ThemeManager()

    // MARK: - Properties

    /// Current active theme
    private(set) var currentTheme: UITheme = .blackAndWhite {
        didSet {
            // Notify all registered components when theme changes
            notifyThemeChange()
        }
    }

    /// All registered themeable components (weak references)
    private var registeredComponents: NSHashTable<AnyObject> = NSHashTable.weakObjects()

    /// THREAD SAFETY: Lock protects registeredComponents from concurrent modification
    /// Components may register from different threads during view lifecycle
    private let componentLock = NSLock()

    /// Logger for theme operations
    private let logger = Logger(subsystem: "com.rgb2gif", category: "ThemeManager")

    // MARK: - Initialization

    private init() {
        logger.info("ThemeManager initialized with black-and-white default theme")
    }

    // MARK: - Registration

    /// Register a UI component for automatic theme updates
    /// THREAD SAFETY: Uses lock to protect NSHashTable from concurrent modification
    func register(_ component: GIPThemeable) {
        componentLock.lock()
        registeredComponents.add(component as AnyObject)
        componentLock.unlock()

        // Apply current theme outside lock (may trigger UI updates)
        component.applyGIPTheme(currentTheme)

        logger.debug("Registered component: \(String(describing: type(of: component)))")
    }

    /// Unregister a UI component (usually not needed due to weak references)
    /// THREAD SAFETY: Uses lock to protect NSHashTable from concurrent modification
    func unregister(_ component: GIPThemeable) {
        componentLock.lock()
        registeredComponents.remove(component as AnyObject)
        componentLock.unlock()
        logger.debug("Unregistered component: \(String(describing: type(of: component)))")
    }

    // MARK: - Theme Loading

    /// Load theme from a GIP container (uses first palette)
    func loadTheme(from gip: GIP) {
        guard let firstPalette = gip.palettes.first else {
            logger.error("No palettes found in GIP")
            return
        }

        logger.info("Extracting UI theme from GIP palette...")

        let extractedTheme = extractUITheme(from: firstPalette)
        currentTheme = extractedTheme

        logger.info("✅ Theme '\(extractedTheme.name)' loaded (mood: \(extractedTheme.mood))")
    }

    /// Reset to black-and-white theme
    func resetToBlackAndWhite() {
        logger.info("Resetting to black-and-white theme (no GIP loaded)")
        currentTheme = .blackAndWhite
    }

    // MARK: - Theme Extraction (GIP → UITheme)

    /// Extract a UITheme from a GIP palette
    /// Algorithm: HSV analysis + auto-contrast + mood detection
    func extractUITheme(from gip: GIPPalette) -> UITheme {
        let palette = gip.rgb // 256 × 3 bytes (RGB)

        // Convert to UIColor array
        let colors = palette.map { rgb in
            UIColor(r: rgb[0], g: rgb[1], b: rgb[2])
        }

        // 1. Sort by prominence (saturation × value)
        let sortedByProminence = colors.enumerated().sorted { a, b in
            let hsvA = a.element.hsv
            let hsvB = b.element.hsv
            return (hsvA.s * hsvA.v) > (hsvB.s * hsvB.v)
        }

        // 2. Extract primary color (most saturated/bright)
        let primary = sortedByProminence[0].element

        // 3. Find complementary secondary (opposite hue, high saturation)
        let primaryHSV = primary.hsv
        let targetHue = (primaryHSV.h + 0.5).truncatingRemainder(dividingBy: 1.0) // 180° opposite

        let secondary = colors.min { a, b in
            let hsvA = a.hsv
            let hsvB = b.hsv
            let distA = abs(hsvA.h - targetHue)
            let distB = abs(hsvB.h - targetHue)
            return distA < distB
        } ?? colors[1]

        // 4. Extract background (least saturated, darkest or lightest)
        let sortedByLuminance = colors.sorted { $0.luminance < $1.luminance }
        let darkBackground = sortedByLuminance.first ?? .black
        let lightBackground = sortedByLuminance.last ?? .white

        // Choose background based on average palette brightness
        let avgLuminance = colors.reduce(0.0) { $0 + $1.luminance } / CGFloat(colors.count)
        let background = avgLuminance > 0.5 ? lightBackground : darkBackground

        // 5. Auto-contrast text color
        let text = background.autoContrastText

        // 6. Extract accent (tertiary high-saturation color)
        let accent = sortedByProminence.count > 2 ? sortedByProminence[2].element : secondary

        // 7. Semantic colors (map to palette ranges)
        let success = findColorByHue(in: colors, targetHue: 0.33, saturationThreshold: 0.4) ?? UIColor.systemGreen
        let warning = findColorByHue(in: colors, targetHue: 0.15, saturationThreshold: 0.5) ?? UIColor.systemOrange
        let error = findColorByHue(in: colors, targetHue: 0.0, saturationThreshold: 0.6) ?? UIColor.systemRed

        // 8. Gradient (from dark to bright)
        let gradientStart = sortedByLuminance.first ?? background
        let gradientEnd = sortedByLuminance[min(sortedByLuminance.count - 1, 10)]

        // 9. Detect mood based on color temperature
        let mood = detectMood(from: colors)

        // 10. Generate palette name
        let name = generatePaletteName(mood: mood, primaryColor: primary)

        // 11. Calculate SHA256 hash of palette data
        let hash = computePaletteHash(gip)

        return UITheme(
            primary: primary,
            secondary: secondary,
            background: background,
            text: text,
            accent: accent,
            success: success,
            warning: warning,
            error: error,
            gradientStart: gradientStart,
            gradientEnd: gradientEnd,
            name: name,
            mood: mood,
            gipHash: hash
        )
    }

    // MARK: - Helper Functions

    /// Find color closest to target hue with minimum saturation
    private func findColorByHue(in colors: [UIColor], targetHue: CGFloat, saturationThreshold: CGFloat) -> UIColor? {
        return colors
            .filter { $0.hsv.s >= saturationThreshold }
            .min { a, b in
                let distA = abs(a.hsv.h - targetHue)
                let distB = abs(b.hsv.h - targetHue)
                return distA < distB
            }
    }

    /// Detect mood from palette color distribution
    private func detectMood(from colors: [UIColor]) -> String {
        let avgHue = colors.reduce(0.0) { $0 + $1.hsv.h } / CGFloat(colors.count)
        let avgSaturation = colors.reduce(0.0) { $0 + $1.hsv.s } / CGFloat(colors.count)
        let avgValue = colors.reduce(0.0) { $0 + $1.hsv.v } / CGFloat(colors.count)

        // Warm vs Cool
        let isWarm = avgHue < 0.15 || avgHue > 0.85 // Reds/oranges
        let isCool = avgHue > 0.45 && avgHue < 0.75 // Blues/greens

        // Vibrant vs Muted
        let isVibrant = avgSaturation > 0.6
        let isMuted = avgSaturation < 0.3

        // Bright vs Dark
        let isBright = avgValue > 0.7
        let isDark = avgValue < 0.3

        // Combine attributes
        if isVibrant && isWarm { return "vibrant sunset" }
        if isVibrant && isCool { return "electric neon" }
        if isMuted && isBright { return "pastel dream" }
        if isMuted && isDark { return "moody noir" }
        if isWarm && isBright { return "warm summer" }
        if isCool && isDark { return "deep ocean" }
        if avgSaturation < 0.2 { return "vintage film" }

        return "balanced"
    }

    /// Generate palette name from mood and primary color
    private func generatePaletteName(mood: String, primaryColor: UIColor) -> String {
        let hsv = primaryColor.hsv

        // Detect dominant color family
        let colorName: String
        switch hsv.h {
        case 0..<0.05, 0.95...1.0:
            colorName = "Ruby"
        case 0.05..<0.15:
            colorName = "Amber"
        case 0.15..<0.25:
            colorName = "Gold"
        case 0.25..<0.40:
            colorName = "Emerald"
        case 0.40..<0.50:
            colorName = "Cyan"
        case 0.50..<0.65:
            colorName = "Sapphire"
        case 0.65..<0.75:
            colorName = "Violet"
        case 0.75..<0.85:
            colorName = "Magenta"
        case 0.85..<0.95:
            colorName = "Rose"
        default:
            colorName = "Neutral"
        }

        return "\(colorName) \(mood.capitalized)"
    }

    /// Compute SHA256 hash of palette RGB data
    private func computePaletteHash(_ palette: GIPPalette) -> String {
        // Flatten RGB data to bytes
        var bytes: [UInt8] = []
        for rgb in palette.rgb {
            bytes.append(contentsOf: rgb)
        }

        // Compute SHA256
        let data = Data(bytes)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Notification

    /// Notify all registered components of theme change
    /// THREAD SAFETY: Copies component list under lock, then notifies outside lock
    /// This prevents holding lock during potentially slow UI updates
    private func notifyThemeChange() {
        // Copy components under lock to avoid modification during iteration
        componentLock.lock()
        let componentsCopy = Array(registeredComponents.allObjects)
        let componentCount = componentsCopy.count
        componentLock.unlock()

        logger.debug("Broadcasting theme change to \(componentCount) components")

        // Theme application happens outside lock - safe for UI updates
        // Components are retained by the local array during iteration
        for component in componentsCopy {
            if let themeable = component as? GIPThemeable {
                themeable.applyGIPTheme(currentTheme)
            }
        }
    }
}
