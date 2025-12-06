//
//  ProcessingMode.swift
//  RGB2GIF
//
//  ============================================================================
//  PROCESSING MODE: MVP0 vs MVP1 Selection
//  ============================================================================
//
//  MVP0: Instant processing using fixed Gaussian downsampling
//        81×81×81 → 729 → 256 → GIF (no user interaction)
//
//  MVP1: Interactive mode with user tools to control downsampling
//        User configures weights, views slices, then generates
//
//  ============================================================================

import Foundation

/// Processing mode for GIF generation
@available(iOS 26.0, *)
public enum ProcessingMode: String, CaseIterable, Sendable {
    /// MVP0: Instant processing with fixed Gaussian weights
    case mvp0 = "Instant (MVP0)"

    /// MVP1: Interactive mode with user tools
    case mvp1 = "Explore (MVP1)"

    /// User-facing description
    public var description: String {
        switch self {
        case .mvp0:
            return "Fast GIF generation using default settings"
        case .mvp1:
            return "Explore the color tensor and customize analysis"
        }
    }

    /// Icon name for UI
    public var iconName: String {
        switch self {
        case .mvp0:
            return "bolt.fill"
        case .mvp1:
            return "slider.horizontal.3"
        }
    }

    /// Whether this mode requires user interaction before GIF generation
    public var requiresUserInteraction: Bool {
        switch self {
        case .mvp0:
            return false
        case .mvp1:
            return true
        }
    }
}
