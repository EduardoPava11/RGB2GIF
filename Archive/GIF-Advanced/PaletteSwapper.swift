//
//  PaletteSwapper.swift
//  RGB2GIF
//
//  ============================================================================
//  PALETTE SWAPPER - Hot-Swap 768-byte Global Color Table in GIF Files
//  ============================================================================
//
//  PURPOSE: Replace the 256-color palette in a GIF without re-encoding LZW data.
//           This enables creative color transformations with zero compression cost.
//
//  WHY IS THIS POSSIBLE?
//  ----------------------
//  GIF files store pixel data as INDICES into a color table, not as RGB values.
//  The LZW-compressed data contains sequences like [42, 42, 43, 100, ...] where
//  each number is a palette index. By swapping the palette, we change what colors
//  those indices represent WITHOUT touching the compressed data.
//
//  GIF FILE STRUCTURE (relevant bytes)
//  ------------------------------------
//  Offset    Size    Content
//  ------    ----    -------
//  0         6       Header ("GIF89a")
//  6         2       Width (little-endian)
//  8         2       Height (little-endian)
//  10        1       Packed byte (GCT flag, color resolution, sort, GCT size)
//  11        1       Background color index
//  12        1       Pixel aspect ratio
//  13        768     Global Color Table (256 × 3 bytes) ← WE SWAP THIS!
//  781       ...     Rest of file (unchanged)
//
//  COMPOSABILITY MAGIC
//  --------------------
//  Because RGB2GIF uses SPATIAL INDEXING (luminance-ordered buckets), the indices
//  have CONSISTENT MEANING across all GIFs:
//
//  - Index 0 = darkest region in original video
//  - Index 255 = brightest region in original video
//
//  When you swap palettes between GIFs:
//  - Dark areas get mapped to the donor's dark colors
//  - Bright areas get mapped to the donor's bright colors
//  - The result looks like a "color mood transfer"
//
//  USAGE
//  -----
//  // Load existing GIF and swap its palette
//  let newPalette = SpatialIndexer.sepiaPalette()
//  try PaletteSwapper.swapPalette(at: gifURL, with: newPalette)
//
//  // Or create a new file with the swapped palette
//  try PaletteSwapper.swapPalette(at: sourceGIF, with: palette, to: destinationGIF)
//
//  ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.rgb2gif", category: "PaletteSwapper")

// MARK: - Palette Swapper

/// Swaps the Global Color Table in GIF files without re-encoding LZW data.
/// This enables instant palette transformations and cross-GIF color transfers.
///
/// ## How It Works
/// GIF stores pixel data as palette indices, not RGB values. The Global Color
/// Table (768 bytes at offset 13) maps these indices to actual colors. By
/// replacing this table, we change the appearance without touching the
/// compressed frame data.
///
/// ## Requirements
/// - GIF must have a Global Color Table (no local color tables)
/// - GCT size must be 256 colors (packed byte bits 0-2 = 7)
/// - Both GIFs should use spatial indexing for meaningful swaps
///
/// ## Example
/// ```swift
/// // Apply sepia tone to a GIF
/// let sepia = SpatialIndexer.sepiaPalette()
/// try PaletteSwapper.swapPalette(at: gifURL, with: sepia)
///
/// // Transfer colors from one GIF to another
/// let donorPalette = try PaletteSwapper.extractPalette(from: donorGIF)
/// try PaletteSwapper.swapPalette(at: targetGIF, with: donorPalette)
/// ```
@available(iOS 26.0, *)
public struct PaletteSwapper {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ════════════════════════════════════════════════════════════════════════

    /// Offset to the Global Color Table (after header + LSD)
    public static let gctOffset: Int = 13

    /// Size of the Global Color Table (256 colors × 3 bytes)
    public static let gctSize: Int = 768

    /// Minimum file size for a valid GIF with 256-color GCT
    public static let minimumGIFSize: Int = gctOffset + gctSize + 1  // +1 for trailer

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Extraction
    // ════════════════════════════════════════════════════════════════════════

    /// Extract the Global Color Table from a GIF file.
    ///
    /// - Parameter url: Path to the GIF file
    /// - Returns: Array of 256 RGB color tuples
    /// - Throws: `SwapperError` if file is invalid or doesn't have a 256-color GCT
    public static func extractPalette(from url: URL) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let data = try Data(contentsOf: url)
        return try extractPalette(from: data)
    }

    /// Extract the Global Color Table from GIF data.
    ///
    /// - Parameter data: GIF file data
    /// - Returns: Array of 256 RGB color tuples
    /// - Throws: `SwapperError` if data is invalid
    public static func extractPalette(from data: Data) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        // Validate minimum size
        guard data.count >= minimumGIFSize else {
            throw SwapperError.fileTooSmall(actual: data.count, minimum: minimumGIFSize)
        }

        // Validate header
        let header = String(data: data.prefix(6), encoding: .utf8) ?? ""
        guard header == "GIF89a" || header == "GIF87a" else {
            throw SwapperError.invalidHeader(header)
        }

        // Check for Global Color Table
        let packed = data[10]
        guard (packed & 0x80) != 0 else {
            throw SwapperError.noGlobalColorTable
        }

        // Check GCT size
        let gctSizeExponent = Int(packed & 0x07)
        let gctColorCount = 1 << (gctSizeExponent + 1)
        guard gctColorCount == 256 else {
            throw SwapperError.wrongPaletteSize(expected: 256, actual: gctColorCount)
        }

        // Extract palette
        var palette = [(r: UInt8, g: UInt8, b: UInt8)]()
        palette.reserveCapacity(256)

        for i in 0..<256 {
            let offset = gctOffset + i * 3
            palette.append((
                r: data[offset],
                g: data[offset + 1],
                b: data[offset + 2]
            ))
        }

        logger.debug("PaletteSwapper: Extracted 256-color palette from GIF")
        return palette
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Palette Swapping (In-Place)
    // ════════════════════════════════════════════════════════════════════════

    /// Replace the Global Color Table in a GIF file (modifies file in place).
    ///
    /// - Parameters:
    ///   - url: Path to the GIF file to modify
    ///   - palette: New palette (must have exactly 256 colors)
    /// - Throws: `SwapperError` if operation fails
    public static func swapPalette(
        at url: URL,
        with palette: [(r: UInt8, g: UInt8, b: UInt8)]
    ) throws {
        // Validate palette size
        guard palette.count == 256 else {
            throw SwapperError.wrongPaletteSize(expected: 256, actual: palette.count)
        }

        // Read file
        var data = try Data(contentsOf: url)

        // Validate and swap
        try validateAndSwap(data: &data, with: palette)

        // Write back
        try data.write(to: url)

        logger.info("PaletteSwapper: Swapped palette in \(url.lastPathComponent)")
    }

    /// Replace the Global Color Table and write to a new file.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the source GIF
    ///   - palette: New palette (must have exactly 256 colors)
    ///   - destinationURL: Path for the output GIF
    /// - Throws: `SwapperError` if operation fails
    public static func swapPalette(
        at sourceURL: URL,
        with palette: [(r: UInt8, g: UInt8, b: UInt8)],
        to destinationURL: URL
    ) throws {
        // Validate palette size
        guard palette.count == 256 else {
            throw SwapperError.wrongPaletteSize(expected: 256, actual: palette.count)
        }

        // Read source file
        var data = try Data(contentsOf: sourceURL)

        // Validate and swap
        try validateAndSwap(data: &data, with: palette)

        // Write to destination
        try data.write(to: destinationURL)

        logger.info("PaletteSwapper: Created \(destinationURL.lastPathComponent) with swapped palette")
    }

    /// Swap palette in memory (doesn't write to disk).
    ///
    /// - Parameters:
    ///   - data: GIF data (will be modified in place)
    ///   - palette: New palette
    /// - Throws: `SwapperError` if data is invalid
    public static func swapPaletteInMemory(
        data: inout Data,
        with palette: [(r: UInt8, g: UInt8, b: UInt8)]
    ) throws {
        guard palette.count == 256 else {
            throw SwapperError.wrongPaletteSize(expected: 256, actual: palette.count)
        }

        try validateAndSwap(data: &data, with: palette)
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Private Helpers
    // ════════════════════════════════════════════════════════════════════════

    /// Validate GIF structure and perform the palette swap.
    private static func validateAndSwap(
        data: inout Data,
        with palette: [(r: UInt8, g: UInt8, b: UInt8)]
    ) throws {
        // Validate minimum size
        guard data.count >= minimumGIFSize else {
            throw SwapperError.fileTooSmall(actual: data.count, minimum: minimumGIFSize)
        }

        // Validate header
        let header = String(data: data.prefix(6), encoding: .utf8) ?? ""
        guard header == "GIF89a" || header == "GIF87a" else {
            throw SwapperError.invalidHeader(header)
        }

        // Check for Global Color Table
        let packed = data[10]
        guard (packed & 0x80) != 0 else {
            throw SwapperError.noGlobalColorTable
        }

        // Check GCT size
        let gctSizeExponent = Int(packed & 0x07)
        let gctColorCount = 1 << (gctSizeExponent + 1)
        guard gctColorCount == 256 else {
            throw SwapperError.wrongPaletteSize(expected: 256, actual: gctColorCount)
        }

        // Perform the swap (768 bytes at offset 13)
        for i in 0..<256 {
            let offset = gctOffset + i * 3
            data[offset] = palette[i].r
            data[offset + 1] = palette[i].g
            data[offset + 2] = palette[i].b
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Preset Palettes
    // ════════════════════════════════════════════════════════════════════════

    /// Generate a grayscale palette (index 0 = black, index 255 = white).
    public static func grayscalePalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let gray = UInt8(i)
            return (gray, gray, gray)
        }
    }

    /// Generate a sepia-tone palette.
    public static func sepiaPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let lum = Double(i)
            let r = UInt8(min(255, lum * 1.2))
            let g = UInt8(lum * 0.9)
            let b = UInt8(lum * 0.6)
            return (r, g, b)
        }
    }

    /// Generate an inverted palette (swaps dark and light).
    public static func invertedPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let inverted = UInt8(255 - i)
            return (inverted, inverted, inverted)
        }
    }

    /// Generate a "thermal" palette (cold blue to hot red).
    public static func thermalPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let t = Double(i) / 255.0

            // Cold (blue) → Hot (red) gradient
            let r: UInt8
            let g: UInt8
            let b: UInt8

            if t < 0.25 {
                // Black to blue
                r = 0
                g = 0
                b = UInt8(t * 4 * 255)
            } else if t < 0.5 {
                // Blue to cyan
                let t2 = (t - 0.25) * 4
                r = 0
                g = UInt8(t2 * 255)
                b = 255
            } else if t < 0.75 {
                // Cyan to yellow
                let t2 = (t - 0.5) * 4
                r = UInt8(t2 * 255)
                g = 255
                b = UInt8((1 - t2) * 255)
            } else {
                // Yellow to white
                let t2 = (t - 0.75) * 4
                r = 255
                g = UInt8((1 - t2 * 0.5) * 255)
                b = UInt8(t2 * 255)
            }

            return (r, g, b)
        }
    }

    /// Generate a "neon" palette (saturated colors).
    public static func neonPalette() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return (0..<256).map { i in
            let hue = Double(i) / 256.0 * 360.0
            return hsvToRGB(h: hue, s: 1.0, v: Double(i) / 255.0)
        }
    }

    /// Convert HSV to RGB.
    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        let c = v * s
        let x = c * (1 - abs((h / 60.0).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case 0..<60:   (r1, g1, b1) = (c, x, 0)
        case 60..<120:  (r1, g1, b1) = (x, c, 0)
        case 120..<180: (r1, g1, b1) = (0, c, x)
        case 180..<240: (r1, g1, b1) = (0, x, c)
        case 240..<300: (r1, g1, b1) = (x, 0, c)
        default:        (r1, g1, b1) = (c, 0, x)
        }

        return (
            r: UInt8((r1 + m) * 255),
            g: UInt8((g1 + m) * 255),
            b: UInt8((b1 + m) * 255)
        )
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
extension PaletteSwapper {

    /// Errors that can occur during palette operations
    public enum SwapperError: Error, LocalizedError {
        case fileTooSmall(actual: Int, minimum: Int)
        case invalidHeader(String)
        case noGlobalColorTable
        case wrongPaletteSize(expected: Int, actual: Int)
        case fileNotFound(URL)
        case writeError(Error)

        public var errorDescription: String? {
            switch self {
            case .fileTooSmall(let actual, let minimum):
                return "GIF file too small (\(actual) bytes, minimum \(minimum))"
            case .invalidHeader(let header):
                return "Invalid GIF header: '\(header)' (expected 'GIF89a' or 'GIF87a')"
            case .noGlobalColorTable:
                return "GIF does not have a Global Color Table"
            case .wrongPaletteSize(let expected, let actual):
                return "Palette size mismatch: expected \(expected) colors, got \(actual)"
            case .fileNotFound(let url):
                return "File not found: \(url.path)"
            case .writeError(let error):
                return "Failed to write GIF: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Debug Visualization

@available(iOS 26.0, *)
extension PaletteSwapper {

    /// Compare two palettes and print differences.
    public static func comparePalettes(
        _ palette1: [(r: UInt8, g: UInt8, b: UInt8)],
        _ palette2: [(r: UInt8, g: UInt8, b: UInt8)]
    ) {
        guard palette1.count == 256 && palette2.count == 256 else {
            print("Cannot compare: palettes must both have 256 colors")
            return
        }

        var totalDifference = 0

        print("╔═══════════════════════════════════════════════════════════════╗")
        print("║  PALETTE COMPARISON                                           ║")
        print("╠═══════════════════════════════════════════════════════════════╣")

        for i in stride(from: 0, to: 256, by: 16) {
            let c1 = palette1[i]
            let c2 = palette2[i]
            let diff = abs(Int(c1.r) - Int(c2.r)) +
                       abs(Int(c1.g) - Int(c2.g)) +
                       abs(Int(c1.b) - Int(c2.b))
            totalDifference += diff

            print(String(format: "║  %3d: (%3d,%3d,%3d) → (%3d,%3d,%3d)  Δ=%3d              ║",
                        i, c1.r, c1.g, c1.b, c2.r, c2.g, c2.b, diff))
        }

        let avgDiff = Double(totalDifference) / 256.0
        print("╠═══════════════════════════════════════════════════════════════╣")
        print(String(format: "║  Average difference per color: %.1f                        ║", avgDiff))
        print("╚═══════════════════════════════════════════════════════════════╝")
    }
}
