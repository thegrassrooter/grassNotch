import AppKit
import SwiftUI

struct ADBPhoneDevice: Identifiable, Equatable, Sendable {
    let serial: String
    let model: String
    let state: String

    var id: String { serial }
    var isReady: Bool { state == "device" }
    var isWireless: Bool { serial.contains(":") || serial.contains("_adb-tls-connect._tcp") }
}

private enum PhoneTool {
    static func executable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 8) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (-1, "The phone connection timed out.")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func parseDevices(_ output: String) -> [ADBPhoneDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard !line.hasPrefix("List of devices"), !line.isEmpty else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            let serial = fields[0]
            let state = fields[1]
            let modelField = fields.first(where: { $0.hasPrefix("model:") })
            let model = modelField.map { String($0.dropFirst("model:".count)) } ?? serial
            return ADBPhoneDevice(serial: serial, model: model, state: state)
        }
    }

    static func uniqueDevices(_ devices: [ADBPhoneDevice]) -> [ADBPhoneDevice] {
        // Wireless debugging may expose both the remembered mDNS transport and
        // a manually connected IP transport for the same handset.
        var chosen: [String: ADBPhoneDevice] = [:]
        for device in devices {
            let key = device.model == device.serial ? device.serial : device.model
            if let previous = chosen[key] {
                let score: (ADBPhoneDevice) -> Int = { item in
                    (item.isReady ? 4 : 0)
                    + (item.serial.contains(":") ? 2 : 0)
                    + (item.serial.contains("_adb-tls-connect._tcp") ? 1 : 0)
                }
                if score(device) > score(previous) { chosen[key] = device }
            } else {
                chosen[key] = device
            }
        }
        return chosen.values.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
    }
}

private final class PhoneProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        if storage.count > 4_096 { storage = String(storage.suffix(4_096)) }
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class PhoneMirrorManager: ObservableObject {
    @Published private(set) var devices: [ADBPhoneDevice] = []
    @Published private(set) var selectedDevice: ADBPhoneDevice?
    @Published private(set) var isConnecting = false
    @Published private(set) var isMirroring = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var toolAvailabilityMessage: String?

    var isConnected: Bool { selectedDevice?.isReady == true }

    private var mirrorProcess: Process?
    private var mirrorOutputPipe: Pipe?
    private var mirrorOutputBuffer: PhoneProcessOutput?
    private var pendingADBDisconnectSerial: String?
    private var pollTimer: Timer?
    private var autoReconnectTimer: Timer?
    private var isShuttingDown = false
    private var generation = 0
    private let adbURL = PhoneTool.executable(named: "adb")
    private let scrcpyURL = PhoneTool.executable(named: "scrcpy")
    private let preferredSerialKey = "grassIsland.phoneMirror.preferredSerial"

    init() {
        if adbURL == nil {
            toolAvailabilityMessage = "Android Platform Tools (adb) were not found. Install them to connect a phone."
        } else if scrcpyURL == nil {
            toolAvailabilityMessage = "scrcpy was not found. Install scrcpy to view and control the phone screen."
        }
    }

    func connect() {
        guard !isConnecting else { return }
        guard let adbURL else {
            toolAvailabilityMessage = "Install Android Platform Tools (adb), then reopen NotchOS."
            return
        }

        isConnecting = true
        errorMessage = nil
        generation += 1
        let request = generation
        let preferred = UserDefaults.standard.string(forKey: preferredSerialKey)

        Task.detached(priority: .userInitiated) { [weak self] in
            _ = PhoneTool.run(adbURL, arguments: ["start-server"], timeout: 6)
            var devices = PhoneTool.parseDevices(PhoneTool.run(adbURL, arguments: ["devices", "-l"]).output)

            if !devices.contains(where: \.isReady) {
                let services = PhoneTool.run(adbURL, arguments: ["mdns", "services"]).output
                let endpoints = services.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                    let text = String(line)
                    guard text.contains("_adb-tls-connect._tcp") else { return nil }
                    return text.split(whereSeparator: \.isWhitespace).last.map(String.init)
                }
                for endpoint in endpoints {
                    _ = PhoneTool.run(adbURL, arguments: ["connect", endpoint], timeout: 5)
                }
                devices = PhoneTool.parseDevices(PhoneTool.run(adbURL, arguments: ["devices", "-l"]).output)
            }

            let unique = PhoneTool.uniqueDevices(devices)
            let ready = unique.filter(\.isReady)
            let selected = ready.first(where: { $0.serial == preferred }) ?? ready.first
            await MainActor.run { [weak self] in
                guard let self, self.generation == request else { return }
                self.devices = unique
                self.selectedDevice = selected
                self.isConnecting = false
                if let selected {
                    UserDefaults.standard.set(selected.serial, forKey: self.preferredSerialKey)
                    self.errorMessage = nil
                    self.startMonitoring()
                } else if let unavailable = unique.first {
                    self.errorMessage = unavailable.state == "unauthorized"
                        ? "Unlock the phone and accept its USB debugging authorization prompt. NotchOS will retry automatically."
                        : "The phone is visible but not ready (\(unavailable.state)). Check Wireless debugging; NotchOS will retry automatically."
                    self.scheduleAutomaticReconnect()
                } else {
                    self.errorMessage = "No paired phone is reachable. Keep Wireless debugging enabled and both devices on the same network; NotchOS will retry automatically."
                    self.scheduleAutomaticReconnect()
                }
            }
        }
    }

    func connectAutomatically() {
        guard !isShuttingDown, !isConnecting, !isConnected else { return }
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = nil
        connect()
    }

    func select(_ device: ADBPhoneDevice) {
        guard device.isReady else { return }
        selectedDevice = device
        UserDefaults.standard.set(device.serial, forKey: preferredSerialKey)
        errorMessage = nil
    }

    func startMirroring() {
        guard isConnected, let selectedDevice else {
            errorMessage = "Connect an authorized phone first."
            return
        }
        guard let scrcpyURL else {
            toolAvailabilityMessage = "Install scrcpy to view and control the phone screen."
            return
        }
        if let mirrorProcess, mirrorProcess.isRunning { return }
        mirrorProcess = nil
        errorMessage = nil

        let process = Process()
        let outputPipe = Pipe()
        let outputBuffer = PhoneProcessOutput()
        mirrorOutputPipe = outputPipe
        mirrorOutputBuffer = outputBuffer
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputBuffer.append(text)
        }
        process.executableURL = scrcpyURL
        // Emulate a physical keyboard so Android's secure lock-screen PIN
        // field receives Mac keystrokes. SDK injection is not accepted
        // consistently by lock screens. Turn the handset display off while
        // keeping the mirrored control session active.
        process.arguments = [
            "-s", selectedDevice.serial,
            "--keyboard=uhid",
            "--turn-screen-off",
            "--power-off-on-close",
            "--window-title=grassNotch Phone"
        ]
        // Finder-launched app bundles do not inherit Homebrew's shell PATH.
        // scrcpy launches its own adb subprocess, so point it at the same adb
        // binary this manager used to discover and connect the phone.
        var environment = ProcessInfo.processInfo.environment
        if let adbURL {
            environment["ADB"] = adbURL.path
            let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let requiredPaths = [adbURL.deletingLastPathComponent().path, scrcpyURL.deletingLastPathComponent().path]
            let pathEntries = (requiredPaths + existingPath.split(separator: ":").map(String.init))
                .reduce(into: [String]()) { paths, path in
                    if !paths.contains(path) { paths.append(path) }
                }
            environment["PATH"] = pathEntries.joined(separator: ":")
        }
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                self.mirrorProcess = nil
                self.isMirroring = false
                let output = outputBuffer.value()
                self.mirrorOutputPipe = nil
                self.mirrorOutputBuffer = nil
                if !output.isEmpty, self.selectedDevice != nil {
                    self.errorMessage = "Phone mirror closed: \(output.suffix(700))"
                } else if self.selectedDevice != nil {
                    self.errorMessage = "Phone mirror closed unexpectedly. Check that the phone is awake and still connected, then try again."
                }
                if let serial = self.pendingADBDisconnectSerial {
                    self.pendingADBDisconnectSerial = nil
                    self.disconnectADB(serial)
                }
            }
        }

        do {
            try process.run()
            mirrorProcess = process
            isMirroring = true
            errorMessage = nil
        } catch {
            errorMessage = "Could not launch scrcpy: \(error.localizedDescription)"
        }
    }

    func togglePhoneDisplay() {
        guard let selectedDevice, let adbURL, isConnected else { return }
        let serial = selectedDevice.serial
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PhoneTool.run(adbURL, arguments: ["-s", serial, "shell", "input", "keyevent", "26"], timeout: 4)
            await MainActor.run { [weak self] in
                guard let self, self.selectedDevice?.serial == serial else { return }
                if result.status == 0 {
                    self.errorMessage = nil
                } else {
                    self.errorMessage = "Could not change the phone display state. Unlock the phone and check its debugging authorization."
                }
            }
        }
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard let selectedDevice else {
            self.selectedDevice = nil
            devices = []
            return
        }

        let serial = selectedDevice.serial
        let disconnectADBWhenMirrorCloses = selectedDevice.isWireless
        if let mirrorProcess {
            // scrcpy must finish its close sequence (including powering the
            // handset display off) before adb disconnects the wireless link.
            pendingADBDisconnectSerial = disconnectADBWhenMirrorCloses ? serial : nil
            mirrorProcess.terminate()
        } else if disconnectADBWhenMirrorCloses {
            disconnectADB(serial)
        }
        self.selectedDevice = nil
        devices = []
        errorMessage = nil
    }

    func shutdown() {
        isShuttingDown = true
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = nil
        stopMirroring()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() { connect() }

    private func stopMirroring() {
        guard let mirrorProcess else { return }
        mirrorProcess.terminate()
    }

    private func disconnectADB(_ serial: String) {
        guard let adbURL else { return }
        Task.detached(priority: .utility) {
            _ = PhoneTool.run(adbURL, arguments: ["disconnect", serial], timeout: 4)
        }
    }

    private func startMonitoring() {
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = nil
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollConnection() }
        }
    }

    private func pollConnection() {
        guard !isConnecting, let adbURL, let selectedDevice else { return }
        let serial = selectedDevice.serial
        Task.detached(priority: .utility) { [weak self] in
            let result = PhoneTool.run(adbURL, arguments: ["-s", serial, "get-state"], timeout: 4)
            await MainActor.run { [weak self] in
                guard let self, self.selectedDevice?.serial == serial else { return }
                if result.status != 0 || result.output.trimmingCharacters(in: .whitespacesAndNewlines) != "device" {
                    self.stopMirroring()
                    self.selectedDevice = nil
                    self.errorMessage = "Phone disconnected. Check that it is on the same Wi-Fi network and Wireless debugging is enabled."
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    self.scheduleAutomaticReconnect()
                }
            }
        }
    }

    private func scheduleAutomaticReconnect() {
        guard !isShuttingDown, !isConnected else { return }
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.connectAutomatically() }
        }
        if let autoReconnectTimer { RunLoop.main.add(autoReconnectTimer, forMode: .common) }
    }
}

@MainActor
struct PhoneMirrorPanel: View {
    @ObservedObject var manager: PhoneMirrorManager
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Android Phone")
                        .font(.system(size: 14, weight: .semibold))
                    Text(manager.isConnected ? "Connected over ADB" : (manager.isConnecting ? "Connecting automatically…" : "Waiting for paired phone"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Circle()
                    .fill(manager.isConnected ? Color.green : Color.white.opacity(0.22))
                    .frame(width: 7, height: 7)
            }

            if manager.isConnected, let device = manager.selectedDevice {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.model.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                Button(action: manager.startMirroring) {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.on.rectangle")
                        Text(manager.isMirroring ? "Screen mirroring is open" : "Show screen mirroring")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .disabled(manager.isMirroring)

                Button(action: manager.togglePhoneDisplay) {
                    Label("Toggle phone display", systemImage: "display")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)

                Text("Click the mirror window to focus it, then type your PIN with the Mac keyboard. Unlock first, then toggle the phone display here; tap again to wake it.")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.54))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if manager.isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting to your paired phone…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 29, weight: .light))
                        .foregroundStyle(.white.opacity(0.78))
                    Text("Waiting for your paired Android phone")
                        .font(.system(size: 11, weight: .medium))
                    Text("NotchOS reconnects automatically when Wireless debugging is available and both devices are on the same network.")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let toolMessage = manager.toolAvailabilityMessage {
                Text(toolMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = manager.errorMessage {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
