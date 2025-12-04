//
//  CBORManifest.swift
//  RGB2GIF
//
//  ╔═══════════════════════════════════════════════════════════════════════════╗
//  ║  CBOR MANIFEST - SESSION METADATA & VERIFICATION CHAIN                    ║
//  ╠═══════════════════════════════════════════════════════════════════════════╣
//  ║                                                                           ║
//  ║  Tracks all session metadata and checksums for verification:              ║
//  ║  • Session identification (UUID, timestamp, device info)                  ║
//  ║  • Layer checksums (L0-L4) for integrity verification                     ║
//  ║  • Algorithm versions for regeneration policy                             ║
//  ║  • Coordinate system (X=right, Y=up, Z=time)                             ║
//  ║                                                                           ║
//  ╚═══════════════════════════════════════════════════════════════════════════╝
//

import Foundation
import CryptoKit
import SwiftCBOR
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let manifestLogger = Logger(subsystem: "com.rgb2gif", category: "CBORManifest")

// MARK: - Coordinate System

/// X=right, Y=up, Z=time coordinate convention
@available(iOS 26.0, *)
public struct CoordinateSystem: Sendable {
    public static let x = "right"
    public static let y = "up"
    public static let z = "time"
    public static let origin = "bottom-left-first-frame"

    public static func toCBOR() -> CBOR {
        return .map([
            "x": .utf8String(x),
            "y": .utf8String(y),
            "z": .utf8String(z),
            "origin": .utf8String(origin)
        ])
    }
}

// MARK: - Dimensions

@available(iOS 26.0, *)
public struct RGB81Dimensions: Sendable {
    public static let frames = 81
    public static let width = 81
    public static let height = 81
    public static let tensorGrid = 9
    public static let paletteSize = 256
    public static let pixelsPerFrame = width * height  // 6561
    public static let bytesPerFrame = pixelsPerFrame * 3  // 19683 (RGB8)
    public static let tensorCells = tensorGrid * tensorGrid * tensorGrid  // 729

    public static func toCBOR() -> CBOR {
        return .map([
            "frames": .unsignedInt(UInt64(frames)),
            "width": .unsignedInt(UInt64(width)),
            "height": .unsignedInt(UInt64(height)),
            "tensor_grid": .unsignedInt(UInt64(tensorGrid)),
            "palette_size": .unsignedInt(UInt64(paletteSize))
        ])
    }
}

// MARK: - Algorithm Versions

@available(iOS 26.0, *)
public struct AlgorithmVersions: Sendable {
    public static let tensorBuilder = "gaussian_weighted_v1"
    public static let quantizer = "octree_v1"
    public static let paletteMapper = "nearest_neighbor_v1"
    public static let lzwEncoder = "gif89a_v1"

    public static func toCBOR() -> CBOR {
        return .map([
            "tensor_builder": .utf8String(tensorBuilder),
            "quantizer": .utf8String(quantizer),
            "palette_mapper": .utf8String(paletteMapper),
            "lzw_encoder": .utf8String(lzwEncoder)
        ])
    }
}

// MARK: - Layer Info

@available(iOS 26.0, *)
public struct LayerInfo {
    public var fileCount: Int = 0
    public var totalBytes: Int64 = 0
    public var sha256: String = ""
    public var algorithm: String = ""
    public var inputSHA256: String = ""

    public func toCBOR() -> CBOR {
        var map: [String: CBOR] = [
            "file_count": .unsignedInt(UInt64(fileCount)),
            "total_bytes": .unsignedInt(UInt64(totalBytes)),
            "sha256": .utf8String(sha256)
        ]
        if !algorithm.isEmpty {
            map["algorithm"] = .utf8String(algorithm)
        }
        if !inputSHA256.isEmpty {
            map["input_sha256"] = .utf8String(inputSHA256)
        }
        return .map(map.mapKeys { .utf8String($0) })
    }
}

// MARK: - CBORManifest

@available(iOS 26.0, *)
public final class CBORManifest {

    // MARK: - Properties

    public let magic = "RGB81"
    public let version = 2
    public let sessionID: String
    public let createdAt: Date
    public let pipelineVersion = "1.0.0"

    // Device info
    public var deviceModel: String = ""
    public var osVersion: String = ""
    public var appVersion: String = ""

    // Layer tracking
    public var l0Frames = LayerInfo()
    public var l1Tensor = LayerInfo()
    public var l2Palette = LayerInfo()
    public var l3Indices = LayerInfo()
    public var l4Compressed = LayerInfo()

    // MARK: - Initialization

    public init(sessionID: String) {
        self.sessionID = sessionID
        self.createdAt = Date()

        // Populate device info
        #if canImport(UIKit)
        self.deviceModel = Self.deviceModelIdentifier()
        self.osVersion = UIDevice.current.systemVersion
        #else
        self.deviceModel = "Unknown"
        self.osVersion = "Unknown"
        #endif

        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.appVersion = version
        } else {
            self.appVersion = "1.0.0"
        }
    }

    // MARK: - Device Identification

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    // MARK: - CBOR Encoding

    public func toCBOR() -> CBOR {
        let iso8601Formatter = ISO8601DateFormatter()

        let deviceMap: CBOR = .map([
            "model": .utf8String(deviceModel),
            "os_version": .utf8String(osVersion),
            "app_version": .utf8String(appVersion)
        ])

        let layersMap: CBOR = .map([
            "L0_frames": l0Frames.toCBOR(),
            "L1_tensor": l1Tensor.toCBOR(),
            "L2_palette": l2Palette.toCBOR(),
            "L3_indices": l3Indices.toCBOR(),
            "L4_compressed": l4Compressed.toCBOR()
        ])

        return .map([
            "magic": .utf8String(magic),
            "version": .unsignedInt(UInt64(version)),
            "session_id": .utf8String(sessionID),
            "created_at": .utf8String(iso8601Formatter.string(from: createdAt)),
            "device": deviceMap,
            "dimensions": RGB81Dimensions.toCBOR(),
            "coordinate_system": CoordinateSystem.toCBOR(),
            "algorithm_versions": AlgorithmVersions.toCBOR(),
            "layers": layersMap,
            "pipeline_version": .utf8String(pipelineVersion),
            "regeneration_policy": .utf8String("auto_on_mismatch")
        ])
    }

    /// Encode manifest to Data
    public func encode() -> Data {
        let cbor = toCBOR()
        return Data(cbor.encode())
    }

    /// Write manifest to session directory
    public func write(to url: URL) throws {
        let data = encode()
        try data.write(to: url)
        manifestLogger.info("Manifest written: \(data.count) bytes")
    }

    // MARK: - Checksum Helpers

    /// Compute SHA-256 hash of data
    public static func sha256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Compute SHA-256 hash of file
    public static func sha256(fileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256(data)
    }

    /// Compute combined SHA-256 of multiple files
    public static func sha256(filesIn directory: URL, matching pattern: String = "*") throws -> String {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cbor" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var hasher = SHA256()
        for url in contents {
            let data = try Data(contentsOf: url)
            hasher.update(data: data)
        }
        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Dictionary Extension for CBOR Key Mapping

extension Dictionary where Key == String {
    func mapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey) -> [NewKey: Value] {
        var result: [NewKey: Value] = [:]
        for (key, value) in self {
            result[transform(key)] = value
        }
        return result
    }
}
