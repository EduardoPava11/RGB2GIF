//
//  SyntheticFrameGenerator.swift
//  RGB2GIF
//
//  ============================================================================
//  SYNTHETIC FRAME GENERATOR: Create 81 RGB Frames for MVP0 Testing
//  ============================================================================
//
//  THE 3-ADIC FRAME STRUCTURE
//  ──────────────────────────
//  - 81 frames (3⁴) organized into 9 time groups (3²)
//  - Each frame is 81×81 pixels (3⁴ × 3⁴)
//  - Total: 531,441 voxels (81 × 81 × 81 = 3¹²)
//
//  FRAME GENERATION PATTERNS
//  ─────────────────────────
//  Each pattern is designed to stress different aspects of the pipeline:
//
//  1. GRADIENT_3D: RGB cube mapped to XYT space
//     - Tests: Full color range, smooth transitions
//     - Expected unique colors: ~50,000+
//
//  2. TILE_IDENTITY: Each 9×9 tile has unique identifying color
//     - Tests: Macro-cell boundary detection
//     - Expected unique colors: 81 (one per tile)
//
//  3. TIME_PULSE: Color intensity varies with frame number
//     - Tests: Temporal presence tracking
//     - Expected: Strong temporal localization
//
//  4. DIAGONAL_WAVE: Diagonal pattern that moves over time
//     - Tests: Combined spatial-temporal correlation
//     - Expected: High entropy in both dimensions
//
//  5. GO_BOARD: 9×9 GO board positions with stones
//     - Tests: NN game compatibility
//     - Expected: Exactly 3 colors (black, white, board)
//
//  ============================================================================

import Foundation
import CoreGraphics

@available(iOS 26.0, *)
public struct SyntheticFrameGenerator {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Constants (Powers of 3)
    // ════════════════════════════════════════════════════════════════════════

    /// Frame dimensions (3⁴ = 81)
    public static let frameSize: Int = 81

    /// Number of frames (3⁴ = 81)
    public static let frameCount: Int = 81

    /// Tile size within frame (3² = 9)
    public static let tileSize: Int = 9

    /// Number of tiles per dimension (3² = 9)
    public static let tilesPerDimension: Int = 9

    /// Time groups (3² = 9)
    public static let timeGroupCount: Int = 9

    /// Frames per time group (3² = 9)
    public static let framesPerTimeGroup: Int = 9

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Generation Patterns
    // ════════════════════════════════════════════════════════════════════════

    public enum Pattern: String, CaseIterable, Codable {
        case gradient3D = "gradient_3d"
        case tileIdentity = "tile_identity"
        case timePulse = "time_pulse"
        case diagonalWave = "diagonal_wave"
        case goBoard = "go_board"
        case rainbow81 = "rainbow_81"

        public var description: String {
            switch self {
            case .gradient3D:
                return "3D RGB gradient (X→R, Y→G, T→B)"
            case .tileIdentity:
                return "Each 9×9 tile has unique color"
            case .timePulse:
                return "Intensity pulses over time"
            case .diagonalWave:
                return "Diagonal wave moving through time"
            case .goBoard:
                return "9×9 GO board with random stones"
            case .rainbow81:
                return "81 distinct hues across frames"
            }
        }

        public var expectedUniqueColors: ClosedRange<Int> {
            switch self {
            case .gradient3D: return 30000...60000
            case .tileIdentity: return 81...162  // 81 tiles, may have some variation
            case .timePulse: return 200...2000
            case .diagonalWave: return 1000...10000
            case .goBoard: return 3...10  // black, white, board color + edges
            case .rainbow81: return 81...500
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Frame Generation
    // ════════════════════════════════════════════════════════════════════════

    /// Generate all 81 frames for a given pattern.
    ///
    /// - Parameter pattern: The test pattern to generate
    /// - Returns: Array of 81 CGImages, each 81×81 pixels
    public static func generateFrames(pattern: Pattern) throws -> [CGImage] {
        var frames = [CGImage]()
        frames.reserveCapacity(frameCount)

        for frameIndex in 0..<frameCount {
            let frame = try generateFrame(
                index: frameIndex,
                pattern: pattern
            )
            frames.append(frame)
        }

        return frames
    }

    /// Generate a single frame.
    private static func generateFrame(
        index: Int,
        pattern: Pattern
    ) throws -> CGImage {
        let width = frameSize
        let height = frameSize
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let color = colorFor(x: x, y: y, frame: index, pattern: pattern)

                pixels[offset] = color.r
                pixels[offset + 1] = color.g
                pixels[offset + 2] = color.b
                pixels[offset + 3] = 255  // Alpha
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
            throw GeneratorError.frameCreationFailed(index)
        }

        return image
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Pattern Implementations
    // ════════════════════════════════════════════════════════════════════════

    private static func colorFor(
        x: Int,
        y: Int,
        frame: Int,
        pattern: Pattern
    ) -> (r: UInt8, g: UInt8, b: UInt8) {

        switch pattern {
        case .gradient3D:
            return gradient3DColor(x: x, y: y, frame: frame)

        case .tileIdentity:
            return tileIdentityColor(x: x, y: y, frame: frame)

        case .timePulse:
            return timePulseColor(x: x, y: y, frame: frame)

        case .diagonalWave:
            return diagonalWaveColor(x: x, y: y, frame: frame)

        case .goBoard:
            return goBoardColor(x: x, y: y, frame: frame)

        case .rainbow81:
            return rainbow81Color(x: x, y: y, frame: frame)
        }
    }

    /// 3D RGB gradient: X→R, Y→G, Frame→B
    private static func gradient3DColor(x: Int, y: Int, frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r = UInt8(x * 255 / (frameSize - 1))
        let g = UInt8(y * 255 / (frameSize - 1))
        let b = UInt8(frame * 255 / (frameCount - 1))
        return (r, g, b)
    }

    /// Each 9×9 tile has a unique identifying color
    private static func tileIdentityColor(x: Int, y: Int, frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let tileRow = y / tileSize
        let tileCol = x / tileSize
        let tileIndex = tileRow * tilesPerDimension + tileCol  // 0-80

        // Map tile index to hue (0-80 → 0-360 degrees)
        let hue = Float(tileIndex) / Float(tilesPerDimension * tilesPerDimension)

        // Slight variation based on frame (keeps tiles identifiable but not static)
        let lightness: Float = 0.4 + Float(frame % 9) * 0.02

        return hslToRGB(h: hue, s: 0.8, l: lightness)
    }

    /// Intensity pulses over time
    private static func timePulseColor(x: Int, y: Int, frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let timeGroup = frame / framesPerTimeGroup
        let frameInGroup = frame % framesPerTimeGroup

        // Base color from spatial position
        let baseHue = Float(x + y) / Float(2 * frameSize)

        // Intensity varies by time group
        let groupPhase = Float(timeGroup) / Float(timeGroupCount)
        let framePhase = Float(frameInGroup) / Float(framesPerTimeGroup)

        // Pulse intensity: peaks at center of each time group
        let intensity = 0.3 + 0.7 * sin(Float.pi * framePhase) * (0.5 + 0.5 * sin(Float.pi * 2 * groupPhase))

        return hslToRGB(h: baseHue, s: 0.7, l: intensity * 0.5 + 0.25)
    }

    /// Diagonal wave moving through time
    private static func diagonalWaveColor(x: Int, y: Int, frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        // Diagonal position: x + y normalized
        let diagonal = Float(x + y) / Float(2 * frameSize - 2)

        // Wave phase that moves with time
        let timeOffset = Float(frame) / Float(frameCount)
        let phase = (diagonal + timeOffset).truncatingRemainder(dividingBy: 1.0)

        // Create wave pattern
        let waveValue = (sin(phase * Float.pi * 4) + 1) / 2

        // Color based on wave position
        let r = UInt8(waveValue * 200 + 55)
        let g = UInt8((1 - waveValue) * 150 + 50)
        let b = UInt8(abs(waveValue - 0.5) * 200 + 55)

        return (r, g, b)
    }

    /// 9×9 GO board with deterministic stone placement
    private static func goBoardColor(x: Int, y: Int, frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        // Board color (wood brown)
        let boardColor: (r: UInt8, g: UInt8, b: UInt8) = (220, 179, 92)
        let blackStone: (r: UInt8, g: UInt8, b: UInt8) = (20, 20, 20)
        let whiteStone: (r: UInt8, g: UInt8, b: UInt8) = (240, 240, 240)

        let tileRow = y / tileSize
        let tileCol = x / tileSize
        let tileIndex = tileRow * tilesPerDimension + tileCol

        // Position within tile (0-8)
        let localX = x % tileSize
        let localY = y % tileSize

        // Distance from tile center
        let centerDist = sqrt(pow(Float(localX) - 4, 2) + pow(Float(localY) - 4, 2))

        // Use frame to determine stone pattern (simple deterministic pattern)
        let timeGroup = frame / framesPerTimeGroup

        // Deterministic "game state" based on time group
        // This creates a pattern that evolves over time
        let stonePattern = (tileIndex + timeGroup * 7) % 17  // Prime modulo for distribution

        // Is there a stone at this intersection?
        let hasStone = stonePattern < 5  // ~30% of positions have stones
        let isBlackStone = stonePattern < 2  // ~40% of stones are black

        // Draw stone if within radius 3.5 of tile center
        if hasStone && centerDist < 3.5 {
            return isBlackStone ? blackStone : whiteStone
        }

        // Draw grid lines
        let onHorizontalLine = localY == 4
        let onVerticalLine = localX == 4

        if onHorizontalLine || onVerticalLine {
            return (80, 60, 30)  // Grid line color
        }

        return boardColor
    }

    /// 81 distinct hues across frames
    private static func rainbow81Color(x: Int, y: Int, frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        // Each frame has a distinct hue
        let hue = Float(frame) / Float(frameCount)

        // Lightness varies spatially (creates gradient within frame)
        let lightness: Float = 0.3 + Float(y) / Float(frameSize) * 0.4

        // Saturation varies with x
        let saturation: Float = 0.5 + Float(x) / Float(frameSize) * 0.4

        return hslToRGB(h: hue, s: saturation, l: lightness)
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Color Space Conversion
    // ════════════════════════════════════════════════════════════════════════

    /// Convert HSL to RGB
    private static func hslToRGB(h: Float, s: Float, l: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
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
            UInt8(min(255, max(0, (r + m) * 255))),
            UInt8(min(255, max(0, (g + m) * 255))),
            UInt8(min(255, max(0, (b + m) * 255)))
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Raw Data Export
    // ════════════════════════════════════════════════════════════════════════

    /// Export frames as raw RGB data (for debugging/validation)
    public static func exportRawData(
        frames: [CGImage],
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        for (index, frame) in frames.enumerated() {
            guard let pixels = extractPixels(from: frame) else {
                throw GeneratorError.pixelExtractionFailed(index)
            }

            let filename = String(format: "frame_%03d.raw", index)
            let fileURL = directory.appendingPathComponent(filename)

            // Write raw RGB data (skip alpha)
            var rgbData = Data()
            rgbData.reserveCapacity(frameSize * frameSize * 3)

            for y in 0..<frameSize {
                for x in 0..<frameSize {
                    let offset = (y * frameSize + x) * 4
                    rgbData.append(pixels[offset])      // R
                    rgbData.append(pixels[offset + 1])  // G
                    rgbData.append(pixels[offset + 2])  // B
                }
            }

            try rgbData.write(to: fileURL)
        }
    }

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
    // MARK: - Errors
    // ════════════════════════════════════════════════════════════════════════

    public enum GeneratorError: Error, LocalizedError {
        case frameCreationFailed(Int)
        case pixelExtractionFailed(Int)

        public var errorDescription: String? {
            switch self {
            case .frameCreationFailed(let index):
                return "Failed to create frame \(index)"
            case .pixelExtractionFailed(let index):
                return "Failed to extract pixels from frame \(index)"
            }
        }
    }
}
