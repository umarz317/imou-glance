import AppKit

@main
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    let model = PreviewModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let lifecycle = AppLifecycle()
        app.delegate = lifecycle
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "video", accessibilityDescription: "Imou Glance")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = PreviewViewController(model: model)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.reconnectNow() }
        }

        // The same content can be shown with --show for local UI inspection.
        let arguments = CommandLine.arguments
        if arguments.contains("--show") {
            let window = NSWindow(contentViewController: PreviewViewController(model: model))
            window.title = "Imou Glance"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            self.window = window
        }

        guard let index = arguments.firstIndex(of: "--credentials-file") else {
            if let saved = SavedCredentials.load() {
                model.signIn(account: saved.account, password: saved.password, areaCode: saved.areaCode)
            }
            return
        }
        do {
            guard index + 1 < arguments.count else { throw ImouError.message("Missing local credentials file path.") }
            let credentials = try LocalTestCredentials.read(path: arguments[index + 1])
            model.signIn(account: credentials.account, password: credentials.password, areaCode: credentials.countryCode)
        } catch {
            model.status = "Could not load local test credentials."
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    /// Standard About panel: name, icon, version, the "Unofficial" line from Info.plist and a one-line description.
    static func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: "Your Imou cameras, live from the menu bar.", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func showAboutFromMenu() { Self.showAbout() }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        // Accessory apps must activate for the popover's text fields to take input.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // Hidden in an accessory app, but supplies the standard editing shortcuts to text fields.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Imou Glance", action: #selector(AppLifecycle.showAboutFromMenu), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Imou Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}
