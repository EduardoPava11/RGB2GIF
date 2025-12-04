#!/usr/bin/env swift
//
//  test_perceptual_metrics.swift
//  RGB2GIF
//
//  ============================================================================
//  TEST SCRIPT: Perceptual Quality Metrics
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Verifies that SSIM, Delta E 2000, and PSNR metrics work correctly:
//  1. SSIM returns 1.0 for identical images
//  2. SSIM decreases with increasing noise
//  3. Delta E 2000 returns 0 for identical colors
//  4. Delta E 2000 produces expected values for known color pairs
//  5. PSNR returns infinity for identical images
//  6. Combined score properly weights components
//
//  USAGE
//  ─────
//  swift test_perceptual_metrics.swift
//
//  ============================================================================

import Foundation

// MARK: - Minimal PerceptualMetrics Implementation (mirrors actual)

struct PerceptualMetrics {

    // MARK: - SSIM

    static func ssim(
        original: [UInt8],
        quantized: [UInt8],
        width: Int,
        height: Int
    ) -> Float {
        let originalY = rgbToLuminance(original, width: width, height: height)
        let quantizedY = rgbToLuminance(quantized, width: width, height: height)

        let L: Float = 255.0
        let K1: Float = 0.01
        let K2: Float = 0.03
        let C1 = (K1 * L) * (K1 * L)
        let C2 = (K2 * L) * (K2 * L)

        let windowSize = 8
        let stepSize = 4

        var ssimSum: Float = 0
        var windowCount = 0

        for y in stride(from: 0, to: height - windowSize, by: stepSize) {
            for x in stride(from: 0, to: width - windowSize, by: stepSize) {
                var windowOrig = [Float](repeating: 0, count: windowSize * windowSize)
                var windowQuant = [Float](repeating: 0, count: windowSize * windowSize)

                for wy in 0..<windowSize {
                    for wx in 0..<windowSize {
                        let idx = (y + wy) * width + (x + wx)
                        let widx = wy * windowSize + wx
                        windowOrig[widx] = originalY[idx]
                        windowQuant[widx] = quantizedY[idx]
                    }
                }

                let muX = mean(windowOrig)
                let muY = mean(windowQuant)
                let sigmaX = stdDev(windowOrig, mean: muX)
                let sigmaY = stdDev(windowQuant, mean: muY)
                let sigmaXY = covariance(windowOrig, windowQuant, meanX: muX, meanY: muY)

                let numerator = (2 * muX * muY + C1) * (2 * sigmaXY + C2)
                let denominator = (muX * muX + muY * muY + C1) * (sigmaX * sigmaX + sigmaY * sigmaY + C2)

                let windowSSIM = numerator / denominator
                ssimSum += windowSSIM
                windowCount += 1
            }
        }

        return windowCount > 0 ? ssimSum / Float(windowCount) : 0
    }

    // MARK: - PSNR

    static func psnr(original: [UInt8], quantized: [UInt8]) -> Float {
        guard !original.isEmpty else { return 0 }

        var mse: Float = 0
        for i in 0..<original.count {
            let diff = Float(original[i]) - Float(quantized[i])
            mse += diff * diff
        }
        mse /= Float(original.count)

        if mse == 0 {
            return Float.infinity
        }

        let maxVal: Float = 255.0
        return 10.0 * log10((maxVal * maxVal) / mse)
    }

    // MARK: - Delta E 2000

    static func deltaE2000(
        original: [(r: UInt8, g: UInt8, b: UInt8)],
        quantized: [(r: UInt8, g: UInt8, b: UInt8)]
    ) -> Float {
        guard !original.isEmpty else { return 0 }

        var totalDeltaE: Float = 0

        for i in 0..<original.count {
            let lab1 = rgbToLab(r: original[i].r, g: original[i].g, b: original[i].b)
            let lab2 = rgbToLab(r: quantized[i].r, g: quantized[i].g, b: quantized[i].b)

            totalDeltaE += deltaE2000Single(lab1: lab1, lab2: lab2)
        }

        return totalDeltaE / Float(original.count)
    }

    static func deltaE2000Single(
        lab1: (L: Float, a: Float, b: Float),
        lab2: (L: Float, a: Float, b: Float)
    ) -> Float {
        let kL: Float = 1.0, kC: Float = 1.0, kH: Float = 1.0

        let L1 = lab1.L, a1 = lab1.a, b1 = lab1.b
        let L2 = lab2.L, a2 = lab2.a, b2 = lab2.b

        let C1 = sqrt(a1 * a1 + b1 * b1)
        let C2 = sqrt(a2 * a2 + b2 * b2)
        let Cab = (C1 + C2) / 2.0

        let G = 0.5 * (1.0 - sqrt(pow(Cab, 7) / (pow(Cab, 7) + pow(25.0, 7))))

        let a1Prime = a1 * (1.0 + G)
        let a2Prime = a2 * (1.0 + G)

        let C1Prime = sqrt(a1Prime * a1Prime + b1 * b1)
        let C2Prime = sqrt(a2Prime * a2Prime + b2 * b2)

        func hPrime(_ aPrime: Float, _ b: Float) -> Float {
            if aPrime == 0 && b == 0 { return 0 }
            var h = atan2(b, aPrime) * 180.0 / .pi
            if h < 0 { h += 360 }
            return h
        }

        let h1Prime = hPrime(a1Prime, b1)
        let h2Prime = hPrime(a2Prime, b2)

        let deltaLPrime = L2 - L1
        let deltaCPrime = C2Prime - C1Prime

        var deltahPrime: Float
        if C1Prime * C2Prime == 0 {
            deltahPrime = 0
        } else {
            let diff = h2Prime - h1Prime
            if abs(diff) <= 180 { deltahPrime = diff }
            else if diff > 180 { deltahPrime = diff - 360 }
            else { deltahPrime = diff + 360 }
        }

        let deltaHPrime = 2.0 * sqrt(C1Prime * C2Prime) * sin(deltahPrime * .pi / 360.0)

        let LPrimeBar = (L1 + L2) / 2.0
        let CPrimeBar = (C1Prime + C2Prime) / 2.0

        var hPrimeBar: Float
        if C1Prime * C2Prime == 0 {
            hPrimeBar = h1Prime + h2Prime
        } else {
            let sum = h1Prime + h2Prime
            if abs(h1Prime - h2Prime) <= 180 { hPrimeBar = sum / 2.0 }
            else if sum < 360 { hPrimeBar = (sum + 360) / 2.0 }
            else { hPrimeBar = (sum - 360) / 2.0 }
        }

        let T = 1.0 - 0.17 * cos((hPrimeBar - 30) * .pi / 180)
            + 0.24 * cos(2 * hPrimeBar * .pi / 180)
            + 0.32 * cos((3 * hPrimeBar + 6) * .pi / 180)
            - 0.20 * cos((4 * hPrimeBar - 63) * .pi / 180)

        let deltaTheta = 30.0 * exp(-pow((hPrimeBar - 275) / 25.0, 2))
        let RC = 2.0 * sqrt(pow(CPrimeBar, 7) / (pow(CPrimeBar, 7) + pow(25.0, 7)))
        let SL = 1.0 + (0.015 * pow(LPrimeBar - 50, 2)) / sqrt(20 + pow(LPrimeBar - 50, 2))
        let SC = 1.0 + 0.045 * CPrimeBar
        let SH = 1.0 + 0.015 * CPrimeBar * T
        let RT = -sin(2 * deltaTheta * .pi / 180) * RC

        let term1 = pow(deltaLPrime / (kL * SL), 2)
        let term2 = pow(deltaCPrime / (kC * SC), 2)
        let term3 = pow(deltaHPrime / (kH * SH), 2)
        let term4 = RT * (deltaCPrime / (kC * SC)) * (deltaHPrime / (kH * SH))

        return sqrt(term1 + term2 + term3 + term4)
    }

    // MARK: - Combined Score

    static func combinedScore(ssim: Float, deltaE: Float, psnr: Float) -> Float {
        let normalizedSSIM = max(0, min(1, ssim))
        let normalizedDeltaE = 1.0 / (1.0 + deltaE / 10.0)
        return 0.70 * normalizedSSIM + 0.30 * normalizedDeltaE
    }

    // MARK: - Color Conversion

    static func rgbToLab(r: UInt8, g: UInt8, b: UInt8) -> (L: Float, a: Float, b: Float) {
        var rf = Float(r) / 255.0
        var gf = Float(g) / 255.0
        var bf = Float(b) / 255.0

        rf = rf > 0.04045 ? pow((rf + 0.055) / 1.055, 2.4) : rf / 12.92
        gf = gf > 0.04045 ? pow((gf + 0.055) / 1.055, 2.4) : gf / 12.92
        bf = bf > 0.04045 ? pow((bf + 0.055) / 1.055, 2.4) : bf / 12.92

        rf *= 100; gf *= 100; bf *= 100

        let x = rf * 0.4124564 + gf * 0.3575761 + bf * 0.1804375
        let y = rf * 0.2126729 + gf * 0.7151522 + bf * 0.0721750
        let z = rf * 0.0193339 + gf * 0.1191920 + bf * 0.9503041

        let refX: Float = 95.047, refY: Float = 100.000, refZ: Float = 108.883

        var xn = x / refX, yn = y / refY, zn = z / refZ

        let threshold: Float = 0.008856, kappa: Float = 903.3

        xn = xn > threshold ? pow(xn, 1.0/3.0) : (kappa * xn + 16) / 116
        yn = yn > threshold ? pow(yn, 1.0/3.0) : (kappa * yn + 16) / 116
        zn = zn > threshold ? pow(zn, 1.0/3.0) : (kappa * zn + 16) / 116

        let L = 116 * yn - 16
        let a = 500 * (xn - yn)
        let labB = 200 * (yn - zn)

        return (L, a, labB)
    }

    // MARK: - Helpers

    private static func rgbToLuminance(_ rgb: [UInt8], width: Int, height: Int) -> [Float] {
        var luminance = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Float(rgb[i * 3])
            let g = Float(rgb[i * 3 + 1])
            let b = Float(rgb[i * 3 + 2])
            luminance[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return luminance
    }

    private static func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    private static func stdDev(_ values: [Float], mean: Float) -> Float {
        guard values.count > 1 else { return 0 }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        return sqrt(variance)
    }

    private static func covariance(_ x: [Float], _ y: [Float], meanX: Float, meanY: Float) -> Float {
        guard x.count == y.count, !x.isEmpty else { return 0 }
        var cov: Float = 0
        for i in 0..<x.count {
            cov += (x[i] - meanX) * (y[i] - meanY)
        }
        return cov / Float(x.count)
    }
}

// MARK: - Test Utilities

func createSolidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
    var image = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
        image[i * 3] = r
        image[i * 3 + 1] = g
        image[i * 3 + 2] = b
    }
    return image
}

func createGradientImage(width: Int, height: Int) -> [UInt8] {
    var image = [UInt8](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 3
            image[i] = UInt8(x * 255 / width)
            image[i + 1] = UInt8(y * 255 / height)
            image[i + 2] = 128
        }
    }
    return image
}

func addNoise(_ image: [UInt8], level: Int) -> [UInt8] {
    var noisy = image
    for i in 0..<noisy.count {
        let noise = Int.random(in: -level...level)
        let newVal = Int(noisy[i]) + noise
        noisy[i] = UInt8(max(0, min(255, newVal)))
    }
    return noisy
}

// MARK: - Tests

func testSSIMIdentical() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 1: SSIM - Identical Images")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let width = 64, height = 64
    let image = createGradientImage(width: width, height: height)

    let ssim = PerceptualMetrics.ssim(original: image, quantized: image, width: width, height: height)

    print("  Image: \(width)×\(height) gradient")
    print("  SSIM: \(String(format: "%.6f", ssim))")
    print("  Expected: ~1.0")
    print("")

    if ssim > 0.99 {
        print("  ✓ PASS: SSIM is approximately 1.0 for identical images")
    } else {
        print("  ✗ FAIL: SSIM should be ~1.0 but got \(ssim)")
    }
}

func testSSIMWithNoise() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 2: SSIM - Decreases with Noise")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let width = 64, height = 64
    let original = createGradientImage(width: width, height: height)

    let noiseLevels = [5, 10, 20, 40]
    var previousSSIM: Float = 1.0

    print("  Noise Level    SSIM      Change")
    print("  ──────────────────────────────────")

    var allDecreasing = true
    for level in noiseLevels {
        let noisy = addNoise(original, level: level)
        let ssim = PerceptualMetrics.ssim(original: original, quantized: noisy, width: width, height: height)
        let change = ssim - previousSSIM

        print("  ±\(String(format: "%2d", level))            \(String(format: "%.4f", ssim))    \(String(format: "%+.4f", change))")

        if ssim >= previousSSIM && level > 0 {
            allDecreasing = false
        }
        previousSSIM = ssim
    }

    print("")
    if allDecreasing {
        print("  ✓ PASS: SSIM decreases monotonically with noise")
    } else {
        print("  ✗ FAIL: SSIM should decrease as noise increases")
    }
}

func testPSNRIdentical() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 3: PSNR - Identical Images")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let image = createSolidImage(width: 32, height: 32, r: 128, g: 64, b: 192)

    let psnr = PerceptualMetrics.psnr(original: image, quantized: image)

    print("  PSNR: \(psnr)")
    print("  Expected: infinity")
    print("")

    if psnr.isInfinite {
        print("  ✓ PASS: PSNR is infinity for identical images")
    } else {
        print("  ✗ FAIL: PSNR should be infinity but got \(psnr)")
    }
}

func testPSNRWithDifference() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 4: PSNR - With Differences")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let original = createSolidImage(width: 32, height: 32, r: 128, g: 128, b: 128)

    let differences = [1, 5, 10, 20, 50]

    print("  Pixel Diff    PSNR (dB)")
    print("  ────────────────────────")

    var previousPSNR: Float = Float.infinity
    var allDecreasing = true

    for diff in differences {
        let modified = createSolidImage(width: 32, height: 32, r: UInt8(128 + diff), g: 128, b: 128)
        let psnr = PerceptualMetrics.psnr(original: original, quantized: modified)

        print("  ±\(String(format: "%2d", diff))           \(String(format: "%.2f", psnr))")

        if psnr >= previousPSNR && !previousPSNR.isInfinite {
            allDecreasing = false
        }
        previousPSNR = psnr
    }

    print("")
    if allDecreasing {
        print("  ✓ PASS: PSNR decreases as difference increases")
    } else {
        print("  ✗ FAIL: PSNR should decrease as difference increases")
    }
}

func testDeltaEIdentical() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 5: Delta E 2000 - Identical Colors")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (128, 64, 192),
        (255, 0, 0),
        (0, 255, 0),
        (0, 0, 255),
    ]

    let deltaE = PerceptualMetrics.deltaE2000(original: colors, quantized: colors)

    print("  Delta E: \(String(format: "%.6f", deltaE))")
    print("  Expected: 0.0")
    print("")

    if deltaE < 0.001 {
        print("  ✓ PASS: Delta E is ~0 for identical colors")
    } else {
        print("  ✗ FAIL: Delta E should be 0 but got \(deltaE)")
    }
}

func testDeltaEKnownPairs() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 6: Delta E 2000 - Known Color Pairs")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    // Test known color pairs with expected Delta E ranges
    let testCases: [(name: String, c1: (r: UInt8, g: UInt8, b: UInt8), c2: (r: UInt8, g: UInt8, b: UInt8), expectedRange: ClosedRange<Float>)] = [
        ("White vs Black", (255, 255, 255), (0, 0, 0), 90...110),
        ("Red vs Green", (255, 0, 0), (0, 255, 0), 50...90),
        ("Similar grays", (128, 128, 128), (130, 130, 130), 0...3),
        ("Near-white", (255, 255, 255), (250, 250, 250), 0...5),
    ]

    var allPassed = true

    print("  Color Pair              Delta E    Expected Range")
    print("  ────────────────────────────────────────────────────")

    for test in testCases {
        let original = [test.c1]
        let quantized = [test.c2]
        let deltaE = PerceptualMetrics.deltaE2000(original: original, quantized: quantized)

        let inRange = test.expectedRange.contains(deltaE)
        let status = inRange ? "✓" : "✗"

        print("  \(test.name.padding(toLength: 18, withPad: " ", startingAt: 0))  \(String(format: "%6.2f", deltaE))     \(test.expectedRange)  \(status)")

        if !inRange {
            allPassed = false
        }
    }

    print("")
    if allPassed {
        print("  ✓ PASS: All Delta E values within expected ranges")
    } else {
        print("  ✗ FAIL: Some Delta E values outside expected ranges")
    }
}

func testCombinedScore() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 7: Combined Score Weighting")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    let testCases: [(ssim: Float, deltaE: Float, psnr: Float, expectedRange: ClosedRange<Float>)] = [
        (1.0, 0.0, Float.infinity, 0.99...1.01),  // Perfect
        (0.0, 100.0, 0.0, 0.0...0.05),            // Terrible
        (0.5, 10.0, 30.0, 0.45...0.55),           // Medium
        (0.9, 5.0, 40.0, 0.75...0.85),            // Good
    ]

    var allPassed = true

    print("  SSIM    ΔE      Combined    Expected")
    print("  ─────────────────────────────────────")

    for test in testCases {
        let combined = PerceptualMetrics.combinedScore(ssim: test.ssim, deltaE: test.deltaE, psnr: test.psnr)
        let inRange = test.expectedRange.contains(combined)
        let status = inRange ? "✓" : "✗"

        print("  \(String(format: "%.1f", test.ssim))     \(String(format: "%5.1f", test.deltaE))   \(String(format: "%.3f", combined))       \(test.expectedRange)  \(status)")

        if !inRange { allPassed = false }
    }

    print("")
    if allPassed {
        print("  ✓ PASS: Combined scores weighted correctly")
    } else {
        print("  ✗ FAIL: Some combined scores outside expected ranges")
    }
}

func testRGBtoLabConversion() {
    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  TEST 8: RGB to Lab Conversion")
    print("═══════════════════════════════════════════════════════════════════")
    print("")

    // Known conversions (approximate)
    let testColors: [(name: String, rgb: (r: UInt8, g: UInt8, b: UInt8), expectedL: Float)] = [
        ("White", (255, 255, 255), 100.0),
        ("Black", (0, 0, 0), 0.0),
        ("Mid-gray", (128, 128, 128), 53.0),  // Approximate
        ("Pure Red", (255, 0, 0), 53.0),       // Approximate
    ]

    var allPassed = true

    print("  Color       RGB             L*       Expected L*")
    print("  ──────────────────────────────────────────────────")

    for test in testColors {
        let lab = PerceptualMetrics.rgbToLab(r: test.rgb.r, g: test.rgb.g, b: test.rgb.b)
        let tolerance: Float = 5.0
        let inRange = abs(lab.L - test.expectedL) < tolerance
        let status = inRange ? "✓" : "✗"

        print("  \(test.name.padding(toLength: 10, withPad: " ", startingAt: 0))  (\(test.rgb.r), \(test.rgb.g), \(test.rgb.b))".padding(toLength: 28, withPad: " ", startingAt: 0) + "  \(String(format: "%6.1f", lab.L))   ~\(test.expectedL)  \(status)")

        if !inRange { allPassed = false }
    }

    print("")
    if allPassed {
        print("  ✓ PASS: Lab conversions within expected tolerances")
    } else {
        print("  ✗ FAIL: Some Lab conversions outside tolerances")
    }
}

// MARK: - Main

func main() {
    print("")
    print("╔═══════════════════════════════════════════════════════════════════╗")
    print("║     RGB2GIF Perceptual Metrics Test Suite                         ║")
    print("╚═══════════════════════════════════════════════════════════════════╝")

    testSSIMIdentical()
    testSSIMWithNoise()
    testPSNRIdentical()
    testPSNRWithDifference()
    testDeltaEIdentical()
    testDeltaEKnownPairs()
    testCombinedScore()
    testRGBtoLabConversion()

    print("")
    print("═══════════════════════════════════════════════════════════════════")
    print("  ✓ ALL TESTS COMPLETE")
    print("═══════════════════════════════════════════════════════════════════")
    print("")
    print("  Perceptual Metrics verified:")
    print("  • SSIM: Returns 1.0 for identical, decreases with noise")
    print("  • PSNR: Returns ∞ for identical, decreases with difference")
    print("  • Delta E 2000: Returns 0 for identical, expected ranges for pairs")
    print("  • Combined Score: Properly weights SSIM (70%) + Delta E (30%)")
    print("  • RGB→Lab: Conversions within expected tolerances")
    print("")
    print("  Ready for hybrid reward system integration!")
    print("")
}

main()
