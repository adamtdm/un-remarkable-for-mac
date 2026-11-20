import AppKit
import Foundation
import RMKit

/// `Unremarkable --mcp-stdio`: for MCP clients that launch a command (Claude Desktop and others).
/// Relays newline-delimited JSON-RPC from stdin to the running app's HTTP endpoint and prints the replies.
/// Starts the app in the background if it isn't running.
enum MCPStdioBridge {
    static func run() -> Never {
        let defaults = UserDefaults.standard // the app's own domain when run from its bundle
        let port = defaults.integer(forKey: "mcpPort") == 0 ? Int(MCPService.defaultPort) : defaults.integer(forKey: "mcpPort")
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let token = Secrets.get("mcp-token") ?? ""
        var session: String?
        ensureRunning(url: url)

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = Data(line.utf8)
            let (data, response) = send(req)
            if let s = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") { session = s }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, !data.isEmpty {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            } else if status != 202, let id = idOf(line) {
                let message = status == 401 ? "Wrong MCP token" : "Un-remarkable isn't reachable (status \(status)). Is it running with MCP turned on?"
                let err: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
                if let d = try? JSONSerialization.data(withJSONObject: err) { FileHandle.standardOutput.write(d + Data("\n".utf8)) }
            }
        }
        exit(0)
    }

    static func send(_ req: URLRequest) -> (Data?, URLResponse?) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Data?, URLResponse?) = (nil, nil)
        URLSession.shared.dataTask(with: req) { d, r, _ in out = (d, r); done.signal() }.resume()
        done.wait()
        return out
    }

    static func idOf(_ line: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"]
    }

    /// Launches the app (hidden) if its server doesn't answer, and waits up to 20 s for it.
    static func ensureRunning(url: URL) {
        let health = URL(string: url.absoluteString.replacingOccurrences(of: "/mcp", with: "/health"))!
        func up() -> Bool { (send(URLRequest(url: health, timeoutInterval: 2)).1 as? HTTPURLResponse)?.statusCode == 200 }
        if up() { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", "com.unremarkable.mac"]
        try? open.run()
        for _ in 0..<40 where !up() { Thread.sleep(forTimeInterval: 0.5) }
    }
}
