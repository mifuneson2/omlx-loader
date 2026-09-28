import Foundation

/// The operations the menu offers, shared by the UI and `--selftest`.
final class Controller {
    let client: OMLXClient
    let service: ServiceController

    init(client: OMLXClient = OMLXClient()) {
        self.client = client
        self.service = ServiceController(client: client)
    }

    struct Snapshot {
        var running: Bool
        var status: ModelStatus?
    }

    func snapshot() async -> Snapshot {
        guard await client.isHealthy() else { return Snapshot(running: false, status: nil) }
        return Snapshot(running: true, status: try? await client.status())
    }

    func start() async throws {
        try await service.start()
    }

    func stop() async throws {
        try await service.stop()
    }

    /// Makes `id` the only loaded model: starts oMLX if needed, unloads the
    /// others (big models don't fit side by side), then loads `id`.
    func loadExclusive(_ id: String, progress: (String) -> Void = { _ in }) async throws {
        if !(await client.isHealthy()) {
            progress("Starting oMLX…")
            try await service.start()
        }
        let status = try await client.status()
        for other in status.loadedModels where other.id != id {
            progress("Unloading \(other.id)…")
            try await client.unload(other.id)
        }
        if status.models.first(where: { $0.id == id })?.loaded == true { return }
        progress("Loading \(id)…")
        try await client.load(id)
    }

    func unload(_ id: String) async throws {
        try await client.unload(id)
    }

    func unloadAll() async throws {
        for model in try await client.status().loadedModels {
            try await client.unload(model.id)
        }
    }
}

func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "?" }
    return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
}
