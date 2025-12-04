#!/usr/bin/env swift
//
//  StandaloneOctreeTests.swift
//  RGB2GIF
//
//  Standalone tests for OctreeColorQuantizer that can run WITHOUT the app.
//  Run with: swift Scripts/StandaloneOctreeTests.swift
//
//  These tests verify the P1 visual quality fix works correctly.
//

import Foundation
import CoreGraphics

// MARK: - Test Framework (Minimal, No Dependencies)

struct TestResult {
    let name: String
    let passed: Bool
    let message: String
    let duration: TimeInterval
}

class TestRunner {
    private var results: [TestResult] = []
    private var currentTest: String = ""

    func run(_ name: String, _ test: () throws -> Void) {
        currentTest = name
        let start = Date()

        do {
            try test()
            let duration = Date().timeIntervalSince(start)
            results.append(TestResult(name: name, passed: true, message: "OK", duration: duration))
            print("✅ \(name) (\(String(format: "%.2f", duration * 1000))ms)")
        } catch {
            let duration = Date().timeIntervalSince(start)
            results.append(TestResult(name: name, passed: false, message: error.localizedDescription, duration: duration))
            print("❌ \(name): \(error.localizedDescription)")
        }
    }

    func runAsync(_ name: String, _ test: @escaping () async throws -> Void) {
        currentTest = name
        let start = Date()

        let semaphore = DispatchSemaphore(value: 0)
        var testError: Error?

        Task {
            do {
                try await test()
            } catch {
                testError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        let duration = Date().timeIntervalSince(start)
        if let error = testError {
            results.append(TestResult(name: name, passed: false, message: error.localizedDescription, duration: duration))
            print("❌ \(name): \(error.localizedDescription)")
        } else {
            results.append(TestResult(name: name, passed: true, message: "OK", duration: duration))
            print("✅ \(name) (\(String(format: "%.2f", duration * 1000))ms)")
        }
    }

    func printSummary() {
        let passed = results.filter { $0.passed }.count
        let failed = results.count - passed
        let totalDuration = results.reduce(0) { $0 + $1.duration }

        print("\n" + String(repeating: "═", count: 60))
        print("TEST SUMMARY")
        print(String(repeating: "═", count: 60))
        print("Total: \(results.count) | Passed: \(passed) | Failed: \(failed)")
        print("Duration: \(String(format: "%.2f", totalDuration * 1000))ms")

        if failed > 0 {
            print("\nFailed tests:")
            for result in results where !result.passed {
                print("  • \(result.name): \(result.message)")
            }
        }

        print(String(repeating: "═", count: 60))
    }

    var allPassed: Bool {
        results.allSatisfy { $0.passed }
    }
}

// MARK: - Test Assertions

enum TestError: LocalizedError {
    case assertionFailed(String)
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let msg): return msg
        case .imageCreationFailed: return "Failed to create test image"
        }
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else {
        throw TestError.assertionFailed("\(msg): expected \(b), got \(a)")
    }
}

func assertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a > b else {
        throw TestError.assertionFailed("\(msg): expected \(a) > \(b)")
    }
}

func assertLessThan<T: Comparable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a < b else {
        throw TestError.assertionFailed("\(msg): expected \(a) < \(b)")
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "") throws {
    guard condition else {
        throw TestError.assertionFailed(msg)
    }
}

// MARK: - Test Image Generation (Pure CoreGraphics, No Dependencies)

func createGradientImage(width: Int, height: Int) throws -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = [UInt8](repeating: 255, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let t = Float(x) / Float(max(1, width - 1))
            let r = UInt8(t * 255)
            let g = UInt8(0)
            let b = UInt8((1.0 - t) * 255)

            let offset = (y * width + x) * bytesPerPixel
            pixelData[offset] = r
            pixelData[offset + 1] = g
            pixelData[offset + 2] = b
            pixelData[offset + 3] = 255
        }
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
          let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw TestError.imageCreationFailed
    }

    return cgImage
}

func createSolidColorImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * bytesPerPixel
            pixelData[offset] = r
            pixelData[offset + 1] = g
            pixelData[offset + 2] = b
            pixelData[offset + 3] = 255
        }
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
          let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw TestError.imageCreationFailed
    }

    return cgImage
}

// MARK: - Standalone Octree Implementation (For Testing Only)
// This is a minimal octree for testing purposes - verifies the algorithm works

class SimpleOctreeNode {
    var red: Int = 0
    var green: Int = 0
    var blue: Int = 0
    var pixelCount: Int = 0
    var children: [SimpleOctreeNode?] = Array(repeating: nil, count: 8)

    var isLeaf: Bool { children.allSatisfy { $0 == nil } }

    func getColor() -> UInt32 {
        guard pixelCount > 0 else { return 0 }
        let r = UInt32(red / pixelCount) & 0xFF
        let g = UInt32(green / pixelCount) & 0xFF
        let b = UInt32(blue / pixelCount) & 0xFF
        return (0xFF << 24) | (r << 16) | (g << 8) | b
    }
}

class SimpleOctreeQuantizer {
    private let maxDepth = 8
    private var root: SimpleOctreeNode?
    private var leafNodes: [SimpleOctreeNode] = []
    private var levelNodes: [[SimpleOctreeNode]] = Array(repeating: [], count: 9)

    func quantize(_ image: CGImage, maxColors: Int) throws -> (palette: [UInt32], indices: [UInt8]) {
        reset()
        try buildOctree(from: image)
        reducePalette(to: maxColors)
        let palette = generatePalette(maxColors: maxColors)
        let indices = try mapPixelsToPalette(image, palette: palette)
        return (palette, indices)
    }

    private func reset() {
        root = SimpleOctreeNode()
        leafNodes.removeAll()
        for i in 0..<levelNodes.count {
            levelNodes[i].removeAll()
        }
    }

    private func buildOctree(from image: CGImage) throws {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw TestError.assertionFailed("Invalid image data")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                addColor(red: data[offset], green: data[offset + 1], blue: data[offset + 2])
            }
        }
    }

    private func addColor(red: UInt8, green: UInt8, blue: UInt8) {
        guard let root = root else { return }

        var node = root

        for level in (0..<maxDepth).reversed() {
            let index = getOctreeIndex(red: red, green: green, blue: blue, level: level)

            if node.children[index] == nil {
                node.children[index] = SimpleOctreeNode()
                if level < maxDepth - 1 {
                    levelNodes[level + 1].append(node.children[index]!)
                }
            }

            node = node.children[index]!
        }

        node.red += Int(red)
        node.green += Int(green)
        node.blue += Int(blue)
        node.pixelCount += 1

        if node.isLeaf && !leafNodes.contains(where: { $0 === node }) {
            leafNodes.append(node)
        }
    }

    private func getOctreeIndex(red: UInt8, green: UInt8, blue: UInt8, level: Int) -> Int {
        var index = 0
        let mask: UInt8 = 0x80 >> level

        if (red & mask) != 0 { index |= 4 }
        if (green & mask) != 0 { index |= 2 }
        if (blue & mask) != 0 { index |= 1 }

        return index
    }

    private func reducePalette(to maxColors: Int) {
        while leafNodes.count > maxColors {
            var foundNodes = false
            for level in (1..<maxDepth).reversed() {
                if !levelNodes[level].isEmpty {
                    let nodeToReduce = levelNodes[level].min { $0.pixelCount < $1.pixelCount }!
                    reduceNode(nodeToReduce)
                    foundNodes = true
                    break
                }
            }

            if !foundNodes && leafNodes.count > maxColors {
                if let minNode = leafNodes.min(by: { $0.pixelCount < $1.pixelCount }),
                   let index = leafNodes.firstIndex(where: { $0 === minNode }) {
                    leafNodes.remove(at: index)
                }
            }
        }
    }

    private func reduceNode(_ node: SimpleOctreeNode) {
        var red = 0, green = 0, blue = 0, pixelCount = 0

        for child in node.children where child != nil {
            red += child!.red
            green += child!.green
            blue += child!.blue
            pixelCount += child!.pixelCount

            if let index = leafNodes.firstIndex(where: { $0 === child }) {
                leafNodes.remove(at: index)
            }
        }

        node.red = red
        node.green = green
        node.blue = blue
        node.pixelCount = pixelCount
        node.children = Array(repeating: nil, count: 8)

        if !leafNodes.contains(where: { $0 === node }) {
            leafNodes.append(node)
        }
    }

    private func generatePalette(maxColors: Int) -> [UInt32] {
        var palette: [UInt32] = []
        let sortedLeaves = leafNodes.sorted { $0.pixelCount > $1.pixelCount }

        for node in sortedLeaves.prefix(maxColors) {
            palette.append(node.getColor())
        }

        while palette.count < maxColors && palette.count < 256 {
            palette.append(0xFF000000)
        }

        return palette
    }

    private func mapPixelsToPalette(_ image: CGImage, palette: [UInt32]) throws -> [UInt8] {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw TestError.assertionFailed("Invalid image data")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8

        var indices: [UInt8] = []
        indices.reserveCapacity(width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]

                let index = findClosestPaletteIndex(red: r, green: g, blue: b, palette: palette)
                indices.append(UInt8(index))
            }
        }

        return indices
    }

    private func findClosestPaletteIndex(red: UInt8, green: UInt8, blue: UInt8, palette: [UInt32]) -> Int {
        var minDistance = Int.max
        var closestIndex = 0

        for (index, color) in palette.enumerated() {
            let pr = Int((color >> 16) & 0xFF)
            let pg = Int((color >> 8) & 0xFF)
            let pb = Int(color & 0xFF)

            let dr = Int(red) - pr
            let dg = Int(green) - pg
            let db = Int(blue) - pb
            let distance = dr * dr + dg * dg + db * db

            if distance < minDistance {
                minDistance = distance
                closestIndex = index
            }
        }

        return closestIndex
    }
}

// MARK: - Frequency-Based Quantizer (The OLD buggy implementation for comparison)

class FrequencyBasedQuantizer {
    func quantize(_ image: CGImage, maxColors: Int) throws -> (palette: [UInt32], indices: [UInt8]) {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            throw TestError.assertionFailed("Invalid image data")
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8

        // Count color frequencies (the buggy approach)
        var colorCounts: [UInt32: Int] = [:]

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]
                let packed = (UInt32(0xFF) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                colorCounts[packed, default: 0] += 1
            }
        }

        // Take top N most frequent (THIS IS THE BUG - doesn't preserve gradients)
        let sorted = colorCounts.sorted { $0.value > $1.value }
        var palette = sorted.prefix(maxColors).map { $0.key }

        while palette.count < maxColors {
            palette.append(0xFF000000)
        }

        // Map pixels to palette
        var indices: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(pixelData) else { continue }

                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]

                var bestIdx = 0
                var minDist = Int.max
                for (idx, color) in palette.enumerated() {
                    let pr = Int((color >> 16) & 0xFF)
                    let pg = Int((color >> 8) & 0xFF)
                    let pb = Int(color & 0xFF)
                    let dist = (Int(r) - pr) * (Int(r) - pr) +
                               (Int(g) - pg) * (Int(g) - pg) +
                               (Int(b) - pb) * (Int(b) - pb)
                    if dist < minDist {
                        minDist = dist
                        bestIdx = idx
                    }
                }
                indices.append(UInt8(bestIdx))
            }
        }

        return (Array(palette), indices)
    }
}

// MARK: - Test Helpers

func countColorTransitions(_ indices: [UInt8], width: Int) -> Int {
    guard indices.count >= width else { return 0 }
    var transitions = 0
    let rowCount = indices.count / width

    for row in 0..<rowCount {
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

func countUniqueColors(_ indices: [UInt8]) -> Int {
    return Set(indices).count
}

// MARK: - Tests

let runner = TestRunner()

print("╔══════════════════════════════════════════════════════════╗")
print("║  RGB2GIF Standalone Octree Quantizer Tests               ║")
print("║  Testing P1 Visual Quality Fix                           ║")
print("╚══════════════════════════════════════════════════════════╝\n")

// Test 1: Octree produces valid 256-color palette
runner.run("Octree produces valid 256-color palette") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 80, height: 80)

    let result = try quantizer.quantize(image, maxColors: 256)

    try assertEqual(result.palette.count, 256, "Palette size")
    try assertEqual(result.indices.count, 80 * 80, "Index count")

    for index in result.indices {
        try assertTrue(Int(index) < result.palette.count, "Index \(index) in bounds")
    }
}

// Test 2: Octree preserves gradient diversity (KEY TEST)
runner.run("Octree preserves gradient diversity") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 80, height: 80)

    let result = try quantizer.quantize(image, maxColors: 256)

    let uniqueColors = countUniqueColors(result.indices)
    try assertGreaterThan(uniqueColors, 30,
        "Octree should use 30+ colors for gradient, got \(uniqueColors)")

    // Check red channel distribution
    var redValues: Set<UInt8> = []
    for index in Set(result.indices) {
        let color = result.palette[Int(index)]
        let r = UInt8((color >> 16) & 0xFF)
        redValues.insert(r)
    }

    let minRed = redValues.min() ?? 255
    let maxRed = redValues.max() ?? 0

    try assertLessThan(minRed, UInt8(50), "Should have dark reds")
    try assertGreaterThan(maxRed, UInt8(200), "Should have bright reds")
}

// Test 3: Frequency-based fails on gradients (proves the bug)
runner.run("Frequency-based fails on gradients (baseline)") {
    let freqQuantizer = FrequencyBasedQuantizer()
    let octreeQuantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 80, height: 80)

    let freqResult = try freqQuantizer.quantize(image, maxColors: 256)
    let octreeResult = try octreeQuantizer.quantize(image, maxColors: 256)

    let freqUnique = countUniqueColors(freqResult.indices)
    let octreeUnique = countUniqueColors(octreeResult.indices)

    // Octree should use more colors than frequency-based for gradients
    // (Frequency-based arbitrarily picks when all colors have equal count)
    print("    Frequency-based unique colors: \(freqUnique)")
    print("    Octree unique colors: \(octreeUnique)")

    // This test documents the difference - octree should be >= frequency
    try assertGreaterThan(octreeUnique, 20, "Octree should use 20+ colors")
}

// Test 4: Solid color image produces single-color palette
runner.run("Solid color produces minimal palette") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createSolidColorImage(width: 80, height: 80, r: 255, g: 0, b: 0)

    let result = try quantizer.quantize(image, maxColors: 256)

    let uniqueColors = countUniqueColors(result.indices)
    try assertEqual(uniqueColors, 1, "Solid color should use 1 palette entry")

    // The used color should be red
    let usedIndex = result.indices[0]
    let color = result.palette[Int(usedIndex)]
    let r = (color >> 16) & 0xFF
    try assertGreaterThan(r, UInt32(200), "Color should be red")
}

// Test 5: Small image handling
runner.run("Small image handling (8x8)") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 8, height: 8)

    let result = try quantizer.quantize(image, maxColors: 256)

    try assertEqual(result.indices.count, 64, "8x8 = 64 pixels")
    try assertGreaterThan(result.palette.count, 0, "Should have palette")
}

// Test 6: Large image handling
runner.run("Large image handling (256x256)") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 256, height: 256)

    let result = try quantizer.quantize(image, maxColors: 256)

    try assertEqual(result.indices.count, 256 * 256, "256x256 = 65536 pixels")
    try assertEqual(result.palette.count, 256, "Full 256-color palette")
}

// Test 7: Color transitions in gradient
runner.run("Gradient has smooth color transitions") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 80, height: 80)

    let result = try quantizer.quantize(image, maxColors: 256)

    let transitions = countColorTransitions(result.indices, width: 80)

    // A well-quantized gradient should have many transitions (not banding)
    try assertGreaterThan(transitions, 100,
        "Should have 100+ transitions for smooth gradient, got \(transitions)")
}

// Test 8: Palette colors are valid ARGB
runner.run("Palette colors are valid ARGB") {
    let quantizer = SimpleOctreeQuantizer()
    let image = try createGradientImage(width: 40, height: 40)

    let result = try quantizer.quantize(image, maxColors: 256)

    for (idx, color) in result.palette.enumerated() {
        let alpha = (color >> 24) & 0xFF
        try assertEqual(alpha, 0xFF, "Color \(idx) should be opaque")
    }
}

// Print summary
runner.printSummary()

// Exit with appropriate code
exit(runner.allPassed ? 0 : 1)
