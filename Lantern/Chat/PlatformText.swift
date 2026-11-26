#if os(iOS)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformBezierPath = UIBezierPath
/// The text size and contrast settings fonts and colours follow: Dynamic Type on iOS.
typealias TextTraits = UITraitCollection
#else
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformBezierPath = NSBezierPath

/// The Mac has no Dynamic Type: one set of sizes, chosen for reading answers in a window.
struct TextTraits {
    static var current: TextTraits { TextTraits() }
}
#endif

/// The few places `Markdown` (shared by both apps) needs a font, colour or path, by platform.
extension PlatformFont {
    #if os(iOS)
    nonisolated static func lanternStyle(_ style: TextStyle, _ traits: TextTraits) -> PlatformFont {
        .preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    /// Monospaced at `size` points for the default text size, scaled with Dynamic Type.
    nonisolated static func lanternCode(size: CGFloat, traits: TextTraits) -> PlatformFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: size, weight: .regular), compatibleWith: traits)
    }

    /// How much Dynamic Type scales body text, to turn a scaled size back into a default one.
    nonisolated static func lanternTextScale(_ traits: TextTraits) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17
    }

    nonisolated func bold() -> PlatformFont { with(.traitBold) }
    nonisolated func italic() -> PlatformFont { with(.traitItalic) }

    nonisolated private func with(_ traits: UIFontDescriptor.SymbolicTraits) -> PlatformFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
    #else
    /// The body size answers are read at on the Mac; the iPhone's is 17.
    nonisolated static let lanternBodySize: CGFloat = 14

    nonisolated static func lanternStyle(_ style: TextStyle, _ traits: TextTraits) -> PlatformFont {
        let b = lanternBodySize
        return switch style {
        case .title1: .systemFont(ofSize: b + 9)
        case .title2: .systemFont(ofSize: b + 5)
        case .title3: .systemFont(ofSize: b + 2)
        case .headline: .systemFont(ofSize: b, weight: .semibold)
        case .subheadline, .callout: .systemFont(ofSize: b - 1)
        case .footnote: .systemFont(ofSize: b - 2)
        case .caption1, .caption2: .systemFont(ofSize: b - 3)
        default: .systemFont(ofSize: b)
        }
    }

    /// Monospaced at `size` points as the iPhone sizes it (body 17), scaled to the Mac's body.
    nonisolated static func lanternCode(size: CGFloat, traits: TextTraits) -> PlatformFont {
        .monospacedSystemFont(ofSize: (size * lanternBodySize / 17 + 0.5).rounded(), weight: .regular)
    }

    nonisolated static func lanternTextScale(_ traits: TextTraits) -> CGFloat { lanternBodySize / 17 }

    nonisolated func bold() -> PlatformFont { with(.bold) }
    nonisolated func italic() -> PlatformFont { with(.italic) }

    nonisolated private func with(_ traits: NSFontDescriptor.SymbolicTraits) -> PlatformFont {
        let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
    #endif
}

extension PlatformColor {
    #if os(iOS)
    nonisolated static var lanternLabel: PlatformColor { .label }
    nonisolated static var lanternSecondaryLabel: PlatformColor { .secondaryLabel }
    nonisolated static var lanternTertiaryLabel: PlatformColor { .tertiaryLabel }
    /// The table header's line and a thematic break: the separator, or with Increase Contrast
    /// something that reads.
    nonisolated static let lanternHairline = UIColor { $0.accessibilityContrast == .high ? .tertiaryLabel : .separator }
    /// In dark mode a code block's or table's fill is close to the background, so a hairline edges it.
    nonisolated static let lanternBlockEdge = UIColor { $0.userInterfaceStyle == .dark ? .separator : .clear }
    #else
    nonisolated static var lanternLabel: PlatformColor { .labelColor }
    nonisolated static var lanternSecondaryLabel: PlatformColor { .secondaryLabelColor }
    nonisolated static var lanternTertiaryLabel: PlatformColor { .tertiaryLabelColor }
    nonisolated static let lanternHairline = NSColor(name: nil) { _ in
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .tertiaryLabelColor : .separatorColor
    }
    nonisolated static let lanternBlockEdge = NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .separatorColor : .clear
    }
    #endif
}

extension PlatformBezierPath {
    nonisolated static func lanternRounded(_ rect: CGRect, radius: CGFloat) -> PlatformBezierPath {
        #if os(iOS)
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #else
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #endif
    }
}
