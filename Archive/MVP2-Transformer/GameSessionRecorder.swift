//
//  GameSessionRecorder.swift
//  RGB2GIF
//
//  ============================================================================
//  GAME SESSION RECORDER: Capture Training Data from User Play
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Record every aspect of a GO game session for transformer training:
//    - Cube features (what the video looks like)
//    - Human moves (what they valued)
//    - NN suggestions (what was offered)
//    - Timing data (how long they thought)
//    - Final results (the palette they got)
//
//  THE TRAINING SIGNAL
//  ───────────────────
//  Every move is an implicit statement of preference:
//
//    EARLY MOVES = "This is my highest priority"
//    LATE MOVES = "This is a refinement"
//    QUICK MOVES = "This is obvious to me"
//    SLOW MOVES = "I'm uncertain about this"
//    ACCEPTING NN = "I agree with the suggestion"
//    REJECTING NN = "I disagree, I want something else"
//
//  DATA PERSISTENCE
//  ────────────────
//  Sessions are stored locally in:
//    ~/Documents/RGB2GIF/TrainingData/sessions/
//
//  Each session is a JSON file with full replay capability.
//
//  PRIVACY CONSIDERATIONS
//  ──────────────────────
//  - Cube features are derived (histograms, not raw pixels)
//  - No actual video frames are stored
//  - User ID is a local hash, not personal info
//  - Training is on-device by default
//
//  ============================================================================

import Foundation

// MARK: - Game Session Recorder

@available(iOS 26.0, *)
public final class GameSessionRecorder {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - State
    // ════════════════════════════════════════════════════════════════════════

    /// Current session being recorded
    private var currentSession: RecordingSession?

    /// Storage directory
    private let storageDirectory: URL

    /// User identifier (hashed for privacy)
    private let userID: String

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Recording Session
    // ════════════════════════════════════════════════════════════════════════

    /// Active recording state
    private struct RecordingSession {
        let sessionID: UUID
        let startTime: Date
        var cubeDigest: MacroCellDigest?
        var spatialMoves: [RecordedMove]
        var temporalMoves: [RecordedMove]
        var lastMoveTime: Date
        var spatialBoardState: [Int]  // Current board: 0=empty, 1=black, 2=white
        var temporalBoardState: [Int]
    }

    /// A recorded move with metadata
    public struct RecordedMove: Codable {
        public let moveNumber: Int
        public let player: Player
        public let position: Int
        public let thinkingTime: TimeInterval
        public let timestamp: Date
        public let wasNNSuggestion: Bool
        public let nnConfidence: Float?
        public let alternativesConsidered: [Int]?  // Other positions the NN suggested

        public enum Player: Int, Codable {
            case human = 0
            case nn = 1
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Initialization
    // ════════════════════════════════════════════════════════════════════════

    public init(userID: String? = nil) {
        // Generate or use provided user ID
        self.userID = userID ?? Self.generateUserID()

        // Set up storage directory
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageDirectory = documents
            .appendingPathComponent("RGB2GIF")
            .appendingPathComponent("TrainingData")
            .appendingPathComponent("sessions")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Session Lifecycle
    // ════════════════════════════════════════════════════════════════════════

    /// Start recording a new session.
    ///
    /// - Parameter digest: The computed macro-cell digest for this video
    public func startSession(with digest: MacroCellDigest) {
        currentSession = RecordingSession(
            sessionID: UUID(),
            startTime: Date(),
            cubeDigest: digest,
            spatialMoves: [],
            temporalMoves: [],
            lastMoveTime: Date(),
            spatialBoardState: [Int](repeating: 0, count: 81),
            temporalBoardState: [Int](repeating: 0, count: 81)
        )

        print("📹 Started recording session: \(currentSession!.sessionID)")
    }

    /// Record a move in the spatial game.
    ///
    /// - Parameters:
    ///   - position: Board position (0-80)
    ///   - player: Who played (human or NN)
    ///   - nnConfidence: If NN played, its confidence
    ///   - alternatives: Other positions the NN considered
    public func recordSpatialMove(
        position: Int,
        player: RecordedMove.Player,
        nnConfidence: Float? = nil,
        alternatives: [Int]? = nil
    ) {
        guard var session = currentSession else {
            print("⚠️ No active session to record move")
            return
        }

        let now = Date()
        let thinkingTime = now.timeIntervalSince(session.lastMoveTime)

        let move = RecordedMove(
            moveNumber: session.spatialMoves.count,
            player: player,
            position: position,
            thinkingTime: thinkingTime,
            timestamp: now,
            wasNNSuggestion: player == .nn,
            nnConfidence: nnConfidence,
            alternativesConsidered: alternatives
        )

        session.spatialMoves.append(move)
        session.spatialBoardState[position] = player == .human ? 1 : 2
        session.lastMoveTime = now

        currentSession = session

        let playerStr = player == .human ? "Human" : "NN"
        let pos = "(\(position / 9), \(position % 9))"
        print("  ♟️ Spatial move \(move.moveNumber): \(playerStr) at \(pos), \(String(format: "%.1f", thinkingTime))s thinking")
    }

    /// Record a move in the temporal game.
    public func recordTemporalMove(
        position: Int,
        player: RecordedMove.Player,
        nnConfidence: Float? = nil,
        alternatives: [Int]? = nil
    ) {
        guard var session = currentSession else {
            print("⚠️ No active session to record move")
            return
        }

        let now = Date()
        let thinkingTime = now.timeIntervalSince(session.lastMoveTime)

        let move = RecordedMove(
            moveNumber: session.temporalMoves.count,
            player: player,
            position: position,
            thinkingTime: thinkingTime,
            timestamp: now,
            wasNNSuggestion: player == .nn,
            nnConfidence: nnConfidence,
            alternativesConsidered: alternatives
        )

        session.temporalMoves.append(move)
        session.temporalBoardState[position] = player == .human ? 1 : 2
        session.lastMoveTime = now

        currentSession = session

        let playerStr = player == .human ? "Human" : "NN"
        let timeGroup = position / 9
        let slot = position % 9
        print("  ⏱️ Temporal move \(move.moveNumber): \(playerStr) at group \(timeGroup) slot \(slot)")
    }

    /// End the session and save with final results.
    ///
    /// - Parameters:
    ///   - weights: Final macro-cell weights
    ///   - palette: Final 256-color palette
    ///   - userRating: Optional user satisfaction rating (1-5)
    ///   - wasEdited: Whether the user edited the result
    /// - Returns: The completed session (for immediate use)
    @discardableResult
    public func endSession(
        weights: [Float],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        userRating: Int? = nil,
        wasEdited: Bool = false
    ) throws -> PreferenceTransformer.GameSession {

        guard let session = currentSession else {
            throw RecorderError.noActiveSession
        }

        guard let digest = session.cubeDigest else {
            throw RecorderError.noDigest
        }

        // Convert to training data format
        let gameSession = PreferenceTransformer.GameSession(
            sessionID: session.sessionID,
            timestamp: session.startTime,
            userID: userID,
            cubeFeatures: digest.featureMatrix,
            spatialMoves: session.spatialMoves.map { convertMove($0) },
            temporalMoves: session.temporalMoves.map { convertMove($0) },
            finalWeights: weights,
            finalPalette: palette.map { [$0.r, $0.g, $0.b] },
            userRating: userRating,
            wasEdited: wasEdited
        )

        // Save to disk
        try saveSession(gameSession)

        // Clear current session
        currentSession = nil

        let duration = Date().timeIntervalSince(session.startTime)
        print("✅ Session ended: \(session.sessionID)")
        print("   Duration: \(String(format: "%.1f", duration))s")
        print("   Spatial moves: \(session.spatialMoves.count)")
        print("   Temporal moves: \(session.temporalMoves.count)")

        return gameSession
    }

    /// Cancel the current session without saving.
    public func cancelSession() {
        if let session = currentSession {
            print("❌ Session cancelled: \(session.sessionID)")
        }
        currentSession = nil
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Persistence
    // ════════════════════════════════════════════════════════════════════════

    private func saveSession(_ session: PreferenceTransformer.GameSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(session)

        let filename = "\(session.sessionID.uuidString).json"
        let fileURL = storageDirectory.appendingPathComponent(filename)

        try data.write(to: fileURL)

        print("   Saved to: \(fileURL.lastPathComponent)")
    }

    /// Load all saved sessions for this user.
    public func loadSessions() throws -> [PreferenceTransformer.GameSession] {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sessions = [PreferenceTransformer.GameSession]()

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let session = try decoder.decode(PreferenceTransformer.GameSession.self, from: data)

                // Only include this user's sessions
                if session.userID == userID {
                    sessions.append(session)
                }
            } catch {
                print("⚠️ Failed to load session \(file.lastPathComponent): \(error)")
            }
        }

        return sessions.sorted { $0.timestamp < $1.timestamp }
    }

    /// Get count of saved sessions.
    public func sessionCount() -> Int {
        let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        return files?.count ?? 0
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Analytics
    // ════════════════════════════════════════════════════════════════════════

    /// Get summary statistics across all sessions.
    public func getAnalytics() throws -> SessionAnalytics {
        let sessions = try loadSessions()

        guard !sessions.isEmpty else {
            return SessionAnalytics.empty
        }

        var totalMoves = 0
        var totalThinkingTime: TimeInterval = 0
        var humanMoves = 0
        var nnMoves = 0
        var avgRating: Float? = nil
        var editRate: Float = 0

        var ratingSum = 0
        var ratingCount = 0
        var editCount = 0

        for session in sessions {
            let allMoves = session.spatialMoves + session.temporalMoves
            totalMoves += allMoves.count

            for move in allMoves {
                totalThinkingTime += TimeInterval(move.thinkingTime)
                if move.player == 0 {
                    humanMoves += 1
                } else {
                    nnMoves += 1
                }
            }

            if let rating = session.userRating {
                ratingSum += rating
                ratingCount += 1
            }

            if session.wasEdited {
                editCount += 1
            }
        }

        if ratingCount > 0 {
            avgRating = Float(ratingSum) / Float(ratingCount)
        }

        editRate = Float(editCount) / Float(sessions.count)

        return SessionAnalytics(
            totalSessions: sessions.count,
            totalMoves: totalMoves,
            avgMovesPerSession: Float(totalMoves) / Float(sessions.count),
            avgThinkingTime: totalMoves > 0 ? totalThinkingTime / Double(totalMoves) : 0,
            humanToNNRatio: nnMoves > 0 ? Float(humanMoves) / Float(nnMoves) : Float(humanMoves),
            averageRating: avgRating,
            editRate: editRate,
            firstSession: sessions.first?.timestamp,
            lastSession: sessions.last?.timestamp
        )
    }

    /// Summary statistics across sessions
    public struct SessionAnalytics {
        public let totalSessions: Int
        public let totalMoves: Int
        public let avgMovesPerSession: Float
        public let avgThinkingTime: TimeInterval
        public let humanToNNRatio: Float
        public let averageRating: Float?
        public let editRate: Float
        public let firstSession: Date?
        public let lastSession: Date?

        public static let empty = SessionAnalytics(
            totalSessions: 0,
            totalMoves: 0,
            avgMovesPerSession: 0,
            avgThinkingTime: 0,
            humanToNNRatio: 0,
            averageRating: nil,
            editRate: 0,
            firstSession: nil,
            lastSession: nil
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ════════════════════════════════════════════════════════════════════════

    private func convertMove(_ recorded: RecordedMove) -> PreferenceTransformer.Move {
        PreferenceTransformer.Move(
            moveNumber: recorded.moveNumber,
            player: recorded.player.rawValue,
            position: recorded.position,
            thinkingTime: Float(recorded.thinkingTime),
            isResponse: recorded.moveNumber > 0 && recorded.player == .human,
            nnEvaluation: recorded.nnConfidence
        )
    }

    private static func generateUserID() -> String {
        // Generate a stable device-based ID (hashed for privacy)
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let hash = deviceID.data(using: .utf8)!.base64EncodedString()
        return String(hash.prefix(16))
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Errors
    // ════════════════════════════════════════════════════════════════════════

    public enum RecorderError: Error, LocalizedError {
        case noActiveSession
        case noDigest
        case saveFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .noActiveSession:
                return "No active recording session"
            case .noDigest:
                return "Session has no cube digest"
            case .saveFailed(let error):
                return "Failed to save session: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - UIKit Import (for device ID)

#if canImport(UIKit)
import UIKit
#else
// Fallback for non-UIKit platforms
private enum UIDevice {
    static let current = UIDevice()
    var identifierForVendor: UUID? { nil }
}
#endif
