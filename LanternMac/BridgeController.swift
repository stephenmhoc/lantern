import AppKit
import Foundation
import Network
import Observation
import os
import ServiceManagement

/// Runs `lantern-bridge` (built from `Bridge/` into the app) for as long as Lantern is open, and
/// talks to it over its admin socket. A bridge already running (started from the command line)
/// is used as it is.
@Observable
final class BridgeController {
    /// What the bridge says about itself (`GET /status`).
    struct Status: Decodable, Equatable {
        var name: String
        var version: String
        var port: Int
        var fingerprint: String
        var addresses: [String]
        var backends: [Backend]
        var models: [Model]
        var devices: [Device]
        var keepLoaded: [String]
    }

    struct Backend: Decodable, Equatable, Identifiable {
        var id: String
        var name: String
        var url: String
    }

    struct Model: Decodable, Equatable, Identifiable {
        struct Info: Decodable, Equatable {
            var backend: String
            var backend_name: String
            var name: String
            var vision: Bool
            var tools: Bool
            var thinking: Bool
            var context_length: Int?
            var size: Int64?
        }
        var id: String
        var owned_by: String
        var lantern: Info
    }

    struct Device: Decodable, Equatable, Identifiable {
        var id: String
        var name: String
        var paired: Date
        var lastSeen: Date?
    }

    struct Pairing: Decodable, Equatable {
        var link: String
        var expires: Date
    }

    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var status: Status?
    /// Ollama answers on the network directly, without the bridge (`OLLAMA_HOST=0.0.0.0`).
    private(set) var ollamaIsExposed = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var restarts: [Date] = []

    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Lantern/Bridge", directoryHint: .isDirectory)
    }

    nonisolated static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Lantern/bridge.log")
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        Task { await start() }
        // Devices can only use this Mac's models while Lantern runs: open at login from the
        // first launch on. Once only, so turning it off sticks.
        if !UserDefaults.standard.bool(forKey: "setUpOpenAtLogin") {
            UserDefaults.standard.set(true, forKey: "setUpOpenAtLogin")
            opensAtLogin = true
        }
    }

    // MARK: - Running it

    func start() async {
        stopping = false
        if await (try? AdminSocket.status()) != nil {
            state = .running  // one is already running: use it
        } else {
            launch()
        }
        poll()
    }

    private func launch() {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "lantern-bridge") else {
            state = .failed("The bridge is missing from Lantern. Reinstall Lantern.")
            return
        }
        try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logFile.path) {
            FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: Self.logFile)
        _ = try? log?.seekToEnd()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            Task { @MainActor in self?.ended(code: code) }
        }
        do {
            try process.run()
            self.process = process
            state = .starting
        } catch {
            state = .failed("The bridge couldn't start: \(error.localizedDescription)")
        }
    }

    /// The bridge stopped: started again, unless Lantern is quitting or it keeps failing.
    private func ended(code: Int32) {
        process = nil
        guard !stopping else { return }
        restarts = restarts.filter { $0.timeIntervalSinceNow > -60 } + [.now]
        if restarts.count > 3 {
            state = .failed("The bridge keeps stopping (exit \(code)). Its log: ~/Library/Logs/Lantern/bridge.log")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !self.stopping { self.launch() }
        }
    }

    func stop() {
        stopping = true
        poller?.cancel()
        process?.terminate()
    }

    func restart() {
        stop()
        restarts = []
        Task {
            try? await Task.sleep(for: .seconds(1))
            await start()
        }
    }

    /// Asks the bridge how things are every few seconds; models and devices change on their own.
    private func poll() {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func refresh() async {
        do {
            let fresh = try await AdminSocket.status()
            if fresh != status { status = fresh }
            if state != .running { state = .running }
            await checkOllama(fresh)
        } catch {
            if process == nil, case .running = state { state = .starting }
        }
    }

    // MARK: - What the bridge does

    func newPairing() async throws -> Pairing {
        try await AdminSocket.decode(Pairing.self, "POST", "/pairing")
    }

    func remove(_ device: Device) async {
        _ = try? await AdminSocket.request("DELETE", "/devices/\(device.id)")
        await refresh()
    }

    func keepLoaded(_ model: Model, _ keep: Bool) async {
        let body = try? JSONSerialization.data(withJSONObject: ["model": model.id, "keep": keep])
        _ = try? await AdminSocket.request("PUT", "/keep-loaded", body: body)
        await refresh()
    }

    // MARK: - Ollama on the network

    /// Whether Ollama also answers on one of this Mac's network addresses, which lets anything on
    /// the network use it unencrypted and without pairing.
    private func checkOllama(_ status: Status) async {
        guard status.backends.contains(where: { $0.id == "ollama" }) else {
            ollamaIsExposed = false
            return
        }
        let ips = status.addresses.compactMap { address -> String? in
            let host = address.split(separator: ":").dropLast().joined(separator: ":")
            return host.allSatisfy { $0.isNumber || $0 == "." } ? host : nil
        }
        var exposed = false
        for ip in ips where await Self.answers(host: ip, port: 11434) {
            exposed = true
            break
        }
        if exposed != ollamaIsExposed { ollamaIsExposed = exposed }
    }

    nonisolated private static func answers(host: String, port: UInt16) async -> Bool {
        let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: Bool) {
                guard done.withLock({ let first = !$0; $0 = true; return first }) else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { finish(false) }
        }
    }

    /// Ollama on this Mac only (`OLLAMA_HOST=127.0.0.1:11434`), restarted so it takes effect.
    /// Devices reach it through the bridge.
    func makeOllamaPrivate() async {
        let run = { (path: String, args: [String]) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }
        run("/bin/launchctl", ["setenv", "OLLAMA_HOST", "127.0.0.1:11434"])
        run("/usr/bin/pkill", ["-x", "Ollama"])
        run("/usr/bin/pkill", ["-f", "Ollama.app/Contents/Resources/ollama"])
        try? await Task.sleep(for: .seconds(2))
        // The app's own "Expose Ollama to the network" overrides OLLAMA_HOST: off, while it's stopped.
        let db = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Ollama/db.sqlite")
        if FileManager.default.fileExists(atPath: db.path) {
            run("/usr/bin/sqlite3", [db.path, "update settings set expose = 0;"])
        }
        run("/usr/bin/open", ["-a", "Ollama"])
        try? await Task.sleep(for: .seconds(5))
        await refresh()
    }

    // MARK: - Open at login

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

/// HTTP/1.0 over the bridge's admin socket (`admin.sock` in its folder): one request per
/// connection, the answer read to the end.
nonisolated enum AdminSocket {
    struct Failure: Error { let status: Int; let body: String }

    static func status() async throws -> BridgeController.Status {
        try await decode(BridgeController.Status.self, "GET", "/status")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: Data? = nil) async throws -> T {
        let (code, data) = try await request(method, path, body: body)
        guard code < 300 else { throw Failure(status: code, body: String(decoding: data, as: UTF8.self)) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            return .distantPast  // Go's zero time: never
        }
        return try decoder.decode(T.self, from: data)
    }

    static func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        let socketPath = BridgeController.folder.appending(path: "admin.sock").path
        return try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard socketPath.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: socketPath.utf8)
                raw[socketPath.utf8.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var message = Data("\(method) \(path) HTTP/1.0\r\nHost: bridge\r\nContent-Length: \(body?.count ?? 0)\r\n\r\n".utf8)
            if let body { message.append(body) }
            let sent = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard sent == message.count else { throw POSIXError(.EIO) }
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                response.append(buffer, count: n)
            }
            guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw POSIXError(.EBADMSG) }
            let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
            let code = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            return (code, Data(response[split.upperBound...]))
        }.value
    }
}
