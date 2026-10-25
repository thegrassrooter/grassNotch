import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Intents
import IOBluetooth
import LocalAuthentication
import SwiftUI
import UserNotifications

enum DeveloperModePresentation: Equatable {
    case closed
    case authenticating
    case message(String)
    case console

    var isDeveloperMessage: Bool {
        if case .message = self { return true }
        return false
    }
}

enum DeveloperLockReason: String {
    case screenLocked
    case userLoggedOut
    case systemSleep
    case applicationTerminated
    case sessionExpired
}

struct DeveloperEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let message: String

    var formatted: String {
        "\(timestamp.formatted(date: .omitted, time: .standard))  [\(category)]  \(message)"
    }
}

@MainActor
final class DeveloperEventLog: ObservableObject {
    static let shared = DeveloperEventLog()
    static let capacity = 200

    @Published private(set) var entries: [DeveloperEvent] = []

    func append(_ category: String, _ message: String) {
        entries.append(DeveloperEvent(timestamp: Date(), category: category, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() { entries.removeAll() }

    var plainText: String {
        entries.map(\.formatted).joined(separator: "\n")
    }
}

@MainActor
final class DeveloperAnimationSettings: ObservableObject {
    static let shared = DeveloperAnimationSettings()
    private let defaults = UserDefaults.standard

    @Published var speed: Double { didSet { persist("speed", speed) } }
    @Published var expansionDuration: Double { didSet { persist("expansionDuration", expansionDuration) } }
    @Published var collapseDuration: Double { didSet { persist("collapseDuration", collapseDuration) } }
    @Published var springResponsiveness: Double { didSet { persist("springResponsiveness", springResponsiveness) } }
    @Published var youtubeAudioAnimationEnabled: Bool {
        didSet { defaults.set(youtubeAudioAnimationEnabled, forKey: Self.youtubeAudioAnimationKey) }
    }
    @Published var previewMaterialEnabled = true

    private static let youtubeAudioAnimationKey = "grassIsland.developer.animation.youtubeAudioAnimationEnabled"

    private init() {
        speed = Self.read("speed", fallback: 1, range: 0.5...2)
        expansionDuration = Self.read("expansionDuration", fallback: 0.29, range: 0.12...0.65)
        collapseDuration = Self.read("collapseDuration", fallback: 0.26, range: 0.12...0.65)
        springResponsiveness = Self.read("springResponsiveness", fallback: 0.55, range: 0...1)
        youtubeAudioAnimationEnabled = UserDefaults.standard.object(forKey: Self.youtubeAudioAnimationKey) as? Bool ?? true
    }

    private static func read(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        let value = UserDefaults.standard.object(forKey: "grassIsland.developer.animation.\(key)") as? Double ?? fallback
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func persist(_ key: String, _ value: Double) {
        defaults.set(value, forKey: "grassIsland.developer.animation.\(key)")
    }

    func reset() {
        speed = 1
        expansionDuration = 0.29
        collapseDuration = 0.26
        springResponsiveness = 0.55
        youtubeAudioAnimationEnabled = true
        previewMaterialEnabled = true
    }

    func reload() {
        speed = Self.read("speed", fallback: 1, range: 0.5...2)
        expansionDuration = Self.read("expansionDuration", fallback: 0.29, range: 0.12...0.65)
        collapseDuration = Self.read("collapseDuration", fallback: 0.26, range: 0.12...0.65)
        springResponsiveness = Self.read("springResponsiveness", fallback: 0.55, range: 0...1)
        youtubeAudioAnimationEnabled = defaults.object(forKey: Self.youtubeAudioAnimationKey) as? Bool ?? true
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var effectiveExpansionDuration: TimeInterval {
        reduceMotion ? 0 : expansionDuration / speed
    }

    var effectiveCollapseDuration: TimeInterval {
        reduceMotion ? 0 : collapseDuration / speed
    }

    var timingFunction: CAMediaTimingFunction {
        if reduceMotion { return CAMediaTimingFunction(name: .linear) }
        let settle = Float(0.18 + 0.32 * springResponsiveness)
        let overshoot = Float(0.72 + 0.22 * springResponsiveness)
        return CAMediaTimingFunction(controlPoints: 0.22, settle, 0.28, overshoot)
    }
}

@MainActor
final class DeveloperModeManager: ObservableObject {
    @Published private(set) var presentation: DeveloperModePresentation = .closed
    @Published private(set) var isAuthenticated = false

    var onPresentationChange: ((DeveloperModePresentation) -> Void)?
    var onConsoleReveal: (() -> Void)?

    private var context: LAContext?
    private var requestID = UUID()
    private var failureTask: Task<Void, Never>?
    private var authenticationTimeoutTask: Task<Void, Never>?

    func handleOptionClick(shiftHeld: Bool) {
        if presentation == .authenticating { return }
        if presentation == .console {
            if shiftHeld {
                closeConsole()
            } else {
                onConsoleReveal?()
            }
            return
        }
        if isAuthenticated {
            setPresentation(.console)
            onConsoleReveal?()
            return
        }
        beginAuthentication()
    }

    func closeConsole() {
        guard presentation == .console else { return }
        DeveloperEventLog.shared.append("Console", "Developer console closed")
        setPresentation(.closed)
    }

    func lockDeveloperMode(reason: DeveloperLockReason) {
        let hadSession = isAuthenticated || presentation != .closed
        requestID = UUID()
        failureTask?.cancel()
        failureTask = nil
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil
        context?.invalidate()
        context = nil
        isAuthenticated = false
        setPresentation(.closed)
        if hadSession {
            DeveloperEventLog.shared.append("Security", "Developer session locked (\(reason.rawValue))")
        }
    }

    private func beginAuthentication() {
        guard presentation != .authenticating else { return }
        failureTask?.cancel()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = nil
        context.interactionNotAllowed = false
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) else {
            showFailure(message(for: evaluationError))
            DeveloperEventLog.shared.append("Security", "Biometric authentication unavailable")
            return
        }

        self.context = context
        let request = UUID()
        requestID = request
        setPresentation(.authenticating)
        // Let AppKit finish activating the accessory app and resizing the notch
        // before LocalAuthentication asks macOS to present its system-owned UI.
        authenticationTimeoutTask = Task { @MainActor [weak self, weak context] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self, self.requestID == request,
                  self.presentation == .authenticating else { return }
            context?.invalidate()
            self.context = nil
            self.authenticationTimeoutTask = nil
            DeveloperEventLog.shared.append("Security", "Biometric authentication timed out")
            self.showFailure("Authentication timed out. Try again.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.requestID == request,
                  self.presentation == .authenticating else { return }
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authenticate to open the Developer Console."
            ) { [weak self] success, error in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == request,
                          self.presentation == .authenticating else { return }
                    self.authenticationTimeoutTask?.cancel()
                    self.authenticationTimeoutTask = nil
                    self.context = nil
                    if success {
                        self.isAuthenticated = true
                        DeveloperEventLog.shared.append("Security", "Biometric authentication succeeded")
                        self.setPresentation(.console)
                    } else {
                        let text = Self.message(for: error)
                        DeveloperEventLog.shared.append("Security", "Biometric authentication failed or was cancelled")
                        self.showFailure(text)
                    }
                }
            }
        }
    }

    private func showFailure(_ message: String) {
        isAuthenticated = false
        setPresentation(.message(message))
        failureTask?.cancel()
        failureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard let self, case .message = self.presentation else { return }
            self.failureTask = nil
            self.setPresentation(.closed)
        }
    }

    private func setPresentation(_ next: DeveloperModePresentation) {
        presentation = next
        onPresentationChange?(next)
    }

    private func message(for error: Error?) -> String {
        Self.message(for: error)
    }

    private static func message(for error: Error?) -> String {
        guard let error = error as? LAError else { return "Touch ID is unavailable on this Mac." }
        switch error.code {
        case .biometryNotAvailable: return "Touch ID is unavailable on this Mac."
        case .biometryNotEnrolled: return "Set up Touch ID in System Settings to continue."
        case .biometryLockout: return "Touch ID is locked. Unlock your Mac, then try again."
        case .passcodeNotSet: return "Set a Mac login passcode before using Touch ID."
        case .authenticationFailed: return "Not recognised"
        case .userCancel, .userFallback, .systemCancel, .appCancel: return "Authentication cancelled. Try again when ready."
        case .notInteractive: return "macOS could not show the authentication prompt. Try again."
        default: return "Authentication could not be completed. Try again."
        }
    }
}

enum DeveloperPreview: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case expanded = "Expanded"
    case music = "Music"
    case notification = "Notification"
    case timer = "Timer"
    case fileTransfer = "File transfer"
    case warning = "Warning"
    case authenticationSuccess = "Auth success"
    case authenticationFailure = "Auth failure"

    var id: String { rawValue }
}

struct DeveloperActivity: Identifiable {
    let id: String
    let name: String
    let kind: String
    let state: String
    let startedAt: Date?
    let visibleInNotch: Bool
    let details: String
    let canTogglePlayback: Bool
    let canDismiss: Bool
}

struct DeveloperPermission: Identifiable {
    let id: String
    let name: String
    let status: String
    let explanation: String
}

struct DeveloperSnapshot {
    let version: String
    let build: String
    let macOS: String
    let architecture: String
    let uptime: TimeInterval
    let memoryBytes: UInt64?
    let activities: [DeveloperActivity]
    let permissions: [DeveloperPermission]

    static var environment: DeveloperSnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Development"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        #if arch(arm64)
        let architecture = "Apple silicon (arm64)"
        #elseif arch(x86_64)
        let architecture = "Intel (x86_64)"
        #else
        let architecture = "Unknown architecture"
        #endif
        return DeveloperSnapshot(
            version: version,
            build: build,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            uptime: ProcessInfo.processInfo.systemUptime,
            memoryBytes: currentMemoryUsage(),
            activities: [],
            permissions: []
        )
    }

    private static func currentMemoryUsage() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

@MainActor
final class DeveloperConsoleModel: ObservableObject {
    @Published var snapshot = DeveloperSnapshot.environment
    @Published var preview: DeveloperPreview = .compact
    @Published var previewExpanded = false
    @Published var showPreviewGuides = false
    @Published var pendingDismiss: DeveloperActivity?
    @Published var showClearLogConfirmation = false

    func resetPreview() {
        preview = .compact
        previewExpanded = false
        showPreviewGuides = false
    }
}

@MainActor
enum DeveloperPermissionReader {
    static func read() async -> [DeveloperPermission] {
        let notificationStatus: String
        if InboxNotifications.hasApplicationBundle {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
            case .denied: notificationStatus = "Denied"
            case .notDetermined: notificationStatus = "Not requested"
            @unknown default: notificationStatus = "Unknown"
            }
        } else {
            notificationStatus = "Requires packaged app"
        }

        let focusStatus: String
        if InboxNotifications.hasApplicationBundle {
            switch INFocusStatusCenter.default.authorizationStatus {
            case .authorized: focusStatus = "Allowed"
            case .denied: focusStatus = "Denied"
            case .notDetermined: focusStatus = "Not requested"
            case .restricted: focusStatus = "Restricted"
            @unknown default: focusStatus = "Unknown"
            }
        } else {
            focusStatus = "Requires packaged app"
        }

        return [
            DeveloperPermission(id: "notifications", name: "Notifications", status: notificationStatus, explanation: "macOS notification delivery for Gmail and WhatsApp alerts."),
            DeveloperPermission(id: "focus", name: "Focus status", status: focusStatus, explanation: "Reads the app-visible Focus availability state; macOS does not expose the active Focus name here."),
            DeveloperPermission(id: "accessibility", name: "Accessibility", status: AXIsProcessTrusted() ? "Allowed" : "Not granted", explanation: "Required only for accessibility integrations used by the app."),
            DeveloperPermission(id: "screen-recording", name: "Screen recording", status: CGPreflightScreenCaptureAccess() ? "Allowed" : "Not granted", explanation: "No screen capture is initiated by Developer Mode."),
            DeveloperPermission(id: "microphone", name: "Microphone", status: AVCaptureDevice.authorizationStatus(for: .audio).developerLabel, explanation: "The current app does not capture microphone audio."),
            DeveloperPermission(id: "automation", name: "Automation", status: "Per-app", explanation: "macOS authorizes Apple Events separately for each target app when the feature uses it."),
            DeveloperPermission(id: "bluetooth", name: "Bluetooth status", status: InboxNotifications.hasApplicationBundle ? (IOBluetoothHostController.default() == nil ? "Unavailable" : "Available") : "Requires packaged app", explanation: "Used to observe Bluetooth power state changes."),
        ]
    }
}

private extension AVAuthorizationStatus {
    var developerLabel: String {
        switch self {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}

@MainActor
struct DeveloperOverlayRoot: View {
    @ObservedObject var manager: DeveloperModeManager
    let snapshotProvider: @MainActor () async -> DeveloperSnapshot
    let playbackAction: @MainActor (Bool) -> Void
    let dismissActivity: @MainActor (String) -> Void
    let openSettings: @MainActor () -> Void
    let returnToDefault: @MainActor () -> Void

    var body: some View {
        Group {
            switch manager.presentation {
            case .authenticating:
                authenticationCard(title: "Developer Mode", subtitle: "Authenticate with Touch ID to continue.", symbol: "touchid", showsProgress: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .message(let message):
                authenticationCard(title: "Developer Mode", subtitle: message, symbol: "touchid", showsProgress: false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .console:
                DeveloperConsoleView(
                    manager: manager,
                    snapshotProvider: snapshotProvider,
                    playbackAction: playbackAction,
                    dismissActivity: dismissActivity,
                    openSettings: openSettings,
                    returnToDefault: returnToDefault
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .closed:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fill the entire panel with black so the auth surface grows out of
        // the physical notch without a grey card, inset seam, or outline.
        .background(Color(red: 0, green: 0, blue: 0, opacity: 1), in: UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: 24,
                bottomTrailing: 24,
                topTrailing: 0
            ),
            style: .continuous
        ))
        // NSHostingView inherits the MacBook display's top safe area. This
        // panel is already positioned at the physical screen edge, so let the
        // developer surface fill that area instead of starting below it.
        .ignoresSafeArea(edges: .top)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.9), value: manager.presentation)
    }

    private func authenticationCard(title: String, subtitle: String, symbol: String, showsProgress: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.green)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsProgress { ProgressView().controlSize(.small).tint(.green) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class DeveloperHostingView: NSHostingView<DeveloperOverlayRoot> {
    var onDeveloperClick: (@MainActor (_ shiftHeld: Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let notchInteractionRegion = NSRect(
            x: bounds.midX - 115,
            y: bounds.maxY - 134,
            width: 230,
            height: 134
        )
        if event.modifierFlags.contains(.option), notchInteractionRegion.contains(point) {
            onDeveloperClick?(event.modifierFlags.contains(.shift))
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
struct DeveloperConsoleView: View {
    @ObservedObject var manager: DeveloperModeManager
    @StateObject private var eventLog = DeveloperEventLog.shared
    @StateObject private var animationSettings = DeveloperAnimationSettings.shared
    @StateObject private var model = DeveloperConsoleModel()

    let snapshotProvider: @MainActor () async -> DeveloperSnapshot
    let playbackAction: @MainActor (Bool) -> Void
    let dismissActivity: @MainActor (String) -> Void
    let openSettings: @MainActor () -> Void
    let returnToDefault: @MainActor () -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    systemOverview
                    activitiesSection
                    previewSection
                    animationSection
                    permissionsSection
                    eventLogSection
                    actionsSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black.opacity(0.01))
        .task {
            while !Task.isCancelled {
                model.snapshot = await snapshotProvider()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .confirmationDialog("Dismiss this live activity?", isPresented: Binding(
            get: { model.pendingDismiss != nil },
            set: { if !$0 { model.pendingDismiss = nil } }
        ), titleVisibility: .visible) {
            Button("Dismiss Activity", role: .destructive) {
                if let pendingDismiss = model.pendingDismiss { dismissActivity(pendingDismiss.id) }
                model.pendingDismiss = nil
            }
            Button("Cancel", role: .cancel) { model.pendingDismiss = nil }
        } message: {
            Text("This affects the live activity. Opening the console never changes it.")
        }
        .confirmationDialog("Clear the in-memory event log?", isPresented: $model.showClearLogConfirmation, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) { eventLog.clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone. The log contains only events observed during this app launch.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer Console").font(.system(size: 14, weight: .semibold))
                Text("grassNotch · authenticated session")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { manager.closeConsole() }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.08), in: Circle())
            .help("Close console (Option–Shift–click the notch)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.035))
    }

    private var systemOverview: some View {
        section("SYSTEM", symbol: "desktopcomputer") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                metric("grassNotch", "v\(model.snapshot.version) · build \(model.snapshot.build)")
                metric("macOS", model.snapshot.macOS)
                metric("Architecture", model.snapshot.architecture)
                metric("Uptime", formattedUptime(model.snapshot.uptime))
                metric("Memory footprint", formattedBytes(model.snapshot.memoryBytes))
                metric("Session", manager.isAuthenticated ? "Authenticated · this launch" : "Locked")
            }
        }
    }

    private var activitiesSection: some View {
        section("LIVE ACTIVITIES", symbol: "waveform.path") {
            if model.snapshot.activities.isEmpty {
                Text("No active grassNotch activities.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 7) {
                    ForEach(model.snapshot.activities) { activity in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: activity.kind == "Media" ? "play.rectangle" : "circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(activity.visibleInNotch ? .green : .secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(activity.name).font(.system(size: 11, weight: .semibold))
                                    Text(activity.kind.uppercased()).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Text(activity.visibleInNotch ? "VISIBLE" : "RUNNING")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(activity.visibleInNotch ? .green : .secondary)
                                }
                                Text("\(activity.state) · \(activity.details)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(activity.startedAt.map { "Started \($0.formatted(date: .omitted, time: .shortened))" } ?? "Start time not tracked")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            if activity.canTogglePlayback {
                                Button(activity.state == "Playing" ? "Pause" : "Resume") {
                                    playbackAction(activity.state == "Paused")
                                }.buttonStyle(.bordered).controlSize(.mini)
                            }
                            if activity.canDismiss {
                                Button("Dismiss", role: .destructive) { model.pendingDismiss = activity }
                                    .buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                        .padding(9)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        section("PREVIEW LAB · SIMULATED ONLY", symbol: "rectangle.on.rectangle") {
            PreviewCanvas(preview: model.preview, expanded: model.previewExpanded, showGuides: model.showPreviewGuides, effectsEnabled: animationSettings.previewMaterialEnabled)
                .frame(height: model.previewExpanded ? 116 : 78)
                .animation(animationSettings.reduceMotion ? nil : .spring(response: animationSettings.effectiveExpansionDuration, dampingFraction: 0.88 - 0.22 * animationSettings.springResponsiveness), value: model.previewExpanded)
                .animation(animationSettings.reduceMotion ? nil : .easeInOut(duration: animationSettings.effectiveExpansionDuration), value: model.preview)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(DeveloperPreview.allCases) { value in
                    Button(value.rawValue) { model.preview = value }
                        .buttonStyle(PreviewChoiceStyle(selected: model.preview == value))
                }
            }
            HStack(spacing: 7) {
                Button("Expand") { model.previewExpanded = true }.buttonStyle(.bordered).controlSize(.small)
                Button("Collapse") { model.previewExpanded = false }.buttonStyle(.bordered).controlSize(.small)
                Button("Cycle") { cyclePreview() }.buttonStyle(.bordered).controlSize(.small)
                Button("Reset") { model.resetPreview() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Toggle("Experimental: notch guides in sandbox", isOn: $model.showPreviewGuides)
                .font(.system(size: 10))
                .tint(.green)
            Text("Previews are isolated from live activities, system events, and notifications. Auth success is a visual mock only.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var animationSection: some View {
        section("ANIMATION", symbol: "sparkles") {
            VStack(spacing: 9) {
                settingSlider("Speed", value: $animationSettings.speed, range: 0.5...2, format: "%.1f×")
                settingSlider("Expand", value: $animationSettings.expansionDuration, range: 0.12...0.65, format: "%.2fs")
                settingSlider("Collapse", value: $animationSettings.collapseDuration, range: 0.12...0.65, format: "%.2fs")
                settingSlider("Bounce", value: $animationSettings.springResponsiveness, range: 0...1, format: "%.2f")
                Text("Subtle overshoot applies to every notch expand and collapse.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Toggle("Orange YouTube playback bars", isOn: $animationSettings.youtubeAudioAnimationEnabled)
                    .font(.system(size: 10)).tint(.green)
                Text("Turn off only the moving orange bars. Video playback, the YouTube logo, and its controls are unaffected.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Toggle("Preview material effects", isOn: $animationSettings.previewMaterialEnabled)
                    .font(.system(size: 10)).tint(.green)
                HStack {
                    Text(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "Reduce Motion is on; app transitions are immediate." : "Reduce Motion is off.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore defaults") { animationSettings.reset() }.buttonStyle(.borderless)
                }
            }
        }
    }

    private var permissionsSection: some View {
        section("PERMISSIONS & CAPABILITIES", symbol: "checkmark.shield") {
            VStack(spacing: 5) {
            ForEach(model.snapshot.permissions) { permission in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(permission.status == "Allowed" || permission.status == "Available" ? .green : .orange)
                            .frame(width: 6, height: 6).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(permission.name).font(.system(size: 10, weight: .medium))
                                Spacer()
                                Text(permission.status.uppercased()).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Text(permission.explanation).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Button("Open System Settings") { openSettings() }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("Refresh") { Task { model.snapshot = await snapshotProvider() } }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var eventLogSection: some View {
        section("RECENT APP EVENTS · \(eventLog.entries.count)/\(DeveloperEventLog.capacity)", symbol: "text.alignleft") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if eventLog.entries.isEmpty {
                        Text("No observed events yet.").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        ForEach(eventLog.entries.reversed()) { event in
                            Text(event.formatted)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(event.category == "Security" ? .green : Color.primary.opacity(0.82))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 120)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(eventLog.plainText, forType: .string)
                }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("Clear Log", role: .destructive) { model.showClearLogConfirmation = true }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var actionsSection: some View {
        section("SAFE ACTIONS", symbol: "wrench.and.screwdriver") {
            LazyVGrid(columns: columns, spacing: 7) {
                Button("Reload visual configuration") { animationSettings.reload() }
                Button("Reset animation preferences") { animationSettings.reset() }
                Button("Reset preview state") { model.resetPreview() }
                Button("Export diagnostic report") { exportReport() }
                Button("Copy environment info") { copyEnvironment() }
                Button("Default notch state") { returnToDefault() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.green.opacity(0.9))
            content()
        }
        .padding(10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10)).frame(width: 82, alignment: .leading)
            Slider(value: value, in: range).tint(.green)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }

    private func cyclePreview() {
        let all = DeveloperPreview.allCases
        guard let index = all.firstIndex(of: model.preview) else { return }
        model.preview = all[(index + 1) % all.count]
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "grassNotch-diagnostic.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = """
        grassNotch Developer Diagnostic
        Version: \(model.snapshot.version) (\(model.snapshot.build))
        System: \(model.snapshot.macOS)
        Architecture: \(model.snapshot.architecture)
        Uptime: \(formattedUptime(model.snapshot.uptime))
        Memory: \(formattedBytes(model.snapshot.memoryBytes))
        Developer session: authenticated in current process only
        Activities: \(model.snapshot.activities.map { "\($0.name) / \($0.kind) / \($0.state)" }.joined(separator: ", "))
        Permissions: \(model.snapshot.permissions.map { "\($0.name)=\($0.status)" }.joined(separator: ", "))

        Observed events:
        \(eventLog.plainText)
        """
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyEnvironment() {
        let text = "grassNotch v\(model.snapshot.version) build \(model.snapshot.build) · \(model.snapshot.macOS) · \(model.snapshot.architecture) · memory \(formattedBytes(model.snapshot.memoryBytes))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formattedUptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(total % 60)s"
    }

    private func formattedBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private struct PreviewChoiceStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: selected ? .semibold : .regular))
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.vertical, 6).frame(maxWidth: .infinity)
            .background(selected ? .green.opacity(0.17) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? .green.opacity(0.4) : .clear))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct PreviewCanvas: View {
    let preview: DeveloperPreview
    let expanded: Bool
    let showGuides: Bool
    let effectsEnabled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: expanded ? 20 : 16, style: .continuous)
                .fill(effectsEnabled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.black))
                .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 16).fill(.black.opacity(0.82)))
                .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 16).strokeBorder(.white.opacity(0.08)))
            previewContent
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
            if showGuides {
                HStack {
                    Rectangle().fill(.green.opacity(0.65)).frame(width: 1)
                    Spacer()
                    Rectangle().fill(.green.opacity(0.65)).frame(width: 1)
                }
                .padding(.horizontal, 28)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("SIMULATED")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(7)
        }
    }

    @ViewBuilder private var previewContent: some View {
        switch preview {
        case .compact:
            HStack(spacing: 7) { Circle().fill(.green).frame(width: 5, height: 5); Text("Compact notch").font(.system(size: 11, weight: .medium)) }
        case .expanded:
            HStack { Text("9:41"); Spacer(); Image(systemName: "battery.100percent") }.font(.system(size: 11, weight: .medium, design: .monospaced))
        case .music:
            HStack(spacing: 10) {
                Image(systemName: "music.note").font(.system(size: 16)).frame(width: 30, height: 30).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sample audio · Preview").font(.system(size: 10, weight: .semibold))
                    ProgressView(value: 0.38).tint(.green)
                }
                Image(systemName: "backward.fill"); Image(systemName: "pause.fill"); Image(systemName: "forward.fill")
            }.font(.system(size: 10))
        case .notification:
            HStack(spacing: 9) {
                Image(systemName: "message.fill").foregroundStyle(.green).font(.system(size: 17))
                VStack(alignment: .leading, spacing: 3) { Text("Notification preview").font(.system(size: 11, weight: .semibold)); Text("Sample content · no real message").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
            }
        case .timer:
            HStack(spacing: 10) { Image(systemName: "timer").foregroundStyle(.green); Text("00:24").font(.system(size: 19, weight: .medium, design: .rounded)); Text("Preview timer").font(.system(size: 9)).foregroundStyle(.secondary) }
        case .fileTransfer:
            HStack(spacing: 9) { Image(systemName: "doc.fill").foregroundStyle(.green); VStack(alignment: .leading) { Text("preview.txt").font(.system(size: 10, weight: .semibold)); Text("Simulated file transfer").font(.system(size: 9)).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.down.doc") }
        case .warning:
            HStack(spacing: 9) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("Preview warning state").font(.system(size: 10, weight: .semibold)); Spacer() }
        case .authenticationSuccess:
            HStack(spacing: 9) { Image(systemName: "checkmark.shield.fill").foregroundStyle(.green); VStack(alignment: .leading) { Text("Authentication success mock").font(.system(size: 10, weight: .semibold)); Text("No authentication occurred").font(.system(size: 9)).foregroundStyle(.secondary) }; Spacer() }
        case .authenticationFailure:
            HStack(spacing: 9) { Image(systemName: "touchid").foregroundStyle(.orange); VStack(alignment: .leading) { Text("Not recognised").font(.system(size: 10, weight: .semibold)); Text("Simulated failure preview").font(.system(size: 9)).foregroundStyle(.secondary) }; Spacer() }
        }
    }
}

