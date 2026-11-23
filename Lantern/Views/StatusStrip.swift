import LlamaKit
import SwiftUI
import UIKit

/// Above the message box: what's loaded (or how the Mac is reached), memory, battery, heat. Also
/// suggests Fast when Smart is too slow or too costly on battery.
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
                }
                ViewThatFits {
                    line(memory: true)
                    line(memory: false)
                    Label(primary, systemImage: conversation.mode.symbol).lineLimit(1)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
            }
        }
        .task(id: conversation.mode) {
            UIDevice.current.isBatteryMonitoringEnabled = true
            if conversation.mode == .mac, mac.route == .unknown { await mac.resolve() }
        }
    }

    private func line(memory: Bool) -> some View {
        HStack(spacing: 10) {
            Label(primary, systemImage: conversation.mode.symbol).lineLimit(1)
            Spacer(minLength: 4)
            if memory, let free = MemoryStats.availableBytes, conversation.mode.isOnDevice {
                Text("\(MemoryStats.gb(free)) free")
            }
            Label(Power.batteryText, systemImage: Power.batterySymbol)
            if Power.isHot {
                Label("Hot", systemImage: "thermometer.high").foregroundStyle(.orange)
            }
        }
    }

    private var primary: String {
        let mode = conversation.mode
        if mode == .mac { return mac.route.label }
        if let loaded = engine.loadedModel, loaded.tier == mode { return loaded.name }
        guard let model = engine.model(for: mode) else { return "No model" }
        return engine.store.states[model.id] == .ready ? model.name : "\(model.name) isn't on this device"
    }

    private var spoken: String {
        var parts = [primary, "battery \(Power.batteryText)"]
        if conversation.mode.isOnDevice, let free = MemoryStats.availableBytes { parts.insert("\(MemoryStats.gb(free)) free", at: 1) }
        if Power.isHot { parts.append("device is hot") }
        return parts.joined(separator: ", ")
    }

    private struct Suggestion {
        let text: String, symbol: String, action: String, perform: () -> Void
    }

    private var suggestion: Suggestion? {
        let fast = engine.model(for: .fast).map { engine.store.states[$0.id] == .ready } ?? false
        guard conversation.mode == .smart, fast else { return nil }
        let runningHere = engine.running == conversation.persistentModelID
        if runningHere, let live = engine.live, live.text.isEmpty, Date().timeIntervalSince(live.started) > 20 {
            return Suggestion(text: "Taking a while.", symbol: "hourglass", action: "Use Fast") {
                engine.restart(in: conversation, mode: .fast)
            }
        }
        if !engine.isBusy, let reason = Power.reasonToSave {
            return Suggestion(text: "\(reason) Fast uses far less power.", symbol: "bolt.badge.clock", action: "Switch to Fast") {
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
