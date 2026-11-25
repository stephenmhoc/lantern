import AppIntents
import StoreKit
import SwiftUI
import WidgetKit

// Deep links and static content only: no App Group, so nothing here reads the app's chats.
// Every tap opens the app through a `lantern://` link (LanternLink.swift, shared with the app).

@main
struct LanternWidgetBundle: WidgetBundle {
    var body: some Widget {
        AskWidget()
        AccessoryWidget()
        NewChatControl()
    }
}

extension Color {
    /// The app's AccentColor (#F29629). A constant, not a second asset catalog in this target.
    static let lanternAmber = Color(red: 0xF2 / 255, green: 0x96 / 255, blue: 0x29 / 255)
}

// MARK: - Timeline

struct BuildEntry: TimelineEntry {
    let date: Date
    /// When this TestFlight build stops launching; nil outside TestFlight.
    let expiry: Date?
}

struct BuildProvider: TimelineProvider {
    func placeholder(in context: Context) -> BuildEntry { BuildEntry(date: .now, expiry: nil) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (BuildEntry) -> Void) {
        completion(BuildEntry(date: .now, expiry: nil))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<BuildEntry>) -> Void) {
        Task {
            let entry = BuildEntry(date: .now, expiry: await BuildExpiry.date())
            // Nothing changes but the day; check again tomorrow.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(86_400))))
        }
    }
}

/// Like `Readiness.expiry` in the app: 90 days after `LanternBuildDate`, for TestFlight installs.
enum BuildExpiry {
    static func date() async -> Date? {
        guard let built = buildDate else { return nil }
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-testflight") else { return nil }
        #else
        guard case .verified(let t)? = try? await AppTransaction.shared, t.environment == .sandbox else { return nil }
        #endif
        return built.addingTimeInterval(90 * 86_400)
    }

    /// Stamped into the app's Info.plist at build time. The extension sits in Lantern.app/PlugIns,
    /// so the app's Info.plist is two levels up.
    static var buildDate: Date? {
        let appPlist = Bundle.main.bundleURL.appending(path: "../../Info.plist").standardizedFileURL
        if let info = NSDictionary(contentsOf: appPlist), let date = info["LanternBuildDate"] as? Date { return date }
        return Bundle.main.object(forInfoDictionaryKey: "LanternBuildDate") as? Date
    }
}

private struct ModeLink: Identifiable {
    let mode: String
    let title: String
    let symbol: String
    var id: String { mode }
    var url: URL { LanternLink.new(mode: mode).url }

    static let all = [
        ModeLink(mode: "fast", title: "E2B", symbol: "cpu"),
        ModeLink(mode: "smart", title: "E4B", symbol: "cpu"),
        ModeLink(mode: "qwen", title: "Qwen", symbol: "cpu"),
        ModeLink(mode: "mac", title: "Mac", symbol: "desktopcomputer"),
        ModeLink(mode: "apple", title: "Apple", symbol: "apple.intelligence"),
    ]
}

// MARK: - Home screen

struct AskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AskLantern", provider: BuildProvider()) { entry in
            AskWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Ask Lantern")
        .description("Start a chat, in the usual mode or a chosen one.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AskWidgetView: View {
    let entry: BuildEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: LanternLink.new(mode: nil).url) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.title2)
                        .foregroundStyle(Color.lanternAmber)
                        .widgetAccentable()  // tinted with the rest of the accent in tinted and clear modes
                    Text("Ask Lantern")
                        .font(.headline)
                    if family == .systemMedium {
                        Text("Works without the internet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(ModeLink.all) { m in
                    Link(destination: m.url) {
                        modeButton(m)
                    }
                }
            }
            if family == .systemMedium, let expiry = entry.expiry {
                Text("Build expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // A small widget is one tap target on some systems: the whole of it starts a chat.
        .widgetURL(LanternLink.new(mode: nil).url)
    }

    @ViewBuilder
    private func modeButton(_ m: ModeLink) -> some View {
        Group {
            if family == .systemMedium {
                Label(m.title, systemImage: m.symbol)
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: m.symbol).font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(.fill.secondary, in: .capsule)
        .accessibilityLabel("New \(m.title) chat")
    }
}

// MARK: - Lock screen

struct AccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AskLanternAccessory", provider: BuildProvider()) { entry in
            AccessoryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Ask Lantern")
        .description("Start a chat from the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct AccessoryView: View {
    let entry: BuildEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label {
                        Text("Ask Lantern")
                    } icon: {
                        Image(systemName: "flame.fill").widgetAccentable()
                    }
                    .font(.headline)
                    if let expiry = entry.expiry {
                        Text("Build expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                    } else {
                        Text("Works offline").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                Label("Ask Lantern", systemImage: "flame.fill")
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "flame.fill").font(.title2).widgetAccentable()
                }
                .accessibilityLabel("Ask Lantern")
            }
        }
        .widgetURL(LanternLink.new(mode: nil).url)
    }
}

// MARK: - Control Center

struct NewChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.merimerimeri.Lantern.NewChat") {
            ControlWidgetButton(action: NewChatIntent()) {
                Label("New Chat", systemImage: "flame.fill")
            }
        }
        .displayName("New Lantern Chat")
        .description("Opens Lantern on a new chat.")
    }
}
