//
//  GIPGIXMerger.swift
//  RGB2GIF
//
//  Modular merging utilities for GIP (palette) and GIX (indices).
//  Enables "mix and match" workflows:
//    - GIX from capture A + GIP from capture B
//    - Palette swapping without re-capturing
//    - Multiple style palettes for same index data
//
//  Design Philosophy:
//    - GIX = pure 8-bit index field (0-255 scalars, semantic-free)
//    - GIP = palette bank (gives meaning to indices)
//    - Merging is explicit, not magic
//

import Foundation

// MARK: - GIPGIXPair (Ready-to-Render Pair)

/// A validated pairing of GIP (palettes) and GIX (indices).
/// Use this when you need a "ready to render" combination.
@available(iOS 26.0, *)
public struct GIPGIXPair: Sendable {
    public let gip: GIP
    public let gix: GIX

    /// Create a validated pair
    /// - Throws: GIPGIXCompatibilityError if pairing is invalid
    public init(gip: GIP, gix: GIX) throws {
        try GIPGIXStructuralValidator.validateComponents(gip: gip, gix: gix)
        self.gip = gip
        self.gix = gix
    }

    /// Canvas dimensions from GIX
    public var canvasWidth: UInt16 { gix.width }
    public var canvasHeight: UInt16 { gix.height }

    /// Frame count from GIX
    public var frameCount: Int { gix.frames.count }

    /// Primary palette (from GIP)
    public var primaryPalette: [[UInt8]] { gip.rgb }
}

// MARK: - Compatibility Errors

@available(iOS 26.0, *)
public enum GIPGIXCompatibilityError: LocalizedError {
    case paletteRefOutOfRange(frameIndex: Int, paletteRef: Int, maxRef: Int)
    case paletteExponentTooLarge(exponent: UInt8, maxColors: Int)
    case emptyPaletteBank
    case emptyFrames

    public var errorDescription: String? {
        switch self {
        case .paletteRefOutOfRange(let frame, let ref, let max):
            return "Frame \(frame) references palette \(ref), but only \(max) palettes available"
        case .paletteExponentTooLarge(let exp, let max):
            return "Palette exponent \(exp) yields > \(max) colors (GIF limit)"
        case .emptyPaletteBank:
            return "GIP contains no palettes"
        case .emptyFrames:
            return "GIX contains no frames"
        }
    }
}

// MARK: - Structural Validator

/// Validates structural compatibility between GIP and GIX.
/// Does NOT check index values (0-255 are always valid).
/// Only checks that paletteRefs point to existing palettes.
@available(iOS 26.0, *)
public struct GIPGIXStructuralValidator {

    /// Check that every frame's `paletteRef` is valid within `gip.palettes`.
    /// Does NOT reject any index values 0-255: that's left to palette semantics.
    public static func validateComponents(gip: GIP, gix: GIX) throws {
        // Check GIP has palettes
        guard !gip.palettes.isEmpty else {
            throw GIPGIXCompatibilityError.emptyPaletteBank
        }

        // Check GIX has frames
        guard !gix.frames.isEmpty else {
            throw GIPGIXCompatibilityError.emptyFrames
        }

        let paletteBankCount = gip.palettes.count

        // Validate each frame's paletteRef
        for (i, frame) in gix.frames.enumerated() {
            let ref = Int(frame.paletteRef)
            if ref < 0 || ref >= paletteBankCount {
                throw GIPGIXCompatibilityError.paletteRefOutOfRange(
                    frameIndex: i,
                    paletteRef: ref,
                    maxRef: paletteBankCount - 1
                )
            }
        }

        // Validate palette size is within GIF limits (≤256 colors)
        let maxColors = 1 << (Int(gip.paletteExp) + 1)
        guard maxColors <= 256 else {
            throw GIPGIXCompatibilityError.paletteExponentTooLarge(
                exponent: gip.paletteExp,
                maxColors: 256
            )
        }
    }

    /// Quick check if GIX is compatible with GIP
    public static func isCompatible(gip: GIP, gix: GIX) -> Bool {
        do {
            try validateComponents(gip: gip, gix: gix)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Merger Errors

@available(iOS 26.0, *)
public enum GIPGIXMergeError: LocalizedError {
    case paletteRefOutOfRange(oldRef: Int, newRef: Int, maxRef: Int)
    case missingMapping(oldRef: Int)

    public var errorDescription: String? {
        switch self {
        case .paletteRefOutOfRange(let oldRef, let newRef, let maxRef):
            return "Cannot map palette \(oldRef) → \(newRef): target has only \(maxRef + 1) palettes"
        case .missingMapping(let oldRef):
            return "No mapping provided for palette ref \(oldRef)"
        }
    }
}

// MARK: - GIPGIXMerger

/// Utilities for merging and adapting GIX from one palette environment to another.
@available(iOS 26.0, *)
public struct GIPGIXMerger {

    // MARK: - Palette Ref Relabeling (Trivial Merge)

    /// Returns a new GIX whose frames have paletteRefs remapped to a new GIP.
    /// Use this when you want the same indices but different palette interpretation.
    ///
    /// Example: Depth capture with grayscale palette → remap to heatmap palette
    ///
    /// - Parameters:
    ///   - original: Source GIX with paletteRefs for original palette bank
    ///   - targetGIP: New palette bank to use
    ///   - refMapping: Maps oldRef (from source GIX) → newRef (valid in target GIP)
    ///                 If nil, uses identity mapping (oldRef == newRef)
    /// - Returns: New GIX with remapped paletteRefs
    public static func relabelPaletteRefs(
        original: GIX,
        targetGIP: GIP,
        refMapping: [Int: Int]? = nil
    ) throws -> GIX {
        let maxPaletteIndex = targetGIP.palettes.count - 1

        let newFrames: [GIXFrame] = try original.frames.enumerated().map { (idx, frame) in
            let oldRef = Int(frame.paletteRef)

            // Apply mapping or use identity
            let newRef: Int
            if let mapping = refMapping {
                guard let mapped = mapping[oldRef] else {
                    throw GIPGIXMergeError.missingMapping(oldRef: oldRef)
                }
                newRef = mapped
            } else {
                newRef = oldRef
            }

            // Validate new ref is in range
            guard newRef >= 0 && newRef <= maxPaletteIndex else {
                throw GIPGIXMergeError.paletteRefOutOfRange(
                    oldRef: oldRef,
                    newRef: newRef,
                    maxRef: maxPaletteIndex
                )
            }

            // Create new frame with updated paletteRef
            return GIXFrame(
                paletteRef: UInt32(newRef),
                delay: frame.delay,
                disposal: frame.disposal,
                transparency: frame.transparency,
                transparentIndex: frame.transparentIndex,
                dataEncoding: frame.dataEncoding,
                payload: frame.payload,
                left: frame.left,
                top: frame.top,
                frameWidth: frame.frameWidth,
                frameHeight: frame.frameHeight,
                interlaced: frame.interlaced
            )
        }

        // Remap defaultPaletteRef too
        let newDefaultRef: UInt32
        if let mapping = refMapping {
            let oldDefault = Int(original.defaultPaletteRef)
            if let mapped = mapping[oldDefault] {
                newDefaultRef = UInt32(mapped)
            } else {
                newDefaultRef = 0 // Fallback to first palette
            }
        } else {
            newDefaultRef = original.defaultPaletteRef
        }

        return try GIX(
            width: original.width,
            height: original.height,
            lzwMinCodeSize: original.lzwMinCodeSize,
            defaultPaletteRef: newDefaultRef,
            name: original.name,
            frames: newFrames,
            loopCount: original.loopCount
        )
    }

    // MARK: - Palette Swapping Convenience

    /// Swap all frames to use a single palette from the target GIP.
    /// Useful for "style transfer" where you want all frames using the same palette.
    ///
    /// - Parameters:
    ///   - original: Source GIX
    ///   - targetGIP: Target palette bank
    ///   - paletteIndex: Which palette in targetGIP to use for all frames
    /// - Returns: New GIX with all frames pointing to paletteIndex
    public static func swapAllToPalette(
        original: GIX,
        targetGIP: GIP,
        paletteIndex: Int
    ) throws -> GIX {
        guard paletteIndex >= 0 && paletteIndex < targetGIP.palettes.count else {
            throw GIPGIXMergeError.paletteRefOutOfRange(
                oldRef: 0,
                newRef: paletteIndex,
                maxRef: targetGIP.palettes.count - 1
            )
        }

        let newFrames: [GIXFrame] = original.frames.map { frame in
            GIXFrame(
                paletteRef: UInt32(paletteIndex),
                delay: frame.delay,
                disposal: frame.disposal,
                transparency: frame.transparency,
                transparentIndex: frame.transparentIndex,
                dataEncoding: frame.dataEncoding,
                payload: frame.payload,
                left: frame.left,
                top: frame.top,
                frameWidth: frame.frameWidth,
                frameHeight: frame.frameHeight,
                interlaced: frame.interlaced
            )
        }

        return try GIX(
            width: original.width,
            height: original.height,
            lzwMinCodeSize: original.lzwMinCodeSize,
            defaultPaletteRef: UInt32(paletteIndex),
            name: original.name,
            frames: newFrames,
            loopCount: original.loopCount
        )
    }

    // MARK: - Palette Bank Concatenation

    /// Combine multiple GIPs into a single palette bank.
    /// Useful when you want multiple style palettes available for the same GIX.
    ///
    /// - Parameters:
    ///   - gips: Array of GIPs to combine
    ///   - name: Name for the combined GIP
    /// - Returns: Combined GIP with all palettes from all inputs
    public static func combinePaletteBanks(
        _ gips: [GIP],
        name: String = "combined"
    ) throws -> GIP {
        guard !gips.isEmpty else {
            throw GIPGIXCompatibilityError.emptyPaletteBank
        }

        // All GIPs must have same paletteExp
        let paletteExp = gips[0].paletteExp
        guard gips.allSatisfy({ $0.paletteExp == paletteExp }) else {
            throw GIP.GIPError.inconsistentPaletteSizes
        }

        // Combine all palettes
        let combinedPalettes = gips.flatMap { $0.palettes }

        return try GIP(
            paletteExp: paletteExp,
            name: name,
            palettes: combinedPalettes,
            hasGlobal: true,
            hasFrameSet: false,
            hashAlg: .sha256
        )
    }
}

// MARK: - GIX Extension for Modular Operations

@available(iOS 26.0, *)
extension GIX {

    /// Canvas size as CGSize
    public var canvasSize: CGSize {
        CGSize(width: Int(width), height: Int(height))
    }

    /// Create a new GIX with updated loop count
    public func withLoopCount(_ count: UInt16?) throws -> GIX {
        return try GIX(
            width: width,
            height: height,
            lzwMinCodeSize: lzwMinCodeSize,
            defaultPaletteRef: defaultPaletteRef,
            name: name,
            frames: frames,
            loopCount: count
        )
    }

    /// Create a new GIX with subset of frames
    public func withFrames(_ range: Range<Int>) throws -> GIX {
        let subset = Array(frames[range])
        return try GIX(
            width: width,
            height: height,
            lzwMinCodeSize: lzwMinCodeSize,
            defaultPaletteRef: defaultPaletteRef,
            name: name,
            frames: subset,
            loopCount: loopCount
        )
    }
}

// MARK: - GIP Extension for PaletteColor Support

@available(iOS 26.0, *)
extension GIP {

    /// Get palette as array of PaletteColor (first palette)
    public var primaryPaletteColors: [PaletteColor] {
        guard let first = palettes.first else { return [] }
        return first.rgb.compactMap { PaletteColor(rgb: $0) }
    }

    /// Get all palettes as PaletteColor arrays
    public var allPaletteColors: [[PaletteColor]] {
        return palettes.map { palette in
            palette.rgb.compactMap { PaletteColor(rgb: $0) }
        }
    }

    /// Create GIP from PaletteColor array
    public static func create(colors: [PaletteColor]) throws -> GIP {
        let rgb = colors.map { $0.asArray }
        return try GIP.create(rgb: rgb)
    }

    /// Create GIP with multiple palettes from PaletteColor arrays
    public static func create(
        paletteColors: [[PaletteColor]],
        name: String = "GIP2"
    ) throws -> GIP {
        guard !paletteColors.isEmpty else {
            throw GIPError.emptyPaletteSet
        }

        // Find required paletteExp
        let maxCount = paletteColors.map { $0.count }.max() ?? 0
        guard maxCount >= 2 && maxCount <= 256 else {
            throw GIPError.invalidPaletteSize(maxCount, expected: 256)
        }

        var paletteExp: UInt8 = 0
        while (1 << (Int(paletteExp) + 1)) < maxCount {
            paletteExp += 1
        }

        let requiredSize = 1 << (Int(paletteExp) + 1)

        // Convert to GIPPalettes with padding
        let gipPalettes: [GIPPalette] = try paletteColors.enumerated().map { (idx, colors) in
            var rgb = colors.map { $0.asArray }
            while rgb.count < requiredSize {
                rgb.append([0, 0, 0]) // Pad with black
            }

            return GIPPalette(
                entryCount: UInt16(requiredSize),
                dims: 1,
                dimA: UInt16(requiredSize),
                dimB: 1,
                ordering: .rowMajor,
                hasTransparency: false,
                transparentIndex: 0,
                label: "palette_\(idx)",
                rgb: rgb,
                remap: nil,
                hash: nil
            )
        }

        return try GIP(
            paletteExp: paletteExp,
            name: name,
            palettes: gipPalettes,
            hasGlobal: true,
            hasFrameSet: paletteColors.count > 1
        )
    }
}

// MARK: - Usage Examples

/*
 ═══════════════════════════════════════════════════════════════════════════════
 Example 1: Depth → Heatmap Palette Swap
 ═══════════════════════════════════════════════════════════════════════════════

 This example demonstrates the "mix and match" workflow:
 - Capture depth data as grayscale (index 0 = near, 255 = far)
 - Re-interpret the SAME indices with a heatmap palette for visualization
 - No re-capture or re-quantization needed!

 ```swift
 // Step 1: Create depth capture with grayscale palette
 let grayscalePalette = [PaletteColor].grayscaleRamp(count: 256)

 // Step 2: Capture depth data (indices are depth values 0-255)
 // This would come from your depth sensor / LiDAR
 let depthIndices: [UInt8] = captureDepthData()

 // Step 3: Create GIP + GIX from grayscale capture
 let depthResult = try GIPGIXBridge.convert(
     colors: grayscalePalette,
     indices: depthIndices,
     width: 80,
     height: 80,
     delay: 10
 )

 // Step 4: Export grayscale GIF (optional)
 try depthResult.muxToGIF(outputURL: grayscaleURL)

 // ═══════════════════════════════════════════════════════════════════════
 // KEY INSIGHT: Now we can re-interpret the SAME depth data with any palette!
 // The GIX (indices) stays the same, only the GIP (palette) changes.
 // ═══════════════════════════════════════════════════════════════════════

 // Step 5: Create heatmap palette (black → red → yellow → white)
 let heatmapPalette = [PaletteColor].heatmapPalette(count: 256)
 let heatmapGIP = try GIP.create(colors: heatmapPalette)

 // Step 6: Use GIPGIXBridgeResult's built-in palette swap
 let heatmapResult = try depthResult.withHeatmapPalette()

 // Step 7: Export heatmap GIF (same indices, different colors!)
 try heatmapResult.muxToGIF(outputURL: heatmapURL)

 // Alternative: Use GIPGIXMerger for more control
 let heatmapGIX = try GIPGIXMerger.swapAllToPalette(
     original: depthResult.gix,
     targetGIP: heatmapGIP,
     paletteIndex: 0
 )
 let heatmapPair = try GIPGIXPair(gip: heatmapGIP, gix: heatmapGIX)
 try GIF89aMuxer.mux(gip: heatmapPair.gip, gix: heatmapPair.gix, to: heatmapURL)
 ```

 ═══════════════════════════════════════════════════════════════════════════════
 Example 2: Multi-Palette Animation (Palette Bank)
 ═══════════════════════════════════════════════════════════════════════════════

 Create an animation where each frame uses a different palette from a bank.

 ```swift
 // Create multiple style palettes
 let palettes: [[PaletteColor]] = [
     [PaletteColor].grayscaleRamp(count: 256),    // Style 0: Grayscale
     [PaletteColor].heatmapPalette(count: 256),   // Style 1: Heatmap
     createSepiaPalette(),                         // Style 2: Sepia
     createNightVisionPalette()                    // Style 3: Night vision
 ]

 // Create GIP with all palettes
 let multiGIP = try GIP.create(paletteColors: palettes, name: "multi-style")

 // Create frames, each referencing a different palette
 var frames: [GIXFrame] = []
 for (i, frameData) in capturedFrames.enumerated() {
     let paletteRef = UInt32(i % palettes.count)  // Cycle through palettes
     let lzwPayload = try LZW_Optimized.compress(
         indices: frameData.indices,
         minCodeSize: 8
     ).reduce(Data()) { $0 + $1 }

     frames.append(GIXFrame(
         paletteRef: paletteRef,  // <-- Each frame can use different palette!
         delay: 10,
         disposal: 0,
         transparency: false,
         transparentIndex: 0,
         dataEncoding: .lzwSubblocks,
         payload: lzwPayload,
         left: 0, top: 0,
         frameWidth: 80, frameHeight: 80,
         interlaced: false
     ))
 }

 let gix = try GIX(
     width: 80, height: 80,
     lzwMinCodeSize: 8,
     defaultPaletteRef: 0,
     name: "multi-style-anim",
     frames: frames,
     loopCount: 0
 )

 // Validate and export
 let pair = try GIPGIXPair(gip: multiGIP, gix: gix)
 try GIF89aMuxer.mux(gip: pair.gip, gix: pair.gix, to: outputURL)
 ```

 ═══════════════════════════════════════════════════════════════════════════════
 Example 3: Combining Palette Banks
 ═══════════════════════════════════════════════════════════════════════════════

 Merge palettes from multiple captures into a single palette bank.

 ```swift
 // Two separate captures with their own palettes
 let captureA = try loadGIPFromFile("captureA.gip")  // Palettes 0-2
 let captureB = try loadGIPFromFile("captureB.gip")  // Palettes 0-1

 // Combine into single palette bank
 let combined = try GIPGIXMerger.combinePaletteBanks(
     [captureA, captureB],
     name: "combined"
 )
 // combined now has palettes 0-4 (3 from A + 2 from B)

 // Remap captureB's GIX to use new palette indices
 let remappedGIX = try GIPGIXMerger.relabelPaletteRefs(
     original: captureBGIX,
     targetGIP: combined,
     refMapping: [0: 3, 1: 4]  // B's 0,1 → combined's 3,4
 )
 ```
 */
