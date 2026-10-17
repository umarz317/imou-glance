import AppKit
import Network
import WebKit

struct DirectStream: Codable, Equatable {
    var deviceId: String
    var channelId: Int
    var streamId: Int
    var code: String
    var streamType: String
    var playUrl: String
    var playToken: String?
    var playTokenKey: String?
    var deviceLoginName: String?
    var deviceLoginPassword: String?
    var nativeSessionId: String?
    var nativeRequest: URLRequest? = nil

    enum CodingKeys: String, CodingKey {
        case deviceId, channelId, streamId, code, streamType, playUrl, playToken, playTokenKey
        case deviceLoginName, deviceLoginPassword, nativeSessionId
    }

    static func playerResource(_ value: String) throws -> String {
        let prefixes = ["rtsp://", "rtsps://", "http://", "https://"]
        let prefix = prefixes.first { value.lowercased().hasPrefix($0) }
        let suffix = prefix.map { String(value.dropFirst($0.count)) } ?? value
        let parts = suffix.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let authority = parts.first.map(String.init) ?? ""
        let parsed = URLComponents(string: "https://" + authority)
        guard parts.count == 2, !parts[1].isEmpty,
              parsed?.host?.isEmpty == false, parsed?.port != nil,
              parsed?.user == nil, parsed?.password == nil,
              parsed?.query == nil, parsed?.fragment == nil, parsed?.path.isEmpty == true,
              !authority.contains(where: { $0.isWhitespace }), !suffix.contains("#"),
              !suffix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImouError.message("Imou returned an unsupported secure stream resource (invalid relay address or path).")
        }
        // Native RTSV separates the authority from an opaque path; TLS is configured separately.
        return "rtsp://" + suffix
    }

    static func nativeResource(_ value: String) throws -> URL {
        let carrier = try playerResource(value)
        guard let url = URL(string: "https://" + carrier.dropFirst(7)) else {
            throw ImouError.message("Imou returned an invalid secure camera request.")
        }
        return url
    }

    init(deviceId: String, channelId: Int, streamId: Int, code: String,
         streamType: String, playUrl: String, playToken: String? = nil,
         playTokenKey: String? = nil, deviceLoginName: String? = nil,
         deviceLoginPassword: String? = nil, nativeSessionId: String? = nil,
         nativeRequest: URLRequest? = nil) {
        self.deviceId = deviceId
        self.channelId = channelId
        self.streamId = streamId
        self.code = code
        self.streamType = streamType
        self.playUrl = playUrl
        self.playToken = playToken
        self.playTokenKey = playTokenKey
        self.deviceLoginName = deviceLoginName
        self.deviceLoginPassword = deviceLoginPassword
        self.nativeSessionId = nativeSessionId
        self.nativeRequest = nativeRequest
    }
}

final class DirectPlayerView: NSView {
    private let webView: WKWebView
    private let coordinator: Coordinator

    /// `onFailure` fires once per player for failures a fresh connection can fix (drops, stalls, crashes).
    init(stream: DirectStream, onStatus: @escaping (String) -> Void, onFailure: @escaping () -> Void = {}) {
        coordinator = Coordinator(onStatus: onStatus, onFailure: onFailure)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Selecting a camera starts its muted preview, including the SDK's hardware video element.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(coordinator, name: "playerStatus")
        configuration.userContentController.add(coordinator, name: "nativeTransport")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        super.init(frame: .zero)
        addFilling(webView)
        coordinator.attach(webView, stream: stream)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ stream: DirectStream) { coordinator.update(stream) }

    /// Stops playback, releases the page's handlers and removes the view.
    func close() {
        coordinator.close()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playerStatus")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nativeTransport")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        removeFromSuperview()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let onStatus: (String) -> Void
        let onFailure: () -> Void
        private var failed = false
        private weak var webView: WKWebView?
        private var server: PlayerAssetServer?
        private var currentStream: DirectStream?
        private var submittedStream: DirectStream?
        private var pageReady = false
        private var visible = false
        private var visibilityTimer: Timer?
        private var closed = false
        private var status = ""
        private var nativeTransport: NativeMediaTransport?
        private var nativeOpened = false
        private var nativeFailed = false
        private var pendingPackets: [Data] = []
        private var pendingBytes = 0
        private var deliveringPacket = false

        init(onStatus: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onStatus = onStatus
            self.onFailure = onFailure
        }

        func attach(_ webView: WKWebView, stream: DirectStream) {
            self.webView = webView
            currentStream = stream
            report("Loading player…")
            do {
                let server = try PlayerAssetServer()
                self.server = server
                server.start { [weak self] url in
                    guard let self, !self.closed else { return }
                    guard let url else { self.report("Could not start the local player."); return }
                    self.webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
                }
                visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkVisibility() }
                }
            } catch { report("Player assets are unavailable.") }
        }

        func update(_ stream: DirectStream) {
            guard currentStream != stream else { return }
            stopNativeTransport()
            currentStream = stream
            submittedStream = nil
            startIfVisible()
        }

        private func checkVisibility() {
            guard !closed, let webView else { return }
            let nowVisible = webView.window?.isVisible == true && !webView.isHiddenOrHasHiddenAncestor
            guard nowVisible != visible else { return }
            visible = nowVisible
            if visible { startIfVisible() }
            else { stopPlayback() }
        }

        private func startIfVisible() {
            guard !closed, visible, pageReady, let webView, let stream = currentStream,
                  submittedStream != stream else { return }
            guard !stream.deviceId.isEmpty, stream.channelId >= 0, stream.streamId >= 0,
                  ["rtsp", "rtsv"].contains(stream.streamType),
                  let resource = URLComponents(string: stream.playUrl),
                  resource.scheme == "rtsp", resource.host?.isEmpty == false else {
                report("Unsupported camera stream resource.")
                return
            }
            do {
                let data = try JSONEncoder().encode(stream)
                let config = try JSONSerialization.jsonObject(with: data)
                submittedStream = stream
                nativeFailed = false
                webView.callAsyncJavaScript("await window.directPlayer.start(config);", arguments: ["config": config],
                                            in: nil, in: .page) { [weak self] result in
                    if case .failure = result { self?.report("Could not start camera playback.", recoverable: true) }
                }
            } catch { report("Could not prepare camera playback.") }
        }

        private func stopPlayback() {
            stopNativeTransport()
            submittedStream = nil
            webView?.evaluateJavaScript("window.directPlayer?.stop();", completionHandler: nil)
        }

        private func stopNativeTransport() {
            nativeTransport?.stop()
            nativeTransport = nil
            nativeOpened = false
            pendingPackets.removeAll()
            pendingBytes = 0
            deliveringPacket = false
        }

        private func startNativeTransport(_ id: String) {
            guard nativeTransport == nil, visible, !closed,
                  let stream = submittedStream, stream.nativeSessionId == id,
                  let request = stream.nativeRequest else { return }
            let transport = NativeMediaTransport(onOpen: { [weak self] in
                guard let self, self.submittedStream?.nativeSessionId == id, let webView = self.webView else { return }
                webView.callAsyncJavaScript("return window.directPlayer.nativeTransportOpened(sessionId);",
                    arguments: ["sessionId": id], in: nil, in: .page) { [weak self] result in
                    guard let self, self.nativeTransport != nil, self.submittedStream?.nativeSessionId == id else { return }
                    guard case .success(let opened) = result, (opened as? Bool) == true else {
                        self.failNativeTransport(id, message: "Could not start the camera decoder."); return
                    }
                    self.nativeOpened = true
                    self.deliverNextPacket(id)
                }
            }, onPacket: { [weak self] packet in
                guard let self, self.nativeTransport != nil, self.submittedStream?.nativeSessionId == id else { return }
                guard self.pendingBytes + packet.count <= 16 * 1024 * 1024 else {
                    self.failNativeTransport(id, message: "The camera decoder could not keep up with the stream."); return
                }
                self.pendingPackets.append(packet)
                self.pendingBytes += packet.count
                self.deliverNextPacket(id)
            }, onError: { [weak self] message in
                self?.failNativeTransport(id, message: message)
            })
            nativeTransport = transport
            transport.start(request, label: StreamLog.camera(stream.deviceId))
            // Say why a slow camera is still connecting instead of looking stuck.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak transport] in
                guard let self, let transport, self.nativeTransport === transport, !self.nativeOpened else { return }
                self.report("Waiting for the camera to respond…")
            }
        }

        private func deliverNextPacket(_ id: String) {
            guard !closed, nativeOpened, !deliveringPacket, !pendingPackets.isEmpty,
                  submittedStream?.nativeSessionId == id, let webView else { return }
            let packet = pendingPackets.removeFirst()
            pendingBytes -= packet.count
            deliveringPacket = true
            webView.callAsyncJavaScript("return window.directPlayer.receiveNativePacket(packet, sessionId);",
                arguments: ["packet": packet.base64EncodedString(), "sessionId": id], in: nil, in: .page) { [weak self] result in
                guard let self, self.submittedStream?.nativeSessionId == id else { return }
                self.deliveringPacket = false
                guard case .success(let accepted) = result, (accepted as? Bool) == true else {
                    self.failNativeTransport(id, message: "Camera decoder rejected a stream packet."); return
                }
                self.deliverNextPacket(id)
            }
        }

        private func failNativeTransport(_ id: String, message: String) {
            guard submittedStream?.nativeSessionId == id else { return }
            nativeFailed = true
            stopNativeTransport()
            report(message, recoverable: true)
            webView?.callAsyncJavaScript("window.directPlayer.nativeTransportFailed(sessionId, 'error');",
                arguments: ["sessionId": id], in: nil, in: .page, completionHandler: nil)
        }

        func close() {
            guard !closed else { return }
            closed = true
            visibilityTimer?.invalidate()
            visibilityTimer = nil
            stopPlayback()
            currentStream = nil
            webView?.stopLoading()
            server?.stop()
            server = nil
        }

        private func report(_ text: String, recoverable: Bool = false) {
            guard !closed, status != text else { return }
            status = text
            StreamLog.logger.info("player \(StreamLog.camera(self.currentStream?.deviceId ?? ""), privacy: .public): \(text, privacy: .public)")
            // Only the first failure asks for a reconnect; the replacement player gets its own chance.
            let notify = recoverable && !failed
            if recoverable { failed = true }
            // Defer so the model is never mutated mid-render.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.onStatus(text)
                if notify { self.onFailure() }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === webView else { return }
            if message.name == "nativeTransport" {
                guard let command = message.body as? [String: String],
                      let id = command["sessionId"], submittedStream?.nativeSessionId == id else { return }
                if command["action"] == "start" { startNativeTransport(id) }
                if command["action"] == "stop" { stopNativeTransport() }
                return
            }
            guard message.name == "playerStatus", let value = message.body as? String else { return }
            guard !nativeFailed || value == "ready" else { return }
            switch value {
            case "ready": pageReady = true; checkVisibility(); startIfVisible()
            case "loading": report("Connecting to camera…")
            case "playing": report("Live")
            case "stopped": report("Stopped")
            case "disconnected": report("Camera connection closed.", recoverable: true)
            case "stalled": report("Camera stream stopped updating.", recoverable: true)
            case "timeout": report("Camera did not send a video frame.", recoverable: true)
            case "encryption": report("This camera encryption mode needs additional protocol support.")
            case "unsupported": report("Unsupported camera stream resource.")
            case "error": report("Camera player could not decode this stream.", recoverable: true)
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame == true,
                  let url = navigationAction.request.url, server?.contains(url) == true else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report("Could not load the camera player.", recoverable: true)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report("Could not load the camera player.", recoverable: true)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            stopNativeTransport()
            pageReady = false
            submittedStream = nil
            report("Camera player stopped.", recoverable: true)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}

// Fixed public files only; account/device data is never served over HTTP.
@MainActor
final class PlayerAssetServer {
    private let listener: NWListener
    private let assets: [String: (Data, String)]
    private var ready: ((URL?) -> Void)?
    private(set) var baseURL: URL?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(directory: URL? = nil) throws {
        guard let directory = directory ?? Bundle.module.url(forResource: "PlayerAssets", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let routes = [
            "/": ("player.html", "text/html; charset=utf-8"),
            "/imou-player.js": ("imou-player.js", "text/javascript; charset=utf-8"),
            "/WasmLib/SingleThread/liblcplay.js": ("WasmLib/SingleThread/liblcplay.js", "text/javascript; charset=utf-8"),
            "/WasmLib/SingleThread/PlaySdkWorker.js": ("WasmLib/SingleThread/PlaySdkWorker.js", "text/javascript; charset=utf-8"),
            "/WasmLib/SingleThread/liblcplay.wasm": ("WasmLib/SingleThread/liblcplay.wasm", "application/wasm"),
        ]
        var loaded: [String: (Data, String)] = [:]
        for (route, entry) in routes {
            loaded[route] = (try Data(contentsOf: directory.appendingPathComponent(entry.0)), entry.1)
        }
        assets = loaded
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ completion: @escaping (URL?) -> Void) {
        ready = completion
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    self.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
                    self.ready?(self.baseURL)
                    self.ready = nil
                case .failed:
                    self.ready?(nil)
                    self.ready = nil
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    func contains(_ url: URL) -> Bool {
        guard let baseURL else { return false }
        return url.scheme == baseURL.scheme && url.host == "127.0.0.1" && url.port == baseURL.port && url.path == "/"
    }

    func stop() {
        ready = nil
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let identity = ObjectIdentifier(connection)
        guard connections.count < 20 else { connection.cancel(); return }
        connections[identity] = connection
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection, self.connections[identity] != nil else { return }
            connection.cancel()
            self.connections.removeValue(forKey: identity)
        }
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var request = accumulated
                if let data { request.append(data) }
                guard error == nil, request.count <= 8192 else { self.finish(connection); return }
                if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                    self.respond(connection, request: text)
                } else if complete { self.finish(connection) }
                else { self.receive(connection, accumulated: request) }
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let fields = firstLine.split(separator: " ")
        let target = fields.count == 3 && fields[0] == "GET" ? String(fields[1]) : ""
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        let entry = assets[path]
        let body = entry?.0 ?? Data()
        let status = entry == nil ? "404 Not Found" : "200 OK"
        let contentType = entry?.1 ?? "text/plain"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; style-src 'unsafe-inline'; connect-src 'self' wss:; worker-src 'self' blob:; media-src blob:; img-src 'self' data: blob:; object-src 'none'; frame-src 'none'; base-uri 'none'\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(connection) }
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
}
