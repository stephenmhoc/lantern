#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import ServiceManagement

/// Everything a Mac that serves does (`MacRole.serve`), and nothing a Mac that doesn't ever
/// touches: the bridge and its LaunchAgent, pairing devices, and this Mac's own chats.
///
/// The bridge (`lantern-bridge`, in the app's Contents/MacOS) isn't a child of the app: launchd
/// runs it from the agent in Contents/Library/LaunchAgents, registered here with `SMAppService`,
/// so it serves at login and while Lantern is closed. It runs Splash (Inkling), keeps it running
/// and stops it with itself (Bridge/README.md). Lantern talks to it over its admin socket.
/// The app's own chats reach it like any device: paired (over the socket, no code to scan), on
/// 127.0.0.1, its certificate pinned, so `MacLink` works unchanged.
@Observable
final class MacServer {
    static let shared = MacServer()

    enum State: Equatable {
        case off
        case starting
        case running
        /// Turned off in System Settings › Login Items: only the user can turn it back on.
        case needsApproval
        case failed(String)
    }

    /// What the bridge says about itself (`GET /status` on its admin socket, snake case).
    struct Status: Decodable, Equatable {
        var name: String
        var version: String?
        var port: Int
        var fingerprint: String
        var splash: Splash?
        var devices: [PairedDevice]
        var tailscale: Tailscale?
        var pairingCodeExpires: Date?
    }

    /// Splash, as the bridge runs it.
    struct Splash: Decodable, Equatable {
        /// "starting", "ready" or "failed".
        var state: String
        /// Why it failed, or what it's doing.
        var message: String?
        var version: String?
        var model: String?
        var restarts: Int?
        var drafter: Drafter?

        var isReady: Bool { state == "ready" }
        var isFailed: Bool { state == "failed" }
    }

    /// The drafter's work on the last reply.
    struct Drafter: Decodable, Equatable {
        var acceptRate: Double?
        var tokensPerStep: Double?
        var tokensPerSecond: Double?
    }

    /// The Tailscale OAuth client that makes join keys for paired devices (never its secret).
    struct Tailscale: Decodable, Equatable {
        var configured: Bool
        var clientId: String?
        var tag: String?
        var lastError: String?
        var host: String?
    }

    struct Code: Decodable, Equatable {
        /// "ABCD-EFGH".
        var code: String
        var expires: Date
    }

    struct PairedDevice: Decodable, Equatable, Identifiable {
        var id: String
        var name: String
        var paired: Date
        var lastSeen: Date?
    }

    struct Pairing: Decodable, Equatable {
        var link: String
        var expires: Date
    }

    private(set) var state = State.off
    private(set) var status: Status?
    /// The iPhones and iPads paired with this Mac (not Lantern itself).
    var devices: [PairedDevice] { status?.devices.filter { $0.name != Self.ownDeviceName } ?? [] }

    /// The name the bridge lists this app under.
    private static let ownDeviceName = "Lantern on This Mac"
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var connecting = false

    private static var agent: SMAppService {
        SMAppService.agent(plistName: "\(Bundle.main.bundleIdentifier ?? "com.merimerimeri.Lantern").bridge.plist")
    }

    /// The bridge's folder: its certificate, paired devices and admin socket.
    nonisolated static var folder: URL { Folders.support.appending(path: "Bridge", directoryHint: .isDirectory) }

    // MARK: - Serving

    /// Registers the agent if it isn't, then follows the bridge and keeps this Mac's chats
    /// connected to it. Safe to call again.
    func start(_ link: MacLink) {
        guard poller == nil else { return }
        state = .starting
        prepareDevFolder()
        register()
        poller = Task {
            while !Task.isCancelled {
                await refresh()
                await connect(link)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Stops serving: the agent is unregistered (which stops the bridge), and this Mac's chats
    /// forget it. Paired devices stay paired, for when it serves again.
    func stop(_ link: MacLink) async {
        poller?.cancel()
        poller = nil
        try? await Self.agent.unregister()
        status = nil
        state = .off
        link.removeComputer()
    }

    /// A Mac that doesn't serve leaves nothing registered (it may have served before).
    func unregisterIfNeeded() {
        let agent = Self.agent
        guard agent.status == .enabled || agent.status == .requiresApproval else { return }
        Task { try? await agent.unregister() }
    }

    private func register() {
        let agent = Self.agent
        guard agent.status != .enabled else { return }
        do {
            try agent.register()
        } catch {
            state = agent.status == .requiresApproval ? .needsApproval
                : .failed("Lantern couldn't start serving: \(error.localizedDescription)")
        }
    }

    /// Opens Login Items, where the agent is allowed again.
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    private func refresh() async {
        do {
            let fresh = try await AdminSocket.decode(Status.self, "GET", "/status")
            if fresh != status { status = fresh }
            if state != .running { state = .running }
        } catch {
            status = nil
            let agent = Self.agent.status
            if agent == .requiresApproval {
                state = .needsApproval
            } else if agent == .enabled {
                if state == .running { state = .starting }  // launchd starts it again
            } else {
                register()
            }
        }
    }

    /// A Debug build's bridge keeps to its own port and name, beside the installed Lantern's. (Its
    /// agent also uses the Splash already running on :8000 rather than starting one: mac-bundle.sh.)
    private func prepareDevFolder() {
        guard Folders.isDevBuild else { return }
        let settings = Self.folder.appending(path: "settings.json")
        guard !FileManager.default.fileExists(atPath: settings.path) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? Data(#"{"name": "Lantern Dev", "port": 11444, "splashPort": 11481}"#.utf8).write(to: settings)
    }

    // MARK: - This Mac's own chats

    /// Pairs Lantern with its own bridge if it isn't (first run, a new certificate, or the
    /// pairing removed), and points `MacLink` at it.
    private func connect(_ link: MacLink) async {
        guard let status, !connecting else { return }
        connecting = true
        defer { connecting = false }
        let host = "127.0.0.1:\(status.port)"
        let samePin = MacPairing.current?.pin.hex == status.fingerprint.lowercased()
        let listed = status.devices.contains { $0.name == Self.ownDeviceName }
        if !(samePin && listed) {
            guard let pairing = try? await newPairing(),
                  var parts = URLComponents(string: pairing.link) else { return }
            // Only the loopback address: the bridge is on this Mac.
            parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "addr" } + [URLQueryItem(name: "addr", value: host)]
            guard let url = parts.url, let offer = PairOffer(url: url),
                  (try? await MacPairing.pair(offer, device: Self.ownDeviceName)) != nil else { return }
            // Earlier pairings of this app are of no use any more.
            for old in status.devices where old.name == Self.ownDeviceName { await remove(old) }
        } else if MacLink.lanHost == host, MacLink.tailnetHost.isEmpty, link.route.host != nil {
            return  // connected already
        }
        if MacLink.lanHost != host || !MacLink.tailnetHost.isEmpty {
            link.configure(name: "This Mac", lan: host, tailnet: "")
        }
        await link.resolve()
    }

    // MARK: - Devices

    /// A one-time code for a device to pair with, as a `lantern://pair` link.
    func newPairing() async throws -> Pairing {
        try await AdminSocket.decode(Pairing.self, "POST", "/pairing")
    }

    /// A code to type on the device instead (`ABCD-EFGH`), replacing any shown before.
    func newCode() async throws -> Code {
        try await AdminSocket.decode(Code.self, "POST", "/pairing/code")
    }

    func remove(_ device: PairedDevice) async {
        _ = try? await AdminSocket.request("DELETE", "/devices/\(device.id)")
        await refresh()
    }

    // MARK: - Splash and Tailscale

    /// Tries starting Splash again now, rather than after the bridge's backoff.
    func restartSplash() async {
        _ = try? await AdminSocket.request("POST", "/splash/restart")
        await refresh()
    }

    /// Keeps a Tailscale OAuth client, once the bridge has checked it with Tailscale. Throws
    /// Tailscale's reason when it doesn't work.
    func setTailscale(clientID: String, secret: String) async throws {
        let body = try JSONEncoder().encode(["client_id": clientID, "client_secret": secret])
        let (code, data) = try await AdminSocket.request("PUT", "/tailscale", body: body)
        guard code < 300 else {
            throw AdminSocket.Failure(status: code, message: (try? JSONDecoder().decode(BridgeAPI.ErrorBody.self, from: data))?.message)
        }
        await refresh()
    }

    func forgetTailscale() async {
        _ = try? await AdminSocket.request("DELETE", "/tailscale")
        await refresh()
    }
}

/// HTTP/1.0 over the bridge's admin socket (`admin.sock` in its folder): one request per
/// connection, the answer read to the end.
nonisolated enum AdminSocket {
    struct Failure: LocalizedError {
        let status: Int
        var message: String?
        var errorDescription: String? { message ?? "The bridge answered with HTTP \(status)." }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ method: String, _ path: String) async throws -> T {
        let (code, data) = try await request(method, path)
        guard code < 300 else { throw Failure(status: code) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text) ?? .distantPast  // Go's zero time: never
        }
        return try decoder.decode(T.self, from: data)
    }

    static func request(_ method: String, _ path: String, body: Data = Data()) async throws -> (Int, Data) {
        let socketPath = MacServer.folder.appending(path: "admin.sock").path
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
            var message = Data("\(method) \(path) HTTP/1.0\r\nHost: bridge\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            message.append(body)
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
#endif
