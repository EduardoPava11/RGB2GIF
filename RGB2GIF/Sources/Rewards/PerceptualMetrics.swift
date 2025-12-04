//
//  PerceptualMetrics.swift
//  RGB2GIF
//
//  ============================================================================
//  PERCEPTUAL QUALITY METRICS FOR ATTENTION REWARD SYSTEM
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Provides objective quality measurements for comparing original video frames
//  to quantized GIF output. These metrics feed into the hybrid reward system
//  to train attention genes.
//
//  METRICS IMPLEMENTED
//  ───────────────────
//  1. SSIM (Structural Similarity Index)
//     - Measures structural patterns, luminance, and contrast
//     - Range: -1 to 1 (higher is better, 1 = identical)
//     - Computed using 8×8 windows with Gaussian weighting
//
//  2. Delta E 2000 (CIE ΔE₀₀)
//     - Perceptually uniform color difference
//     - Range: 0 to 100+ (lower is better, 0 = identical)
//     - Accounts for human color perception non-uniformities
//
//  3. PSNR (Peak Signal-to-Noise Ratio)
//     - Classic reconstruction quality metric
//     - Range: 0 to ∞ dB (higher is better, ∞ = identical)
//     - Good for tracking improvement over time
//
//  USAGE
//  ─────
//  These metrics are computed after GIF export and combined into a single
//  perceptual score that forms 45% of the hybrid reward signal.
//
//  ============================================================================

import Foundation
import Accelerate

// MARK: - Perceptual Metrics

/// Computes perceptual quality metrics for GIF quantization evaluation.
///
/// Uses Accelerate framework for efficient SIMD operations on image data.
@available(iOS 15.0, macOS 12.0, *)
public struct PerceptualMetrics: Sendable {

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Combined Score
    // ═══════════════════════════════════════════════════════════════════════════

    /// Combined perceptual quality score (0-1, higher is better).
    ///
    /// Weights:
    /// - SSIM: 70% (most perceptually relevant)
    /// - Delta E: 30% (color accuracy)
    /// - PSNR: Used for logging only (not in combined score)
    ///
    /// - Parameters:
    ///   - ssim: Structural similarity index (0-1)
    ///   - deltaE: Color difference (0-100+)
    ///   - psnr: Peak signal-to-noise ratio (dB)
    /// - Returns: Combined score (0-1)
    public static func combinedScore(ssim: Float, deltaE: Float, psnr: Float) -> Float {
        // Normalize SSIM to 0-1 (already in this range, but clamp)
        let normalizedSSIM = max(0, min(1, ssim))

        // Normalize Delta E: 0 is perfect, 100+ is very bad
        // Use sigmoid-like curve: 1 / (1 + deltaE/10)
        let normalizedDeltaE = 1.0 / (1.0 + deltaE / 10.0)

        // Combine with weights
        let score = 0.70 * normalizedSSIM + 0.30 * normalizedDeltaE

        return score
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - SSIM (Structural Similarity Index)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute SSIM between original and quantized frame data.
    ///
    /// Uses the standard SSIM formula with constants:
    /// - C1 = (K1 * L)² where K1 = 0.01, L = 255
    /// - C2 = (K2 * L)² where K2 = 0.03, L = 255
    ///
    /// - Parameters:
    ///   - original: Original frame pixels as RGB bytes (width × height × 3)
    ///   - quantized: Quantized frame pixels (palette indices expanded to RGB)
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    /// - Returns: SSIM value (-1 to 1, typically 0.5-1 for reasonable quality)
    public static func ssim(
        original: [UInt8],
        quantized: [UInt8],
        width: Int,
        height: Int
    ) -> Float {
        precondition(original.count == quantized.count)
        precondition(original.count == width * height * 3)

        // Convert to luminance (Y channel)
        let originalY = rgbToLuminance(original, width: width, height: height)
        let quantizedY = rgbToLuminance(quantized, width: width, height: height)

        // SSIM constants
        let L: Float = 255.0
        let K1: Float = 0.01
        let K2: Float = 0.03
        let C1 = (K1 * L) * (K1 * L)
        let C2 = (K2 * L) * (K2 * L)

        // Window size
        let windowSize = 8
        let stepSize = 4  // 50% overlap

        var ssimSum: Float = 0
        var windowCount = 0

        // Slide window across image
        for y in stride(from: 0, to: height - windowSize, by: stepSize) {
            for x in stride(from: 0, to: width - windowSize, by: stepSize) {
                // Extract windows
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

                // Compute statistics
                let muX = mean(windowOrig)
                let muY = mean(windowQuant)
                let sigmaX = stdDev(windowOrig, mean: muX)
                let sigmaY = stdDev(windowQuant, mean: muY)
                let sigmaXY = covariance(windowOrig, windowQuant, meanX: muX, meanY: muY)

                // SSIM formula
                let numerator = (2 * muX * muY + C1) * (2 * sigmaXY + C2)
                let denominator = (muX * muX + muY * muY + C1) * (sigmaX * sigmaX + sigmaY * sigmaY + C2)

                let windowSSIM = numerator / denominator
                ssimSum += windowSSIM
                windowCount += 1
            }
        }

        return windowCount > 0 ? ssimSum / Float(windowCount) : 0
    }

    /// Compute SSIM for a batch of frames.
    ///
    /// - Parameters:
    ///   - originalFrames: Array of original frame data
    ///   - quantizedFrames: Array of quantized frame data
    ///   - width: Frame width
    ///   - height: Frame height
    /// - Returns: Array of SSIM values per frame
    public static func ssimBatch(
        originalFrames: [[UInt8]],
        quantizedFrames: [[UInt8]],
        width: Int,
        height: Int
    ) -> [Float] {
        precondition(originalFrames.count == quantizedFrames.count)

        return zip(originalFrames, quantizedFrames).map { orig, quant in
            ssim(original: orig, quantized: quant, width: width, height: height)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Delta E 2000
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute Delta E 2000 color difference between original and quantized.
    ///
    /// Delta E 2000 is the most perceptually accurate color difference metric,
    /// accounting for:
    /// - Lightness weighting (humans are more sensitive to lightness changes)
    /// - Chroma weighting (less sensitive to chroma in desaturated colors)
    /// - Hue weighting (less sensitive to hue in neutral colors)
    /// - Interactive terms between differences
    ///
    /// - Parameters:
    ///   - original: Original pixel RGB values
    ///   - quantized: Quantized pixel RGB values
    /// - Returns: Average Delta E 2000 across all pixels (0 = identical, 100+ = very different)
    public static func deltaE2000(
        original: [(r: UInt8, g: UInt8, b: UInt8)],
        quantized: [(r: UInt8, g: UInt8, b: UInt8)]
    ) -> Float {
        precondition(original.count == quantized.count)
        guard !original.isEmpty else { return 0 }

        var totalDeltaE: Float = 0

        for i in 0..<original.count {
            let lab1 = rgbToLab(r: original[i].r, g: original[i].g, b: original[i].b)
            let lab2 = rgbToLab(r: quantized[i].r, g: quantized[i].g, b: quantized[i].b)

            totalDeltaE += deltaE2000Single(lab1: lab1, lab2: lab2)
        }

        return totalDeltaE / Float(original.count)
    }

    /// Compute Delta E 2000 for a single Lab color pair.
    ///
    /// Implements the full CIE DE2000 formula from:
    /// "The CIEDE2000 Color-Difference Formula: Implementation Notes"
    private static func deltaE2000Single(
        lab1: (L: Float, a: Float, b: Float),
        lab2: (L: Float, a: Float, b: Float)
    ) -> Float {
        let kL: Float = 1.0
        let kC: Float = 1.0
        let kH: Float = 1.0

        let L1 = lab1.L, a1 = lab1.a, b1 = lab1.b
        let L2 = lab2.L, a2 = lab2.a, b2 = lab2.b

        // Calculate C'
        let C1 = sqrt(a1 * a1 + b1 * b1)
        let C2 = sqrt(a2 * a2 + b2 * b2)
        let Cab = (C1 + C2) / 2.0

        let G = 0.5 * (1.0 - sqrt(pow(Cab, 7) / (pow(Cab, 7) + pow(25.0, 7))))

        let a1Prime = a1 * (1.0 + G)
        let a2Prime = a2 * (1.0 + G)

        let C1Prime = sqrt(a1Prime * a1Prime + b1 * b1)
        let C2Prime = sqrt(a2Prime * a2Prime + b2 * b2)

        // Calculate h'
        func hPrime(_ aPrime: Float, _ b: Float) -> Float {
            if aPrime == 0 && b == 0 {
                return 0
            }
            var h = atan2(b, aPrime) * 180.0 / .pi
            if h < 0 { h += 360 }
            return h
        }

        let h1Prime = hPrime(a1Prime, b1)
        let h2Prime = hPrime(a2Prime, b2)

        // Calculate ΔL', ΔC', ΔH'
        let deltaLPrime = L2 - L1
        let deltaCPrime = C2Prime - C1Prime

        var deltahPrime: Float
        if C1Prime * C2Prime == 0 {
            deltahPrime = 0
        } else {
            let diff = h2Prime - h1Prime
            if abs(diff) <= 180 {
                deltahPrime = diff
            } else if diff > 180 {
                deltahPrime = diff - 360
            } else {
                deltahPrime = diff + 360
            }
        }

        let deltaHPrime = 2.0 * sqrt(C1Prime * C2Prime) * sin(deltahPrime * .pi / 360.0)

        // Calculate L̄', C̄', h̄'
        let LPrimeBar = (L1 + L2) / 2.0
        let CPrimeBar = (C1Prime + C2Prime) / 2.0

        var hPrimeBar: Float
        if C1Prime * C2Prime == 0 {
            hPrimeBar = h1Prime + h2Prime
        } else {
            let sum = h1Prime + h2Prime
            if abs(h1Prime - h2Prime) <= 180 {
                hPrimeBar = sum / 2.0
            } else if sum < 360 {
                hPrimeBar = (sum + 360) / 2.0
            } else {
                hPrimeBar = (sum - 360) / 2.0
            }
        }

        // Calculate T
        let T = 1.0 - 0.17 * cos((hPrimeBar - 30) * .pi / 180)
            + 0.24 * cos(2 * hPrimeBar * .pi / 180)
            + 0.32 * cos((3 * hPrimeBar + 6) * .pi / 180)
            - 0.20 * cos((4 * hPrimeBar - 63) * .pi / 180)

        // Calculate SL, SC, SH
        let deltaTheta = 30.0 * exp(-pow((hPrimeBar - 275) / 25.0, 2))
        let RC = 2.0 * sqrt(pow(CPrimeBar, 7) / (pow(CPrimeBar, 7) + pow(25.0, 7)))
        let SL = 1.0 + (0.015 * pow(LPrimeBar - 50, 2)) / sqrt(20 + pow(LPrimeBar - 50, 2))
        let SC = 1.0 + 0.045 * CPrimeBar
        let SH = 1.0 + 0.015 * CPrimeBar * T
        let RT = -sin(2 * deltaTheta * .pi / 180) * RC

        // Calculate ΔE₀₀
        let term1 = pow(deltaLPrime / (kL * SL), 2)
        let term2 = pow(deltaCPrime / (kC * SC), 2)
        let term3 = pow(deltaHPrime / (kH * SH), 2)
        let term4 = RT * (deltaCPrime / (kC * SC)) * (deltaHPrime / (kH * SH))

        return sqrt(term1 + term2 + term3 + term4)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - PSNR (Peak Signal-to-Noise Ratio)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Compute PSNR between original and quantized frame data.
    ///
    /// PSNR = 10 × log₁₀(MAX² / MSE)
    ///
    /// - Parameters:
    ///   - original: Original frame pixels as RGB bytes
    ///   - quantized: Quantized frame pixels as RGB bytes
    /// - Returns: PSNR in decibels (higher is better, ∞ if identical)
    public static func psnr(
        original: [UInt8],
        quantized: [UInt8]
    ) -> Float {
        precondition(original.count == quantized.count)
        guard !original.isEmpty else { return 0 }

        var mse: Float = 0
        for i in 0..<original.count {
            let diff = Float(original[i]) - Float(quantized[i])
            mse += diff * diff
        }
        mse /= Float(original.count)

        if mse == 0 {
            return Float.infinity  // Identical images
        }

        let maxVal: Float = 255.0
        return 10.0 * log10((maxVal * maxVal) / mse)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Color Space Conversions
    // ═══════════════════════════════════════════════════════════════════════════

    /// Convert RGB to CIE Lab color space.
    ///
    /// Uses D65 illuminant (standard daylight).
    public static func rgbToLab(r: UInt8, g: UInt8, b: UInt8) -> (L: Float, a: Float, b: Float) {
        // RGB to XYZ (sRGB with D65)
        var rf = Float(r) / 255.0
        var gf = Float(g) / 255.0
        var bf = Float(b) / 255.0

        // Gamma correction (sRGB)
        rf = rf > 0.04045 ? pow((rf + 0.055) / 1.055, 2.4) : rf / 12.92
        gf = gf > 0.04045 ? pow((gf + 0.055) / 1.055, 2.4) : gf / 12.92
        bf = bf > 0.04045 ? pow((bf + 0.055) / 1.055, 2.4) : bf / 12.92

        rf *= 100
        gf *= 100
        bf *= 100

        // sRGB to XYZ (D65)
        let x = rf * 0.4124564 + gf * 0.3575761 + bf * 0.1804375
        let y = rf * 0.2126729 + gf * 0.7151522 + bf * 0.0721750
        let z = rf * 0.0193339 + gf * 0.1191920 + bf * 0.9503041

        // Reference white D65
        let refX: Float = 95.047
        let refY: Float = 100.000
        let refZ: Float = 108.883

        var xn = x / refX
        var yn = y / refY
        var zn = z / refZ

        let threshold: Float = 0.008856
        let kappa: Float = 903.3

        xn = xn > threshold ? pow(xn, 1.0/3.0) : (kappa * xn + 16) / 116
        yn = yn > threshold ? pow(yn, 1.0/3.0) : (kappa * yn + 16) / 116
        zn = zn > threshold ? pow(zn, 1.0/3.0) : (kappa * zn + 16) / 116

        let L = 116 * yn - 16
        let a = 500 * (xn - yn)
        let labB = 200 * (yn - zn)

        return (L, a, labB)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Helper Functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// Convert RGB image to luminance (Y channel).
    private static func rgbToLuminance(_ rgb: [UInt8], width: Int, height: Int) -> [Float] {
        var luminance = [Float](repeating: 0, count: width * height)

        for i in 0..<(width * height) {
            let r = Float(rgb[i * 3])
            let g = Float(rgb[i * 3 + 1])
            let b = Float(rgb[i * 3 + 2])

            // ITU-R BT.601 luma coefficients
            luminance[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        return luminance
    }

    /// Compute mean of array.
    private static func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Compute standard deviation of array.
    private static func stdDev(_ values: [Float], mean: Float) -> Float {
        guard values.count > 1 else { return 0 }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        return sqrt(variance)
    }

    /// Compute covariance of two arrays.
    private static func covariance(_ x: [Float], _ y: [Float], meanX: Float, meanY: Float) -> Float {
        guard x.count == y.count, !x.isEmpty else { return 0 }
        var cov: Float = 0
        for i in 0..<x.count {
            cov += (x[i] - meanX) * (y[i] - meanY)
        }
        return cov / Float(x.count)
    }
}

// MARK: - Convenience Extensions

@available(iOS 15.0, macOS 12.0, *)
extension PerceptualMetrics {

    /// Compute all metrics at once for efficiency.
    ///
    /// - Parameters:
    ///   - originalRGB: Original frame as RGB bytes (width × height × 3)
    ///   - quantizedRGB: Quantized frame as RGB bytes
    ///   - width: Frame width
    ///   - height: Frame height
    /// - Returns: Tuple of (ssim, deltaE, psnr, combinedScore)
    public static func computeAll(
        originalRGB: [UInt8],
        quantizedRGB: [UInt8],
        width: Int,
        height: Int
    ) -> (ssim: Float, deltaE: Float, psnr: Float, combined: Float) {

        // Compute SSIM
        let ssimValue = ssim(original: originalRGB, quantized: quantizedRGB, width: width, height: height)

        // Compute PSNR
        let psnrValue = psnr(original: originalRGB, quantized: quantizedRGB)

        // Convert to pixel tuples for Delta E
        let pixelCount = width * height
        var origPixels = [(r: UInt8, g: UInt8, b: UInt8)]()
        var quantPixels = [(r: UInt8, g: UInt8, b: UInt8)]()
        origPixels.reserveCapacity(pixelCount)
        quantPixels.reserveCapacity(pixelCount)

        for i in 0..<pixelCount {
            origPixels.append((originalRGB[i*3], originalRGB[i*3+1], originalRGB[i*3+2]))
            quantPixels.append((quantizedRGB[i*3], quantizedRGB[i*3+1], quantizedRGB[i*3+2]))
        }

        // Compute Delta E (sample for speed - every 4th pixel)
        var sampledOrig = [(r: UInt8, g: UInt8, b: UInt8)]()
        var sampledQuant = [(r: UInt8, g: UInt8, b: UInt8)]()
        for i in stride(from: 0, to: pixelCount, by: 4) {
            sampledOrig.append(origPixels[i])
            sampledQuant.append(quantPixels[i])
        }

        let deltaEValue = deltaE2000(original: sampledOrig, quantized: sampledQuant)

        // Combined score
        let combined = combinedScore(ssim: ssimValue, deltaE: deltaEValue, psnr: psnrValue)

        return (ssimValue, deltaEValue, psnrValue, combined)
    }
}

// MARK: - Result Structure

/// Container for perceptual metric results.
public struct PerceptualMetricsResult: Codable, Sendable {
    /// Structural Similarity Index (0-1, higher is better)
    public let ssim: Float

    /// Delta E 2000 color difference (0-100+, lower is better)
    public let deltaE: Float

    /// Peak Signal-to-Noise Ratio in dB (higher is better)
    public let psnr: Float

    /// Combined perceptual score (0-1, higher is better)
    public let combinedScore: Float

    /// Computation timestamp
    public let timestamp: Date

    /// Initialize from computed values.
    public init(ssim: Float, deltaE: Float, psnr: Float, combinedScore: Float) {
        self.ssim = ssim
        self.deltaE = deltaE
        self.psnr = psnr
        self.combinedScore = combinedScore
        self.timestamp = Date()
    }
}
