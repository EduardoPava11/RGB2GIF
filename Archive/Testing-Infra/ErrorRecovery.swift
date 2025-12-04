//
//  ErrorRecovery.swift
//  RGB2GIF
//
//  Error recovery system for iPhone 17 Pro camera operations
//

import Foundation
import AVFoundation
import os.log

private let recoveryLogger = Logger(subsystem: "com.rgb2gif", category: "ErrorRecovery")

/// Comprehensive error recovery for camera operations
@available(iOS 26.0, *)
public final class ErrorRecoveryManager {

    public enum RecoveryAction {
        case retry(delay: TimeInterval)
        case fallback(handler: () async throws -> Void)
        case alert(title: String, message: String)
        case reset
        case abort
    }

    public static func recover(from error: Error) -> RecoveryAction {
        recoveryLogger.error("Recovering from error: \(error.localizedDescription)")

        switch error {
        case let avError as AVError:
            return recoverFromAVError(avError)

        case let nsError as NSError:
            return recoverFromNSError(nsError)

        default:
            return .alert(
                title: "Unexpected Error",
                message: error.localizedDescription
            )
        }
    }

    // Legacy error recovery - removed with GIP2/GIX2 refactor
    // private static func recoverFromGIFError(_ error: Error) -> RecoveryAction { ... }

    private static func recoverFromAVError(_ error: AVError) -> RecoveryAction {
        switch error.code {
        case .sessionNotRunning:
            return .reset

        case .deviceIsNotAvailableInBackground:
            return .alert(
                title: "Camera Unavailable",
                message: "Camera cannot be used while app is in background."
            )

        case .maximumDurationReached:
            // Normal completion for video capture
            return .abort

        case .diskFull:
            return .alert(
                title: "Storage Full",
                message: "Please free up space to continue capturing."
            )

        default:
            return .retry(delay: 1.0)
        }
    }

    private static func recoverFromNSError(_ error: NSError) -> RecoveryAction {
        // Check for specific domains
        if error.domain == AVFoundationErrorDomain {
            return recoverFromAVError(AVError(_nsError: error))
        }

        // Memory warnings
        if error.code == NSFileWriteOutOfSpaceError {
            return .alert(
                title: "Storage Full",
                message: "Cannot save file. Please free up storage space."
            )
        }

        return .retry(delay: 1.0)
    }
}

/// Retry mechanism with exponential backoff
@available(iOS 26.0, *)
public actor RetryManager {
    private var retryCount = 0
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0

    public func retry<T>(
        operation: () async throws -> T,
        onError: (Error) -> ErrorRecoveryManager.RecoveryAction = ErrorRecoveryManager.recover
    ) async throws -> T {
        for attempt in 0..<self.maxRetries {
            do {
                let result = try await operation()
                self.retryCount = 0 // Reset on success
                return result
            } catch {
                self.retryCount = attempt + 1

                let recovery = onError(error)
                switch recovery {
                case .retry(let delay):
                    let backoffDelay = delay * pow(2.0, Double(attempt))
                    recoveryLogger.info("Retrying after \(backoffDelay)s (attempt \(self.retryCount)/\(self.maxRetries))")
                    try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))

                case .fallback(let handler):
                    try await handler()
                    return try await operation()

                case .reset:
                    recoveryLogger.info("Resetting and retrying")
                    self.retryCount = 0
                    try await Task.sleep(nanoseconds: 1_000_000_000)

                case .abort:
                    throw error

                case .alert:
                    throw error
                }
            }
        }

        throw RetryError.maxRetriesExceeded
    }
}

public enum RetryError: LocalizedError {
    case maxRetriesExceeded

    public var errorDescription: String? {
        switch self {
        case .maxRetriesExceeded:
            return "Operation failed after maximum retry attempts"
        }
    }
}
