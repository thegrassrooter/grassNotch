import AppKit
import QuartzCore
import SwiftUI
import UserNotifications

enum GrassUtilityApp: String, CaseIterable, Identifiable {
    case calculator, timer, stopwatch, notes

    var id: String { rawValue }
    var title: String {
        switch self {
        case .calculator: "Calculator"
        case .timer: "Timer"
        case .stopwatch: "Stopwatch"
        case .notes: "Notes"
        }
    }
    var symbol: String {
        switch self {
        case .calculator: "calculator"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .notes: "note.text"
        }
    }
    var tint: Color {
        switch self {
        case .calculator: Color(red: 1, green: 0.59, blue: 0.18)
        case .timer: Color(red: 1, green: 0.31, blue: 0.28)
        case .stopwatch: Color(red: 0.28, green: 0.78, blue: 0.53)
        case .notes: Color(red: 1, green: 0.82, blue: 0.31)
        }
    }
}
/// The two utility apps whose running state can live beside the notch.
enum GrassLiveActivity: String, CaseIterable, Hashable {
    case timer
    case stopwatch

    var utility: GrassUtilityApp {
        switch self {
        case .timer: .timer
        case .stopwatch: .stopwatch
        }
    }
}

private enum TimerCompletionNotifier {
    static func post() {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == "com.grassisland.app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Timer Complete"
            content.body = "Your grassNotch timer has finished."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "grassNotch.timer.\(UUID().uuidString)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("grassNotch: timer notification failed: %@", error.localizedDescription) }
            }
        }
    }
}

@MainActor
final class CalculatorModel: ObservableObject {
    @Published private(set) var display = "0"
    @Published private(set) var expression = ""
    @Published private(set) var recentCalculation = ""
    private var storedValue: Double?
    private var pendingOperator: String?
    private var startsNewNumber = true

    func input(_ key: String) {
        if key.count == 1, let digit = key.first, digit.isNumber {
            guard display.count < 14 || startsNewNumber else { return }
            if startsNewNumber || display == "0" || display == "Error" {
                display = String(digit)
                startsNewNumber = false
            } else { display.append(digit) }
            expression = storedValue.map { format($0) + " " + (pendingOperator ?? "") } ?? ""
            return
        }
        switch key {
        case ".":
            if startsNewNumber || display == "Error" { display = "0"; startsNewNumber = false }
            if !display.contains(".") { display.append(".") }
        case "AC": clear()
        case "⌫":
            guard !startsNewNumber, display != "Error" else { return }
            display.removeLast()
            if display.isEmpty || display == "-" { display = "0"; startsNewNumber = true }
        case "±":
            guard display != "Error" else { return }
            display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display
        case "%":
            guard let value = Double(display) else { return }
            if let storedValue, (pendingOperator == "+" || pendingOperator == "−") {
                display = format(storedValue * value / 100)
            } else {
                display = format(value / 100)
            }
        case "+", "−", "×", "÷":
            guard let value = Double(display) else { return }
            if let storedValue, let pendingOperator, !startsNewNumber {
                guard let result = calculate(storedValue, value, pendingOperator) else { display = "Error"; clearPending(); return }
                self.storedValue = result
                display = format(result)
            } else { storedValue = value }
            pendingOperator = key
            expression = format(storedValue ?? value) + " " + key
            startsNewNumber = true
        case "=":
            guard let left = storedValue, let right = Double(display), let op = pendingOperator else { return }
            guard let result = calculate(left, right, op) else { display = "Error"; recentCalculation = expression + " " + display; clearPending(); return }
            let equation = "\(format(left)) \(op) \(format(right)) = \(format(result))"
            recentCalculation = equation
            expression = equation
            display = format(result)
            clearPending()
            startsNewNumber = true
        default: break
        }
    }

    func clear() {
        display = "0"; expression = ""; storedValue = nil; pendingOperator = nil; startsNewNumber = true
    }
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let characters = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 51 || event.keyCode == 117 { input("⌫"); return true }
        if event.keyCode == 36 || event.keyCode == 76 { input("="); return true }
        guard characters.count == 1, let character = characters.first else { return false }
        if character.isNumber { input(String(character)); return true }
        switch character {
        case ".": input(".")
        case "+": input("+")
        case "-": input("−")
        case "*", "x", "X": input("×")
        case "/": input("÷")
        case "%": input("%")
        case "=": input("=")
        default: return false
        }
        return true
    }
    private func clearPending() { storedValue = nil; pendingOperator = nil }
    private func calculate(_ lhs: Double, _ rhs: Double, _ op: String) -> Double? {
        switch op {
        case "+": lhs + rhs
        case "−": lhs - rhs
        case "×": lhs * rhs
        case "÷": rhs == 0 ? nil : lhs / rhs
        default: nil
        }
    }
    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "Error" }
        if abs(value) < 1e14, value.rounded() == value { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }
}

@MainActor
final class CountdownTimerModel: ObservableObject {
    @Published var hours = "0"
    @Published var minutes = "5"
    @Published var seconds = "0"
    @Published private(set) var remaining: TimeInterval = 300
    @Published private(set) var isRunning = false {
        didSet { if oldValue != isRunning { onActivityStateChange?(isRunning) } }
    }
    @Published private(set) var didFinish = false
    private var deadline: Date?
    private var ticker: Timer?
    var onActivityStateChange: ((Bool) -> Void)?
    var onCompletion: (() -> Void)?

    var display: String {
        let total = max(0, Int(ceil(remaining)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
    var canStart: Bool { inputDuration > 0 }

    init() {}
    func startOrResume() {
        guard !isRunning else { pause(); return }
        if remaining <= 0 { remaining = inputDuration }
        guard remaining > 0 else { return }
        didFinish = false; deadline = Date().addingTimeInterval(remaining); isRunning = true
        startTicker()
        tick()
    }
    func pause() {
        tick(); isRunning = false; deadline = nil; ticker?.invalidate(); ticker = nil
    }
    func reset() {
        isRunning = false; deadline = nil; didFinish = false; remaining = inputDuration
        ticker?.invalidate(); ticker = nil
    }
    func updateInput() {
        guard !isRunning else { return }
        remaining = inputDuration; didFinish = false
    }
    private var inputDuration: TimeInterval {
        let h = max(0, Int(hours) ?? 0), m = max(0, Int(minutes) ?? 0), s = max(0, Int(seconds) ?? 0)
        return TimeInterval(min(99 * 3600 + 3599, h * 3600 + m * 60 + s))
    }
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }
    private func tick() {
        guard isRunning, let deadline else { return }
        remaining = max(0, deadline.timeIntervalSinceNow)
        if remaining <= 0 {
            isRunning = false; self.deadline = nil; didFinish = true
            ticker?.invalidate(); ticker = nil
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            TimerCompletionNotifier.post()
            onCompletion?()
        }
    }
}

@MainActor
final class StopwatchModel: ObservableObject {
    @Published private(set) var isRunning = false {
        didSet { if oldValue != isRunning { onActivityStateChange?(isRunning) } }
    }
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var now = Date()
    @Published private(set) var laps: [TimeInterval] = []
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    var onActivityStateChange: ((Bool) -> Void)?

    init() {}
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }
    func toggle() {
        if isRunning {
            accumulated = currentElapsed; isRunning = false; startedAt = nil
            ticker?.invalidate(); ticker = nil
        } else {
            startedAt = Date(); isRunning = true
            startTicker()
        }
        refresh()
    }
    func reset() { isRunning = false; startedAt = nil; accumulated = 0; elapsed = 0; laps = []; now = Date(); ticker?.invalidate(); ticker = nil }
    func lap() { guard isRunning else { return }; laps.insert(currentElapsed, at: 0) }
    private var currentElapsed: TimeInterval { accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    private func refresh() { now = Date(); elapsed = currentElapsed }
    var timeText: String {
        let ms = Int((elapsed * 1000).rounded(.down))
        return String(format: "%02d:%02d.%03d", ms / 60_000, (ms / 1000) % 60, ms % 1000)
    }
}

struct GrassNote: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var modifiedAt: Date
    var preview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No additional text" : trimmed
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [GrassNote] = []
    @Published var selectedID: UUID?
    @Published var draftTitle = ""
    @Published var draftContent = ""
    @Published private(set) var saveError: String?
    private let directory: URL
    private var saveWork: [UUID: DispatchWorkItem] = [:]
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init(fileManager: FileManager = .default, storageRoot: URL? = nil) {
        // userDomainMask resolves inside the current macOS account's home folder.
        let base = storageRoot ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        directory = base.appendingPathComponent("grassNotch/Notes", isDirectory: true)
        load()
    }
    var selectedNote: GrassNote? { notes.first(where: { $0.id == selectedID }) }
    func flushPendingSaves() {
        saveWork.values.forEach { $0.cancel() }
        saveWork.removeAll()
        notes.forEach { persist($0) }
    }
    @discardableResult func createNote() -> UUID {
        let now = Date(), note = GrassNote(id: UUID(), title: "New Note", content: "", createdAt: now, modifiedAt: now)
        notes.insert(note, at: 0); selectedID = note.id
        draftTitle = note.title; draftContent = note.content
        persist(note)
        return note.id
    }
    func select(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        selectedID = id; draftTitle = note.title; draftContent = note.content
    }
    func update(_ id: UUID, title: String? = nil, content: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if let title { notes[index].title = title }
        if let content { notes[index].content = content }
        notes[index].modifiedAt = Date()
        scheduleSave(notes[index])
    }
    func delete(_ id: UUID) {
        saveWork[id]?.cancel()
        saveWork[id] = nil
        guard let url = fileURL(id) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            notes.removeAll { $0.id == id }
            if selectedID == id {
                selectedID = notes.first?.id
                draftTitle = notes.first?.title ?? ""
                draftContent = notes.first?.content ?? ""
            }
            saveError = nil
        } catch { saveError = "Could not delete this note. \(error.localizedDescription)" }
    }
    private func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            var loaded: [GrassNote] = []
            for url in urls {
                do { loaded.append(try decoder.decode(GrassNote.self, from: Data(contentsOf: url))) }
                catch { NSLog("grassNotch: skipped unreadable note file %@", url.lastPathComponent) }
            }
            notes = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
            selectedID = notes.first?.id
            draftTitle = notes.first?.title ?? ""
            draftContent = notes.first?.content ?? ""
        } catch { saveError = "Could not open notes storage. \(error.localizedDescription)" }
    }
    private func scheduleSave(_ note: GrassNote) {
        saveWork[note.id]?.cancel()
        let noteID = note.id
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let latest = self.notes.first(where: { $0.id == noteID }) else { return }
                self.persist(latest)
            }
        }
        saveWork[note.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func persist(_ note: GrassNote) {
        guard let url = fileURL(note.id) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(note).write(to: url, options: .atomic)
            saveError = nil
        } catch { saveError = "Changes are still in memory but could not be saved. \(error.localizedDescription)" }
    }
    private func fileURL(_ id: UUID) -> URL? { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}

@MainActor
final class GrassUtilitiesModel: ObservableObject {
    let calculator = CalculatorModel()
    let timer = CountdownTimerModel()
    let stopwatch = StopwatchModel()
    let notes = NotesStore()
    @Published private(set) var activeActivities: [GrassLiveActivity] = []
    var onLiveActivitiesChange: (() -> Void)?
    private var activityStartOrder: [GrassLiveActivity: UInt64] = [:]
    private var nextActivityOrder: UInt64 = 0

    init() {
        timer.onActivityStateChange = { [weak self] running in self?.setActivity(.timer, running: running) }
        stopwatch.onActivityStateChange = { [weak self] running in self?.setActivity(.stopwatch, running: running) }
    }

    private func setActivity(_ activity: GrassLiveActivity, running: Bool) {
        if running {
            if activityStartOrder[activity] == nil {
                nextActivityOrder &+= 1
                activityStartOrder[activity] = nextActivityOrder
            }
        } else {
            activityStartOrder.removeValue(forKey: activity)
        }
        activeActivities = activityStartOrder.sorted { $0.value < $1.value }.map(\.key)
        onLiveActivitiesChange?()
    }

    func flushPendingSaves() { notes.flushPendingSaves() }
}

struct GrassUtilityAppView: View {
    let app: GrassUtilityApp
    @ObservedObject var utilities: GrassUtilitiesModel
    let detached: Bool
    var showsHeader = true
    let onBack: () -> Void
    let onDetach: (() -> Void)?
    var detachPullDistance: CGFloat = 0
    var onDetachPullChanged: ((CGFloat) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            if showsHeader { appHeader }

            Group {
                switch app {
                case .calculator: CalculatorUtilityView(model: utilities.calculator)
                case .timer: TimerUtilityView(model: utilities.timer)
                case .stopwatch: StopwatchUtilityView(model: utilities.stopwatch)
                case .notes: NotesUtilityView(store: utilities.notes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !detached, onDetach != nil { detachHandle }
        }
        .padding(.bottom, 10)
        .background {
            if !detached {
                NotchContourShape(bottomCornerRadius: 22).fill(Color.black)
            }
        }
        .foregroundStyle(.white)
    }

    private var detachHandle: some View {
        VStack(spacing: 4) {
            Capsule().fill(.white.opacity(0.34)).frame(width: 34, height: 3)
                .overlay(alignment: .center) {
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .frame(width: 2, height: min(14, detachPullDistance * 0.16))
                        .offset(y: 7 + min(14, detachPullDistance * 0.16) / 2)
                        .allowsHitTesting(false)
                }
            Text("Drag down to detach")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    onDetachPullChanged?(value.translation.height)
                }
                .onEnded { value in
                    let shouldDetach = value.translation.height > 38
                    onDetachPullChanged?(0)
                    if shouldDetach { onDetach?() }
                }
        )
        .accessibilityLabel("Drag down to detach this app")
    }

    private var appHeader: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 25, height: 25)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to grassMenu")
            VStack(alignment: .leading, spacing: 1) {
                Text(app.title).font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 6)
        }
        .foregroundStyle(.white.opacity(0.93))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .contentShape(Rectangle())
    }
}

private struct CalculatorUtilityView: View {
    @ObservedObject var model: CalculatorModel
    private let rows = [["AC", "±", "%", "÷"], ["7", "8", "9", "×"], ["4", "5", "6", "−"], ["1", "2", "3", "+"]]
    var body: some View {
        VStack(spacing: 7) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.expression.isEmpty ? model.recentCalculation : model.expression)
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                Text(model.display).font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 14).padding(.top, 2)
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 7) { ForEach(row, id: \.self) { key in calcButton(key) } }
            }
            HStack(spacing: 7) {
                calcButton("0").frame(maxWidth: .infinity)
                calcButton(".").frame(maxWidth: .infinity)
                calcButton("⌫").frame(maxWidth: .infinity)
                calcButton("=").frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .onKeyPress { press in
            let characters = press.characters
            if characters.count == 1, characters.first?.isNumber == true { model.input(characters); return .handled }
            switch characters {
            case ".": model.input(".")
            case "+": model.input("+")
            case "-", "−": model.input("−")
            case "*", "x", "X": model.input("×")
            case "/": model.input("÷")
            case "%": model.input("%")
            case "=", "\r", "\n": model.input("=")
            case "\u{08}", "\u{7f}": model.input("⌫")
            default: return .ignored
            }
            return .handled
        }
    }
    private func calcButton(_ key: String) -> some View {
        Button { model.input(key) } label: {
            Text(key).font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(key == "=" || ["+", "−", "×", "÷"].contains(key) ? .white : .white.opacity(0.92))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(key == "=" ? Color.orange : (["+", "−", "×", "÷"].contains(key) ? Color.orange.opacity(0.82) : Color(white: 0.20)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel(key == "⌫" ? "Delete" : key)
    }
}

private struct TimerUtilityView: View {
    @ObservedObject var model: CountdownTimerModel
    var body: some View {
        VStack(spacing: 10) {
            Text(model.display).font(.system(size: 38, weight: .ultraLight, design: .rounded)).monospacedDigit().foregroundStyle(model.didFinish ? .orange : .white)
            if !model.isRunning {
                HStack(spacing: 10) {
                    timeInput("Hours", text: $model.hours)
                    timeInput("Minutes", text: $model.minutes)
                    timeInput("Seconds", text: $model.seconds)
                }.onChange(of: model.hours) { model.updateInput() }.onChange(of: model.minutes) { model.updateInput() }.onChange(of: model.seconds) { model.updateInput() }
            }
            HStack(spacing: 10) {
                Button(model.isRunning ? "Pause" : (model.remaining == 0 ? "Start Again" : "Start")) { model.startOrResume() }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(!model.isRunning && !model.canStart)
                Button("Reset") { model.reset() }.buttonStyle(.bordered).disabled(model.remaining == 0 && !model.didFinish)
            }
            if model.didFinish { Text("Time is up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange) }
        }.padding(.horizontal, 14).padding(.bottom, 8)
    }
    private func timeInput(_ title: String, text: Binding<String>) -> some View {
        VStack(spacing: 3) {
            TextField("0", text: text).textFieldStyle(.plain).font(.system(size: 15, weight: .medium, design: .rounded)).multilineTextAlignment(.center).frame(width: 56).padding(.vertical, 6).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                .onChange(of: text.wrappedValue) { _, value in text.wrappedValue = String(value.filter(\.isNumber).prefix(2)) }
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.52))
        }
    }
}

private struct StopwatchUtilityView: View {
    @ObservedObject var model: StopwatchModel
    var body: some View {
        VStack(spacing: 8) {
        Text(model.timeText).font(.system(size: 39, weight: .ultraLight, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7)
            HStack(spacing: 10) {
                Button(model.isRunning ? "Stop" : (model.elapsed > 0 ? "Resume" : "Start")) { model.toggle() }.buttonStyle(.borderedProminent).tint(model.isRunning ? .red : .green)
                Button(model.isRunning ? "Lap" : "Reset") { model.isRunning ? model.lap() : model.reset() }.buttonStyle(.bordered).disabled(!model.isRunning && model.elapsed == 0)
            }
            if !model.laps.isEmpty {
                ScrollView { VStack(spacing: 4) { ForEach(Array(model.laps.enumerated()), id: \.offset) { index, lap in HStack { Text("Lap \(model.laps.count - index)"); Spacer(); Text(Self.format(lap)).monospacedDigit() }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.74)) } } }
                    .frame(maxHeight: 48).padding(.horizontal, 14)
            }
        }.padding(.bottom, 8)
    }
    private static func format(_ value: TimeInterval) -> String {
        let ms = Int(value * 1000)
        return String(format: "%02d:%02d.%03d", ms / 60_000, (ms / 1000) % 60, ms % 1000)
    }
}

private struct NotesUtilityView: View {
    @ObservedObject var store: NotesStore
    @FocusState private var focusedField: NotesField?

    private enum NotesField: Hashable {
        case title
        case content
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Text("Notes").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button(action: createNoteAndFocus) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.yellow)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New note")
                }.padding(.horizontal, 9).padding(.top, 4)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(store.notes) { note in
                            Button {
                                store.select(note.id)
                                focusNoteContent()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title.isEmpty ? "New Note" : note.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                    Text(note.preview).font(.system(size: 9)).foregroundStyle(.white.opacity(0.52)).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6).background(store.selectedID == note.id ? .white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 5)
                }
            }.frame(width: 122).background(Color(white: 0.09))
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            VStack(alignment: .leading, spacing: 4) {
                if let note = store.selectedNote {
                    TextField("Title", text: $store.draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .focused($focusedField, equals: .title)
                        .onChange(of: store.draftTitle) { _, value in store.update(note.id, title: value) }
                    Text("Edited \(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 8)).foregroundStyle(.white.opacity(0.42))
                    TextEditor(text: $store.draftContent)
                        .font(.system(size: 11))
                        .tint(.white)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white.opacity(0.9))
                        .focused($focusedField, equals: .content)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                        .onChange(of: store.draftContent) { _, value in store.update(note.id, content: value) }
                    HStack {
                        if let error = store.saveError { Text(error).font(.system(size: 8)).foregroundStyle(.red).lineLimit(2) }
                        Spacer()
                        Button(role: .destructive) { store.delete(note.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("Delete note")
                    }
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "note.text").font(.system(size: 24)).foregroundStyle(.yellow.opacity(0.8))
                        Text("No Notes").font(.system(size: 12, weight: .medium))
                        Button("Create a Note", action: createNoteAndFocus)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(9).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        // The notch window has a 10 pt drawing bleed. Keep the Notes sidebar
        // and editor inside the visible contour instead of painting outside it.
        .padding(.horizontal, NotchView.upperCornerBleed * 2)
        .clipShape(NotchContourShape(bottomCornerRadius: 22))
        .onAppear {
            if store.selectedNote != nil { focusNoteContent() }
        }
    }

    private func createNoteAndFocus() {
        store.createNote()
        focusNoteContent()
    }

    private func focusNoteContent() {
        DispatchQueue.main.async {
            focusedField = .content
        }
    }
}

struct DetachedUtilityIslandView: View {
    let app: GrassUtilityApp
    @ObservedObject var utilities: GrassUtilitiesModel
    var isAbsorbing = false
    var isFading = false
    let onClose: () -> Void
    let onReattach: () -> Void
    var body: some View {
        let cornerRadius: CGFloat = isAbsorbing ? 15 : 34
        VStack(spacing: 0) {
            header
            utilityContent
        }
        .frame(width: 340, height: 350)
        .background(.black, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: app.tint.opacity(isAbsorbing ? 0.06 : 0.18),
            radius: isAbsorbing ? 8 : 24,
            y: isAbsorbing ? 1 : 8
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Compress the rounded island into the physical notch's short,
        // horizontal silhouette. The tighter corner radius and settling spring
        // make the panel feel like it is being drawn into the notch, while its
        // black surface stays solid until it arrives.
        .scaleEffect(x: isAbsorbing ? 0.56 : 1, y: isAbsorbing ? 0.10 : 1, anchor: .center)
        .opacity(isFading ? 0 : 1)
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? .easeOut(duration: 0.16)
                : .spring(response: 0.84, dampingFraction: 0.88, blendDuration: 0.08),
            value: isAbsorbing
        )
        .animation(.easeInOut(duration: 0.18), value: isFading)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.title).font(.system(size: 11, weight: .semibold))
                Capsule().fill(app.tint.opacity(0.85)).frame(width: 28, height: 3)
            }
            Spacer()
            Button(action: onReattach) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22)
            }.buttonStyle(.plain).help("Reattach to notch")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 22)
                    .background(.white.opacity(0.13), in: Circle())
            }.buttonStyle(.plain).help("Close island")
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 11).padding(.top, 8).padding(.bottom, 3)
    }

    private var utilityContent: some View {
        GrassUtilityAppView(app: app, utilities: utilities, detached: true, showsHeader: false, onBack: onReattach, onDetach: nil)
            .padding(.top, 2)
    }

}


@MainActor
final class DetachableIslandController {
    private let utilities: GrassUtilitiesModel
    private weak var anchorWindow: NSWindow?
    private var islandWindow: NSPanel?
    private var selectedApp: GrassUtilityApp?
    private var activeScreen: NSScreen?
    private var isTransitioning = false
    private var detachTransitionID: UUID?
    private var detachTransitionStartedAt: TimeInterval?
    private var detachTargetFrame: NSRect?
    private var closeTransitionID: UUID?
    private var closeTransitionStartedAt: TimeInterval?
    private var closeTransitionReattaches = false
    var onDismiss: ((GrassUtilityApp) -> Void)?
    var onReattach: ((GrassUtilityApp) -> Void)?

    init(utilities: GrassUtilitiesModel, anchorWindow: NSWindow) {
        self.utilities = utilities
        self.anchorWindow = anchorWindow
    }

    @discardableResult
    func detach(_ app: GrassUtilityApp) -> Bool {
        recoverInterruptedDetachmentIfNeeded()
        guard islandWindow == nil, !isTransitioning, let anchorWindow else { return false }
        isTransitioning = true
        selectedApp = app
        activeScreen = NSScreen.screens.first(where: { $0.frame.intersects(anchorWindow.frame) }) ?? NSScreen.main
        guard let screen = activeScreen else { selectedApp = nil; isTransitioning = false; return false }

        let size = NSSize(width: 340, height: 350)
        // Anchor the island to the physical notch, not to the bottom of the
        // expanded utility panel. Using anchorWindow.minY here pushed the
        // detached app hundreds of points down the screen.
        let notchBottom = screen.frame.maxY - max(34, screen.safeAreaInsets.top)
        let gap: CGFloat = 12
        let origin = NSPoint(x: anchorWindow.frame.midX - size.width / 2, y: notchBottom - size.height - gap)
        let frame = boundedFrame(NSRect(origin: origin, size: size), on: screen)
        let startFrame = NSRect(
            x: anchorWindow.frame.midX - 96,
            y: notchBottom - 22,
            width: 192,
            height: 34
        )
        let transitionID = UUID()
        detachTransitionID = transitionID
        detachTransitionStartedAt = ProcessInfo.processInfo.systemUptime
        detachTargetFrame = frame
        let panel = UtilityIslandPanel(
            contentRect: startFrame,
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.onCalculatorKeyDown = { [weak utilities] event in
            guard app == .calculator else { return false }
            return utilities?.calculator.handleKeyEvent(event) ?? false
        }
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hostingView = NSHostingView(rootView: DetachedUtilityIslandView(
            app: app,
            utilities: utilities,
            onClose: { [weak self] in self?.closeIsland() },
            onReattach: { [weak self] in self?.reattachIsland() }
        ))
        hostingView.wantsLayer = true
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.alphaValue = 1
        panel.onIslandDragStarted = { [weak self] in self?.beginDragging() }
        panel.onIslandDragChanged = { [weak self] origin in self?.dragIsland(to: origin) }
        panel.onIslandDragEnded = { [weak self] in self?.finishDragging() }
        islandWindow = panel
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.78
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.22, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeDetachment(transitionID, panel: panel, frame: frame)
            }
        })
        // AppKit can omit the animation completion when the user changes apps
        // or Spaces. Recover promptly on activation and keep a short watchdog
        // so one interrupted presentation cannot block later detaches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.92) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.completeDetachment(transitionID, panel: panel, frame: frame)
        }
        return true
    }

    func reattachUtility(_ app: GrassUtilityApp) {
        guard selectedApp == app else { return }
        reattachIsland()
    }

    func recoverInterruptedDetachmentIfNeeded() {
        if let transitionID = closeTransitionID,
           let app = selectedApp,
           let startedAt = closeTransitionStartedAt,
           ProcessInfo.processInfo.systemUptime - startedAt >= 1.05 {
            completeClosing(
                app: app,
                transitionID: transitionID,
                reattach: closeTransitionReattaches
            )
            return
        }

        guard let transitionID = detachTransitionID,
              let panel = islandWindow,
              let frame = detachTargetFrame,
              let startedAt = detachTransitionStartedAt,
              ProcessInfo.processInfo.systemUptime - startedAt >= 0.82 else { return }
        completeDetachment(transitionID, panel: panel, frame: frame)
    }

    private func completeDetachment(_ transitionID: UUID, panel: NSPanel, frame: NSRect) {
        guard detachTransitionID == transitionID, islandWindow === panel else { return }
        panel.setFrame(frame, display: true)
        detachTransitionID = nil
        detachTransitionStartedAt = nil
        detachTargetFrame = nil
        isTransitioning = false
    }

    private func beginDragging() {
        guard islandWindow != nil, !isTransitioning else { return }
    }

    private func dragIsland(to origin: NSPoint) {
        guard let panel = islandWindow, let screen = activeScreen else { return }
        let bounded = boundedFrame(NSRect(origin: origin, size: panel.frame.size), on: screen)
        panel.setFrameOrigin(bounded.origin)
    }

    private func finishDragging() {
        guard let panel = islandWindow else { return }
        if isNearNotch(panel.frame) { reattachIsland() }
    }

    private func isNearNotch(_ frame: NSRect) -> Bool {
        guard let anchorWindow, let screen = activeScreen else { return false }
        let dx = abs(frame.midX - anchorWindow.frame.midX)
        let notchBottom = screen.frame.maxY - max(34, screen.safeAreaInsets.top)
        let dy = abs(frame.maxY - notchBottom)
        return dx < 150 && dy < 175
    }

    private func closeIsland() {
        guard let app = selectedApp, !isTransitioning else { return }
        isTransitioning = true
        let transitionID = UUID()
        closeTransitionID = transitionID
        closeTransitionStartedAt = ProcessInfo.processInfo.systemUptime
        closeTransitionReattaches = false
        utilities.flushPendingSaves()
        animateIslandIntoNotch { [weak self] in
            self?.completeClosing(app: app, transitionID: transitionID, reattach: false)
        }
        // AppKit may interrupt a panel animation when Spaces or display
        // configuration changes. Keep the close path recoverable so the
        // controller and menu cannot remain wedged after the island vanishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            self?.completeClosing(app: app, transitionID: transitionID, reattach: false)
        }
    }

    private func reattachIsland() {
        guard let app = selectedApp, islandWindow != nil, !isTransitioning else { return }
        isTransitioning = true
        let transitionID = UUID()
        closeTransitionID = transitionID
        closeTransitionStartedAt = ProcessInfo.processInfo.systemUptime
        closeTransitionReattaches = true
        animateIslandIntoNotch { [weak self] in
            self?.completeClosing(app: app, transitionID: transitionID, reattach: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            self?.completeClosing(app: app, transitionID: transitionID, reattach: true)
        }
    }

    private func completeClosing(app: GrassUtilityApp, transitionID: UUID, reattach: Bool) {
        guard closeTransitionID == transitionID else { return }
        closeTransitionID = nil
        closeTransitionStartedAt = nil
        closeTransitionReattaches = false
        finishClosing()
        if reattach { onReattach?(app) } else { onDismiss?(app) }
    }

    private func animateIslandIntoNotch(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let panel = islandWindow, let anchorWindow, let screen = activeScreen else { completion(); return }
        let notchBottom = screen.frame.maxY - max(34, screen.safeAreaInsets.top)
        let size = panel.frame.size
        let destinationOrigin = NSPoint(
            x: anchorWindow.frame.midX - size.width / 2,
            y: notchBottom + 14 - size.height / 2
        )
        if let host = panel.contentView as? NSHostingView<DetachedUtilityIslandView> {
            var islandView = host.rootView
            islandView.isAbsorbing = true
            host.rootView = islandView
        }
        let animationDuration: TimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0.84
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, animationDuration - 0.20)) { [weak panel] in
            Task { @MainActor in
                guard let host = panel?.contentView as? NSHostingView<DetachedUtilityIslandView> else { return }
                var islandView = host.rootView
                islandView.isFading = true
                host.rootView = islandView
            }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: 0.34, 0.92, 0.54, 1.08)
            panel.animator().setFrame(
                NSRect(origin: destinationOrigin, size: size),
                display: true
            )
        })
        // Do not rely on NSWindow's animator completion to keep the panel
        // alive: some borderless panels report completion before their SwiftUI
        // content animation has finished. Finish only after the visual motion.
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.04) {
            Task { @MainActor in completion() }
        }
    }

    private func finishClosing() {
        islandWindow?.orderOut(nil)
        islandWindow = nil
        selectedApp = nil
        activeScreen = nil
        detachTransitionID = nil
        detachTransitionStartedAt = nil
        detachTargetFrame = nil
        closeTransitionID = nil
        closeTransitionStartedAt = nil
        closeTransitionReattaches = false
        isTransitioning = false
    }

    private func boundedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

}

private final class UtilityIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCalculatorKeyDown: ((NSEvent) -> Bool)?
    var onIslandDragStarted: (() -> Void)?
    var onIslandDragChanged: ((NSPoint) -> Void)?
    var onIslandDragEnded: (() -> Void)?
    private var dragStartPoint: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingIsland = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            dragStartPoint = convertPoint(toScreen: event.locationInWindow)
            dragStartOrigin = frame.origin
            isDraggingIsland = false
            super.sendEvent(event)
            return
        }

        if event.type == .leftMouseDragged,
           let dragStartPoint, let dragStartOrigin {
            super.sendEvent(event)
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - dragStartPoint.x
            let dy = pointer.y - dragStartPoint.y
            if !isDraggingIsland, hypot(dx, dy) >= 5 {
                isDraggingIsland = true
                onIslandDragStarted?()
            }
            if isDraggingIsland {
                onIslandDragChanged?(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
            }
            return
        }

        if event.type == .leftMouseUp {
            super.sendEvent(event)
            if isDraggingIsland { onIslandDragEnded?() }
            dragStartPoint = nil
            dragStartOrigin = nil
            isDraggingIsland = false
            return
        }

        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if onCalculatorKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
