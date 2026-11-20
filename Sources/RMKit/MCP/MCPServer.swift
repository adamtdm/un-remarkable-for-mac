import Foundation
import Network

/// A tool exposed over MCP.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments.
    public let inputSchema: [String: any Sendable]
    public let run: @Sendable (MCPArgs) async throws -> MCPContent

    public init(name: String, description: String, properties: [String: [String: any Sendable]] = [:], required: [String] = [],
                run: @escaping @Sendable (MCPArgs) async throws -> MCPContent) {
        self.name = name
        self.description = description
        self.inputSchema = ["type": "object", "properties": properties, "required": required]
        self.run = run
    }

    /// Shorthand for a schema property.
    public static func prop(_ type: String, _ description: String) -> [String: any Sendable] {
        ["type": type, "description": description]
    }
}

/// Tool arguments (immutable JSON values from the request) with typed accessors.
public struct MCPArgs: @unchecked Sendable {
    let values: [String: Any]
    public init(_ values: [String: Any]) { self.values = values }
    public func string(_ key: String) -> String? { values[key] as? String }
    public func int(_ key: String) -> Int? { (values[key] as? Int) ?? (values[key] as? String).flatMap(Int.init) }
    public func bool(_ key: String) -> Bool? { (values[key] as? Bool) ?? (values[key] as? String).map { $0 == "true" } }
}

public enum MCPContent: Sendable {
    case text(String)
    case png(Data, caption: String)

    /// A JSON value, serialised straight away (results cross threads as text).
    public static func json(_ value: Any) -> MCPContent {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8)
        return .text(String(decoding: data, as: UTF8.self))
    }
}

/// Model Context Protocol over JSON-RPC 2.0: initialize, tools/list, tools/call and ping.
public final class MCPHandler: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    let tools: [String: MCPTool]
    let order: [String]
    let serverName: String
    let version: String

    public init(tools: [MCPTool], serverName: String, version: String) {
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.order = tools.map(\.name)
        self.serverName = serverName
        self.version = version
    }

    /// Handles one JSON-RPC message (or batch). Returns nil for notifications.
    public func handle(_ body: Data) async -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = obj as? [[String: Any]] {
            var out: [[String: Any]] = []
            for m in batch { if let r = await handleOne(m) { out.append(r) } }
            return out.isEmpty ? nil : Self.encode(out)
        }
        guard let msg = obj as? [String: Any] else { return Self.encode(Self.error(id: NSNull(), code: -32600, message: "Invalid request")) }
        return await handleOne(msg).map(Self.encode)
    }

    func handleOne(_ msg: [String: Any]) async -> [String: Any]? {
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"] else { return nil } // notification
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return Self.result(id: id, [
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": version],
                "instructions": "Tools for the user's reMarkable library: documents, notebooks, PDFs, tasks and meeting notes. Excluded folders are hidden.",
            ])
        case "ping":
            return Self.result(id: id, [String: Any]())
        case "tools/list":
            let list: [[String: Any]] = order.compactMap { tools[$0] }.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
            }
            return Self.result(id: id, ["tools": list])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools[name] else {
                return Self.error(id: id, code: -32602, message: "Unknown tool")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await tool.run(MCPArgs(args))
                return Self.result(id: id, ["content": Self.contentItems(content), "isError": false])
            } catch {
                return Self.result(id: id, ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func contentItems(_ c: MCPContent) -> [[String: Any]] {
        switch c {
        case .text(let s): return [["type": "text", "text": s]]
        case .png(let d, let caption):
            return [["type": "image", "data": d.base64EncodedString(), "mimeType": "image/png"], ["type": "text", "text": caption]]
        }
    }

    static func result(id: Any, _ r: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    static func encode(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v)) ?? Data() }
}

/// Minimal HTTP/1.1 server for MCP's Streamable HTTP transport (JSON responses): POST /mcp with a bearer token.
public final class MCPHTTPServer: @unchecked Sendable {
    public enum Scope: String, Sendable { case localhost, network }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "unremarkable.mcp")
    private let handler: MCPHandler
    private let token: String
    public private(set) var port: UInt16 = 0
    public var onLog: (@Sendable (String) -> Void)?

    public init(handler: MCPHandler, token: String) {
        self.handler = handler
        self.token = token
    }

    public func start(port: UInt16, scope: Scope) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if scope == .localhost {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        }
        self.port = port
        listener?.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.onLog?("MCP server failed: \(e)") }
        }
        listener?.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                Task { await self.respond(conn, req) }
            } else if done || error != nil || buf.count > 8 << 20 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) async {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        var status = 200, body = Data(), type = "application/json"
        var extra: [String: String] = [:]
        if path == "/health" {
            body = Data("{\"ok\":true}".utf8)
        } else if path != "/mcp" {
            status = 404
        } else if req.headers["authorization"] != "Bearer \(token)" {
            status = 401
            body = Data("{\"error\":\"Missing or wrong bearer token\"}".utf8)
            extra["WWW-Authenticate"] = "Bearer"
        } else if req.method == "POST" {
            if let out = await handler.handle(req.body) {
                body = out
            } else {
                status = 202
            }
            if let session = req.headers["mcp-session-id"] { extra["Mcp-Session-Id"] = session }
            else if String(decoding: req.body, as: UTF8.self).contains("\"initialize\"") { extra["Mcp-Session-Id"] = UUID().uuidString }
        } else if req.method == "DELETE" {
            status = 200
        } else {
            status = 405
            type = "text/plain"
            extra["Allow"] = "POST, DELETE"
        }
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        onLog?("MCP \(req.method) \(path) → \(status)")
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Parses a complete request (headers plus Content-Length body), or nil if more data is needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: data[bodyStart..<(bodyStart + length)])
    }
}
