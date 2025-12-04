//
//  PaletteInterchange.swift
//  RGB2GIF
//
//  Palette swapping and clip recoloring without re-quantization
//  Enables creative workflows by mixing .gix and .gip files from different clips
//

import Foundation
import CryptoKit
import os.log

private let interchangeLogger = Logger(subsystem: "com.rgb2gif", category: "PaletteInterchange")

// MARK: - Palette Interchange Coordinator

/// Coordinates palette swapping between clips
@available(iOS 26.0, *)
public actor PaletteInterchangeCoordinator {

    // MARK: - Public API

    /// Create a new clip by combining indices from one clip with palettes from another
    /// - Parameters:
    ///   - indicesGIM: Manifest URL for indices source (.gim file)
    ///   - palettesGIM: Manifest URL for palettes source (.gim file)
    ///   - bindMap: Optional custom mapping (frame index → palette index). If nil, uses identity mapping.
    ///   - outputDirectory: Where to write the new .gim manifest
    /// - Returns: URL of the new .gim manifest
    public func createRecoloredClip(
        indicesFrom indicesGIM: URL,
        palettesFrom palettesGIM: URL,
        bindMap: [Int]? = nil,
        outputDirectory: URL
    ) async throws -> URL {

        // 1. Load source manifests
        let indicesManifest = try await loadManifest(from: indicesGIM)
        let palettesManifest = try await loadManifest(from: palettesGIM)

        // 2. Validate compatibility
        try validateCompatibility(
            indicesDims: indicesManifest.dims,
            paletteFrames: palettesManifest.dims.frames,
            bindMap: bindMap
        )

        // 3. Determine binding mode
        let finalBindMap: [Int]
        let bindingMode: GIMV2.BindingMode

        if let customMap = bindMap {
            bindingMode = .explicit
            finalBindMap = customMap
        } else {
            bindingMode = .ident
            finalBindMap = Array(0..<indicesManifest.dims.frames)
        }

        // 4. Locate source files
        let indicesDir = indicesGIM.deletingLastPathComponent()
        let palettesDir = palettesGIM.deletingLastPathComponent()

        let indicesBasename = indicesGIM.deletingPathExtension().lastPathComponent
        let palettesBasename = palettesGIM.deletingPathExtension().lastPathComponent

        let gixURL = indicesDir.appendingPathComponent("\(indicesBasename).gix")
        let gipURL = palettesDir.appendingPathComponent("\(palettesBasename).gip")

        // 5. Verify files exist
        guard FileManager.default.fileExists(atPath: gixURL.path) else {
            throw InterchangeError.missingFile(gixURL)
        }
        guard FileManager.default.fileExists(atPath: gipURL.path) else {
            throw InterchangeError.missingFile(gipURL)
        }

        // 6. Compute SHA-256 hashes
        let gixData = try Data(contentsOf: gixURL)
        let gipData = try Data(contentsOf: gipURL)

        let gixHash = SHA256.hash(data: gixData).hexString
        let gipHash = SHA256.hash(data: gipData).hexString

        // 7. Create new manifest
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")

        let newManifest = GIMV2(
            width: indicesManifest.dims.width,
            height: indicesManifest.dims.height,
            frames: indicesManifest.dims.frames,
            delay_cs: indicesManifest.timing.delay_cs,
            loop: indicesManifest.timing.loop,
            gix_sha256: gixHash,
            gip_sha256: gipHash,
            binding: bindingMode,
            bind_map: bindingMode == .explicit ? finalBindMap : nil,
            meta: GIMV2.Metadata(
                title: "Recolored Clip",
                author: indicesManifest.meta?.author,
                createdAt: timestamp,
                device: await UIDevice.current.model,
                orientation: indicesManifest.meta?.orientation ?? "up"
            )
        )

        // 8. Write new manifest
        let outputBasename = "recolored_\(timestamp)"
        let outputGIM = outputDirectory.appendingPathComponent("\(outputBasename).gim")

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(newManifest)
        try manifestData.write(to: outputGIM, options: .atomic)

        interchangeLogger.info("Created recolored clip: \(outputGIM.lastPathComponent)")
        interchangeLogger.info("  Indices: \(indicesBasename).gix")
        interchangeLogger.info("  Palettes: \(palettesBasename).gip")
        interchangeLogger.info("  Binding: \(bindingMode.rawValue)")

        return outputGIM
    }

    /// Apply a specific palette to all frames
    /// - Parameters:
    ///   - indicesGIM: Source indices manifest
    ///   - paletteIndex: Palette frame index to apply to all frames
    ///   - palettesGIM: Source palettes manifest (if nil, uses same as indices)
    ///   - outputDirectory: Where to write the new manifest
    /// - Returns: URL of the new .gim manifest
    public func applyUniformPalette(
        indicesFrom indicesGIM: URL,
        paletteIndex: Int,
        palettesFrom palettesGIM: URL? = nil,
        outputDirectory: URL
    ) async throws -> URL {

        let indicesManifest = try await loadManifest(from: indicesGIM)
        let paletteSource = palettesGIM ?? indicesGIM

        // Create bind map: all frames use same palette
        let bindMap = [Int](repeating: paletteIndex, count: indicesManifest.dims.frames)

        return try await createRecoloredClip(
            indicesFrom: indicesGIM,
            palettesFrom: paletteSource,
            bindMap: bindMap,
            outputDirectory: outputDirectory
        )
    }

    /// Create a palette animation effect (cycle through palettes)
    /// - Parameters:
    ///   - indicesGIM: Source indices manifest
    ///   - paletteRange: Range of palette indices to cycle through
    ///   - palettesGIM: Source palettes manifest
    ///   - outputDirectory: Where to write the new manifest
    /// - Returns: URL of the new .gim manifest
    public func createPaletteCycle(
        indicesFrom indicesGIM: URL,
        paletteRange: ClosedRange<Int>,
        palettesFrom palettesGIM: URL,
        outputDirectory: URL
    ) async throws -> URL {

        let indicesManifest = try await loadManifest(from: indicesGIM)

        // Create cycling bind map
        var bindMap: [Int] = []
        let cycleLength = paletteRange.count

        for frameIndex in 0..<indicesManifest.dims.frames {
            let paletteIndex = paletteRange.lowerBound + (frameIndex % cycleLength)
            bindMap.append(paletteIndex)
        }

        return try await createRecoloredClip(
            indicesFrom: indicesGIM,
            palettesFrom: palettesGIM,
            bindMap: bindMap,
            outputDirectory: outputDirectory
        )
    }

    // MARK: - Private Helpers

    private func loadManifest(from gimURL: URL) async throws -> GIMV2 {
        let data = try Data(contentsOf: gimURL)
        return try JSONDecoder().decode(GIMV2.self, from: data)
    }

    private func validateCompatibility(
        indicesDims: GIMV2.Dims,
        paletteFrames: Int,
        bindMap: [Int]?
    ) throws {
        // Validate bind_map if provided
        if let map = bindMap {
            guard map.count == indicesDims.frames else {
                throw InterchangeError.invalidBindMapSize(
                    expected: indicesDims.frames,
                    got: map.count
                )
            }

            // Validate all palette indices are in range
            for (frameIndex, paletteIndex) in map.enumerated() {
                guard paletteIndex >= 0 && paletteIndex < paletteFrames else {
                    throw InterchangeError.paletteIndexOutOfRange(
                        frameIndex: frameIndex,
                        paletteIndex: paletteIndex,
                        maxPalette: paletteFrames - 1
                    )
                }
            }
        }
    }
}

// MARK: - Split Format Reader Actor (Memory-Mapped)

/// Async reader with memory-mapped file support for efficient random access
@available(iOS 26.0, *)
public actor SplitFormatReaderActor {

    private let gimURL: URL
    private let gixURL: URL
    private let gipURL: URL

    private let manifest: GIMV2

    // Memory-mapped data for fast random access
    private let gixData: Data
    private let gipData: Data

    // MARK: - Initialization

    public init(gimURL: URL) async throws {
        self.gimURL = gimURL

        // Load manifest
        let manifestData = try Data(contentsOf: gimURL)
        self.manifest = try JSONDecoder().decode(GIMV2.self, from: manifestData)

        // Derive .gix and .gip paths
        let dir = gimURL.deletingLastPathComponent()
        let basename = gimURL.deletingPathExtension().lastPathComponent

        self.gixURL = dir.appendingPathComponent("\(basename).gix")
        self.gipURL = dir.appendingPathComponent("\(basename).gip")

        // Validate files exist
        guard FileManager.default.fileExists(atPath: gixURL.path) else {
            throw InterchangeError.missingFile(gixURL)
        }
        guard FileManager.default.fileExists(atPath: gipURL.path) else {
            throw InterchangeError.missingFile(gipURL)
        }

        // Memory-map files for efficient random access
        self.gixData = try Data(contentsOf: gixURL, options: .alwaysMapped)
        self.gipData = try Data(contentsOf: gipURL, options: .alwaysMapped)

        interchangeLogger.info("SplitFormatReaderActor initialized: \(basename)")
    }

    // MARK: - Reading

    /// Read a specific frame (async, memory-mapped for speed)
    public func readFrame(at index: Int) async throws -> (indices: [UInt8], palette: [UInt8]) {
        guard index < manifest.dims.frames else {
            throw InterchangeError.frameIndexOutOfRange(index, max: manifest.dims.frames - 1)
        }

        // Read indices from .gix (fast random access via memory map)
        let indexOffset = 16 + index * manifest.dims.width * manifest.dims.height
        let indexSize = manifest.dims.width * manifest.dims.height
        let indexRange = indexOffset..<(indexOffset + indexSize)

        guard indexRange.upperBound <= gixData.count else {
            throw InterchangeError.corruptedFile
        }

        let indices = [UInt8](gixData[indexRange])

        // Read palette from .gip (respecting binding)
        let paletteIndex: Int
        switch manifest.binding {
        case .ident:
            paletteIndex = index
        case .explicit:
            guard let bindMap = manifest.bind_map, index < bindMap.count else {
                throw InterchangeError.invalidBindMap
            }
            paletteIndex = bindMap[index]
        }

        let paletteOffset = 16 + paletteIndex * 1024
        let paletteRange = paletteOffset..<(paletteOffset + 1024)

        guard paletteRange.upperBound <= gipData.count else {
            throw InterchangeError.corruptedFile
        }

        let palette = [UInt8](gipData[paletteRange])

        return (indices: indices, palette: palette)
    }

    /// Get manifest
    public func getManifest() async -> GIMV2 {
        return manifest
    }

    /// Verify file integrity (async SHA-256 verification)
    public func verifyIntegrity() async throws -> Bool {
        let gixHash = SHA256.hash(data: gixData).hexString
        let gipHash = SHA256.hash(data: gipData).hexString

        let isValid = gixHash == manifest.integrity.gix_sha256 &&
                     gipHash == manifest.integrity.gip_sha256

        if isValid {
            interchangeLogger.info("Integrity verified ✅")
        } else {
            interchangeLogger.error("Integrity check failed ❌")
        }

        return isValid
    }
}

// MARK: - Errors

@available(iOS 26.0, *)
public enum InterchangeError: LocalizedError {
    case missingFile(URL)
    case invalidBindMapSize(expected: Int, got: Int)
    case paletteIndexOutOfRange(frameIndex: Int, paletteIndex: Int, maxPalette: Int)
    case frameIndexOutOfRange(Int, max: Int)
    case corruptedFile
    case invalidBindMap

    public var errorDescription: String? {
        switch self {
        case .missingFile(let url):
            return "Missing file: \(url.lastPathComponent)"
        case .invalidBindMapSize(let expected, let got):
            return "Invalid bind_map size: expected \(expected), got \(got)"
        case .paletteIndexOutOfRange(let frameIndex, let paletteIndex, let maxPalette):
            return "Frame \(frameIndex): palette index \(paletteIndex) out of range [0..\(maxPalette)]"
        case .frameIndexOutOfRange(let index, let max):
            return "Frame index \(index) out of range [0..\(max)]"
        case .corruptedFile:
            return "Corrupted file data"
        case .invalidBindMap:
            return "Invalid bind_map in manifest"
        }
    }
}

// MARK: - Usage Examples

/*

 Example 1: Apply single palette to all frames
 ```swift
 let coordinator = PaletteInterchangeCoordinator()

 let recoloredURL = try await coordinator.applyUniformPalette(
     indicesFrom: originalClipGIM,
     paletteIndex: 50,  // Use palette from frame 50
     outputDirectory: outputDir
 )
 ```

 Example 2: Cycle through palette range
 ```swift
 let cycledURL = try await coordinator.createPaletteCycle(
     indicesFrom: indicesGIM,
     paletteRange: 0...15,  // Cycle through first 16 palettes
     palettesFrom: palettesGIM,
     outputDirectory: outputDir
 )
 ```

 Example 3: Custom palette mapping
 ```swift
 var customMap = Array(0..<128)
 customMap[0..<10] = Array(repeating: 50, count: 10)  // Frames 0-9 use palette 50

 let customURL = try await coordinator.createRecoloredClip(
     indicesFrom: indicesGIM,
     palettesFrom: palettesGIM,
     bindMap: customMap,
     outputDirectory: outputDir
 )
 ```

 Example 4: Read and verify
 ```swift
 let reader = try await SplitFormatReaderActor(gimURL: recoloredURL)

 // Verify integrity
 let isValid = try await reader.verifyIntegrity()

 // Read specific frame
 let (indices, palette) = try await reader.readFrame(at: 37)
 ```

 */
