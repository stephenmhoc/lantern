import Foundation
import Network
import Observation
import os

/// A computer found running Ollama, by one route or both.
struct FoundComputer: Identifiable, Hashable {
    /// `MacLink.slug` of its name: the key that joins its Bonjour name, `.local` host and tailnet name.
    var id: String
    var name: String
    var lanHost: String?
    var tailnetHost: String?
    var version: String?
    var modelCount: Int?

    var routes: String {
        switch (lanHost != nil, tailnetHost != nil) {
        case (true, true): "Home network and tailnet"
        case (true, false): "Home network"
        default: "Tailnet"
        }
    }

    var summary: String {
        var parts = [routes]
        if let modelCount { parts.append(modelCount == 1 ? "1 model" : "\(modelCount) models") }
        if let version { parts.append("Ollama \(version)") }
        return parts.joined(separator: " · ")
    }
}

/// Finds computers running Ollama while the Add a Computer list is on screen, three ways at once:
/// Bonjour (`_ollama._tcp`, which `scripts/mac-ollama-setup.sh` advertises), the tailnet's peers
/// through Lantern's own node, and the addresses already saved (or the defaults), which also tries
/// the Tailscale app's VPN. Nothing runs until `start()`; `stop()` cancels everything.
@Observable
final class ComputerFinder {
    private(set) var found: [FoundComputer] = []
    /// Bonjour is browsing (it never finishes by itself; it just stops finding more).
    private(set) var browsing = false
    /// Why Bonjour can't browse, such as local network access being off.
    private(set) var browseProblem: String?
    private(set) var probingTailnet = false

    let mac: MacLink
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Hosts already asked this time, so a repeated Bonjour result isn't probed again.
    @ObservationIgnored private var asked: Set<String> = []

    init(mac: MacLink) { self.mac = mac }

    var onNetwork: [FoundComputer] { found.filter { $0.lanHost != nil } }
    var onTailnetOnly: [FoundComputer] { found.filter { $0.lanHost == nil } }

    func start() {
        guard browser == nil else { return }
        browse()
        probeSaved()
        probeTailnet()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        browsing = false
        tasks.forEach { $0.cancel() }
        tasks = []
        asked = []
        probingTailnet = false
    }

    // MARK: Bonjour

    private func browse() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_ollama._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            let problem: String? = switch state {
            case .failed(let error), .waiting(let error):
                if case .dns(let code) = error, code == -65570 {  // kDNSServiceErr_PolicyDenied
                    "Local network access is off for Lantern. Turn it on in Settings › Privacy & Security › Local Network."
                } else {
                    "Can't look on this network: \(error.localizedDescription)"
                }
            default: nil
            }
            let ready = if case .ready = state { true } else { false }
            Task { @MainActor in
                self?.browseProblem = problem
                self?.browsing = ready
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services: [(name: String, endpoint: NWEndpoint, host: String?, tailnet: String?)] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var host: String?, tailnet: String?
                if case .bonjour(let txt) = result.metadata {
                    host = txt["host"].flatMap { $0.isEmpty ? nil : $0 }
                    tailnet = txt["tailnet"].flatMap { $0.isEmpty ? nil : $0 }
                }
                return (name, result.endpoint, host, tailnet)
            }
            Task { @MainActor in
                for s in services { self?.foundService(name: s.name, endpoint: s.endpoint, host: s.host, tailnet: s.tailnet) }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    /// A Bonjour service: its TXT record names the host (the setup script puts the Mac's
    /// `.local` name there, which survives a new IP address); without one, its current address.
    private func foundService(name: String, endpoint: NWEndpoint, host: String?, tailnet: String?) {
        let key = "bonjour:\(name)"
        guard !asked.contains(key) else { return }
        asked.insert(key)
        run {
            var lan = host
            if lan == nil { lan = await Self.address(of: endpoint) }
            guard let lan, let normalized = MacLink.normalized(lan) else { return }
            guard let answer = await Self.probe(normalized) else { return }
            self.add(name: MacLink.prettyName(name), slugSource: host ?? name, lan: lan, tailnet: tailnet, answer: answer)
        }
    }

    /// A service's IPv4 address and port, by connecting to it briefly.
    nonisolated private static func address(of endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: String?) {
                guard done.withLock({ let first = !$0; $0 = true; return first }) else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        switch host {
                        case .ipv4(let a): finish("\(a):\(port.rawValue)")
                        case .name(let n, _): finish("\(n):\(port.rawValue)")
                        default: finish(nil)
                        }
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    // MARK: Saved addresses and the tailnet

    /// The saved (or default) addresses: the home network directly, the tailnet through the
    /// Tailscale app's VPN and, when signed in, Lantern's own node.
    private func probeSaved() {
        let lan = MacLink.lanHost.isEmpty ? MacLink.defaultLAN : MacLink.lanHost
        let tail = MacLink.tailnetHost.isEmpty ? MacLink.defaultTailnet : MacLink.tailnetHost
        let name = UserDefaults.standard.string(forKey: MacLink.computerNameKey)
        if let host = MacLink.normalized(lan), !asked.contains(host) {
            asked.insert(host)
            run {
                guard let answer = await Self.probe(host) else { return }
                self.add(name: name ?? MacLink.derivedName(fromHost: lan), slugSource: lan, lan: lan, tailnet: nil, answer: answer)
            }
        }
        if let host = MacLink.normalized(tail), !asked.contains(host) {
            asked.insert(host)
            run {
                var answer = await Self.probe(host, timeout: 4)
                if answer == nil, let node = self.mac.tailnet.session { answer = await Self.probe(host, session: node, timeout: 4) }
                guard let answer else { return }
                self.add(name: name ?? MacLink.derivedName(fromHost: tail), slugSource: tail, lan: nil, tailnet: tail, answer: answer)
            }
        }
    }

    /// Every online peer, asked through Lantern's node on port 11434, all at once.
    func probeTailnet() {
        let tailnet = mac.tailnet
        guard tailnet.state == .connected, let node = tailnet.session else { return }
        probingTailnet = true
        run {
            await tailnet.refreshPeers()
            let peers = tailnet.onlinePeers.isEmpty ? tailnet.peers : tailnet.peers.filter(tailnet.onlinePeers.contains)
            await withTaskGroup(of: Void.self) { group in
                for peer in peers {
                    guard let host = MacLink.normalized(peer), !self.asked.contains("node:\(host)") else { continue }
                    self.asked.insert("node:\(host)")
                    group.addTask {
                        guard let answer = await Self.probe(host, session: node, timeout: 3) else { return }
                        await MainActor.run {
                            self.add(name: MacLink.derivedName(fromHost: peer), slugSource: peer, lan: nil, tailnet: peer, answer: answer)
                        }
                    }
                }
            }
            self.probingTailnet = false
        }
    }

    // MARK: Results

    struct Answer: Sendable { var version: String?; var modelCount: Int? }

    /// Ollama's version and model count at a host, or nil if nothing answers.
    static func probe(_ host: String, session: URLSession = .shared, timeout: TimeInterval = 2.5) async -> Answer? {
        async let version = MacLink.version(host, session: session, timeout: timeout)
        async let listing = MacLink.listing(host, session: session, timeout: timeout)
        let (v, l) = await (version, listing)
        guard v != nil || l != nil else { return nil }
        return Answer(version: v, modelCount: l?.count)
    }

    /// Adds a computer, or fills in the other route of one already found under the same name.
    private func add(name: String?, slugSource: String, lan: String?, tailnet: String?, answer: Answer) {
        let id = MacLink.slug(slugSource)
        if let i = found.firstIndex(where: { $0.id == id }) {
            var c = found[i]
            c.lanHost = c.lanHost ?? lan
            c.tailnetHost = c.tailnetHost ?? tailnet
            if lan != nil, let name { c.name = name }  // the Bonjour name is the computer's own
            c.version = c.version ?? answer.version
            c.modelCount = c.modelCount ?? answer.modelCount
            found[i] = c
        } else {
            found.append(FoundComputer(
                id: id, name: name ?? MacLink.derivedName(fromHost: slugSource) ?? slugSource,
                lanHost: lan, tailnetHost: tailnet, version: answer.version, modelCount: answer.modelCount))
        }
        found.sort { ($0.lanHost == nil ? 1 : 0, $0.name) < ($1.lanHost == nil ? 1 : 0, $1.name) }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await work() })
    }
}
