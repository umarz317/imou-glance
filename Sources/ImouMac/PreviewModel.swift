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

    /// Waits 2, 4, 8, 16, then 30 seconds between attempts while the camera is on screen.
    /// A minute of healthy playback resets the backoff, so a long session recovers quickly from a one-off drop.
    private func scheduleReconnect(_ cameraId: String) {
        guard visible, signedIn else { return }
        if let since = liveSince.removeValue(forKey: cameraId), Date().timeIntervalSince(since) >= 60 {
            retryAttempts[cameraId] = 0
        }
        let attempt = (retryAttempts[cameraId] ?? 0) + 1
        retryAttempts[cameraId] = attempt
        let delay = min(30, 1 << min(attempt, 5))
        let note = "Connection lost. Reconnecting…"
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

    private static func isNetworkError(_ error: Error) -> Bool { error is URLError }

    func connectGrid() {
        stopGrid()
        guard visible, signedIn else { return }
        for camera in gridCameras { connectTile(camera) }
    }

    func connectTile(_ camera: ImouCamera) {
        gridTasks[camera.id]?.cancel()
        gridStreams[camera.id] = nil
        gridStatus[camera.id] = "Connecting…"
        gridTasks[camera.id] = Task {
            do {
                let direct = try await fetchStream(camera)
                if visible && layout > 1 { gridStreams[camera.id] = direct }
            } catch is CancellationError { }
            catch where Self.isNetworkError(error) { scheduleReconnect(camera.id) }
            catch { gridStatus[camera.id] = error.localizedDescription }
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
        authenticate {
            try await self.client.signIn(account: account, password: password, areaCode: areaCode)
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
                if let pendingSave {
                    self.pendingSave = nil
                    do { try pendingSave.save() } catch { self.error = error.localizedDescription }
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
            catch where Self.isNetworkError(error) {
                guard operationId == run else { return }
                busy = false
                scheduleReconnect(camera.id)
            }
            catch {
                guard operationId == run else { return }
                self.error = error.localizedDescription; status = "Camera could not connect."
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
        if forget { SavedCredentials.delete() }
        pendingSave = nil
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
