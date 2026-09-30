import Foundation
import AppKit
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1

/// Diptych's embedded MCP server: while enabled, listens on 127.0.0.1 and
/// answers `list_windows` / `get_pane` / `get_selection` with the app's live,
/// in-memory session state -- open windows, what each pane is browsing, what
/// is selected. None of this exists anywhere bash could read it from; that is
/// the whole reason for this to exist rather than telling an agent to run a
/// shell command. See DIPTYCH_MCP_PROPOSAL.md.
///
/// `StatefulHTTPServerTransport` (the SDK's transport) is deliberately
/// framework-agnostic -- it converts protocol messages, not bytes on a
/// socket -- so this type is the part that actually listens: a small SwiftNIO
/// HTTP server that hands each request to the transport and writes back
/// whatever it returns. One MCP `Server` (and one transport) per HTTP
/// session, exactly as the SDK expects.
actor MCPServer {

    static let shared = MCPServer()

    private struct SessionContext {
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    let endpoint = "/mcp"
    private let sessionTimeout: TimeInterval = 3600

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private var listeningPort: Int?
    private var token = ""
    private var cleanupTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle, driven by ConfigStore

    /// Called whenever `mcpServerEnabled` or `mcpServerPort` changes, and once
    /// at launch if the setting was already on. Safe to call repeatedly with
    /// the same values -- an already-listening server on the same port is
    /// left alone rather than being torn down and restarted.
    func applyConfiguration(enabled: Bool, port: Int, token: String) async {
        self.token = token
        guard enabled else {
            await stop()
            return
        }
        if listeningPort == port, channel != nil { return }
        await stop()
        do {
            try await start(port: port)
            listeningPort = port
        } catch {
            // Nobody is listening for this synchronously -- the toggle in
            // Settings already flipped -- so this is a log line, not an
            // error surfaced through the model. Reads back as "off" (no
            // channel), which is honest: it isn't listening.
            NSLog("Diptych MCP server: failed to listen on 127.0.0.1:\(port): \(error)")
        }
    }

    /// Stops listening, for app termination -- distinct from
    /// `applyConfiguration(enabled: false, ...)` only in not asking a caller
    /// to invent a throwaway port and token for a call that ignores both.
    func shutdown() async {
        await stop()
    }

    private func start(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(MCPError.internalError("server gone"))
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(server: self))
                }
            }

        channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        cleanupTask = Task { [weak self] in await self?.sessionCleanupLoop() }
    }

    private func stop() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        for (_, session) in sessions { await session.transport.disconnect() }
        sessions.removeAll()
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
        listeningPort = nil
    }

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            let now = Date()
            let expired = sessions.filter { now.timeIntervalSince($0.value.lastAccessedAt) > sessionTimeout }
            for (id, session) in expired {
                await session.transport.disconnect()
                sessions.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Request routing

    /// Entry point from the NIO handler. Every request needs the bearer
    /// token, checked before any session lookup or MCP protocol handling --
    /// nothing past this point should be reachable without it.
    fileprivate func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard !token.isEmpty, request.header(HTTPHeaderName.authorization) == "Bearer \(token)" else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"))
        }

        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Missing \(HTTPHeaderName.sessionID) header"))
    }

    /// `JSONRPCMessageKind`, the SDK's own way of answering this, is
    /// package-internal -- not visible outside the SDK's own module -- so
    /// this reads the method name straight out of the JSON-RPC envelope
    /// instead. Handles both a lone request object and a batch array, since
    /// the Streamable HTTP spec allows a POST body to be either.
    private static func isInitializeRequest(_ body: Data) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            return (object["method"] as? String) == "initialize"
        }
        if let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] {
            return array.contains { ($0["method"] as? String) == "initialize" }
        }
        return false
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID))
        let server = await Self.makeToolServer()

        do {
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(transport: transport, lastAccessedAt: Date())
            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500,
                          .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }
}

// MARK: - NIO adapter

/// Thin NIO-to-`HTTPRequest`/`HTTPResponse` adapter. Everything that
/// understands MCP lives in `MCPServer`; this only speaks NIO on one side and
/// the SDK's framework-agnostic types on the other, matching the shape the
/// SDK's own reference server uses for the same purpose.
private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: MCPServer

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }
    private var requestState: RequestState?

    init(server: MCPServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestState = RequestState(head: head,
                                        bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            Task { await self.respond(to: state, context: ctx) }
        }
    }

    private func respond(to state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        guard await path == server.endpoint else {
            await write(.error(statusCode: 404, .invalidRequest("Not Found")),
                       version: head.version, context: context)
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            if let existing = headers[name] { headers[name] = existing + ", " + value }
            else { headers[name] = value }
        }
        var bodyBuffer = state.bodyBuffer
        let body: Data? = bodyBuffer.readableBytes > 0
            ? bodyBuffer.readBytes(length: bodyBuffer.readableBytes).map { Data($0) }
            : nil

        let request = HTTPRequest(method: head.method.rawValue, headers: headers, body: body, path: path)
        let response = await server.handleHTTPRequest(request)
        await write(response, version: head.version, context: context)
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion,
                        context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        switch response {
        case .stream(let stream, let headers):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version,
                                            status: HTTPResponseStatus(statusCode: response.statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch { /* stream ended with an error; close below regardless */ }
            eventLoop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version,
                                            status: HTTPResponseStatus(statusCode: response.statusCode))
                for (name, value) in response.headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: bodyData.count)
                    buffer.writeBytes(bodyData)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

// MARK: - Tool server

extension MCPServer {

    /// A fresh MCP `Server`, one per HTTP session, with the three read-only
    /// tools registered. Cheap to build: the handlers close over no
    /// per-session state of their own, only live `AppModel` state read fresh
    /// on every call.
    fileprivate static func makeToolServer() async -> Server {
        let server = Server(
            name: "diptych",
            version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0",
            instructions: "Diptych is a dual-pane macOS file manager. These tools read its live "
                + "session -- open windows, what each pane is browsing, what's selected -- none "
                + "of which is visible any other way. They do not read or write file contents.",
            capabilities: Server.Capabilities(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(name: "list_windows",
                     description: "Every open Diptych window: the two-pane browser windows, each "
                        + "with its pane directories and which side is active, plus any Info, "
                        + "Compare, Bin Edit, Text Edit or Rename Many windows, each with what "
                        + "it's showing.",
                     inputSchema: .object(["type": "object", "properties": [:]])),
                Tool(name: "get_pane",
                     description: "A pane's current directory and listing.",
                     inputSchema: .object([
                        "type": "object",
                        "properties": [
                            "windowId": [
                                "type": "string",
                                "description": "From list_windows. Defaults to the frontmost Diptych window.",
                            ],
                            "side": [
                                "type": "string",
                                "enum": ["left", "right", "active"],
                                "description": "Defaults to \"active\".",
                            ],
                        ],
                     ])),
                Tool(name: "get_selection",
                     description: "The files currently selected in a pane.",
                     inputSchema: .object([
                        "type": "object",
                        "properties": [
                            "windowId": [
                                "type": "string",
                                "description": "From list_windows. Defaults to the frontmost Diptych window.",
                            ],
                            "side": [
                                "type": "string",
                                "enum": ["left", "right", "active"],
                                "description": "Defaults to \"active\".",
                            ],
                        ],
                     ])),
                Tool(name: "set_active_pane",
                     description: "Makes a window's left or right pane the active (focused) one.",
                     inputSchema: .object([
                        "type": "object",
                        "properties": [
                            "windowId": [
                                "type": "string",
                                "description": "From list_windows. Defaults to the frontmost Diptych window.",
                            ],
                            "side": ["type": "string", "enum": ["left", "right"]],
                        ],
                        "required": ["side"],
                     ])),
                Tool(name: "close_window",
                     description: "Closes a Diptych window (browser, Text Edit, Bin Edit, "
                        + "Compare, Get Info, Rename Many, or Settings). Runs the same "
                        + "unsaved-changes prompt Cmd-W would, rather than discarding edits.",
                     inputSchema: .object([
                        "type": "object",
                        "properties": [
                            "windowNumber": [
                                "type": "integer",
                                "description": "From list_windows' windowNumber field.",
                            ],
                        ],
                        "required": ["windowNumber"],
                     ])),
                Tool(name: "select_items",
                     description: "Replaces a pane's selection with exactly these paths, "
                        + "visibly reflected in the GUI -- for \"select the 5 largest files\" "
                        + "style requests, not just answering questions about the selection.",
                     inputSchema: .object([
                        "type": "object",
                        "properties": [
                            "windowId": [
                                "type": "string",
                                "description": "From list_windows. Defaults to the frontmost Diptych window.",
                            ],
                            "side": [
                                "type": "string",
                                "enum": ["left", "right", "active"],
                                "description": "Defaults to \"active\".",
                            ],
                            "paths": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "Absolute paths to select. Any not present in the pane are ignored.",
                            ],
                        ],
                        "required": ["paths"],
                     ])),
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            let windowId = params.arguments?["windowId"]?.stringValue
            let side = params.arguments?["side"]?.stringValue

            switch params.name {
            case "select_items":
                let paths = params.arguments?["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let found = await MainActor.run {
                    MCPToolSupport.selectItems(windowId: windowId, side: side, paths: paths)
                }
                return .init(content: [.text(
                    text: found ? "Selected \(paths.count) path(s) (any not present in the pane were ignored)."
                                : "No matching Diptych window is open.",
                    annotations: nil, _meta: nil)], isError: !found)

            case "set_active_pane":
                guard let activeSide = params.arguments?["side"]?.stringValue,
                      activeSide == "left" || activeSide == "right" else {
                    return .init(content: [.text(text: "side must be \"left\" or \"right\".",
                                                 annotations: nil, _meta: nil)], isError: true)
                }
                let found = await MainActor.run {
                    MCPToolSupport.setActivePane(windowId: windowId, side: activeSide)
                }
                return .init(content: [.text(
                    text: found ? "Active pane set to \(activeSide)."
                                : "No matching Diptych window is open.",
                    annotations: nil, _meta: nil)], isError: !found)

            case "close_window":
                guard let windowNumber = params.arguments?["windowNumber"]?.intValue else {
                    return .init(content: [.text(text: "windowNumber is required.",
                                                 annotations: nil, _meta: nil)], isError: true)
                }
                let found = await MainActor.run { MCPToolSupport.closeWindow(windowNumber: windowNumber) }
                return .init(content: [.text(
                    text: found ? "Closed (or asked to close) window \(windowNumber)."
                                : "No open window has number \(windowNumber).",
                    annotations: nil, _meta: nil)], isError: !found)

            case "list_windows":
                let list = await MainActor.run {
                    MCPModels.WindowList(windows: MCPToolSupport.listWindows(),
                                         toolWindows: MCPToolSupport.listToolWindows())
                }
                return try MCPModels.result(for: list)

            case "get_pane":
                guard let snapshot = await MainActor.run(body: {
                    MCPToolSupport.pane(windowId: windowId, side: side)
                }) else {
                    return .init(content: [.text(text: "No matching Diptych window is open.",
                                                 annotations: nil, _meta: nil)], isError: true)
                }
                return try MCPModels.result(for: snapshot)

            case "get_selection":
                guard let snapshot = await MainActor.run(body: {
                    MCPToolSupport.selection(windowId: windowId, side: side)
                }) else {
                    return .init(content: [.text(text: "No matching Diptych window is open.",
                                                 annotations: nil, _meta: nil)], isError: true)
                }
                return try MCPModels.result(for: snapshot)

            default:
                return .init(content: [.text(text: "Unknown tool: \(params.name)",
                                             annotations: nil, _meta: nil)], isError: true)
            }
        }

        return server
    }
}
