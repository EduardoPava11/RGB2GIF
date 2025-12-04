//
//  GIF81TestHarness.swift
//  RGB2GIF Tests
//
//  ============================================================================
//  MVP0 TEST HARNESS: Validate Pipeline Before NN Integration
//  ============================================================================
//
//  MVP STAGES
//  ──────────
//  MVP0: Basic GIF generation (this test)
//        - Synthetic frames → MacroCellDigest → Uniform weights → GIF
//        - No games, but structure ready for them
//
//  MVP1: Add dual GO games
//        - Same digest, but weights come from spatial/temporal games
//        - DualGameWeights replaces uniform weights
//
//  MVP2: Transformer learning
//        - GameSessionRecorder captures moves
//        - PreferenceTransformer learns patterns
//        - Preset generation
//
//  WHY COMPUTE DIGEST IN MVP0?
//  ───────────────────────────
//  The MacroCellDigest is REQUIRED for NN games to work:
//    - NN needs to "see" what each macro-cell contains
//    - 729 embeddings (81D each) describe the video structure (= 3¹⁰ total)
//    - Games operate on this digest, not raw pixels
//
//  By computing digest in MVP0, we ensure:
//    1. The pipeline works end-to-end
//    2. Digest computation is tested before games need it
//    3. Adding games later is just replacing weight source
//
//  TEST PATTERNS
//  ─────────────
//  We generate several test patterns to stress different aspects:
//
//    GRADIENT:     Smooth color transitions (tests palette diversity)
//    CHECKERBOARD: Alternating colors (tests LZW compression)
//    SOLID:        81 solid color frames (tests frame independence)
//    CONCENTRIC:   Expanding rings (tests spatial indexing)
//    TEMPORAL:     Color that changes over frames (tests temporal digest)
//
//  ============================================================================

import Foundation
import CoreGraphics

// MARK: - Test Harness

@available(iOS 26.0, *)
public struct GIF81TestHarness {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Test Patterns
    // ════════════════════════════════════════════════════════════════════════

    /// Available test patterns for synthetic frame generation
    public enum TestPattern: String, CaseIterable {
        case gradient       // RGB gradient across space
        case checkerboard   // Alternating black/white
        case solidColors    // Each frame is a solid color
        case concentricRings // Circles expanding from center
        case temporalWave   // Color wave moving through time
        case rainbowTiles   // Each 9×9 tile is a different hue

        public var description: String {
            switch self {
            case .gradient:
                return "Smooth RGB gradient (tests palette diversity)"
            case .checkerboard:
                return "B/W checkerboard (tests LZW compression)"
            case .solidColors:
                return "81 solid colors (tests frame independence)"
            case .concentricRings:
                return "Expanding circles (tests spatial coherence)"
            case .temporalWave:
                return "Color wave over time (tests temporal digest)"
            case .rainbowTiles:
                return "Rainbow 9×9 tiles (tests macro-cell boundaries)"
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Frame Generation
    // ════════════════════════════════════════════════════════════════════════

    /// Generate 81 synthetic frames for testing.
    ///
    /// - Parameter pattern: Which test pattern to generate
    /// - Returns: Array of 81 CGImages, each 81×81 pixels
    public static func generateFrames(pattern: TestPattern) throws -> [CGImage] {
        var frames = [CGImage]()
        frames.reserveCapacity(81)

        for frameIndex in 0..<81 {
            let image = try generateFrame(index: frameIndex, pattern: pattern)
            frames.append(image)
        }

        return frames
    }

    /// Generate a single frame.
    private static func generateFrame(index: Int, pattern: TestPattern) throws -> CGImage {
        let width = 81
        let height = 81
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let (r, g, b) = colorFor(x: x, y: y, frame: index, pattern: pattern)

                pixels[offset] = r      // R
                pixels[offset + 1] = g  // G
                pixels[offset + 2] = b  // B
                pixels[offset + 3] = 255 // A
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage() else {
            throw TestError.frameGenerationFailed(index)
        }

        return image
    }

    /// Calculate color for a pixel based on pattern.
    private static func colorFor(x: Int, y: Int, frame: Int, pattern: TestPattern) -> (UInt8, UInt8, UInt8) {
        switch pattern {
        case .gradient:
            // RGB gradient: R increases with X, G with Y, B with frame
            let r = UInt8(x * 255 / 80)
            let g = UInt8(y * 255 / 80)
            let b = UInt8(frame * 255 / 80)
            return (r, g, b)

        case .checkerboard:
            // 9×9 checkerboard pattern, alternates per frame
            let tileX = x / 9
            let tileY = y / 9
            let isEven = (tileX + tileY + frame) % 2 == 0
            let v: UInt8 = isEven ? 255 : 0
            return (v, v, v)

        case .solidColors:
            // Each frame is a single color from HSL wheel
            let hue = Float(frame) / 81.0
            return hslToRGB(h: hue, s: 0.8, l: 0.5)

        case .concentricRings:
            // Rings expanding from center, color based on frame
            let cx = 40.0
            let cy = 40.0
            let dx = Double(x) - cx
            let dy = Double(y) - cy
            let distance = sqrt(dx * dx + dy * dy)

            // Ring pattern (distance + frame offset) mod period
            let period = 10.0
            let phase = (distance + Double(frame)) / period
            let intensity = UInt8((sin(phase * .pi * 2) + 1) / 2 * 255)

            // Hue based on frame
            let hue = Float(frame) / 81.0
            let (r, g, b) = hslToRGB(h: hue, s: 0.7, l: Float(intensity) / 255.0 * 0.5 + 0.25)
            return (r, g, b)

        case .temporalWave:
            // Color wave moving through time
            // At each frame, a "wave" of brightness sweeps across
            let wavePosition = Float(frame) / 81.0 * Float(81 + 20) - 10
            let pixelDistance = abs(Float(x) - wavePosition)
            let intensity = max(0, 1.0 - pixelDistance / 10.0)

            let r = UInt8(intensity * 255)
            let g = UInt8(Float(y) / 80.0 * 128 + 64)
            let b = UInt8(Float(frame) / 80.0 * 128 + 64)
            return (r, g, b)

        case .rainbowTiles:
            // Each 9×9 tile gets a unique hue, brightness varies with frame
            let tileX = x / 9
            let tileY = y / 9
            let tileIndex = tileY * 9 + tileX

            let hue = Float(tileIndex) / 81.0
            let lightness = 0.3 + Float(frame) / 81.0 * 0.4  // 0.3 to 0.7
            return hslToRGB(h: hue, s: 0.8, l: lightness)
        }
    }

    /// Convert HSL to RGB.
    private static func hslToRGB(h: Float, s: Float, l: Float) -> (UInt8, UInt8, UInt8) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(fmod(h * 6, 2) - 1))
        let m = l - c / 2

        var r: Float = 0, g: Float = 0, b: Float = 0

        switch h * 6 {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default:    (r, g, b) = (c, 0, x)
        }

        return (
            UInt8((r + m) * 255),
            UInt8((g + m) * 255),
            UInt8((b + m) * 255)
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Full Pipeline Test
    // ════════════════════════════════════════════════════════════════════════

    /// Run the complete MVP0 pipeline with a test pattern.
    ///
    /// This tests:
    /// 1. Frame generation (synthetic)
    /// 2. MacroCellDigest computation (729 embeddings × 81D = 59,049 features)
    /// 3. ColorVectorSpace construction (732D per unique color = 3 RGB + 729 cell presence)
    /// 4. Dual palette selection (256 spatial + 256 temporal)
    /// 5. CIEDE2000 palette merge → final 256 colors
    /// 6. GIF writing
    /// 7. Output validation
    ///
    /// - Parameters:
    ///   - pattern: Test pattern to use
    ///   - outputDirectory: Where to save the GIF
    /// - Returns: Validation report
    public static func runPipelineTest(
        pattern: TestPattern,
        outputDirectory: URL
    ) async throws -> ValidationReport {

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  MVP0 PIPELINE TEST: \(pattern.rawValue.padding(toLength: 42, withPad: " ", startingAt: 0)) ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")

        var report = ValidationReport(pattern: pattern)

        // ─────────────────────────────────────────────────────────────────────
        // Step 1: Generate Frames
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 1: Generating 81 synthetic frames...                        ║")

        let startGenerate = Date()
        let frames = try generateFrames(pattern: pattern)
        report.frameGenerationTime = Date().timeIntervalSince(startGenerate)
        report.frameCount = frames.count

        print("║          ✓ Generated \(frames.count) frames in \(String(format: "%.2f", report.frameGenerationTime))s                      ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 2: Compute MacroCellDigest
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 2: Computing MacroCellDigest (729 × 81 = 59,049 features).. ║")

        let startDigest = Date()
        let digest = try MacroCellDigest.compute(from: frames)
        report.digestComputeTime = Date().timeIntervalSince(startDigest)
        report.cellCount = digest.cells.count
        report.featureDimension = MacroCellDigest.featureDimension

        print("║          ✓ Digest computed in \(String(format: "%.2f", report.digestComputeTime))s                           ║")
        print("║          ✓ \(report.cellCount) cells × \(report.featureDimension)D = \(report.cellCount * report.featureDimension) features          ║")

        // Validate digest is ready for NN games
        report.digestValidForNN = validateDigestForNN(digest)
        let nnStatus = report.digestValidForNN ? "✓" : "✗"
        print("║          \(nnStatus) Digest compatible with future NN games              ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 3: Build Color Vector Space
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 3: Building Color Vector Space (732D per color)...          ║")

        let startVectorSpace = Date()
        let colorSpace = try ColorVectorSpace.build(from: frames)
        let vectorSpaceTime = Date().timeIntervalSince(startVectorSpace)
        report.uniqueColorsFound = colorSpace.uniqueColorCount

        print("║          ✓ Found \(String(format: "%5d", colorSpace.uniqueColorCount)) unique colors in \(String(format: "%.2f", vectorSpaceTime))s              ║")
        print("║          ✓ Each color = RGB(3D) + cell_presence(729D) = 732D     ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 4: Create Uniform Weights (MVP0 placeholder)
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 4: Creating uniform weights (MVP0 - no games)...            ║")

        // In MVP1, this will be: DualGameWeights from actual games
        // For MVP0, we use uniform 9×9 weights
        let uniformWeights = [[Float]](
            repeating: [Float](repeating: 0.5, count: 9),
            count: 9
        )
        report.weightStrategy = "uniform (MVP0)"

        print("║          ✓ Using uniform weights (all 0.5)                        ║")
        print("║          ✓ Ready for GO game weights in MVP1                      ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 5: Select Dual Palettes (256 + 256)
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 5: Selecting dual palettes (256 spatial + 256 temporal)...  ║")

        let startSelection = Date()
        let (spatialPalette, temporalPalette) = colorSpace.selectBothPalettes(
            spatialWeights: uniformWeights,
            temporalWeights: uniformWeights
        )
        let selectionTime = Date().timeIntervalSince(startSelection)

        print("║          ✓ Spatial palette: 256 colors selected                   ║")
        print("║          ✓ Temporal palette: 256 colors selected                  ║")
        print("║          ✓ Selection time: \(String(format: "%.2f", selectionTime))s                              ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 6: Merge Palettes via CIEDE2000
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 6: Merging palettes (CIEDE2000 perceptual distance)...      ║")

        let startMerge = Date()

        // Analyze merge before doing it
        let mergeStats = ColorMerger.analyzeMerge(
            spatialPalette: spatialPalette,
            temporalPalette: temporalPalette
        )
        report.exactMatches = mergeStats.exactMatches
        report.similarMerges = mergeStats.similarMerges

        // Perform the merge
        let palette = ColorMerger.merge(
            spatialPalette: spatialPalette,
            temporalPalette: temporalPalette
        )
        report.paletteComputeTime = Date().timeIntervalSince(startMerge) + selectionTime
        report.paletteSize = palette.count

        // Count unique colors in final palette
        let uniqueColors = Set(palette.map { "\($0.0),\($0.1),\($0.2)" }).count
        report.uniqueColorsInPalette = uniqueColors

        print("║          ✓ Exact matches (both games agree): \(String(format: "%3d", mergeStats.exactMatches))                ║")
        print("║          ✓ Similar merges (CIEDE2000 < 5.0): \(String(format: "%3d", mergeStats.similarMerges))                ║")
        print("║          ✓ Final palette: \(uniqueColors) unique colors                     ║")
        print("║          ✓ Agreement rate: \(String(format: "%.1f%%", mergeStats.agreementRate * 100))                            ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 7: Index Frames
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 7: Indexing frames to palette...                            ║")

        let startIndex = Date()
        let indexedFrames = indexFramesToPalette(frames: frames, palette: palette)
        report.indexingTime = Date().timeIntervalSince(startIndex)

        print("║          ✓ Indexed \(indexedFrames.count) frames in \(String(format: "%.2f", report.indexingTime))s                      ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 8: Write GIF
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 8: Writing GIF file...                                      ║")

        let outputURL = outputDirectory
            .appendingPathComponent("test_\(pattern.rawValue).gif")

        // Convert palette format for GIF writer
        let gifPalette = palette.map { (r: $0.0, g: $0.1, b: $0.2) }

        let startWrite = Date()
        try GIF81Writer.write(
            frames: indexedFrames,
            palette: gifPalette,
            to: outputURL,
            frameDelay: 3  // 33ms = ~30fps
        )
        report.gifWriteTime = Date().timeIntervalSince(startWrite)

        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        report.gifFileSize = (attributes[.size] as? Int) ?? 0
        report.outputURL = outputURL

        print("║          ✓ GIF written in \(String(format: "%.2f", report.gifWriteTime))s                             ║")
        print("║          ✓ File size: \(formatBytes(report.gifFileSize))                              ║")

        // ─────────────────────────────────────────────────────────────────────
        // Step 9: Validate Output
        // ─────────────────────────────────────────────────────────────────────
        print("║  Step 9: Validating GIF structure...                              ║")

        let validation = try GIF81Validator.validate(at: outputURL)
        report.structureValid = validation.isValid
        report.validationDetails = validation

        let structureStatus = validation.isValid ? "✓" : "✗"
        print("║          \(structureStatus) Structure validation: \(validation.isValid ? "PASSED" : "FAILED")                    ║")

        if !validation.isValid {
            for issue in validation.issues {
                print("║            ⚠️ \(issue.padding(toLength: 50, withPad: " ", startingAt: 0)) ║")
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Summary
        // ─────────────────────────────────────────────────────────────────────
        report.totalTime = report.frameGenerationTime + report.digestComputeTime +
                          report.paletteComputeTime + report.indexingTime + report.gifWriteTime

        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  SUMMARY                                                          ║")
        print("║  Total time: \(String(format: "%.2f", report.totalTime))s                                            ║")
        print("║  Output: \(outputURL.lastPathComponent.padding(toLength: 55, withPad: " ", startingAt: 0)) ║")
        let overallStatus = report.isSuccess ? "✓ PASSED" : "✗ FAILED"
        print("║  Status: \(overallStatus.padding(toLength: 55, withPad: " ", startingAt: 0)) ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")

        return report
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Validation Helpers
    // ════════════════════════════════════════════════════════════════════════

    /// Validate that digest is compatible with future NN games.
    private static func validateDigestForNN(_ digest: MacroCellDigest) -> Bool {
        // Check we have exactly 729 cells
        guard digest.cells.count == 729 else { return false }

        // Check each cell has valid features
        for cell in digest.cells {
            let vector = cell.toVector()
            guard vector.count == MacroCellDigest.featureDimension else { return false }

            // Check no NaN or Inf values
            for value in vector {
                if value.isNaN || value.isInfinite { return false }
            }
        }

        // Check we can query by address
        let testCell = digest.cell(tileRow: 4, tileCol: 4, timeGroup: 4)
        guard testCell.tileRow == 4 && testCell.tileCol == 4 && testCell.timeGroup == 4 else {
            return false
        }

        return true
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }

    /// Index frames to palette using nearest-neighbor matching.
    ///
    /// For each pixel in each frame, find the palette index of the closest color.
    /// Uses simple Euclidean distance in RGB space (fast for MVP0).
    ///
    /// - Parameters:
    ///   - frames: Array of CGImages (81 frames, 81×81 each)
    ///   - palette: 256 colors as (UInt8, UInt8, UInt8) tuples
    /// - Returns: Array of indexed frames (each 6561 bytes)
    private static func indexFramesToPalette(
        frames: [CGImage],
        palette: [(UInt8, UInt8, UInt8)]
    ) -> [[UInt8]] {

        var indexedFrames = [[UInt8]]()
        indexedFrames.reserveCapacity(frames.count)

        // Build lookup table for fast palette indexing
        // Key: packed RGB, Value: palette index
        var exactLookup = [UInt32: UInt8]()
        for (idx, color) in palette.enumerated() {
            let packed = (UInt32(color.0) << 16) | (UInt32(color.1) << 8) | UInt32(color.2)
            exactLookup[packed] = UInt8(idx)
        }

        for frame in frames {
            guard let pixels = extractPixels(from: frame) else {
                // Fallback to all zeros
                indexedFrames.append([UInt8](repeating: 0, count: 81 * 81))
                continue
            }

            var indexed = [UInt8]()
            indexed.reserveCapacity(81 * 81)

            for y in 0..<81 {
                for x in 0..<81 {
                    let offset = (y * 81 + x) * 4
                    let r = pixels[offset]
                    let g = pixels[offset + 1]
                    let b = pixels[offset + 2]

                    // Try exact match first
                    let packed = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                    if let exactIdx = exactLookup[packed] {
                        indexed.append(exactIdx)
                        continue
                    }

                    // Find nearest color in palette
                    var bestIdx: UInt8 = 0
                    var bestDist = Int.max

                    for (idx, color) in palette.enumerated() {
                        let dr = Int(r) - Int(color.0)
                        let dg = Int(g) - Int(color.1)
                        let db = Int(b) - Int(color.2)
                        let dist = dr * dr + dg * dg + db * db

                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = UInt8(idx)
                        }

                        // Early exit if exact match
                        if dist == 0 { break }
                    }

                    indexed.append(bestIdx)
                }
            }

            indexedFrames.append(indexed)
        }

        return indexedFrames
    }

    /// Extract raw pixel data from a CGImage.
    private static func extractPixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Validation Report
    // ════════════════════════════════════════════════════════════════════════

    /// Report from a pipeline test run.
    public struct ValidationReport {
        public let pattern: TestPattern

        // Frame generation
        public var frameCount: Int = 0
        public var frameGenerationTime: TimeInterval = 0

        // Digest
        public var cellCount: Int = 0
        public var featureDimension: Int = 0
        public var digestComputeTime: TimeInterval = 0
        public var digestValidForNN: Bool = false

        // Color Vector Space
        public var uniqueColorsFound: Int = 0

        // Weights
        public var weightStrategy: String = ""

        // Palette merge statistics
        public var exactMatches: Int = 0       // Both games picked same color
        public var similarMerges: Int = 0      // Colors merged via CIEDE2000

        // Palette
        public var paletteSize: Int = 0
        public var uniqueColorsInPalette: Int = 0
        public var paletteComputeTime: TimeInterval = 0

        // Indexing
        public var indexingTime: TimeInterval = 0

        // GIF output
        public var gifFileSize: Int = 0
        public var gifWriteTime: TimeInterval = 0
        public var outputURL: URL?

        // Validation
        public var structureValid: Bool = false
        public var validationDetails: GIF81Validator.ValidationResult?

        // Totals
        public var totalTime: TimeInterval = 0

        /// Agreement rate between spatial and temporal games
        public var agreementRate: Float {
            guard uniqueColorsInPalette > 0 else { return 0 }
            return Float(exactMatches + similarMerges) / Float(256)
        }

        /// Overall success
        public var isSuccess: Bool {
            frameCount == 81 &&
            cellCount == 729 &&
            digestValidForNN &&
            paletteSize == 256 &&
            structureValid
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Errors
    // ════════════════════════════════════════════════════════════════════════

    public enum TestError: Error, LocalizedError {
        case frameGenerationFailed(Int)
        case digestComputeFailed
        case gifWriteFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .frameGenerationFailed(let index):
                return "Failed to generate frame \(index)"
            case .digestComputeFailed:
                return "Failed to compute MacroCellDigest"
            case .gifWriteFailed(let error):
                return "Failed to write GIF: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Run All Tests

@available(iOS 26.0, *)
extension GIF81TestHarness {

    /// Run all test patterns and generate a summary.
    public static func runAllTests(
        outputDirectory: URL
    ) async throws -> [ValidationReport] {

        print("\n")
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  RGB2GIF MVP0 TEST SUITE                                          ║")
        print("║  Testing all patterns...                                          ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
        print("\n")

        var reports = [ValidationReport]()

        for pattern in TestPattern.allCases {
            do {
                let report = try await runPipelineTest(
                    pattern: pattern,
                    outputDirectory: outputDirectory
                )
                reports.append(report)
            } catch {
                print("❌ Test failed for \(pattern.rawValue): \(error)")
            }
            print("\n")
        }

        // Summary
        let passed = reports.filter { $0.isSuccess }.count
        let total = reports.count

        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  TEST SUITE SUMMARY                                               ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Passed: \(passed) / \(total)                                                    ║")
        for report in reports {
            let status = report.isSuccess ? "✓" : "✗"
            let name = report.pattern.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
            let size = formatBytes(report.gifFileSize).padding(toLength: 10, withPad: " ", startingAt: 0)
            print("║    \(status) \(name) \(size) \(String(format: "%.2fs", report.totalTime))                   ║")
        }
        print("╚═══════════════════════════════════════════════════════════════════╝")

        return reports
    }
}
