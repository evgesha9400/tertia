import Foundation
import TertiaCore

/// JSON value. A parsed incoming number keeps its exact source text (`number`), so integer checks never pass through
/// floating point; outgoing responses only ever carry integers (`int`, such as error codes), and request IDs are
/// spliced in as raw text, so a parsed number is never encoded.
enum JSONValue: Encodable, Sendable, Equatable {
    case string(String), number(String), int(Int), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .number: throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Parsed numbers are input only."))
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// The exact integer a number denotes (`1.0` and `1e2` count; `1.5`, `9007199254740992.1`, and values outside `Int`
    /// do not), computed from its decimal digits and exponent without floating point.
    var intValue: Int? {
        guard case .number(let text) = self else { return nil }
        let negative = text.hasPrefix("-"), body = text.drop { $0 == "-" }
        let parts = body.split(omittingEmptySubsequences: false) { $0 == "e" || $0 == "E" }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fraction = mantissa.count > 1 ? mantissa[1] : ""
        var digits = String(mantissa[0] + fraction).drop { $0 == "0" }
        if digits.isEmpty { return 0 }
        guard let rawScale = parts.count > 1 ? Int(parts[1]) : 0 else { return nil }
        let (shifted, overflow) = rawScale.subtractingReportingOverflow(fraction.count)
        guard !overflow else { return nil }
        var scale = shifted
        while scale < 0, digits.last == "0" { digits.removeLast(); scale += 1 }
        guard scale >= 0, scale <= 20 else { return nil }
        return Int((negative ? "-" : "") + digits + String(repeating: "0", count: scale))
    }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
}

/// Strict RFC 8259 parser for one MCP line. It also captures the exact source text of the top-level `"id"` value and
/// whether that key appears more than once, so the echoed id and the parsed object can never disagree.
struct StrictJSONParser {
    struct Failure: Error {}
    private let bytes: [UInt8]
    private var i = 0
    private(set) var rawId: String?
    private(set) var duplicateId = false

    /// Parses `text` as exactly one JSON value surrounded by optional whitespace; throws `Failure` otherwise.
    static func parse(_ text: String) throws -> (value: JSONValue, rawId: String?, duplicateId: Bool) {
        var parser = StrictJSONParser(bytes: Array(text.utf8))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.i == parser.bytes.count else { throw Failure() }
        return (value, parser.rawId, parser.duplicateId)
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }
    private mutating func skipSpace() { while let b = peek, [0x20, 0x09, 0x0A, 0x0D].contains(b) { i += 1 } }
    private mutating func expect(_ byte: UInt8) throws { guard peek == byte else { throw Failure() }; i += 1 }
    private func isDigit(_ b: UInt8?) -> Bool { b.map { (0x30...0x39).contains($0) } ?? false }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < 512, let b = peek else { throw Failure() }
        switch b {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["):
            i += 1; skipSpace()
            var items: [JSONValue] = []
            if peek == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipSpace(); items.append(try value(depth: depth + 1)); skipSpace()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                try expect(UInt8(ascii: "]")); return .array(items)
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        i += 1; skipSpace()
        var members: [String: JSONValue] = [:]
        if peek == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipSpace()
            let key = try string()
            skipSpace(); try expect(UInt8(ascii: ":")); skipSpace()
            let start = i
            members[key] = try value(depth: depth + 1)
            if depth == 0, key == "id" {
                duplicateId = duplicateId || rawId != nil
                rawId = String(decoding: bytes[start..<i], as: UTF8.self)
            }
            skipSpace()
            if peek == UInt8(ascii: ",") { i += 1; continue }
            try expect(UInt8(ascii: "}")); return .object(members)
        }
    }

    private mutating func literal(_ word: String) throws {
        guard bytes[i...].starts(with: word.utf8) else { throw Failure() }
        i += word.utf8.count
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, returned as its exact text.
    private mutating func number() throws -> String {
        let start = i
        if peek == UInt8(ascii: "-") { i += 1 }
        if peek == UInt8(ascii: "0") { i += 1 } else { try digits() }
        if peek == UInt8(ascii: ".") { i += 1; try digits() }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            try digits()
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func digits() throws {
        guard isDigit(peek) else { throw Failure() }
        while isDigit(peek) { i += 1 }
    }

    /// A string with its escapes decoded; raw control characters and unpaired surrogates are rejected.
    private mutating func string() throws -> String {
        try expect(UInt8(ascii: "\""))
        var out: [UInt8] = []
        while let b = peek {
            i += 1
            switch b {
            case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
            case 0x00..<0x20: throw Failure()
            case UInt8(ascii: "\\"):
                guard let e = peek else { throw Failure() }
                i += 1
                let simple: [UInt8: UInt8] = [0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09]
                if let mapped = simple[e] { out.append(mapped); continue }
                guard e == UInt8(ascii: "u") else { throw Failure() }
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code) {
                    try expect(UInt8(ascii: "\\")); try expect(UInt8(ascii: "u"))
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low) else { throw Failure() }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { throw Failure() }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: out.append(b)
            }
        }
        throw Failure()
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16),
              bytes[i..<(i + 4)].allSatisfy({ isDigit($0) || (0x41...0x46).contains($0 & 0xDF) }) else { throw Failure() }
        i += 4
        return code
    }
}

public enum MCPServer {
    private struct Arg { let type, description: String; var options: [String] = [] }
    private struct Tool { let name, description: String; var args: [String: Arg] = [:]; var required: [String] = [] }

    /// Single source for `tools/list` schemas and `tools/call` argument validation.
    private static let tools: [Tool] = [
        Tool(name: "list_clubs", description: "List Third Space London clubs (filtered to the signed-in member's account when authenticated, or all 17 clubs when signed out)."),
        Tool(name: "get_timetable", description: "Fetch the public Third Space timetable for a club and London date (read-only).", args: [
            "club_id": Arg(type: "integer", description: "Club ID (defaults to active widget club preference)"),
            "date": Arg(type: "string", description: "YYYY-MM-DD in Europe/London"),
            "period": Arg(type: "string", description: "Day period", options: SchedulePeriod.allCases.map(\.rawValue)),
            "search": Arg(type: "string", description: "Optional title or instructor filter"),
            "refresh": Arg(type: "boolean", description: "Bypass 30-minute public cache"),
        ]),
        Tool(name: "set_widget_club", description: "Switch the active club shown in the Tertia menu-bar app and desktop widget.", args: ["club_id": Arg(type: "integer", description: "Target Third Space club ID")], required: ["club_id"]),
        Tool(name: "my_bookings", description: "List the signed-in member's upcoming bookings from local cache or live API when refresh=true.", args: ["refresh": Arg(type: "boolean", description: "Set true to fetch latest bookings from mobile API")]),
        Tool(name: "book_class", description: "Book an available (48H OPEN) Third Space class by ID using the Keychain member session.", args: ["class_id": Arg(type: "integer", description: "Class ID from get_timetable")], required: ["class_id"]),
        Tool(name: "cancel_booking", description: "Cancel a booked Third Space class by ID (set late_booking=true if the class starts in 3 hours or less).", args: [
            "class_id": Arg(type: "integer", description: "Booked class ID"),
            "late_booking": Arg(type: "boolean", description: "Acknowledge 3-hour late-cancel window"),
        ], required: ["class_id"]),
        Tool(name: "list_reminders", description: "List active local macOS class reminders (works both signed out and signed in)."),
        Tool(name: "set_reminder", description: "Schedule a local macOS Notification Center reminder before a class starts (5m to 48h). Works signed out and signed in.", args: [
            "class_id": Arg(type: "integer", description: "Class ID from get_timetable"),
            "hours": Arg(type: "integer", description: "Hours before class start (0 to 48)"),
            "minutes": Arg(type: "integer", description: "Minutes before class start (5 to 2880 total; 0 to 59 when combined with hours)"),
            "club_id": Arg(type: "integer", description: "Optional club ID when class_id appears in multiple cached clubs"),
        ], required: ["class_id"]),
        Tool(name: "remove_reminder", description: "Remove scheduled reminder(s) for a class ID (pass hours/minutes to target one lead time, or omit both to clear all).", args: [
            "class_id": Arg(type: "integer", description: "Class ID"),
            "hours": Arg(type: "integer", description: "Optional hours of a specific lead time to remove"),
            "minutes": Arg(type: "integer", description: "Optional minutes of a specific lead time to remove"),
            "club_id": Arg(type: "integer", description: "Optional club ID scope"),
        ], required: ["class_id"]),
    ]

    /// One stdin line (strict UTF-8), a line that is not valid UTF-8, a line longer than the cap (its bytes were
    /// drained through the next `\n`), or EOF before any byte.
    public enum BoundedLineResult: Equatable, Sendable { case line(String), invalidUTF8, overflow, eof }

    /// Reads bytes from `nextByte` through the next `\n`. A line longer than `maxLineBytes` is never buffered: the rest
    /// of it is drained and `.overflow` returned, so the next call starts on the following line.
    public static func readBoundedLine(maxLineBytes: Int = 1_048_576, nextByte: () -> UInt8?) -> BoundedLineResult {
        var bytes: [UInt8] = [], overflow = false, sawByte = false
        while let byte = nextByte() {
            sawByte = true
            if byte == 0x0A { break }
            if overflow { continue }
            if bytes.count >= maxLineBytes { overflow = true; bytes = [] } else { bytes.append(byte) }
        }
        guard sawByte else { return .eof }
        return overflow ? .overflow : String(bytes: bytes, encoding: .utf8).map(BoundedLineResult.line) ?? .invalidUTF8
    }

    private static let invalidUTF8Response = response(id: "null", error: (-32700, "Parse error: invalid UTF-8"))

    public static func run(store: SharedStateStore, keychain: KeychainStore = KeychainStore(), client: PublicTimetableClient, bookingClient: MobileBookingClient = MobileBookingClient(),
                           reminderScheduler: (any ReminderScheduler)? = nil, onStateChanged: @Sendable () -> Void = {}, maxLineBytes: Int = 1_048_576) async {
        while true {
            let out: String?
            switch readBoundedLine(maxLineBytes: maxLineBytes, nextByte: { let c = getchar(); return c == EOF ? nil : UInt8(truncatingIfNeeded: c) }) {
            case .eof: return
            case .line(let line): out = await handleLine(line, store: store, keychain: keychain, client: client, bookingClient: bookingClient, reminderScheduler: reminderScheduler, onStateChanged: onStateChanged)
            case .invalidUTF8: out = invalidUTF8Response
            case .overflow: out = response(id: "null", error: (-32600, "Invalid Request: line exceeded maximum size"))
            }
            if let out { print(out); fflush(stdout) }
        }
    }

    public static func handleLine(_ rawLine: String, store: SharedStateStore, keychain: KeychainStore = KeychainStore(), client: PublicTimetableClient, bookingClient: MobileBookingClient = MobileBookingClient(), reminderScheduler: (any ReminderScheduler)? = nil, onStateChanged: @Sendable () -> Void = {}) async -> String? {
        // Only RFC 8259 whitespace (space, tab, LF, CR) makes a blank line; the line is parsed untrimmed, so other
        // Unicode whitespace such as U+00A0 is a parse error.
        if rawLine.utf8.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return nil }
        guard let parsed = try? StrictJSONParser.parse(rawLine) else { return response(id: "null", error: (-32700, "Parse error")) }
        // Duplicate top-level "id" keys are rejected, so the echoed id text and the parsed object can never disagree.
        guard case .object(let obj) = parsed.value, !parsed.duplicateId else { return response(id: "null", error: (-32600, "Invalid Request")) }
        switch obj["id"] {
        case nil, .number?, .string?, .null?: break
        default: return response(id: "null", error: (-32600, "Invalid Request"))
        }
        // The id is echoed as its exact JSON text, so distinct high-precision numbers never collide after rounding.
        let rawId = parsed.rawId
        guard obj["jsonrpc"]?.stringValue == "2.0", let method = obj["method"]?.stringValue, !method.isEmpty else {
            return response(id: rawId ?? "null", error: (-32600, "Invalid Request"))
        }
        // Only a missing "id" key marks a notification (no response); any request with an "id" (even null, even a
        // `notifications/*` method) gets a response.
        guard let id = rawId else { return nil }
        var params: [String: JSONValue] = [:]
        if let rawParams = obj["params"] {
            guard let object = rawParams.objectValue else { return response(id: id, error: (-32602, "Invalid params")) }
            params = object
        }

        switch method {
        case "initialize":
            guard let proto = params["protocolVersion"]?.stringValue, !proto.isEmpty, params["capabilities"]?.objectValue != nil,
                  let clientInfo = params["clientInfo"]?.objectValue, clientInfo["name"]?.stringValue?.isEmpty == false
            else { return response(id: id, error: (-32602, "Invalid params: initialize requires protocolVersion, capabilities, and clientInfo.name")) }
            return response(id: id, result: .object([
                "protocolVersion": .string("2024-11-05"), "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("tertia"), "version": .string(TertiaCLI.version)]),
            ]))
        case "ping":
            return response(id: id, result: .object([:]))
        case "tools/list":
            return response(id: id, result: .object(["tools": .array(tools.map(toolSpec))]))
        case "tools/call":
            guard let name = params["name"]?.stringValue, !name.isEmpty else { return response(id: id, error: (-32602, "Invalid params: name must be a non-empty string")) }
            var args: [String: JSONValue] = [:]
            if let rawArgs = params["arguments"] { // only an omitted key defaults to no arguments; `null` is rejected
                guard let object = rawArgs.objectValue else { return response(id: id, error: (-32602, "Invalid params: arguments must be an object")) }
                args = object
            }
            // Unknown tools and invalid arguments are protocol errors; `isError` results are reserved for tools that ran and failed.
            guard let tool = tools.first(where: { $0.name == name }) else { return response(id: id, error: (-32602, "Invalid params: unknown tool '\(name)'")) }
            if let problem = validationError(args, for: tool) { return response(id: id, error: (-32602, "Invalid params: \(problem)")) }
            return response(id: id, result: await handleToolCall(name: name, args: args, store: store, keychain: keychain, client: client, bookingClient: bookingClient, reminderScheduler: reminderScheduler, onStateChanged: onStateChanged))
        default:
            return response(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private static func toolSpec(_ tool: Tool) -> JSONValue {
        let properties = tool.args.mapValues { arg -> JSONValue in
            var prop: [String: JSONValue] = ["type": .string(arg.type), "description": .string(arg.description)]
            if !arg.options.isEmpty { prop["enum"] = .array(arg.options.map(JSONValue.string)) }
            return .object(prop)
        }
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false)]
        if !tool.required.isEmpty { schema["required"] = .array(tool.required.map(JSONValue.string)) }
        return .object(["name": .string(tool.name), "description": .string(tool.description), "inputSchema": .object(schema)])
    }

    /// Rejects unknown keys, wrong value types, values outside an `enum`, and missing required keys before any side effect.
    private static func validationError(_ args: [String: JSONValue], for tool: Tool) -> String? {
        for (key, value) in args.sorted(by: { $0.key < $1.key }) {
            guard let arg = tool.args[key] else { return "Unknown argument '\(key)' for \(tool.name)." }
            let valid = switch arg.type {
            case "integer": value.intValue != nil
            case "boolean": value.boolValue != nil
            default: value.stringValue != nil
            }
            if !valid { return "Argument '\(key)' must be of type \(arg.type)." }
            if !arg.options.isEmpty, !(value.stringValue.map(arg.options.contains) ?? false) {
                return "Argument '\(key)' must be one of: \(arg.options.joined(separator: ", "))."
            }
        }
        return tool.required.first { args[$0] == nil }.map { "Missing required argument '\($0)'." }
    }

    private static func handleToolCall(name: String, args: [String: JSONValue], store: SharedStateStore, keychain: KeychainStore, client: PublicTimetableClient, bookingClient: MobileBookingClient, reminderScheduler: (any ReminderScheduler)?, onStateChanged: @Sendable () -> Void) async -> JSONValue {
        do {
            switch name {
            case "list_clubs":
                let result = try TertiaCLI.availableClubsWithWarning(store: store, keychain: keychain)
                let note = result.warning.map { "warning: \($0.localizedDescription)" }
                if let note { writeStderr(note) }
                return toolText(encodePrettyJSON(result.clubs), note: note)

            case "get_timetable":
                let (snap, date, classes) = try await TertiaCLI.queryTimetable(
                    clubId: args["club_id"]?.intValue, date: args["date"]?.stringValue, period: args["period"]?.stringValue,
                    search: args["search"]?.stringValue, refresh: args["refresh"]?.boolValue ?? false, store: store, client: client)
                struct Payload: Encodable { let clubId: Int; let clubName, date: String; let classes: [ClassSession] }
                return toolText(encodePrettyJSON(Payload(clubId: snap.clubId, clubName: snap.clubName, date: date, classes: classes)))

            case "set_widget_club":
                guard let clubId = args["club_id"]?.intValue, clubId > 0,
                      let (club, warning) = try await TertiaCLI.applyWidgetClub(clubId: clubId, store: store, keychain: keychain, client: client, onStateChanged: onStateChanged)
                else { return toolText("Club ID is unavailable for the current account. Call list_clubs first.", isError: true) }
                return toolText("Widget club updated to \(club.name) (id=\(club.id)).\(warning ?? "")")

            case "my_bookings":
                let result = try await TertiaCLI.memberBookings(refresh: args["refresh"]?.boolValue ?? false, store: store, keychain: keychain, bookingClient: bookingClient, onStateChanged: onStateChanged)
                return toolText(encodePrettyJSON(result.snapshot), note: result.warning.map { "warning:\($0)" })

            case "list_reminders":
                return toolText(encodePrettyJSON(TertiaCLI.listReminders(store: store)))

            case "set_reminder":
                guard let classId = args["class_id"]?.intValue, classId > 0 else { return toolText("class_id must be a positive integer.", isError: true) }
                let clubId = args["club_id"]?.intValue
                if let clubId, clubId <= 0 { return toolText("club_id must be a positive integer.", isError: true) }
                let lead = try ClassReminder.leadMinutes(hours: args["hours"]?.intValue, minutes: args["minutes"]?.intValue)
                let res = try await TertiaCLI.setReminder(classId: classId, clubId: clubId, leadMinutes: lead, store: store, keychain: keychain,
                                                          client: client, reminderScheduler: reminderScheduler, onStateChanged: onStateChanged)
                return toolText(encodePrettyJSON(res.reminder), note: TertiaCLI.reminderSyncNote(res.syncStatus))

            case "remove_reminder":
                guard let classId = args["class_id"]?.intValue, classId > 0 else { return toolText("class_id must be a positive integer.", isError: true) }
                let clubId = args["club_id"]?.intValue
                if let clubId, clubId <= 0 { return toolText("club_id must be a positive integer.", isError: true) }
                let h = args["hours"]?.intValue, m = args["minutes"]?.intValue
                let lead: Int? = (h != nil || m != nil) ? try ClassReminder.leadMinutes(hours: h, minutes: m) : nil
                let res = try await TertiaCLI.removeReminder(classId: classId, clubId: clubId, leadMinutes: lead, store: store,
                                                             reminderScheduler: reminderScheduler, onStateChanged: onStateChanged)
                return toolText("Removed \(res.removed) reminder(s) for class \(classId).", note: TertiaCLI.reminderSyncNote(res.syncStatus))

            default: // book_class, cancel_booking
                guard let classId = args["class_id"]?.intValue, classId > 0 else { return toolText("class_id must be a positive integer.", isError: true) }
                return toolText(try await TertiaCLI.performMutation(
                    classId: classId, isCancel: name == "cancel_booking", late: args["late_booking"]?.boolValue ?? false,
                    store: store, keychain: keychain, client: client, bookingClient: bookingClient, onStateChanged: onStateChanged))
            }
        } catch {
            return toolText(error.localizedDescription, isError: true)
        }
    }

    /// `note` (such as a widget-mirror warning) follows as a second text item, so `text` stays parseable JSON.
    private static func toolText(_ text: String, isError: Bool = false, note: String? = nil) -> JSONValue {
        let items = ([text] + [note].compactMap { $0 }).map { JSONValue.object(["type": .string("text"), "text": .string($0)]) }
        return .object(["content": .array(items), "isError": .bool(isError)])
    }

    /// `id` is raw JSON text spliced in verbatim ahead of the encoded members.
    private static func response(id: String, result: JSONValue? = nil, error: (Int, String)? = nil) -> String? {
        var payload: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        if let result { payload["result"] = result }
        if let error { payload["error"] = .object(["code": .int(error.0), "message": .string(error.1)]) }
        guard let body = (try? JSONEncoder().encode(JSONValue.object(payload))).flatMap({ String(data: $0, encoding: .utf8) }), body.hasPrefix("{") else { return nil }
        return "{\"id\":\(id)," + body.dropFirst()
    }
}
