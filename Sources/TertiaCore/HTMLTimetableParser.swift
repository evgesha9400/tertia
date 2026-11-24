import Foundation

public enum ParserError: Error, LocalizedError, Sendable {
    case missingEmbeddedData(String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .missingEmbeddedData(let detail): "Missing embedded schedule data: \(detail)"
        case .invalidJSON(let detail): "Failed to decode public schedule JSON: \(detail)"
        }
    }
}

public struct ParsedTimetablePage: Sendable {
    public let clubs: [Club]
    public let days: [String: [ClassSession]]
}

private struct RawClub: Decodable {
    let id: Int; let name: String; let short_code: String?; let hidden: Bool?
}

private struct RawClass: Decodable {
    let id: Int
    let start_time, end_time, service_title: String
    let trainer_name, location_name: String?
    let duration_hours, duration_minutes: Int?
}

/// PHP `json_encode` emits `[]` for empty dates and `{"Club Name": [...]}` for populated dates.
/// Any other shape (non-empty array, primitive, malformed class) is a decoding error, never a silent empty day.
private enum DayScheduleEntry: Decodable {
    case empty
    case byClub([String: [RawClass]])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // `[]` decodes as any array type; a non-empty array of objects fails here and then fails the object decode below.
        if let list = try? c.decode([Int].self), list.isEmpty { self = .empty; return }
        self = .byClub(try c.decode([String: [RawClass]].self))
    }
}

public enum HTMLTimetableParser {
    /// Parses the embedded `let clubs =` and `let timetable =` JSON. When `clubId` is given, keeps only sessions whose
    /// club key (and non-empty `location_name`) match that club's name, so mixed-club payloads never leak other clubs.
    public static func parse(html: String, clubId: Int? = nil) throws -> ParsedTimetablePage {
        let bodies = scriptBodies(Array(html.utf8))
        guard let clubsJSON = extractJSONLiteral(bodies, variable: "clubs") else { throw ParserError.missingEmbeddedData("let clubs =") }
        guard let timetableJSON = extractJSONLiteral(bodies, variable: "timetable") else { throw ParserError.missingEmbeddedData("let timetable =") }

        let decoder = JSONDecoder()
        let decodedClubs: [RawClub]
        do { decodedClubs = try decoder.decode([RawClub].self, from: Data(clubsJSON.utf8)) }
        catch { throw ParserError.invalidJSON("clubs: \(error.localizedDescription)") }

        // One club ID names one club: positive IDs only, exact repeats collapse, any disagreement is an error.
        var seen: [Int: (club: Club, hidden: Bool)] = [:], visible: [Club] = []
        for raw in decodedClubs {
            guard raw.id > 0 else { throw ParserError.invalidJSON("non-positive club id \(raw.id)") }
            let club = Club(id: raw.id, name: clean(raw.name), shortCode: (raw.short_code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)), hidden = raw.hidden ?? false
            if let prior = seen[raw.id] {
                guard prior.club == club, prior.hidden == hidden else { throw ParserError.invalidJSON("conflicting duplicate club id \(raw.id)") }
                continue
            }
            seen[raw.id] = (club, hidden)
            if !hidden { visible.append(club) }
        }
        let clubs = visible.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let targetName = clubId.map { id in seen[id]?.club.name ?? Club.defaultClubs.first { $0.id == id }?.name ?? "" }

        let decodedDays: [String: DayScheduleEntry]
        do { decodedDays = try decoder.decode([String: DayScheduleEntry].self, from: Data(timetableJSON.utf8)) }
        catch { throw ParserError.invalidJSON("timetable: \(error.localizedDescription)") }

        var days: [String: [ClassSession]] = [:], byId: [Int: ClassSession] = [:]
        for (dateStr, entry) in decodedDays {
            guard LondonCalendar.parseIsoDate(dateStr) != nil else { throw ParserError.invalidJSON("invalid date key '\(dateStr)'") }
            guard case .byClub(let byClub) = entry else { days[dateStr] = []; continue }
            var sessions: [(Int, ClassSession)] = []
            for (rawKey, rawList) in byClub {
                let clubKey = clean(rawKey)
                for item in rawList {
                    let loc = clean(item.location_name ?? "")
                    if let targetName, !(sameName(clubKey, targetName) && (loc.isEmpty || sameName(loc, targetName))) { continue }
                    guard item.id > 0 else { throw ParserError.invalidJSON("non-positive class id \(item.id)") }
                    let session = try makeSession(item, date: dateStr, clubName: loc.isEmpty ? clubKey : loc)
                    // One ID names one class on the whole page: exact repeats collapse, any other reuse is an error.
                    if let seen = byId[item.id] {
                        guard seen == session else { throw ParserError.invalidJSON("conflicting duplicate class id \(item.id)") }
                        continue
                    }
                    byId[item.id] = session
                    sessions.append((LondonCalendar.secondsOfDay(session.startTime) ?? 0, session))
                }
            }
            sessions.sort { ($0.0, $0.1.id) < ($1.0, $1.1.id) }
            days[dateStr] = sessions.map(\.1)
        }
        return ParsedTimetablePage(clubs: clubs, days: days)
    }

    private static func makeSession(_ item: RawClass, date: String, clubName: String) throws -> ClassSession {
        guard LondonCalendar.parseWallTime(item.start_time) != nil, LondonCalendar.parseWallTime(item.end_time) != nil else {
            throw ParserError.invalidJSON("class \(item.id) has invalid time '\(item.start_time)'-'\(item.end_time)'")
        }
        if LondonCalendar.resolveLondonWallTime(dateIso: date, hhmm: item.start_time) == .invalid {
            throw ParserError.invalidJSON("class \(item.id) starts at '\(item.start_time)', which does not exist in London on \(date)")
        }
        let hours = item.duration_hours ?? 0, minutes = item.duration_minutes ?? 0
        let (hourMinutes, overflowA) = hours.multipliedReportingOverflow(by: 60)
        let (total, overflowB) = hourMinutes.addingReportingOverflow(minutes)
        guard hours >= 0, minutes >= 0, !overflowA, !overflowB else {
            throw ParserError.invalidJSON("class \(item.id) has invalid duration \(hours)h \(minutes)m")
        }
        return ClassSession(
            id: item.id, date: date, startTime: item.start_time, endTime: item.end_time, durationMinutes: total,
            title: clean(item.service_title), trainer: clean(item.trainer_name ?? ""), clubName: clubName
        )
    }

    private static func clean(_ text: String) -> String { decodeHTMLEntities(text).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func sameName(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// The balanced JSON literal assigned by the first real `let <variable> =` declaration in a `<script>` body (the
    /// whole input only when it has no HTML tags at all). Comments, string literals, and HTML comments never count.
    private static func extractJSONLiteral(_ bodies: [ArraySlice<UInt8>], variable: String) -> String? {
        bodies.lazy.compactMap { declaration(in: Array($0), variable: Array(variable.utf8)) }.first
    }

    /// Elements whose content is text, never markup (`script` bodies are collected; the others are skipped).
    private static let rawTextTags = ["script", "textarea", "title", "style", "xmp", "iframe", "noembed", "noframes", "noscript"]

    private static func isSpace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0A, 0x0C, 0x0D].contains(byte) }
    private static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
    private static func isIdentifier(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || (byte >= 0x30 && byte <= 0x39) || isLetter(byte) }

    private static func startsCaseInsensitive(_ bytes: [UInt8], at i: Int, _ token: String) -> Bool {
        let t = Array(token.utf8)
        return i + t.count <= bytes.count && zip(bytes[i..<(i + t.count)], t).allSatisfy { a, b in a == b || (isLetter(a) && (a | 0x20) == (b | 0x20)) }
    }

    /// Bodies of real `<script>` elements, walking markup tag by tag: quoted attribute values inside every tag are
    /// skipped (so `<div data-x="<script>">` never opens a script), `<!-- ... -->` regions are skipped, the raw-text and
    /// RCDATA elements in `rawTextTags` are skipped through their closing tag (so `<textarea><script>` is text), and a
    /// body ends only at `</script` followed by `>`, `/`, or whitespace (so `</scripture>` inside JS does not end it).
    /// Only executable inline scripts count (`isExecutableScript`: no `src`, and no `type` or a JavaScript or module
    /// type), so inert data blocks such as `type="application/json"` never supply a declaration. Everything inside a
    /// `<template>` element (nesting tracked, with the same comment, attribute, and raw-text skipping) is inert too, so
    /// a declaration there never hides the real inline script. Input with no HTML tags is scanned whole;
    /// markup without any script yields nothing, so declarations in body text never count.
    private static func scriptBodies(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var bodies: [ArraySlice<UInt8>] = [], sawTag = false, i = 0, templateDepth = 0
        func find(_ token: String, from start: Int) -> Int? { (start..<max(start, bytes.count)).first { startsCaseInsensitive(bytes, at: $0, token) } }
        /// Index of the `>` closing the tag that opens at `start`, skipping quoted attribute values.
        func tagEnd(from start: Int) -> Int? {
            var j = start, quote: UInt8?
            while j < bytes.count {
                if let q = quote { if bytes[j] == q { quote = nil } }
                else if bytes[j] == UInt8(ascii: "\"") || bytes[j] == UInt8(ascii: "'") { quote = bytes[j] }
                else if bytes[j] == UInt8(ascii: ">") { return j }
                j += 1
            }
            return nil
        }
        /// Whether `token` (such as `<script`) starts at `at` and ends at a tag-name boundary (`>`, `/`, or whitespace).
        func tagName(_ token: String, at: Int) -> Bool {
            let after = at + token.utf8.count
            return startsCaseInsensitive(bytes, at: at, token) && (after >= bytes.count || bytes[after] == UInt8(ascii: ">") || bytes[after] == UInt8(ascii: "/") || isSpace(bytes[after]))
        }
        /// Start of the first `</name` at a tag-name boundary at or after `start`.
        func closeTag(_ name: String, from start: Int) -> Int {
            var k = start
            while let hit = find("</" + name, from: k) {
                if tagName("</" + name, at: hit) { return hit }
                k = hit + 1
            }
            return bytes.count
        }
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<"), i + 1 < bytes.count else { i += 1; continue }
            let next = bytes[i + 1]
            guard isLetter(next) || next == UInt8(ascii: "!") || next == UInt8(ascii: "/") else { i += 1; continue }
            sawTag = true
            if startsCaseInsensitive(bytes, at: i, "<!--") {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? bytes.count
                continue
            }
            guard let end = tagEnd(from: i + 1) else { break }
            if tagName("<template", at: i) { templateDepth += 1 } else if tagName("</template", at: i) { templateDepth = max(0, templateDepth - 1) }
            // HTML5 ignores `/>` on raw-text and RCDATA tags: `<textarea/>` still runs to `</textarea>`.
            if let name = rawTextTags.first(where: { tagName("<" + $0, at: i) }) {
                let close = closeTag(name, from: end + 1)
                if name == "script", templateDepth == 0, isExecutableScript(bytes[(i + 7)..<end]) { bodies.append(bytes[(end + 1)..<close]) }
                i = close < bytes.count ? (tagEnd(from: close + 1) ?? bytes.count) + 1 : bytes.count
            } else {
                i = end + 1
            }
        }
        return bodies.isEmpty && !sawTag ? [bytes[...]] : bodies
    }

    private static let executableScriptTypes: Set<String> = ["", "text/javascript", "application/javascript", "javascript", "module"]

    /// Whether the attributes of a `<script ...>` tag (the bytes after `<script` up to `>`) make it an executable inline
    /// script: no `src` attribute (with or without a value), and the first `type` attribute (unquoted, `'...'`, or
    /// `"..."`; names matched case-insensitively) is absent or, trimmed and lowercased, one of `executableScriptTypes`.
    private static func isExecutableScript(_ attributes: ArraySlice<UInt8>) -> Bool {
        let a = Array(attributes)
        var i = 0, type: String?
        while i < a.count {
            while i < a.count, isSpace(a[i]) || a[i] == UInt8(ascii: "/") { i += 1 }
            let nameStart = i
            while i < a.count, !isSpace(a[i]), a[i] != UInt8(ascii: "="), a[i] != UInt8(ascii: "/") { i += 1 }
            let name = String(decoding: a[nameStart..<i], as: UTF8.self).lowercased()
            while i < a.count, isSpace(a[i]) { i += 1 }
            var value: String?
            if i < a.count, a[i] == UInt8(ascii: "=") {
                i += 1
                while i < a.count, isSpace(a[i]) { i += 1 }
                let quote = i < a.count && (a[i] == UInt8(ascii: "\"") || a[i] == UInt8(ascii: "'")) ? a[i] : nil
                if quote != nil { i += 1 }
                let valueStart = i
                while i < a.count, quote.map({ a[i] != $0 }) ?? !isSpace(a[i]) { i += 1 }
                value = String(decoding: a[valueStart..<i], as: UTF8.self)
                if quote != nil { i += 1 }
            }
            if name == "src" { return false }
            if name == "type", type == nil { type = value ?? "" }
            if name.isEmpty && value == nil { i += 1 }
        }
        return executableScriptTypes.contains((type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func at(_ code: [UInt8], _ i: Int, _ token: String) -> Bool { code[i...].starts(with: token.utf8) }

    /// Index of the last byte of the first `end` at or after `i` (past the end of `code` when there is none).
    private static func skip(_ code: [UInt8], to end: String, from i: Int) -> Int {
        var j = i
        while j < code.count, !at(code, j, end) { j += 1 }
        return j + end.utf8.count - 1
    }

    /// A JS line terminator at `j`: LF, CR, U+2028, or U+2029.
    private static func isLineTerminator(_ code: [UInt8], _ j: Int) -> Bool {
        code[j] == 0x0A || code[j] == 0x0D || (code[j] == 0xE2 && j + 2 < code.count && code[j + 1] == 0x80 && (code[j + 2] == 0xA8 || code[j + 2] == 0xA9))
    }

    /// Index of the line terminator ending a single-line comment that starts at `i` (or the end of the code).
    private static func lineEnd(_ code: [UInt8], from i: Int) -> Int {
        var j = i
        while j < code.count, !isLineTerminator(code, j) { j += 1 }
        return j
    }

    /// Index of the first byte at or after `start` that is not whitespace, a `//` or `<!--` comment, or a `/* */` comment.
    private static func skipTrivia(in code: [UInt8], from start: Int) -> Int {
        var j = start
        while j < code.count {
            if isSpace(code[j]) { j += 1 }
            else if at(code, j, "//") || at(code, j, "<!--") { j = lineEnd(code, from: j) }
            else if at(code, j, "/*") { j = skip(code, to: "*/", from: j + 2) + 1 }
            else { break }
        }
        return min(j, code.count)
    }

    /// Single-pass JS lexer: skips `//` and `<!--` comments (through a JS line terminator: LF, CR, U+2028, or U+2029),
    /// `/* */` comments, quoted and template strings, and regular-expression literals (a `/` where an expression may
    /// start: after an operator, punctuation other than `)` or `]`, a keyword such as `return`, or at the start), and
    /// matches `let`, `variable` (both at identifier boundaries), then `=` (not `==`) in code, with whitespace and
    /// comments allowed in every gap (`skipTrivia`).
    private static func declaration(in code: [UInt8], variable: [UInt8]) -> String? {
        func at(_ i: Int, _ token: String) -> Bool { Self.at(code, i, token) }
        func isLineTerminator(_ j: Int) -> Bool { Self.isLineTerminator(code, j) }
        func lineEnd(from i: Int) -> Int { Self.lineEnd(code, from: i) }
        /// Index of the `/` closing a regular-expression literal opened at `i` (escapes and `[...]` classes skipped), or
        /// of the line terminator or end that cuts it short.
        func regexEnd(from i: Int) -> Int {
            var j = i + 1, inClass = false
            while j < code.count, !isLineTerminator(j) {
                switch code[j] {
                case UInt8(ascii: "\\"): j += 1
                case UInt8(ascii: "["): inClass = true
                case UInt8(ascii: "]"): inClass = false
                case UInt8(ascii: "/") where !inClass: return j
                default: break
                }
                j += 1
            }
            return j
        }
        /// Index just after the `=` of a declaration starting at `i`, if there is one.
        func assignment(at i: Int) -> Int? {
            guard at(i, "let"), i == 0 || !isIdentifier(code[i - 1]), i + 3 == code.count || !isIdentifier(code[i + 3]) else { return nil }
            var j = skipTrivia(in: code, from: i + 3)
            guard code[j...].starts(with: variable) else { return nil }
            j += variable.count
            guard j == code.count || !isIdentifier(code[j]) else { return nil }
            j = skipTrivia(in: code, from: j)
            guard j < code.count, code[j] == UInt8(ascii: "="), j + 1 == code.count || code[j + 1] != UInt8(ascii: "=") else { return nil }
            return j + 1
        }
        // `pendingConditionParen`: the last token was `if`, `while`, `for`, or `with`, so the next `(` opens a condition
        // whose `)` may be followed by a regex (`if (x) /re/.test(y)`); each open paren remembers that on a stack.
        var i = 0, canStartRegex = true, pendingConditionParen = false, parenRegexAfterClose: [Bool] = []
        while i < code.count {
            let byte = code[i]
            if [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`")].contains(byte) {
                i += 1
                while i < code.count, code[i] != byte { i += code[i] == UInt8(ascii: "\\") ? 2 : 1 }
                canStartRegex = false; pendingConditionParen = false
            } else if at(i, "//") || at(i, "<!--") {
                i = lineEnd(from: i)
            } else if at(i, "/*") {
                i = skip(code, to: "*/", from: i + 2)
            } else if byte == UInt8(ascii: "/"), canStartRegex {
                i = regexEnd(from: i)
                canStartRegex = false; pendingConditionParen = false
            } else if let start = assignment(at: i) {
                return balancedLiteral(code, from: start)
            } else if isIdentifier(byte) {
                var j = i
                while j < code.count, isIdentifier(code[j]) { j += 1 }
                let word = String(decoding: code[i..<j], as: UTF8.self)
                canStartRegex = regexKeywords.contains(word)
                pendingConditionParen = conditionKeywords.contains(word)
                i = j
                continue
            } else if !canStartRegex, at(i, "++") || at(i, "--") {
                // Postfix increment or decrement (`x++ / y`): an operand ends here, so a following `/` divides.
                pendingConditionParen = false
                i += 2
                continue
            } else if byte == UInt8(ascii: "(") {
                parenRegexAfterClose.append(pendingConditionParen)
                canStartRegex = true; pendingConditionParen = false
            } else if byte == UInt8(ascii: ")") {
                canStartRegex = parenRegexAfterClose.popLast() ?? false; pendingConditionParen = false
            } else if !isSpace(byte) {
                canStartRegex = byte != UInt8(ascii: "]"); pendingConditionParen = false
            }
            i += 1
        }
        return nil
    }

    /// Keywords after which a `/` starts a regular-expression literal rather than a division.
    private static let regexKeywords: Set<String> = ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]
    /// Keywords whose parenthesized condition may be followed by a regular-expression literal.
    private static let conditionKeywords: Set<String> = ["if", "while", "for", "with"]

    /// The balanced JSON array/object literal starting after optional whitespace and comments at `start`, honouring
    /// string quotes and `\` escapes so `;`, `]`, or `}` inside class titles extract intact.
    private static func balancedLiteral(_ code: [UInt8], from start: Int) -> String? {
        var idx = skipTrivia(in: code, from: start)
        guard idx < code.count, code[idx] == UInt8(ascii: "[") || code[idx] == UInt8(ascii: "{") else { return nil }
        let begin = idx
        var depth = 0, inString = false, escaped = false
        while idx < code.count {
            switch (inString, code[idx]) {
            case (true, _) where escaped: escaped = false
            case (true, UInt8(ascii: "\\")): escaped = true
            case (_, UInt8(ascii: "\"")): inString.toggle()
            case (false, UInt8(ascii: "[")), (false, UInt8(ascii: "{")): depth += 1
            case (false, UInt8(ascii: "]")), (false, UInt8(ascii: "}")):
                depth -= 1
                if depth == 0 { return String(decoding: code[begin...idx], as: UTF8.self) }
            default: break
            }
            idx += 1
        }
        return nil
    }

    private static let entities: [String: String] = [
        "&#8211;": "-", "&ndash;": "-", "&#8212;": "-", "&mdash;": "-",
        "&#8217;": "'", "&#8216;": "'", "&apos;": "'", "&#039;": "'",
        "&#8220;": "\"", "&#8221;": "\"", "&quot;": "\"",
        "&#038;": "&", "&amp;": "&", "&nbsp;": " ",
    ]

    /// Decodes the known entities in one left-to-right pass, so each `&...;` of the input is decoded once (`&amp;nbsp;`
    /// becomes `&nbsp;`, never a space); unknown entities stay as written.
    public static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            if let semi = tail.prefix(8).firstIndex(of: ";"), let decoded = entities[String(tail[...semi])] {
                out += decoded; rest = tail[tail.index(after: semi)...]
            } else {
                out += "&"; rest = tail.dropFirst()
            }
        }
        return out + rest
    }
}
