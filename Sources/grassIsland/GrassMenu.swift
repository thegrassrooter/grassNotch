import SwiftUI

@MainActor
final class GrassMenuModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var selectedPage: Page = .home
    @Published private(set) var selectedUtility: GrassUtilityApp = .calculator
    @Published private(set) var detachedUtility: GrassUtilityApp?
    @Published private(set) var detachPullDistance: CGFloat = 0

    enum Page { case home, phone, utility }

    var onPresentationChange: ((Bool) -> Void)?
    var onContentChange: (() -> Void)?
    var onOpenNotchSettings: (() -> Void)?
    var onDetachUtility: ((GrassUtilityApp) -> Bool)?

    func toggle() {
        setPresented(!isPresented)
    }

    func present() {
        setPresented(true)
    }

    func dismiss() {
        setPresented(false)
    }

    func openPhone() {
        guard selectedPage != .phone else { return }
        selectedPage = .phone
        onContentChange?()
    }

    func openUtility(_ app: GrassUtilityApp) {
        guard detachedUtility != app else { return }
        selectedUtility = app
        selectedPage = .utility
        onContentChange?()
    }

    func presentUtilityForLiveActivity(_ app: GrassUtilityApp) {
        guard detachedUtility != app else { return }
        selectedUtility = app
        selectedPage = .utility
        if !isPresented { setPresented(true) }
        onContentChange?()
    }

    func detachUtility(_ app: GrassUtilityApp) {
        guard detachedUtility == nil else { return }
        // Only lock the tile after the island controller confirms that it
        // actually created the detached panel. A stale transition must not
        // leave the menu thinking an island exists when it does not.
        guard onDetachUtility?(app) == true else { return }
        detachedUtility = app
        setPresented(false)
    }

    func reattachUtility(_ app: GrassUtilityApp) {
        guard detachedUtility == app else { return }
        detachedUtility = nil
        selectedUtility = app
        selectedPage = .utility
        setPresented(true)
        onContentChange?()
    }

    func finishDetachedUtility(_ app: GrassUtilityApp) {
        guard detachedUtility == app else { return }
        detachedUtility = nil
        onContentChange?()
    }

    func updateDetachPull(_ distance: CGFloat) {
        detachPullDistance = min(110, max(0, distance))
    }

    func returnHome() {
        guard selectedPage != .home else { return }
        selectedPage = .home
        onContentChange?()
    }

    func openNotchSettings() {
        onOpenNotchSettings?()
    }

    private func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        if !presented {
            selectedPage = .home
            detachPullDistance = 0
        }
        isPresented = presented
        onPresentationChange?(presented)
    }
}

struct GrassMenuView: View {
    @ObservedObject var model: GrassMenuModel
    @ObservedObject var phoneMirror: PhoneMirrorManager
    @ObservedObject var utilities: GrassUtilitiesModel
    let safeAreaTop: CGFloat
    let allowsInput: Bool

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 60), spacing: 12),
        count: 3
    )

    var body: some View {
        Group {
            if model.isPresented {
                if model.selectedPage == .utility {
                    GrassUtilityAppView(
                        app: model.selectedUtility,
                        utilities: utilities,
                        detached: false,
                        onBack: model.returnHome,
                        onDetach: { model.detachUtility(model.selectedUtility) },
                        detachPullDistance: model.detachPullDistance,
                        onDetachPullChanged: model.updateDetachPull
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if model.selectedPage == .phone {
                    PhoneMirrorPanel(manager: phoneMirror, onBack: model.returnHome)
                        .padding(.top, max(4, safeAreaTop + 4))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                            Button(action: model.openNotchSettings) {
                                VStack(spacing: 5) {
                                    NotchSettingsIcon()
                                        .frame(width: 50, height: 50)
                                    Text("Notch Settings")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.88))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open Notch Settings")

                            ForEach(GrassUtilityApp.allCases) { app in
                                UtilityTile(app: app, isDetached: model.detachedUtility == app) {
                                    model.openUtility(app)
                                }
                            }

                            Button(action: model.openPhone) {
                                VStack(spacing: 5) {
                                    PhoneMirrorIcon(connected: phoneMirror.isConnected)
                                        .frame(width: 50, height: 50)
                                    Text("Android Phone")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.88))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open Android Phone")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, max(4, safeAreaTop + 4))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if model.isPresented {
                NotchContourShape(bottomCornerRadius: 22)
                    .fill(Color.black)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isPresented {
                Button(action: model.dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.12), in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close grassMenu")
                .help("Close grassMenu")
                .padding(.top, max(6, safeAreaTop + 4))
                .padding(.trailing, 14)
            }
        }
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .spring(response: 0.36, dampingFraction: 0.9),
            value: model.isPresented
        )
        .onExitCommand { if allowsInput { model.dismiss() } }
    }
}

private struct UtilityTile: View {
    let app: GrassUtilityApp
    let isDetached: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    UtilityAppIcon(app: app)
                        .frame(width: 50, height: 50)
                    if isDetached {
                        Image(systemName: "arrow.up.right.and.arrow.down.left")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.62), in: Circle())
                            .padding(3)
                    }
                }
                .frame(width: 50, height: 50)
                Text(isDetached ? "In island" : app.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(isDetached ? 0.42 : 0.88))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isDetached ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDetached)
        .accessibilityLabel(isDetached ? "\(app.title) already open in detached island" : "Open \(app.title)")
    }
}

private struct UtilityAppIcon: View {
    let app: GrassUtilityApp

    private let cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            switch app {
            case .timer:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.12, green: 0.76, blue: 0.94), Color(red: 0.05, green: 0.39, blue: 0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "alarm.fill")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(.white)

            case .stopwatch:
                stopwatchFace

            case .calculator, .notes:
                if let icon = MacOSUtilityIcons.icon(for: app) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [app.tint, app.tint.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: app.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.8)
        }
        .accessibilityHidden(true)
    }

    private var stopwatchFace: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                Circle()
                    .fill(Color(white: 0.96))
                    .padding(3)

                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(Color(white: index.isMultiple(of: 3) ? 0.23 : 0.64))
                        .frame(width: index.isMultiple(of: 3) ? 1.8 : 1.2,
                               height: index.isMultiple(of: 3) ? 5.5 : 3.2)
                        .offset(y: -side * 0.37)
                        .rotationEffect(.degrees(Double(index) * 30))
                }

                Capsule()
                    .fill(Color.black)
                    .frame(width: 3.4, height: side * 0.31)
                    .offset(x: -side * 0.12, y: -side * 0.095)
                    .rotationEffect(.degrees(-48))
                Capsule()
                    .fill(Color.black)
                    .frame(width: 3.4, height: side * 0.39)
                    .offset(x: side * 0.12, y: -side * 0.12)
                    .rotationEffect(.degrees(48))
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 1.5, height: side * 0.38)
                    .offset(y: side * 0.19)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4, height: 4)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

@MainActor
private enum MacOSUtilityIcons {
    private static let calculator = load(bundleIdentifier: "com.apple.calculator")
    private static let notes = load(bundleIdentifier: "com.apple.Notes")

    static func icon(for app: GrassUtilityApp) -> NSImage? {
        switch app {
        case .calculator: calculator
        case .notes: notes
        case .timer, .stopwatch: nil
        }
    }

    private static func load(bundleIdentifier: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

private struct PhoneMirrorIcon: View {
    let connected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.43), Color(white: 0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: "iphone.gen3")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color(white: 0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}

private struct NotchSettingsIcon: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.48), Color(white: 0.27)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0,
                    bottomLeading: 5,
                    bottomTrailing: 5,
                    topTrailing: 0
                ),
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: 34, height: 21)
            .overlay {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.78))
                    .offset(y: 1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}

@MainActor
final class GrassMenuHostingView: NSHostingView<GrassMenuView> {
    var isGrassMenuActive: @MainActor () -> Bool = { false }
    var onOptionClick: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isGrassMenuActive() else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            onOptionClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
