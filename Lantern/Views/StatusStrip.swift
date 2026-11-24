import LlamaKit
import SwiftUI
import UIKit

/// Above the message box, only when there's something to suggest: Gemma 4 E2B when E4B is too slow
/// or too costly on battery. What's loaded, memory, battery and heat are in the chat's info panel.
struct StatusStrip: View {
    let conversation: Conversation
    @Environment(Engine.self) private var engine
    @Environment(MacLink.self) private var mac

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                if let suggestion {
                    HStack {
                        Label(suggestion.text, systemImage: suggestion.symbol)
                        Spacer()
                        Button(suggestion.action, action: suggestion.perform).buttonStyle(.bordered).controlSize(.small)
                    }
                    .font(.footnote)
                    .padding(.bottom, 6)  // the composer adds no spacing after the strip, so it takes none when empty
                }
            }
        }
        .task(id: conversation.mode) {
            UIDevice.current.isBatteryMonitoringEnabled = true
            if conversation.mode == .mac, mac.route == .unknown { await mac.resolve() }
        }
    }

    private struct Suggestion {
        let text: String, symbol: String, action: String, perform: () -> Void
    }

    private var suggestion: Suggestion? {
        let fast = engine.model(for: .fast).map { engine.store.states[$0.id] == .ready } ?? false
        guard conversation.mode == .smart, fast else { return nil }
        let runningHere = engine.running == conversation.persistentModelID
        if runningHere, let live = engine.live, live.text.isEmpty, Date().timeIntervalSince(live.started) > 20 {
            return Suggestion(text: "Taking a while.", symbol: "hourglass", action: "Use E2B") {
                engine.restart(in: conversation, mode: .fast)
            }
        }
        if !engine.isBusy, let reason = Power.reasonToSave {
            return Suggestion(text: "\(reason) E2B uses less power.", symbol: "bolt.badge.clock", action: "Switch to E2B") {
                conversation.mode = .fast
            }
        }
        return nil
    }
}

enum Power {
    static var level: Float { UIDevice.current.batteryLevel }
    static var isCharging: Bool { [.charging, .full].contains(UIDevice.current.batteryState) }
    static var isHot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }

    static var batteryText: String { level < 0 ? "–" : "\(Int(level * 100))%" }
    static var batterySymbol: String {
        if isCharging { return "battery.100.bolt" }
        return level < 0.2 ? "battery.25" : level < 0.6 ? "battery.50" : "battery.100"
    }

    /// Why to prefer Fast right now, if there's a reason.
    static var reasonToSave: String? {
        if isHot { return "The device is hot." }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Low Power Mode is on." }
        if level >= 0, level < 0.2, !isCharging { return "Battery is low." }
        return nil
    }
}
