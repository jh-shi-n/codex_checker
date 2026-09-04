import AppKit

/// Mouse-transparent black connector between the two interactive quota wings.
@MainActor
public final class CenterBridgePanel: NotchQuotaPanel {
    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        hasShadow = false
        level = .statusBar
    }
}
