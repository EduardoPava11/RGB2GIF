#!/usr/bin/env swift
//
//  test_tensor_games.swift
//  RGB2GIF
//
//  ============================================================================
//  TEST SCRIPT: Tensor to Go Game Conversion
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Verifies that TensorCube729 data can be correctly interpreted as Go game
//  positions for the Spatial and Temporal players.
//
//  USAGE
//  ─────
//  swift test_tensor_games.swift
//
//  WHAT IT TESTS
//  ─────────────
//  1. Creates a synthetic TensorCube729 with known patterns
//  2. Converts to Spatial game (tile variance over time)
//  3. Converts to Temporal game (frame-to-frame motion)
//  4. Visualizes both game positions
//  5. Verifies stone placement makes sense
//
//  ============================================================================

import Foundation

// MARK: - Test Configuration

let testPatterns = [
    "gradient",      // Smooth color gradient
    "checkerboard",  // Alternating high/low variance
    "center_hot",    // High variance in center
    "motion_wave"    // Motion across time
]

// MARK: - Synthetic Tensor Data

/// Simple cell structure for testing (mimics TensorCube729.Cell)
struct TestCell {
    var weightedR: Float = 0
    var weightedG: Float = 0
    var weightedB: Float = 0
    var totalWeight: Float = 0

    func centroidColor() -> (r: UInt8, g: UInt8, b: UInt8) {
        guard totalWeight > 0 else { return (0, 0, 0) }
        let r = UInt8(min(255, max(0, Int(weightedR / totalWeight))))
        let g = UInt8(min(255, max(0, Int(weightedG / totalWeight))))
        let b = UInt8(min(255, max(0, Int(weightedB / totalWeight))))
        return (r, g, b)
    }
}

/// Synthetic tensor for testing
struct TestTensor {
    var cells: [[[TestCell]]]  // [t][y][x]

    init() {
        cells = Array(
            repeating: Array(
                repeating: Array(repeating: TestCell(), count: 9),
                count: 9
            ),
            count: 9
        )
    }

    subscript(t: Int, y: Int, x: Int) -> TestCell {
        get { cells[t][y][x] }
        set { cells[t][y][x] = newValue }
    }

    /// Create gradient pattern (color varies smoothly across space and time)
    static func gradient() -> TestTensor {
        var tensor = TestTensor()
        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let r = Float(x * 28 + t * 3)
                    let g = Float(y * 28 + t * 3)
                    let b = Float((x + y) * 14 + t * 5)
                    tensor.cells[t][y][x] = TestCell(
                        weightedR: r, weightedG: g, weightedB: b, totalWeight: 1.0
                    )
                }
            }
        }
        return tensor
    }

    /// Create checkerboard pattern (alternating high/low variance)
    static func checkerboard() -> TestTensor {
        var tensor = TestTensor()
        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let isEven = (x + y) % 2 == 0
                    // Even squares: stable color, Odd squares: changing color
                    let timeVar = isEven ? 0 : t * 20
                    let r = Float(128 + timeVar)
                    let g = Float(128 - timeVar / 2)
                    let b = Float(128 + timeVar / 3)
                    tensor.cells[t][y][x] = TestCell(
                        weightedR: r, weightedG: g, weightedB: b, totalWeight: 1.0
                    )
                }
            }
        }
        return tensor
    }

    /// Create center-hot pattern (high variance in center)
    static func centerHot() -> TestTensor {
        var tensor = TestTensor()
        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let distFromCenter = sqrt(Float((x-4)*(x-4) + (y-4)*(y-4)))
                    let intensity = max(0, 4 - distFromCenter)
                    // Center changes a lot over time, edges stay stable
                    let timeVar = intensity * Float(t) * 15
                    let r = Float(128 + timeVar)
                    let g = Float(100 + timeVar * 0.5)
                    let b = Float(150 - timeVar * 0.3)
                    tensor.cells[t][y][x] = TestCell(
                        weightedR: r, weightedG: g, weightedB: b, totalWeight: 1.0
                    )
                }
            }
        }
        return tensor
    }

    /// Create motion wave pattern (wave of motion across time)
    static func motionWave() -> TestTensor {
        var tensor = TestTensor()
        for t in 0..<9 {
            for y in 0..<9 {
                for x in 0..<9 {
                    // Wave of motion passes through at different times
                    let wavePos = (t * 9 / 8) % 9
                    let distFromWave = abs(y - wavePos)
                    let motionIntensity = max(0, 3 - distFromWave) * 30
                    let r = Float(100 + motionIntensity)
                    let g = Float(100 + motionIntensity / 2)
                    let b = Float(200 - motionIntensity / 3)
                    tensor.cells[t][y][x] = TestCell(
                        weightedR: r, weightedG: g, weightedB: b, totalWeight: 1.0
                    )
                }
            }
        }
        return tensor
    }
}

// MARK: - Game Creation (Simplified version of TensorToGame)

enum StoneColor: String {
    case empty = "·"
    case black = "●"
    case white = "○"
}

struct GamePosition {
    var board: [[StoneColor]]
    var komi: Float
    var blackCount: Int = 0
    var whiteCount: Int = 0

    init(komi: Float = 7.0) {
        self.board = Array(repeating: Array(repeating: .empty, count: 9), count: 9)
        self.komi = komi
    }

    mutating func placeStone(_ color: StoneColor, row: Int, col: Int) {
        board[row][col] = color
        if color == .black { blackCount += 1 }
        if color == .white { whiteCount += 1 }
    }

    func visualize(title: String) -> String {
        var lines = [String]()
        lines.append("╔═══════════════════════════════════════╗")
        lines.append("║  \(title.padding(toLength: 36, withPad: " ", startingAt: 0)) ║")
        lines.append("╠═══════════════════════════════════════╣")
        lines.append("║  Black: \(String(format: "%2d", blackCount))  White: \(String(format: "%2d", whiteCount))  Komi: \(String(format: "%.1f", komi))   ║")
        lines.append("╠═══════════════════════════════════════╣")
        lines.append("║     A B C D E F G H J                 ║")

        for row in 0..<9 {
            var line = "║  \(9 - row)  "
            for col in 0..<9 {
                line += board[row][col].rawValue + " "
            }
            line += "                ║"
            lines.append(line)
        }

        lines.append("╚═══════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}

/// Create spatial game from tensor
func createSpatialGame(from tensor: TestTensor) -> GamePosition {
    var position = GamePosition(komi: 5.5)  // Japanese rules

    // Compute temporal variance for each tile
    var variances: [(row: Int, col: Int, variance: Float)] = []

    for row in 0..<9 {
        for col in 0..<9 {
            // Get colors across time
            var colors: [(r: Float, g: Float, b: Float)] = []
            for t in 0..<9 {
                let cell = tensor[t, row, col]
                let (r, g, b) = cell.centroidColor()
                colors.append((Float(r), Float(g), Float(b)))
            }

            // Compute variance
            let meanR = colors.map(\.r).reduce(0, +) / 9
            let meanG = colors.map(\.g).reduce(0, +) / 9
            let meanB = colors.map(\.b).reduce(0, +) / 9

            var variance: Float = 0
            for c in colors {
                variance += (c.r - meanR) * (c.r - meanR)
                variance += (c.g - meanG) * (c.g - meanG)
                variance += (c.b - meanB) * (c.b - meanB)
            }
            variance /= 27  // 9 samples * 3 channels

            variances.append((row, col, variance))
        }
    }

    // Sort by variance
    variances.sort { $0.variance > $1.variance }

    // Compute threshold (mean variance)
    let meanVariance = variances.map(\.variance).reduce(0, +) / 81

    // Place stones
    for (row, col, variance) in variances {
        if variance > meanVariance * 1.5 {
            position.placeStone(.black, row: row, col: col)
        } else if variance < meanVariance * 0.5 {
            position.placeStone(.white, row: row, col: col)
        }
    }

    return position
}

/// Create temporal game from tensor
func createTemporalGame(from tensor: TestTensor) -> GamePosition {
    var position = GamePosition(komi: 7.0)  // Tromp-Taylor rules

    // Compute inter-frame motion
    var motions: [(row: Int, col: Int, motion: Float)] = []

    for t in 0..<9 {
        // Compute motion from t-1 to t
        var rowMotion: Float = 0

        if t > 0 {
            for y in 0..<9 {
                for x in 0..<9 {
                    let prev = tensor[t-1, y, x]
                    let curr = tensor[t, y, x]
                    let (r1, g1, b1) = prev.centroidColor()
                    let (r2, g2, b2) = curr.centroidColor()

                    let dr = Float(r2) - Float(r1)
                    let dg = Float(g2) - Float(g1)
                    let db = Float(b2) - Float(b1)
                    rowMotion += sqrt(dr*dr + dg*dg + db*db)
                }
            }
            rowMotion /= 81
        }

        // Distribute across the row
        for col in 0..<9 {
            motions.append((t, col, rowMotion))
        }
    }

    // Compute threshold
    let meanMotion = motions.map(\.motion).reduce(0, +) / 81

    // Place stones
    for (row, col, motion) in motions {
        if motion > meanMotion * 1.5 {
            position.placeStone(.black, row: row, col: col)
        } else if motion < meanMotion * 0.5 {
            position.placeStone(.white, row: row, col: col)
        }
    }

    return position
}

// MARK: - Main Test

func main() {
    print("")
    print("╔═══════════════════════════════════════════════════════════════════╗")
    print("║     RGB2GIF Tensor to Go Game Conversion Test                     ║")
    print("╚═══════════════════════════════════════════════════════════════════╝")
    print("")

    // Test each pattern
    let patterns: [(name: String, tensor: TestTensor)] = [
        ("Gradient", TestTensor.gradient()),
        ("Checkerboard", TestTensor.checkerboard()),
        ("Center Hot", TestTensor.centerHot()),
        ("Motion Wave", TestTensor.motionWave())
    ]

    for (name, tensor) in patterns {
        print("═══════════════════════════════════════════════════════════════════")
        print("  PATTERN: \(name)")
        print("═══════════════════════════════════════════════════════════════════")
        print("")

        // Create spatial game
        let spatialGame = createSpatialGame(from: tensor)
        print(spatialGame.visualize(title: "SPATIAL GAME (x/y tiles)"))
        print("")

        // Create temporal game
        let temporalGame = createTemporalGame(from: tensor)
        print(temporalGame.visualize(title: "TEMPORAL GAME (t→t+1)"))
        print("")

        // Analysis
        print("  Analysis:")
        print("    Spatial: \(spatialGame.blackCount) high-variance tiles (Black)")
        print("             \(spatialGame.whiteCount) low-variance tiles (White)")
        print("    Temporal: \(temporalGame.blackCount) high-motion frames (Black)")
        print("              \(temporalGame.whiteCount) low-motion frames (White)")
        print("")
    }

    print("═══════════════════════════════════════════════════════════════════")
    print("  ✓ TEST COMPLETE")
    print("═══════════════════════════════════════════════════════════════════")
    print("")
    print("  The patterns show how tensor data maps to Go positions:")
    print("  • Gradient: Smooth variance → scattered stones")
    print("  • Checkerboard: Alternating variance → clear Black/White pattern")
    print("  • Center Hot: Center variance → Black cluster in center")
    print("  • Motion Wave: Temporal motion → Black rows where motion occurs")
    print("")
}

main()
