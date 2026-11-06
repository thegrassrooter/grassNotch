import AppKit
import QuartzCore

@MainActor
private final class LiveActivityIslandView: NSView {
    let activity: GrassLiveActivity
    var onActivate: (() -> Void)?
    private let symbolView = NSImageView()

    init(activity: GrassLiveActivity, frame: NSRect) {
        self.activity = activity
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(activity.utility.title)")
        toolTip = "Open \(activity.utility.title)"
        symbolView.image = NSImage(systemSymbolName: activity == .timer ? "timer" : "stopwatch",
                                  accessibilityDescription: activity.utility.title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        symbolView.contentTintColor = .white
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(symbolView)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.setFill()
        capsule.fill()
    }

    override func layout() {
        super.layout()
        symbolView.frame = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onActivate?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the small, independent activity islands on the built-in display and
/// every mirrored display. Keeping these as tiny panels leaves the main notch
/// geometry and all of its existing activity layouts untouched.
@MainActor
final class GrassLiveActivityIslandController {
    private final class Entry {
        let panel: NSPanel
        let view: LiveActivityIslandView

        init(panel: NSPanel, view: LiveActivityIslandView) {
            self.panel = panel
            self.view = view
        }
    }

    private var entries: [UInt32: [GrassLiveActivity: Entry]] = [:]
    private let islandSize = NSSize(width: 44, height: 34)
    private let gap: CGFloat = 12

    func update(
        activities: [GrassLiveActivity],
        screens: [(id: UInt32, screen: NSScreen)],
        notchWidth: CGFloat,
        animatePositionChanges: Bool = true,
        positionAnimationDuration: TimeInterval = 0.36,
        onSelect: @escaping (GrassLiveActivity) -> Void
    ) {
        let limited = Array(activities.prefix(2))
        let connectedIDs = Set(screens.map(\.id))
        for displayID in entries.keys.filter({ !connectedIDs.contains($0) }) {
            entries[displayID]?.values.forEach { $0.panel.orderOut(nil) }
            entries.removeValue(forKey: displayID)
        }

        for (displayID, screen) in screens {
            var displayEntries = entries[displayID, default: [:]]
            let exitingEntries = displayEntries.filter { !limited.contains($0.key) }
            for (activity, entry) in exitingEntries {
                displayEntries.removeValue(forKey: activity)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    entry.panel.animator().alphaValue = 0
                    var target = entry.panel.frame
                    target.size.width = 2
                    target.origin.x += activityIsOnRight(activity, in: limited) ? 20 : 0
                    entry.panel.animator().setFrame(target, display: true)
                } completionHandler: { [weak self, weak panel = entry.panel] in
                    Task { @MainActor in
                        guard let self, let panel else { return }
                        panel.orderOut(nil)
                        // The activity may have restarted while its exit animation ran.
                        if self.entries[displayID]?[activity]?.panel === panel {
                            self.entries[displayID]?.removeValue(forKey: activity)
                        }
                    }
                }
            }

            for (index, activity) in limited.enumerated() {
                let onRight = index == 0
                let target = islandFrame(onRight: onRight, screen: screen, notchWidth: notchWidth)
                if let entry = displayEntries[activity] {
                    if !entry.panel.frame.equalTo(target) {
                        if animatePositionChanges {
                            NSAnimationContext.runAnimationGroup { context in
                                context.duration = max(0.12, positionAnimationDuration)
                                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
                                entry.panel.animator().setFrame(target, display: true)
                            }
                        } else {
                            entry.panel.setFrame(target, display: true)
                        }
                    }
                    entry.view.onActivate = { onSelect(activity) }
                } else {
                    let panel = NSPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
                    panel.level = .statusBar
                    panel.backgroundColor = .clear
                    panel.isOpaque = false
                    panel.hasShadow = false
                    panel.ignoresMouseEvents = false
                    panel.hidesOnDeactivate = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                    let view = LiveActivityIslandView(activity: activity,
                                                      frame: NSRect(origin: .zero, size: target.size))
                    view.autoresizingMask = [.width, .height]
                    view.onActivate = { onSelect(activity) }
                    panel.contentView = view
                    let start = target.offsetBy(dx: onRight ? -12 : 12, dy: 0)
                    panel.setFrame(start, display: false)
                    panel.alphaValue = 0
                    let entry = Entry(panel: panel, view: view)
                    displayEntries[activity] = entry
                    panel.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.34
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
                        panel.animator().alphaValue = 1
                        panel.animator().setFrame(target, display: true)
                    }
                }
            }
            entries[displayID] = displayEntries
        }
    }

    func dismissAll() {
        entries.values.forEach { $0.values.forEach { $0.panel.orderOut(nil) } }
        entries.removeAll()
    }

    private func islandFrame(onRight: Bool, screen: NSScreen, notchWidth: CGFloat) -> NSRect {
        let x = onRight
            ? screen.frame.midX + notchWidth / 2 + gap
            : screen.frame.midX - notchWidth / 2 - gap - islandSize.width
        let height = screen.safeAreaInsets.top > 0
            ? min(40, max(islandSize.height, screen.safeAreaInsets.top))
            : islandSize.height
        let size = NSSize(width: islandSize.width, height: height)
        return NSRect(x: x, y: screen.frame.maxY - height, width: size.width, height: size.height)
    }

    private func activityIsOnRight(_ activity: GrassLiveActivity, in activities: [GrassLiveActivity]) -> Bool {
        activities.first == activity
    }
}
