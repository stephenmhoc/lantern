import Foundation
import Observation
import UIKit
#if canImport(TailscaleKit)
import TailscaleKit
#endif

/// Lantern's own node on your tailnet (Tailscale's embedded TailscaleKit), so the Mac is reachable
/// away from home without the Tailscale app. Sign in once in a browser sheet; the node's keys stay in
/// Application Support and it reconnects at launch. Joining needs Tailscale's servers, so with the
/// internet down this simply stays offline and the home network is used instead.
///
/// Compiled out until `scripts/fetch-tailscale.sh` has put TailscaleKit.xcframework in Vendor/.
@Observable
final class Tailnet {
    enum State: Equatable {
        case unavailable          // built without TailscaleKit
        case signedOut
        case starting
        case needsLogin(URL)      // open this in a browser to approve the node
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .unavailable: "Not included in this build"
            case .signedOut: "Signed out"
            case .starting: "Connecting…"
            case .needsLogin: "Waiting for sign-in"
            case .connected: "Connected"
            case .failed(let e): e
            }
        }
    }

    private(set) var state: State {
        didSet {
            #if DEBUG
            print("TAILNET \(state)")
            #endif
        }
    }
    /// Other devices on the tailnet, by MagicDNS name, for picking the Mac.
    private(set) var peers: [String] = []
    /// The peers the tailnet says are online now: the ones worth probing for Ollama.
    private(set) var onlinePeers: Set<String> = []
    /// Who the node is signed in as (the tailnet's login name), once connected.
    private(set) var account: String?
    /// The tailnet's MagicDNS suffix ("tail7b6e2.ts.net"), for completing a typed short name.
    private(set) var magicDNSSuffix: String?
    /// Requests through the node, once it's connected.
    private(set) var session: URLSession?

    private static let signedInKey = "tailnet.signedIn"
    private var stateDirectory: URL { URL.applicationSupportDirectory.appending(path: "tailscale") }

    #if canImport(TailscaleKit)
    @ObservationIgnored private var node: TailscaleNode?
    @ObservationIgnored private var bus: MessageProcessor?
    @ObservationIgnored private var client: LocalAPIClient?
    #endif

    init() {
        #if canImport(TailscaleKit)
        state = .signedOut
        if UserDefaults.standard.bool(forKey: Self.signedInKey) { Task { await start() } }
        #else
        state = .unavailable
        #endif
    }

    /// Waits while the node is still connecting (it starts at launch), up to `limit`, so a check of
    /// the Mac right after launch goes through it instead of failing without it.
    func waitWhileStarting(upTo limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while state == .starting, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func signIn() async {
        UserDefaults.standard.set(true, forKey: Self.signedInKey)
        await start()
    }

    /// Forgets this device's tailnet identity. Its entry in the Tailscale admin console stays until
    /// removed there or it expires.
    func signOut() async {
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
        await stop()
        try? FileManager.default.removeItem(at: stateDirectory)
        state = .signedOut
    }

    #if canImport(TailscaleKit)
    private func start() async {
        guard node == nil else { return }
        state = .starting
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let config = Configuration(
                hostName: "lantern-\(UIDevice.current.model.lowercased())",
                path: stateDirectory.path(), authKey: nil, controlURL: kDefaultControlURL, ephemeral: false)
            let node = try TailscaleNode(config: config, logger: nil)
            self.node = node
            let client = LocalAPIClient(localNode: node, logger: nil)
            self.client = client
            // The bus says when a login URL is ready and when the node is running.
            bus = try await client.watchIPNBus(mask: [.initialState], consumer: BusWatcher(tailnet: self))
            try await node.up()  // returns once signed in
            let (config2, _) = try await URLSessionConfiguration.tailscaleSession(node)
            session = URLSession(configuration: config2)
            state = .connected
            await refreshPeers()
        } catch {
            await stop()
            state = .failed("Couldn't connect: \(error.localizedDescription)")
        }
    }

    private func stop() async {
        bus?.cancel()
        bus = nil
        try? await node?.close()
        node = nil
        client = nil
        session = nil
        peers = []
        onlinePeers = []
        account = nil
    }

    fileprivate func handle(_ notify: Ipn.Notify) {
        if let raw = notify.BrowseToURL, let url = URL(string: raw) { state = .needsLogin(url) }
        if notify.State == .NeedsLogin, case .starting = state {
            Task { try? await client?.startLoginInteractive() }  // ask for a login URL
        }
    }

    func refreshPeers() async {
        guard let status = try? await client?.backendStatus() else { return }
        let all = (status.Peer ?? [:]).values
        func name(_ peer: IpnState.PeerStatus) -> String { peer.DNSName.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        peers = all.map(name).filter { !$0.isEmpty }.sorted()
        onlinePeers = Set(all.filter(\.Online).map(name).filter { !$0.isEmpty })
        account = status.User?.values.first(where: { !$0.isTaggedDevice })?.LoginName ?? status.CurrentTailnet?.Name
        let suffix = status.CurrentTailnet?.MagicDNSSuffix ?? ""
        magicDNSSuffix = suffix.isEmpty ? nil : suffix
    }
    #else
    private func start() async {}
    private func stop() async {}
    func refreshPeers() async {}
    #endif
}

#if canImport(TailscaleKit)
/// Receives the node's IPN bus on TailscaleKit's actor and hands it to the main actor.
private actor BusWatcher: MessageConsumer {
    weak var tailnet: Tailnet?
    init(tailnet: Tailnet) { self.tailnet = tailnet }

    func notify(_ notify: Ipn.Notify) {
        Task { @MainActor [tailnet] in tailnet?.handle(notify) }
    }

    func error(_ error: Error) {}
}
#endif
