import Foundation
import QuillKit

// Quill's MCP server — a real one, not a description of one. Claude Desktop
// spawns this over stdio (see the connection instructions on the Account
// tab, or `Sources/QuillMCP/README` for the config snippet) and talks
// JSON-RPC 2.0 to it, one message per line.
//
// Deliberately narrow: one tool, and it hands over the same thing the
// dashboard's "Copy for AI" button already writes to a file — writing
// style, learned patterns, real dictation examples. Nothing here reads or
// sends email; that access, if Claude has it at all, is granted to Claude
// separately and is none of this server's business. See `VoiceExport` for
// the actual content and `SyncEngine`'s doc comment for the same boundary
// stated from the account side.
//
// Requires a signed-in account (`AccountStore`), because that is the
// feature this unlocks — see `OnboardingWindow`'s account step and
// `AccountSectionView`'s "Synced to your account" card for why the two are
// already the same boundary elsewhere in this app.

// MARK: - Wire format

/// Whatever the client sent for `id` — number, string, or absent — echoed
/// back exactly. A notification (no `id` at all) gets no response; getting
/// this wrong either leaves Claude Desktop waiting on a reply that never
/// comes or sends one it never asked for.
enum RPCID {
    case number(Int)
    case string(String)
    case null
    case none

    static func from(_ raw: Any?) -> RPCID {
        switch raw {
        case let n as Int: return .number(n)
        case let n as NSNumber: return .number(n.intValue)
        case let s as String: return .string(s)
        case is NSNull: return .null
        case .some: return .null
        case .none: return .none
        }
    }

    var jsonValue: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        case .null, .none: return NSNull()
        }
    }
}

/// Every write to stdout goes through here, and nowhere else in this file
/// writes to stdout — the transport IS the stream, and one stray `print`
/// debugging a tool call is a corrupted message from Claude Desktop's side,
/// not a log line. `FileHandle.standardError` is where diagnostics go.
func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func respond(id: RPCID, result: [String: Any]) {
    guard case .none = id else {
        send(["jsonrpc": "2.0", "id": id.jsonValue, "result": result])
        return
    }
    // A notification has no id and gets no reply — responding to one is
    // itself a protocol violation.
}

func respondError(id: RPCID, code: Int, message: String) {
    guard case .none = id else {
        send(["jsonrpc": "2.0", "id": id.jsonValue, "error": ["code": code, "message": message]])
        return
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data(("[quill-mcp] " + message + "\n").utf8))
}

// MARK: - Tools

enum Tools {
    static let writingVoiceName = "get_writing_voice"

    static let list: [[String: Any]] = [
        [
            "name": writingVoiceName,
            "description": "How this person writes: learned patterns (spelling, contractions, "
                + "formality, sentence length) plus real excerpts of things they have actually "
                + "dictated, oldest first. Use this when asked to write, draft, or reply AS this "
                + "person, in their voice — not as a source of facts about them.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
    ]

    /// `content` + `isError`, MCP's own shape for "the tool ran, and here is
    /// what happened" — a signed-out Mac is not a protocol failure, it is an
    /// answer Claude can read and relay: "ask them to sign in."
    static func call(_ name: String) -> (content: String, isError: Bool) {
        guard name == writingVoiceName else {
            return ("No tool named \"\(name)\".", true)
        }
        guard AccountStore.shared.current != nil else {
            return ("Quill is not signed into an account on this Mac. Open Quill, "
                    + "go to Account, and sign in or create one — this tool needs that "
                    + "to know whose voice to hand over.", true)
        }
        let text = VoiceExport.markdown(profile: StyleStore.shared.profile, records: HistoryStore().all)
        return (text, false)
    }
}

// MARK: - Loop

log("starting")

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = request["method"] as? String
    else {
        log("unparseable line, ignored: \(line.prefix(120))")
        continue
    }
    let id = RPCID.from(request["id"])

    switch method {
    case "initialize":
        respond(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "quill", "version": "1.0.0"],
        ])

    case "notifications/initialized", "notifications/cancelled":
        break // Notifications. No reply, ever.

    case "tools/list":
        respond(id: id, result: ["tools": Tools.list])

    case "tools/call":
        guard let params = request["params"] as? [String: Any],
              let toolName = params["name"] as? String
        else {
            respondError(id: id, code: -32602, message: "Missing tool name.")
            continue
        }
        let (text, isError) = Tools.call(toolName)
        respond(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ])

    case "ping":
        respond(id: id, result: [String: Any]())

    default:
        respondError(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

log("stdin closed, exiting")
