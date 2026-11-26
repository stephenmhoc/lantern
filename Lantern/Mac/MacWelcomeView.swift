#if targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac's first run: what this Mac does (`MacRole`), asked once and changed in Settings.
/// Serving runs Inkling here, for this Mac and the devices paired with it; using another Mac
/// pairs with one that serves, like an iPhone does.
struct MacWelcomeView: View {
    let choose: (MacRole) -> Void
    @State private var pick: MacRole = MacRole.canServe ? .serve : .client

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(.tint.opacity(0.14), in: .circle)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("Welcome to Lantern").font(.title.bold())
                Text("An assistant that keeps working with the internet down. How will this Mac chat?")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                RoleOption(
                    role: .serve, pick: $pick, symbol: "desktopcomputer", title: "Serve Inkling from This Mac",
                    detail: "Inkling runs here, for this Mac and the iPhones and iPads you pair with it, at home or away. It keeps serving while Lantern is closed.",
                    unavailable: MacRole.whyNot)
                RoleOption(
                    role: .client, pick: $pick, symbol: "laptopcomputer", title: "Use Another Mac",
                    detail: "Chat with Inkling on a Mac that serves it, the way an iPhone does. Nothing runs here in the background.")
            }

            HStack {
                Text("You can change this in Settings.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Continue") { choose(pick) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.top, 24)
        }
        .padding(32)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}

/// One of the two roles, as a card: picked with a click, outlined in the accent when it is.
private struct RoleOption: View {
    let role: MacRole
    @Binding var pick: MacRole
    let symbol: String
    let title: String
    let detail: String
    var unavailable: String?
    @State private var hovering = false

    private var picked: Bool { pick == role }

    var body: some View {
        Button { pick = role } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(unavailable ?? detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(.rect(cornerRadius: 12))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(picked ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0.035)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: picked ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
        .opacity(unavailable != nil ? 0.5 : 1)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
#endif
