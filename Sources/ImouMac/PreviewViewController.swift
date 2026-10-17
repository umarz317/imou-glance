import AppKit
import Combine

@MainActor
final class PreviewViewController: NSViewController, NSTextFieldDelegate {
    private static let width: CGFloat = 440
    private static let inset: CGFloat = 20
    private static let contentWidth = width - inset * 2
    private static let accent = NSColor(red: 0.94, green: 0.40, blue: 0.12, alpha: 1)

    private let model: PreviewModel
    private let visibilityId = UUID()
    private var observation: AnyCancellable?
    private let root = NSStackView()

    // Header and footer
    private let spinner = NSProgressIndicator()
    private let optionsButton = NSButton()
    private let statusLabel = label("", size: 11, color: .secondaryLabelColor)
    private let statusDot = NSView()
    private let statusRow = NSStackView()
    private let footer = NSStackView()
    private let signInMessage = MessageBanner()
    private let footerMessage = MessageBanner()
    private var prominentHosts: [NSButton: NSView] = [:]

    // Sign in
    private let signInScreen = screenStack()
    private let accountField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let areaCodeField = NSTextField()
    private let signInButton = NSButton()
    private let methodControl = NSSegmentedControl(labels: ["Email", "Phone"], trackingMode: .selectOne, target: nil, action: nil)
    private var usesPhone: Bool { methodControl.selectedSegment == 1 }
    private let rememberCheckbox = NSButton(checkboxWithTitle: "Remember me in Keychain", target: nil, action: nil)

    // Captcha
    private let captchaScreen = screenStack()
    private let captchaHost = NSView()
    private var captchaView: CaptchaView?
    private var captchaId: UUID?
    private lazy var captchaHeight = captchaHost.heightAnchor.constraint(equalToConstant: Self.captchaCollapsed)
    private static let captchaCollapsed: CGFloat = 90
    private static let captchaExpanded: CGFloat = 420

    // Terminal verification
    private let terminalScreen = screenStack()
    private let sendCodeButton = NSButton()
    private let codeField = NSTextField()
    private let authorizeButton = NSButton()
    private let codeNote = label("Use the code sent by Imou. It is not saved.", size: 11, color: .secondaryLabelColor)
    private let terminalCancelButton = NSButton()
    private var resendTimer: Timer?

    // Cameras
    private let cameraScreen = screenStack()
    private let noCamerasScreen = screenStack()
    private let noCamerasIcon = NSImageView()
    private let noCamerasSpinner = NSProgressIndicator()
    private let noCamerasTitle = label("No cameras", size: 17, weight: .semibold)
    private let noCamerasDetail = label("Cameras from your Imou account will appear here.", size: 12, color: .secondaryLabelColor)
    private let cameraPopUp = NSPopUpButton()
    private let qualityPopUp = NSPopUpButton()
    private var cameraIds: [String] = []
    private let videoBox = NSView()
    private var player: DirectPlayerView?
    private let overlay = NSStackView()
    private let overlayIcon = NSImageView()
    private let overlaySpinner = NSProgressIndicator()
    private let overlayLabel = label("", size: 12, color: NSColor.white.withAlphaComponent(0.75))
    private let reconnectButton = NSButton()
    private let layoutControl = NSSegmentedControl()
    private let gridView = NSStackView()
    private var tiles: [String: CameraTile] = [:]
    private var tileOrder: [String] = []
    private var videoHeight: NSLayoutConstraint!
    private var liveBadge = NSView()

    init(model: PreviewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        NSLayoutConstraint.activate([statusDot.widthAnchor.constraint(equalToConstant: 7), statusDot.heightAnchor.constraint(equalToConstant: 7)])
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth - 15
        statusRow.setViews([statusDot, statusLabel], in: .leading)
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 2, left: Self.inset, bottom: 16, right: Self.inset)
        footer.addArrangedSubview(statusRow)
        footer.addArrangedSubview(footerMessage)
        footerMessage.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        buildSignIn(); buildCaptcha(); buildTerminal(); buildCamera(); buildNoCameras()
        for section in [header(), signInScreen, captchaScreen, terminalScreen, cameraScreen, noCamerasScreen, footer] {
            root.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            // Sections keep their natural height so fittingSize sizes the popover exactly.
            if let stack = section as? NSStackView, stack.orientation == .vertical {
                stack.setHuggingPriority(.required, for: .vertical)
            }
        }
        root.setHuggingPriority(.required, for: .vertical)
        statusLabel.isSelectable = true
        // The window or popover sizes the container; measuring the stack avoids its frame constraints.
        let container = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        let bottom = root.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor), bottom,
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        view = container
        observation = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.setVisible(true, view: visibilityId)
        render()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.setVisible(false, view: visibilityId)
    }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        let current: NSView
        if model.captcha != nil { current = captchaScreen }
        else if model.terminalVerification { current = terminalScreen }
        else if model.signedIn { current = model.cameras.isEmpty ? noCamerasScreen : cameraScreen }
        else { current = signInScreen }
        for screen in [signInScreen, captchaScreen, terminalScreen, cameraScreen, noCamerasScreen] {
            screen.isHidden = screen !== current
        }

        // Screens with their own progress (button title, video overlay, loading list) skip the header spinner.
        let headerSpinner = model.busy && (current === captchaScreen || current === terminalScreen)
        headerSpinner ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !headerSpinner
        statusLabel.stringValue = model.status
        let detail = model.error ?? ""
        let onSignIn = current === signInScreen
        signInMessage.set(detail)
        footerMessage.set(detail)
        signInMessage.isHidden = !onSignIn || detail.isEmpty
        footerMessage.isHidden = onSignIn || detail.isEmpty

        renderSignIn()
        renderCaptcha()
        renderNoCameras()
        renderTerminal(visible: current === terminalScreen)
        renderCamera(visible: current === cameraScreen)
        // Other screens show progress in place (button, video overlay, tiles, loading list);
        // only the code screen relies on the footer status. Errors still show everywhere.
        statusDot.layer?.backgroundColor = (model.busy ? Self.accent : .tertiaryLabelColor).cgColor
        statusRow.isHidden = current !== terminalScreen || !detail.isEmpty
        footer.isHidden = statusRow.isHidden && footerMessage.isHidden
        for (button, host) in prominentHosts { host.alphaValue = button.isEnabled ? 1 : 0.45 }
        // Stack views detach hidden screens while updating constraints, before the fitting size is valid.
        root.updateConstraintsForSubtreeIfNeeded()
        preferredContentSize = root.fittingSize
        // The --show window owns this controller directly; the popover follows preferredContentSize.
        if let window = view.window, window.contentViewController === self { window.setContentSize(preferredContentSize) }
    }

    private func renderSignIn() {
        for control in [accountField, passwordField, areaCodeField] { control.isEnabled = !model.busy }
        signInButton.title = model.busy ? "Signing in…" : "Sign In"
        methodControl.isEnabled = !model.busy
        rememberCheckbox.isEnabled = !model.busy
        // Kept enabled: a disabled glass button is nearly invisible. signIn() points at the missing field instead.
        signInButton.isEnabled = !model.busy
    }

    private func renderCaptcha() {
        guard captchaId != model.captcha?.id else { return }
        captchaView?.close()
        captchaView = nil
        captchaId = model.captcha?.id
        guard let challenge = model.captcha else { return }
        let captcha = CaptchaView(captchaId: challenge.captchaId, onResult: { [weak self] result in
            self?.model.completeCaptcha(challenge, result: result)
        }, onError: { [weak self] in self?.model.error = $0 }, onRetry: { [weak self] in
            self?.captchaId = nil
            self?.model.error = nil
            self?.render()
        }, onExpand: { [weak self] open in
            guard let self else { return }
            captchaHeight.constant = open ? Self.captchaExpanded : Self.captchaCollapsed
            render()
        })
        captchaHeight.constant = Self.captchaCollapsed
        captchaHost.addFilling(captcha)
        captchaView = captcha
    }

    private func renderTerminal(visible: Bool) {
        if visible && resendTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderTerminal(visible: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            resendTimer = timer
        } else if !visible {
            resendTimer?.invalidate()
            resendTimer = nil
            codeField.stringValue = ""
            return
        }
        let seconds = max(0, Int(ceil((model.resendAvailableAt ?? .distantPast).timeIntervalSinceNow)))
        sendCodeButton.title = seconds > 0 ? "Send Again in \(seconds)s" : (model.terminalCodeSent ? "Send Code Again" : "Send Verification Code")
        sendCodeButton.isEnabled = !model.busy && seconds == 0
        for view in [codeField, prominentHosts[authorizeButton]!, codeNote] { view.isHidden = !model.terminalCodeSent }
        codeField.isEnabled = !model.busy
        authorizeButton.isEnabled = !model.busy && !codeField.stringValue.isEmpty
        terminalCancelButton.isEnabled = !model.busy
    }

    private func renderCamera(visible: Bool) {
        let ids = model.cameras.map(\.id)
        if ids != cameraIds {
            cameraIds = ids
            cameraPopUp.removeAllItems()
            cameraPopUp.addItems(withTitles: model.cameras.map(\.name))
        }
        if let index = model.selectedId.flatMap(ids.firstIndex(of:)), cameraPopUp.indexOfSelectedItem != index {
            cameraPopUp.selectItem(at: index)
        }
        if let camera = model.selected {
            Self.updateQualityMenu(qualityPopUp, camera: camera, selected: model.quality(for: camera))
        }
        qualityPopUp.isHidden = model.layout > 1 || (model.selected?.qualities.count ?? 0) < 2
        qualityPopUp.isEnabled = !model.busy

        if visible, model.visible, let stream = model.stream {
            if let player { player.update(stream) } else {
                let cameraId = model.selectedId ?? ""
                let player = DirectPlayerView(stream: stream, onStatus: { [weak self] in
                    self?.model.playbackStatus($0, for: cameraId)
                }, onFailure: { [weak self] in self?.model.playbackFailed(for: cameraId) })
                videoBox.addFilling(player, below: overlay)
                self.player = player
            }
        } else if let player {
            player.close()
            self.player = nil
        }

        let grid = model.layout > 1
        layoutControl.isHidden = model.cameras.count < 2
        layoutControl.setEnabled(model.cameras.count >= 3, forSegment: 2)
        layoutControl.selectedSegment = [1: 0, 2: 1, 4: 2][model.layout] ?? 0
        videoHeight.constant = Self.videoHeight(layout: model.layout)
        renderGrid(visible: visible && grid)
        cameraPopUp.isHidden = grid
        gridView.isHidden = !grid
        videoBox.layer?.backgroundColor = (grid ? NSColor.clear : NSColor.black).cgColor

        let live = !grid && player != nil && model.status == "Live"
        // In-progress messages from the model and player all end with an ellipsis.
        let reconnecting = model.isReconnecting(model.selectedId)
        let working = model.busy || reconnecting || (player != nil && model.status.hasSuffix("…"))
        overlay.isHidden = live || grid
        liveBadge.isHidden = !live
        overlayIcon.isHidden = working
        overlaySpinner.isHidden = !working
        working ? overlaySpinner.startAnimation(nil) : overlaySpinner.stopAnimation(nil)
        overlayLabel.stringValue = player != nil || reconnecting ? model.status
            : (model.busy ? "Connecting…" : "Ready to connect")
        overlayIcon.image = NSImage(systemSymbolName: player != nil && !working ? "exclamationmark.triangle" : "video",
                                    accessibilityDescription: nil)
        reconnectButton.isEnabled = !model.busy
        // Grid tiles recover on their own and keep their own quality menus where this button would sit.
        reconnectButton.isHidden = grid
    }

    private static let tileGap: CGFloat = 6

    // Single and four-up keep the 16:9 card; two-up stacks two 16:9 tiles.
    private static func videoHeight(layout: Int) -> CGFloat {
        let single = (contentWidth * 9 / 16).rounded()
        return layout == 2 ? single * 2 + tileGap : single
    }

    private func renderGrid(visible: Bool) {
        let cameras = visible ? model.gridCameras : []
        let ids = cameras.map(\.id)
        if ids != tileOrder {
            tiles.values.forEach { $0.close() }
            tiles.removeAll()
            gridView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            tileOrder = ids
            let columns = model.layout == 4 ? 2 : 1
            var row: NSStackView?
            for (index, camera) in cameras.enumerated() {
                if index % columns == 0 {
                    let next = NSStackView()
                    next.distribution = .fillEqually
                    next.spacing = Self.tileGap
                    gridView.addArrangedSubview(next)
                    row = next
                }
                let tile = CameraTile(name: camera.name, changeQuality: { [weak self] id in
                    self?.model.selectQuality(id, for: camera.id)
                }) { [weak self] in
                    self?.model.layout = 1
                    self?.model.select(camera.id)
                }
                glassStyle(tile.qualityPopUp, shape: .capsule)
                tiles[camera.id] = tile
                row?.addArrangedSubview(tile)
            }
            // Keep an empty slot so a partly filled grid keeps equal tile sizes.
            if let row, row.arrangedSubviews.count < columns { row.addArrangedSubview(NSView()) }
        }
        for camera in cameras {
            if let tile = tiles[camera.id] {
                Self.updateQualityMenu(tile.qualityPopUp, camera: camera, selected: model.quality(for: camera))
            }
            tiles[camera.id]?.update(stream: model.gridStreams[camera.id], status: model.gridStatus[camera.id] ?? "",
                                     onStatus: { [weak self] in self?.model.playbackStatus($0, for: camera.id) },
                                     onFailure: { [weak self] in self?.model.playbackFailed(for: camera.id) })
        }
    }

    @objc private func changeLayout() {
        model.layout = [0: 1, 1: 2, 2: 4][layoutControl.selectedSegment] ?? 1
        render()
    }

    private static func updateQualityMenu(_ menu: NSPopUpButton, camera: ImouCamera, selected: CameraQuality) {
        let options = camera.qualities
        if menu.itemArray.compactMap({ $0.representedObject as? String }) != options.map(\.id) || menu.itemTitles != options.map(\.name) {
            menu.removeAllItems()
            for quality in options {
                menu.addItem(withTitle: quality.name)
                menu.lastItem?.representedObject = quality.id
            }
        }
        if let index = options.firstIndex(where: { $0.id == selected.id }) { menu.selectItem(at: index) }
        menu.isHidden = options.count < 2
    }

    // MARK: Actions

    @objc private func selectQuality() {
        guard let camera = model.selected, let id = qualityPopUp.selectedItem?.representedObject as? String else { return }
        model.selectQuality(id, for: camera.id)
    }

    @objc private func showOptions() {
        let menu = NSMenu()
        if model.signedIn { menu.addItem(item("Sign Out", #selector(signOutAndForget))) }
        let quit = NSMenuItem(title: "Quit Imou Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.maxY + 4), in: optionsButton)
    }

    @objc private func signIn() {
        guard !model.busy else { return }
        let account = trimmed(accountField)
        let digits = trimmed(areaCodeField).filter(\.isNumber)
        let missing: NSTextField? = usesPhone && digits.isEmpty ? areaCodeField
            : account.isEmpty ? accountField
            : passwordField.stringValue.isEmpty ? passwordField : nil
        if let missing { view.window?.makeFirstResponder(missing); NSSound.beep(); return }
        model.signIn(account: account, password: passwordField.stringValue, areaCode: usesPhone ? "+" + digits : "",
                     remember: rememberCheckbox.state == .on)
        passwordField.stringValue = ""
    }

    @objc private func changeSignInMethod() {
        areaCodeField.isHidden = !usesPhone
        accountField.placeholderString = usesPhone ? "Phone number" : "Email address"
        accountField.stringValue = ""
        view.window?.makeFirstResponder(usesPhone ? areaCodeField : accountField)
        render()
    }

    @objc private func signOut() { codeField.stringValue = ""; model.signOut() }
    @objc private func signOutAndForget() { codeField.stringValue = ""; model.signOut(forget: true) }
    @objc private func sendCode() { model.sendTerminalCode() }
    @objc private func reconnect() { model.reconnectNow() }

    @objc private func authorize() {
        guard !model.busy, !codeField.stringValue.isEmpty else { return }
        model.authorizeTerminal(code: codeField.stringValue)
        codeField.stringValue = ""
    }

    @objc private func selectCamera() {
        let index = cameraPopUp.indexOfSelectedItem
        guard cameraIds.indices.contains(index), cameraIds[index] != model.selectedId else { return }
        model.select(cameraIds[index])
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === codeField, codeField.stringValue.count > 6 {
            codeField.stringValue = String(codeField.stringValue.prefix(6))
        }
        render()
    }

    // MARK: Layout

    private func header() -> NSView {
        let glyph = icon("video.fill", size: 14, color: .white)
        // Glass reports its own alignment rect, which skews stack centring; a plain box aligns like any view.
        let badge = glass(glyph, cornerRadius: 17, tint: Self.accent, fallback: Self.accent)
        let icon = NSView()
        icon.addFilling(badge)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34)])
        let title = NSTextField(labelWithString: "Imou Glance")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.setAccessibilityLabel("Connecting")
        optionsButton.image = symbol("ellipsis", size: 13)
        glassStyle(optionsButton, shape: .circle)
        optionsButton.target = self
        optionsButton.action = #selector(showOptions)
        optionsButton.setAccessibilityLabel("Options")
        NSLayoutConstraint.activate([optionsButton.widthAnchor.constraint(equalToConstant: 24),
                                     optionsButton.heightAnchor.constraint(equalToConstant: 24)])
        let row = NSStackView()
        for view in [icon, title] { row.addView(view, in: .leading) }
        layoutControl.segmentCount = 3
        for (index, (symbolName, title)) in [("rectangle", "Single view"), ("rectangle.split.1x2", "Two cameras"),
                                             ("square.grid.2x2", "Four cameras")].enumerated() {
            layoutControl.setImage(symbol(symbolName, size: 12), forSegment: index)
            layoutControl.setToolTip(title, forSegment: index)
            layoutControl.setWidth(30, forSegment: index)
        }
        layoutControl.trackingMode = .selectOne
        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(changeLayout)
        layoutControl.setAccessibilityLabel("Camera layout")
        for view in [spinner, layoutControl, optionsButton] { row.addView(view, in: .trailing) }
        row.spacing = 10
        row.alignment = .centerY
        // Fixed height keeps the padding: the root's tight hugging otherwise squeezes the top inset away.
        // 16 above the 34pt badge; 4 below plus the screen's 12 top inset gives a matching 16.
        row.heightAnchor.constraint(equalToConstant: 16 + 34 + 4).isActive = true
        row.edgeInsets = NSEdgeInsets(top: 16, left: Self.inset, bottom: 4, right: Self.inset)
        return row
    }

    private func buildSignIn() {
        methodControl.selectedSegment = 0
        methodControl.segmentDistribution = .fillEqually
        methodControl.target = self
        methodControl.action = #selector(changeSignInMethod)
        methodControl.setAccessibilityLabel("Sign in with")
        accountField.placeholderString = "Email address"
        accountField.contentType = .username
        passwordField.placeholderString = "Imou password"
        passwordField.contentType = .password
        areaCodeField.placeholderString = "+92"
        areaCodeField.alignment = .center
        areaCodeField.setAccessibilityLabel("Country code")
        areaCodeField.isHidden = true
        areaCodeField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        accountField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Country code and number read as one phone entry; the code hides for email.
        let accountRow = NSStackView(views: [areaCodeField, accountField])
        accountRow.spacing = 8
        accountRow.distribution = .fill
        for field in [accountField, passwordField, areaCodeField] {
            field.delegate = self
            field.bezelStyle = .roundedBezel
            field.controlSize = .large
        }
        configure(signInButton, title: "Sign In", action: #selector(signIn), prominent: true)
        signInButton.keyEquivalent = "\r"
        addFull(signInScreen, [
            label("Sign in to Imou", size: 17, weight: .semibold),
            methodControl, accountRow, passwordField, rememberCheckbox, prominentHosts[signInButton]!,
            signInMessage
        ])
        signInScreen.setCustomSpacing(14, after: signInScreen.arrangedSubviews[0])
        signInScreen.setCustomSpacing(18, after: rememberCheckbox)
        signInScreen.setCustomSpacing(14, after: prominentHosts[signInButton]!)
        signInScreen.setCustomSpacing(14, after: signInMessage)
        rememberCheckbox.state = .on
        rememberCheckbox.toolTip = "Saved only in this Mac’s Keychain. Sign Out removes it. Camera keys are never saved."
        rememberCheckbox.font = .systemFont(ofSize: 12)
        if let saved = SavedCredentials.load() {
            methodControl.selectedSegment = saved.areaCode.isEmpty ? 0 : 1
            areaCodeField.isHidden = saved.areaCode.isEmpty
            areaCodeField.stringValue = saved.areaCode
            accountField.placeholderString = saved.areaCode.isEmpty ? "Email address" : "Phone number"
            accountField.stringValue = saved.account
        }
    }

    private func buildCaptcha() {
        captchaHeight.isActive = true
        let cancel = NSButton()
        configure(cancel, title: "Cancel Sign In", action: #selector(signOut))
        addFull(captchaScreen, [
            label("Verify it’s you", size: 17, weight: .semibold),
            label("Imou requires a security check before sign-in can continue.", size: 12, color: .secondaryLabelColor),
            captchaHost
        ])
        captchaScreen.addArrangedSubview(cancel)
    }

    private func buildTerminal() {
        let icon = icon("lock.desktopcomputer", size: 34, color: Self.accent)
        configure(sendCodeButton, title: "Send Verification Code", action: #selector(sendCode))
        codeField.placeholderString = "Verification code"
        codeField.contentType = .oneTimeCode
        codeField.delegate = self
        codeField.bezelStyle = .roundedBezel
        codeField.controlSize = .large
        configure(authorizeButton, title: "Authorize This Mac", action: #selector(authorize), prominent: true)
        authorizeButton.keyEquivalent = "\r"
        configure(terminalCancelButton, title: "Cancel Sign In", action: #selector(signOut))
        terminalScreen.addArrangedSubview(icon)
        addFull(terminalScreen, [
            label("Authorize this Mac", size: 17, weight: .semibold),
            label("Your Imou account has terminal binding enabled. Request a code at your registered account, then enter it here to authorize Imou Glance.", size: 12, color: .secondaryLabelColor)
        ])
        terminalScreen.addArrangedSubview(sendCodeButton)
        addFull(terminalScreen, [codeField, prominentHosts[authorizeButton]!, codeNote])
        terminalScreen.addArrangedSubview(terminalCancelButton)
    }

    private func buildCamera() {
        cameraPopUp.target = self
        cameraPopUp.action = #selector(selectCamera)
        cameraPopUp.setAccessibilityLabel("Camera")
        glassStyle(cameraPopUp, shape: .capsule)
        qualityPopUp.target = self
        qualityPopUp.action = #selector(selectQuality)
        qualityPopUp.setAccessibilityLabel("Video quality")
        qualityPopUp.toolTip = "Video quality"
        glassStyle(qualityPopUp, shape: .capsule)

        videoBox.wantsLayer = true
        videoBox.layer?.backgroundColor = NSColor.black.cgColor
        // Concentric with the popover's rounded glass.
        videoBox.layer?.cornerRadius = 18
        videoBox.layer?.cornerCurve = .continuous
        videoBox.layer?.masksToBounds = true
        // 16:9 at the popover's content width.
        videoHeight = videoBox.heightAnchor.constraint(equalToConstant: Self.videoHeight(layout: 1))
        videoHeight.isActive = true
        gridView.orientation = .vertical
        gridView.distribution = .fillEqually
        gridView.spacing = Self.tileGap
        gridView.isHidden = true
        videoBox.addFilling(gridView)
        overlayIcon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        overlayIcon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        overlaySpinner.style = .spinning
        overlaySpinner.appearance = NSAppearance(named: .darkAqua)
        overlayLabel.alignment = .center
        overlayLabel.preferredMaxLayoutWidth = Self.contentWidth - 40
        overlay.orientation = .vertical
        overlay.spacing = 10
        for view in [overlayIcon, overlaySpinner, overlayLabel] { overlay.addArrangedSubview(view) }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        videoBox.addSubview(overlay)

        // Controls float over the video in glass, so the picture keeps the full card.
        configure(reconnectButton, title: "", action: #selector(reconnect))
        reconnectButton.image = symbol("arrow.clockwise", size: 13)
        reconnectButton.toolTip = "Reconnect"
        reconnectButton.setAccessibilityLabel("Reconnect")
        glassStyle(reconnectButton, shape: .circle)
        let controls = NSStackView()
        controls.addView(cameraPopUp, in: .leading)
        controls.addView(qualityPopUp, in: .trailing)
        controls.addView(reconnectButton, in: .trailing)
        let bar = glassContainer(controls)
        bar.appearance = NSAppearance(named: .darkAqua)
        videoBox.addSubview(bar)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3
        let liveText = label("LIVE", size: 10, weight: .semibold, color: .white)
        let badgeContent = NSStackView(views: [dot, liveText])
        badgeContent.spacing = 5
        badgeContent.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 10)
        let badge = glass(badgeContent, cornerRadius: 11, tint: nil, fallback: NSColor.black.withAlphaComponent(0.5))
        badge.appearance = NSAppearance(named: .darkAqua)
        badge.setAccessibilityLabel("Live")
        liveBadge = badge
        videoBox.addSubview(badge)
        for view in [bar, badge] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: videoBox.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: videoBox.centerYAnchor, constant: -14),
            bar.leadingAnchor.constraint(equalTo: videoBox.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: videoBox.trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: videoBox.bottomAnchor, constant: -10),
            badge.topAnchor.constraint(equalTo: videoBox.topAnchor, constant: 10),
            badge.leadingAnchor.constraint(equalTo: videoBox.leadingAnchor, constant: 10),
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            // Insets + dot + spacing + text, measured directly: the stack's fitting size omitted the insets.
            badge.widthAnchor.constraint(equalToConstant: ceil(liveText.intrinsicContentSize.width) + 9 + 6 + 5 + 10 + 2),
            badge.heightAnchor.constraint(equalToConstant: 22)
        ])

        addFull(cameraScreen, [videoBox])
    }

    private func buildNoCameras() {
        noCamerasIcon.image = NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)
        noCamerasIcon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        noCamerasIcon.contentTintColor = .secondaryLabelColor
        noCamerasSpinner.style = .spinning
        noCamerasScreen.alignment = .centerX
        noCamerasScreen.spacing = 8
        noCamerasScreen.edgeInsets = NSEdgeInsets(top: 48, left: Self.inset, bottom: 48, right: Self.inset)
        for view in [noCamerasIcon, noCamerasSpinner, noCamerasTitle, noCamerasDetail] { noCamerasScreen.addArrangedSubview(view) }
    }

    private func renderNoCameras() {
        let loading = model.loadingCameras
        noCamerasIcon.isHidden = loading
        noCamerasSpinner.isHidden = !loading
        loading ? noCamerasSpinner.startAnimation(nil) : noCamerasSpinner.stopAnimation(nil)
        noCamerasTitle.stringValue = loading ? "Loading cameras…" : "No cameras"
        noCamerasDetail.isHidden = loading
    }

    // MARK: Helpers

    private static func screenStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // 12 under the header's 4pt bottom inset matches the 16pt above the badge.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: Self.inset, right: Self.inset)
        return stack
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        // Wrapping labels need an explicit width for the popover's fitting size.
        label.preferredMaxLayoutWidth = contentWidth
        return label
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        Self.label(text, size: size, weight: weight, color: color)
    }

    private func addFull(_ stack: NSStackView, _ views: [NSView]) {
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
    }

    private func configure(_ button: NSButton, title: String, action: Selector, prominent: Bool = false) {
        button.title = title
        button.target = self
        button.action = action
        guard prominent else { glassStyle(button, shape: .capsule); return }
        // Glass bezels nearly vanish on the popover's own glass, so the primary action sits in accent-tinted glass.
        button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.contentTintColor = .white
        let host = glass(button, cornerRadius: 18, tint: Self.accent, fallback: Self.accent)
        button.pinEdges(to: host)
        host.heightAnchor.constraint(equalToConstant: 36).isActive = true
        prominentHosts[button] = host
    }

    /// One inline line: a red icon and the reason, without a card or headline.
    private final class MessageBanner: NSStackView {
        private let text = NSTextField(wrappingLabelWithString: "")

        init() {
            super.init(frame: .zero)
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .systemRed
            icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            icon.setContentHuggingPriority(.required, for: .horizontal)
            text.font = .systemFont(ofSize: 12)
            text.textColor = .systemRed
            text.isSelectable = true
            text.preferredMaxLayoutWidth = PreviewViewController.contentWidth - 20
            setViews([icon, text], in: .leading)
            spacing = 6
            alignment = .firstBaseline
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func set(_ message: String) {
            text.stringValue = message.trimmingCharacters(in: .whitespacesAndNewlines)
            setAccessibilityLabel(text.stringValue)
        }
    }

    // Liquid Glass on macOS 26 and later; the standard bezel before that.
    private func glassStyle(_ button: NSButton, shape: GlassShape) {
        guard #available(macOS 26, *) else {
            button.bezelStyle = shape == .circle ? .circular : .push
            return
        }
        button.bezelStyle = .glass
        button.borderShape = shape == .circle ? .circle : .capsule
    }

    private enum GlassShape { case capsule, circle }

    private func glass(_ content: NSView, cornerRadius: CGFloat, tint: NSColor?, fallback: NSColor) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            // The glass lays out its content view; callers give the glass its size.
            return glass
        }
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = fallback.cgColor
        box.layer?.cornerRadius = cornerRadius
        box.addFilling(content)
        return box
    }

    // Lets neighbouring glass controls render and blend as one group.
    private func glassContainer(_ content: NSView) -> NSView {
        guard #available(macOS 26, *) else { return content }
        let container = NSGlassEffectContainerView()
        container.contentView = content
        container.spacing = 8
        content.pinEdges(to: container)
        return container
    }

    private func icon(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let view = NSImageView(image: symbol(name, size: size))
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? image
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One camera in the multi-view grid. Click opens it full size.
    private final class CameraTile: NSView {
        private var player: DirectPlayerView?
        private let status = NSTextField(labelWithString: "")
        private let name: NSTextField
        private let dot = NSView()
        private let open: () -> Void
        let qualityPopUp = NSPopUpButton()
        private let changeQuality: (String) -> Void

        init(name title: String, changeQuality: @escaping (String) -> Void, open: @escaping () -> Void) {
            self.open = open
            self.changeQuality = changeQuality
            name = NSTextField(labelWithString: title)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.cornerRadius = 12
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            status.font = .systemFont(ofSize: 11)
            status.textColor = NSColor.white.withAlphaComponent(0.75)
            status.alignment = .center
            status.lineBreakMode = .byTruncatingTail
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = .white
            name.lineBreakMode = .byTruncatingTail
            name.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black; return s }()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            let label = NSStackView(views: [dot, name])
            label.spacing = 5
            qualityPopUp.target = self
            qualityPopUp.action = #selector(selectQuality)
            qualityPopUp.controlSize = .small
            qualityPopUp.font = .systemFont(ofSize: 11)
            qualityPopUp.setAccessibilityLabel("Video quality for \(title)")
            qualityPopUp.toolTip = "Video quality"
            for view in [status, label, qualityPopUp] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                status.centerXAnchor.constraint(equalTo: centerXAnchor),
                status.centerYAnchor.constraint(equalTo: centerYAnchor),
                status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                qualityPopUp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                qualityPopUp.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)
            ])
            toolTip = "Open \(title)"
            setAccessibilityRole(.button)
            setAccessibilityLabel(title)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func mouseUp(with event: NSEvent) { open() }

        // Keep the quality control interactive while clicks on the picture open the camera.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let hit = super.hitTest(point), hit === qualityPopUp || hit.isDescendant(of: qualityPopUp) { return hit }
            return frame.contains(point) ? self : nil
        }

        @objc private func selectQuality() {
            if let id = qualityPopUp.selectedItem?.representedObject as? String { changeQuality(id) }
        }

        func update(stream: DirectStream?, status text: String, onStatus: @escaping (String) -> Void,
                    onFailure: @escaping () -> Void) {
            if let stream {
                if let player { player.update(stream) } else {
                    let player = DirectPlayerView(stream: stream, onStatus: onStatus, onFailure: onFailure)
                    addFilling(player)
                    self.player = player
                }
            } else {
                close()
            }
            let live = player != nil && text == "Live"
            status.stringValue = live ? "" : text
            status.toolTip = text
            dot.isHidden = !live
        }

        func close() {
            player?.close()
            player = nil
        }
    }
}
