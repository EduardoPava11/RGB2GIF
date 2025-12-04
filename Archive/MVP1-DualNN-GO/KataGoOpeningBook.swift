//
//  KataGoOpeningBook.swift
//  RGB2GIF
//
//  ============================================================================
//  KATAGO OPENING BOOK PARSER
//  ============================================================================
//
//  PURPOSE
//  ───────
//  Parse pre-computed KataGo opening book positions from HTML files.
//  These provide professional-level GO analysis without running the NN live.
//
//  BOOK FORMAT (from katagobooks.org)
//  ──────────────────────────────────
//  Each HTML file contains JavaScript with:
//    - board[81]: Stone positions (0=empty, 1=black, 2=white)
//    - nextPla: Next player to move (1=black, 2=white)
//    - moves[]: Array of evaluated moves with policy/value/visits
//    - links{}: Hash links to child positions
//    - pLink: Parent position link
//
//  TWO RULE SETS AVAILABLE
//  ───────────────────────
//    book9x9jp: Japanese rules (territorial, defensive style)
//    book9x9tt: Tromp-Taylor rules (aggressive, fighting style)
//
//  USAGE FOR RGB2GIF
//  ─────────────────
//  Use different books for spatial vs temporal games:
//    - Japanese rules → spatial game (territory = color regions)
//    - Tromp-Taylor → temporal game (fighting = dynamic frames)
//
//  Or both from same book for consistency.
//
//  ============================================================================

import Foundation

// MARK: - Opening Book Types

@available(iOS 26.0, *)
public struct KataGoOpeningBook {

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Data Types
    // ════════════════════════════════════════════════════════════════════════

    /// Stone type on the GO board.
    public enum Stone: Int {
        case empty = 0
        case black = 1
        case white = 2

        public var symbol: String {
            switch self {
            case .empty: return "·"
            case .black: return "●"
            case .white: return "○"
            }
        }
    }

    /// An evaluated move from the opening book.
    public struct EvaluatedMove {
        /// Board coordinates (0-8, 0-8), or nil for pass
        public let coordinates: (x: Int, y: Int)?

        /// Policy probability (how likely this move is)
        public let policy: Float

        /// Win-loss expectation (-1 to +1)
        public let winLoss: Float

        /// Score margin (positive = ahead)
        public let scoreMargin: Float

        /// Number of MCTS visits (analysis depth)
        public let visits: Int

        /// True if this represents "all other moves"
        public let isOther: Bool
    }

    /// A complete board position from the opening book.
    public struct Position {
        /// 9×9 board state
        public let board: [[Stone]]

        /// Next player to move
        public let nextPlayer: Stone

        /// Evaluated moves in order of quality
        public let moves: [EvaluatedMove]

        /// Hash ID of this position
        public let hashID: String

        /// Link to parent position
        public let parentLink: String?

        /// Links to child positions (move index → hash)
        public let childLinks: [Int: String]

        /// Get the flat 81-element board array (for DualGameWeights).
        public var flatBoard: [Int] {
            board.flatMap { row in row.map { $0.rawValue } }
        }

        /// Get ownership estimation from stone positions.
        /// This is a simple approximation; real ownership needs NN inference.
        public var simpleOwnership: [[Float]] {
            board.map { row in
                row.map { stone -> Float in
                    switch stone {
                    case .black: return -1.0  // Black territory
                    case .white: return 1.0   // White territory
                    case .empty: return 0.0   // Contested
                    }
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Parsing
    // ════════════════════════════════════════════════════════════════════════

    /// Parse a position from an opening book HTML file.
    ///
    /// - Parameter url: URL to the HTML file
    /// - Returns: Parsed position, or nil if parsing fails
    public static func parsePosition(from url: URL) throws -> Position {
        let html = try String(contentsOf: url, encoding: .utf8)
        return try parsePosition(from: html, hashID: url.lastPathComponent)
    }

    /// Parse a position from HTML content.
    ///
    /// - Parameters:
    ///   - html: HTML string containing the position data
    ///   - hashID: Optional hash ID for the position
    /// - Returns: Parsed position
    public static func parsePosition(from html: String, hashID: String = "") throws -> Position {
        // Extract JavaScript variables
        guard let boardArray = extractArray(named: "board", from: html) else {
            throw ParserError.missingBoard
        }

        guard boardArray.count == 81 else {
            throw ParserError.invalidBoardSize(boardArray.count)
        }

        guard let nextPla = extractInt(named: "nextPla", from: html) else {
            throw ParserError.missingNextPlayer
        }

        // Parse board into 9×9 grid
        var board = [[Stone]]()
        for row in 0..<9 {
            var rowStones = [Stone]()
            for col in 0..<9 {
                let value = boardArray[row * 9 + col]
                rowStones.append(Stone(rawValue: value) ?? .empty)
            }
            board.append(rowStones)
        }

        // Parse moves
        let moves = extractMoves(from: html)

        // Parse links
        let parentLink = extractString(named: "pLink", from: html)
        let childLinks = extractLinks(from: html)

        return Position(
            board: board,
            nextPlayer: Stone(rawValue: nextPla) ?? .black,
            moves: moves,
            hashID: hashID.replacingOccurrences(of: ".html", with: ""),
            parentLink: parentLink,
            childLinks: childLinks
        )
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Extraction Helpers
    // ════════════════════════════════════════════════════════════════════════

    private static func extractArray(named name: String, from html: String) -> [Int]? {
        // Pattern: const board = [0,0,0,...];
        let pattern = "const \(name) = \\[([0-9,]+)\\];"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let arrayString = String(html[range])
        return arrayString.split(separator: ",").compactMap { Int($0) }
    }

    private static func extractInt(named name: String, from html: String) -> Int? {
        // Pattern: const nextPla = 1;
        let pattern = "const \(name) = (\\d+);"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return Int(html[range])
    }

    private static func extractString(named name: String, from html: String) -> String? {
        // Pattern: const pLink = '../98/hash.html';
        let pattern = "const \(name) = '([^']+)';"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return String(html[range])
    }

    private static func extractMoves(from html: String) -> [EvaluatedMove] {
        // Pattern: const moves = [{...}, {...}];
        // This is complex JSON-like structure, parse manually

        guard let movesStart = html.range(of: "const moves = ["),
              let movesEnd = html.range(of: "];", range: movesStart.upperBound..<html.endIndex) else {
            return []
        }

        let movesString = String(html[movesStart.upperBound..<movesEnd.lowerBound])
        var moves = [EvaluatedMove]()

        // Split by move objects
        let movePattern = "\\{([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: movePattern) else {
            return []
        }

        let matches = regex.matches(
            in: movesString,
            range: NSRange(movesString.startIndex..., in: movesString)
        )

        for match in matches {
            guard let range = Range(match.range(at: 1), in: movesString) else { continue }
            let moveContent = String(movesString[range])

            // Check if this is an "other" move
            let isOther = moveContent.contains("'move':'other'")

            // Extract coordinates if present
            var coordinates: (x: Int, y: Int)? = nil
            if let xyMatch = moveContent.range(of: "'xy':\\[\\[(\\d+),(\\d+)\\]", options: .regularExpression) {
                let xyString = String(moveContent[xyMatch])
                let numbers = xyString.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .filter { !$0.isEmpty }
                    .compactMap { Int($0) }
                if numbers.count >= 2 {
                    coordinates = (x: numbers[0], y: numbers[1])
                }
            }

            // Extract numeric fields
            let policy = extractFloat(named: "'p'", from: moveContent) ?? 0
            let winLoss = extractFloat(named: "'wl'", from: moveContent) ?? 0
            let scoreMargin = extractFloat(named: "'ssM'", from: moveContent) ?? 0
            let visits = extractMoveInt(named: "'v'", from: moveContent) ?? 0

            moves.append(EvaluatedMove(
                coordinates: coordinates,
                policy: policy,
                winLoss: winLoss,
                scoreMargin: scoreMargin,
                visits: visits,
                isOther: isOther
            ))
        }

        return moves
    }

    private static func extractFloat(named name: String, from text: String) -> Float? {
        let pattern = "\(name):(-?[0-9.]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Float(text[range])
    }

    private static func extractMoveInt(named name: String, from text: String) -> Int? {
        let pattern = "\(name):(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private static func extractLinks(from html: String) -> [Int: String] {
        // Pattern: const links = {68:'../20/hash.html',};
        guard let linksStart = html.range(of: "const links = {"),
              let linksEnd = html.range(of: "};", range: linksStart.upperBound..<html.endIndex) else {
            return [:]
        }

        let linksString = String(html[linksStart.upperBound..<linksEnd.lowerBound])
        var links = [Int: String]()

        // Pattern: 68:'../20/hash.html'
        let linkPattern = "(\\d+):'([^']+)'"
        guard let regex = try? NSRegularExpression(pattern: linkPattern) else {
            return [:]
        }

        let matches = regex.matches(
            in: linksString,
            range: NSRange(linksString.startIndex..., in: linksString)
        )

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: linksString),
                  let valueRange = Range(match.range(at: 2), in: linksString) else { continue }

            if let key = Int(linksString[keyRange]) {
                links[key] = String(linksString[valueRange])
            }
        }

        return links
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - Errors
    // ════════════════════════════════════════════════════════════════════════

    public enum ParserError: Error, LocalizedError {
        case missingBoard
        case invalidBoardSize(Int)
        case missingNextPlayer
        case fileNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .missingBoard:
                return "Board array not found in HTML"
            case .invalidBoardSize(let size):
                return "Invalid board size: \(size) (expected 81)"
            case .missingNextPlayer:
                return "Next player not found in HTML"
            case .fileNotFound(let path):
                return "Opening book file not found: \(path)"
            }
        }
    }
}

// MARK: - Opening Book Collection

@available(iOS 26.0, *)
extension KataGoOpeningBook {

    /// Manages a collection of opening book positions.
    public struct BookCollection {

        /// Root directory of the extracted opening book
        public let rootDirectory: URL

        /// Rule set (jp = Japanese, tt = Tromp-Taylor)
        public let ruleSet: String

        /// Initialize with the root directory of an extracted book
        public init(rootDirectory: URL, ruleSet: String) {
            self.rootDirectory = rootDirectory
            self.ruleSet = ruleSet
        }

        /// Load a position by its hash ID.
        ///
        /// - Parameter hashID: The hash identifier (e.g., "0000D33FA3...")
        /// - Returns: Parsed position
        public func loadPosition(hashID: String) throws -> Position {
            // Hash files are organized by first 2 characters
            let prefix = String(hashID.prefix(2))
            let fileName = "\(hashID).html"
            let fileURL = rootDirectory
                .appendingPathComponent("html")
                .appendingPathComponent(prefix)
                .appendingPathComponent(fileName)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ParserError.fileNotFound(fileURL.path)
            }

            return try KataGoOpeningBook.parsePosition(from: fileURL)
        }

        /// Get the root position (empty board).
        ///
        /// The root position's hash depends on the rule set.
        public func loadRootPosition() throws -> Position {
            // Find any file and navigate to root via parent links
            // For now, return a synthesized empty board position
            let emptyBoard = [[Stone]](
                repeating: [Stone](repeating: .empty, count: 9),
                count: 9
            )

            return Position(
                board: emptyBoard,
                nextPlayer: .black,
                moves: [],
                hashID: "ROOT",
                parentLink: nil,
                childLinks: [:]
            )
        }

        /// List all available position files.
        public func listPositions(limit: Int = 100) throws -> [String] {
            let htmlDir = rootDirectory.appendingPathComponent("html")

            guard let enumerator = FileManager.default.enumerator(
                at: htmlDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            var hashes = [String]()
            while let url = enumerator.nextObject() as? URL, hashes.count < limit {
                if url.pathExtension == "html" {
                    let hash = url.deletingPathExtension().lastPathComponent
                    hashes.append(hash)
                }
            }

            return hashes
        }
    }
}

// MARK: - Position Visualization

@available(iOS 26.0, *)
extension KataGoOpeningBook.Position {

    /// Generate ASCII visualization of the board.
    public func visualize() -> String {
        var lines = [String]()
        lines.append("╔═══════════════════════════════════════╗")
        lines.append("║  KATAGO OPENING BOOK POSITION          ║")
        lines.append("╠═══════════════════════════════════════╣")
        lines.append("║  Hash: \(hashID.prefix(20))...       ║")
        lines.append("║  Next: \(nextPlayer == .black ? "Black ●" : "White ○")                          ║")
        lines.append("╠═══════════════════════════════════════╣")

        // Column labels
        lines.append("║    A B C D E F G H J                  ║")
        lines.append("║   ┌─────────────────┐                 ║")

        for row in 0..<9 {
            var line = "║ \(9 - row) │"
            for col in 0..<9 {
                line += board[row][col].symbol + " "
            }
            line += "│                 ║"
            lines.append(line)
        }

        lines.append("║   └─────────────────┘                 ║")

        // Best moves
        if !moves.isEmpty {
            lines.append("╠═══════════════════════════════════════╣")
            lines.append("║  Top moves:                            ║")
            for (i, move) in moves.prefix(3).enumerated() {
                let coord: String
                if let xy = move.coordinates {
                    let col = ["A","B","C","D","E","F","G","H","J"][xy.x]
                    coord = "\(col)\(9 - xy.y)"
                } else if move.isOther {
                    coord = "other"
                } else {
                    coord = "pass"
                }
                let line = String(format: "║  %d. %-6s p=%.2f wl=%+.3f v=%d",
                                  i + 1, coord, move.policy, move.winLoss, move.visits)
                lines.append(line.padding(toLength: 42, withPad: " ", startingAt: 0) + "║")
            }
        }

        lines.append("╚═══════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}
