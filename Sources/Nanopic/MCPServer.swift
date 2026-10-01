import AppKit
import Foundation
import NanopicCore
import Network

/// エージェントから nanopic を操作するための MCP サーバー（Streamable HTTP、127.0.0.1 だけで待ち受ける）。
///
/// Claude Code なら `claude mcp add --transport http nanopic http://127.0.0.1:<port>/mcp` で使える。
/// POST された JSON-RPC にそのまま JSON で答える。サーバーからの通知はしないので、GET（SSE）は 405 を返す。
final class MCPServer {
    static let defaultPort: UInt16 = 47823

    private let toolbox: AgentToolbox
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nanopic.mcp")
    private(set) var port: UInt16 = 0
    /// 状態が変わったら（メインスレッドで）呼ぶ
    var onStatusChange: ((String) -> Void)?

    init(toolbox: AgentToolbox) {
        self.toolbox = toolbox
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    func start(port: UInt16) {
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                let text: String
                switch st {
                case .ready: text = "待ち受け中: \(self.endpoint)"
                case let .failed(e): text = "起動できませんでした: \(e)"
                case .cancelled: text = "停止中"
                default: return
                }
                DispatchQueue.main.async { self.onStatusChange?(text) }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onStatusChange?("起動できませんでした: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {
                self.respond(c, to: req)
            } else if done || error != nil || buf.count > 64 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, to req: HTTPRequest) {
        func send(_ status: String, _ body: Data = Data(), type: String = "application/json") {
            var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            if !body.isEmpty { head += "Content-Type: \(type)\r\n" }
            var out = Data((head + "\r\n").utf8)
            out.append(body)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
        // 別のサイトのページから localhost を叩かれないよう、ブラウザの Origin は localhost だけ通す
        if let origin = req.headers["origin"], let host = URL(string: origin)?.host, !["localhost", "127.0.0.1"].contains(host) {
            return send("403 Forbidden")
        }
        guard req.path.hasPrefix("/mcp") else { return send("404 Not Found") }
        guard req.method == "POST" else { return send("405 Method Not Allowed") }
        guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
            return send("400 Bad Request", Self.encode(Self.error(nil, -32700, "JSON として読めません")))
        }
        let replies: [[String: Any]]
        if let batch = json as? [[String: Any]] {
            replies = batch.compactMap(handle)
        } else if let msg = json as? [String: Any] {
            replies = handle(msg).map { [$0] } ?? []
        } else {
            return send("400 Bad Request", Self.encode(Self.error(nil, -32600, "JSON-RPC のメッセージではありません")))
        }
        if replies.isEmpty { return send("202 Accepted") }
        send("200 OK", Self.encode(json is [Any] ? replies : replies[0]))
    }

    // MARK: - JSON-RPC

    private func handle(_ msg: [String: Any]) -> [String: Any]? {
        guard let method = msg["method"] as? String else { return nil } // 応答やおかしなものは無視
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        if id == nil { return nil } // 通知
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            return Self.result(id, [
                "protocolVersion": supported.contains(requested ?? "") ? requested! : supported[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nanopic", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": AgentToolbox.instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            let tools = onMain { self.toolbox.tools }
            return Self.result(id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.error(id, -32602, "name がありません") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let out: Result<[AgentContent], Error> = onMain { Result { try self.toolbox.call(name, args) } }
            switch out {
            case let .success(contents):
                return Self.result(id, ["content": contents.map(Self.content)])
            case let .failure(e):
                return Self.result(id, ["content": [["type": "text", "text": "\(e)"]], "isError": true])
            }
        default:
            return Self.error(id, -32601, "知らないメソッドです: \(method)")
        }
    }

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private static func content(_ c: AgentContent) -> [String: Any] {
        switch c {
        case let .text(t): return ["type": "text", "text": t]
        case let .png(d): return ["type": "image", "data": d.base64EncodedString(), "mimeType": "image/png"]
        }
    }

    private static func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r]
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func encode(_ v: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes])) ?? Data()
    }
}

/// 受け取ったバイト列から HTTP リクエストを読む（本文がそろっていなければ nil）
private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = String(first[0])
        path = String(first[1])
        headers = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = Data(data[bodyStart..<(bodyStart + length)])
    }
}
