//
//  GIPGIXComposer.swift
//  RGB2GIF
//
//  Helpers for merging palettes and frames across captures and for
//  recomposing GIF files from existing GIP/GIX assets. Designed for
//  tooling and validation flows (e.g., combining two GIFs or
//  regenerating a GIF after tweaking palettes).
//

import Foundation

@available(iOS 26.0, *)
struct GIPGIXComposer {

    static func merge(gip primary: GIP, with secondary: GIP) throws -> GIP {
        guard primary.paletteExp == secondary.paletteExp else {
            throw ComposerError.mismatchedPaletteExponent(primary.paletteExp, secondary.paletteExp)
        }

        let combinedPalettes = primary.palettes + secondary.palettes
        return try GIP(
            paletteExp: primary.paletteExp,
            name: primary.name + "+" + secondary.name,
            palettes: combinedPalettes,
            hasGlobal: primary.hasGlobal,
            hasFrameSet: primary.hasFrameSet || secondary.hasFrameSet,
            hashAlg: primary.hashAlg,
            backgroundColorIndex: primary.backgroundColorIndex ?? secondary.backgroundColorIndex,
            pixelAspectRatio: primary.pixelAspectRatio ?? secondary.pixelAspectRatio
        )
    }

    static func merge(gix primary: GIX, with secondary: GIX, paletteOffset: UInt32) throws -> GIX {
        guard primary.width == secondary.width && primary.height == secondary.height else {
            throw ComposerError.mismatchedDimensions
        }

        guard primary.lzwMinCodeSize == secondary.lzwMinCodeSize else {
            throw ComposerError.mismatchedLZW(primary.lzwMinCodeSize, secondary.lzwMinCodeSize)
        }

        let adjustedFrames = secondary.frames.map { frame -> GIXFrame in
            GIXFrame(
                paletteRef: frame.paletteRef + paletteOffset,
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
            width: primary.width,
            height: primary.height,
            lzwMinCodeSize: primary.lzwMinCodeSize,
            defaultPaletteRef: primary.defaultPaletteRef,
            name: primary.name + "+" + secondary.name,
            frames: primary.frames + adjustedFrames,
            loopCount: primary.loopCount ?? secondary.loopCount
        )
    }

    static func composeGIF(gip: GIP, gix: GIX, outputURL: URL? = nil) throws -> URL {
        let destination: URL
        if let outputURL {
            destination = outputURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let exportRoot = documents.appendingPathComponent("GIFCompositions", isDirectory: true)
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
            destination = exportRoot
                .appendingPathComponent("composition_\(UUID().uuidString)")
                .appendingPathExtension("gif")
        }

        try GIF89aMuxer.mux(gip: gip, gix: gix, to: destination, loopForever: true)
        return destination
    }

    enum ComposerError: LocalizedError {
        case mismatchedPaletteExponent(UInt8, UInt8)
        case mismatchedDimensions
        case mismatchedLZW(UInt8, UInt8)

        var errorDescription: String? {
            switch self {
            case .mismatchedPaletteExponent(let a, let b):
                return "Palette exponents differ: \(a) vs \(b)"
            case .mismatchedDimensions:
                return "GIX dimensions differ"
            case .mismatchedLZW(let a, let b):
                return "LZW min code size mismatch: \(a) vs \(b)"
            }
        }
    }
}
