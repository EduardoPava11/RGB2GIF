//
//  UITheme.swift
//  RGB2GIF
//
//  GIP-Driven UI Theme System
//  Extracts UI colors from GIP palettes to create dynamic app themes
//

import UIKit

/// Represents a complete UI color theme extracted from a GIP palette
struct UITheme {
    // MARK: - Core Colors

    /// Primary UI color (most dominant/saturated color from palette)
    let primary: UIColor

    /// Secondary UI color (complementary accent)
    let secondary: UIColor

    /// Background color (least saturated, typically from palette extremes)
    let background: UIColor

    /// Text color (auto-contrasted against background)
    let text: UIColor

    // MARK: - Extended Colors

    /// Tertiary accent color
    let accent: UIColor

    /// Success/positive feedback color
    let success: UIColor

    /// Warning/caution color
    let warning: UIColor

    /// Error/danger color
    let error: UIColor

    // MARK: - Gradients

    /// Background gradient colors (for visual richness)
    let gradientStart: UIColor
    let gradientEnd: UIColor

    // MARK: - Metadata

    /// Palette name (auto-generated from color mood)
    let name: String

    /// Mood descriptor (e.g., "warm sunset", "cool ocean", "retro")
    let mood: String

    /// Source GIP palette SHA256 hash
    let gipHash: String?

    // MARK: - Black & White Preset

    /// Default theme when NO GIP is loaded
    static let blackAndWhite = UITheme(
        primary: UIColor.white,
        secondary: UIColor(white: 0.7, alpha: 1.0),
        background: UIColor.black,
        text: UIColor.white,
        accent: UIColor(white: 0.5, alpha: 1.0),
        success: UIColor.white,
        warning: UIColor(white: 0.8, alpha: 1.0),
        error: UIColor(white: 0.6, alpha: 1.0),
        gradientStart: UIColor.black,
        gradientEnd: UIColor(white: 0.15, alpha: 1.0),
        name: "Black & White",
        mood: "minimalist",
        gipHash: nil
    )

    // MARK: - System Integration

    /// Applies theme to system status bar style
    var preferredStatusBarStyle: UIStatusBarStyle {
        // Calculate luminance of background
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        return luminance > 0.5 ? .darkContent : .lightContent
    }
}

// MARK: - GIPThemeable Protocol

/// Protocol for UI components that can be themed by GIP palettes
protocol GIPThemeable: AnyObject {
    /// Current active theme
    var currentTheme: UITheme? { get set }

    /// Apply a GIP-derived theme to this component
    func applyGIPTheme(_ theme: UITheme)

    /// Revert to black-and-white theme
    func resetToBlackAndWhite()
}

extension GIPThemeable {
    /// Default implementation for resetting to B&W
    func resetToBlackAndWhite() {
        applyGIPTheme(.blackAndWhite)
    }
}

// MARK: - Color Utilities

extension UIColor {
    /// Create UIColor from RGB bytes (0-255)
    convenience init(r: UInt8, g: UInt8, b: UInt8) {
        self.init(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    /// Convert to HSV color space
    var hsv: (h: CGFloat, s: CGFloat, v: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        self.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (h, s, v)
    }

    /// Calculate relative luminance (for contrast calculations)
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)

        // sRGB to linear RGB conversion
        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }

        let R = linearize(r)
        let G = linearize(g)
        let B = linearize(b)

        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }

    /// Calculate contrast ratio with another color (WCAG 2.0)
    func contrastRatio(with other: UIColor) -> CGFloat {
        let l1 = self.luminance
        let l2 = other.luminance
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Get auto-contrasting text color (ensures WCAG AA compliance)
    var autoContrastText: UIColor {
        return self.contrastRatio(with: .white) > 4.5 ? .white : .black
    }
}
