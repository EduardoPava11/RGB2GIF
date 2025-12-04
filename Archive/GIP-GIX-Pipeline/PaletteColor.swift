//
//  PaletteColor.swift
//  RGB2GIF
//
//  Lightweight RGB color container for palette operations.
//  Designed for modularity: indices are semantic-free 0-255 values.
//  The *meaning* of an index (color, grayscale, depth) comes from the palette.
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Core Palette Color Type

/// A single RGB palette entry.
/// Kept minimal for cache-friendly palette operations.
@available(iOS 26.0, *)
public struct PaletteColor: Sendable, Equatable, Hashable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    @inlinable
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Initialize from RGB array [R, G, B]
    @inlinable
    public init?(rgb: [UInt8]) {
        guard rgb.count == 3 else { return nil }
        self.r = rgb[0]
        self.g = rgb[1]
        self.b = rgb[2]
    }

    /// Initialize from packed ARGB (ignores alpha)
    @inlinable
    public init(argb: UInt32) {
        self.r = UInt8((argb >> 16) & 0xFF)
        self.g = UInt8((argb >> 8) & 0xFF)
        self.b = UInt8(argb & 0xFF)
    }

    /// Convert to RGB array [R, G, B]
    @inlinable
    public var asArray: [UInt8] { [r, g, b] }

    /// Convert to packed ARGB (alpha = 0xFF)
    @inlinable
    public var asARGB: UInt32 {
        return 0xFF000000 | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    /// Luminance (grayscale equivalent) using Rec. 709 coefficients
    @inlinable
    public var luminance: UInt8 {
        // Y = 0.2126 R + 0.7152 G + 0.0722 B
        let y = (Int(r) * 2126 + Int(g) * 7152 + Int(b) * 722) / 10000
        return UInt8(clamping: y)
    }
}

// MARK: - UIKit/CoreGraphics Conversions

@available(iOS 26.0, *)
extension PaletteColor {

    /// Convert to CGColor (sRGB)
    public var cgColor: CGColor {
        return CGColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    /// Convert to UIColor
    public var uiColor: UIColor {
        return UIColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    /// Initialize from UIColor (clamps to sRGB)
    public init(uiColor: UIColor) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        self.r = UInt8(clamping: Int(r * 255))
        self.g = UInt8(clamping: Int(g * 255))
        self.b = UInt8(clamping: Int(b * 255))
    }
}

// MARK: - Common Palette Colors

@available(iOS 26.0, *)
extension PaletteColor {
    public static let black = PaletteColor(r: 0, g: 0, b: 0)
    public static let white = PaletteColor(r: 255, g: 255, b: 255)
    public static let red = PaletteColor(r: 255, g: 0, b: 0)
    public static let green = PaletteColor(r: 0, g: 255, b: 0)
    public static let blue = PaletteColor(r: 0, g: 0, b: 255)
    public static let transparent = PaletteColor(r: 0, g: 0, b: 0) // Index matters, not color
}

// MARK: - Palette Bank Type Alias

/// A palette bank is a collection of palettes (each 2-256 colors).
/// Index into this with `paletteRef` from GIXFrame.
@available(iOS 26.0, *)
public typealias PaletteBank = [[PaletteColor]]

// MARK: - Array Conversions

@available(iOS 26.0, *)
extension Array where Element == PaletteColor {

    /// Convert to legacy [[UInt8]] format for serialization
    public var asLegacyRGB: [[UInt8]] {
        return self.map { $0.asArray }
    }

    /// Create from legacy [[UInt8]] format
    public init?(legacyRGB: [[UInt8]]) {
        var result: [PaletteColor] = []
        for rgb in legacyRGB {
            guard let color = PaletteColor(rgb: rgb) else { return nil }
            result.append(color)
        }
        self = result
    }

    /// Create grayscale ramp (0=black, 255=white)
    public static func grayscaleRamp(count: Int = 256) -> [PaletteColor] {
        precondition(count >= 2 && count <= 256)
        return (0..<count).map { i in
            let gray = UInt8(i * 255 / (count - 1))
            return PaletteColor(r: gray, g: gray, b: gray)
        }
    }

    /// Create fire/heatmap palette (black→red→yellow→white)
    public static func heatmapPalette(count: Int = 256) -> [PaletteColor] {
        precondition(count >= 2 && count <= 256)
        return (0..<count).map { i in
            let t = Float(i) / Float(count - 1)
            let r: UInt8
            let g: UInt8
            let b: UInt8

            if t < 0.33 {
                // Black → Red
                r = UInt8(t * 3.0 * 255)
                g = 0
                b = 0
            } else if t < 0.66 {
                // Red → Yellow
                r = 255
                g = UInt8((t - 0.33) * 3.0 * 255)
                b = 0
            } else {
                // Yellow → White
                r = 255
                g = 255
                b = UInt8((t - 0.66) * 3.0 * 255)
            }
            return PaletteColor(r: r, g: g, b: b)
        }
    }
}

// MARK: - CustomStringConvertible

@available(iOS 26.0, *)
extension PaletteColor: CustomStringConvertible {
    public var description: String {
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
