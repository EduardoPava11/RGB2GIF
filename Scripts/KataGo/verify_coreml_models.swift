#!/usr/bin/env swift
//
//  verify_coreml_models.swift
//  RGB2GIF
//
//  ============================================================================
//  COREML MODEL VERIFICATION SCRIPT
//  ============================================================================
//
//  PURPOSE
//  ───────
//  This script verifies that the dual KataGo CoreML models are correctly
//  installed and can perform inference. Run this after running:
//    1. download_katago_9x9.sh
//    2. convert_to_dual_coreml.py
//
//  USAGE
//  ─────
//  From the Scripts/KataGo directory:
//    swift verify_coreml_models.swift
//
//  Or make executable and run:
//    chmod +x verify_coreml_models.swift
//    ./verify_coreml_models.swift
//
//  EXPECTED OUTPUT
//  ───────────────
//  ✓ Found KataGo9x9_Spatial.mlpackage
//  ✓ Found KataGo9x9_Temporal.mlpackage
//  ✓ Spatial model loaded successfully
//  ✓ Temporal model loaded successfully
//  ✓ Spatial inference: 82 policy logits, 3 value logits
//  ✓ Temporal inference: 82 policy logits, 3 value logits
//  ✓ All tests passed!
//
//  ============================================================================

import Foundation
import CoreML

// MARK: - Configuration

let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent()
let modelsDir = projectRoot.appendingPathComponent("RGB2GIF/Resources/Models")

let spatialModelName = "KataGo9x9_Spatial"
let temporalModelName = "KataGo9x9_Temporal"

// MARK: - Test Runner

func main() async {
    print("")
    print("╔═══════════════════════════════════════════════════════════════════╗")
    print("║     RGB2GIF KataGo CoreML Model Verification                      ║")
    print("╚═══════════════════════════════════════════════════════════════════╝")
    print("")

    var allPassed = true

    // Check if models exist
    print("Checking for model files...")
    print("  Models directory: \(modelsDir.path)")
    print("")

    let spatialPath = modelsDir.appendingPathComponent("\(spatialModelName).mlpackage")
    let temporalPath = modelsDir.appendingPathComponent("\(temporalModelName).mlpackage")

    if FileManager.default.fileExists(atPath: spatialPath.path) {
        print("  ✓ Found \(spatialModelName).mlpackage")
    } else {
        print("  ✗ Missing \(spatialModelName).mlpackage")
        print("    Expected at: \(spatialPath.path)")
        allPassed = false
    }

    if FileManager.default.fileExists(atPath: temporalPath.path) {
        print("  ✓ Found \(temporalModelName).mlpackage")
    } else {
        print("  ✗ Missing \(temporalModelName).mlpackage")
        print("    Expected at: \(temporalPath.path)")
        allPassed = false
    }

    guard allPassed else {
        print("")
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  ✗ VERIFICATION FAILED: Models not found                          ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Please run the following scripts first:                          ║")
        print("║    1. ./download_katago_9x9.sh                                    ║")
        print("║    2. python3 convert_to_dual_coreml.py                           ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
        exit(1)
    }

    print("")
    print("Loading models...")

    // Load Spatial model
    do {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let compiledURL = try await compileModel(at: spatialPath)
        let _ = try MLModel(contentsOf: compiledURL, configuration: config)
        print("  ✓ Spatial model loaded successfully")
    } catch {
        print("  ✗ Spatial model failed to load: \(error)")
        allPassed = false
    }

    // Load Temporal model
    do {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let compiledURL = try await compileModel(at: temporalPath)
        let _ = try MLModel(contentsOf: compiledURL, configuration: config)
        print("  ✓ Temporal model loaded successfully")
    } catch {
        print("  ✗ Temporal model failed to load: \(error)")
        allPassed = false
    }

    guard allPassed else {
        print("")
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  ✗ VERIFICATION FAILED: Models could not be loaded                ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
        exit(1)
    }

    print("")
    print("Running test inference...")

    // Test inference
    do {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let spatialCompiled = try await compileModel(at: spatialPath)
        let spatialModel = try MLModel(contentsOf: spatialCompiled, configuration: config)

        let temporalCompiled = try await compileModel(at: temporalPath)
        let temporalModel = try MLModel(contentsOf: temporalCompiled, configuration: config)

        // Create sample inputs
        let spatial = try createSampleSpatialInput()
        let global = try createSampleGlobalInput()

        // Run spatial inference
        let spatialInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_spatial": MLFeatureValue(multiArray: spatial),
            "input_global": MLFeatureValue(multiArray: global)
        ])

        let spatialOutput = try spatialModel.prediction(from: spatialInput)

        if let policy = spatialOutput.featureValue(for: "policy")?.multiArrayValue,
           let value = spatialOutput.featureValue(for: "value")?.multiArrayValue {
            print("  ✓ Spatial inference: \(policy.count) policy logits, \(value.count) value logits")
        } else {
            print("  ✗ Spatial inference: unexpected output format")
            allPassed = false
        }

        // Run temporal inference
        let temporalInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_spatial": MLFeatureValue(multiArray: spatial),
            "input_global": MLFeatureValue(multiArray: global)
        ])

        let temporalOutput = try temporalModel.prediction(from: temporalInput)

        if let policy = temporalOutput.featureValue(for: "policy")?.multiArrayValue,
           let value = temporalOutput.featureValue(for: "value")?.multiArrayValue {
            print("  ✓ Temporal inference: \(policy.count) policy logits, \(value.count) value logits")
        } else {
            print("  ✗ Temporal inference: unexpected output format")
            allPassed = false
        }

    } catch {
        print("  ✗ Inference failed: \(error)")
        allPassed = false
    }

    print("")

    if allPassed {
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  ✓ ALL TESTS PASSED                                               ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Both KataGo CoreML models are working correctly.                 ║")
        print("║  You can now use them in RGB2GIF for Q-K-V attention.             ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
        exit(0)
    } else {
        print("╔═══════════════════════════════════════════════════════════════════╗")
        print("║  ✗ SOME TESTS FAILED                                              ║")
        print("╠═══════════════════════════════════════════════════════════════════╣")
        print("║  Check the error messages above for details.                      ║")
        print("╚═══════════════════════════════════════════════════════════════════╝")
        exit(1)
    }
}

// MARK: - Helper Functions

func compileModel(at url: URL) async throws -> URL {
    // Check if already compiled
    let compiledName = url.deletingPathExtension().lastPathComponent + ".mlmodelc"
    let compiledURL = url.deletingLastPathComponent().appendingPathComponent(compiledName)

    if FileManager.default.fileExists(atPath: compiledURL.path) {
        return compiledURL
    }

    // Compile the model
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let compiled = try MLModel.compileModel(at: url)
                continuation.resume(returning: compiled)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

func createSampleSpatialInput() throws -> MLMultiArray {
    // Shape: (1, 22, 9, 9)
    let spatial = try MLMultiArray(shape: [1, 22, 9, 9], dataType: .float32)

    // Initialize with zeros
    for i in 0..<spatial.count {
        spatial[i] = 0
    }

    // Set mask plane (plane 0) to all 1s
    for y in 0..<9 {
        for x in 0..<9 {
            spatial[[0, 0, y, x] as [NSNumber]] = 1.0
        }
    }

    // Set a simple pattern for testing
    // Place some "stones" to simulate a board position
    spatial[[0, 1, 4, 4] as [NSNumber]] = 1.0  // Own stone at center
    spatial[[0, 2, 3, 3] as [NSNumber]] = 1.0  // Opponent stone

    return spatial
}

func createSampleGlobalInput() throws -> MLMultiArray {
    // Shape: (1, 19)
    let global = try MLMultiArray(shape: [1, 19], dataType: .float32)

    // Initialize with zeros
    for i in 0..<global.count {
        global[i] = 0
    }

    // Set komi (normalized)
    global[[0, 0] as [NSNumber]] = NSNumber(value: 7.0 / 14.0)

    return global
}

// MARK: - Entry Point

// Run the async main function
Task {
    await main()
}

// Keep the script running for async tasks
RunLoop.main.run()
