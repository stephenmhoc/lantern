import SwiftData
import SwiftUI
import UIKit

/// Which row in the side panel has its actions out, and on which side. One at a time: swiping
/// another row, scrolling or tapping anywhere in the list puts them away.
struct SwipeOpen: Equatable {
    var id: PersistentIdentifier
    var edge: HorizontalEdge
}

/// A chat row in the side panel with its swipe actions drawn to match the panel: the row slides
/// inside its own rounded shape and round buttons grow into the gap it leaves (Pin on the left,
/// Rename and Delete on the right), instead of the list's full-height coloured slabs. A swipe
/// never acts by itself (no full swipe): deleting is immediate, with no undo.
struct SwipeRow<Content: View>: View {
    let id: PersistentIdentifier
    @Binding var open: SwipeOpen?
    let pinned: Bool
    let onPin: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    /// How far the row moves to show each side's buttons.
    private static var leadingWidth: CGFloat { 60 }
    private static var trailingWidth: CGFloat { 112 }
    private static var button: CGFloat { 40 }

    /// The live drag, from where the row sat when it started.
    @State private var drag: CGFloat?
    /// Whether the drag is past the point where letting go opens: a tick when it crosses.
    @State private var armed = false

    private var edge: HorizontalEdge? { open?.id == id ? open?.edge : nil }

    private var settled: CGFloat {
        switch edge {
        case .leading?: Self.leadingWidth
        case .trailing?: -Self.trailingWidth
        case nil: 0
        }
    }

    private var offset: CGFloat {
        guard let drag else { return settled }
        return Self.resist(settled + drag)
    }

    var body: some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                actions(width: max(0, offset), total: Self.leadingWidth) {
                    circle(pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash.fill" : "pin.fill",
                           fill: .accentColor, ink: .black) { close(then: onPin) }
                }
            }
            .background(alignment: .trailing) {
                actions(width: max(0, -offset), total: Self.trailingWidth) {
                    circle("Rename", symbol: "pencil", fill: Color(.systemGray4), ink: .primary) { close(then: onRename) }
                    circle("Delete", symbol: "trash.fill", fill: .red, ink: .white) { close(animated: false, then: onDelete) }
                }
            }
            // The title slides under the row's own rounded edge, not off the side of the panel.
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .gesture(HorizontalPan(changed: dragged, ended: released))
            .accessibilityActions {
                Button(pinned ? "Unpin" : "Pin", action: onPin)
                Button("Rename", action: onRename)
                Button("Delete", action: onDelete)
            }
    }

    /// The buttons for one side, in the gap the row leaves: clipped to it, and growing from small
    /// and faint to full size as it opens.
    private func actions(width: CGFloat, total: CGFloat, @ViewBuilder _ buttons: () -> some View) -> some View {
        let progress = min(1, width / total)
        return HStack(spacing: 10) { buttons() }
            .fixedSize()
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(Double(progress))
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(progress == 1)
            .accessibilityHidden(true)
    }

    private func circle(_ title: String, symbol: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: Self.button, height: Self.button)
                .background(fill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Dragging

    private func dragged(_ translation: CGFloat) {
        // Another row's actions go away as this one starts moving.
        if drag == nil, let other = open, other.id != id { withAnimation(Self.spring) { open = nil } }
        drag = translation
        let now = target(for: settled + translation) != nil
        if now != armed {
            armed = now
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
        }
    }

    private func released(_ translation: CGFloat, velocity: CGFloat) {
        // Where a flick would carry it, not just where the finger stopped.
        let projected = settled + translation + velocity * 0.15
        // Swiping an open row back the other way only closes it.
        let wanted = settled != 0 && (projected * settled < 0) ? nil : target(for: projected)
        withAnimation(Self.spring) {
            drag = nil
            if let wanted {
                open = SwipeOpen(id: id, edge: wanted)
            } else if edge != nil {
                open = nil
            }
        }
        armed = false
    }

    /// The side that opens if the row is let go at `x`: past half of that side's buttons.
    private func target(for x: CGFloat) -> HorizontalEdge? {
        if x > Self.leadingWidth / 2 { return .leading }
        if x < -Self.trailingWidth / 2 { return .trailing }
        return nil
    }

    private func close(animated: Bool = true, then action: () -> Void) {
        if animated {
            withAnimation(Self.spring) { open = nil }
        } else {
            open = nil
        }
        action()
    }

    /// Past its buttons the row only follows the finger a quarter as far.
    private static func resist(_ x: CGFloat) -> CGFloat {
        if x > leadingWidth { return leadingWidth + (x - leadingWidth) * 0.25 }
        if x < -trailingWidth { return -trailingWidth + (x + trailingWidth) * 0.25 }
        return x
    }

    private static var spring: Animation { .spring(response: 0.32, dampingFraction: 0.86) }
}

/// A horizontal pan that leaves vertical ones to the list: it only begins when the finger moves
/// mostly sideways, so scrolling the panel is untouched. A UIKit recognizer, since a SwiftUI
/// drag on a list row holds up the list's scrolling. Trackpad two-finger swipes count too.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedScrollTypesMask = .continuous
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let x = pan.translation(in: pan.view).x
        switch pan.state {
        case .began, .changed: changed(x)
        case .ended: ended(x, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }
    }
}
