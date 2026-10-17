import Foundation
import Network
import Security

// URLSession's ATS policy rejects this expired peer even after a trust credential is supplied.
// The user-requested exact-leaf exception is active while signed in; account requests keep ATS.
@MainActor
final class LegacyRelayConnection {
    private var connection: NWConnection?
    private var parser = NativeHTTPResponseParser()
    private var timeout: Task<Void, Never>?
    private let onResponse: (Int, String, String?) -> Bool
    private let onData: (Data) -> Void
    private let onError: (String) -> Void

    init(onResponse: @escaping (Int, String, String?) -> Bool, onData: @escaping (Data) -> Void,
         onError: @escaping (String) -> Void) {
        self.onResponse = onResponse
        self.onData = onData
        self.onError = onError
    }

    static func wireRequest(_ request: URLRequest) throws -> Data {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw ImouError.message("Unsupported secure camera request.")
        }
        let target = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) +
            (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var lines = ["GET \(target) HTTP/1.1", "Host: \(authority):\(url.port ?? 443)", "Accept-Encoding: identity"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !["host", "accept-encoding", "content-length", "transfer-encoding"].contains(name.lowercased()),
                  !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 }),
                  value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
                throw ImouError.message("Invalid camera request header.")
            }
            lines.append("\(name): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    func start(_ request: URLRequest) {
        guard LegacyRelayCertificate.approvedForRun,
              let url = request.url, let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 443) ?? 0),
              port.rawValue != 0, let bytes = try? Self.wireRequest(request) else {
            onError("The relay certificate exception is not active or the request is invalid.")
            return
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, peer, complete in
            MainActor.assumeIsolated {
                guard self?.connection != nil, LegacyRelayCertificate.approvedForRun else {
                    complete(false); return
                }
                let trust = sec_trust_copy_ref(peer).takeRetainedValue()
                if LegacyRelayCertificate.permits(LegacyRelayCertificate.fingerprint(in: trust), approved: true) {
                    complete(true)
                } else {
                    // An unrecognized certificate must still pass normal chain, time and host validation.
                    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                    complete(SecTrustEvaluateWithError(trust, nil))
                }
            }
        }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                      using: NWParameters(tls: tls, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                        MainActor.assumeIsolated {
                            guard let self, self.connection != nil else { return }
                            if let error { self.fail(Self.message(error)) }
                            else { self.receive() }
                        }
                    })
                case .failed(let error): self.fail(Self.message(error))
                default: break
                }
            }
        }
        armTimeout()
        connection.start(queue: .main)
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil
        old?.cancel()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, self.connection != nil else { return }
                if let data, !data.isEmpty {
                    self.armTimeout()
                    do {
                        for event in try self.parser.append(data) {
                            guard self.connection != nil else { return }
                            switch event {
                            case .response(let status, let contentType, let privateLength):
                                if (100..<200).contains(status) { continue }
                                guard self.onResponse(status, contentType, privateLength) else { self.stop(); return }
                            case .body(let bytes): self.onData(bytes)
                            case .end: self.fail("Camera connection closed."); return
                            }
                        }
                    } catch { self.fail("Camera relay returned an invalid HTTP response."); return }
                }
                guard self.connection != nil else { return }
                if let error { self.fail(Self.message(error)) }
                else if ended {
                    do {
                        _ = try self.parser.finish()
                        self.fail("Camera connection closed.")
                    } catch { self.fail("Camera relay returned an incomplete HTTP response.") }
                }
                else { self.receive() }
            }
        }
    }

    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            // Some cameras take 20-30 s to answer their first relay request; 60 s avoids restarting a slow wake-up.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fail("Camera relay timed out.")
        }
    }

    private func fail(_ message: String) {
        guard connection != nil else { return }
        stop()
        onError(message)
    }

    private static func message(_ error: NWError) -> String {
        switch error {
        case .tls(let code): return "Secure camera connection failed (TLS \(code))."
        case .posix(let code): return "Camera connection failed (network \(code.rawValue))."
        case .dns(let code): return "Camera connection failed (DNS \(code))."
        case .wifiAware: return "Camera connection failed."
        @unknown default: return "Camera connection failed."
        }
    }
}
