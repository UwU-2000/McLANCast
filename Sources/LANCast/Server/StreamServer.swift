import Foundation
import Network
import CryptoKit

/// A small embedded HTTP + WebSocket server.
///
/// - `GET /` serves the MSE player page.
/// - `GET /ws` upgrades to a WebSocket and receives, in order: a JSON `init`
///   message (with the MSE MIME type), the fMP4 initialization segment, then a
///   continuous stream of media segments.
///
/// Implemented directly on `Network.framework` so the app has no third-party
/// dependencies. WebSocket framing (server -> client, unmasked) is built by hand.
final class StreamServer {

    private let queue = DispatchQueue(label: "lancast.server")
    private var listener: NWListener?

    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var httpBuffers: [ObjectIdentifier: Data] = [:]
    private var wsBuffers: [ObjectIdentifier: Data] = [:]

    // Per-connection metadata.
    private var clientIds: [ObjectIdentifier: String] = [:]
    private var clientNames: [ObjectIdentifier: String] = [:]
    private var remoteIPs: [ObjectIdentifier: String] = [:]
    private var viewOnly: [ObjectIdentifier: Bool] = [:]
    private var lastPong: [ObjectIdentifier: Date] = [:]
    /// Connections that have passed the password gate (always true when no
    /// password is configured). Only authed connections receive the stream and
    /// count as viewers.
    private var authed: Set<ObjectIdentifier> = []

    // Single active controller (only one client controls the host at a time).
    private var activeControllerOID: ObjectIdentifier?
    private(set) var activeControllerClientId: String?

    private var cachedInitMime: String?
    private var cachedInitSegment: Data?

    private var password: String = ""
    private var controlMasterEnabled = true

    private var heartbeat: DispatchSourceTimer?

    private static let wsMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let heartbeatInterval: TimeInterval = 5
    private static let pongTimeout: TimeInterval = 15

    private(set) var boundPort: UInt16 = 0

    // MARK: - Callbacks

    /// Fired (on the main queue) whenever the viewer count changes.
    var onViewerCountChanged: ((Int) -> Void)?
    /// Fired (on the main queue) when a client asks to control the host. The
    /// host should respond with `grantControl`/`denyControl`.
    var onControlRequest: ((ControlRequest) -> Void)?
    /// Fired (on the server queue) for input from the active controller only.
    var onInput: ((InputEvent) -> Void)?
    /// Fired (on the main queue) when the active controller is cleared, so the
    /// host can release any held buttons.
    var onControllerCleared: (() -> Void)?

    /// Opaque handle describing a pending control request.
    struct ControlRequest {
        let clientId: String
        let name: String
        let ip: String
        fileprivate let oid: ObjectIdentifier
    }

    /// Number of currently connected viewers (authenticated only).
    var viewerCount: Int {
        queue.sync { authed.count }
    }

    // MARK: - Lifecycle

    func start(config: StreamConfig) throws {
        stop()

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) else {
            throw NSError(domain: "LANCast", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(config.port)"])
        }

        password = config.password
        controlMasterEnabled = config.allowRemoteControl

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: port)
        self.boundPort = UInt16(config.port)

        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let actual = self?.listener?.port?.rawValue {
                self?.boundPort = actual
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.setupConnection(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        startHeartbeat()
    }

    func stop() {
        queue.sync {
            heartbeat?.cancel()
            heartbeat = nil
            for (_, c) in clients { c.cancel() }
            clients.removeAll()
            httpBuffers.removeAll()
            wsBuffers.removeAll()
            clientIds.removeAll()
            clientNames.removeAll()
            remoteIPs.removeAll()
            viewOnly.removeAll()
            lastPong.removeAll()
            authed.removeAll()
            activeControllerOID = nil
            activeControllerClientId = nil
            cachedInitMime = nil
            cachedInitSegment = nil
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Heartbeat (prunes dead viewers so the count stays accurate)

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeat = timer
        timer.resume()
    }

    private func heartbeatTick() {
        let now = Date()
        let snapshot = clients // avoid mutating while iterating
        for (oid, connection) in snapshot {
            let last = lastPong[oid] ?? now
            if now.timeIntervalSince(last) > Self.pongTimeout {
                Log.log("dropping stale viewer (no pong for \(Int(now.timeIntervalSince(last)))s)")
                connection.cancel()
                removeClient(oid)
            } else {
                let ping = Self.wsFrame(opcode: 0x9, payload: Data())
                connection.send(content: ping, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: - Stream data in

    /// Caches the init segment and pushes it to all current viewers.
    func setInit(mime: String, segment: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cachedInitMime = mime
            self.cachedInitSegment = segment
            for (oid, c) in self.clients where self.authed.contains(oid) {
                self.sendInit(to: c, mime: mime, segment: segment)
            }
        }
    }

    /// Broadcasts a media segment to all current viewers.
    func broadcastSegment(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let frame = Self.wsFrame(opcode: 0x2, payload: data)
            for (oid, c) in self.clients where self.authed.contains(oid) {
                c.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: - Connection handling

    private func setupConnection(_ connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Log.log("connection failed: \(error)")
                self?.removeClient(oid)
            case .cancelled:
                self?.removeClient(oid)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHTTP(connection)
    }

    private func removeClient(_ oid: ObjectIdentifier) {
        let wasClient = clients[oid] != nil
        clients[oid] = nil
        httpBuffers[oid] = nil
        wsBuffers[oid] = nil
        clientIds[oid] = nil
        clientNames[oid] = nil
        remoteIPs[oid] = nil
        viewOnly[oid] = nil
        lastPong[oid] = nil
        authed.remove(oid)
        if oid == activeControllerOID {
            activeControllerOID = nil
            activeControllerClientId = nil
            DispatchQueue.main.async { [weak self] in self?.onControllerCleared?() }
        }
        if wasClient { notifyViewerCount() }
    }

    private func notifyViewerCount() {
        let count = authed.count
        DispatchQueue.main.async { [weak self] in self?.onViewerCountChanged?(count) }
    }

    private func receiveHTTP(_ connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var buffer = self.httpBuffers[oid] ?? Data()
                buffer.append(data)
                self.httpBuffers[oid] = buffer

                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                    self.httpBuffers[oid] = nil
                    self.handleRequest(headerData, connection: connection)
                    return
                }

                if buffer.count < 64 * 1024 {
                    self.receiveHTTP(connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.removeClient(oid)
            } else {
                self.receiveHTTP(connection)
            }
        }
    }

    private func handleRequest(_ headerData: Data, connection: NWConnection) {
        guard let header = String(data: headerData, encoding: .utf8) else {
            connection.cancel(); return
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let rawPath = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let (path, query) = splitQuery(rawPath)

        // The player page itself is not sensitive, so it is served openly; the
        // password gate is enforced on the WebSocket (the actual stream). This
        // lets the page render a password prompt when no/incorrect token is set.
        let isWebSocket = (headers["upgrade"]?.lowercased().contains("websocket") ?? false)

        if isWebSocket && (path == "/ws") {
            let tokenOK = password.isEmpty || (tokenFromQuery(query) == password)
            upgradeToWebSocket(connection, key: headers["sec-websocket-key"], authed: tokenOK)
            return
        }

        switch path {
        case "/", "/index.html":
            let body = Data(PlayerPage.html.utf8)
            sendHTTP(connection, status: "200 OK",
                     contentType: "text/html; charset=utf-8", body: body, close: true)
        case "/health":
            sendHTTP(connection, status: "200 OK",
                     contentType: "text/plain; charset=utf-8",
                     body: Data("ok".utf8), close: true)
        default:
            sendHTTP(connection, status: "404 Not Found",
                     contentType: "text/plain; charset=utf-8",
                     body: Data("Not found".utf8), close: true)
        }
    }

    // MARK: - WebSocket

    private func upgradeToWebSocket(_ connection: NWConnection, key: String?, authed isAuthed: Bool) {
        guard let key else { connection.cancel(); return }
        let accept = Self.acceptKey(for: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let oid = ObjectIdentifier(connection)
            self.clients[oid] = connection
            self.lastPong[oid] = Date()
            let ip = Self.remoteIP(of: connection)
            self.remoteIPs[oid] = ip
            self.viewOnly[oid] = Self.isLocalAddress(ip)
            let haveInit = self.cachedInitMime != nil
            Log.log("WebSocket client connected (total \(self.clients.count)), ip=\(ip), authed=\(isAuthed), viewOnly=\(self.viewOnly[oid] ?? false), cachedInit=\(haveInit)")
            if isAuthed {
                self.authed.insert(oid)
                self.notifyViewerCount()
                if let mime = self.cachedInitMime, let seg = self.cachedInitSegment {
                    self.sendInit(to: connection, mime: mime, segment: seg)
                }
            } else {
                // Hold the connection open but withhold the stream until the
                // viewer supplies the correct password over the socket.
                self.sendJSON(["type": "auth", "state": "required"], to: connection)
            }
            self.receiveWS(connection)
        })
    }

    private func sendInit(to connection: NWConnection, mime: String, segment: Data) {
        // The MIME string contains double quotes (codecs="..."), so build JSON
        // safely instead of interpolating it raw.
        let payload: [String: String] = ["type": "init", "mime": mime]
        let jsonData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"type\":\"init\"}".utf8)
        let textFrame = Self.wsFrame(opcode: 0x1, payload: jsonData)
        let binFrame = Self.wsFrame(opcode: 0x2, payload: segment)
        connection.send(content: textFrame, completion: .contentProcessed { _ in })
        connection.send(content: binFrame, completion: .contentProcessed { _ in })
    }

    /// Reads inbound WebSocket frames just enough to honor ping/close.
    private func receiveWS(_ connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var buffer = self.wsBuffers[oid] ?? Data()
                buffer.append(data)
                self.wsBuffers[oid] = self.parseWSFrames(buffer, connection: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
                self.removeClient(oid)
            } else {
                self.receiveWS(connection)
            }
        }
    }

    /// Parses complete client frames, returns leftover bytes. Handles close/ping.
    private func parseWSFrames(_ input: Data, connection: NWConnection) -> Data {
        let bytes = [UInt8](input)
        var offset = 0

        while bytes.count - offset >= 2 {
            let b0 = bytes[offset]
            let b1 = bytes[offset + 1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var idx = offset + 2

            if len == 126 {
                guard bytes.count - idx >= 2 else { break }
                len = Int(bytes[idx]) << 8 | Int(bytes[idx + 1])
                idx += 2
            } else if len == 127 {
                guard bytes.count - idx >= 8 else { break }
                var value = 0
                for i in 0..<8 { value = (value << 8) | Int(bytes[idx + i]) }
                len = value
                idx += 8
            }

            var maskKey: [UInt8] = [0, 0, 0, 0]
            if masked {
                guard bytes.count - idx >= 4 else { break }
                maskKey = Array(bytes[idx..<idx + 4])
                idx += 4
            }

            guard bytes.count - idx >= len else { break }
            var payload = Array(bytes[idx..<idx + len])
            if masked {
                for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            }
            idx += len
            offset = idx

            switch opcode {
            case 0x1: // text -> JSON control / diagnostic message
                if let text = String(bytes: payload, encoding: .utf8) {
                    handleClientText(text, connection: connection)
                }
            case 0x8: // close
                Log.log("WebSocket client sent close")
                connection.cancel()
                removeClient(ObjectIdentifier(connection))
                return Data()
            case 0x9: // ping -> pong
                let pong = Self.wsFrame(opcode: 0xA, payload: Data(payload))
                connection.send(content: pong, completion: .contentProcessed { _ in })
            case 0xA: // pong -> keepalive
                lastPong[ObjectIdentifier(connection)] = Date()
            default:
                break
            }
        }

        return Data(bytes[offset...])
    }

    // MARK: - Client control messages

    private func handleClientText(_ text: String, connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        // The "auth" reply is the only message accepted from an unauthenticated
        // connection (besides identity/diagnostics which are harmless to record).
        switch type {
        case "log":
            if let msg = obj["msg"] as? String { Log.log("client: \(msg)") }

        case "hello":
            clientIds[oid] = (obj["clientId"] as? String) ?? ""
            if let name = obj["name"] as? String, !name.isEmpty { clientNames[oid] = name }
            if authed.contains(oid) { sendControlAvailability(to: connection) }

        case "auth":
            handleAuth(oid: oid, connection: connection, token: obj["token"] as? String ?? "")

        case "control-request":
            guard authed.contains(oid) else { return }
            handleControlRequest(oid: oid, connection: connection)

        case "control-release":
            guard authed.contains(oid) else { return }
            if oid == activeControllerOID { clearActiveController() }

        case "input":
            guard authed.contains(oid), oid == activeControllerOID,
                  let event = Self.parseInput(obj) else { return }
            onInput?(event)

        default:
            break
        }
    }

    private func handleAuth(oid: ObjectIdentifier, connection: NWConnection, token: String) {
        if authed.contains(oid) { return }
        guard !password.isEmpty, token == password else {
            sendJSON(["type": "auth", "state": "bad"], to: connection)
            return
        }
        authed.insert(oid)
        sendJSON(["type": "auth", "state": "ok"], to: connection)
        notifyViewerCount()
        if let mime = cachedInitMime, let seg = cachedInitSegment {
            sendInit(to: connection, mime: mime, segment: seg)
        }
        // A hello may have arrived before auth; surface control availability now.
        sendControlAvailability(to: connection)
    }

    private func sendControlAvailability(to connection: NWConnection) {
        let oid = ObjectIdentifier(connection)
        if viewOnly[oid] == true {
            sendJSON(["type": "control", "state": "view-only"], to: connection)
        } else if !controlMasterEnabled {
            sendJSON(["type": "control", "state": "unavailable",
                      "reason": "Remote control is disabled on the host."], to: connection)
        } else {
            sendJSON(["type": "control", "state": "available"], to: connection)
        }
    }

    private func handleControlRequest(oid: ObjectIdentifier, connection: NWConnection) {
        if viewOnly[oid] == true {
            sendJSON(["type": "control", "state": "view-only"], to: connection)
            return
        }
        if !controlMasterEnabled {
            sendJSON(["type": "control", "state": "unavailable",
                      "reason": "Remote control is disabled on the host."], to: connection)
            return
        }
        let clientId = clientIds[oid] ?? ""
        // Single-controller arbitration.
        if let active = activeControllerClientId, active != clientId {
            sendJSON(["type": "control", "state": "busy"], to: connection)
            return
        }
        let request = ControlRequest(clientId: clientId, name: clientNames[oid] ?? "",
                                     ip: remoteIPs[oid] ?? "", oid: oid)
        DispatchQueue.main.async { [weak self] in self?.onControlRequest?(request) }
    }

    private func clearActiveController() {
        activeControllerOID = nil
        activeControllerClientId = nil
        DispatchQueue.main.async { [weak self] in self?.onControllerCleared?() }
    }

    // MARK: - Control responses (called by the host / AppController)

    func grantControl(_ request: ControlRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            // Revoke a different previous controller.
            if let prev = self.activeControllerOID, prev != request.oid, let c = self.clients[prev] {
                self.sendJSON(["type": "control", "state": "revoked",
                               "reason": "Another device took control."], to: c)
            }
            self.activeControllerOID = request.oid
            self.activeControllerClientId = request.clientId
            if let c = self.clients[request.oid] {
                self.sendJSON(["type": "control", "state": "granted"], to: c)
            }
        }
    }

    func denyControl(_ request: ControlRequest, state: String, reason: String?) {
        queue.async { [weak self] in
            guard let self, let c = self.clients[request.oid] else { return }
            var msg: [String: Any] = ["type": "control", "state": state]
            if let reason { msg["reason"] = reason }
            self.sendJSON(msg, to: c)
        }
    }

    func revokeControl(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let oid = self.activeControllerOID, let c = self.clients[oid] {
                self.sendJSON(["type": "control", "state": "revoked", "reason": reason], to: c)
            }
            self.activeControllerOID = nil
            self.activeControllerClientId = nil
        }
    }

    /// Revokes the active controller only if it is the given client.
    func revokeControl(clientId: String, reason: String) {
        queue.async { [weak self] in
            guard let self, self.activeControllerClientId == clientId else { return }
            if let oid = self.activeControllerOID, let c = self.clients[oid] {
                self.sendJSON(["type": "control", "state": "revoked", "reason": reason], to: c)
            }
            self.activeControllerOID = nil
            self.activeControllerClientId = nil
        }
    }

    private func sendJSON(_ obj: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let frame = Self.wsFrame(opcode: 0x1, payload: data)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private static func parseInput(_ obj: [String: Any]) -> InputEvent? {
        guard let kind = obj["kind"] as? String else { return nil }
        func d(_ key: String) -> Double { (obj[key] as? Double) ?? 0 }
        let x = d("x"), y = d("y")
        switch kind {
        case "move":
            return .move(x: x, y: y)
        case "down":
            return .mouseDown(x: x, y: y, button: (obj["button"] as? String) == "right" ? .right : .left)
        case "up":
            return .mouseUp(x: x, y: y, button: (obj["button"] as? String) == "right" ? .right : .left)
        case "scroll":
            return .scroll(x: x, y: y, dx: d("dx"), dy: d("dy"))
        case "text":
            return .text((obj["text"] as? String) ?? "")
        case "key":
            let mods = KeyModifiers(
                shift: (obj["shift"] as? Bool) ?? false,
                ctrl: (obj["ctrl"] as? Bool) ?? false,
                alt: (obj["alt"] as? Bool) ?? false,
                meta: (obj["meta"] as? Bool) ?? false
            )
            return .key(down: (obj["down"] as? Bool) ?? false,
                        code: (obj["code"] as? String) ?? "",
                        char: obj["char"] as? String,
                        mods: mods)
        default:
            return nil
        }
    }

    // MARK: - HTTP helpers

    private func sendHTTP(_ connection: NWConnection, status: String, contentType: String, body: Data, close: Bool) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    private func splitQuery(_ raw: String) -> (path: String, query: String) {
        if let q = raw.firstIndex(of: "?") {
            return (String(raw[..<q]), String(raw[raw.index(after: q)...]))
        }
        return (raw, "")
    }

    private func tokenFromQuery(_ query: String) -> String? {
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "token" {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }

    // MARK: - WebSocket framing

    private static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + wsMagic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func wsFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN + opcode
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    // MARK: - Networking info

    /// Extracts the remote peer's IP (without IPv6 zone) from a connection.
    static func remoteIP(of connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "" }
        var s = "\(host)"
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) } // strip %en0 zone
        return s
    }

    /// Whether the given IP belongs to this host (loopback or any local
    /// interface) — used to detect "same device" and block control feedback.
    static func isLocalAddress(_ ip: String) -> Bool {
        if ip.isEmpty { return false }
        if ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1" { return true }
        return allLocalAddresses().contains(ip)
    }

    /// All numeric IPv4/IPv6 addresses assigned to local interfaces.
    static func allLocalAddresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                var addr = interface.ifa_addr.pointee
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    var s = String(cString: hostname)
                    if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
                    result.insert(s)
                }
            }
            ptr = interface.ifa_next
        }
        return result
    }

    /// Returns the primary LAN IPv4 address (en* interface), or nil.
    static func localIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let candidate = String(cString: hostname)
                        if !candidate.hasPrefix("169.254") { // skip link-local
                            address = candidate
                            if name == "en0" { break } // prefer en0
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return address
    }
}
