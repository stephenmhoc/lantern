import Foundation
import LlamaKit
import Network
import Observation
import os

/// Ollama on the Mac. The home network comes first (it works without the internet); the tailnet is
/// the way in from elsewhere, through Lantern's own tailnet node or the Tailscale app's VPN,
/// whichever answers first. Every model Ollama has is offered in the chat's model picker.
@Observable
final class MacLink {
    enum Route: Hashable {
        case unknown, checking, unreachable
        case lan(String)
        /// `viaApp`: through the Tailscale app's VPN rather than Lantern's own node.
        case tailnet(String, viaApp: Bool)

        var label: String {
            switch self {
            case .unknown: "Not checked"
            case .checking: "Checking…"
            case .lan: "Home network"
            case .tailnet(_, let app): app ? "Tailnet (Tailscale app)" : "Tailnet"
            case .unreachable: "Not reachable"
            }
        }

        var host: String? {
            switch self {
            case .lan(let h), .tailnet(let h, _): h
            default: nil
            }
        }

        var isTailnet: Bool { if case .tailnet = self { true } else { false } }
    }

    /// Where the time before a Mac reply's first token went, for the reply's footnote.
    struct Timings {
        /// Finding the Mac (only when the route had to be checked first).
        var findSeconds: Double = 0
        /// Opening the connection (DNS, TCP, the tailnet's handshake), from URLSession's metrics.
        var connectSeconds: Double?
        /// Ollama loading the model, and reading the prompt.
        var loadSeconds: Double = 0
        var readSeconds: Double = 0
        /// Ollama's own `total_duration`: everything it did on the Mac for the request (load, read,
        /// generate), without the network. Nil until the final chunk.
        var serverSeconds: Double?
    }

    /// One request to Ollama, handed back with its stream so a reply reads its own route and
    /// timings, never another request's. `timings` is complete once the stream has yielded `.done`.
    final class Request {
        /// The route it went out on.
        let route: Route
        fileprivate(set) var timings: Timings

        fileprivate init(route: Route, timings: Timings) {
            self.route = route
            self.timings = timings
        }
    }

    /// "inkling-2-mini:latest" → "Inkling 2 Mini", "gemma4:31b-mlx" → "Gemma 4 31B".
    nonisolated static func displayName(_ model: String) -> String {
        guard !model.isEmpty else { return "Mac" }
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        var name = parts[0].split(separator: "/").last.map(String.init) ?? parts[0]
        // "gemma4" → "gemma 4": a number stuck to the family name.
        name = name.replacing(/([a-z])([0-9])/) { "\($0.output.1) \($0.output.2)" }
        var words = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map { word in
            word.count <= 3 && word.contains(where: \.isNumber) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }
        // A size tag ("31b", not "latest", "mlx" or a quant) says which of a family it is.
        if parts.count > 1 {
            let size = parts[1].split(separator: "-").first.map(String.init) ?? ""
            if size.range(of: #"^[0-9.]+[bm]$"#, options: .regularExpression) != nil,
               !["inkling", "muse"].contains(where: { name.lowercased().hasPrefix($0) }) {
                words.append(size.uppercased())
            }
        }
        return words.joined(separator: " ")
    }

    // Settings, edited with @AppStorage in ComputersView (Settings › On Your Computers).
    /// `modelKey`: the model a new Mac chat uses, the one last picked.
    nonisolated static let lanKey = "mac.lan", tailnetKey = "mac.tailnet", modelKey = "mac.model"
    /// The models Ollama listed last time, so the picker has them before the Mac is checked.
    private static let knownModelsKey = "mac.knownModels"
    /// The context Ollama is asked for (`options.num_ctx`); its own default is much smaller and
    /// silently drops the start of a long chat.
    static let contextKey = "mac.numCtx"
    // The Mac Studio by its Bonjour and MagicDNS names, so a fresh install finds it with no setup.
    static let defaultLAN = "Stephens-Mac-Studio.local", defaultTailnet = "stephens-mac-studio.tail7b6e2.ts.net"
    static let defaultContext = 16384

    let tailnet = Tailnet()
    private(set) var route: Route = .unknown
    /// Ollama's models, from the last check (or the one before, until the Mac answers).
    private(set) var models: [String] = UserDefaults.standard.stringArray(forKey: "mac.knownModels") ?? []
    /// Each model's size on the Mac's disk, from the last check that answered.
    private(set) var modelSizes: [String: Int64] = [:]

    private var defaults: UserDefaults { .standard }
    var modelName: String { defaults.string(forKey: Self.modelKey) ?? "" }
    var contextLength: Int {
        let n = defaults.integer(forKey: Self.contextKey)
        return n > 0 ? n : Self.defaultContext
    }
    /// Models Ollama refused `think` for; they're asked without it from then on.
    @ObservationIgnored private var cannotThink: Set<String> = []
    /// Whether each model has Ollama's "vision" capability, once asked (`/api/show`).
    @ObservationIgnored private var vision: [String: Bool] = [:]
    /// Set when the device's network changes (left home, Wi-Fi to cellular): the route found
    /// before may lead nowhere, and sending on it would wait for a connection that never comes.
    @ObservationIgnored private var routeIsStale = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPath: (status: NWPath.Status, interfaces: [NWInterface.InterfaceType])?
    @ObservationIgnored private var resolving: Task<Route, Never>?
    @ObservationIgnored private var lastWarm: [String: Date] = [:]
    @ObservationIgnored private var warming: Set<String> = []
    /// What `/api/show` says each model can do ("vision", "thinking"…), once asked.
    @ObservationIgnored fileprivate var capabilityCache: [String: Set<String>] = [:]
    /// Bumped when the computer's addresses change, so a check begun before doesn't land after.
    @ObservationIgnored fileprivate var configuration = 0

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let summary = (path.status, path.availableInterfaces.map(\.type))
            Task { @MainActor in self?.networkChanged(summary) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Lantern.MacLink.path"))
        #if DEBUG && os(iOS)
        ComputersDebug.presentIfAsked(self)  // `-ui computers|addcomputer`
        #endif
    }

    private func networkChanged(_ path: (status: NWPath.Status, interfaces: [NWInterface.InterfaceType])) {
        defer { lastPath = path }
        guard let last = lastPath, last.status != path.status || last.interfaces != path.interfaces else { return }
        routeIsStale = true
        // If the Mac was in use, find it again on the new network now, not when the next
        // question is sent, and keep its model loaded.
        let inUse = lastWarm.keys
        lastWarm = [:]
        for model in inUse { warm(model) }
    }

    /// Models that think whatever `think` says.
    nonisolated static func alwaysThinks(_ model: String) -> Bool {
        model.lowercased().hasPrefix("inkling")
    }

    /// Back from the background: the route is checked again before it's used.
    func cameToFront() {
        routeIsStale = true
        lastWarm = [:]
    }

    /// Checks both routes at once and uses the home network if it answers (it works without the
    /// internet). The tailnet doesn't wait out the home network's timeout when away from home:
    /// once it has answered, the home network gets only a moment longer.
    @discardableResult
    func resolve() async -> Route {
        if let resolving { return await resolving.value }
        let task = Task { await performResolve() }
        resolving = task
        defer { resolving = nil }
        return await task.value
    }

    private func performResolve() async -> Route {
        if route.host == nil { route = .checking }
        routeIsStale = false
        let generation = configuration
        let lan = Self.normalized(defaults.string(forKey: Self.lanKey) ?? Self.defaultLAN)
        let tail = Self.normalized(defaults.string(forKey: Self.tailnetKey) ?? Self.defaultTailnet)
        let tailnet = tailnet
        var tailViaApp = false
        typealias Listing = [OllamaModel]
        enum Probe { case lan(Listing?), tail(Listing?, viaApp: Bool), graceOver }
        let (l, t): (Listing?, Listing?) = await withTaskGroup(of: Probe.self) { group in
            group.addTask { .lan(await Self.listing(lan)) }
            group.addTask {
                // Lantern's own tailnet node starts at launch: give it a moment rather than probing
                // without it. Only this probe waits, so the home network (which works with the
                // internet down, when the node never connects) answers at once.
                guard tail != nil else { return .tail(nil, viaApp: false) }
                await tailnet.waitWhileStarting(upTo: .seconds(8))
                // A cold node's first connection through a relay can take seconds. With both
                // Lantern's node and the Tailscale app's VPN up, the first to answer wins: the VPN
                // stays connected while Lantern is in the background, the node starts over.
                guard let node = await tailnet.session else {
                    return .tail(await Self.listing(tail, timeout: 6), viaApp: true)
                }
                return await withTaskGroup(of: (Listing?, Bool).self) { race in
                    race.addTask { (await Self.listing(tail, session: node, timeout: 6), false) }
                    race.addTask { (await Self.listing(tail, timeout: 6), true) }
                    var last: (Listing?, Bool) = (nil, false)
                    for await result in race {
                        last = result
                        if result.0 != nil { race.cancelAll(); break }
                    }
                    return .tail(last.0, viaApp: last.1)
                }
            }
            // Outer nil: not back yet. Inner nil: no answer.
            var l: Listing??, t: Listing??
            var viaApp = false
            var graceStarted = false
            while let probe = await group.next() {
                switch probe {
                case .lan(let r): l = .some(r)
                case .tail(let r, let app): t = .some(r); viaApp = app
                case .graceOver: if l == nil { l = .some(nil) }
                }
                if case .some(.some) = l { break }  // home answered: use it
                if l != nil, t != nil { break }
                // Away from home the local name never answers: don't sit out its timeout. At home
                // it gets a second: a `.local` name and TLS take ~0.4 s, longer than the tailnet's
                // MagicDNS name, and the home network is the route that works with the internet down.
                if case .some(.some) = t, l == nil, !graceStarted {
                    graceStarted = true
                    group.addTask {
                        try? await Task.sleep(for: .seconds(1))
                        return .graceOver
                    }
                }
            }
            group.cancelAll()
            tailViaApp = viaApp
            return (l ?? nil, t ?? nil)
        }
        // The addresses changed while this check was out: the check that follows has the say.
        guard generation == configuration else { return route }
        var listing: Listing = []
        if let lan, let l {
            route = .lan(lan)
            listing = l
        } else if let tail, let t {
            route = .tailnet(tail, viaApp: tailViaApp)
            listing = t
        } else {
            route = .unreachable
        }
        models = listing.map(\.name)
        if !listing.isEmpty {
            modelSizes = Dictionary(listing.map { ($0.name, $0.size ?? 0) }, uniquingKeysWith: { a, _ in a })
            capabilityCache = Dictionary(listing.map { ($0.name, $0.capabilities) }, uniquingKeysWith: { a, _ in a })
        }
        if !models.isEmpty { defaults.set(models, forKey: Self.knownModelsKey) }
        if !models.isEmpty, !models.contains(modelName) {
            let pick = models.first { $0.localizedCaseInsensitiveContains("inkling") } ?? models[0]
            defaults.set(pick, forKey: Self.modelKey)
        }
        return route
    }

    static func normalized(_ host: String) -> String? {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return nil }
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        // The bridge's port.
        if !h.contains(":") { h += ":\(MacPairing.bridgePort)" }
        return h
    }

    /// The model names Ollama has, or nil if the host doesn't answer.
    static func tags(_ host: String?, session: URLSession = MacPairing.session, timeout: TimeInterval = 2.5) async -> [String]? {
        await listing(host, session: session, timeout: timeout)?.map(\.name)
    }

    /// The computer's models, with their sizes and what each can do (the bridge's `/v1/models`), or
    /// nil if the host doesn't answer.
    static func listing(_ host: String?, session: URLSession = MacPairing.session, timeout: TimeInterval = 2.5) async -> [OllamaModel]? {
        guard let host, var request = MacPairing.request(host, "/v1/models", timeout: timeout) else { return nil }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let answer: (Data, URLResponse)
        do { answer = try await session.data(for: request) } catch {
            if MacPairing.isUntrusted(error) { refusal.withLock { $0 = .untrusted } }
            // Not paired: the bridge's own certificate can't be trusted yet, so nothing was sent.
            else if !MacPairing.isPaired, MacPairing.isCertificateError(error) { refusal.withLock { $0 = .notPaired } }
            return nil
        }
        let code = (answer.1 as? HTTPURLResponse)?.statusCode
        if code == 401 { refusal.withLock { $0 = .notPaired } }
        guard code == 200, let list = try? JSONDecoder().decode(BridgeAPI.ModelList.self, from: answer.0) else { return nil }
        refusal.withLock { $0 = nil }
        return list.data.map { OllamaModel(name: $0.id, size: $0.lantern?.size, capabilities: $0.capabilities) }
    }

    /// Why the computer last turned Lantern away (no pairing, or not the paired certificate), so a
    /// reply that can't reach it says that rather than "can't reach". Cleared when it answers.
    nonisolated static let refusal = OSAllocatedUnfairLock<MacError?>(initialState: nil)

    /// Stops when the reading task is cancelled. A route that has gone stale (left home, Wi-Fi
    /// dropped) gets one fresh check and retry before giving up. The `Request` returned with the
    /// stream has the route and, once `.done` arrives, the timings.
    ///
    /// With `search`, a model Ollama says can use tools is offered `web_search`. When it calls it,
    /// this device runs the search (`WebSearcher`), the call and its results go back as a tool turn and
    /// the model carries on: up to `searchRounds` times, after which it's asked without the tool so
    /// it answers. Each search is reported as `.searching` and `.searched`, for the reply to keep.
    func stream(
        _ messages: [ChatMessage], thinking: Thinking, model: String, search: Bool = false
    ) async throws -> (stream: AsyncThrowingStream<Generation, Error>, request: Request) {
        var timings = Timings()
        let started = ContinuousClock.now
        if route.host == nil || routeIsStale { await resolve() }
        timings.findSeconds = (ContinuousClock.now - started).seconds
        var messages = messages
        // Images go in each message's `images`, for a model that can see. One that can't is sent
        // the text alone, unless the question itself is about an image.
        if messages.contains(where: \.hasImages), await !canSee(model) {
            if messages.last?.hasImages == true { throw MacError.noVision(model) }
            messages = messages.map(\.withoutImages)
        }
        let tools = search && model.isEmpty == false ? await canUseTools(model) : false
        let turns = BridgeAPI.messages(messages)
        let metrics = ConnectMetrics()
        let (first, _) = try await open(turns, tools: tools, thinking: thinking, model: model, metrics: metrics, retry: true)
        lastWarm[model] = .now  // a real request keeps it loaded as well as a warm-up does
        let request = Request(route: route, timings: timings)  // after `open`, which may have re-resolved
        let stream = AsyncThrowingStream<Generation, Error> { continuation in
            let task = Task {
                do {
                    var bytes = first
                    var turns = turns
                    var rounds = 0
                    var total = GenerationStats()
                    var sent = ContinuousClock.now
                    while true {
                        var pending: [Int: BridgeAPI.PendingCall] = [:]  // tool calls, by index
                        var said = ""
                        var finished = false
                        var firstToken: ContinuousClock.Instant?
                        lines: for try await line in bytes.lines {
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { finished = true; break lines }
                            guard let chunk = try? JSONDecoder().decode(BridgeAPI.Chunk.self, from: Data(payload.utf8)) else { continue }
                            if let error = chunk.error { throw MacError.ollama(error.message ?? "the model server failed") }
                            if let usage = chunk.usage {
                                // The prompt of the last round is the whole chat as the model last saw it.
                                total.promptTokens = usage.prompt_tokens ?? total.promptTokens
                                total.generatedTokens += usage.completion_tokens ?? 0
                            }
                            guard let choice = chunk.choices?.first else { continue }
                            if let delta = choice.delta {
                                if let t = delta.reasoning ?? delta.reasoning_content, !t.isEmpty {
                                    if firstToken == nil { firstToken = .now }
                                    continuation.yield(.thinking(t))
                                }
                                if let t = delta.content, !t.isEmpty {
                                    if firstToken == nil { firstToken = .now }
                                    said += t
                                    continuation.yield(.text(t))
                                }
                                for call in delta.tool_calls ?? [] {
                                    let i = call.index ?? pending.count
                                    var p = pending[i] ?? BridgeAPI.PendingCall()
                                    if let id = call.id, !id.isEmpty { p.id = id }
                                    if let name = call.function?.name, !name.isEmpty { p.name = name }
                                    p.arguments += call.function?.arguments ?? ""
                                    pending[i] = p
                                }
                            }
                            if choice.finish_reason != nil { finished = true }  // the usage chunk may follow
                        }
                        // Ended without finishing: the connection closed (Stop, or the computer went away).
                        guard finished else { break }
                        let end = ContinuousClock.now
                        if rounds == 0 {
                            // URLSession reports the connection's metrics as the task ends.
                            timings.connectSeconds = await metrics.connectSeconds(waitingUpTo: .milliseconds(300))
                        }
                        // The wait for the first token (loading and reading) and the writing, over the rounds.
                        total.promptSeconds += ((firstToken ?? end) - sent).seconds
                        total.generateSeconds += firstToken.map { (end - $0).seconds } ?? 0
                        let calls = pending.sorted { $0.key < $1.key }.map(\.value)
                        let asked = calls.compactMap(\.search)
                        guard tools, !asked.isEmpty else {
                            request.timings = timings
                            continuation.yield(.done(total))
                            break
                        }
                        rounds += 1
                        var searches: [WebSearch] = []
                        for search in asked {
                            try Task.checkCancellation()
                            continuation.yield(.searching(search.query))
                            let result = await WebSearcher.search(search.query, topic: search.topic)
                            searches.append(result)
                            continuation.yield(.searched(result))
                        }
                        let ids = calls.filter { $0.search != nil }.enumerated().map { i, call in
                            call.id.isEmpty ? "call_r\(rounds)_\(i)" : call.id
                        }
                        turns += BridgeAPI.searchMessages(searches, ids: ids, said: said)
                        try Task.checkCancellation()
                        sent = .now
                        (bytes, _) = try await self.open(
                            turns, tools: rounds < Self.searchRounds, thinking: thinking, model: model,
                            metrics: ConnectMetrics(), retry: true)
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()  // Stop, not a failure
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if error is URLError { route = .unknown }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, request)
    }

    /// Searches a reply may run before it has to answer.
    nonisolated static let searchRounds = 3

    /// Gets the Mac ready for a question that's coming (a chat opened, typing started): finds the
    /// route if it isn't known or the network changed, then asks the bridge to load the model. It also opens the connection (and the
    /// tailnet's path to the Mac) before it's needed. Cheap to call often: it does nothing if this
    /// model was warmed in the last minute on the same network.
    func warm(_ model: String) {
        guard !model.isEmpty, !warming.contains(model) else { return }
        if let last = lastWarm[model], Date().timeIntervalSince(last) < 60, !routeIsStale, route.host != nil { return }
        warming.insert(model)
        Task {
            defer { warming.remove(model) }
            if route.host == nil || routeIsStale { await resolve() }
            // The bridge loads it (an empty chat, for Ollama) and answers at once.
            guard let host = route.host, var request = MacPairing.request(host, "/lantern/v1/warm", timeout: 10) else { return }
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["model": model])
            lastWarm[model] = .now
            if (try? await session.data(for: request)) == nil { lastWarm[model] = nil }
        }
    }

    /// Where requests go on the current route: through Lantern's tailnet node when that's the route.
    fileprivate var session: URLSession {
        if case .tailnet(_, viaApp: false) = route { return tailnet.session ?? MacPairing.session }
        return MacPairing.session
    }

    /// Whether a model can see images, as the bridge listed it. A model it didn't list counts as without.
    func canSee(_ model: String) async -> Bool {
        await capabilities(of: model)?.contains("vision") == true
    }

    private func open(
        _ turns: [BridgeAPI.Message], tools: Bool, thinking: Thinking, model: String, metrics: ConnectMetrics, retry: Bool
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let host = route.host, var request = MacPairing.request(host, "/v1/chat/completions", timeout: 120) else {  // between bytes, not overall
            throw Self.refusal.withLock { $0 } ?? MacError.unreachable
        }
        guard !model.isEmpty else { throw MacError.noModel }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Thinking is asked for only from a model that thinks ("none" turns it off). A model that
        // always thinks is asked for its thinking even when it's off: told not to, it thinks anyway
        // and Ollama hides it, so nothing shows for seconds (Inkling: first token after 4 s instead
        // of 0.4 s on the Mac Studio, the answer at the same moment).
        let thinks = capabilityCache[model]?.contains("thinking") == true || Self.alwaysThinks(model)
        let effort: String? = !thinks || cannotThink.contains(model) ? nil
            : thinking != .off || Self.alwaysThinks(model) ? "medium" : "none"
        request.httpBody = try JSONEncoder().encode(BridgeAPI.Request(
            model: model, messages: turns, reasoning_effort: effort,
            tools: tools ? [BridgeAPI.Tool.webSearch] : nil))
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
            guard let code = (response as? HTTPURLResponse)?.statusCode, code == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // The bridge and the model server explain themselves in a small JSON body.
                var body = Data()
                for try await byte in bytes.prefix(4096) { body.append(byte) }
                let message = (try? JSONDecoder().decode(BridgeAPI.ErrorBody.self, from: body))?.message
                if code == 400, effort != nil, message?.localizedCaseInsensitiveContains("reason") == true
                    || message?.localizedCaseInsensitiveContains("think") == true {
                    cannotThink.insert(model)  // not a thinking model: ask again without it, once
                    return try await open(turns, tools: tools, thinking: thinking, model: model, metrics: metrics, retry: retry)
                }
                throw MacError.http(code, model: model, message: message)
            }
            return (bytes, response)
        } catch let error as URLError where MacPairing.isUntrusted(error) {
            throw MacError.untrusted  // never retried: it isn't the paired computer
        } catch let error as URLError where error.code != .cancelled && retry {
            await resolve()
            return try await open(turns, tools: tools, thinking: thinking, model: model, metrics: metrics, retry: false)
        }
    }

    /// Whether Ollama says the model can call tools (`/api/show`'s "tools").
    func canUseTools(_ model: String) async -> Bool {
        await capabilities(of: model)?.contains("tools") == true
    }

    /// One of the computer's models, from the bridge's `/v1/models`: its name, size on disk and
    /// what it can do ("vision", "tools", "thinking").
    nonisolated struct OllamaModel: Hashable, Sendable {
        let name: String
        let size: Int64?
        var capabilities: Set<String> = []
    }

}

// MARK: - The computer

/// The computer Ollama runs on, as Settings' "On Your Computers" shows it. One computer for now:
/// its two addresses (`lanKey`, `tailnetKey`), the model new chats use (`modelKey`) and its name
/// (`computerNameKey`).
extension MacLink {
    /// The name the computer was added with ("Mac Studio"); without one it comes from the host.
    nonisolated static let computerNameKey = "mac.name"

    static var lanHost: String { UserDefaults.standard.string(forKey: lanKey) ?? defaultLAN }
    static var tailnetHost: String { UserDefaults.standard.string(forKey: tailnetKey) ?? defaultTailnet }
    /// Whether there is a computer at all: "Remove Computer" leaves both addresses empty.
    static var isConfigured: Bool { MacPairing.isPaired && (normalized(lanHost) != nil || normalized(tailnetHost) != nil) }

    /// "Mac Studio": the stored name, else one from the home-network or tailnet host.
    static var computerName: String {
        computerName(stored: UserDefaults.standard.string(forKey: computerNameKey), lan: lanHost, tailnet: tailnetHost)
    }
    var computerName: String { Self.computerName }

    nonisolated static func computerName(stored: String?, lan: String, tailnet: String) -> String {
        if let stored = stored?.trimmingCharacters(in: .whitespaces), !stored.isEmpty { return stored }
        return derivedName(fromHost: lan) ?? derivedName(fromHost: tailnet) ?? "Computer"
    }

    /// "Stephens-Mac-Studio.local" → "Mac Studio", "stephens-mac-studio.tail7b6e2.ts.net:11434" →
    /// "Mac Studio", "devbox" → "Devbox". Nil for an IP address or nothing.
    nonisolated static func derivedName(fromHost host: String) -> String? {
        let label = shortName(host)
        guard !label.isEmpty, !label.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { return nil }
        return prettyName(label)
    }

    /// "Stephen’s Mac Studio" or "Stephens-Mac-Studio" → "Mac Studio": the owner's name in front
    /// goes, from the product on stays. Anything else is just capitalized.
    nonisolated static func prettyName(_ raw: String) -> String {
        var words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
        let products = ["mac", "macbook", "imac", "macmini", "macpro"]
        if let i = words.firstIndex(where: { products.contains($0.lowercased()) }), i > 0 {
            words.removeFirst(i)
        } else if let i = words.firstIndex(where: { $0.hasSuffix("’s") || $0.hasSuffix("'s") }), i < words.count - 1 {
            words.removeFirst(i + 1)
        }
        let spelled = ["mac": "Mac", "macbook": "MacBook", "imac": "iMac", "macmini": "Mac mini", "macpro": "Mac Pro", "mini": "mini"]
        return words.map { spelled[$0.lowercased()] ?? $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// A host's first label, without scheme or port: "stephens-mac-studio.tail7b6e2.ts.net:11434"
    /// → "stephens-mac-studio". An IP address stays whole.
    nonisolated static func shortName(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if h.hasPrefix("[") { return h }  // IPv6
        if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        if h.allSatisfy({ $0.isNumber || $0 == "." }) { return h }
        return h.split(separator: ".").first.map(String.init) ?? h
    }

    /// The same computer's names, compared: "Stephen’s Mac Studio" (its Bonjour name),
    /// "Stephens-Mac-Studio.local" and "stephens-mac-studio.tail….ts.net" all give "stephens-mac-studio".
    nonisolated static func slug(_ name: String) -> String {
        let base = name.contains(" ") ? name : shortName(name)
        return base.lowercased()
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).joined(separator: "-")
    }

    /// Whether a host is on the tailnet (a MagicDNS name or a 100.64/10 address).
    nonisolated static func isTailnetHost(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        if h.hasSuffix(".ts.net") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Saves the computer's addresses and name; the route is checked again before it's next used.
    func configure(name: String?, lan: String, tailnet: String) {
        defaults.set(lan.trimmingCharacters(in: .whitespaces), forKey: Self.lanKey)
        defaults.set(tailnet.trimmingCharacters(in: .whitespaces), forKey: Self.tailnetKey)
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            defaults.set(name.trimmingCharacters(in: .whitespaces), forKey: Self.computerNameKey)
        } else {
            defaults.removeObject(forKey: Self.computerNameKey)
        }
        configuration += 1
        resolving = nil
        route = .unknown
        routeIsStale = true
        lastWarm = [:]
        vision = [:]
        capabilityCache = [:]
        cannotThink = []
    }

    /// Forgets the computer: no addresses, no name, no models. Chats already on it keep their model.
    func removeComputer() {
        MacPairing.forget()
        configure(name: nil, lan: "", tailnet: "")
        models = []
        modelSizes = [:]
        defaults.removeObject(forKey: "mac.knownModels")
    }

    /// The bridge on the current route and what it serves: "Lantern Bridge 0.1.0 · Ollama".
    func ollamaVersion() async -> String? {
        guard let host = route.host else { return nil }
        return await Self.version(host, session: session)
    }

    /// The bridge's version and model servers at a host, or nil if nothing answers there.
    static func version(_ host: String?, session: URLSession = MacPairing.session, timeout: TimeInterval = 2.5) async -> String? {
        guard let host, var request = MacPairing.request(host, "/lantern/v1/info", timeout: timeout) else { return nil }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(BridgeAPI.Info.self, from: data) else { return nil }
        let servers = info.backends.map(\.name)
        return (["Lantern Bridge \(info.version)"] + (servers.isEmpty ? [] : [ListFormatter.localizedString(byJoining: servers)]))
            .joined(separator: " · ")
    }

    /// The models in memory now: the bridge doesn't say, so nil.
    func loadedModels() async -> Set<String>? { nil }

    /// What a model can do ("thinking", "vision", "tools"), as the bridge listed it; the list is
    /// asked for again for a model it didn't have.
    func capabilities(of model: String) async -> Set<String>? {
        if let known = capabilityCache[model] { return known }
        guard let host = route.host, let listing = await Self.listing(host, session: session) else { return nil }
        for m in listing { capabilityCache[m.name] = m.capabilities }
        return capabilityCache[model]
    }

    /// The result of "Test Connection".    /// The result of "Test Connection".
    struct ConnectionTest {
        var route: Route
        var timings = Timings()
        /// Wall time of the whole test.
        var totalSeconds: Double = 0
        var failure: String?
    }

    /// Finds the computer again (both routes, as a send would) and loads `model` (as `warm` does),
    /// timing each: found, connected, loaded.
    func testConnection(model: String) async -> ConnectionTest {
        let started = ContinuousClock.now
        routeIsStale = true
        let found = await resolve()
        var result = ConnectionTest(route: found)
        result.timings.findSeconds = (ContinuousClock.now - started).seconds
        guard let host = found.host, var request = MacPairing.request(host, "/v1/chat/completions", timeout: 120) else {
            result.failure = (Self.refusal.withLock { $0 } ?? MacError.unreachable).errorDescription
            result.totalSeconds = (ContinuousClock.now - started).seconds
            return result
        }
        guard !model.isEmpty else {
            result.failure = MacError.noModel.errorDescription
            result.totalSeconds = (ContinuousClock.now - started).seconds
            return result
        }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // One token of an answer: loads the model if it isn't, and reads almost nothing.
        var ask = BridgeAPI.Request(model: model, messages: [.init(role: "user", content: .text("Hi"))], max_tokens: 1)
        ask.stream = false
        ask.stream_options = [:]
        if capabilityCache[model]?.contains("thinking") == true, !Self.alwaysThinks(model) { ask.reasoning_effort = "none" }
        request.httpBody = try? JSONEncoder().encode(ask)
        // A fresh connection, so "connected" is measured rather than reused from finding it. Lantern's
        // own tailnet node has one session, used as it is.
        let fresh = session === MacPairing.session
        let testSession = fresh ? URLSession(configuration: .ephemeral, delegate: PinningDelegate.shared, delegateQueue: nil) : session
        defer { if fresh { testSession.finishTasksAndInvalidate() } }
        let metrics = ConnectMetrics()
        let sent = ContinuousClock.now
        do {
            let (data, response) = try await testSession.data(for: request, delegate: metrics)
            let elapsed = (ContinuousClock.now - sent).seconds
            let connect = await metrics.connectSeconds(waitingUpTo: .milliseconds(300))
            result.timings.connectSeconds = connect
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                let message = (try? JSONDecoder().decode(BridgeAPI.ErrorBody.self, from: data))?.message
                result.failure = MacError.http(code, model: model, message: message).errorDescription
            } else {
                // What isn't the connection is loading the model (if it wasn't) and one token.
                result.timings.loadSeconds = max(0, elapsed - (connect ?? 0))
                lastWarm[model] = .now
            }
        } catch {
            result.failure = MacPairing.isUntrusted(error) ? MacError.untrusted.errorDescription : error.localizedDescription
        }
        result.totalSeconds = (ContinuousClock.now - started).seconds
        return result
    }

}

nonisolated enum MacError: LocalizedError {
    case unreachable, noModel, http(Int, model: String, message: String?), ollama(String), noVision(String)
    /// The computer turned down the access key, or answered with a certificate other than the paired one.
    case notPaired, untrusted

    var errorDescription: String? {
        switch self {
        case .unreachable: "Can't reach the Mac over the home network or the tailnet. Check that Lantern is open on it."
        case .noModel: "The Mac has no models. Add one in Ollama or LM Studio."
        case .http(404, let model, _):
            "The Mac doesn't have the model \(model) any more. Pick another in Settings."
        case .http(400, _, let message): "The Mac couldn't use this request: \(message ?? "bad request")."
        case .notPaired, .http(401, _, _):
            "This device isn't paired with the Mac. In Lantern on the Mac, choose Pair a Device and scan the code with this device's camera."
        case .untrusted:
            "The computer didn't prove it's the Mac Lantern was paired with, so nothing was sent. If you set it up again, pair again."
        case .http(403, _, _): "The Mac refused the connection."
        case .http(429, _, _), .http(503, _, _): "The Mac is busy. Try again in a moment."
        case .http(502, _, let message): "The Mac's model server didn't answer\(message.map { ": \($0)" } ?? ""). Check that Ollama or LM Studio is running."
        case .http(let code, let model, let message) where code >= 500:
            "The Mac failed to run \(model)\(message.map { ": \($0)" } ?? " (HTTP \(code))"). It may be out of memory."
        case .http(let code, _, let message): "The Mac answered with HTTP \(code)\(message.map { ": \($0)" } ?? "")."
        case .ollama(let message): "The computer's model server: \(message)"
        case .noVision(let model): "\(model) on the Mac can't see images. Pick a vision model in Settings, or use Gemma on this device."
        }
    }

    var kind: ReplyErrorKind {
        switch self {
        case .unreachable: .macUnreachable
        case .noModel, .http(404, _, _): .macNoModel
        case .http, .ollama, .noVision, .notPaired, .untrusted: .macFailed
        }
    }
}

/// Catches a request's URLSession metrics, for how long opening the connection took.
nonisolated final class ConnectMetrics: NSObject, URLSessionTaskDelegate, Sendable {
    /// Whether URLSession has reported yet, and the connect time (nil for a reused connection).
    private let state = OSAllocatedUnfairLock<(reported: Bool, seconds: Double?)>(initialState: (false, nil))

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // From asking to having a connection: DNS, TCP and (on the tailnet) the path to the Mac.
        var value: Double?
        if let t = metrics.transactionMetrics.last, !t.isReusedConnection,
           let start = t.fetchStartDate, let end = t.connectEndDate ?? t.requestStartDate {
            value = end.timeIntervalSince(start)
        }
        let result = value
        state.withLock { $0 = (true, result) }
    }

    /// The figure once URLSession has delivered it (as the task ends), or nil after `limit`.
    func connectSeconds(waitingUpTo limit: Duration) async -> Double? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let (reported, value) = state.withLock { $0 }
            if reported { return value }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }
}

extension Duration {
    nonisolated var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
