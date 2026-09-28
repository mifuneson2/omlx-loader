import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private var snapshot = Controller.Snapshot(running: false, status: nil)
    private var busy: String?          // set while an action is in progress
    private var lastError: String?
    private var lastKnownModels: [String] = []

    private var menuIsOpen = false
    private var renderedSignature = ""   // state the open menu was built from
    private var memoryItem: NSMenuItem?  // updated in place so an open submenu isn't disturbed

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        // Poll so the icon reflects state changes made elsewhere (terminal, admin page).
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    // MARK: - State

    private func refresh() {
        Task { @MainActor in
            apply(await controller.snapshot())
            render()
        }
    }

    private func apply(_ snap: Controller.Snapshot) {
        snapshot = snap
        if let models = snap.status?.models.map(\.id), !models.isEmpty { lastKnownModels = models }
    }

    /// Fetches state off the main thread, waiting at most `timeout` so opening the
    /// menu never hangs. Returns nil if oMLX didn't answer in time.
    private func fetchSnapshot(waitingAtMost timeout: TimeInterval) -> Controller.Snapshot? {
        final class Box: @unchecked Sendable { var value: Controller.Snapshot? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let controller = self.controller
        Task.detached {
            box.value = await controller.snapshot()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? box.value : nil
    }

    /// Updates the icon, and the menu too if it's open and what it shows has changed.
    private func render() {
        updateIcon()
        guard menuIsOpen else { return }
        if signature() != renderedSignature {
            rebuildMenu()
        } else {
            memoryItem?.title = memoryText()
        }
    }

    /// Everything the menu shows except the memory figure, which changes constantly while loading.
    private func signature() -> String {
        let models = (snapshot.status?.models ?? []).map { "\($0.id):\($0.loaded):\($0.isLoading)" }
        return ([headline(), "\(snapshot.running)", lastError ?? "", busy ?? ""] + models).joined(separator: "|")
    }

    private func memoryText() -> String {
        guard let status = snapshot.status else { return "" }
        return "Memory in use: \(formatBytes(status.currentModelMemory)) of \(formatBytes(status.maxModelMemory))"
    }

    private func perform(_ label: String, _ action: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        lastError = nil
        render()
        Task { @MainActor in
            do {
                try await action()
            } catch {
                lastError = error.localizedDescription
            }
            busy = nil
            apply(await controller.snapshot())
            render()
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let loading = busy != nil || !(snapshot.status?.loadingModels.isEmpty ?? true)
        let loaded = !(snapshot.status?.loadedModels.isEmpty ?? true)
        let symbol: String
        if lastError != nil { symbol = "exclamationmark.triangle" }
        else if loading { symbol = "hourglass" }
        else if loaded { symbol = "cpu.fill" }
        else { symbol = "cpu" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "oMLX")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !snapshot.running && busy == nil && lastError == nil
        button.toolTip = headline()
    }

    private func headline() -> String {
        if let busy { return busy }
        guard snapshot.running else { return "oMLX is stopped" }
        let loaded = snapshot.status?.loadedModels.map(\.id) ?? []
        return loaded.isEmpty ? "oMLX is running · no model loaded" : "oMLX is running · \(loaded.joined(separator: ", "))"
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // Show current state, not the last poll (up to 3 s old). If oMLX is slow to
        // answer, open with the cached state; the next poll updates the open menu.
        if let fresh = fetchSnapshot(waitingAtMost: 0.3) { apply(fresh) }
        updateIcon()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        renderedSignature = signature()
        memoryItem = nil
        let idle = busy == nil
        let status = snapshot.status

        menu.addItem(info(headline()))
        if snapshot.running, status != nil {
            let item = info(memoryText())
            memoryItem = item
            menu.addItem(item)
        }
        if let lastError {
            menu.addItem(info("⚠︎ \(lastError)"))
        }
        menu.addItem(.separator())

        // Service
        if snapshot.running {
            menu.addItem(action("Stop oMLX", #selector(stopService), enabled: idle))
            menu.addItem(info("   Also turns off start at login"))
        } else {
            menu.addItem(action("Start oMLX", #selector(startService), enabled: idle))
        }
        menu.addItem(.separator())

        // Load
        let loadItem = NSMenuItem(title: "Load Model", action: nil, keyEquivalent: "")
        let loadMenu = NSMenu()
        loadMenu.autoenablesItems = false
        let models: [(id: String, detail: String, loaded: Bool, loading: Bool)]
        if let status {
            models = status.models.map { ($0.id, formatBytes($0.estimatedSize), $0.loaded, $0.isLoading) }
        } else {
            let names = lastKnownModels.isEmpty ? controller.client.settings.modelsOnDisk() : lastKnownModels
            models = names.map { ($0, "", false, false) }
        }
        for m in models {
            var title = m.detail.isEmpty ? m.id : "\(m.id)  —  \(m.detail)"
            if m.loading { title += "  (loading…)" }
            let item = action(title, #selector(loadModel(_:)), enabled: idle && !m.loaded && !m.loading)
            item.representedObject = m.id
            item.state = m.loaded ? .on : .off
            loadMenu.addItem(item)
        }
        if models.isEmpty { loadMenu.addItem(info("No models found")) }
        loadMenu.addItem(.separator())
        loadMenu.addItem(info("Loading a model unloads the others first"))
        if !snapshot.running { loadMenu.addItem(info("oMLX will be started first")) }
        loadItem.submenu = loadMenu
        menu.addItem(loadItem)

        // Unload
        let loaded = status?.loadedModels ?? []
        if loaded.isEmpty {
            menu.addItem(action("Unload Model", nil, enabled: false))
        } else {
            for m in loaded {
                let item = action("Unload \(m.id)", #selector(unloadModel(_:)), enabled: idle)
                item.representedObject = m.id
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        menu.addItem(action("Open oMLX Dashboard", #selector(openDashboard), enabled: snapshot.running))
        let login = action("Open oMLX Loader at Login", #selector(toggleLoginItem), enabled: true)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Quit oMLX Loader", #selector(quit), enabled: true, key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector?, enabled: Bool, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // MARK: - Actions

    @objc private func startService() {
        perform("Starting oMLX…") { try await self.controller.start() }
    }

    @objc private func stopService() {
        perform("Stopping oMLX…") { try await self.controller.stop() }
    }

    @objc private func loadModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform("Loading \(id)…") {
            try await self.controller.loadExclusive(id) { step in
                Task { @MainActor in
                    guard self.busy != nil else { return } // action already finished
                    self.busy = step
                    self.render()
                }
            }
        }
    }

    @objc private func unloadModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform("Unloading \(id)…") { try await self.controller.unload(id) }
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(controller.client.dashboardURL)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Couldn't change login item: \(error.localizedDescription)"
            render()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
