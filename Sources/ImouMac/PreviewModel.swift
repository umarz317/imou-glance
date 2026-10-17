import Combine
import Foundation

@MainActor
final class PreviewModel: ObservableObject {
    @Published var signedIn = false {
        didSet { LegacyRelayCertificate.approvedForRun = signedIn }
    }
    @Published var busy = false
    @Published var cameras: [ImouCamera] = []
    @Published var selectedId: String?
    /// Viewing choices kept across launches in preferences. Camera choices are cleared by Sign Out; layout is not.
    private enum Preference {
        static let qualities = "cameraQualitySelections"
        static let lastCamera = "lastSelectedCamera"
        static let layout = "cameraLayout"
    }

    /// Chosen video quality per camera. Unknown or removed qualities fall back to the default.
    @Published private var qualitySelections = UserDefaults.standard.dictionary(forKey: Preference.qualities) as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(qualitySelections, forKey: Preference.qualities) }
    }
    @Published var stream: DirectStream?
    @Published var captcha: CaptchaChallenge?
    @Published var terminalVerification = false
    @Published var terminalCodeSent = false
    @Published var resendAvailableAt: Date?
    /// PNG of the QR code shown while a QR sign-in waits for the phone; nil otherwise.
    @Published private(set) var loginQRCode: Data?
    @Published var status = "Sign in to your Imou account."
    @Published var error: String?
    /// True between sign-in and the camera list arriving, so the UI does not flash "No cameras".
    @Published private(set) var loadingCameras = false
    @Published private(set) var visible = false
    private var visibleViews = Set<UUID>()
    private var client = ImouClient()
    private var operation: Task<Void, Never>?
    private var operationId = UUID()
    private var loadingAccount = false
    private var cameraCodes: [String: String] = [:]
    // Written to the Keychain only once Imou accepts the sign-in.
    private var pendingSave: SavedCredentials?
    // QR sign-in has no password; with Remember on, the accepted Imou session is saved instead.
    private var pendingSessionSave = false
    var selected: ImouCamera? { cameras.first { $0.id == selectedId } }

    func clearQualitySelections() { qualitySelections.removeAll() }

    /// Last camera the user picked, restored after sign-in on the next launch. Written only on a user choice,
    /// so sign-out clearing `selectedId` does not erase it.
    private var lastCameraId: String? {
        get { UserDefaults.standard.string(forKey: Preference.lastCamera) }
        set { UserDefaults.standard.set(newValue, forKey: Preference.lastCamera) }
    }

    func quality(for camera: ImouCamera) -> CameraQuality { camera.quality(id: qualitySelections[camera.id]) }

    func selectQuality(_ id: String, for cameraId: String) {
        guard let camera = cameras.first(where: { $0.id == cameraId }),
              camera.qualities.contains(where: { $0.id == id }), quality(for: camera).id != id else { return }
        qualitySelections[cameraId] = id
        guard visible, signedIn else { return }
        if layout == 1 {
            if selectedId == cameraId { connect() }
        } else if gridCameras.contains(where: { $0.id == cameraId }) { connectTile(camera) }
    }

    /// Multi-view: 1 uses the single `stream`; 2 or 4 show that many cameras at once, starting with the
    /// selected one, each connecting independently. Restored from the last launch and clamped to the
    /// account's camera count once cameras load.
    @Published var layout = PreviewModel.storedLayout {
        didSet {
            guard layout != oldValue else { return }
            UserDefaults.standard.set(layout, forKey: Preference.layout)
            cancelRetries()
            if layout > 1 {
                operation?.cancel(); stream = nil; busy = false; error = nil
                connectGrid()
            } else { stopGrid(); connect() }
        }
    }
    private nonisolated static var storedLayout: Int {
        let saved = UserDefaults.standard.integer(forKey: Preference.layout)
        return [1, 2, 4].contains(saved) ? saved : 1
    }
    @Published private(set) var gridStreams: [String: DirectStream] = [:]
    @Published private(set) var gridStatus: [String: String] = [:]
    private var gridTasks: [String: Task<Void, Never>] = [:]
    var gridCameras: [ImouCamera] {
        guard layout > 1 else { return [] }
        let first = selected.map { [$0] } ?? []
        return Array((first + cameras.filter { $0.id != selectedId }).prefix(layout))
    }

    // MARK: Long-playback recovery

    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var retryAttempts: [String: Int] = [:]
    private var liveSince: [String: Date] = [:]

    /// Player status for the single view or a tile; "Live" marks the stream healthy.
    func playbackStatus(_ text: String, for cameraId: String) {
        if layout == 1 { if selectedId == cameraId { status = text } } else { gridStatus[cameraId] = text }
        if text == "Live" { liveSince[cameraId] = Date() }
    }

    /// A drop, stall, decoder error or player crash: reconnect that camera after a backoff.
    func playbackFailed(for cameraId: String) { scheduleReconnect(cameraId) }

    /// Waits about 2, 4, 8, 16, then 30 seconds between attempts while the camera is on screen.
    /// A minute of healthy playback resets the backoff, so a long session recovers quickly from a one-off drop.
    /// Jitter keeps several cameras that dropped together from reconnecting in lockstep.
    private func scheduleReconnect(_ cameraId: String, note: String = "Connection lost. Reconnecting…") {
        guard visible, signedIn else { return }
        if let since = liveSince.removeValue(forKey: cameraId), Date().timeIntervalSince(since) >= 60 {
            retryAttempts[cameraId] = 0
        }
        let attempt = (retryAttempts[cameraId] ?? 0) + 1
        retryAttempts[cameraId] = attempt
        let delay = Double(min(30, 1 << min(attempt, 5))) * Double.random(in: 0.8...1.2)
        StreamLog.logger.info("reconnect \(cameraId.suffix(12), privacy: .public) attempt=\(attempt) in=\(Int(delay))s: \(note, privacy: .public)")
        if layout == 1 { if selectedId == cameraId { status = note; stream = nil } }
        else { gridStatus[cameraId] = note; gridStreams[cameraId] = nil }
        retryTasks[cameraId]?.cancel()
        retryTasks[cameraId] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, visible, signedIn else { return }
            retryTasks[cameraId] = nil
            if layout == 1 { if selectedId == cameraId { connect() } }
            else if let camera = gridCameras.first(where: { $0.id == cameraId }) { connectTile(camera) }
        }
    }

    /// True while a dropped camera waits for its next automatic attempt.
    func isReconnecting(_ cameraId: String?) -> Bool { cameraId.map { retryTasks[$0] != nil } ?? false }

    private func cancelRetries() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        retryAttempts.removeAll()
        liveSince.removeAll()
    }

    /// Reconnect button, and after sleep when relay sessions are gone (rather than waiting for the stall watchdog).
    func reconnectNow() {
        guard visible, signedIn, !busy else { return }
        cancelRetries()
        connect()
    }

    /// What a tile shows while it waits to retry a failed stream request; nil when retrying cannot help.
    private static func retryNote(_ error: Error) -> String? {
        if case ImouError.unsupported = error { return nil }
        if error is URLError { return "Connection lost. Reconnecting…" }
        // Imou sometimes rejects several stream requests at once; the next attempt usually succeeds.
        return error.localizedDescription + " Retrying…"
    }

    /// Delay between starting grid tiles, so their players do not all load the decoder at the same moment.
    private static let tileStagger = 0.75

    func connectGrid() {
        stopGrid()
        guard visible, signedIn else { return }
        for (index, camera) in gridCameras.enumerated() { connectTile(camera, after: Double(index) * Self.tileStagger) }
    }

    func connectTile(_ camera: ImouCamera, after delay: Double = 0) {
        gridTasks[camera.id]?.cancel()
        gridStreams[camera.id] = nil
        gridStatus[camera.id] = "Connecting…"
        gridTasks[camera.id] = Task {
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                let direct = try await fetchStream(camera)
                if visible && layout > 1 { gridStreams[camera.id] = direct }
            } catch is CancellationError { }
            catch {
                if let note = Self.retryNote(error) { scheduleReconnect(camera.id, note: note) }
                else { gridStatus[camera.id] = error.localizedDescription }
            }
        }
    }

    /// Requests a stream at the camera's chosen quality and caches its device key for reconnects.
    private func fetchStream(_ camera: ImouCamera) async throws -> DirectStream {
        let direct = try await client.stream(for: camera, code: cameraCodes[camera.id] ?? "",
                                             qualityID: qualitySelections[camera.id])
        try Task.checkCancellation()
        cameraCodes[camera.id] = direct.deviceLoginPassword
        return direct
    }

    private func stopGrid() {
        gridTasks.values.forEach { $0.cancel() }
        gridTasks.removeAll()
        gridStreams.removeAll()
        gridStatus.removeAll()
    }

    func signIn(account: String, password: String, areaCode: String, remember: Bool = false) {
        pendingSave = remember ? SavedCredentials(account: account, password: password, areaCode: areaCode) : nil
        pendingSessionSave = false
        authenticate {
            try await self.client.signIn(account: account, password: password, areaCode: areaCode)
            return true
        }
    }

    /// Shows a QR code for the Imou Life app to scan, then polls until the phone approves it.
    func signInWithQRCode(remember: Bool = false) {
        pendingSave = nil
        pendingSessionSave = remember
        authenticate {
            let qr = try await self.client.loginQRCode(size: 360)
            try Task.checkCancellation()
            self.loginQRCode = qr.image
            self.status = "Scan with the Imou Life app."
            defer { self.loginQRCode = nil }
            // Imou reports "expire" itself; the deadline only stops polling a code it never expires.
            let deadline = Date().addingTimeInterval(330)
            var networkFailures = 0
            while true {
                do {
                    if try await self.client.pollLoginQRCode(qr.code) { return true }
                    networkFailures = 0
                } catch let error as URLError where error.code != .cancelled {
                    // Ride out brief drops (Wi-Fi switch, sleep); the code stays valid on Imou's side meanwhile.
                    networkFailures += 1
                    if networkFailures >= 5 { throw error }
                }
                guard Date() < deadline else { throw ImouError.message("The QR code expired. Show a new one to try again.") }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Signs in with a session saved by an earlier QR sign-in. A session Imou rejects is forgotten.
    func resumeSession(_ saved: SavedSession) {
        pendingSave = nil
        pendingSessionSave = false
        authenticate {
            do {
                try await self.client.resume(saved)
            } catch let error where !(error is URLError || error is CancellationError) {
                SavedSession.delete()
                throw error
            }
            return true
        }
    }

    func completeCaptcha(_ challenge: CaptchaChallenge, result: [String: Any]) {
        authenticate { try await self.client.verifyCaptcha(challenge, result: result) }
    }

    func sendTerminalCode() {
        guard !busy, (resendAvailableAt ?? .distantPast) <= Date() else { return }
        authenticate {
            try await self.client.sendTerminalCode()
            return false
        }
    }

    func authorizeTerminal(code: String) {
        authenticate {
            try await self.client.authorizeTerminal(code: code)
            return true
        }
    }

    private func authenticate(_ action: @escaping () async throws -> Bool) {
        guard !busy else { return }
        busy = true
        loadingAccount = true
        let run = UUID()
        operationId = run
        error = nil
        status = captcha == nil && !terminalVerification ? "Signing in…" : "Verifying with Imou…"
        operation = Task {
            defer { if operationId == run { busy = false; loadingAccount = false; loadingCameras = false } }
            do {
                let completed = try await action()
                try Task.checkCancellation()
                captcha = nil
                guard completed else {
                    terminalVerification = true
                    terminalCodeSent = true
                    resendAvailableAt = Date().addingTimeInterval(60)
                    status = "Imou sent a verification code to your registered account."
                    return
                }
                terminalVerification = false
                terminalCodeSent = false
                resendAvailableAt = nil
                signedIn = true
                // Keep at most one saved sign-in: the password, or the QR session.
                if let pendingSave {
                    self.pendingSave = nil
                    SavedSession.delete()
                    do { try pendingSave.save() } catch { self.error = error.localizedDescription }
                } else if pendingSessionSave, let session = client.savedSession {
                    pendingSessionSave = false
                    SavedCredentials.delete()
                    do { try session.save() } catch { self.error = error.localizedDescription }
                }
                status = "Loading cameras…"
                loadingCameras = true
                cameras = try await client.cameras()
                loadingCameras = false
                try Task.checkCancellation()
                selectedId = cameras.first { $0.id == lastCameraId }?.id ?? cameras.first?.id
                // Match the header switch: two views need 2 cameras, four need 3.
                if layout == 4 && cameras.count < 3 { layout = cameras.count < 2 ? 1 : 2 }
                if layout == 2 && cameras.count < 2 { layout = 1 }
                status = cameras.isEmpty ? "No cameras are available in this account." : "Select a camera to connect."
                loadingAccount = false
                if visible && selected != nil { connect() }
            } catch is CancellationError { }
            catch ImouError.captcha(let challenge) {
                guard operationId == run else { return }
                captcha = challenge
                status = "Complete the verification below to continue signing in."
            } catch ImouError.terminalVerification {
                guard operationId == run else { return }
                captcha = nil
                terminalVerification = true
                status = "Authorize this Mac with a code from Imou."
            } catch {
                guard operationId == run else { return }
                captcha = nil
                if !signedIn && !terminalVerification { client.signOut() }
                self.error = error.localizedDescription
                status = signedIn ? "Could not load cameras." : (terminalVerification ? "Verification did not finish." : "Sign-in failed.")
            }
        }
    }

    func connect() {
        guard layout == 1 else { connectGrid(); return }
        guard let camera = selected else { return }
        operation?.cancel()
        let run = UUID()
        operationId = run
        stream = nil
        error = nil
        busy = true
        status = "Connecting to \(camera.name)…"
        operation = Task {
            defer { if operationId == run { busy = false } }
            do {
                let direct = try await fetchStream(camera)
                if visible { stream = direct }
            } catch is CancellationError { }
            catch {
                guard operationId == run else { return }
                if let note = Self.retryNote(error) {
                    busy = false
                    scheduleReconnect(camera.id, note: note)
                } else {
                    self.error = error.localizedDescription; status = "Camera could not connect."
                }
            }
        }
    }

    func select(_ id: String?) {
        if let id { lastCameraId = id }
        cancelRetries()
        operation?.cancel()
        selectedId = id
        stream = nil
        busy = false
        error = nil
        if id != nil { connect() }
    }

    func setVisible(_ value: Bool, view: UUID) {
        if value { visibleViews.insert(view) } else { visibleViews.remove(view) }
        let value = !visibleViews.isEmpty
        guard visible != value else { return }
        visible = value
        if value && signedIn && selected != nil && !busy { connect() }
        if !value {
            cancelRetries()
            stopGrid()
            stream = nil
            if signedIn && !loadingAccount { operation?.cancel(); operationId = UUID(); busy = false }
        }
    }

    /// `forget` also removes the saved Keychain sign-in; cancelling or quitting keeps it.
    func signOut(forget: Bool = false) {
        if forget { SavedCredentials.delete(); SavedSession.delete() }
        pendingSave = nil
        pendingSessionSave = false
        signedIn = false
        loadingCameras = false
        operation?.cancel()
        operationId = UUID()
        loadingAccount = false
        operation = nil
        stream = nil
        cancelRetries()
        stopGrid()
        captcha = nil
        terminalVerification = false
        terminalCodeSent = false
        resendAvailableAt = nil
        loginQRCode = nil
        cameraCodes.removeAll()
        // Quit also signs out; keep quality choices then and drop them only on an explicit Sign Out.
        if forget { clearQualitySelections(); lastCameraId = nil }
        cameras.removeAll()
        selectedId = nil
        client.signOut()
        busy = false
        status = "Sign in to your Imou account."
        error = nil
    }

    func shutdown() { signOut() }
}
