import AppKit

/// `oMLXLoader --selftest [model]` exercises the real controller code without the UI:
/// start (if stopped) → load a small model → unload → stop again (if it was stopped).
/// It refuses to run if another model is loaded, so it never evicts your work.
func runSelfTest(model: String) async -> Int32 {
    let controller = Controller()
    func log(_ s: String) { print("[selftest] \(s)") }
    func check(_ ok: Bool, _ what: String) throws {
        log("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { throw ServiceError.timeout("check failed: \(what)") }
    }
    do {
        let before = await controller.snapshot()
        log("oMLX initially \(before.running ? "running" : "stopped")")
        let alreadyLoaded = before.status?.loadedModels.map(\.id) ?? []
        if !alreadyLoaded.isEmpty {
            // Don't evict the user's model: load the test model alongside it instead.
            log("\(alreadyLoaded.joined(separator: ", ")) is loaded; testing side by side without unloading it")
            try await controller.client.load(model)
            let mid = await controller.snapshot()
            try check(Set(mid.status?.loadedModels.map(\.id) ?? []) == Set(alreadyLoaded + [model]),
                      "\(model) loaded alongside \(alreadyLoaded.joined(separator: ", "))")
            try await controller.unload(model)
            let end = await controller.snapshot()
            try check(end.status?.loadedModels.map(\.id) == alreadyLoaded,
                      "\(model) unloaded, \(alreadyLoaded.joined(separator: ", ")) still loaded")
            log("PASSED (side-by-side mode; start/stop and exclusive load not exercised)")
            return 0
        }

        try await controller.loadExclusive(model) { log($0) }
        let afterLoad = await controller.snapshot()
        try check(afterLoad.running, "oMLX running after load")
        try check(afterLoad.status?.loadedModels.map(\.id) == [model], "\(model) is the only loaded model")

        try await controller.unload(model)
        let afterUnload = await controller.snapshot()
        try check(afterUnload.status?.loadedModels.isEmpty == true, "no model loaded after unload")

        if !before.running {
            log("Stopping oMLX to restore the initial state…")
            try await controller.stop()
            let end = await controller.snapshot()
            try check(!end.running, "oMLX stopped again")
        }
        log("ALL PASSED")
        return 0
    } catch {
        log("ERROR: \(error.localizedDescription)")
        return 1
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest") {
    let model = args.count > i + 1 ? args[i + 1] : "readerlm-v2"
    Task {
        exit(await runSelfTest(model: model))
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
