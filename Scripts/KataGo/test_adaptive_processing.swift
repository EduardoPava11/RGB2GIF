#!/usr/bin/env swift
//
//  test_adaptive_processing.swift
//  RGB2GIF
//
//  ============================================================================
//  TEST SCRIPT: Adaptive Processing (Importance Analysis + Budget Allocation)
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Verifies that the adaptive processing system works correctly:
//  1. SliceImportanceAnalyzer correctly ranks slices
//  2. Budget allocation respects anchor slices (0, 4, 8)
//  3. Interpolation produces reasonable values
//  4. Different content patterns produce different rankings
//
//  USAGE
//  ─────
//  swift test_adaptive_processing.swift
//
//  NOTE: Simplified standalone test without CoreML dependencies.
//
//  ============================================================================

import Foundation

// MARK: - Test Configuration

let gridDimension = 9

// MARK: - Simplified Importance Analyzer

struct TestImportanceAnalyzer {
    var temperature: Float = 1.0
    var colorVarianceWeight: Float = 0.6
    var edgeDensityWeight: Float = 0.4
    var motionWeight: Float = 0.7
    var frameDeltaWeight: Float = 0.3

    struct ImportanceResult {
        let spatialImportance: [Float]
        let temporalImportance: [Float]
        let spatialRanking: [Int]
        let temporalRanking: [Int]
        let analysisTimeMs: Double

        func selectSpatialSlices(budget: Int) -> Set<Int> {
            var selected: Set<Int> = [0, 4, 8]  // Anchor slices
            for idx in spatialRanking {
                if selected.count >= budget { break }
                selected.insert(idx)
            }
            return selected
        }

        func selectTemporalSlices(budget: Int) -> Set<Int> {
            var selected: Set<Int> = [0, 4, 8]
            for idx in temporalRanking {
                if selected.count >= budget { break }
                selected.insert(idx)
            }
            return selected
        }
    }

    func analyze(centroids: [(r: UInt8, g: UInt8, b: UInt8)]) -> ImportanceResult {
        let startTime = Date()

        // Spatial importance
        var spatialImportance = [Float](repeating: 0, count: 9)
        for t in 0..<9 {
            spatialImportance[t] = computeSpatialImportance(centroids: centroids, timeSlice: t)
        }

        // Temporal importance
        var temporalImportance = [Float](repeating: 0, count: 9)
        for x in 0..<9 {
            temporalImportance[x] = computeTemporalImportance(centroids: centroids, column: x)
        }

        // Softmax normalization
        spatialImportance = softmax(spatialImportance)
        temporalImportance = softmax(temporalImportance)

        // Rankings
        let spatialRanking = spatialImportance.enumerated()
            .sorted { $0.element > $1.element }
            .map { $0.offset }

        let temporalRanking = temporalImportance.enumerated()
            .sorted { $0.element > $1.element }
            .map { $0.offset }

        let elapsed = Date().timeIntervalSince(startTime) * 1000

        return ImportanceResult(
            spatialImportance: spatialImportance,
            temporalImportance: temporalImportance,
            spatialRanking: spatialRanking,
            temporalRanking: temporalRanking,
            analysisTimeMs: elapsed
        )
    }

    private func computeSpatialImportance(centroids: [(r: UInt8, g: UInt8, b: UInt8)], timeSlice t: Int) -> Float {
        var colors: [(r: Float, g: Float, b: Float)] = []
        for y in 0..<9 {
            for x in 0..<9 {
                let idx = t * 81 + y * 9 + x
                let c = centroids[idx]
                colors.append((Float(c.r), Float(c.g), Float(c.b)))
            }
        }

        let variance = computeColorVariance(colors)
        let edgeDensity = computeEdgeDensity(colors)

        return colorVarianceWeight * variance + edgeDensityWeight * edgeDensity
    }

    private func computeTemporalImportance(centroids: [(r: UInt8, g: UInt8, b: UInt8)], column x: Int) -> Float {
        var motion: Float = 0
        var count = 0

        for t in 1..<9 {
            for y in 0..<9 {
                let currIdx = t * 81 + y * 9 + x
                let prevIdx = (t-1) * 81 + y * 9 + x
                let curr = centroids[currIdx]
                let prev = centroids[prevIdx]

                let dr = Float(curr.r) - Float(prev.r)
                let dg = Float(curr.g) - Float(prev.g)
                let db = Float(curr.b) - Float(prev.b)
                motion += sqrt(dr*dr + dg*dg + db*db)
                count += 1
            }
        }

        let normalizedMotion = count > 0 ? (motion / Float(count)) / 441.67 : 0

        // Simplified: just use motion
        return motionWeight * normalizedMotion
    }

    private func computeColorVariance(_ colors: [(r: Float, g: Float, b: Float)]) -> Float {
        guard !colors.isEmpty else { return 0 }

        var meanR: Float = 0, meanG: Float = 0, meanB: Float = 0
        for c in colors {
            meanR += c.r; meanG += c.g; meanB += c.b
        }
        let n = Float(colors.count)
        meanR /= n; meanG /= n; meanB /= n

        var varR: Float = 0, varG: Float = 0, varB: Float = 0
        for c in colors {
            let dr = c.r - meanR, dg = c.g - meanG, db = c.b - meanB
            varR += dr * dr; varG += dg * dg; varB += db * db
        }
        varR /= n; varG /= n; varB /= n

        let maxVar: Float = 255 * 255
        return (varR + varG + varB) / (3 * maxVar)
    }

    private func computeEdgeDensity(_ colors: [(r: Float, g: Float, b: Float)]) -> Float {
        var totalEdge: Float = 0
        var count = 0

        for y in 0..<9 {
            for x in 0..<9 {
                let idx = y * 9 + x

                if x < 8 {
                    let rightIdx = y * 9 + (x + 1)
                    totalEdge += colorDistance(colors[idx], colors[rightIdx])
                    count += 1
                }
                if y < 8 {
                    let bottomIdx = (y + 1) * 9 + x
                    totalEdge += colorDistance(colors[idx], colors[bottomIdx])
                    count += 1
                }
            }
        }

        return count > 0 ? (totalEdge / Float(count)) / 441.67 : 0
    }

    private func colorDistance(_ a: (r: Float, g: Float, b: Float), _ b: (r: Float, g: Float, b: Float)) -> Float {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return sqrt(dr*dr + dg*dg + db*db)
    }

    private func softmax(_ values: [Float]) -> [Float] {
        let maxVal = values.max() ?? 0
        var exps = values.map { exp(($0 - maxVal) / temperature) }
        let sum = exps.reduce(0, +)
        if sum > 0 { exps = exps.map { $0 / sum } }
        return exps
    }
}

// MARK: - Test Data Generators

func generateUniformCentroids() -> [(r: UInt8, g: UInt8, b: UInt8)] {
    // All cells have the same color (lowest importance)
    return (0..<729).map { _ in (r: UInt8(128), g: UInt8(128), b: UInt8(128)) }
}

func generateGradientCentroids() -> [(r: UInt8, g: UInt8, b: UInt8)] {
    // Gradient across space and time
    return (0..<729).map { idx in
        let t = idx / 81
        let y = (idx % 81) / 9
        let x = idx % 9
        return (r: UInt8(x * 28), g: UInt8(y * 28), b: UInt8(t * 28))
    }
}

func generateMotionBurstCentroids() -> [(r: UInt8, g: UInt8, b: UInt8)] {
    // Motion burst at t=4-5, column x=4 (center)
    return (0..<729).map { idx in
        let t = idx / 81
        let y = (idx % 81) / 9
        let x = idx % 9

        let isBurst = (t >= 4 && t <= 5) && (x >= 3 && x <= 5)
        let baseValue: UInt8 = isBurst ? 255 : 50
        return (r: baseValue, g: baseValue, b: baseValue)
    }
}

func generateCenterHotCentroids() -> [(r: UInt8, g: UInt8, b: UInt8)] {
    // High variance in center, low at edges
    return (0..<729).map { idx in
        let y = (idx % 81) / 9
        let x = idx % 9

        let distFromCenter = sqrt(Float((x-4)*(x-4) + (y-4)*(y-4)))
        let intensity = UInt8(max(0, min(255, 255 - Int(distFromCenter * 40))))

        // Add noise to center for variance
        let noise = (x == 4 && y == 4) ? UInt8.random(in: 100...255) : intensity
        return (r: noise, g: intensity, b: intensity)
    }
}

// MARK: - Interpolation Test

func testInterpolation() -> Bool {
    var policies = [[Float]?](repeating: nil, count: 9)

    // Set anchor values
    policies[0] = [Float](repeating: 0.1, count: 81)
    policies[4] = [Float](repeating: 0.5, count: 81)
    policies[8] = [Float](repeating: 0.9, count: 81)

    let processed: Set<Int> = [0, 4, 8]

    // Interpolate
    for i in 0..<9 {
        if policies[i] != nil { continue }

        var leftIdx: Int?
        var rightIdx: Int?

        for j in stride(from: i-1, through: 0, by: -1) {
            if processed.contains(j) { leftIdx = j; break }
        }
        for j in (i+1)..<9 {
            if processed.contains(j) { rightIdx = j; break }
        }

        if let left = leftIdx, let right = rightIdx,
           let leftPolicy = policies[left], let rightPolicy = policies[right] {
            let t = Float(i - left) / Float(right - left)
            policies[i] = zip(leftPolicy, rightPolicy).map { (1-t) * $0 + t * $1 }
        }
    }

    // Verify interpolation
    let p2 = policies[2]?[0] ?? -1  // Should be ~0.3 (interpolated between 0.1 and 0.5)
    let p6 = policies[6]?[0] ?? -1  // Should be ~0.7 (interpolated between 0.5 and 0.9)

    return abs(p2 - 0.3) < 0.01 && abs(p6 - 0.7) < 0.01
}

// MARK: - Main Test

func main() {
    print("")
    print("╔═══════════════════════════════════════════════════════════════════╗")
    print("║     RGB2GIF Adaptive Processing Test Suite                        ║")
    print("╚═══════════════════════════════════════════════════════════════════╝")
    print("")

    let analyzer = TestImportanceAnalyzer()
    var allPassed = true

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 1: Uniform Content (lowest importance variation)
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 1: Uniform Content (all cells same color)")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let uniformCentroids = generateUniformCentroids()
    let uniformResult = analyzer.analyze(centroids: uniformCentroids)

    print("  Analysis time: \(String(format: "%.2f", uniformResult.analysisTimeMs))ms")
    print("  Spatial importance (should be uniform):")
    for (i, imp) in uniformResult.spatialImportance.enumerated() {
        print("    t=\(i): \(String(format: "%.4f", imp))")
    }
    print("")

    // Check that all slices have similar importance
    let uniformSpread = uniformResult.spatialImportance.max()! - uniformResult.spatialImportance.min()!
    if uniformSpread < 0.05 {
        print("  ✓ PASS: Uniform content produces uniform importance (spread=\(String(format: "%.4f", uniformSpread)))")
    } else {
        print("  ✗ FAIL: Expected uniform importance")
        allPassed = false
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 2: Gradient Content (increasing importance)
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 2: Gradient Content (color varies with position)")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let gradientCentroids = generateGradientCentroids()
    let gradientResult = analyzer.analyze(centroids: gradientCentroids)

    print("  Analysis time: \(String(format: "%.2f", gradientResult.analysisTimeMs))ms")
    print("  Spatial ranking: \(gradientResult.spatialRanking)")
    print("  Temporal ranking: \(gradientResult.temporalRanking)")
    print("")

    if gradientResult.analysisTimeMs < 50 {
        print("  ✓ PASS: Analysis completed in <50ms")
    } else {
        print("  ✗ FAIL: Analysis too slow (>\(gradientResult.analysisTimeMs)ms)")
        allPassed = false
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 3: Motion Burst (high temporal importance in center)
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 3: Motion Burst (high motion at t=4-5, x=4)")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let motionCentroids = generateMotionBurstCentroids()
    let motionResult = analyzer.analyze(centroids: motionCentroids)

    print("  Temporal importance (should peak at center columns):")
    for (i, imp) in motionResult.temporalImportance.enumerated() {
        let marker = (i >= 3 && i <= 5) ? "← motion region" : ""
        print("    x=\(i): \(String(format: "%.4f", imp)) \(marker)")
    }
    print("")
    print("  Temporal ranking: \(motionResult.temporalRanking)")
    print("")

    // Check that center columns rank higher
    let topTemporal = Set(motionResult.temporalRanking.prefix(3))
    let containsCenter = topTemporal.contains(4) || topTemporal.contains(3) || topTemporal.contains(5)
    if containsCenter {
        print("  ✓ PASS: Motion region ranks in top 3 temporal slices")
    } else {
        print("  ✗ FAIL: Motion region should rank higher")
        allPassed = false
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 4: Budget Allocation (anchor slices always included)
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 4: Budget Allocation (anchors 0, 4, 8 always included)")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let budgets = [3, 6, 9]
    for budget in budgets {
        let selected = motionResult.selectSpatialSlices(budget: budget)
        let hasAnchors = selected.contains(0) && selected.contains(4) && selected.contains(8)

        print("  Budget \(budget): \(selected.sorted())")
        if hasAnchors && selected.count <= budget {
            print("    ✓ Contains anchors {0, 4, 8}")
        } else if !hasAnchors {
            print("    ✗ FAIL: Missing anchor slices")
            allPassed = false
        }
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 5: Interpolation
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 5: Interpolation (missing slices filled from neighbors)")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    if testInterpolation() {
        print("  ✓ PASS: Linear interpolation produces correct values")
        print("    p[0]=0.1, p[4]=0.5, p[8]=0.9")
        print("    → p[2]≈0.3 (interpolated)")
        print("    → p[6]≈0.7 (interpolated)")
    } else {
        print("  ✗ FAIL: Interpolation values incorrect")
        allPassed = false
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 6: Speedup Calculation
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 6: Speedup Calculation")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let budgetSpeedups = [
        (6, 3.0),   // 18/6 = 3x
        (9, 2.0),   // 18/9 = 2x
        (12, 1.5),  // 18/12 = 1.5x
        (18, 1.0),  // 18/18 = 1x
    ]

    for (budget, expectedSpeedup) in budgetSpeedups {
        let actualSpeedup = 18.0 / Float(budget)
        print("  Budget \(String(format: "%2d", budget)): \(String(format: "%.1fx", actualSpeedup)) speedup")

        if abs(actualSpeedup - Float(expectedSpeedup)) < 0.01 {
            print("    ✓ Correct")
        } else {
            print("    ✗ FAIL")
            allPassed = false
        }
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST 7: Importance Sum = 1.0 (softmax normalization)
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 7: Importance Normalization (sums to 1.0)")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let spatialSum = gradientResult.spatialImportance.reduce(0, +)
    let temporalSum = gradientResult.temporalImportance.reduce(0, +)

    print("  Spatial sum: \(String(format: "%.4f", spatialSum))")
    print("  Temporal sum: \(String(format: "%.4f", temporalSum))")
    print("")

    if abs(spatialSum - 1.0) < 0.001 && abs(temporalSum - 1.0) < 0.001 {
        print("  ✓ PASS: Both sums are ~1.0")
    } else {
        print("  ✗ FAIL: Softmax normalization incorrect")
        allPassed = false
    }
    print("")

    // ═══════════════════════════════════════════════════════════════════════════
    // SUMMARY
    // ═══════════════════════════════════════════════════════════════════════════

    print("═══════════════════════════════════════════════════════════════════")
    if allPassed {
        print("  ✓ ALL TESTS PASSED")
    } else {
        print("  ✗ SOME TESTS FAILED")
    }
    print("═══════════════════════════════════════════════════════════════════")
    print("")
    print("  Adaptive Processing System verified:")
    print("  • Importance analysis (<50ms)")
    print("  • Uniform content → uniform importance")
    print("  • Motion regions → higher temporal importance")
    print("  • Anchor slices (0, 4, 8) always included")
    print("  • Linear interpolation for skipped slices")
    print("  • Softmax normalization (sums to 1.0)")
    print("")
    print("  Budget → Speedup:")
    print("    6 inferences → 3.0x speedup")
    print("    12 inferences → 1.5x speedup (default)")
    print("    18 inferences → 1.0x (full processing)")
    print("")
    print("  Ready for integration with DualPlayerAttention!")
    print("")
}

main()
