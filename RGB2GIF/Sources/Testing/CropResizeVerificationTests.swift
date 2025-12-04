//
//  CropResizeVerificationTests.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  SYNTHETIC CROP/RESIZE VERIFICATION TESTS                                 ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  These tests create synthetic images with known pixel values and verify   ║
//  ║  that FrameFormatConverter.safeCropAndResizeToRGB() produces correct      ║
//  ║  output. This catches coordinate system bugs that real camera tests miss. ║
//  ║                                                                           ║
//  ║  V.1  Gradient Test - R=X, G=Y, B=128                                     ║
//  ║  V.2  Quadrant Test - TL=Red, TR=Green, BL=Blue, BR=Yellow               ║
//  ║  V.3  Coordinate Trace - Verify L2→L0 mapping formula                    ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CoreGraphics
import os.log

private let verifyLogger = Logger(subsystem: "com.rgb2gif.tests", category: "CropResizeVerify")

@available(iOS 26.0, *)
public struct CropResizeVerificationTests {

    // MARK: - Test 1: Gradient Test

    /// Create a synthetic 720×1280 BGRA image with known gradient values
    /// R = x coordinate scaled to 0-255
    /// G = y coordinate scaled to 0-255
    /// B = 128 (constant)
    ///
    /// Verify corners of output match expected gradient values
    public static func testGradient() -> (passed: Bool, diagnostic: String) {
        let srcWidth = 720
        let srcHeight = 1280

        // Calculate expected crop parameters
        let cropSize = min(srcWidth, srcHeight)  // 720
        let cropX = (srcWidth - cropSize) / 2     // 0
        let cropY = (srcHeight - cropSize) / 2    // 280
        let targetSize = 81
        let scale = Double(cropSize) / Double(targetSize)  // 8.888...

        // Create BGRA pixel data with gradient
        var bgra = [UInt8](repeating: 0, count: srcWidth * srcHeight * 4)

        for y in 0..<srcHeight {
            for x in 0..<srcWidth {
                let offset = (y * srcWidth + x) * 4
                let r = UInt8((x * 255) / max(srcWidth - 1, 1))
                let g = UInt8((y * 255) / max(srcHeight - 1, 1))
                let b: UInt8 = 128

                // BGRA order (byteOrder32Little + premultipliedFirst)
                bgra[offset + 0] = b  // B
                bgra[offset + 1] = g  // G
                bgra[offset + 2] = r  // R
                bgra[offset + 3] = 255 // A
            }
        }

        // Create CGImage with camera-like format
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let testImage = CGImage(
                  width: srcWidth,
                  height: srcHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: srcWidth * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return (false, "V.1 GRADIENT TEST: FAILED - Could not create test CGImage")
        }

        // Run crop+resize
        let rgb = FrameFormatConverter.safeCropAndResizeToRGB(testImage, targetSize: targetSize)

        guard rgb.count == targetSize * targetSize * 3 else {
            return (false, "V.1 GRADIENT TEST: FAILED - Output size wrong: \(rgb.count) vs expected \(targetSize * targetSize * 3)")
        }

        // Calculate expected corner values
        // Output (outX, outY) maps to source (cropX + (outX+0.5)*scale, cropY + (outY+0.5)*scale)

        func expectedRGB(outX: Int, outY: Int) -> (UInt8, UInt8, UInt8) {
            let srcX = Int(Double(cropX) + (Double(outX) + 0.5) * scale)
            let srcY = Int(Double(cropY) + (Double(outY) + 0.5) * scale)
            let r = UInt8((srcX * 255) / max(srcWidth - 1, 1))
            let g = UInt8((srcY * 255) / max(srcHeight - 1, 1))
            return (r, g, 128)
        }

        func getActualRGB(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * targetSize + x) * 3
            return (rgb[offset], rgb[offset + 1], rgb[offset + 2])
        }

        let tolerance: Int = 5  // Allow small rounding differences

        func matches(_ actual: (UInt8, UInt8, UInt8), _ expected: (UInt8, UInt8, UInt8)) -> Bool {
            abs(Int(actual.0) - Int(expected.0)) <= tolerance &&
            abs(Int(actual.1) - Int(expected.1)) <= tolerance &&
            abs(Int(actual.2) - Int(expected.2)) <= tolerance
        }

        // Check corners
        let tlExpected = expectedRGB(outX: 0, outY: 0)
        let trExpected = expectedRGB(outX: 80, outY: 0)
        let blExpected = expectedRGB(outX: 0, outY: 80)
        let brExpected = expectedRGB(outX: 80, outY: 80)

        let tlActual = getActualRGB(x: 0, y: 0)
        let trActual = getActualRGB(x: 80, y: 0)
        let blActual = getActualRGB(x: 0, y: 80)
        let brActual = getActualRGB(x: 80, y: 80)

        let tlMatch = matches(tlActual, tlExpected)
        let trMatch = matches(trActual, trExpected)
        let blMatch = matches(blActual, blExpected)
        let brMatch = matches(brActual, brExpected)

        let allMatch = tlMatch && trMatch && blMatch && brMatch

        let diagnostic = """
        ═══════════════════════════════════════════════════════════════════════════════
        V.1 GRADIENT TEST (R=X, G=Y, B=128)
        ═══════════════════════════════════════════════════════════════════════════════

        Source: \(srcWidth)×\(srcHeight), Crop: \(cropSize)×\(cropSize) at (\(cropX),\(cropY))
        Output: \(targetSize)×\(targetSize), Scale: \(String(format: "%.3f", scale))

        ┌──────────┬─────────────────────┬─────────────────────┬─────────┐
        │ Corner   │ Expected RGB        │ Actual RGB          │ Match?  │
        ├──────────┼─────────────────────┼─────────────────────┼─────────┤
        │ TL (0,0) │ (\(String(format: "%3d", tlExpected.0)),\(String(format: "%3d", tlExpected.1)),\(String(format: "%3d", tlExpected.2)))           │ (\(String(format: "%3d", tlActual.0)),\(String(format: "%3d", tlActual.1)),\(String(format: "%3d", tlActual.2)))           │ \(tlMatch ? "✓ YES" : "✗ NO")   │
        │ TR(80,0) │ (\(String(format: "%3d", trExpected.0)),\(String(format: "%3d", trExpected.1)),\(String(format: "%3d", trExpected.2)))           │ (\(String(format: "%3d", trActual.0)),\(String(format: "%3d", trActual.1)),\(String(format: "%3d", trActual.2)))           │ \(trMatch ? "✓ YES" : "✗ NO")   │
        │ BL(0,80) │ (\(String(format: "%3d", blExpected.0)),\(String(format: "%3d", blExpected.1)),\(String(format: "%3d", blExpected.2)))           │ (\(String(format: "%3d", blActual.0)),\(String(format: "%3d", blActual.1)),\(String(format: "%3d", blActual.2)))           │ \(blMatch ? "✓ YES" : "✗ NO")   │
        │ BR(80,80)│ (\(String(format: "%3d", brExpected.0)),\(String(format: "%3d", brExpected.1)),\(String(format: "%3d", brExpected.2)))           │ (\(String(format: "%3d", brActual.0)),\(String(format: "%3d", brActual.1)),\(String(format: "%3d", brActual.2)))           │ \(brMatch ? "✓ YES" : "✗ NO")   │
        └──────────┴─────────────────────┴─────────────────────┴─────────┘

        RESULT: \(allMatch ? "✓ PASS - All corners match expected gradient values" : "✗ FAIL - Corner mismatch detected")
        """

        return (allMatch, diagnostic)
    }

    // MARK: - Test 2: Quadrant Color Test

    /// Create a 720×720 square image with 4 solid color quadrants
    /// TL = Red (255,0,0)
    /// TR = Green (0,255,0)
    /// BL = Blue (0,0,255)
    /// BR = Yellow (255,255,0)
    ///
    /// Verify each output quadrant has the correct color
    public static func testQuadrantColors() -> (passed: Bool, diagnostic: String) {
        let srcSize = 720  // Square to avoid crop complexity
        let targetSize = 81

        var bgra = [UInt8](repeating: 0, count: srcSize * srcSize * 4)

        for y in 0..<srcSize {
            for x in 0..<srcSize {
                let offset = (y * srcSize + x) * 4

                let r: UInt8
                let g: UInt8
                let b: UInt8

                if x < srcSize / 2 {
                    if y < srcSize / 2 {
                        // TL = Red
                        r = 255; g = 0; b = 0
                    } else {
                        // BL = Blue
                        r = 0; g = 0; b = 255
                    }
                } else {
                    if y < srcSize / 2 {
                        // TR = Green
                        r = 0; g = 255; b = 0
                    } else {
                        // BR = Yellow
                        r = 255; g = 255; b = 0
                    }
                }

                // BGRA order
                bgra[offset + 0] = b
                bgra[offset + 1] = g
                bgra[offset + 2] = r
                bgra[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let testImage = CGImage(
                  width: srcSize,
                  height: srcSize,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: srcSize * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return (false, "V.2 QUADRANT TEST: FAILED - Could not create test CGImage")
        }

        let rgb = FrameFormatConverter.safeCropAndResizeToRGB(testImage, targetSize: targetSize)

        guard rgb.count == targetSize * targetSize * 3 else {
            return (false, "V.2 QUADRANT TEST: FAILED - Output size wrong")
        }

        // Sample center of each output quadrant
        func getPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * targetSize + x) * 3
            return (rgb[offset], rgb[offset + 1], rgb[offset + 2])
        }

        let tlSample = getPixel(x: 20, y: 20)   // Should be Red
        let trSample = getPixel(x: 60, y: 20)   // Should be Green
        let blSample = getPixel(x: 20, y: 60)   // Should be Blue
        let brSample = getPixel(x: 60, y: 60)   // Should be Yellow

        func isRed(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 > 200 && p.1 < 50 && p.2 < 50 }
        func isGreen(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 < 50 && p.1 > 200 && p.2 < 50 }
        func isBlue(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 < 50 && p.1 < 50 && p.2 > 200 }
        func isYellow(_ p: (UInt8, UInt8, UInt8)) -> Bool { p.0 > 200 && p.1 > 200 && p.2 < 50 }

        let tlCorrect = isRed(tlSample)
        let trCorrect = isGreen(trSample)
        let blCorrect = isBlue(blSample)
        let brCorrect = isYellow(brSample)

        let allCorrect = tlCorrect && trCorrect && blCorrect && brCorrect

        // Diagnose what's wrong if test fails
        var diagnosis = ""
        if !allCorrect {
            if isRed(blSample) && isBlue(tlSample) {
                diagnosis = "DIAGNOSIS: Y-axis is FLIPPED (top-bottom swap)"
            } else if isRed(trSample) && isGreen(tlSample) {
                diagnosis = "DIAGNOSIS: X-axis is FLIPPED (left-right swap)"
            } else if isRed(brSample) {
                diagnosis = "DIAGNOSIS: Both axes FLIPPED (180° rotation)"
            } else {
                diagnosis = "DIAGNOSIS: Unknown coordinate mapping error"
            }
        }

        let diagnostic = """
        ═══════════════════════════════════════════════════════════════════════════════
        V.2 QUADRANT COLOR TEST
        ═══════════════════════════════════════════════════════════════════════════════

        Source: \(srcSize)×\(srcSize) (square, no crop needed)
        Pattern: TL=Red, TR=Green, BL=Blue, BR=Yellow

        ┌─────────────┬───────────┬─────────────────────┬─────────┐
        │ Quadrant    │ Expected  │ Actual RGB          │ Correct │
        ├─────────────┼───────────┼─────────────────────┼─────────┤
        │ TL (20,20)  │ RED       │ (\(String(format: "%3d", tlSample.0)),\(String(format: "%3d", tlSample.1)),\(String(format: "%3d", tlSample.2)))           │ \(tlCorrect ? "✓ YES" : "✗ NO")   │
        │ TR (60,20)  │ GREEN     │ (\(String(format: "%3d", trSample.0)),\(String(format: "%3d", trSample.1)),\(String(format: "%3d", trSample.2)))           │ \(trCorrect ? "✓ YES" : "✗ NO")   │
        │ BL (20,60)  │ BLUE      │ (\(String(format: "%3d", blSample.0)),\(String(format: "%3d", blSample.1)),\(String(format: "%3d", blSample.2)))           │ \(blCorrect ? "✓ YES" : "✗ NO")   │
        │ BR (60,60)  │ YELLOW    │ (\(String(format: "%3d", brSample.0)),\(String(format: "%3d", brSample.1)),\(String(format: "%3d", brSample.2)))           │ \(brCorrect ? "✓ YES" : "✗ NO")   │
        └─────────────┴───────────┴─────────────────────┴─────────┘

        \(diagnosis)

        RESULT: \(allCorrect ? "✓ PASS - All quadrants have correct colors" : "✗ FAIL - Quadrant mapping is wrong")
        """

        return (allCorrect, diagnostic)
    }

    // MARK: - Run All Verification Tests

    public static func runAllTests() -> String {
        var output = """
        ╔═══════════════════════════════════════════════════════════════════════════════╗
        ║              CROP/RESIZE VERIFICATION TESTS                                   ║
        ║              Testing FrameFormatConverter.safeCropAndResizeToRGB()           ║
        ╚═══════════════════════════════════════════════════════════════════════════════╝

        """

        let (gradientPassed, gradientDiag) = testGradient()
        output += gradientDiag + "\n\n"

        let (quadrantPassed, quadrantDiag) = testQuadrantColors()
        output += quadrantDiag + "\n\n"

        let summary = gradientPassed && quadrantPassed
            ? "✓ ALL VERIFICATION TESTS PASSED"
            : "✗ SOME VERIFICATION TESTS FAILED"

        output += """
        ═══════════════════════════════════════════════════════════════════════════════
        SUMMARY: \(summary)
        ═══════════════════════════════════════════════════════════════════════════════
        """

        verifyLogger.info("Verification tests complete: gradient=\(gradientPassed), quadrant=\(quadrantPassed)")

        return output
    }
}
