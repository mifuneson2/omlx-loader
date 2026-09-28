import Foundation

/// Starts and stops the oMLX Homebrew service.
///
/// Never kill the oMLX process directly: the brew launch agent has KeepAlive on,
/// so launchd restarts it immediately. `brew services stop` unloads the agent,
/// which also turns off start-at-login until `brew services start` is run again.
final class ServiceController {
    static let formula = "jundot/omlx/omlx"

    private let client: OMLXClient

    init(client: OMLXClient) {
        self.client = client
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() async throws {
        try await brew(["services", "start", Self.formula])
        // The server needs a few seconds after launchd starts it.
        for _ in 0..<60 {
            if await client.isHealthy() { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ServiceError.timeout("oMLX didn't respond within 60 seconds of starting. Check /opt/homebrew/var/log/omlx.log.")
    }

    func stop() async throws {
        try await brew(["services", "stop", Self.formula])
        for _ in 0..<30 {
            if !(await client.isHealthy()) { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ServiceError.timeout("oMLX was still answering 30 seconds after stopping.")
    }

    // MARK: - Private

    @discardableResult
    private func brew(_ args: [String]) async throws -> String {
        guard let brew = Self.brewPath else { throw ServiceError.noBrew }
        return try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = args
            // GUI apps don't inherit the shell PATH; give brew a sane one.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    cont.resume(throwing: ServiceError.brewFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

enum ServiceError: LocalizedError {
    case noBrew
    case brewFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .noBrew: return "Homebrew not found at /opt/homebrew/bin/brew"
        case .brewFailed(let out): return "brew failed: \(out.suffix(300))"
        case .timeout(let msg): return msg
        }
    }
}
