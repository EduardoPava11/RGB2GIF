//
//  PerformanceTelemetry.swift
//  RGB2GIF
//
//  Real-time performance monitoring and telemetry system
//

import Foundation
import Combine
import os.signpost
import os.log
import QuartzCore
import UIKit

@available(iOS 26.0, *)
public final class PerformanceTelemetry: NSObject, ObservableObject {

    // MARK: - Singleton
    public static let shared = PerformanceTelemetry()

    // MARK: - Published Properties
    @Published public var currentFPS: Double = 0
    @Published public var averageFPS: Double = 0
    @Published public var memoryUsageMB: Double = 0
    @Published public var peakMemoryMB: Double = 0
    @Published public var thermalState: ProcessInfo.ThermalState = .nominal
    @Published public var captureProgress: Double = 0
    @Published public var processingProgress: Double = 0
    @Published public var batteryLevel: Double = Double(UIDevice.current.batteryLevel)
    @Published public var batteryState: UIDevice.BatteryState = .unknown

    // MARK: - Private Properties
    private let signposter = OSSignposter()
    private let logger = Logger(subsystem: "com.rgb2gif", category: "Performance")

    private var captureIntervalState: OSSignpostIntervalState?
    private var processingIntervalState: OSSignpostIntervalState?
    private var exportIntervalState: OSSignpostIntervalState?

    private var displayLink: CADisplayLink?

    // THREAD SAFETY: Lock protects mutable arrays accessed from callbacks
    // Even though CADisplayLink runs on main, defensive locking prevents future bugs
    private let telemetryLock = NSLock()

    // PERFORMANCE FIX: Ring buffer for frame timestamps - O(1) add/remove instead of O(n)
    private let maxFrameSamples = 60  // 1 second at 60fps
    private var frameTimestampBuffer: [TimeInterval]
    private var frameTimestampIndex = 0
    private var frameTimestampCount = 0

    // PERFORMANCE FIX: Ring buffer for memory history - O(1) operations
    private let maxMemorySamples = 100
    private var memoryHistoryBuffer: [Double]
    private var memoryHistoryIndex = 0
    private var memoryHistoryCount = 0

    // MARK: - Initialization
    private override init() {
        // Pre-allocate ring buffers with fixed capacity
        self.frameTimestampBuffer = Array(repeating: 0.0, count: maxFrameSamples)
        self.memoryHistoryBuffer = Array(repeating: 0.0, count: maxMemorySamples)
        super.init()
        setupMonitoring()
    }

    // MARK: - Setup
    private func setupMonitoring() {
        // Setup thermal state monitoring
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        // Setup battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = Double(UIDevice.current.batteryLevel)
        batteryState = UIDevice.current.batteryState

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryLevelChanged),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )

        // Setup display link for FPS monitoring
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)

        // Initial thermal state
        thermalState = ProcessInfo.processInfo.thermalState
    }

    // MARK: - Capture Tracking
    public func beginCapture(frameCount: Int) {
        let id = signposter.makeSignpostID()
        captureIntervalState = signposter.beginInterval("Capture", id: id)

        logger.info("📹 Capture started: \(frameCount) frames")
        captureProgress = 0
    }

    public func updateCaptureProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.captureProgress = progress
        }
    }

    public func endCapture(capturedFrames: Int, duration: TimeInterval) {
        if let state = captureIntervalState {
            signposter.endInterval("Capture", state)
            captureIntervalState = nil
        }

        logger.info("📹 Capture completed: \(capturedFrames) frames in \(String(format: "%.2f", duration))s")

        // Calculate capture FPS
        let captureFPS = Double(capturedFrames) / duration
        logger.info("📊 Capture FPS: \(String(format: "%.1f", captureFPS))")
    }

    // MARK: - Processing Tracking
    public func beginProcessing(operation: String) {
        let id = signposter.makeSignpostID()
        processingIntervalState = signposter.beginInterval("Processing", id: id)

        logger.info("⚙️ Processing started: \(operation)")
        processingProgress = 0
    }

    public func updateProcessingProgress(_ progress: Double) {
        DispatchQueue.main.async {
            self.processingProgress = progress
        }
    }

    public func endProcessing(operation: String, duration: TimeInterval) {
        if let state = processingIntervalState {
            signposter.endInterval("Processing", state)
            processingIntervalState = nil
        }

        logger.info("⚙️ Processing completed: \(operation) in \(String(format: "%.2f", duration))s")
    }

    // MARK: - Export Tracking
    public func beginExport(format: String) {
        let id = signposter.makeSignpostID()
        exportIntervalState = signposter.beginInterval("Export", id: id)

        logger.info("💾 Export started: \(format)")
    }

    public func endExport(format: String, duration: TimeInterval, fileSize: Int64) {
        if let state = exportIntervalState {
            signposter.endInterval("Export", state)
            exportIntervalState = nil
        }

        let sizeMB = Double(fileSize) / 1024.0 / 1024.0
        logger.info("💾 Export completed: \(format) in \(String(format: "%.2f", duration))s, size: \(String(format: "%.1f", sizeMB))MB")
    }

    // MARK: - Memory Tracking
    public func updateMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if result == KERN_SUCCESS {
            let memoryMB = Double(info.resident_size) / 1024.0 / 1024.0

            DispatchQueue.main.async {
                self.memoryUsageMB = memoryMB

                // Update peak memory
                if memoryMB > self.peakMemoryMB {
                    self.peakMemoryMB = memoryMB
                }

                // PERFORMANCE FIX: Ring buffer insertion - O(1) instead of O(n)
                self.telemetryLock.lock()
                self.memoryHistoryBuffer[self.memoryHistoryIndex] = memoryMB
                self.memoryHistoryIndex = (self.memoryHistoryIndex + 1) % self.maxMemorySamples
                self.memoryHistoryCount = min(self.memoryHistoryCount + 1, self.maxMemorySamples)
                self.telemetryLock.unlock()
            }
        }
    }

    // MARK: - FPS Tracking
    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        let timestamp = displayLink.timestamp

        // PERFORMANCE FIX: Ring buffer for timestamps - O(1) operations
        telemetryLock.lock()

        // Add timestamp to ring buffer (overwrites oldest when full)
        frameTimestampBuffer[frameTimestampIndex] = timestamp
        frameTimestampIndex = (frameTimestampIndex + 1) % maxFrameSamples
        frameTimestampCount = min(frameTimestampCount + 1, maxFrameSamples)

        // Count recent timestamps within last second for FPS calculation
        let cutoff = timestamp - 1.0
        var recentCount = 0
        for i in 0..<frameTimestampCount {
            if frameTimestampBuffer[i] >= cutoff {
                recentCount += 1
            }
        }

        telemetryLock.unlock()

        // Calculate FPS based on recent frame count
        if recentCount > 1 {
            let fps = Double(recentCount)

            // Already on main thread (CADisplayLink), no dispatch needed
            self.currentFPS = fps
            self.averageFPS = (self.averageFPS * 0.9) + (fps * 0.1)
        }

        // Periodically update memory (every ~0.5 seconds at 60fps)
        if frameTimestampIndex % 30 == 0 {
            updateMemoryUsage()
        }
    }

    // MARK: - Thermal State
    @objc private func thermalStateChanged() {
        DispatchQueue.main.async {
            self.thermalState = ProcessInfo.processInfo.thermalState

            switch self.thermalState {
            case .nominal:
                self.logger.info("🌡️ Thermal state: Nominal")
            case .fair:
                self.logger.info("🌡️ Thermal state: Fair (slight throttling)")
            case .serious:
                self.logger.warning("🌡️ Thermal state: Serious (performance impacted)")
            case .critical:
                self.logger.error("🌡️ Thermal state: Critical (severe throttling)")
            @unknown default:
                break
            }
        }
    }

    // MARK: - Battery Monitoring
    @objc private func batteryLevelChanged() {
        DispatchQueue.main.async {
            self.batteryLevel = Double(UIDevice.current.batteryLevel)
        }
    }

    @objc private func batteryStateChanged() {
        DispatchQueue.main.async {
            self.batteryState = UIDevice.current.batteryState
        }
    }

    // MARK: - Performance Metrics
    public func generatePerformanceReport() -> [String: Any] {
        return [
            "averageFPS": averageFPS,
            "currentFPS": currentFPS,
            "memoryUsageMB": memoryUsageMB,
            "peakMemoryMB": peakMemoryMB,
            "thermalState": thermalStateString,
            "timestamp": Date().timeIntervalSince1970
        ]
    }

    private var thermalStateString: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Public Methods
    public func startMonitoring() {
        // Enable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Start display link if not already running
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
            displayLink?.add(to: .main, forMode: .common)
        }

        logger.info("📊 Performance monitoring started")
    }

    public func stopMonitoring() {
        // Disable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = false

        // Stop display link
        displayLink?.invalidate()
        displayLink = nil

        logger.info("📊 Performance monitoring stopped")
    }

    public func getPerformanceRecommendations() -> [String] {
        var recommendations: [String] = []

        if thermalState == .serious || thermalState == .critical {
            recommendations.append("Device is throttling due to heat. Consider taking a break.")
        }

        if batteryLevel < 0.2 {
            recommendations.append("Low battery may impact performance. Consider charging.")
        }

        if averageFPS < 24 {
            recommendations.append("Frame rate is below optimal. Close other apps to improve performance.")
        }

        if memoryUsageMB > 1024 {
            recommendations.append("High memory usage detected. Consider reducing capture resolution.")
        }

        return recommendations.isEmpty ? ["Performance is optimal"] : recommendations
    }

    public func generateReport() -> String {
        let report = """
        Performance Report
        ==================
        FPS: \(String(format: "%.1f", averageFPS))
        Memory: \(String(format: "%.1f", memoryUsageMB)) MB
        Peak Memory: \(String(format: "%.1f", peakMemoryMB)) MB
        Thermal State: \(thermalStateString)
        Battery: \(String(format: "%.0f", batteryLevel * 100))%
        """
        return report
    }

    // MARK: - Cleanup
    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Objective-C Compatibility
extension PerformanceTelemetry {
    @objc public var objcCurrentFPS: NSNumber {
        return NSNumber(value: currentFPS)
    }

    @objc public var objcMemoryUsageMB: NSNumber {
        return NSNumber(value: memoryUsageMB)
    }
}