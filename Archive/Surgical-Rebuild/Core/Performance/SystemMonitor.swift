import Foundation
import os
import Darwin

/// System resource monitor for capture safety
class SystemMonitor {
    private let logger = Logger(subsystem: "com.rgb2gif", category: "monitor")

    // MARK: - Memory Monitoring

    /// Get available memory in bytes (physical - resident)
    func availableMemory() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            logger.error("task_info failed: \(kerr)")
            return 0
        }

        let usedMemory = Int64(info.resident_size)
        let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let available = max(0, totalMemory - usedMemory)
        return available
    }

    /// Get memory pressure (0.0 = low, 1.0 = critical)
    func memoryPressure() -> Float {
        let available = Float(availableMemory())
        let total = Float(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 1.0 }
        return 1.0 - (available / total)
    }

    /// Check if we have enough memory for capture (need ~500MB buffer)
    func hasEnoughMemoryForCapture() -> Bool {
        let requiredMemory: Int64 = 500 * 1024 * 1024 // 500MB minimum
        let available = availableMemory()
        logger.info("Available memory: \(available / 1024 / 1024) MB")
        return available > requiredMemory
    }

    // MARK: - Disk Space Monitoring

    /// Get available disk space in bytes
    func availableDiskSpace() -> Int64? {
        guard let documentDirectory = FileManager.default.urls(for: .documentDirectory,
                                                               in: .userDomainMask).first else {
            return nil
        }

        do {
            let values = try documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            logger.error("Error getting disk space: \(error.localizedDescription)")
        }

        return nil
    }

    /// Check if we have enough disk space for 80 frames (~8GB for ProRAW, ~2.5GB for DNG)
    func hasEnoughDiskSpaceForCapture() -> Bool {
        // Keep conservative default for worst case (ProRAW)
        let requiredSpace: Int64 = 8 * 1024 * 1024 * 1024 // 8GB

        guard let available = availableDiskSpace() else {
            logger.error("Could not determine available disk space")
            return false
        }

        logger.info("Available disk space: \(available / 1024 / 1024 / 1024) GB")
        return available > requiredSpace
    }

    /// Get formatted disk space string
    func formattedDiskSpace() -> String {
        guard let bytes = availableDiskSpace() else {
            return "Unknown"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }

    /// Get formatted memory string
    func formattedMemory() -> String {
        let bytes = availableMemory()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Pre-capture Validation

    struct ValidationResult {
        let isValid: Bool
        let memoryOK: Bool
        let diskOK: Bool
        let memoryMessage: String
        let diskMessage: String

        var errorMessage: String? {
            if isValid { return nil }

            var messages: [String] = []
            if !memoryOK { messages.append(memoryMessage) }
            if !diskOK { messages.append(diskMessage) }
            return messages.joined(separator: "\n")
        }
    }

    /// Validate system resources before capture
    func validateForCapture() -> ValidationResult {
        let memoryOK = hasEnoughMemoryForCapture()
        let diskOK = hasEnoughDiskSpaceForCapture()

        let memoryMessage = memoryOK ?
            "Memory: \(formattedMemory()) available" :
            "Insufficient memory. Need 500MB, have \(formattedMemory())"

        let diskMessage = diskOK ?
            "Disk: \(formattedDiskSpace()) available" :
            "Insufficient disk space. Need 8GB, have \(formattedDiskSpace())"

        return ValidationResult(
            isValid: memoryOK && diskOK,
            memoryOK: memoryOK,
            diskOK: diskOK,
            memoryMessage: memoryMessage,
            diskMessage: diskMessage
        )
    }
}
