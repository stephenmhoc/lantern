import UIKit

/// Lantern's waiting state: a small amber flame-glow in place of a spinner. It breathes slowly
/// while the model works and brightens as text arrives. With Reduce Motion it holds still and only
/// its brightness changes.
final class GlowView: UIView {
    static let amber = UIColor(red: 1.0, green: 0.66, blue: 0.22, alpha: 1)

    private let container = CALayer()  // scaled by intensity
    private let halo = CAGradientLayer()  // breathes inside it
    private let core = CALayer()
    private var isRunning = false

    /// 0 (waiting) to 1 (text streaming in).
    var intensity: CGFloat = 0.3 {
        didSet { applyIntensity(animated: true) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        halo.type = .radial
        halo.colors = [Self.amber.withAlphaComponent(0.9).cgColor, Self.amber.withAlphaComponent(0.35).cgColor,
                       Self.amber.withAlphaComponent(0).cgColor]
        halo.locations = [0, 0.45, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        core.backgroundColor = Self.amber.cgColor
        container.addSublayer(halo)
        layer.addSublayer(container)
        layer.addSublayer(core)
        applyIntensity(animated: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 22, height: 22) }

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        halo.frame = container.bounds
        let d = bounds.width * 0.3
        core.frame = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        core.cornerRadius = d / 2
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isHidden = false
        addBreathing()
    }

    func stop() {
        isRunning = false
        halo.removeAnimation(forKey: "breathe")
        isHidden = true
    }

    /// A brief brighter flicker, for a tick in which new text arrived.
    func flicker() {
        guard isRunning, !UIAccessibility.isReduceMotionEnabled else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = halo.opacity
        a.duration = 0.35
        core.add(a, forKey: "flicker")
    }

    private func applyIntensity(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.4)
        halo.opacity = Float(0.35 + 0.65 * intensity)
        core.opacity = Float(0.55 + 0.45 * intensity)
        // With Reduce Motion it doesn't grow either: one size, only brighter or dimmer.
        let scale = UIAccessibility.isReduceMotionEnabled ? 0.85 : 0.7 + 0.3 * intensity
        container.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    private func addBreathing() {
        halo.removeAnimation(forKey: "breathe")
        guard isRunning, !UIAccessibility.isReduceMotionEnabled else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.82
        a.toValue = 1.08
        a.duration = 1.6
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(a, forKey: "breathe")
    }

    @objc private func motionChanged() {
        applyIntensity(animated: false)
        addBreathing()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { addBreathing() }  // Core Animation drops animations when a view leaves the window
    }
}
