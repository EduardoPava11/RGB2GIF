# RGB2GIF Visual Quality Fix Plan

## Executive Summary

**Core Problem**: "The GIF is created but the visual is not correct."

**Root Cause Identified**: The pipeline's `octreeQuantize()` function (lines 623-644 in `CaptureToGIP2Pipeline.swift`) does NOT use actual octree color quantization. It uses a naive frequency-based approach that picks the N most common colors, which produces poor results for:
- Gradients (smooth color transitions become banding)
- Complex scenes (important minority colors are discarded)
- Skin tones and natural images

**Solution**: Replace the fake implementation with the existing `OctreeColorQuantizer` class that implements proper octree-based quantization with optional Floyd-Steinberg dithering.

---

## Priority 1: Core Visual Quality Fix

### Change 1.1: Replace Fake Octree with Real OctreeColorQuantizer

| Attribute | Details |
|-----------|---------|
| **File** | `RGB2GIF/Sources/Camera/CaptureToGIP2Pipeline.swift` |
| **Lines** | 623-644 (remove entire function) |
| **Impact** | CRITICAL - This is the root cause of poor visual quality |
| **Effort** | Medium (requires async integration) |

#### Current Code (PROBLEMATIC):
```swift
// Lines 623-644 - This is NOT octree quantization!
private func octreeQuantize(pixels: [[UInt8]], maxColors: Int) -> [[UInt8]] {
    var colorCounts: [UInt32: Int] = [:]
    for pixel in pixels {
        let packed = packRGB(pixel)
        colorCounts[packed, default: 0] += 1
    }

    // BUG: Just picks most frequent colors, NOT perceptually optimal
    let sorted = colorCounts.sorted { $0.value > $1.value }
    let topColors = sorted.prefix(maxColors)

    var palette: [[UInt8]] = []
    palette.reserveCapacity(maxColors)
    for (packed, _) in topColors {
        palette.append(unpackRGB(packed))
    }

    while palette.count < maxColors {
        palette.append([0, 0, 0])
    }

    return palette
}
```

#### Required Change:
1. Add `OctreeColorQuantizer` instance as property
2. Replace inline `octreeQuantize()` calls with `OctreeColorQuantizer.quantize()`
3. Convert async API to fit pipeline flow

#### New Implementation:
```swift
// Add to class properties (around line 139)
private let octreeQuantizer = OctreeColorQuantizer()

// Replace octreeQuantize calls in quantizeFramesGlobal() (line 468) with:
// Use the real OctreeColorQuantizer for proper octree-based color selection
let quantizationResult = try await octreeQuantizer.quantize(
    compositeImage,  // Need to create composite or process per-frame
    options: .balanced
)
let palette = quantizationResult.palette.map { argb -> [UInt8] in
    return [
        UInt8((argb >> 16) & 0xFF),  // R
        UInt8((argb >> 8) & 0xFF),   // G
        UInt8(argb & 0xFF)           // B
    ]
}
```

#### Files Affected:
- `CaptureToGIP2Pipeline.swift` - Main changes
- No other files need modification for this fix

#### Test Requirements:
```swift
// Add to PropertyTests.swift
func testOctreeQuantizerProducesValidPalette() async throws {
    let quantizer = OctreeColorQuantizer()
    let testImage = createGradientTestImage(width: 80, height: 80)

    let result = try await quantizer.quantize(testImage, options: .balanced)

    XCTAssertEqual(result.palette.count, 256, "Palette must have 256 colors")
    XCTAssertEqual(result.indexedPixels.count, 80 * 80, "Must have one index per pixel")

    // All indices must be valid
    for index in result.indexedPixels {
        XCTAssertLessThan(Int(index), result.palette.count, "Index out of bounds")
    }
}

func testOctreeVsFrequencyQuality() async throws {
    // Create gradient image where frequency-based fails
    let gradient = createGradientTestImage(width: 80, height: 80)
    let quantizer = OctreeColorQuantizer()

    let result = try await quantizer.quantize(gradient, options: .balanced)

    // Verify gradient colors are represented (not just most frequent)
    let uniqueColors = Set(result.palette)
    XCTAssertGreaterThan(uniqueColors.count, 128,
        "Octree should preserve gradient diversity")
}
```

---

### Change 1.2: Enable Dithering Option

| Attribute | Details |
|-----------|---------|
| **File** | `RGB2GIF/Sources/Camera/CaptureToGIP2Pipeline.swift` |
| **Lines** | 71-91 (Options struct) |
| **Impact** | HIGH - Reduces banding artifacts |
| **Effort** | Low |

#### Current Code:
```swift
// Lines 71-91 - No dithering option exposed
struct Options {
    let paletteStrategy: PaletteStrategy
    let colorPipeline: ColorPipeline
    // Missing: dithering option!
}
```

#### Required Change:
```swift
struct Options {
    let paletteStrategy: PaletteStrategy
    let colorPipeline: ColorPipeline
    let enableDithering: Bool  // ADD THIS

    static var `default`: Options {
        Options(
            paletteStrategy: .global,
            colorPipeline: .yuv,
            enableDithering: false  // Conservative default
        )
    }

    static var highQuality: Options {
        Options(
            paletteStrategy: .global,
            colorPipeline: .yuv,
            enableDithering: true  // Enable for quality
        )
    }
}
```

#### Test Requirements:
```swift
func testDitheringReducesBanding() async throws {
    let gradient = createGradientTestImage(width: 80, height: 80)
    let quantizer = OctreeColorQuantizer()

    let noDither = try await quantizer.quantize(gradient, options: .balanced)
    let withDither = try await quantizer.quantize(gradient, options: .quality)

    // Dithered version should have more apparent color variation
    let noDitherTransitions = countColorTransitions(noDither.indexedPixels, width: 80)
    let ditherTransitions = countColorTransitions(withDither.indexedPixels, width: 80)

    XCTAssertGreaterThan(ditherTransitions, noDitherTransitions,
        "Dithering should increase color transitions")
}
```

---

## Priority 2: Pipeline Integration Fixes

### Change 2.1: Fix Async/Sync Mismatch

| Attribute | Details |
|-----------|---------|
| **File** | `RGB2GIF/Sources/Camera/CaptureToGIP2Pipeline.swift` |
| **Lines** | 388-517 (quantizeFramesGlobal) |
| **Impact** | MEDIUM - Required for octree integration |
| **Effort** | Medium |

The `OctreeColorQuantizer.quantize()` is async but `quantizeFramesGlobal()` is sync. Options:

**Option A**: Make pipeline async (preferred)
```swift
private func quantizeFramesGlobal(
    _ frames: [CGImage],
    targetDimension: Int,
    paletteExp: UInt8
) async throws -> GlobalQuantizationOutput {  // Add async
    // ... existing code ...

    // Use actual octree quantization
    let compositePixels = framePixels.flatMap { $0 }
    let compositeImage = try createCompositeImage(from: compositePixels, dimension: targetDimension)
    let quantResult = try await octreeQuantizer.quantize(compositeImage, options: .balanced)

    // Convert to expected format
    let palette = quantResult.palette.map { argb -> [UInt8] in
        [UInt8((argb >> 16) & 0xFF), UInt8((argb >> 8) & 0xFF), UInt8(argb & 0xFF)]
    }
    // ...
}
```

**Option B**: Create sync wrapper (simpler but blocks)
```swift
private func quantizeSynchronously(_ image: CGImage) throws -> OctreeColorQuantizer.QuantizationResult {
    var result: OctreeColorQuantizer.QuantizationResult?
    var error: Error?

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            result = try await octreeQuantizer.quantize(image, options: .balanced)
        } catch let e {
            error = e
        }
        semaphore.signal()
    }
    semaphore.wait()

    if let error = error { throw error }
    return result!
}
```

---

### Change 2.2: Add Composite Image Creation

| Attribute | Details |
|-----------|---------|
| **File** | `RGB2GIF/Sources/Camera/CaptureToGIP2Pipeline.swift` |
| **Lines** | After 644 (new function) |
| **Impact** | MEDIUM - Required for multi-frame palette |
| **Effort** | Low |

```swift
/// Create a composite image from all frame pixels for global palette generation
private func createCompositeImage(
    from frames: [CGImage],
    targetDimension: Int
) throws -> CGImage {
    // Create a tall image with all frames stacked vertically
    let width = targetDimension
    let height = targetDimension * frames.count

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw PipelineError.invalidFrameData
    }

    for (index, frame) in frames.enumerated() {
        let y = index * targetDimension
        context.draw(frame, in: CGRect(x: 0, y: y, width: width, height: targetDimension))
    }

    guard let compositeImage = context.makeImage() else {
        throw PipelineError.invalidFrameData
    }

    return compositeImage
}
```

---

## Priority 3: Quality-of-Life Improvements

### Change 3.1: Expose Quality Presets in UI

| Attribute | Details |
|-----------|---------|
| **File** | UI layer (TBD based on UI architecture) |
| **Impact** | LOW - User experience improvement |
| **Effort** | Low |

Add UI toggle for:
- "Fast" (128 colors, no dithering)
- "Balanced" (256 colors, no dithering) - current default
- "Quality" (256 colors, with dithering)

### Change 3.2: Better Error Logging

| Attribute | Details |
|-----------|---------|
| **File** | `RGB2GIF/Sources/Camera/CaptureToGIP2Pipeline.swift` |
| **Lines** | 161-164 (emitLog function) |
| **Impact** | LOW - Debugging aid |
| **Effort** | Very Low |

Add timing metrics to emitLog for performance profiling:
```swift
private func emitLog(_ message: String, level: OSLogType = .info, timing: TimeInterval? = nil) {
    var fullMessage = message
    if let t = timing {
        fullMessage += String(format: " (%.2fms)", t * 1000)
    }
    pipelineLogger.log(level: level, "\(fullMessage, privacy: .public)")
    NotificationCenter.default.post(name: .capturePipelineLog, object: nil, userInfo: ["message": fullMessage])
}
```

---

## Test Plan

### Unit Tests (PropertyTests.swift)

| Test Name | Purpose | Location |
|-----------|---------|----------|
| `testOctreeQuantizerProducesValidPalette` | Verify 256-color palette generation | New |
| `testOctreeVsFrequencyQuality` | Verify octree preserves gradients | New |
| `testDitheringReducesBanding` | Verify dithering improves quality | New |
| `testPipelineIntegrationWithRealOctree` | End-to-end test | New |
| `testCompositeImageCreation` | Verify multi-frame compositing | New |

### Integration Tests

| Test Name | Purpose | Verification |
|-----------|---------|--------------|
| Gradient GIF Test | Smooth gradients render correctly | Visual inspection |
| Photo GIF Test | Real camera frames look accurate | Visual inspection |
| Dithered vs Non-Dithered | Compare quality settings | Side-by-side comparison |

### Test Helper Functions to Add:

```swift
// Add to PropertyTests.swift

/// Create a horizontal gradient test image
func createGradientTestImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    for y in 0..<height {
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            let r = UInt8(t * 255)
            let g = UInt8((1 - t) * 255)
            let b = UInt8(128)

            let offset = (y * width + x) * 4
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            data[offset] = r
            data[offset + 1] = g
            data[offset + 2] = b
            data[offset + 3] = 255
        }
    }

    return context.makeImage()!
}

/// Count horizontal color transitions (indicator of banding)
func countColorTransitions(_ indices: [UInt8], width: Int) -> Int {
    var transitions = 0
    for row in 0..<(indices.count / width) {
        for col in 1..<width {
            let prev = indices[row * width + col - 1]
            let curr = indices[row * width + col]
            if prev != curr {
                transitions += 1
            }
        }
    }
    return transitions
}
```

---

## Implementation Checklist

### Phase 1: Core Fix (Must Do First)
- [ ] 1.1 Delete fake `octreeQuantize()` function (lines 623-644)
- [ ] 1.2 Add `OctreeColorQuantizer` instance to pipeline
- [ ] 1.3 Replace quantization calls with real octree
- [ ] 1.4 Handle async/sync mismatch
- [ ] 1.5 Add unit tests for octree integration
- [ ] 1.6 Visual verification: test with gradient image

### Phase 2: Integration
- [ ] 2.1 Add composite image creation helper
- [ ] 2.2 Update `quantizeFramesGlobal()` to use real octree
- [ ] 2.3 Update `quantizeSingleFrame()` to use real octree
- [ ] 2.4 Test with 80-frame capture

### Phase 3: Quality Options
- [ ] 3.1 Add dithering option to Options struct
- [ ] 3.2 Wire dithering option through pipeline
- [ ] 3.3 Test dithered vs non-dithered output

### Phase 4: Polish
- [ ] 4.1 Add quality presets to UI (if applicable)
- [ ] 4.2 Add timing metrics to logging
- [ ] 4.3 Update documentation

---

## Summary

| Priority | Change | File | Lines | Impact |
|----------|--------|------|-------|--------|
| P1 | Replace fake octreeQuantize | CaptureToGIP2Pipeline.swift | 623-644 | CRITICAL |
| P1 | Enable dithering option | CaptureToGIP2Pipeline.swift | 71-91 | HIGH |
| P2 | Async/sync integration | CaptureToGIP2Pipeline.swift | 388-517 | MEDIUM |
| P2 | Composite image creation | CaptureToGIP2Pipeline.swift | new | MEDIUM |
| P3 | UI quality presets | UI layer | TBD | LOW |
| P3 | Better logging | CaptureToGIP2Pipeline.swift | 161-164 | LOW |

**Estimated Total Effort**: 2-4 hours for P1+P2, additional 1-2 hours for P3

**Expected Outcome**: GIFs will display correct colors with smooth gradients and accurate representation of the original camera frames.
