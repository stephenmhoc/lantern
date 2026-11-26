import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformBezierPath = UIBezierPath
/// The text size and contrast settings fonts and colours follow: Dynamic Type.
typealias TextTraits = UITraitCollection

/// The few places `Markdown` needs a font, colour or path (names from when a native Mac app shared it).
extension PlatformFont {
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
}

extension PlatformColor {
    nonisolated static var lanternLabel: PlatformColor { .label }
    nonisolated static var lanternSecondaryLabel: PlatformColor { .secondaryLabel }
    nonisolated static var lanternTertiaryLabel: PlatformColor { .tertiaryLabel }
    /// The table header's line and a thematic break: the separator, or with Increase Contrast
    /// something that reads.
    nonisolated static let lanternHairline = UIColor { $0.accessibilityContrast == .high ? .tertiaryLabel : .separator }
    /// In dark mode a code block's or table's fill is close to the background, so a hairline edges it.
    nonisolated static let lanternBlockEdge = UIColor { $0.userInterfaceStyle == .dark ? .separator : .clear }
}

extension PlatformBezierPath {
    nonisolated static func lanternRounded(_ rect: CGRect, radius: CGFloat) -> PlatformBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
    }
}
