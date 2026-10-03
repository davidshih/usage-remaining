import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UsageCore

/// Hosting view that drags the panel by its whole surface and toggles compact mode on double-click.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let autosaveName = "UsageWidgetPanel"
    private let store = UsageStore()
    private var panel: NSPanel!
    private var hostingView: DraggableHostingView<WidgetView>!
    private var statusItem: NSStatusItem!
    private var timers: [Timer] = []
    private var cancellables: Set<AnyCancellable> = []

    private var toggleWidgetItem: NSMenuItem!
    private var compactItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpPanel()
        setUpStatusItem()
        initializeLoginItemOnFirstRun()

        store.refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refreshIfResetPassed() }
        })
    }

    // MARK: Panel

    private func setUpPanel() {
        let hosting = DraggableHostingView(rootView: WidgetView(store: store))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onDoubleClick = { [weak self] in self?.store.compact.toggle() }
        hostingView = hosting

        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        self.panel = panel

        let restored = panel.setFrameUsingName(autosaveName)
        if !restored, let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
        }
        panel.setFrameAutosaveName(autosaveName)
        fitPanelToContent()
        panel.orderFrontRegardless()

        // Content height/width changes (compact toggle, rows appearing): resize after SwiftUI lays out.
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitPanelToContent() } }
            .store(in: &cancellables)
    }

    /// Resizes the panel to the content's fitting size, keeping its top-left corner fixed.
    private func fitPanelToContent() {
        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "Usage") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "◔"
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        toggleWidgetItem = menu.addItem(withTitle: "Hide Widget", action: #selector(toggleWidget), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        compactItem = menu.addItem(withTitle: "Compact Mode", action: #selector(toggleCompact), keyEquivalent: "")
        loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        updateMenuState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenuState() }

    private func updateMenuState() {
        toggleWidgetItem.title = panel.isVisible ? "Hide Widget" : "Show Widget"
        compactItem.state = store.compact ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        updateMenuState()
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func toggleCompact() {
        store.compact.toggle()
        updateMenuState()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            // Swallowed: the checkmark below always reflects the real status.
        }
        updateMenuState()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Login item

    private func initializeLoginItemOnFirstRun() {
        let key = "loginItemInitialized"
        guard Bundle.main.bundleURL.pathExtension == "app",
              !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }
}

// Top-level code runs on the main thread; the delegate and store are main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
