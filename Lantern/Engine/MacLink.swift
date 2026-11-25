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
    /// How long Ollama keeps a model in memory after a request (`keep_alive`). Inkling, the usual
    /// model, stays for good (-1): Ollama's own default is five minutes, after which a question
    /// waits for the whole model to load again. The others are left out (nil), so the server's
    /// `OLLAMA_KEEP_ALIVE` (30 minutes, from `scripts/mac-ollama-setup.sh`) applies: keeping all
    /// three resident held ~60 GB of the Mac's memory for good. A request's value overrides the
    /// server's, which is why the others send none.
    nonisolated static func keepAlive(for model: String) -> Int? {
        model.lowercased().hasPrefix("inkling") ? -1 : nil
    }

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
        #if DEBUG
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
                // Away from home the local name never answers: don't sit out its timeout.
                if case .some(.some) = t, l == nil, !graceStarted {
                    graceStarted = true
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(300))
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
        if !h.contains(":") { h += ":11434" }
        return h
    }

    /// The model names Ollama has, or nil if the host doesn't answer.
    static func tags(_ host: String?, session: URLSession = .shared, timeout: TimeInterval = 2.5) async -> [String]? {
        await listing(host, session: session, timeout: timeout)?.map(\.name)
    }

    /// The models Ollama has, with their sizes (`/api/tags`), or nil if the host doesn't answer.
    static func listing(_ host: String?, session: URLSession = .shared, timeout: TimeInterval = 2.5) async -> [OllamaModel]? {
        guard let host, let url = URL(string: "http://\(host)/api/tags") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(TagList.self, from: data) else { return nil }
        return list.models
    }

    /// Stops when the reading task is cancelled. A route that has gone stale (left home, Wi-Fi
    /// dropped) gets one fresh check and retry before giving up. The `Request` returned with the
    /// stream has the route and, once `.done` arrives, the timings.
    func stream(
        _ messages: [ChatMessage], thinking: Thinking, model: String
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
        let metrics = ConnectMetrics()
        let (bytes, _) = try await open(messages, thinking: thinking, model: model, metrics: metrics, retry: true)
        lastWarm[model] = .now  // a real request keeps it loaded as well as a warm-up does
        let request = Request(route: route, timings: timings)  // after `open`, which may have re-resolved
        let stream = AsyncThrowingStream<Generation, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: Data(line.utf8)) else { continue }
                        if let error = chunk.error { throw MacError.ollama(error) }
                        if let t = chunk.message?.thinking, !t.isEmpty { continuation.yield(.thinking(t)) }
                        if let t = chunk.message?.content, !t.isEmpty { continuation.yield(.text(t)) }
                        if chunk.done == true {
                            timings.loadSeconds = Double(chunk.load_duration ?? 0) / 1e9
                            timings.readSeconds = Double(chunk.prompt_eval_duration ?? 0) / 1e9
                            timings.serverSeconds = chunk.total_duration.map { Double($0) / 1e9 }
                            // URLSession reports the connection's metrics as the task ends.
                            timings.connectSeconds = await metrics.connectSeconds(waitingUpTo: .milliseconds(300))
                            request.timings = timings
                            var stats = GenerationStats()
                            stats.promptTokens = chunk.prompt_eval_count ?? 0
                            stats.promptSeconds = Double(chunk.prompt_eval_duration ?? 0) / 1e9
                            stats.generatedTokens = chunk.eval_count ?? 0
                            stats.generateSeconds = Double(chunk.eval_duration ?? 0) / 1e9
                            continuation.yield(.done(stats))
                        }
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()  // Stop, not a failure
                } catch {
                    if error is URLError { route = .unknown }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, request)
    }

    /// Gets the Mac ready for a question that's coming (a chat opened, typing started): finds the
    /// route if it isn't known or the network changed, then asks Ollama to load the model, which an
    /// empty chat request does without generating anything. It also opens the connection (and the
    /// tailnet's path to the Mac) before it's needed. Cheap to call often: it does nothing if this
    /// model was warmed in the last minute on the same network.
    func warm(_ model: String) {
        guard !model.isEmpty, !warming.contains(model) else { return }
        if let last = lastWarm[model], Date().timeIntervalSince(last) < 60, !routeIsStale, route.host != nil { return }
        warming.insert(model)
        Task {
            defer { warming.remove(model) }
            if route.host == nil || routeIsStale { await resolve() }
            guard let host = route.host, let url = URL(string: "http://\(host)/api/chat") else { return }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The same num_ctx as a real request: a different one would make Ollama load it again.
            request.httpBody = try? JSONEncoder().encode(ChatRequest(
                model: model, messages: [], stream: false, think: nil,
                options: .init(num_ctx: contextLength), keep_alive: Self.keepAlive(for: model)))
            lastWarm[model] = .now
            if (try? await session.data(for: request)) == nil { lastWarm[model] = nil }
        }
    }

    /// Where requests go on the current route: through Lantern's tailnet node when that's the route.
    fileprivate var session: URLSession {
        if case .tailnet(_, viaApp: false) = route { return tailnet.session ?? .shared }
        return .shared
    }

    /// Asks Ollama whether a model has vision. A model it can't describe counts as without.
    func canSee(_ model: String) async -> Bool {
        if let known = vision[model] { return known }
        guard let host = route.host, let url = URL(string: "http://\(host)/api/show") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["model": model])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(ShowResponse.self, from: data) else { return false }
        let sees = info.capabilities?.contains("vision") == true
        vision[model] = sees
        return sees
    }

    private func open(
        _ messages: [ChatMessage], thinking: Thinking, model: String, metrics: ConnectMetrics, retry: Bool
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let host = route.host, let url = URL(string: "http://\(host)/api/chat") else { throw MacError.unreachable }
        guard !model.isEmpty else { throw MacError.noModel }
        var request = URLRequest(url: url, timeoutInterval: 120)  // between bytes, not overall
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sent even when off, or a thinking model thinks anyway; left out for models that reject it.
        // A model that always thinks is asked for its thinking even when it's off: told not to,
        // it thinks anyway and Ollama hides it, so nothing shows for seconds (Inkling: first
        // token after 4 s instead of 0.4 s on the Mac Studio, the answer at the same moment).
        let think: Bool? = cannotThink.contains(model) ? nil : thinking != .off || Self.alwaysThinks(model)
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages.map {
                .init(role: $0.role.rawValue, content: $0.content, images: $0.images?.map { $0.base64EncodedString() })
            },
            stream: true,
            think: think,
            options: .init(num_ctx: contextLength),
            keep_alive: Self.keepAlive(for: model)
        ))
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
            guard let code = (response as? HTTPURLResponse)?.statusCode, code == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Ollama explains itself in a small JSON body.
                var body = Data()
                for try await byte in bytes.prefix(4096) { body.append(byte) }
                let message = (try? JSONDecoder().decode(ChatChunk.self, from: body))?.error
                if code == 400, think != nil, message?.localizedCaseInsensitiveContains("think") == true {
                    cannotThink.insert(model)  // not a thinking model: ask again without it, once
                    return try await open(messages, thinking: thinking, model: model, metrics: metrics, retry: retry)
                }
                throw MacError.http(code, model: model, message: message)
            }
            return (bytes, response)
        } catch let error as URLError where error.code != .cancelled && retry {
            await resolve()
            return try await open(messages, thinking: thinking, model: model, metrics: metrics, retry: false)
        }
    }

    /// One of Ollama's models, from `/api/tags`.
    nonisolated struct OllamaModel: Decodable, Hashable, Sendable {
        let name: String
        let size: Int64?
    }

    private struct TagList: Decodable { let models: [OllamaModel] }

    fileprivate struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String; let images: [String]? }
        struct Options: Encodable { let num_ctx: Int }
        let model: String
        let messages: [Message]
        let stream: Bool
        let think: Bool?  // left out when nil
        let options: Options
        let keep_alive: Int?  // left out when nil: the server's OLLAMA_KEEP_ALIVE applies
    }

    fileprivate struct ShowResponse: Decodable { let capabilities: [String]? }

    fileprivate struct ChatChunk: Decodable {
        struct Message: Decodable { let content: String?; let thinking: String? }
        let message: Message?
        let done: Bool?
        let error: String?
        let total_duration: Int64?
        let load_duration: Int64?
        let prompt_eval_count: Int?
        let prompt_eval_duration: Int64?
        let eval_count: Int?
        let eval_duration: Int64?
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
    static var isConfigured: Bool { normalized(lanHost) != nil || normalized(tailnetHost) != nil }

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
        configure(name: nil, lan: "", tailnet: "")
        models = []
        modelSizes = [:]
        defaults.removeObject(forKey: "mac.knownModels")
    }

    /// Ollama's version on the current route ("0.40.18").
    func ollamaVersion() async -> String? {
        guard let host = route.host else { return nil }
        return await Self.version(host, session: session)
    }

    /// Ollama's version at a host, or nil if nothing answers there.
    static func version(_ host: String?, session: URLSession = .shared, timeout: TimeInterval = 2.5) async -> String? {
        guard let host, let url = URL(string: "http://\(host)/api/version") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONDecoder().decode(VersionResponse.self, from: data) else { return nil }
        return v.version
    }

    /// The models Ollama has in memory now (`/api/ps`), or nil without an answer.
    func loadedModels() async -> Set<String>? {
        guard let host = route.host, let url = URL(string: "http://\(host)/api/ps") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(PSResponse.self, from: data) else { return nil }
        return Set(list.models.map(\.name))
    }

    /// What a model can do, from `/api/show` ("thinking", "vision"…), asked once per model.
    func capabilities(of model: String) async -> Set<String>? {
        if let known = capabilityCache[model] { return known }
        guard let host = route.host, let url = URL(string: "http://\(host)/api/show") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["model": model])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(ShowResponse.self, from: data) else { return nil }
        let set = Set(info.capabilities ?? [])
        capabilityCache[model] = set
        vision[model] = set.contains("vision")
        return set
    }

    /// The result of "Test Connection".
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
        guard let host = found.host, let url = URL(string: "http://\(host)/api/chat") else {
            result.failure = "Ollama didn't answer on the home network or the tailnet."
            result.totalSeconds = (ContinuousClock.now - started).seconds
            return result
        }
        guard !model.isEmpty else {
            result.failure = MacError.noModel.errorDescription
            result.totalSeconds = (ContinuousClock.now - started).seconds
            return result
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ChatRequest(
            model: model, messages: [], stream: false, think: nil,
            options: .init(num_ctx: contextLength), keep_alive: Self.keepAlive(for: model)))
        // A fresh connection, so "connected" is measured rather than reused from finding it. Lantern's
        // own tailnet node has one session, used as it is.
        let fresh = session === URLSession.shared
        let testSession = fresh ? URLSession(configuration: .ephemeral) : session
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
                let message = (try? JSONDecoder().decode(ChatChunk.self, from: data))?.error
                result.failure = MacError.http(code, model: model, message: message).errorDescription
            } else {
                // An empty chat only loads: what isn't the connection is Ollama loading the model.
                let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data)
                result.timings.loadSeconds = chunk?.load_duration.map { Double($0) / 1e9 } ?? max(0, elapsed - (connect ?? 0))
                lastWarm[model] = .now
            }
        } catch {
            result.failure = error.localizedDescription
        }
        result.totalSeconds = (ContinuousClock.now - started).seconds
        return result
    }

    private struct VersionResponse: Decodable { let version: String }
    private struct PSResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}

nonisolated enum MacError: LocalizedError {
    case unreachable, noModel, http(Int, model: String, message: String?), ollama(String), noVision(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: "Can't reach Ollama on the Mac over the home network or the tailnet."
        case .noModel: "Ollama on the Mac has no models."
        case .http(404, let model, _):
            "The Mac doesn't have the model \(model) any more. Pick another in Settings, or pull it in Ollama."
        case .http(400, _, let message): "Ollama couldn't use this request: \(message ?? "bad request")."
        case .http(401, _, _), .http(403, _, _): "Ollama on the Mac refused the connection. Check that it allows this device."
        case .http(429, _, _), .http(503, _, _): "Ollama on the Mac is busy. Try again in a moment."
        case .http(let code, let model, let message) where code >= 500:
            "Ollama on the Mac failed to run \(model)\(message.map { ": \($0)" } ?? " (HTTP \(code))"). It may be out of memory."
        case .http(let code, _, let message): "Ollama answered with HTTP \(code)\(message.map { ": \($0)" } ?? "")."
        case .ollama(let message): "Ollama: \(message)"
        case .noVision(let model): "\(model) on the Mac can't see images. Pick a vision model in Settings, or use Gemma on this device."
        }
    }

    var kind: ReplyErrorKind {
        switch self {
        case .unreachable: .macUnreachable
        case .noModel, .http(404, _, _): .macNoModel
        case .http, .ollama, .noVision: .macFailed
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
