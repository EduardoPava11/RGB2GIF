//
//  QUICK_LOGGING_INTEGRATION.swift
//  Example: How to add logging to CaptureToGIP2Pipeline to see where it stalls
//
//  This file shows the exact changes needed to diagnose the runtime stall
//

import Foundation

// MARK: - Example 1: Add logging to CaptureToGIP2Pipeline

/*
 BEFORE (no visibility into what's happening):

 func processCapturedFrames(
     _ frames: [CGImage],
     captureName: String,
     savePaletteToLibrary: Bool
 ) async throws -> CaptureResult {
     let rgbPixels = try extractRGBPixels(from: frames, targetDimension: mode.dimension)
     let paletteSet = try buildPaletteSet(from: rgbPixels, mode: mode, options: options)
     // ... more work ...
 }

 AFTER (with ObservabilityService):
*/

func processCapturedFrames_LOGGED(
    _ frames: [CGImage],
    captureName: String,
    savePaletteToLibrary: Bool
) async throws -> CaptureResult {
    let obs = ObservabilityService.shared
    let overallStart = Date()

    // Log workflow start with metadata
    obs.logStart("GIF Compilation", category: obs.capture, metadata: [
        "frameCount": "\(frames.count)",
        "dimension": "\(mode.dimension)",
        "captureName": captureName
    ])

    // Step 1: Extract RGB pixels (measure timing)
    obs.logStep("Extracting RGB pixels from \(frames.count) frames", category: obs.capture)
    let rgbPixels = try await obs.measure("Extract RGB Pixels", category: obs.capture) {
        try extractRGBPixels(from: frames, targetDimension: mode.dimension)
    }
    obs.notice("✅ Extracted \(rgbPixels.count) RGB frames", category: obs.capture)

    // Step 2: Build palette (THIS IS WHERE IT STALLS - now we'll see timing)
    obs.logStep("Building color palette", category: obs.quantization)
    let paletteStart = Date()
    let paletteSet = try await obs.measure("Build Palette Set", category: obs.quantization) {
        try buildPaletteSet(from: rgbPixels, mode: mode, options: options)
    }
    let paletteDuration = Date().timeIntervalSince(paletteStart)
    obs.notice("✅ Built palette: \(paletteSet.palettes.count) palettes in \(String(format: "%.2f", paletteDuration))s",
               category: obs.quantization)

    // If palette took >10 seconds, log warning
    if paletteDuration > 10.0 {
        obs.warning("⚠️ Palette generation took \(paletteDuration)s - consider optimization",
                    category: obs.quantization)
    }

    // Step 3: Create GIP
    obs.logStep("Creating GIP container", category: obs.muxer)
    let gip = try obs.measure("Create GIP", category: obs.muxer) {
        try createGIP(paletteSet: paletteSet, name: captureName)
    }

    // Step 4: Create GIX with LZW compression
    obs.logStep("Creating GIX with LZW compression", category: obs.compression)
    let gix = try await obs.measure("Create GIX + LZW", category: obs.compression) {
        try createGIX(/* ... */)
    }

    // Step 5: Validate
    obs.logStep("Validating GIP+GIX compatibility", category: obs.muxer)
    let validation = obs.measure("Validate Components", category: obs.muxer) {
        GIPGIXComponentValidator.validateComponents(gip: gip, gix: gix)
    }

    if !validation.isValid {
        obs.error("❌ Component validation failed: \(validation.summary)",
                  category: obs.muxer)
        throw PipelineError.validationFailed(validation.summary)
    }
    obs.notice("✅ Validation passed", category: obs.muxer)

    // Step 6: Mux to GIF
    obs.logStep("Muxing GIP+GIX to GIF89a", category: obs.muxer)
    try obs.measure("Mux to GIF", category: obs.muxer) {
        try GIF89aMuxer.mux(gip: gip, gix: gix, to: gifURL, loopForever: true)
    }

    let totalDuration = Date().timeIntervalSince(overallStart)
    obs.logComplete("GIF Compilation", category: obs.capture, duration: totalDuration)

    // Log performance summary
    obs.notice("📊 Performance Summary: Total=\(String(format: "%.2f", totalDuration))s, Palette=\(String(format: "%.2f", paletteDuration))s",
               category: obs.capture)

    return CaptureResult(/* ... */)
}

// MARK: - Example 2: Add detailed logging to OctreeColorQuantizer

/*
 This shows where the actual bottleneck is within quantization
*/

func quantize_LOGGED(_ image: CGImage, options: QuantizationOptions) async throws -> QuantizationResult {
    let obs = ObservabilityService.shared

    obs.debug("🎨 Starting quantization: \(image.width)×\(image.height), maxColors=\(options.maxColors)",
              category: obs.quantization)

    return try await Task.detached(priority: .userInitiated) { [self] in
        let overallStart = CACurrentMediaTime()

        // Step 1: Build octree (USUALLY THE SLOWEST PART)
        obs.debug("Building octree from pixel data...", category: obs.quantization)
        let buildStart = CACurrentMediaTime()
        self.reset()
        try self.buildOctree(from: image)
        let buildDuration = CACurrentMediaTime() - buildStart
        obs.debug("✅ Octree built in \(String(format: "%.2f", buildDuration * 1000))ms", category: obs.quantization)

        // Step 2: Reduce palette
        obs.debug("Reducing palette to \(options.maxColors) colors...", category: obs.quantization)
        let reduceStart = CACurrentMediaTime()
        self.reducePalette(to: options.maxColors)
        let reduceDuration = CACurrentMediaTime() - reduceStart
        obs.debug("✅ Palette reduced in \(String(format: "%.2f", reduceDuration * 1000))ms", category: obs.quantization)

        // Step 3: Generate palette
        obs.debug("Generating final palette...", category: obs.quantization)
        let genStart = CACurrentMediaTime()
        let palette = self.generatePalette(maxColors: options.maxColors)
        let genDuration = CACurrentMediaTime() - genStart
        obs.debug("✅ Palette generated: \(palette.count) colors in \(String(format: "%.2f", genDuration * 1000))ms",
                  category: obs.quantization)

        // Step 4: Map pixels (SECOND SLOWEST PART)
        obs.debug("Mapping \(image.width * image.height) pixels to palette...", category: obs.quantization)
        let mapStart = CACurrentMediaTime()
        let indexedPixels = try self.mapPixelsToPalette(image, palette: palette)
        let mapDuration = CACurrentMediaTime() - mapStart
        obs.debug("✅ Pixels mapped in \(String(format: "%.2f", mapDuration * 1000))ms", category: obs.quantization)

        // Step 5: Dithering (if enabled)
        let finalIndexedPixels: [UInt8]
        if options.dithering {
            obs.debug("Applying Floyd-Steinberg dithering...", category: obs.quantization)
            let ditherStart = CACurrentMediaTime()
            finalIndexedPixels = try self.applyDithering(
                indexedPixels,
                width: image.width,
                height: image.height,
                palette: palette
            )
            let ditherDuration = CACurrentMediaTime() - ditherStart
            obs.debug("✅ Dithering applied in \(String(format: "%.2f", ditherDuration * 1000))ms",
                      category: obs.quantization)
        } else {
            finalIndexedPixels = indexedPixels
        }

        // Step 6: Create quantized image
        obs.debug("Creating quantized CGImage...", category: obs.quantization)
        let createStart = CACurrentMediaTime()
        let quantizedImage = try self.createQuantizedImage(
            indexedPixels: finalIndexedPixels,
            palette: palette,
            width: image.width,
            height: image.height
        )
        let createDuration = CACurrentMediaTime() - createStart
        obs.debug("✅ Image created in \(String(format: "%.2f", createDuration * 1000))ms", category: obs.quantization)

        let totalDuration = CACurrentMediaTime() - overallStart

        // Log summary with breakdown
        obs.notice("""
        🎨 Quantization complete:
           Total: \(String(format: "%.2f", totalDuration * 1000))ms
           Build octree: \(String(format: "%.2f", buildDuration * 1000))ms (\(Int(buildDuration / totalDuration * 100))%)
           Reduce palette: \(String(format: "%.2f", reduceDuration * 1000))ms (\(Int(reduceDuration / totalDuration * 100))%)
           Map pixels: \(String(format: "%.2f", mapDuration * 1000))ms (\(Int(mapDuration / totalDuration * 100))%)
        """, category: obs.quantization)

        return QuantizationResult(/* ... */)
    }.value
}

// MARK: - Example 3: Viewing Logs in Real-Time

/*
 To see these logs in real-time, use Console.app:

 1. Open Console.app (macOS)
 2. Connect your iPhone or select simulator
 3. In the search filter, enter:
    subsystem:com.rgb2gif2voxel

 4. You'll see output like:

 12:30:45.123 [NOTICE] [Capture] ▶️ Starting: GIF Compilation [frameCount=80, dimension=128]
 12:30:45.124 [NOTICE] [Capture] 📋 Step: Extracting RGB pixels from 80 frames
 12:30:45.345 [NOTICE] [Capture] ✅ Extracted 80 RGB frames
 12:30:45.346 [NOTICE] [Quantization] 📋 Step: Building color palette
 12:30:45.347 [DEBUG] [Quantization] 🎨 Starting quantization: 128×128, maxColors=256
 12:30:45.348 [DEBUG] [Quantization] Building octree from pixel data...
 12:30:45.593 [DEBUG] [Quantization] ✅ Octree built in 245.00ms
 12:30:45.594 [DEBUG] [Quantization] Reducing palette to 256 colors...
 12:30:45.647 [DEBUG] [Quantization] ✅ Palette reduced in 53.00ms
 ...
 12:30:46.103 [NOTICE] [Capture] ✅ Completed: GIF Compilation [duration_ms=980.00]

 Now you can SEE EXACTLY where it's slow!
*/

// MARK: - Example 4: Quick Diagnostic Function

/*
 Add this to your app to quickly diagnose performance issues
*/

extension CaptureToGIP2Pipeline {

    /// Diagnostic function to measure each step of the pipeline
    func diagnosePerformance(frames: [CGImage]) async {
        let obs = ObservabilityService.shared

        obs.notice("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: obs.capture)
        obs.notice("🔍 PERFORMANCE DIAGNOSTIC", category: obs.capture)
        obs.notice("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: obs.capture)

        // Measure RGB extraction
        let rgbStart = Date()
        _ = try? extractRGBPixels(from: frames, targetDimension: 128)
        let rgbDuration = Date().timeIntervalSince(rgbStart)
        obs.notice("1️⃣ RGB Extraction: \(String(format: "%.2f", rgbDuration))s", category: obs.capture)

        // Measure single frame quantization
        if let firstFrame = frames.first {
            let quantStart = Date()
            let quantizer = OctreeColorQuantizer()
            _ = try? await quantizer.quantize(firstFrame, options: .balanced)
            let quantDuration = Date().timeIntervalSince(quantStart)
            obs.notice("2️⃣ Single Frame Quantization: \(String(format: "%.2f", quantDuration))s", category: obs.quantization)

            // Estimate total for all frames
            let estimatedTotal = quantDuration * Double(frames.count)
            obs.notice("   Estimated for \(frames.count) frames: \(String(format: "%.2f", estimatedTotal))s",
                       category: obs.quantization)

            if estimatedTotal > 30.0 {
                obs.warning("⚠️ BOTTLENECK DETECTED: Quantization will take >\(Int(estimatedTotal))s",
                            category: obs.quantization)
                obs.warning("   Recommendation: Integrate Accelerate framework (10-50x speedup)",
                            category: obs.quantization)
            }
        }

        obs.notice("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", category: obs.capture)
    }
}

// MARK: - Example 5: Usage in Your App

/*
 In your view controller or SwiftUI view:

 Button("Capture GIF") {
     Task {
         let obs = ObservabilityService.shared

         // Optional: Run diagnostic first
         // await pipeline.diagnosePerformance(frames: capturedFrames)

         do {
             let result = try await pipeline.processCapturedFrames(
                 capturedFrames,
                 captureName: "test",
                 savePaletteToLibrary: false
             )

             obs.notice("✅ GIF created: \(result.gifURL)", category: obs.capture)

         } catch {
             obs.error("❌ GIF creation failed", category: obs.capture, error: error)
         }
     }
 }

 Now when you tap the button, you'll see live logs showing:
 - Which step is running
 - How long each step takes
 - Where it gets stuck (if anywhere)
*/
