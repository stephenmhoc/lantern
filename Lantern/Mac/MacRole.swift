#if targetEnvironment(macCatalyst)
import Foundation
import ServiceManagement

/// What this Mac does. Chosen once, on first run (`MacWelcomeView`), and changed in Settings.
/// A Mac never runs a model inside Lantern: it serves one to the others, or uses another Mac's.
enum MacRole: String {
    /// Serves its model: the bridge runs as a LaunchAgent (at login, and while Lantern is closed),
    /// devices pair with it, and this Mac's own chats use it on 127.0.0.1. All of it is `MacServer`.
    case serve
    /// Uses another Mac, exactly like an iPhone: it pairs with one, and never installs, starts or
    /// registers anything.
    case client

    static let key = "mac.role"

    /// Nil until chosen. A Mac that ran Lantern for Mac before 2.0 (it served its own bridge, and
    /// its chats talked to it on 127.0.0.1) carries on serving, if it still can.
    static var current: MacRole? {
        if let stored = UserDefaults.standard.string(forKey: key).flatMap(MacRole.init) { return stored }
        return canServe && (MacLink.lanHost.hasPrefix("127.0.0.1") || servedBefore) ? .serve : nil
    }

    /// Set by Lantern for Mac before 2.0 (the same app, in the same place) when it made itself
    /// open at login, to keep its bridge running.
    private static let oldLoginKey = "setUpOpenAtLogin"
    private static var servedBefore: Bool { UserDefaults.standard.object(forKey: oldLoginKey) != nil }

    /// At launch: carries on as chosen. A Mac that serves starts serving (the agent is likely
    /// running already, since login); a client makes sure no agent of Lantern's is left registered.
    static func resume(_ link: MacLink) {
        switch current {
        case .serve:
            UserDefaults.standard.set(MacRole.serve.rawValue, forKey: key)  // a Mac that served before
            MacServer.shared.start(link)
        case .client:
            MacServer.shared.unregisterIfNeeded()
        case nil:
            break
        }
        tidyOldApp()
    }

    /// What Lantern for Mac before 2.0 left behind. It opened at login to run its bridge as a child
    /// process; 2.0's bridge has a LaunchAgent, so the app no longer opens at login. (Its bridge,
    /// still running, gives up the port to the new one: Bridge/port.go. Its certificate and paired
    /// devices are in the same folder, so paired iPhones and iPads carry on.)
    private static func tidyOldApp() {
        guard servedBefore else { return }
        UserDefaults.standard.removeObject(forKey: oldLoginKey)
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
    }

    /// The first run's choice, or a change in Settings. Serving starts the bridge and pairs this
    /// Mac's chats with it; becoming a client stops it and unregisters its agent, and forgets the
    /// Mac it served (pairing with another is next).
    static func choose(_ role: MacRole, link: MacLink) async {
        let was = current
        guard role != was || UserDefaults.standard.string(forKey: key) == nil else { return }
        UserDefaults.standard.set(role.rawValue, forKey: key)
        switch role {
        case .serve:
            if was == .client { link.removeComputer() }  // the other Mac: this one answers now
            MacServer.shared.start(link)
        case .client:
            await MacServer.shared.stop(link)
        }
    }

    // MARK: - Which Macs can serve

    /// The M in "Apple M3 Max"; nil on an Intel Mac.
    static let chipGeneration: Int? = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let brand = String(cString: bytes)
        return brand.firstMatch(of: /Apple M(\d+)/).flatMap { Int($0.output.1) }
    }()

    /// Inkling needs Apple silicon from the M3 on and macOS 26.4.
    static let canServe: Bool = {
        guard let chip = chipGeneration, chip >= 3 else { return false }
        if #available(macCatalyst 26.4, *) { return true }
        return false
    }()

    /// Why this Mac can't serve, for the choice that's turned off.
    static var whyNot: String? {
        if canServe { return nil }
        guard let chip = chipGeneration, chip >= 3 else { return "Needs a Mac with an M3 chip or later." }
        return "Needs macOS 26.4 or later."
    }
}
#endif
