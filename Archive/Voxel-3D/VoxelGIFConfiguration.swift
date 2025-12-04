//
//  VoxelGIFConfiguration.swift
//  RGB2GIF
//

import Foundation
import CoreGraphics
import UIKit

@available(iOS 26.0, *)
public struct VoxelGIFConfiguration {
    public enum CubeDimension: Int {
        case small = 80
        case large = 128

        public var frameCount: Int { rawValue }
        public var size: CGSize { CGSize(width: rawValue, height: rawValue) }
    }

    public struct ConveyorSettings: Codable {
        public let enabled: Bool
        public let zDepth: Int
        public let brightnessDecay: Float
        public let frameSpacing: Float
        public let animationSpeed: Float
        public let highlightFrontFrame: Bool

        public static var `default`: ConveyorSettings {
            ConveyorSettings(
                enabled: true,
                zDepth: 80,
                brightnessDecay: 0.5,
                frameSpacing: 2.0,
                animationSpeed: 1.0,
                highlightFrontFrame: true
            )
        }
    }

    public enum ExportFormat {
        case standard       // Regular GIF89a
        case withTensor     // GIF + tensor sidecar
        case proprietaryApp // App-specific format
    }

    // Core export options
    public let dimension: CubeDimension
    public let frameDelay: TimeInterval
    public let loopCount: Int
    public let colorCount: Int

    // Rendering/processing options
    public let useDithering: Bool
    public let correctOrientation: Bool

    // Conveyor visualization
    public let conveyorSettings: ConveyorSettings
    public let exportFormat: ExportFormat

    // Photos integration
    public let autoSaveToPhotos: Bool
    public let photosTitle: String?

    public init(
        dimension: CubeDimension = .large,
        frameDelay: TimeInterval = 1.0 / 24.0,
        loopCount: Int = 0,
        colorCount: Int = 256,
        useDithering: Bool = false,
        correctOrientation: Bool = true,
        conveyorSettings: ConveyorSettings = .default,
        exportFormat: ExportFormat = .withTensor,
        autoSaveToPhotos: Bool = false,
        photosTitle: String? = nil
    ) {
        self.dimension = dimension
        self.frameDelay = max(0.1, frameDelay) // iOS enforces minimum 0.1s
        self.loopCount = loopCount
        self.colorCount = min(256, max(2, colorCount))
        self.useDithering = useDithering
        self.correctOrientation = correctOrientation
        self.conveyorSettings = conveyorSettings
        self.exportFormat = exportFormat
        self.autoSaveToPhotos = autoSaveToPhotos
        self.photosTitle = photosTitle
    }
}

// MARK: - Voxel GIF Metadata

@available(iOS 26.0, *)
public struct VoxelGIFMetadata: Codable {
    public let dimension: Int
    public let frameCount: Int
    public let fps: Double
    public let fileSize: Int
    public let colorCount: Int
    public let hasConveyor: Bool
    public let hasTensor: Bool
    public let captureDate: Date
    public let deviceModel: String?

    public init(
        dimension: Int,
        frameCount: Int,
        fps: Double = 24.0,
        fileSize: Int,
        colorCount: Int = 256,
        hasConveyor: Bool = false,
        hasTensor: Bool = false,
        captureDate: Date = Date(),
        deviceModel: String? = UIDevice.current.model
    ) {
        self.dimension = dimension
        self.frameCount = frameCount
        self.fps = fps
        self.fileSize = fileSize
        self.colorCount = colorCount
        self.hasConveyor = hasConveyor
        self.hasTensor = hasTensor
        self.captureDate = captureDate
        self.deviceModel = deviceModel
    }
}
