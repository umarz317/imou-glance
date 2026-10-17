import Foundation

@MainActor
final class NativeMediaTransport: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var legacyConnection: LegacyRelayConnection?
    private var framer = NativeMediaFramer()
    private var active = false
    private var label = ""
    private var bytes = 0
    private var startedAt = Date()
    private let onOpen: () -> Void
    private let onPacket: (Data) -> Void
    private let onError: (String) -> Void

    init(onOpen: @escaping () -> Void, onPacket: @escaping (Data) -> Void,
         onError: @escaping (String) -> Void) {
        self.onOpen = onOpen
        self.onPacket = onPacket
        self.onError = onError
    }

    func start(_ request: URLRequest, label: String = "") {
        stop()
        self.label = label
        bytes = 0
        startedAt = Date()
        StreamLog.logger.info("relay start \(label, privacy: .public)")
        guard request.url?.scheme == "https", request.httpMethod == "GET" else {
            onError("Unsupported secure camera request."); return
        }
        active = true
        if LegacyRelayCertificate.approvedForRun {
            let connection = LegacyRelayConnection(onResponse: { [weak self] status, type, privateLength in
                self?.acceptResponse(status: status, contentType: type, privateLength: privateLength) ?? false
            }, onData: { [weak self] in self?.receive($0) },
               onError: { [weak self] in self?.fail($0) })
            legacyConnection = connection
            connection.start(request)
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        // Matches LegacyRelayConnection: a slow camera can take 20-30 s to answer the first request.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        if active {
            StreamLog.logger.info("relay stop \(self.label, privacy: .public) bytes=\(self.bytes) after=\(Int(Date().timeIntervalSince(self.startedAt)))s")
        }
        active = false
        task?.cancel()
        task = nil
        legacyConnection?.stop()
        legacyConnection = nil
        session?.invalidateAndCancel()
        session = nil
        framer = NativeMediaFramer()
    }

    private func fail(_ message: String) {
        guard active else { return }
        StreamLog.logger.error("relay fail \(self.label, privacy: .public): \(message, privacy: .public)")
        stop()
        onError(message)
    }

    static func secureFailureMessage(_ error: NSError) -> String {
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let code = (error.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue ??
                   (underlying?.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber)?.intValue
        return "Secure camera connection failed (\(error.code)\(code.map { "; TLS \($0)" } ?? ""))."
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            guard active, dataTask === task else { completionHandler(.cancel); return }
            let response = response as? HTTPURLResponse
            completionHandler(acceptResponse(status: response?.statusCode ?? 0,
                contentType: response?.value(forHTTPHeaderField: "Content-Type") ?? "",
                privateLength: response?.value(forHTTPHeaderField: "Private-Length")) ? .allow : .cancel)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard active, dataTask === task else { return }
            receive(data)
        }
    }

    private func acceptResponse(status: Int, contentType: String, privateLength: String?) -> Bool {
        guard active else { return false }
        guard status == 200 else {
            fail("Camera relay rejected the stream (HTTP \(status))."); return false
        }
        guard let preambleLength = try? NativeMediaFramer.preambleLength(from: privateLength) else {
            fail("Camera relay returned an invalid private header length."); return false
        }
        let type = contentType.lowercased()
        if type.contains("-rtpxav") { framer = NativeMediaFramer(format: .privateRTP, preambleLength: preambleLength) }
        else if type.contains("-xav") { framer = NativeMediaFramer(format: .privateXAV, preambleLength: preambleLength) }
        else { fail("Camera relay returned an unsupported media format."); return false }
        StreamLog.logger.info("relay open \(self.label, privacy: .public) after=\(Int(Date().timeIntervalSince(self.startedAt)))s")
        onOpen()
        return true
    }

    private func receive(_ data: Data) {
        guard active else { return }
        bytes += data.count
        do {
            for packet in try framer.append(data) { onPacket(packet) }
        } catch { fail("Camera returned an unsupported media packet.") }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard active, task === self.task else { return }
            if let error = error as NSError? {
                switch error.code {
                case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                     NSURLErrorSecureConnectionFailed:
                    fail(Self.secureFailureMessage(error))
                case NSURLErrorTimedOut:
                    fail("Camera relay timed out.")
                default:
                    fail("Camera connection failed (\(error.code)).")
                }
            } else { fail("Camera connection closed.") }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
