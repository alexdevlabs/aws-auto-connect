import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: DropdownPanel!
    private var termSource: DispatchSourceSignal?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTermSignal()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        panel = DropdownPanel(rootView: PanelView(model: model))
        installMainMenu()
        // Esc in Settings goes back to the status; on the status it closes the panel.
        panel.onEscape = { [weak self] in
            guard let self, self.model.showingSettings else { return false }
            self.model.closeSettings()
            return true
        }

        model.onChange = { [weak self] in self?.refreshIcon() }
        model.start()
        refreshIcon()

        UNUserNotificationCenter.current().delegate = self
        // --show-panel[=<tab id>,…], e.g. --show-panel=status,dns: a snapshot of each (debug aid).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--show-panel") }) {
            let pages = arg.split(separator: "=", maxSplits: 1).dropFirst().first?.split(separator: ",").map(String.init) ?? []
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.togglePanel()
                for (i, page) in (pages.isEmpty ? ["status"] : pages).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i)) {
                        if page == "status" { self.model.closeSettings() } else { self.model.openSettings(page) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i) + 1) {
                        self.panel.saveSnapshot(name: pages.isEmpty ? nil : page)
                    }
                }
            }
        }
    }

    /// Quitting (menu, logout, `kill`, an update replacing the app) closes the VPN first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard model.needsShutdown || VPNHelper.isTunnelRunning else { return .terminateNow }
        quitting = true
        panel?.close()
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// SIGTERM (`kill`, `pkill`) goes through the normal quit so the VPN is closed too.
    private func handleTermSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Quit from the run loop, not from inside this main-queue block: the shutdown work below
        // also runs on the main queue and would wait behind it forever.
        source.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        source.resume()
        termSource = source
    }

    // Clicking a notification opens the sign-in window if a flow is waiting on it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            if model.signInNeeded { model.showSignIn() }
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        if panel.isVisible {
            panel.close()
        } else {
            model.showingSettings = false
            panel.show(below: buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)))
        }
    }

    /// Never shown (the app has no menu bar of its own), but it's what makes ⌘C/⌘V and Undo work in
    /// the panel's text fields.
    private func installMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        let item = NSMenuItem()
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }

    private func refreshIcon() {
        statusItem.button?.image = StatusIcon.image(for: model.health)
        statusItem.button?.toolTip = model.tooltip
    }
}

/// A floating panel placed under the menu bar icon when opened. Unlike NSPopover it isn't
/// attached to the icon, so it stays put when a full-screen app hides the menu bar.
/// Closes on a click outside or Esc (which first goes back from Settings).
final class DropdownPanel: NSPanel {
    /// Room around the visible panel for its SwiftUI-drawn shadow.
    private static let margin: CGFloat = 24
    private var monitors: [Any] = []
    private var hosting: NSHostingView<AnyView>!
    /// The window never resizes while open (a resize redraws one frame at the old origin, which makes
    /// the header twitch). It is tall enough for any state; the panel is drawn at its top.
    private static let maxPanelHeight: CGFloat = 560
    private var panelSize = CGSize(width: 380, height: 300)
    /// Esc first asks this; it returns true when it handled the key (e.g. went back from Settings).
    var onEscape: (() -> Bool)?

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // drawn by SwiftUI so it follows the animated height
        isReleasedWhenClosed = false

        // The window is clear and at least as tall as the panel; SwiftUI draws the rounded panel at
        // the top and animates its height, so a state change never snaps or crops.
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let chrome = rootView
            .fixedSize()
            .background(VisualEffect())
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .background(shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.25), radius: 14, y: 6))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                DispatchQueue.main.async { self?.panelSize = size }
            }
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        hosting = NSHostingView(rootView: AnyView(chrome))
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    func show(below anchor: NSRect) {
        let size = hosting.fittingSize
        if size.width > 0, size.height > 0 {
            panelSize = CGSize(width: size.width - 2 * Self.margin, height: size.height - 2 * Self.margin)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let bounds = screen?.frame ?? .zero
        let w = panelSize.width, h = max(panelSize.height, Self.maxPanelHeight), m = Self.margin
        let x = min(max(anchor.midX - w / 2, bounds.minX + 8), bounds.maxX - w - 8)
        setFrame(NSRect(x: x - m, y: anchor.minY - 6 - h - m, width: w + 2 * m, height: h + 2 * m), display: true)
        orderFrontRegardless()
        makeKey()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        // A click in the clear margin around the panel counts as outside.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self else { return event }
            let m = Self.margin
            let visible = NSRect(x: m, y: self.frame.height - m - self.panelSize.height,
                                 width: self.panelSize.width, height: self.panelSize.height)
            if !visible.contains(event.locationInWindow) { self.close(); return nil }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                if self?.onEscape?() != true { self?.close() }
                return nil
            }
            return event
        } as Any)
    }

    /// Debug aid (--show-panel): writes what the panel drew to ~/Library/Logs.
    func saveSnapshot(name: String? = nil) {
        guard let view = contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = LogFiles.folder.appendingPathComponent("AWSAutoConnect-panel\(name.map { "-" + $0 } ?? "").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    override func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        super.close()
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
