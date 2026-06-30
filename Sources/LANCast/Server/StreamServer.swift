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

    private var cachedInitMime: String?
    private var cachedInitSegment: Data?

    private var password: String = ""

    private static let wsMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private(set) var boundPort: UInt16 = 0

    /// Number of currently connected viewers.
    var viewerCount: Int {
        queue.sync { clients.count }
    }

    // MARK: - Lifecycle

    func start(config: StreamConfig) throws {
        stop()

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) else {
            throw NSError(domain: "LANCast", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(config.port)"])
        }

        password = config.password

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
    }

    func stop() {
        queue.sync {
            for (_, c) in clients { c.cancel() }
            clients.removeAll()
            httpBuffers.removeAll()
            wsBuffers.removeAll()
            cachedInitMime = nil
            cachedInitSegment = nil
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Stream data in

    /// Caches the init segment and pushes it to all current viewers.
    func setInit(mime: String, segment: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cachedInitMime = mime
            self.cachedInitSegment = segment
            for (_, c) in self.clients {
                self.sendInit(to: c, mime: mime, segment: segment)
            }
        }
    }

    /// Broadcasts a media segment to all current viewers.
    func broadcastSegment(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let frame = Self.wsFrame(opcode: 0x2, payload: data)
            for (_, c) in self.clients {
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
        clients[oid] = nil
        httpBuffers[oid] = nil
        wsBuffers[oid] = nil
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

        // Auth check (only when a password is configured).
        if !password.isEmpty, tokenFromQuery(query) != password {
            sendHTTP(connection, status: "401 Unauthorized",
                     contentType: "text/plain; charset=utf-8",
                     body: Data("Unauthorized. Append ?token=YOUR_PASSWORD to the URL.".utf8),
                     close: true)
            return
        }

        let isWebSocket = (headers["upgrade"]?.lowercased().contains("websocket") ?? false)

        if isWebSocket && (path == "/ws") {
            upgradeToWebSocket(connection, key: headers["sec-websocket-key"])
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

    private func upgradeToWebSocket(_ connection: NWConnection, key: String?) {
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
            let haveInit = self.cachedInitMime != nil
            Log.log("WebSocket client connected (total \(self.clients.count)), cachedInit=\(haveInit)")
            if let mime = self.cachedInitMime, let seg = self.cachedInitSegment {
                self.sendInit(to: connection, mime: mime, segment: seg)
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
            case 0x1: // text -> client diagnostic
                if let text = String(bytes: payload, encoding: .utf8) {
                    Log.log("client: \(text)")
                }
            case 0x8: // close
                Log.log("WebSocket client sent close")
                connection.cancel()
                removeClient(ObjectIdentifier(connection))
                return Data()
            case 0x9: // ping -> pong
                let pong = Self.wsFrame(opcode: 0xA, payload: Data(payload))
                connection.send(content: pong, completion: .contentProcessed { _ in })
            default:
                break
            }
        }

        return Data(bytes[offset...])
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
