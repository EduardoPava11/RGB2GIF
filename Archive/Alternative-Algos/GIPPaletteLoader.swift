//
//  GIPPaletteLoader.swift
//  RGB2GIF
//
//  Load GIP palettes from disk and generate luminance-based LUTs
//  Supports palette packs with content-addressed hashing for deduplication
//
//  File Layout:
//  - palettes/Retro.gip
//  - palettes/Film.gip
//  - palettes/Vaporwave.gip
//

import Foundation
import Metal

@available(iOS 26.0, *)
final class GIPPaletteLoader {

    // MARK: - Loaded Palette

    struct LoadedPalette {
        let gip: GIP
        let paletteIndex: Int
        let palette: GIPPalette
        let lut: [UInt8]
        let metalTexture: MTLTexture  // 256×1 RGBA texture for Metal rendering
    }

    // MARK: - Properties

    private let device: MTLDevice
    private var cachedPalettes: [URL: GIP] = [:]

    // MARK: - Initialization

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Loading

    /// Load GIP from disk and cache it
    func loadGIP(from url: URL) throws -> GIP {
        // Check cache first
        if let cached = cachedPalettes[url] {
            return cached
        }

        // Load from disk
        let data = try Data(contentsOf: url)
        let gip = try GIP.deserialize(data)

        // Cache for future use
        cachedPalettes[url] = gip

        print("🎨 Loaded GIP from \(url.lastPathComponent):")
        print("   Version: \(gip.version)")
        print("   Palette count: \(gip.palettes.count)")
        print("   Palette exponent: \(gip.paletteExp)")

        return gip
    }

    /// Load specific palette from GIP and generate LUT + Metal texture
    func loadPalette(
        from gip: GIP,
        paletteIndex: Int,
        lutStrategy: CaptureConfiguration.LUTStrategy = .luminanceBased
    ) throws -> LoadedPalette {
        guard paletteIndex < gip.palettes.count else {
            throw PaletteLoaderError.paletteIndexOutOfRange(paletteIndex, gip.palettes.count)
        }

        let palette = gip.palettes[paletteIndex]

        // Generate LUT based on strategy
        let lut: [UInt8]
        switch lutStrategy {
        case .direct:
            lut = generateDirectLUT(paletteExp: gip.paletteExp)

        case .luminanceBased:
            lut = generateLuminanceLUT(palette: palette, paletteExp: gip.paletteExp)

        case .histogramMatched:
            // TODO: Implement histogram matching
            // Fall back to luminance-based for now
            lut = generateLuminanceLUT(palette: palette, paletteExp: gip.paletteExp)
        }

        // Create Metal texture for palette
        let metalTexture = try createPaletteTexture(palette: palette)

        print("🎨 Loaded palette \(paletteIndex) from \(palette.label):")
        print("   Entry count: \(palette.entryCount)")
        print("   Has transparency: \(palette.hasTransparency)")
        print("   LUT strategy: \(lutStrategy)")

        return LoadedPalette(
            gip: gip,
            paletteIndex: paletteIndex,
            palette: palette,
            lut: lut,
            metalTexture: metalTexture
        )
    }

    /// Load palette by URL and index (convenience method)
    func loadPalette(
        from url: URL,
        paletteIndex: Int,
        lutStrategy: CaptureConfiguration.LUTStrategy = .luminanceBased
    ) throws -> LoadedPalette {
        let gip = try loadGIP(from: url)
        return try loadPalette(from: gip, paletteIndex: paletteIndex, lutStrategy: lutStrategy)
    }

    // MARK: - LUT Generation

    /// Generate direct LUT: LUT[y] = y >> (8 - (paletteExp+1))
    private func generateDirectLUT(paletteExp: UInt8) -> [UInt8] {
        let shift = 8 - (Int(paletteExp) + 1)
        let paletteSize = 1 << (Int(paletteExp) + 1)

        var lut = [UInt8](repeating: 0, count: 256)
        for y in 0..<256 {
            lut[y] = UInt8(min(y >> shift, paletteSize - 1))
        }

        return lut
    }

    /// Generate luminance-based LUT: map Y to nearest palette color by luminance
    /// Reference: Rec.709 luminance formula
    private func generateLuminanceLUT(palette: GIPPalette, paletteExp: UInt8) -> [UInt8] {
        let paletteSize = Int(palette.entryCount)

        // Compute luminance for each palette entry
        let luminances = palette.rgb.map { rgb in
            // Rec.709: Y = 0.2126*R + 0.7152*G + 0.0722*B
            let r = Double(rgb[0])
            let g = Double(rgb[1])
            let b = Double(rgb[2])
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        // Build LUT by finding nearest luminance match for each Y value
        var lut = [UInt8](repeating: 0, count: 256)

        for y in 0..<256 {
            let targetLuminance = Double(y)
            var closestIndex = 0
            var closestDistance = Double.infinity

            for (paletteIdx, luminance) in luminances.enumerated() {
                let distance = abs(luminance - targetLuminance)
                if distance < closestDistance {
                    closestDistance = distance
                    closestIndex = paletteIdx
                }
            }

            lut[y] = UInt8(closestIndex)
        }

        return lut
    }

    // MARK: - Metal Texture Creation

    /// Create 256×1 RGBA Metal texture from palette
    private func createPaletteTexture(palette: GIPPalette) throws -> MTLTexture {
        let paletteSize = Int(palette.entryCount)

        // Create texture descriptor (256×1 RGBA8)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 256,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PaletteLoaderError.textureCreationFailed
        }

        // Convert RGB palette to RGBA bytes
        var rgba = [UInt8](repeating: 0, count: 256 * 4)

        for i in 0..<paletteSize {
            let rgb = palette.rgb[i]
            rgba[i * 4 + 0] = rgb[0]  // R
            rgba[i * 4 + 1] = rgb[1]  // G
            rgba[i * 4 + 2] = rgb[2]  // B
            rgba[i * 4 + 3] = 255     // A (opaque)
        }

        // Handle transparency
        if palette.hasTransparency {
            let transparentIdx = Int(palette.transparentIndex)
            if transparentIdx < paletteSize {
                rgba[transparentIdx * 4 + 3] = 0  // Set alpha to 0
            }
        }

        // Fill remaining entries with black (if palette < 256 colors)
        for i in paletteSize..<256 {
            rgba[i * 4 + 0] = 0    // R
            rgba[i * 4 + 1] = 0    // G
            rgba[i * 4 + 2] = 0    // B
            rgba[i * 4 + 3] = 255  // A
        }

        // Upload to texture
        texture.replace(
            region: MTLRegionMake2D(0, 0, 256, 1),
            mipmapLevel: 0,
            withBytes: rgba,
            bytesPerRow: 256 * 4
        )

        return texture
    }

    // MARK: - Palette Pack Management

    /// List all GIP files in palettes directory
    func listPalettePacks(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return contents.filter { $0.pathExtension == "gip" }
    }

    /// Load all palettes from a directory (for palette picker UI)
    func loadAllPalettePacks(from directory: URL) throws -> [GIP] {
        let urls = try listPalettePacks(in: directory)
        return try urls.map { try loadGIP(from: $0) }
    }

    // MARK: - Cache Management

    /// Clear cached GIP files to free memory
    func clearCache() {
        cachedPalettes.removeAll()
        print("🗑️ GIP palette cache cleared")
    }

    // MARK: - Errors

    enum PaletteLoaderError: Error, CustomStringConvertible {
        case paletteIndexOutOfRange(Int, Int)
        case textureCreationFailed

        var description: String {
            switch self {
            case .paletteIndexOutOfRange(let index, let count):
                return "Palette index \(index) out of range (GIP has \(count) palettes)"
            case .textureCreationFailed:
                return "Failed to create Metal texture for palette"
            }
        }
    }
}
