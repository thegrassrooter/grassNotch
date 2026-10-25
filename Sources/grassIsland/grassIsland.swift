
import AppKit
import AVFoundation
import CoreAudio
import Darwin
import QuartzCore
import Foundation
import Intents
import Network
import IOBluetooth
import SwiftUI

// MARK: - Screen

extension NSScreen {
    static var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
    }
}

// MARK: - Battery

enum SystemBattery {
    static let alertThresholds = [10, 5, 2]

    static func crossedAlertThresholds(
        previousPercent: Int?,
        currentPercent: Int,
        isCharging: Bool
    ) -> [Int] {
        guard !isCharging,
              let previousPercent,
              currentPercent < previousPercent else { return [] }
        return alertThresholds.filter {
            previousPercent > $0 && currentPercent <= $0
        }
    }

    static func fetchInfo() -> (percent: Int, isCharging: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: data, encoding: .utf8) ?? ""

            // `discharging` contains the substring `charging`, so exclude it
            // before checking the charging state. AC Power also detects that
            // the adapter is connected when the battery is not actively charging.
            let isDischarging = output.localizedCaseInsensitiveContains("discharging")
            let isActivelyCharging = !isDischarging
                && output.localizedCaseInsensitiveContains("charging")
            let isOnACPower = output.localizedCaseInsensitiveContains("AC Power")
            let charging = isActivelyCharging || isOnACPower

            if let range = output.range(
                of: #"\d+%"#,
                options: .regularExpression
            ), let percent = Int(
                output[range].replacingOccurrences(of: "%", with: "")
            ) {
                return (percent, charging)
            }

            return (100, charging)
        } catch {
            return (100, false)
        }
    }
}

enum SystemNetwork {
    static func shouldShowDisconnectAlert(previouslyConnected: Bool?, connected: Bool) -> Bool {
        if let previouslyConnected { return previouslyConnected && !connected }
        return !connected
    }
}

enum SystemBluetooth {
    // The physical notch masks the center of this window. The alert must be
    // wider than the notch and draw its icon in a visible side wing.
    static let physicalNotchWidth: CGFloat = 210
    static let alertWidth: CGFloat = 360
    static let alertHeight: CGFloat = 34

    static func isPoweredOn() -> Bool? {
        // Accessing IOBluetoothHostController from a bare `swift run`
        // executable can trigger a TCC privacy termination because that
        // process has no app Info.plist usage description.
        guard InboxNotifications.hasApplicationBundle else { return nil }
        guard let controller = IOBluetoothHostController.default() else { return nil }
        switch controller.powerState {
        case kBluetoothHCIPowerStateON:
            return true
        case kBluetoothHCIPowerStateOFF:
            return false
        default:
            return nil
        }
    }

    static func didPowerStateChange(previous: Bool?, current: Bool) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}

struct CaptureActivityState: Equatable, Sendable {
    var cameraInUse = false
    var microphoneInUse = false

    var activeCount: Int { (cameraInUse ? 1 : 0) + (microphoneInUse ? 1 : 0) }
    var hasActivity: Bool { activeCount > 0 }

    static func idleWidth(for state: CaptureActivityState, baseWidth: CGFloat = 210) -> CGFloat {
        state.hasActivity ? (state.activeCount == 1 ? baseWidth + 50 : baseWidth + 90) : baseWidth
    }

    static func compactMediaWidth(for state: CaptureActivityState, baseWidth: CGFloat = 360) -> CGFloat {
        baseWidth + CGFloat(state.activeCount) * 32
    }
}

enum SystemCaptureActivity {
    static func currentState() -> CaptureActivityState {
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        return CaptureActivityState(
            cameraInUse: cameras.contains(where: \.isInUseByAnotherApplication),
            microphoneInUse: isAnyProcessCapturingAudioInput()
        )
    }

    private static func isAnyProcessCapturingAudioInput() -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize
        ) == noErr, listSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return false }
        var processIDs = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &processIDs
        ) == noErr else { return false }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for processID in processIDs {
            var isRunningInput: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(
                processID, &runningAddress, 0, nil, &runningSize, &isRunningInput
            ) == noErr, isRunningInput != 0 { return true }
        }
        return false
    }

    static func icon(camera: Bool) -> NSImage? {
        let name = camera ? "camera-activity" : "microphone-activity"
        if let bundled = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: bundled) { return image }
#if !GRASS_ISLAND_REGRESSION
        if let packaged = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Assets"),
           let image = NSImage(contentsOf: packaged) { return image }
#endif
        return nil
    }
}

/// Google Meet keeps the system microphone capture stream active while its
/// in-call mute is on. macOS only reports that a process is capturing audio,
/// so read Meet's public accessibility labels through the same Chrome
/// automation path already used for YouTube. Other apps continue to use the
/// system-wide Core Audio capture signal above.
enum ChromeMeetingCapture {
    struct State: Equatable, Sendable {
        var cameraInUse: Bool
        var microphoneInUse: Bool
    }

    static func parse(_ output: String?) -> State? {
        guard let output else { return nil }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count == 3, parts[0] == "GRASS_MEET" else { return nil }
        return State(cameraInUse: parts[1] == "1", microphoneInUse: parts[2] == "1")
    }

    @MainActor
    static func fetch(completion: @MainActor @Sendable @escaping (State?) -> Void) {
        let script = #"""
        tell application "Google Chrome"
            if not running or (count of windows) is 0 then return "NO_MEET"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "meet.google.com/" then
                        set captureState to execute t javascript "(() => { const labels = Array.from(document.querySelectorAll('[aria-label]')).map(x => (x.getAttribute('aria-label') || '').toLowerCase()); const mic = labels.find(x => (x.includes('microphone') || x.includes('mic')) && (x.includes('turn on') || x.includes('turn off') || x.includes('mute') || x.includes('unmute'))); const camera = labels.find(x => (x.includes('camera') || x.includes('video')) && (x.includes('turn on') || x.includes('turn off') || x.includes('mute') || x.includes('unmute'))); if (!mic || !camera) return 'NO_MEETING_CONTROLS'; const isOn = x => !(x.includes('turn on') || x.includes('unmute')); return ['GRASS_MEET', isOn(camera) ? '1' : '0', isOn(mic) ? '1' : '0'].join('|'); })()"
                        return captureState
                    end if
                end repeat
            end repeat
            return "NO_MEET"
        end tell
        """#

        SystemVolume.runAppleScriptAsync(script, timeoutInterval: 1.0) { output in
            completion(parse(output))
        }
    }
}

enum SystemFocus {
    static let alertWidth: CGFloat = 360

    static func didStatusChange(previous: Bool?, current: Bool) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}

// MARK: - Volume and AppleScript

enum SystemVolume {
    static func readNative() -> Float? {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }

        return min(max(Float(value), 0), 1)
    }

    static func runAppleScriptAsync(
        _ source: String,
        timeoutInterval: TimeInterval = 3,
        completion: @MainActor @Sendable @escaping (String?) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let output = Pipe()
            let errors = Pipe()

            process.standardOutput = output
            process.standardError = errors

            do {
                try process.run()

                // Drain both pipes before waiting to avoid pipe-buffer deadlocks.
                let outputTask = Task.detached(priority: .utility) {
                    output.fileHandleForReading.readDataToEndOfFile()
                }

                let errorTask = Task.detached(priority: .utility) {
                    errors.fileHandleForReading.readDataToEndOfFile()
                }

                let timeout = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeoutInterval,
                    execute: timeout
                )

                process.waitUntilExit()
                timeout.cancel()

                let data = await outputTask.value
                let errorData = await errorTask.value

                guard process.terminationStatus == 0 else {
                    let reason = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !reason.isEmpty {
                        NSLog("[AppleScript] %@", reason)
                    }
                    await completion(nil)
                    return
                }

                await completion(String(data: data, encoding: .utf8))
            } catch {
                await completion(nil)
            }
        }
    }
}

// MARK: - Clock Timer

struct ClockTimerInfo: Sendable {
    let isRunning: Bool
    let remainingText: String
}

enum ClockAppMonitor {
    static func fetchActiveTimer(
        completion: @MainActor @Sendable @escaping (ClockTimerInfo?) -> Void
    ) {
        let script = #"""
        tell application "System Events"
            if not (exists process "Clock") then return "NOT_RUNNING"
            tell process "Clock"
                try
                    set timeElements to (value of every static text of UI elements of window 1 whose value contains ":")
                    repeat with itemRef in timeElements
                        if class of itemRef is list then
                            repeat with subItem in itemRef
                                if subItem contains ":" and length of subItem <= 8 then return subItem as text
                            end repeat
                        else if itemRef contains ":" and length of itemRef <= 8 then
                            return itemRef as text
                        end if
                    end repeat
                    return "NOT_RUNNING"
                on error
                    return "NOT_RUNNING"
                end try
            end tell
        end tell
        """#

        SystemVolume.runAppleScriptAsync(script) { output in
            guard let value = output?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !value.isEmpty,
               value != "NOT_RUNNING",
               !value.contains("execution error") else {
                completion(nil)
                return
            }

            completion(
                ClockTimerInfo(isRunning: true, remainingText: value)
            )
        }
    }
}

// MARK: - YouTube

struct MediaInfo: Sendable {
    let url: String
    let title: String
    let videoID: String
    let isYouTube: Bool
    let isWatchPage: Bool
    let playing: Bool
    let isPaused: Bool
    let currentTime: Double
    let duration: Double
    let thumbnailURL: String
    let isShort: Bool
    let tabID: Int
}

enum ChromeYouTube {
    @MainActor
    static func fetchPlaybackState(
        tabID: Int,
        completion: @MainActor @Sendable @escaping (Bool?) -> Void
    ) {
        guard tabID > 0 else { completion(nil); return }
        let script = #"""
        tell application "Google Chrome"
            if not running or (count of windows) is 0 then return "NO_STATE"
            set stateJS to "(() => { const shortPage = location.pathname.startsWith('/shorts/'); const v = (shortPage ? (document.querySelector('ytd-reel-video-renderer[is-active] video') || document.querySelector('ytd-shorts video') || document.querySelector('#shorts-player video')) : null) || document.querySelector('video.html5-main-video') || document.querySelector('video'); return v && !v.paused && !v.ended ? 'PLAYING' : 'PAUSED'; })()"
            set frontTab to active tab of front window
            if (id of frontTab as integer) is TAB_ID then
                return execute frontTab javascript stateJS
            end if
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as integer) is TAB_ID then
                        return execute t javascript stateJS
                    end if
                end repeat
            end repeat
            return "NO_STATE"
        end tell
        """#.replacingOccurrences(of: "TAB_ID", with: String(tabID))

        SystemVolume.runAppleScriptAsync(script, timeoutInterval: 0.75) { output in
            guard let state = output?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                completion(nil)
                return
            }
            switch state {
            case "PLAYING": completion(true)
            case "PAUSED": completion(false)
            default: completion(nil)
            }
        }
    }

    static func fetch(
        preferredTabID: Int?,
        completion: @MainActor @Sendable @escaping (MediaInfo?) -> Void
    ) {
        let preferredID = preferredTabID ?? 0
        let script = #"""
        tell application "Google Chrome"
            if not running then return "NO_MEDIA"
            if (count of windows) is 0 then return "NO_MEDIA"
            set chosenTab to missing value
            if PREFERRED_TAB_ID > 0 then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (id of t as integer) is PREFERRED_TAB_ID then
                            set chosenTab to t
                            exit repeat
                        end if
                    end repeat
                    if chosenTab is not missing value then exit repeat
                end repeat
                if chosenTab is missing value then return "NO_MEDIA"
            else
                set frontTab to active tab of front window
                set frontURL to URL of frontTab
                if frontURL contains "youtube.com/watch" or frontURL contains "youtube.com/shorts/" or frontURL contains "youtu.be/" then
                    set chosenTab to frontTab
                else
                    repeat with w in windows
                        repeat with t in tabs of w
                            set candidateURL to URL of t
                            if candidateURL contains "youtube.com/watch" or candidateURL contains "youtube.com/shorts/" or candidateURL contains "youtu.be/" then
                                set chosenTab to t
                                exit repeat
                            end if
                        end repeat
                        if chosenTab is not missing value then exit repeat
                    end repeat
                end if
                if chosenTab is missing value then return "NO_MEDIA"
            end if
            set chosenTabID to id of chosenTab as text
            set jsResult to execute chosenTab javascript "(() => { const u = new URL(location.href); const host = u.hostname.toLowerCase(); const yt = host === 'youtube.com' || host.endsWith('.youtube.com') || host === 'youtu.be'; const shortPage = yt && u.pathname.startsWith('/shorts/'); const shortLink = host === 'youtu.be' && !!u.pathname.split('/').filter(Boolean)[0]; const watchPage = yt && ((u.pathname === '/watch' && !!u.searchParams.get('v')) || shortLink); const videoID = u.pathname === '/watch' ? (u.searchParams.get('v') || '') : (shortPage ? (u.pathname.split('/')[2] || '') : (host === 'youtu.be' ? u.pathname.split('/').filter(Boolean)[0] || '' : '')); const videos = Array.from(document.querySelectorAll('video')); const shortVideo = shortPage ? (document.querySelector('ytd-reel-video-renderer[is-active] video') || document.querySelector('ytd-shorts video') || document.querySelector('#shorts-player video')) : null; const visibleVideo = videos.find(x => !x.paused && !x.ended && x.readyState >= 1); const v = shortVideo || visibleVideo || document.querySelector('video.html5-main-video') || videos.find(x => x.readyState >= 1) || videos[0] || null; const activeVideo = (shortPage && shortVideo) ? shortVideo : (visibleVideo || v); const active = !!(activeVideo && !activeVideo.paused && !activeVideo.ended); const duration = activeVideo && Number.isFinite(activeVideo.duration) ? activeVideo.duration : 0; const currentTime = activeVideo && Number.isFinite(activeVideo.currentTime) ? activeVideo.currentTime : 0; const thumbnailURL = videoID ? ('https://i.ytimg.com/vi/' + videoID + '/hqdefault.jpg') : ''; return JSON.stringify({ url: location.href, title: document.title || '', videoID, youtube: yt, watchPage, shortPage, playing: active, isPaused: !active, currentTime, duration, thumbnailURL }); })()"
            return chosenTabID & "|||MEDIA|||" & jsResult
        end tell
        """#.replacingOccurrences(of: "PREFERRED_TAB_ID", with: String(preferredID))

        SystemVolume.runAppleScriptAsync(script) { output in
            guard let output, !output.contains("execution error") else {
                completion(nil)
                return
            }
            if output.contains("NO_MEDIA") {
                completion(MediaInfo(url: "", title: "", videoID: "", isYouTube: false,
                                     isWatchPage: false, playing: false, isPaused: true,
                                     currentTime: 0, duration: 0, thumbnailURL: "", isShort: false,
                                     tabID: -1))
                return
            }
            let pieces = output.components(separatedBy: "|||MEDIA|||")
            guard pieces.count == 2,
                  let tabID = Int(pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let data = pieces[1].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = json["url"] as? String else {
                completion(nil)
                return
            }
            let host = URL(string: url)?.host?.lowercased() ?? ""
            let youtube = (json["youtube"] as? Bool)
                ?? (host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be")
            completion(MediaInfo(
                url: url,
                title: (json["title"] as? String ?? "").replacingOccurrences(of: " - YouTube", with: ""),
                videoID: json["videoID"] as? String ?? "",
                isYouTube: youtube,
                isWatchPage: json["watchPage"] as? Bool ?? false,
                playing: json["playing"] as? Bool ?? false,
                isPaused: json["isPaused"] as? Bool ?? true,
                currentTime: json["currentTime"] as? Double ?? 0,
                duration: json["duration"] as? Double ?? 0,
                thumbnailURL: json["thumbnailURL"] as? String ?? "",
                isShort: json["shortPage"] as? Bool ?? false,
                tabID: tabID
            ))
        }
    }

    private static let videoActionQueue = DispatchQueue(label: "grassIsland.youtube.actions", qos: .userInitiated)

    static func performVideoAction(_ action: String, seekSeconds: Double = 0, tabID: Int, videoID: String) {
        guard tabID > 0, !videoID.isEmpty else { return }
        let js: String
        switch action {
        case "play":
            js = "(() => { const shortPage = location.pathname.startsWith('/shorts/'); const player = document.getElementById('movie_player'); const shortVideo = shortPage ? (document.querySelector('ytd-reel-video-renderer[is-active] video') || document.querySelector('ytd-shorts video') || document.querySelector('#shorts-player video')) : null; const v = shortVideo || player?.querySelector('video.html5-main-video') || document.querySelector('video.html5-main-video') || Array.from(document.querySelectorAll('video')).find(x => x.readyState >= 1) || document.querySelector('video'); if (!v) return 'NO_VIDEO'; if (!shortPage && player && typeof player.playVideo === 'function') { player.playVideo(); return 'PLAY_REQUESTED'; } if (!v.paused && !v.ended) return 'PLAYING'; const p = v.play(); if (p && p.catch) p.catch(() => {}); return 'PLAY_REQUESTED'; })()"
        case "pause":
            js = "(() => { const shortPage = location.pathname.startsWith('/shorts/'); const player = document.getElementById('movie_player'); const shortVideo = shortPage ? (document.querySelector('ytd-reel-video-renderer[is-active] video') || document.querySelector('ytd-shorts video') || document.querySelector('#shorts-player video')) : null; const v = shortVideo || player?.querySelector('video.html5-main-video') || document.querySelector('video.html5-main-video') || Array.from(document.querySelectorAll('video')).find(x => !x.paused && !x.ended) || document.querySelector('video'); if (!v) return 'NO_VIDEO'; if (!shortPage && player && typeof player.pauseVideo === 'function') { player.pauseVideo(); return 'PAUSED'; } v.pause(); return 'PAUSED'; })()"
        case "seek":
            let safe = max(-3600, min(3600, seekSeconds))
            js = "(() => { const shortVideo = document.querySelector('ytd-reel-video-renderer[is-active] video') || document.querySelector('ytd-shorts video') || document.querySelector('#shorts-player video'); const v = shortVideo || document.querySelector('video.html5-main-video') || Array.from(document.querySelectorAll('video')).find(x => !x.paused && !x.ended) || document.querySelector('video'); if (!v) return 'NO_VIDEO'; const next = Math.max(0, Math.min(Number.isFinite(v.duration) ? v.duration : Infinity, v.currentTime + (\(safe)))); try { v.currentTime = next; } catch (_) {} v.dispatchEvent(new Event('seeking')); return 'SEEK'; })()"
        default:
            return
        }
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        tell application "Google Chrome"
            if running then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (id of t as integer) is \(tabID) then
                            if (URL of t contains "youtube.com/watch" or URL of t contains "youtube.com/shorts/" or URL of t contains "youtu.be/") and (URL of t contains "\(videoID)") then
                                set jsResult to execute t javascript "\(escaped)"
                                return jsResult
                            end if
                            return "NOT_TRACKED_VIDEO"
                        end if
                    end repeat
                end repeat
            end if
            return "NO_TRACKED_TAB"
        end tell
        """

        // Serialize commands off the main thread. Rapid clicks now issue explicit
        // play/pause states in order rather than racing independent toggle scripts.
        videoActionQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // The media panel remains responsive; the next poll reconciles state.
            }
        }
    }
}

// MARK: - Real Inbox and Gmail detection

struct InboxMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var service: String
    var account: String
    var sender: String
    var senderEmail: String
    var subject: String
    var preview: String
    var receivedAt: Date
    var fingerprint: String
    var sourceURL: String
    var isRead: Bool

    var displayTitle: String {
        let candidate = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? (preview.isEmpty ? service : preview) : candidate
    }
}

extension Notification.Name {
    static let grassIslandInboxChanged = Notification.Name("grassIslandInboxChanged")
}

@MainActor
final class InboxStore {
    static let shared = InboxStore()
    private let defaultsKey = "grassIsland.realInbox.messages.v1"
    private let seenKey = "grassIsland.realInbox.seenFingerprints.v1"
    private let notifiedKey = "grassIsland.notificationFingerprints.v4"
    private(set) var messages: [InboxMessage] = []
    private var seenFingerprints = Set<String>()
    private var notifiedFingerprints: Set<String>

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([InboxMessage].self, from: data) {
            messages = saved.sorted { $0.receivedAt > $1.receivedAt }
        }
        seenFingerprints = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        seenFingerprints.formUnion(messages.map(\.fingerprint))
        notifiedFingerprints = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
    }

    func contains(fingerprint: String) -> Bool {
        !fingerprint.isEmpty && seenFingerprints.contains(fingerprint)
    }

    func claimNotification(for fingerprint: String) -> Bool {
        !claimNotifications(for: [fingerprint]).isEmpty
    }

    func claimNotifications(for fingerprints: [String]) -> Set<String> {
        var claimed = Set<String>()
        for fingerprint in fingerprints where !fingerprint.isEmpty {
            if notifiedFingerprints.insert(fingerprint).inserted { claimed.insert(fingerprint) }
        }
        guard !claimed.isEmpty else { return [] }
        if notifiedFingerprints.count > 20_000 {
            notifiedFingerprints = Set(notifiedFingerprints.suffix(15_000))
        }
        UserDefaults.standard.set(Array(notifiedFingerprints), forKey: notifiedKey)
        return claimed
    }

    func hasNotificationBeenDelivered(for fingerprint: String) -> Bool {
        notifiedFingerprints.contains(fingerprint)
    }

    @discardableResult
    func add(_ message: InboxMessage) -> Bool {
        add(contentsOf: [message]) > 0
    }

    /// Adds a scan's messages together so one inbox update performs one
    /// persistence write and one UI notification, regardless of batch size.
    @discardableResult
    func add(contentsOf incoming: [InboxMessage]) -> Int {
        var fingerprintsInBatch = Set<String>()
        var additions: [InboxMessage] = []
        additions.reserveCapacity(incoming.count)
        for message in incoming where !message.fingerprint.isEmpty {
            guard !contains(fingerprint: message.fingerprint),
                  fingerprintsInBatch.insert(message.fingerprint).inserted else { continue }
            seenFingerprints.insert(message.fingerprint)
            additions.append(message)
        }
        guard !additions.isEmpty else { return 0 }
        // Single-message insertion previously put the last scanned message at
        // the front. Reversing the batch preserves that visible ordering.
        messages.insert(contentsOf: additions.reversed(), at: 0)
        if messages.count > 150 { messages = Array(messages.prefix(150)) }
        persistAndNotify()
        return additions.count
    }

    func markReadAndRemove(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].isRead = true
        messages.remove(at: index)
        persistAndNotify()
    }

    func remove(id: String) {
        let oldCount = messages.count
        messages.removeAll { $0.id == id }
        if messages.count != oldCount { persistAndNotify() }
    }

    func clearAll() {
        guard !messages.isEmpty else { return }
        messages.removeAll()
        persistAndNotify()
    }

    func reconcileGmail(scannedAccounts: Set<String>, unreadFingerprints: Set<String>) {
        guard !scannedAccounts.isEmpty else { return }
        let oldCount = messages.count
        messages.removeAll { message in
            message.service == "Gmail"
                && scannedAccounts.contains(message.account.lowercased())
                && !unreadFingerprints.contains(message.fingerprint)
        }
        if messages.count != oldCount { persistAndNotify() }
    }

    func reconcileWhatsAppUnread(fingerprints: Set<String>) {
        let oldCount = messages.count
        messages.removeAll { $0.service == "WhatsApp" && !fingerprints.contains($0.fingerprint) }
        if messages.count != oldCount { persistAndNotify() }
    }

    private func persistAndNotify() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(Array(seenFingerprints.suffix(2000)), forKey: seenKey)
        NotificationCenter.default.post(name: .grassIslandInboxChanged, object: nil)
    }
}

struct GmailScan: Sendable {
    let messages: [InboxMessage]
    let scannedInboxAccounts: Set<String>
}

enum GmailMonitor {
    static func parseOutput(_ output: String) -> GmailScan? {
        guard output != "NO_GMAIL", !output.hasPrefix("GMAIL_ERROR::"), !output.contains("execution error") else { return nil }
        var found: [InboxMessage] = []
        var scannedAccounts = Set<String>()
        for payload in output.components(separatedBy: "|||GMAIL|||") {
            guard let data = payload.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let account = root["account"] as? String ?? "Gmail"
            if root["inboxVisible"] as? Bool == true { scannedAccounts.insert(account.lowercased()) }
            let items = root["messages"] as? [[String: Any]] ?? []
            for item in items {
                let sender = item["sender"] as? String ?? "Unknown sender"
                let senderEmail = item["senderEmail"] as? String ?? ""
                let subject = item["subject"] as? String ?? "(No subject)"
                let preview = item["preview"] as? String ?? ""
                let fingerprint = "gmail::" + (item["fingerprint"] as? String ?? "")
                guard fingerprint != "gmail::" else { continue }
                found.append(InboxMessage(
                    id: UUID().uuidString,
                    service: "Gmail",
                    account: account,
                    sender: sender,
                    senderEmail: senderEmail,
                    subject: subject,
                    preview: preview,
                    receivedAt: Date(),
                    fingerprint: fingerprint,
                    sourceURL: item["sourceURL"] as? String ?? "https://mail.google.com/",
                    isRead: false
                ))
            }
        }
        guard !scannedAccounts.isEmpty || !found.isEmpty else { return nil }
        return GmailScan(messages: found, scannedInboxAccounts: scannedAccounts)
    }

    static func fetchUnread(completion: @MainActor @Sendable @escaping (GmailScan?) -> Void) {
        let javascript = #"""
        (() => {
          const clean = value => (value || '').replace(/\s+/g, ' ').trim();
          const match = location.pathname.match(/\/mail\/u\/(\d+)/);
          const accountIndex = match ? Number(match[1]) : 0;
          const profile = document.querySelector('a[aria-label*="Google Account"], button[aria-label*="Google Account"], [data-tooltip*="Google Account"], [data-email]');
          const profileText = profile ? [profile.getAttribute('aria-label'), profile.getAttribute('data-tooltip'), profile.getAttribute('data-email'), profile.getAttribute('email'), profile.innerText].filter(Boolean).join(' ') : '';
          const emailMatch = profileText.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
          const account = emailMatch ? emailMatch[0] : ('Gmail account ' + (accountIndex + 1));
          const inboxVisible = /#inbox(?:\/|$)/.test(location.hash) && !!document.querySelector('[role="main"]') && !document.querySelector('[role="progressbar"]');
          const rows = inboxVisible ? Array.from(document.querySelectorAll('tr.zA,[role="main"] [role="main"] tr')).filter(row => row.classList.contains('zE') || /unread/i.test(row.getAttribute('aria-label') || '') || row.querySelector('[aria-label*="unread" i]')) : [];
          const messages = [];
          for (const row of rows.slice(0, 50)) {
            const senderNode = row.querySelector('.yW span[email], .yW span[title], .yP span[email], [email]');
            const senderEmail = senderNode ? (senderNode.getAttribute('email') || '') : '';
            const sender = senderNode ? clean(senderNode.getAttribute('name') || senderNode.getAttribute('title') || senderNode.innerText) : 'Unknown sender';
            const subjectNode = row.querySelector('.bog span, .y6 span:not(.y2), .y6');
            const subject = clean(subjectNode ? subjectNode.innerText : '') || clean(row.getAttribute('aria-label') || '').slice(0, 100) || '(No subject)';
            const previewNode = row.querySelector('.y2');
            const preview = clean(previewNode ? previewNode.innerText : '').replace(/^[-–—]\s*/, '').slice(0, 240);
            const dateNode = row.querySelector('td.xW, span[title]');
            const dateText = dateNode ? clean(dateNode.getAttribute('title') || dateNode.innerText) : '';
            const threadID = row.getAttribute('data-thread-id') || row.getAttribute('data-legacy-thread-id') || '';
            const link = row.querySelector('a[href*="#"]');
            let sourceURL = 'https://mail.google.com/mail/u/' + accountIndex + '/#inbox';
            if (threadID) sourceURL += '/' + threadID;
            else if (link && link.getAttribute('href')) {
              const href = link.getAttribute('href');
              sourceURL = href.startsWith('http') ? href : (href.startsWith('#') ? ('https://mail.google.com/mail/u/' + accountIndex + '/' + href) : ('https://mail.google.com' + href));
            }
            const fingerprint = [account.toLowerCase(), senderEmail.toLowerCase(), sender.toLowerCase(), subject.toLowerCase(), preview.toLowerCase(), threadID || dateText].join('::');
            messages.push({account, sender, senderEmail, subject, preview, fingerprint, sourceURL});
          }
          return JSON.stringify({account, accountIndex, inboxVisible, messages});
        })()
        """#

        let escapedJS = javascript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        tell application "Google Chrome"
            if not running then return "NO_GMAIL"
            if (count of windows) is 0 then return "NO_GMAIL"
            set allResults to ""
            set allErrors to ""
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "mail.google.com/mail" then
                        try
                            set jsResult to execute t javascript "\(escapedJS)"
                            if jsResult is not missing value and jsResult is not "" then
                                if allResults is not "" then set allResults to allResults & "|||GMAIL|||"
                                set allResults to allResults & (jsResult as text)
                            end if
                        on error errMsg
                            if allErrors is not "" then set allErrors to allErrors & "; "
                            set allErrors to allErrors & (errMsg as text)
                        end try
                    end if
                end repeat
            end repeat
            if allResults is "" then
                if allErrors is not "" then return "GMAIL_ERROR::" & allErrors
                return "NO_GMAIL"
            end if
            return allResults
        end tell
        """

        SystemVolume.runAppleScriptAsync(script, timeoutInterval: 10) { output in
            if let output, output.hasPrefix("GMAIL_ERROR::") {
                NSLog("[GmailMonitor] Chrome could not read Gmail: %@", String(output.dropFirst("GMAIL_ERROR::".count)))
                completion(nil)
                return
            }
            guard let output else {
                completion(nil)
                return
            }
            let scan = parseOutput(output)
            if let scan {
                print("[GmailMonitor] inbox accounts: \(scan.scannedInboxAccounts.count), unread rows: \(scan.messages.count)")
            } else {
                print("[GmailMonitor] output could not be parsed as a rendered inbox")
            }
            completion(scan)
        }
    }
}

// MARK: - WhatsApp

struct WhatsAppMessageItem: Sendable, Equatable {
    let name: String
    let avatarURL: String
    let fingerprint: String
    let preview: String
}

struct WhatsAppState: Sendable {
    let hasIncomingCall: Bool
    let callerName: String
    let incomingCallLabel: String
    let messages: [WhatsAppMessageItem]
    let overflowCount: Int
    let isActivePage: Bool

    var hasNewMessage: Bool { !messages.isEmpty }
    var messageSender: String { messages.first?.name ?? "WhatsApp" }
    var avatarUrl: String { messages.first?.avatarURL ?? "" }
    var messageFingerprint: String {
        messages.map { "\($0.name)::\($0.fingerprint)::\($0.avatarURL)" }.joined(separator: "||")
    }
}

struct WhatsAppNotificationFilter {
    private(set) var suppressedFingerprints = Set<String>()

    mutating func notifications(
        from messages: [WhatsAppMessageItem],
        whilePageIsActive: Bool
    ) -> [WhatsAppMessageItem] {
        let currentFingerprints = Set(messages.map(Self.key(for:)))
        if whilePageIsActive {
            suppressedFingerprints.formUnion(currentFingerprints)
            return []
        }

        suppressedFingerprints.formIntersection(currentFingerprints)
        return messages.filter { !suppressedFingerprints.contains(Self.key(for: $0)) }
    }

    mutating func suppress(_ messages: [WhatsAppMessageItem]) {
        suppressedFingerprints.formUnion(messages.map(Self.key(for:)))
    }

    mutating func suppressFingerprints(_ fingerprints: [String]) {
        suppressedFingerprints.formUnion(fingerprints)
    }

    private static func key(for message: WhatsAppMessageItem) -> String {
        "whatsapp::\(message.fingerprint.lowercased())"
    }
}

enum WhatsAppMonitor {
    static func parseOutput(_ output: String) -> WhatsAppState? {
        let activePagePrefix = "ACTIVE_PAGE|||"
        let backgroundPagePrefix = "BACKGROUND_PAGE|||"
        let isActivePage = output.hasPrefix(activePagePrefix)
        let jsonOutput: String
        if isActivePage {
            jsonOutput = String(output.dropFirst(activePagePrefix.count))
        } else if output.hasPrefix(backgroundPagePrefix) {
            jsonOutput = String(output.dropFirst(backgroundPagePrefix.count))
        } else {
            jsonOutput = output
        }
        guard output != "NO_WA", !output.contains("execution error"),
              let data = jsonOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        if type == "CALL" {
            return WhatsAppState(
                hasIncomingCall: true,
                callerName: json["sender"] as? String ?? "WhatsApp Web Call",
                incomingCallLabel: json["callLabel"] as? String ?? "Incoming Call",
                messages: [],
                overflowCount: 0,
                isActivePage: isActivePage
            )
        }
        let rawItems = json["messages"] as? [[String: Any]] ?? []
        let items = rawItems.compactMap { item -> WhatsAppMessageItem? in
            guard let name = item["name"] as? String else { return nil }
            return WhatsAppMessageItem(
                name: name,
                avatarURL: item["avatarURL"] as? String ?? "",
                fingerprint: item["fingerprint"] as? String ?? "",
                preview: item["preview"] as? String ?? ""
            )
        }
        return WhatsAppState(
            hasIncomingCall: false,
            callerName: "",
            incomingCallLabel: "",
            messages: items,
            overflowCount: json["overflowCount"] as? Int ?? 0,
            isActivePage: isActivePage
        )
    }

    static func pollingAppleScript(chromeIsFrontmost: Bool = false) -> String {
        let javascript = #"""
        (() => { const clean = s => (s || '').replace(/\s+/g, ' ').trim(); const activePage = CHROME_FRONTMOST && document.visibilityState === 'visible' && document.hasFocus(); const dialog = document.querySelector('[role=\"dialog\"]'); const text = clean(dialog ? dialog.innerText : ''); const callButtons = Array.from(document.querySelectorAll('button,[role=\"button\"]')); const incoming = /incoming (?:voice |video )?call/i.test(text) || !!document.querySelector('[data-icon*=\"incoming-call\"],[data-testid*=\"incoming-call\"]') || callButtons.some(b => /incoming (?:voice |video )?call/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.innerText || ''))); if (incoming) { const callRoot = dialog || document; const isVideo = !!callRoot.querySelector('[data-testid*=\"video-call\"],[aria-label*=\"video call\" i]') || /video call/i.test(text); const isVoice = !!callRoot.querySelector('[data-testid*=\"voice-call\"],[aria-label*=\"voice call\" i],[aria-label*=\"audio call\" i]') || /voice call|audio call/i.test(text); const lines = (dialog ? dialog.innerText : '').split('\\n').map(clean).filter(Boolean); return (activePage ? 'ACTIVE_PAGE|||' : 'BACKGROUND_PAGE|||') + JSON.stringify({type:'CALL', sender: lines.find(x => !/incoming|voice call|video call/i.test(x)) || 'WhatsApp Web Call', callLabel: isVideo ? 'Incoming Video Call' : (isVoice ? 'Incoming Voice Call' : 'Incoming Call'), activePage}); } const rows = Array.from(document.querySelectorAll('[data-testid=\"cell-frame-container\"], [role=\"listitem\"]')); const found = []; const seen = new Set(); for (const row of rows) { const badge = row.querySelector('[aria-label*=\"unread\" i],[data-testid*=\"unread\"],[data-testid=\"icon-unread-count\"]'); if (!badge) continue; const nameNode = row.querySelector('[data-testid=\"cell-frame-title\"] span[title], span[title]'); const name = clean(nameNode ? (nameNode.getAttribute('title') || nameNode.innerText) : '') || 'WhatsApp'; const img = row.querySelector('img'); const avatarURL = img ? (img.src || '') : ''; const rowText = clean(row.innerText); const unread = clean(badge.getAttribute('aria-label') || badge.innerText || badge.getAttribute('data-testid') || 'unread'); const timeBits = Array.from(row.querySelectorAll('[data-testid*=\"time\"], time')).map(e => clean(e.getAttribute('title') || e.innerText)).filter(Boolean); const lines = (row.innerText || '').split('\\n').map(clean).filter(Boolean); const preview = lines.filter(x => x !== name && x !== unread && !/^\\d{1,2}:\\d{2}$/.test(x)).slice(0, 2).join(' · ').slice(0, 180); const fingerprint = [name.toLowerCase(), preview.toLowerCase(), timeBits.join('|')].join('::'); const key = name + '::' + avatarURL; if (!seen.has(key)) { seen.add(key); found.push({name, avatarURL, fingerprint, preview}); } } found.sort((a,b) => a.name.localeCompare(b.name)); return (activePage ? 'ACTIVE_PAGE|||' : 'BACKGROUND_PAGE|||') + JSON.stringify({type: found.length ? 'MSG' : 'NONE', messages: found.slice(0,100), overflowCount: Math.max(0, found.length - 4), activePage}); })()
        """#.replacingOccurrences(of: "CHROME_FRONTMOST", with: chromeIsFrontmost ? "true" : "false")
        let escapedJS = javascript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        tell application "Google Chrome"
            if not running then return "NO_WA"
            if (count of windows) is 0 then return "NO_WA"
            set fallbackResult to "NO_WA"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "web.whatsapp.com" then
                        set jsResult to execute t javascript "\(escapedJS)"
                        if jsResult begins with "ACTIVE_PAGE|||" then return jsResult
                        set fallbackResult to jsResult
                    end if
                end repeat
            end repeat
            return fallbackResult
        end tell
        """.replacingOccurrences(
            of: "CHROME_FRONTMOST",
            with: chromeIsFrontmost ? "true" : "false"
        )
    }

    static func checkState(
        chromeIsFrontmost: Bool = false,
        completion: @MainActor @Sendable @escaping (WhatsAppState?) -> Void
    ) {
        let script = pollingAppleScript(chromeIsFrontmost: chromeIsFrontmost)
        SystemVolume.runAppleScriptAsync(script) { output in
            // A failed AppleScript/Chrome poll is inconclusive. Do not clear the UI.
            completion(output.flatMap(parseOutput))
        }
    }

    static func runAction(_ javascript: String) {
        let escaped = javascript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let script = """
        tell application "Google Chrome"
            if not running then return
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "web.whatsapp.com" then
                        execute t javascript "\(escaped)"
                        return
                    end if
                end repeat
            end repeat
        end tell
        """

        SystemVolume.runAppleScriptAsync(script) { _ in }
    }

    static func acceptCall() {
        runAction("""
        (() => {
            const buttons = Array.from(document.querySelectorAll('button, [role="button"]'));
            const b = buttons.find(x => /accept|answer/i.test((x.innerText || '') + ' ' + (x.getAttribute('aria-label') || '')));
            if (b) b.click();
        })()
        """)
    }

    static func declineCall() {
        runAction("""
        (() => {
            const buttons = Array.from(document.querySelectorAll('button, [role="button"]'));
            const b = buttons.find(x => /decline|reject|end call/i.test((x.innerText || '') + ' ' + (x.getAttribute('aria-label') || '')));
            if (b) b.click();
        })()
        """)
    }

    static func toggleMute() {
        runAction("""
        (() => {
            const buttons = Array.from(document.querySelectorAll('button, [role="button"]'));
            const b = buttons.find(x => /mute/i.test((x.innerText || '') + ' ' + (x.getAttribute('aria-label') || '')));
            if (b) b.click();
        })()
        """)
    }
}

// MARK: - Physical MacBook Notch View

@MainActor
final class NotchView: NSView {
    static let clearAllFadeDuration: TimeInterval = 0.16

    // Use an explicit opaque sRGB zero so the notch surface never inherits a
    // dynamic system color or an alpha-tinted black from the current appearance.
    private static let pitchBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    var volume: Float = 0.5 { didSet { needsDisplay = true } }
    var volumeHUD = false { didSet { needsDisplay = true } }
    var volumeHUDOpacity: CGFloat = 0 { didSet { needsDisplay = true } }

    var mediaPlaying = false { didSet { needsDisplay = true } }
    var mediaTitle = "" { didSet { needsDisplay = true } }
    var mediaIsShort = false { didSet { needsDisplay = true } }
    var mediaPaused = true {
        didSet {
            if oldValue != mediaPaused { animatePlaybackGlyph(toPaused: mediaPaused) }
            needsDisplay = true
        }
    }
    private var mediaIconProgress: CGFloat = 0 // 0 = play glyph, 1 = pause glyph
    private var mediaIconAnimationTimer: Timer?
    private var mediaIconAnimationStart: CFTimeInterval = 0
    private var mediaIconAnimationFrom: CGFloat = 0
    private var mediaIconAnimationTo: CGFloat = 0
    var mediaCurrentTime: Double = 0 { didSet { needsDisplay = true } }
    var mediaDuration: Double = 0 { didSet { needsDisplay = true } }
    var mediaThumbnail: NSImage? { didSet { needsDisplay = true } }

    var expanded = false { didSet { needsDisplay = true } }
    var startupSplash = false { didSet { needsDisplay = true } }

    var appSwitchIcon: NSImage? { didSet { needsDisplay = true } }
    var appSwitchOpacity: CGFloat = 0 { didSet { needsDisplay = true } }
    var currentAppIcon: NSImage? { didSet { needsDisplay = true } }
    var previousCurrentAppIcon: NSImage? { didSet { needsDisplay = true } }
    var currentAppIconTransitionProgress: CGFloat = 1 { didSet { needsDisplay = true } }
    var incomingNotification: InboxMessage? { didSet { needsDisplay = true } }
    var incomingNotificationAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    var noNetworkAlertActive = false { didSet { needsDisplay = true } }
    var lowBatteryAlertPercent: Int? { didSet { needsDisplay = true } }
    var bluetoothAlertState: Bool? { didSet { needsDisplay = true } }
    var focusAlertState: Bool? { didSet { needsDisplay = true } }

    var systemTimerActive = false { didSet { needsDisplay = true } }
    var systemTimerText = "" { didSet { needsDisplay = true } }
    var chargingIndicatorActive = false { didSet { needsDisplay = true } }

    var currentTimeText = "" { didSet { needsDisplay = true } }
    var batteryPercent = 100 { didSet { needsDisplay = true } }
    var batteryIsCharging = false { didSet { needsDisplay = true } }
    var captureActivity = CaptureActivityState() { didSet { needsDisplay = true } }

    var whatsAppCallActive = false { didSet { needsDisplay = true } }
    var whatsAppInCall = false { didSet { needsDisplay = true } }
    var whatsAppCallerName = "WhatsApp Web Call" { didSet { needsDisplay = true } }
    var whatsAppCallTypeLabel = "Incoming Call" { didSet { needsDisplay = true } }
    var whatsAppCallDurationSeconds = 0 { didSet { needsDisplay = true } }
    var whatsAppIsMuted = false { didSet { needsDisplay = true } }

    var whatsAppMessageActive = false { didSet { needsDisplay = true } }
    var whatsAppMessages: [WhatsAppMessageItem] = [] { didSet { needsDisplay = true } }
    var whatsAppAvatarImages: [String: NSImage] = [:] { didSet { needsDisplay = true } }
    var whatsAppOverflowCount = 0 { didSet { needsDisplay = true } }

    var onToggleExpanded: (@MainActor () -> Void)?
    var onDeveloperModeClick: (@MainActor (_ shiftHeld: Bool) -> Void)?
    var onControlClickLock: (@MainActor () -> Void)?
    var onAcceptWhatsAppCall: (@MainActor () -> Void)?
    var onDeclineWhatsAppCall: (@MainActor () -> Void)?
    var onToggleWhatsAppMute: (@MainActor () -> Void)?
    var onMediaPlayPause: (@MainActor () -> Void)?
    var onMediaSeek: (@MainActor (Double) -> Void)?
    var onClearIncomingMessages: (@MainActor () -> Void)?
    var onMirrorToggleExpanded: (@MainActor () -> Void)?
    var isMirror = false
    private var screenSafeAreaTop: CGFloat { window?.screen?.safeAreaInsets.top ?? 0 }

    func copyVisualState(from source: NotchView) {
        if volume != source.volume { volume = source.volume }
        if volumeHUD != source.volumeHUD { volumeHUD = source.volumeHUD }
        if volumeHUDOpacity != source.volumeHUDOpacity { volumeHUDOpacity = source.volumeHUDOpacity }
        if mediaPlaying != source.mediaPlaying { mediaPlaying = source.mediaPlaying }
        if mediaTitle != source.mediaTitle { mediaTitle = source.mediaTitle }
        if mediaIsShort != source.mediaIsShort { mediaIsShort = source.mediaIsShort }
        if mediaPaused != source.mediaPaused { mediaPaused = source.mediaPaused }
        if mediaCurrentTime != source.mediaCurrentTime { mediaCurrentTime = source.mediaCurrentTime }
        if mediaDuration != source.mediaDuration { mediaDuration = source.mediaDuration }
        if mediaThumbnail !== source.mediaThumbnail { mediaThumbnail = source.mediaThumbnail }
        if expanded != source.expanded { expanded = source.expanded }
        if startupSplash != source.startupSplash { startupSplash = source.startupSplash }
        if appSwitchIcon !== source.appSwitchIcon { appSwitchIcon = source.appSwitchIcon }
        if appSwitchOpacity != source.appSwitchOpacity { appSwitchOpacity = source.appSwitchOpacity }
        if currentAppIcon !== source.currentAppIcon { currentAppIcon = source.currentAppIcon }
        if previousCurrentAppIcon !== source.previousCurrentAppIcon { previousCurrentAppIcon = source.previousCurrentAppIcon }
        if currentAppIconTransitionProgress != source.currentAppIconTransitionProgress { currentAppIconTransitionProgress = source.currentAppIconTransitionProgress }
        if incomingNotification != source.incomingNotification { incomingNotification = source.incomingNotification }
        if incomingNotificationAlpha != source.incomingNotificationAlpha { incomingNotificationAlpha = source.incomingNotificationAlpha }
        if noNetworkAlertActive != source.noNetworkAlertActive { noNetworkAlertActive = source.noNetworkAlertActive }
        if lowBatteryAlertPercent != source.lowBatteryAlertPercent { lowBatteryAlertPercent = source.lowBatteryAlertPercent }
        if bluetoothAlertState != source.bluetoothAlertState { bluetoothAlertState = source.bluetoothAlertState }
        if focusAlertState != source.focusAlertState { focusAlertState = source.focusAlertState }
        if systemTimerActive != source.systemTimerActive { systemTimerActive = source.systemTimerActive }
        if systemTimerText != source.systemTimerText { systemTimerText = source.systemTimerText }
        if chargingIndicatorActive != source.chargingIndicatorActive { chargingIndicatorActive = source.chargingIndicatorActive }
        if currentTimeText != source.currentTimeText { currentTimeText = source.currentTimeText }
        if batteryPercent != source.batteryPercent { batteryPercent = source.batteryPercent }
        if batteryIsCharging != source.batteryIsCharging { batteryIsCharging = source.batteryIsCharging }
        if captureActivity != source.captureActivity { captureActivity = source.captureActivity }
        if whatsAppCallActive != source.whatsAppCallActive { whatsAppCallActive = source.whatsAppCallActive }
        if whatsAppInCall != source.whatsAppInCall { whatsAppInCall = source.whatsAppInCall }
        if whatsAppCallerName != source.whatsAppCallerName { whatsAppCallerName = source.whatsAppCallerName }
        if whatsAppCallTypeLabel != source.whatsAppCallTypeLabel { whatsAppCallTypeLabel = source.whatsAppCallTypeLabel }
        if whatsAppCallDurationSeconds != source.whatsAppCallDurationSeconds { whatsAppCallDurationSeconds = source.whatsAppCallDurationSeconds }
        if whatsAppIsMuted != source.whatsAppIsMuted { whatsAppIsMuted = source.whatsAppIsMuted }
        if whatsAppMessageActive != source.whatsAppMessageActive { whatsAppMessageActive = source.whatsAppMessageActive }
        if whatsAppMessages != source.whatsAppMessages { whatsAppMessages = source.whatsAppMessages }
        let avatarImagesDiffer = whatsAppAvatarImages.count != source.whatsAppAvatarImages.count
            || whatsAppAvatarImages.contains { key, image in source.whatsAppAvatarImages[key] !== image }
        if avatarImagesDiffer { whatsAppAvatarImages = source.whatsAppAvatarImages }
        if whatsAppOverflowCount != source.whatsAppOverflowCount { whatsAppOverflowCount = source.whatsAppOverflowCount }
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard Self.shouldReceivePointer(at: localPoint, in: bounds),
              notchPath(in: bounds).contains(localPoint) else { return nil }
        return super.hitTest(point)
    }

    static func shouldReceivePointer(at point: NSPoint, in bounds: NSRect) -> Bool {
        bounds.contains(point)
    }

    static func shouldAcceptPointer(
        at point: NSPoint,
        in bounds: NSRect,
        safeAreaTop: CGFloat,
        extraHitTargets: [NSRect] = []
    ) -> Bool {
        let notchHeight = min(bounds.height, max(34, safeAreaTop))
        let physicalNotch = NSRect(
            x: bounds.midX - 105,
            y: bounds.maxY - notchHeight,
            width: 210,
            height: notchHeight
        )
        return physicalNotch.contains(point) || extraHitTargets.contains(where: { $0.contains(point) })
    }

    func shouldAcceptPointer(at point: NSPoint) -> Bool {
        var extraTargets: [NSRect] = []
        if incomingNotification != nil { extraTargets.append(clearAllRect(in: bounds)) }
        if mediaPlaying && expanded {
            extraTargets.append(Self.mediaPlayControlRect(in: bounds))
            extraTargets.append(Self.mediaBackControlRect(in: bounds))
            extraTargets.append(Self.mediaForwardControlRect(in: bounds))
        }
        if whatsAppInCall {
            extraTargets.append(NSRect(x: bounds.maxX - 104, y: bounds.midY - 9, width: 44, height: 18))
            extraTargets.append(NSRect(x: bounds.maxX - 54, y: bounds.midY - 9, width: 44, height: 18))
        }
        if whatsAppCallActive {
            extraTargets.append(NSRect(x: bounds.maxX - 110, y: bounds.midY - 9, width: 48, height: 18))
            extraTargets.append(NSRect(x: bounds.maxX - 56, y: bounds.midY - 9, width: 48, height: 18))
        }
        return Self.shouldAcceptPointer(
            at: point,
            in: bounds,
            safeAreaTop: screenSafeAreaTop,
            extraHitTargets: extraTargets
        )
    }

    private func notchPath(
        in bounds: NSRect,
        cornerRadius: CGFloat = 18
    ) -> NSBezierPath {
        // Keep the top edge square and flush with the physical display edge.
        // Only the lower corners round as the notch body expands downward.
        let r = min(cornerRadius, min(bounds.width / 2, bounds.height / 2))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.height))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height))
        path.line(to: NSPoint(x: bounds.width, y: r))
        path.curve(
            to: NSPoint(x: bounds.width - r, y: 0),
            controlPoint1: NSPoint(x: bounds.width, y: r * 0.42),
            controlPoint2: NSPoint(x: bounds.width - r * 0.42, y: 0)
        )
        path.line(to: NSPoint(x: r, y: 0))
        path.curve(
            to: NSPoint(x: 0, y: r),
            controlPoint1: NSPoint(x: r * 0.42, y: 0),
            controlPoint2: NSPoint(x: 0, y: r * 0.42)
        )
        path.close()
        return path
    }

    /// Paint the surface directly into the backing context with opaque sRGB
    /// zero, bypassing dynamic colors and alpha-based compositing entirely.
    private func fillPitchBlack(_ path: NSBezierPath) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(Self.pitchBlack.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.restoreGState()
    }

    private func drawText(
        _ string: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight = .medium,
        color: NSColor = .white
    ) {
        NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color
            ]
        ).draw(at: NSPoint(x: x, y: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current?.cgContext
        let bounds = self.bounds

        if noNetworkAlertActive {
            drawNoNetworkAlert(in: bounds)
            return
        }

        if let lowBatteryAlertPercent {
            drawLowBatteryAlert(lowBatteryAlertPercent, in: bounds)
            return
        }

        if let bluetoothAlertState {
            drawBluetoothAlert(bluetoothAlertState, in: bounds)
            return
        }

        if let focusAlertState {
            drawFocusAlert(focusAlertState, in: bounds)
            return
        }

        if let incomingNotification {
            context?.saveGState()
            context?.setAlpha(incomingNotificationAlpha)
            drawInboxNotification(incomingNotification, in: bounds)
            context?.restoreGState()
            return
        }

        if whatsAppMessageActive {
            drawConnectedWhatsAppCard(in: bounds)
            return
        }

        fillPitchBlack(notchPath(in: bounds))

        if whatsAppInCall {
            drawWhatsAppInCall(in: bounds)
            return
        }
        if whatsAppCallActive {
            drawWhatsAppIncomingCall(in: bounds)
            return
        }

        let switchingApp = appSwitchIcon != nil && appSwitchOpacity > 0
        let showingVolume = volumeHUD || volumeHUDOpacity > 0.001
        if switchingApp {
            let context = NSGraphicsContext.current?.cgContext
            if startupSplash {
                context?.saveGState()
                context?.setAlpha(1 - min(1, max(0, appSwitchOpacity)))
                drawStartupLogo(in: bounds)
                context?.restoreGState()
            } else if showingVolume {
                let transitionOpacity = 1 - min(1, max(0, appSwitchOpacity))
                context?.saveGState()
                context?.setAlpha(transitionOpacity * (1 - min(1, max(0, volumeHUDOpacity))))
                drawUnderlyingState(in: bounds)
                context?.restoreGState()
                context?.saveGState()
                context?.setAlpha(transitionOpacity * min(1, max(0, volumeHUDOpacity)))
                drawVolume(in: bounds)
                context?.restoreGState()
            } else {
                context?.saveGState()
                context?.setAlpha(1 - min(1, max(0, appSwitchOpacity)))
                drawUnderlyingState(in: bounds)
                context?.restoreGState()
            }
            drawAppSwitch(in: bounds)
            return
        }

        if startupSplash {
            drawStartupLogo(in: bounds)
            if captureActivity.hasActivity { drawCaptureIndicators(in: bounds, expandedMedia: false) }
            return
        }

        if showingVolume {
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(1 - min(1, max(0, volumeHUDOpacity)))
            drawUnderlyingState(in: bounds)
            context?.restoreGState()

            context?.saveGState()
            context?.setAlpha(min(1, max(0, volumeHUDOpacity)))
            drawVolume(in: bounds)
            context?.restoreGState()
            return
        }

        drawUnderlyingState(in: bounds)
        if captureActivity.hasActivity {
            drawCaptureIndicators(in: bounds, expandedMedia: expanded && mediaPlaying)
        }
    }

    private func drawNoNetworkAlert(in bounds: NSRect) {
        fillPitchBlack(notchPath(in: bounds, cornerRadius: 22))
        let safeTop = screenSafeAreaTop
        let visibleHeight = max(0, bounds.height - safeTop)
        guard let symbol = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: "No network") else { return }
        let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [NSColor.systemRed])
        let icon = symbol.withSymbolConfiguration(sizeConfiguration.applying(colorConfiguration)) ?? symbol
        icon.draw(in: NSRect(x: bounds.midX - 19, y: max(0, (visibleHeight - 38) / 2), width: 38, height: 38))
    }

    private func drawLowBatteryAlert(_ percent: Int, in bounds: NSRect) {
        fillPitchBlack(notchPath(in: bounds))
        let y = bounds.midY - 6
        drawText("\(percent)%", x: 15, y: y, size: 10, weight: .bold, color: .systemRed)
        drawText("Low Battery", x: bounds.maxX - 82, y: y, size: 10, weight: .bold, color: .systemRed)
    }

    private func drawBluetoothAlert(_ isPoweredOn: Bool, in bounds: NSRect) {
        fillPitchBlack(notchPath(in: bounds))

        let wingWidth = max(0, (bounds.width - SystemBluetooth.physicalNotchWidth) / 2)
        let iconCenterX = wingWidth / 2
        let iconRect = NSRect(x: iconCenterX - 10, y: bounds.midY - 10, width: 20, height: 20)
        let bluetooth = NSBezierPath()
        bluetooth.lineWidth = 2.1
        bluetooth.lineCapStyle = .round
        bluetooth.lineJoinStyle = .round
        let center = iconRect.midX
        bluetooth.move(to: NSPoint(x: center, y: iconRect.minY + 1))
        bluetooth.line(to: NSPoint(x: center, y: iconRect.maxY - 1))
        bluetooth.move(to: NSPoint(x: center, y: iconRect.maxY - 1))
        bluetooth.line(to: NSPoint(x: iconRect.maxX - 1, y: iconRect.midY + 4))
        bluetooth.line(to: NSPoint(x: center, y: iconRect.midY))
        bluetooth.line(to: NSPoint(x: iconRect.maxX - 1, y: iconRect.midY - 4))
        bluetooth.line(to: NSPoint(x: center, y: iconRect.minY + 1))
        bluetooth.move(to: NSPoint(x: iconRect.minX + 1, y: iconRect.midY + 6))
        bluetooth.line(to: NSPoint(x: iconRect.maxX - 1, y: iconRect.midY - 6))
        bluetooth.move(to: NSPoint(x: iconRect.minX + 1, y: iconRect.midY - 6))
        bluetooth.line(to: NSPoint(x: iconRect.maxX - 1, y: iconRect.midY + 6))
        (isPoweredOn ? NSColor.systemBlue : NSColor(white: 0.60, alpha: 1)).setStroke()
        bluetooth.stroke()
        if !isPoweredOn {
            let slash = NSBezierPath()
            slash.lineWidth = 1.8
            slash.move(to: NSPoint(x: iconRect.minX + 2, y: iconRect.minY + 2))
            slash.line(to: NSPoint(x: iconRect.maxX - 2, y: iconRect.maxY - 2))
            NSColor(white: 0.60, alpha: 1).setStroke()
            slash.stroke()
        }

        drawSystemAlertSideLabel(
            isPoweredOn ? "BT On" : "BT Off",
            x: bounds.width - wingWidth,
            width: wingWidth,
            y: bounds.midY - 5,
            color: isPoweredOn ? .white : NSColor(white: 0.78, alpha: 1)
        )
    }

    private func drawFocusAlert(_ isFocused: Bool, in bounds: NSRect) {
        fillPitchBlack(notchPath(in: bounds))

        guard let moon = NSImage(
            systemSymbolName: "moon.fill",
            accessibilityDescription: isFocused ? "Do Not Disturb on" : "Do Not Disturb off"
        ) else { return }
        let wingWidth = max(0, (bounds.width - SystemBluetooth.physicalNotchWidth) / 2)
        let iconRect = NSRect(x: wingWidth / 2 - 10, y: bounds.midY - 10, width: 20, height: 20)
        let tint = NSColor.systemPurple
        (moon.withSymbolConfiguration(.init(paletteColors: [tint])) ?? moon).draw(in: iconRect)
        if !isFocused {
            let slash = NSBezierPath()
            slash.lineWidth = 2
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: iconRect.minX + 2, y: iconRect.minY + 2))
            slash.line(to: NSPoint(x: iconRect.maxX - 2, y: iconRect.maxY - 2))
            tint.setStroke()
            slash.stroke()
        }
        drawSystemAlertSideLabel(
            isFocused ? "DND On" : "DND Off",
            x: bounds.width - wingWidth,
            width: wingWidth,
            y: bounds.midY - 5,
            color: tint
        )
    }

    private func drawSystemAlertSideLabel(
        _ text: String,
        x: CGFloat,
        width: CGFloat,
        y: CGFloat,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        string.draw(in: NSRect(x: x + 2, y: y, width: max(0, width - 4), height: 14))
    }

    private func drawUnderlyingState(in bounds: NSRect) {
        if expanded {
            if mediaPlaying {
                // Fade the media controls in as the notch grows back to full size.
                // This avoids a sudden pop-in at the final frame of the resize.
                let reveal = min(1, max(0, (bounds.height - 72) / 146))
                guard reveal > 0 else { return }
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState()
                context?.setAlpha(reveal)
                drawMediaPanel(in: bounds)
                context?.restoreGState()
            } else {
                drawExpandedInfo(in: bounds)
            }
            return
        }

        if chargingIndicatorActive {
            drawChargingIndicator(in: bounds)
            return
        }
        if mediaPlaying {
            drawMedia(in: bounds)
            return
        }
        if systemTimerActive {
            drawSystemTimer(in: bounds)
        }
    }

    private func drawInboxNotification(_ message: InboxMessage, in bounds: NSRect) {
        fillPitchBlack(notchPath(in: bounds, cornerRadius: 22))

        // The physical notch covers the top safe-area strip of this window.
        // Lay out all message text in the visible body below that strip.
        let safeTop = screenSafeAreaTop
        let visibleHeight = max(0, bounds.height - safeTop)

        let isGmail = message.service == "Gmail"
        if let logo = InboxNotifications.brandLogo(for: message.service) {
            logo.draw(in: NSRect(x: 20, y: max(0, (visibleHeight - 30) / 2), width: 30, height: 30),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let left: CGFloat = 60
        let width = max(80, bounds.width - left - 92)
        let header = isGmail ? "GMAIL  ·  TO  \(message.account)" : "WHATSAPP"
        drawNotificationText(header, in: NSRect(x: left, y: visibleHeight - 17, width: width, height: 13), size: 9, weight: .semibold, color: NSColor(white: 0.68, alpha: 1))

        let title = isGmail ? message.subject : message.sender
        drawNotificationText(title.isEmpty ? "New message" : title, in: NSRect(x: left, y: visibleHeight - 38, width: width, height: 17), size: 13, weight: .bold, color: .white)

        let sender = isGmail
            ? (message.senderEmail.isEmpty ? message.sender : "From  \(message.sender)  <\(message.senderEmail)>")
            : message.preview
        drawNotificationText(sender, in: NSRect(x: left, y: visibleHeight - 59, width: width, height: 14), size: 10, weight: .medium, color: NSColor(white: 0.86, alpha: 1))

        if isGmail, !message.preview.isEmpty {
            drawNotificationText(message.preview, in: NSRect(x: left, y: 2, width: width, height: 12), size: 9, weight: .regular, color: NSColor(white: 0.62, alpha: 1))
        }

        let clearRect = clearAllRect(in: bounds)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: clearRect, xRadius: 8, yRadius: 8).fill()
        drawCenteredNotificationText("Clear all", in: clearRect, size: 9, weight: .semibold, color: NSColor(white: 0.82, alpha: 1))
    }

    private func clearAllRect(in bounds: NSRect) -> NSRect {
        let visibleHeight = max(0, bounds.height - screenSafeAreaTop)
        return Self.inboxClearAllRect(in: bounds, visibleHeight: visibleHeight)
    }

    static func inboxClearAllRect(in bounds: NSRect, visibleHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.maxX - 78, y: visibleHeight - 25, width: 64, height: 19)
    }

    static func idlePanelHeight(safeAreaTop: CGFloat) -> CGFloat {
        max(34, safeAreaTop)
    }

    static func notchFrame(in displayFrame: NSRect, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: displayFrame.midX - width / 2,
            y: displayFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private func drawNotificationText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]).draw(in: rect)
    }

    private func drawCenteredNotificationText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ])
        let textSize = attributed.size()
        attributed.draw(at: Self.centeredTextOrigin(textSize, in: rect))
    }

    static func centeredTextOrigin(_ textSize: NSSize, in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
    }

    private func drawStartupLogo(in bounds: NSRect) {
        // The physical Mac notch occludes the top-center of the screen. Keep the
        // logo in the visible body beneath that cutout instead of centering it
        // across the entire splash window.
        let logoFont = NSFont(name: "Apple Symbols", size: 50) ?? NSFont.systemFont(ofSize: 50, weight: .regular)
        let logo = NSAttributedString(string: "", attributes: [
            .font: logoFont,
            .foregroundColor: NSColor.white
        ])
        let measured = logo.size()
        let safeTop = screenSafeAreaTop
        let visibleBodyHeight = max(40, bounds.height - safeTop)
        let origin = NSPoint(
            x: bounds.midX - measured.width / 2,
            y: max(8, visibleBodyHeight / 2 - measured.height / 2)
        )
        logo.draw(at: origin)

        let subtitle = NSAttributedString(string: "NotchOS 2.4", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1)
        ])
        subtitle.draw(at: NSPoint(
            x: bounds.midX - subtitle.size().width / 2,
            y: max(1, origin.y - subtitle.size().height - 1)
        ))
    }

    // MARK: Connected WhatsApp Notification

    // A compact notch silhouette that smoothly widens into the notification card.
    // The top remains flush with the physical screen edge; only the lower body grows.
    private func drawConnectedWhatsAppCard(in bounds: NSRect) {
        let width = bounds.width
        let height = bounds.height
        // Dynamic Notch silhouette: the entire top edge is a perfectly
        // straight, full-width edge so the black shape blends into the
        // MacBook's top screen border. Only the bottom corners are rounded.
        let bottomRadius: CGFloat = 18
        let path = NSBezierPath()

        // Flush, square top edge: this is the part that must merge into the
        // display's top border. Do not round or inset either top corner.
        path.move(to: NSPoint(x: 0, y: height))
        path.line(to: NSPoint(x: width, y: height))
        path.line(to: NSPoint(x: width, y: bottomRadius))
        path.curve(
            to: NSPoint(x: width - bottomRadius, y: 0),
            controlPoint1: NSPoint(x: width, y: bottomRadius * 0.42),
            controlPoint2: NSPoint(x: width - bottomRadius * 0.42, y: 0)
        )
        path.line(to: NSPoint(x: bottomRadius, y: 0))
        path.curve(
            to: NSPoint(x: 0, y: bottomRadius),
            controlPoint1: NSPoint(x: bottomRadius * 0.42, y: 0),
            controlPoint2: NSPoint(x: 0, y: bottomRadius * 0.42)
        )
        path.line(to: NSPoint(x: 0, y: height))
        path.close()
        fillPitchBlack(path)

        let messages = Array(whatsAppMessages.prefix(4))
        guard !messages.isEmpty else { return }
        let rowStep: CGFloat = 38
        // A single notification is compact. Additional rows stack upward
        // while the top edge remains attached to the physical notch.
        let safeTop = screenSafeAreaTop
        let firstCenterY = Self.whatsAppFirstRowCenterY(in: bounds, safeTop: safeTop)

        for (index, message) in messages.enumerated() {
            let centerY = firstCenterY - CGFloat(index) * rowStep
            let avatarSize: CGFloat = 32
            let avatarRect = NSRect(x: 17, y: centerY - avatarSize / 2, width: avatarSize, height: avatarSize)
            if let avatar = whatsAppAvatarImages[message.avatarURL] {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: avatarRect).addClip()
                avatar.draw(in: avatarRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor(white: 0.24, alpha: 1).setFill()
                NSBezierPath(ovalIn: avatarRect).fill()
                let initial = String(message.name.first ?? "W").uppercased()
                let attr = NSAttributedString(string: initial, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.white
                ])
                let size = attr.size()
                attr.draw(at: NSPoint(x: avatarRect.midX - size.width / 2, y: avatarRect.midY - size.height / 2))
            }

            let textX = avatarRect.maxX + 11
            let logoRect = NSRect(x: width - 26, y: centerY - 8, width: 16, height: 16)
            InboxNotifications.brandLogo(for: "WhatsApp")?.draw(
                in: logoRect, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil
            )
            let textWidth = max(CGFloat(40), width - textX - 36)
            NSAttributedString(string: message.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
                .foregroundColor: NSColor.white
            ]).draw(with: NSRect(x: textX, y: centerY + 1, width: textWidth, height: 17),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSAttributedString(string: message.preview, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white
            ]).draw(with: NSRect(x: textX, y: centerY - 13, width: textWidth, height: 14),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if whatsAppOverflowCount > 0 {
            let overflow = "+\(whatsAppOverflowCount) more"
            NSAttributedString(string: overflow, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(white: 0.65, alpha: 1)
            ]).draw(at: NSPoint(x: width - 60, y: 8))
        }
    }

    // MARK: Incoming Call

    private func drawWhatsAppIncomingCall(in bounds: NSRect) {
        let y = bounds.midY - 6

        drawText("📞", x: 14, y: y, size: 12, color: .systemGreen)
        drawText(whatsAppCallTypeLabel, x: 34, y: y + 13, size: 8, color: NSColor.secondaryLabelColor)

        NSAttributedString(
            string: whatsAppCallerName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
        ).draw(
            with: NSRect(x: 34, y: y, width: 140, height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )

        let accept = NSRect(
            x: bounds.maxX - 110,
            y: bounds.midY - 9,
            width: 48,
            height: 18
        )

        NSColor.systemGreen.setFill()
        NSBezierPath(
            roundedRect: accept,
            xRadius: 9,
            yRadius: 9
        ).fill()

        drawText(
            "Accept",
            x: bounds.maxX - 105,
            y: y - 1,
            size: 9,
            weight: .bold
        )

        let decline = NSRect(
            x: bounds.maxX - 56,
            y: bounds.midY - 9,
            width: 48,
            height: 18
        )

        NSColor.systemRed.setFill()
        NSBezierPath(
            roundedRect: decline,
            xRadius: 9,
            yRadius: 9
        ).fill()

        drawText(
            "Decline",
            x: bounds.maxX - 52,
            y: y - 1,
            size: 9,
            weight: .bold
        )
    }

    // MARK: Active Call

    private func drawWhatsAppInCall(in bounds: NSRect) {
        let y = bounds.midY - 6

        let duration = String(
            format: "%02d:%02d",
            whatsAppCallDurationSeconds / 60,
            whatsAppCallDurationSeconds % 60
        )

        drawText("🟢", x: 12, y: y, size: 10, color: .systemGreen)
        drawText(
            duration,
            x: 28,
            y: y,
            size: 10,
            weight: .bold,
            color: .systemGreen
        )

        NSAttributedString(
            string: whatsAppCallerName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        ).draw(
            with: NSRect(x: 75, y: y, width: 100, height: 14),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )

        let mute = NSRect(
            x: bounds.maxX - 104,
            y: bounds.midY - 9,
            width: 44,
            height: 18
        )

        (whatsAppIsMuted
            ? NSColor.systemOrange
            : NSColor(white: 0.25, alpha: 1)
        ).setFill()

        NSBezierPath(
            roundedRect: mute,
            xRadius: 9,
            yRadius: 9
        ).fill()

        drawText(
            whatsAppIsMuted ? "Unmute" : "Mute",
            x: bounds.maxX - (whatsAppIsMuted ? 102 : 96),
            y: y - 1,
            size: 9,
            weight: .bold
        )

        let end = NSRect(
            x: bounds.maxX - 54,
            y: bounds.midY - 9,
            width: 44,
            height: 18
        )

        NSColor.systemRed.setFill()
        NSBezierPath(
            roundedRect: end,
            xRadius: 9,
            yRadius: 9
        ).fill()

        drawText(
            "End",
            x: bounds.maxX - 42,
            y: y - 1,
            size: 9,
            weight: .bold
        )
    }

    // MARK: Expanded Info

    private func drawExpandedInfo(in bounds: NSRect) {
        let y = bounds.midY - 6
        let timeSize = NSAttributedString(string: currentTimeText, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold)
        ]).size()
        drawText(
            currentTimeText,
            x: 16,
            y: y,
            size: 11,
            weight: .bold
        )

        drawCurrentAppIcon(in: Self.expandedAppIconRect(timeWidth: timeSize.width, baselineY: y))

        drawText(
            "\(batteryPercent)% \(batteryIsCharging ? "⚡️" : "🔋")",
            x: bounds.maxX - 68,
            y: y,
            size: 11,
            weight: .bold
        )
    }

    // MARK: Charging Indicator

    private func drawChargingIndicator(in bounds: NSRect) {
        let y = bounds.midY - 6
        drawText("Battery", x: 14, y: y, size: 10, color: NSColor(white: 0.78, alpha: 1))
        drawText("\(batteryPercent)% ⚡", x: bounds.maxX - 78, y: y, size: 11, weight: .bold, color: .systemGreen)
    }

    // MARK: Volume

    private func drawVolume(in bounds: NSRect) {
        let y = bounds.midY - 7

        drawText(
            volume > 0.01 ? "🔊" : "🔈",
            x: 12,
            y: y,
            size: 11
        )

        let barWidth: CGFloat = 64
        let barHeight: CGFloat = 5
        let barX = bounds.maxX - barWidth - 16
        let barY = bounds.midY - barHeight / 2

        NSColor(white: 0.25, alpha: 1).setFill()

        NSBezierPath(
            roundedRect: NSRect(
                x: barX,
                y: barY,
                width: barWidth,
                height: barHeight
            ),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()

        if volume > 0 {
            NSColor.white.setFill()

            NSBezierPath(
                roundedRect: NSRect(
                    x: barX,
                    y: barY,
                    width: barWidth * CGFloat(volume),
                    height: barHeight
                ),
                xRadius: 2.5,
                yRadius: 2.5
            ).fill()
        }
    }

    // MARK: Media

    private func drawMedia(in bounds: NSRect) {
        let y = bounds.midY - 6
        let logo = NSRect(x: 13 + CGFloat(captureActivity.activeCount) * 24, y: y - 1, width: 22, height: 15)
        NSColor(calibratedRed: 1.0, green: 0.08, blue: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: logo, xRadius: 4, yRadius: 4).fill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: logo.minX + 8.5, y: logo.minY + 3.5))
        triangle.line(to: NSPoint(x: logo.minX + 8.5, y: logo.maxY - 3.5))
        triangle.line(to: NSPoint(x: logo.maxX - 5, y: logo.midY))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()

        guard !mediaPaused else { return }
        for index in 0..<4 {
            let barWidth: CGFloat = 3
            let gap: CGFloat = 3
            let total = 4 * barWidth + 3 * gap
            let startX = bounds.maxX - total - 16
            let wave = abs(sin(CACurrentMediaTime() * 5.0 + Double(index) * 0.85))
            let barHeight = CGFloat(4 + wave * 11)
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: bounds.midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            ), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func mediaTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func animatePlaybackGlyph(toPaused: Bool) {
        mediaIconAnimationTimer?.invalidate()
        mediaIconAnimationFrom = mediaIconProgress
        mediaIconAnimationTo = toPaused ? 0 : 1
        guard abs(mediaIconAnimationTo - mediaIconAnimationFrom) > 0.001 else { return }
        mediaIconAnimationStart = CACurrentMediaTime()
        mediaIconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let raw = min(1, max(0, (CACurrentMediaTime() - self.mediaIconAnimationStart) / 0.20))
                let eased = raw * raw * (3 - 2 * raw)
                self.mediaIconProgress = self.mediaIconAnimationFrom + (self.mediaIconAnimationTo - self.mediaIconAnimationFrom) * CGFloat(eased)
                self.needsDisplay = true
                if raw >= 1 {
                    self.mediaIconProgress = self.mediaIconAnimationTo
                    self.mediaIconAnimationTimer?.invalidate()
                    self.mediaIconAnimationTimer = nil
                }
            }
        }
    }

    private func drawPlaybackGlyph(in rect: NSRect, playing: Bool, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        NSColor.white.withAlphaComponent(alpha).setFill()
        if playing {
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 7, y: rect.midY - 10, width: 5, height: 20), xRadius: 1.4, yRadius: 1.4).fill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX + 2, y: rect.midY - 10, width: 5, height: 20), xRadius: 1.4, yRadius: 1.4).fill()
        } else {
            let play = NSBezierPath()
            play.move(to: NSPoint(x: rect.midX - 6, y: rect.midY - 10))
            play.line(to: NSPoint(x: rect.midX - 6, y: rect.midY + 10))
            play.line(to: NSPoint(x: rect.midX + 11, y: rect.midY))
            play.close()
            play.fill()
        }
    }

    private func drawMediaPanel(in bounds: NSRect) {
        let width = bounds.width
        let height = bounds.height

        // A restrained inset surface gives the controls a clear hierarchy while
        // preserving the black notch silhouette around it.
        let surface = NSRect(x: 7, y: 7, width: width - 14, height: height - 14)
        fillPitchBlack(NSBezierPath(roundedRect: surface, xRadius: 21, yRadius: 21))

        // Compact top metadata row, spaced away from the thumbnail/title row.
        drawText(currentTimeText, x: 19, y: height - 28, size: 10, weight: .semibold)
        let timeSize = NSAttributedString(string: currentTimeText, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold)
        ]).size()
        drawCurrentAppIcon(in: Self.mediaHeaderAppIconRect(timeWidth: timeSize.width, panelHeight: height))
        let batteryText = "\(batteryPercent)%"
        let batteryAttrs = NSAttributedString(string: batteryText, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        batteryAttrs.draw(at: NSPoint(x: width - 42, y: height - 28))
        if batteryIsCharging {
            drawText("ϟ", x: width - 22, y: height - 28, size: 10, weight: .bold, color: .systemGreen)
        }

        let thumbRect = NSRect(x: 18, y: height - 108, width: 62, height: 62)
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 14, yRadius: 14).fill()
        if let thumbnail = mediaThumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: thumbRect, xRadius: 14, yRadius: 14).addClip()
            let imageSize = thumbnail.size
            let targetAspect = thumbRect.width / thumbRect.height
            let imageAspect = imageSize.width / imageSize.height
            let sourceRect: NSRect
            if imageAspect > targetAspect {
                let sourceWidth = imageSize.height * targetAspect
                sourceRect = NSRect(x: (imageSize.width - sourceWidth) / 2, y: 0,
                                    width: sourceWidth, height: imageSize.height)
            } else {
                let sourceHeight = imageSize.width / targetAspect
                sourceRect = NSRect(x: 0, y: (imageSize.height - sourceHeight) / 2,
                                    width: imageSize.width, height: sourceHeight)
            }
            thumbnail.draw(in: thumbRect, from: sourceRect, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            drawText("▶", x: thumbRect.midX - 6, y: thumbRect.midY - 8, size: 18, weight: .bold)
        }

        let title = mediaTitle.isEmpty ? "YouTube video" : mediaTitle
        // Keep simultaneous camera and microphone marks clear of the title
        // instead of drawing them over the last line of text.
        let indicatorReserve = captureActivity.hasActivity
            ? CGFloat(captureActivity.activeCount) * 28
            : 0
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]).draw(with: NSRect(x: 94, y: height - 79, width: max(80, width - 116 - indicatorReserve), height: 42),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSAttributedString(string: "YouTube · Now playing", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(white: 0.58, alpha: 1)
        ]).draw(at: NSPoint(x: 94, y: height - 104))

        // A single rounded timeline sits between elapsed and remaining time.
        let progressRect = Self.mediaProgressRect(in: bounds)
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: progressRect, xRadius: progressRect.height / 2, yRadius: progressRect.height / 2).fill()
        let ratio = mediaDuration > 0 ? min(1, max(0, mediaCurrentTime / mediaDuration)) : 0
        if ratio > 0 {
            NSColor(calibratedRed: 0.39, green: 0.70, blue: 0.80, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: progressRect.minX, y: progressRect.minY,
                                             width: max(progressRect.height, progressRect.width * ratio),
                                             height: progressRect.height),
                         xRadius: progressRect.height / 2, yRadius: progressRect.height / 2).fill()
        }
        let elapsed = mediaTime(mediaCurrentTime)
        let remaining = "-\(mediaTime(max(0, mediaDuration - mediaCurrentTime)))"
        let timelineFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let timelineColor = NSColor(white: 0.64, alpha: 1)
        NSAttributedString(string: elapsed, attributes: [.font: timelineFont, .foregroundColor: timelineColor])
            .draw(at: NSPoint(x: 18, y: progressRect.midY - 6))
        let remainingText = NSAttributedString(string: remaining, attributes: [.font: timelineFont, .foregroundColor: timelineColor])
        remainingText.draw(at: NSPoint(x: width - 18 - remainingText.size().width, y: progressRect.midY - 6))

        let backRect = Self.mediaBackControlRect(in: bounds)
        let playButton = Self.mediaPlayControlRect(in: bounds)
        let forwardRect = Self.mediaForwardControlRect(in: bounds)
        drawSeekControl(in: backRect, backwards: true)
        drawPlaybackGlyph(in: playButton, playing: false, alpha: 1 - mediaIconProgress)
        drawPlaybackGlyph(in: playButton, playing: true, alpha: mediaIconProgress)
        drawSeekControl(in: forwardRect, backwards: false)
    }

    private func drawSeekControl(in rect: NSRect, backwards: Bool) {
        let centerX = rect.midX
        let centerY = rect.midY
        // Minimal skip glyph with a clear 10-second label, aligned to the same baseline.
        let direction = Self.mediaSeekArrowDirection(backwards: backwards)
        let symbol = NSBezierPath()
        symbol.lineWidth = 2.3
        symbol.lineCapStyle = .round
        symbol.lineJoinStyle = .round
        symbol.move(to: NSPoint(x: centerX + 4 * direction, y: centerY + 9))
        symbol.line(to: NSPoint(x: centerX - 8 * direction, y: centerY))
        symbol.line(to: NSPoint(x: centerX + 4 * direction, y: centerY - 9))
        symbol.move(to: NSPoint(x: centerX + 17 * direction, y: centerY + 9))
        symbol.line(to: NSPoint(x: centerX + 5 * direction, y: centerY))
        symbol.line(to: NSPoint(x: centerX + 17 * direction, y: centerY - 9))
        NSColor.white.setStroke()
        symbol.stroke()
        let ten = NSAttributedString(string: "10", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor(white: 0.60, alpha: 1)
        ])
        ten.draw(at: NSPoint(x: centerX - ten.size().width / 2, y: rect.minY - 1))
    }

    static func mediaProgressRect(in bounds: NSRect) -> NSRect {
        NSRect(x: 60, y: 80, width: max(0, bounds.width - 120), height: 7)
    }

    static func mediaBackControlRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.midX - 91, y: 8, width: 42, height: 42)
    }

    static func mediaPlayControlRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.midX - 22, y: 8, width: 44, height: 42)
    }

    static func mediaForwardControlRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.midX + 49, y: 8, width: 42, height: 42)
    }

    static func mediaSeekArrowDirection(backwards: Bool) -> CGFloat {
        backwards ? 1 : -1
    }

    static func expandedCaptureIndicatorRects(
        in bounds: NSRect,
        safeAreaTop: CGFloat,
        cameraInUse: Bool,
        microphoneInUse: Bool
    ) -> [(camera: Bool, rect: NSRect)] {
        let size: CGFloat = 16
        let centerY = max(8, bounds.height - safeAreaTop - size - 2) + size / 2
        var centerX = bounds.maxX - 20
        var placements: [(camera: Bool, rect: NSRect)] = []
        if microphoneInUse {
            placements.append((false, NSRect(x: centerX - 6, y: centerY - 8, width: 12, height: 16)))
            centerX -= 28
        }
        if cameraInUse {
            placements.append((true, NSRect(x: centerX - 9, y: centerY - 7.5, width: 18, height: 15)))
        }
        return placements
    }

    private func drawCaptureIndicators(in bounds: NSRect, expandedMedia: Bool) {
        var icons: [(camera: Bool, rect: NSRect)] = []
        func iconRect(camera: Bool, centerX: CGFloat, centerY: CGFloat) -> NSRect {
            let iconSize = camera ? NSSize(width: 18, height: 15) : NSSize(width: 12, height: 16)
            return NSRect(x: centerX - iconSize.width / 2, y: centerY - iconSize.height / 2,
                          width: iconSize.width, height: iconSize.height)
        }
        if expandedMedia {
            icons = Self.expandedCaptureIndicatorRects(
                in: bounds,
                safeAreaTop: screenSafeAreaTop,
                cameraInUse: captureActivity.cameraInUse,
                microphoneInUse: captureActivity.microphoneInUse
            )
        } else if mediaPlaying {
            var x: CGFloat = 22
            if captureActivity.cameraInUse {
                icons.append((true, iconRect(camera: true, centerX: x, centerY: bounds.midY)))
                x += 24
            }
            if captureActivity.microphoneInUse {
                icons.append((false, iconRect(camera: false, centerX: x, centerY: bounds.midY)))
            }
        } else if captureActivity.cameraInUse && captureActivity.microphoneInUse {
            icons.append((true, iconRect(camera: true, centerX: 20, centerY: bounds.midY)))
            icons.append((false, iconRect(camera: false, centerX: bounds.maxX - 20, centerY: bounds.midY)))
        } else {
            icons.append((captureActivity.cameraInUse,
                          iconRect(camera: captureActivity.cameraInUse,
                                   centerX: bounds.maxX - 16, centerY: bounds.midY)))
        }

        for icon in icons {
            if let image = SystemCaptureActivity.icon(camera: icon.camera) {
                image.draw(in: icon.rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else if let symbol = NSImage(systemSymbolName: icon.camera ? "camera.fill" : "mic.fill",
                                           accessibilityDescription: icon.camera ? "Camera in use" : "Microphone in use") {
                symbol.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))?.draw(in: icon.rect)
            }
        }
    }

    // MARK: System Timer

    private func drawSystemTimer(in bounds: NSRect) {
        let y = bounds.midY - 6

        drawText("⏱", x: 14, y: y, size: 11, color: .systemOrange)

        drawText(
            systemTimerText,
            x: 32,
            y: y,
            size: 11,
            weight: .bold,
            color: .systemOrange
        )
    }

    // MARK: App Switch

    private func drawCurrentAppIcon(in rect: NSRect) {
        let sourceRect = NSRect(origin: .zero, size: currentAppIcon?.size ?? rect.size)
        if let previousCurrentAppIcon, currentAppIconTransitionProgress < 1 {
            previousCurrentAppIcon.draw(
                in: rect, from: NSRect(origin: .zero, size: previousCurrentAppIcon.size),
                operation: .sourceOver, fraction: 1 - currentAppIconTransitionProgress,
                respectFlipped: true, hints: nil
            )
        }
        currentAppIcon?.draw(
            in: rect, from: sourceRect, operation: .sourceOver,
            fraction: currentAppIcon == nil ? 0 : currentAppIconTransitionProgress,
            respectFlipped: true, hints: nil
        )
    }

    private func drawAppSwitch(in bounds: NSRect) {
        guard let icon = appSwitchIcon else { return }

        let iconRect = Self.appSwitchIconRect(in: bounds, baseNotchWidth: 210)
        let sourceRect = NSRect(origin: .zero, size: icon.size)
        icon.draw(
            in: iconRect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: min(1, max(0, appSwitchOpacity)),
            respectFlipped: true,
            hints: nil
        )
    }

    static func appSwitchIconRect(in bounds: NSRect, baseNotchWidth: CGFloat) -> NSRect {
        let iconSize = min(27, max(16, bounds.height - 6))
        let wingWidth = max(0, (bounds.width - baseNotchWidth) / 2)
        return NSRect(
            x: bounds.midX - baseNotchWidth / 2 - (wingWidth + iconSize) / 2,
            y: (bounds.height - iconSize) / 2 + 2,
            width: iconSize,
            height: iconSize
        )
    }

    static func shouldKeepExpandedShapeOnAppSwitch(isExpanded: Bool) -> Bool {
        isExpanded
    }

    static func expandedAppIconRect(timeWidth: CGFloat, baselineY: CGFloat) -> NSRect {
        NSRect(x: 16 + timeWidth + 9, y: baselineY - 1, width: 16, height: 16)
    }

    static func mediaHeaderAppIconRect(timeWidth: CGFloat, panelHeight: CGFloat) -> NSRect {
        NSRect(x: 19 + timeWidth + 8, y: panelHeight - 29, width: 15, height: 15)
    }

    static func appSwitchOpacity(after elapsed: TimeInterval, expansionDuration: TimeInterval) -> CGFloat {
        let fadeInDuration: TimeInterval = 0.16
        let holdUntil: TimeInterval = 1.08
        let totalDuration: TimeInterval = 1.42

        guard elapsed > expansionDuration else { return 0 }
        if elapsed < expansionDuration + fadeInDuration {
            let progress = (elapsed - expansionDuration) / fadeInDuration
            return CGFloat(progress * progress * (3 - 2 * progress))
        }
        if elapsed < holdUntil { return 1 }
        return CGFloat(max(0, 1 - (elapsed - holdUntil) / (totalDuration - holdUntil)))
    }

    static func whatsAppFirstRowCenterY(in bounds: NSRect, safeTop: CGFloat) -> CGFloat {
        max(0, bounds.height - safeTop - 24)
    }

    // MARK: Mouse Interaction

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds
        let loc = viewPoint
        guard bounds.contains(loc) else { return }

        if event.modifierFlags.contains(.option) {
            onDeveloperModeClick?(event.modifierFlags.contains(.shift))
            return
        }

        if event.modifierFlags.contains(.control) {
            onControlClickLock?()
            return
        }

        if incomingNotification != nil,
           clearAllRect(in: bounds).contains(loc) {
            onClearIncomingMessages?()
            return
        }

        if whatsAppInCall {
            let mute = NSRect(
                x: bounds.maxX - 104,
                y: bounds.midY - 9,
                width: 44,
                height: 18
            )

            let end = NSRect(
                x: bounds.maxX - 54,
                y: bounds.midY - 9,
                width: 44,
                height: 18
            )

            if mute.contains(loc) {
                onToggleWhatsAppMute?()
                return
            } else if end.contains(loc) {
                onDeclineWhatsAppCall?()
                return
            }
        }

        if whatsAppCallActive {
            let accept = NSRect(
                x: bounds.maxX - 110,
                y: bounds.midY - 9,
                width: 48,
                height: 18
            )

            let decline = NSRect(
                x: bounds.maxX - 56,
                y: bounds.midY - 9,
                width: 48,
                height: 18
            )

            if accept.contains(loc) {
                onAcceptWhatsAppCall?()
                return
            } else if decline.contains(loc) {
                onDeclineWhatsAppCall?()
                return
            }
        }

        if mediaPlaying {
            if expanded {
                let playButton = Self.mediaPlayControlRect(in: bounds)
                let backButton = Self.mediaBackControlRect(in: bounds)
                let forwardButton = Self.mediaForwardControlRect(in: bounds)
                if playButton.contains(loc) {
                    onMediaPlayPause?()
                    return
                }
                if backButton.contains(loc) {
                    onMediaSeek?(-10)
                    return
                }
                if forwardButton.contains(loc) {
                    onMediaSeek?(10)
                    return
                }
            }
            if isMirror { onMirrorToggleExpanded?(); return }
            // Clicking the compact YouTube indicator opens/closes its panel.
            expanded.toggle()
            onToggleExpanded?()
            needsDisplay = true
            return
        }

        if isMirror { onMirrorToggleExpanded?(); return }
        expanded.toggle()
        onToggleExpanded?()
        needsDisplay = true
    }

}

// MARK: - App

@MainActor
private final class MirroredNotchDisplay {
    let displayID: UInt32
    let panel: NSPanel
    let view: NotchView
    let developerHost: DeveloperHostingView

    init(displayID: UInt32, panel: NSPanel, view: NotchView, developerHost: DeveloperHostingView) {
        self.displayID = displayID
        self.panel = panel
        self.view = view
        self.developerHost = developerHost
    }
}

@MainActor
final class GrassIslandAppDelegate: NSObject, NSApplicationDelegate {
    private enum SystemAlert {
        case networkDisconnected
        case lowBattery(Int)
        case bluetoothPowerChanged(Bool)
        case focusStateChanged(Bool)
    }

    private var panel: NSPanel!
    private var notch: NotchView!
    private var mirroredNotches: [UInt32: MirroredNotchDisplay] = [:]
    private var displaySyncTimer: Timer?
    private var pointerAcceptanceTimer: Timer?
    private let developerMode = DeveloperModeManager()
    private var developerHost: DeveloperHostingView?
    private var developerSessionObservers: [NSObjectProtocol] = []
    private var lastDeveloperPermissionStates: [String: String] = [:]
    private var incomingNotificationQueue: [InboxMessage] = []
    private var isClearingIncomingMessages = false
    private var pendingNotificationFingerprints = Set<String>()
    private var deferredInboxMessages: [String: InboxMessage] = [:]
    private var inboxSessionInactive = false
    private var deferGmailScanToNotificationCenter = true
    private var deferWhatsAppScanToNotificationCenter = true
    private var incomingNotificationTimer: Timer?
    private var incomingNotificationTransitionTimer: Timer?
    private var gmailCheckInProgress = false
    private var didInitialGmailSync = false
    private var volumeAnimationTimer: Timer?
    private var volumeAnimationStartedAt: TimeInterval = 0
    private var volumeAnimationFrom: CGFloat = 0
    private var volumeAnimationTo: CGFloat = 0

    private var timers: [Timer] = []
    private var appActivationObserver: NSObjectProtocol?
    private var systemStateObservers: [NSObjectProtocol] = []
    private let networkMonitor = NWPathMonitor()
    private var lastNetworkConnected: Bool?
    private var lastBatteryPercent: Int?
    private var lastBluetoothPoweredOn: Bool?
    private var lastBluetoothNotificationAt: CFTimeInterval = 0
    private var captureActivityCheckInProgress = false
    private var focusStatusTimer: Timer?
    private var youtubePollingTimer: Timer?
    private var lastFocusState: Bool?
    private var focusStatusMonitoringStarted = false
    private var systemAlertQueue: [SystemAlert] = []
    private var activeSystemAlert: SystemAlert?
    private var systemAlertTimer: Timer?

    private let idleWidth: CGFloat = 210
    private let activeWidth: CGFloat = 360
    private let appSwitchWidth: CGFloat = 294
    private var appSwitchExpansionDuration: TimeInterval {
        DeveloperAnimationSettings.shared.effectiveExpansionDuration
    }
    private let cardWidth: CGFloat = 246
    private let multiMessageBaseWidth: CGFloat = 258
    private let maximumMessagesInNotchQueue = 20

    // NSScreen reports the actual cutout's top safe-area depth. MacBook Pro
    // and Air displays differ, so use their live display geometry rather than
    // assuming a single model's notch height.
    private var idleHeight: CGFloat {
        NotchView.idlePanelHeight(safeAreaTop: NSScreen.notchScreen?.safeAreaInsets.top ?? 0)
    }
    private let noNetworkAlertHeight: CGFloat = 104
    private let singleMessageHeight: CGFloat = 100
    private let messageRowHeight: CGFloat = 38

    private var currentWidth: CGFloat = 210
    private var currentHeight: CGFloat = 34
    private var resizeAnimationGeneration = 0

    private var lastVolume: Float?
    private var appSwitchTimer: Timer?
    private var appSwitchStartedAt: TimeInterval = 0
    private var currentAppIconTimer: Timer?
    private var currentAppIconTransitionStartedAt: TimeInterval = 0

    // YouTube state: identify each video independently of indicator visibility.
    private var currentMediaTitle = ""
    private var currentMediaKey = ""
    private var currentMediaVideoID = ""
    private var currentMediaTabID: Int?
    private var currentShortSession = false
    private var mediaCheckInProgress = false
    private var mediaPlaybackCheckInProgress = false
    private var lastMediaPlaybackPollAt: CFTimeInterval = 0
    private var mediaPlaybackRevision = 0
    private var lastFullMediaPollAt: CFTimeInterval = 0
    private var loadedThumbnailURL = ""
    private var mediaActionOverrideUntil = Date.distantPast
    private var mediaTimeOverrideUntil = Date.distantPast

    private var callTimer: Timer?
    private var chargingDismissTimer: Timer?

    private var waCheckInProgress = false
    private var whatsAppPageIsActive = false
    private var whatsAppNotificationFilter = WhatsAppNotificationFilter()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.notchScreen else { return }

        NSApp.setActivationPolicy(.accessory)
        InboxNotifications.configure()

        let frame = NSRect(
            x: screen.frame.midX - idleWidth / 2,
            y: screen.frame.maxY - idleHeight,
            width: idleWidth,
            height: idleHeight
        )

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Keep the notch above app windows without using the screen-saver
        // level, which can block system and app controls beneath its window.
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]

        notch = NotchView(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        notch.autoresizingMask = [.width, .height]
        notch.startupSplash = true

        panel.contentView = notch

        developerHost = DeveloperHostingView(rootView: DeveloperOverlayRoot(
            manager: developerMode,
            snapshotProvider: { [weak self] in await self?.makeDeveloperSnapshot() ?? .environment },
            playbackAction: { [weak self] shouldPlay in self?.developerSetPlayback(shouldPlay: shouldPlay) },
            dismissActivity: { [weak self] identifier in self?.developerDismissActivity(identifier) },
            openSettings: { [weak self] in self?.openDeveloperSystemSettings() },
            returnToDefault: { [weak self] in self?.developerReturnToDefaultState() }
        ))
        developerHost?.safeAreaRegions = []
        developerMode.onPresentationChange = { [weak self] presentation in
            self?.applyDeveloperPresentation(presentation)
        }
        developerMode.onConsoleReveal = { [weak self] in
            self?.panel.makeKeyAndOrderFront(nil)
        }
        notch.onDeveloperModeClick = { [weak self] shiftHeld in
            self?.developerMode.handleOptionClick(shiftHeld: shiftHeld)
        }
        developerHost?.onDeveloperClick = { [weak self] shiftHeld in
            self?.developerMode.handleOptionClick(shiftHeld: shiftHeld)
        }
        installDeveloperSessionObservers()
        DeveloperEventLog.shared.append("Lifecycle", "App launched; developer session locked")

        panel.orderFrontRegardless()

        notch.onToggleExpanded = { [weak self] in
            guard let self = self else { return }
            // Expand the media panel in one frame so its controls never appear
            // after a temporary clock/battery-only strip.
            self.resizeWindow(animated: true)
            self.notch.needsDisplay = true
            DeveloperEventLog.shared.append("Interface", self.notch.expanded ? "Notch expanded" : "Notch collapsed")
        }

        notch.onClearIncomingMessages = { [weak self] in self?.clearIncomingMessagesToNotificationCenter() }

        notch.onControlClickLock = { [weak self] in
            self?.lockScreen()
        }

        notch.onAcceptWhatsAppCall = { [weak self] in
            guard let self = self else { return }

            WhatsAppMonitor.acceptCall()

            self.notch.whatsAppCallActive = false
            self.notch.whatsAppInCall = true
            self.notch.whatsAppCallDurationSeconds = 0

            self.startCallTimer()
            self.resizeWindow()
        }

        notch.onDeclineWhatsAppCall = { [weak self] in
            guard let self = self else { return }

            WhatsAppMonitor.declineCall()

            self.stopCallTimer()
            self.notch.whatsAppCallActive = false
            self.notch.whatsAppInCall = false

            self.resizeWindow()
        }

        notch.onToggleWhatsAppMute = {
            self.notch.whatsAppIsMuted.toggle()
            WhatsAppMonitor.toggleMute()
        }

        notch.onMediaPlayPause = { [weak self] in
            guard let self, let tabID = self.currentMediaTabID else { return }
            // Treat the panel state as the immediate user intent. Send explicit,
            // serialized play/pause commands so rapid clicks never invert stale state.
            let shouldPlay = self.notch.mediaPaused
            self.notch.mediaPaused = !shouldPlay
            self.mediaActionOverrideUntil = Date().addingTimeInterval(1.8)
            self.notch.needsDisplay = true
            ChromeYouTube.performVideoAction(shouldPlay ? "play" : "pause", tabID: tabID, videoID: self.currentMediaVideoID)
        }
        notch.onMediaSeek = { [weak self] seconds in
            guard let self, let tabID = self.currentMediaTabID else { return }
            let upperBound = self.notch.mediaDuration > 0 ? self.notch.mediaDuration : Double.greatestFiniteMagnitude
            self.notch.mediaCurrentTime = min(upperBound, max(0, self.notch.mediaCurrentTime + seconds))
            self.mediaTimeOverrideUntil = Date().addingTimeInterval(1.0)
            self.notch.needsDisplay = true
            ChromeYouTube.performVideoAction("seek", seekSeconds: seconds, tabID: tabID, videoID: self.currentMediaVideoID)
        }

        refreshMirroredDisplays()
        let screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMirroredDisplays() }
        }
        systemStateObservers.append(screenChangeObserver)
        displaySyncTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncMirroredNotches(animated: false)
            }
        }
        if let displaySyncTimer { RunLoop.main.add(displaySyncTimer, forMode: .common) }
        pointerAcceptanceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateNotchPointerAcceptance() }
        }
        if let pointerAcceptanceTimer { RunLoop.main.add(pointerAcceptanceTimer, forMode: .common) }
        updateNotchPointerAcceptance()

        panel.orderFrontRegardless()

        installAppActivationObserver()
        pollCaptureActivity()
        pollClockAndBattery()
        // Observe YouTube playback during the startup splash so the audio
        // indicator is not delayed until the rest of app polling starts.
        let youtubeTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollYouTubePlaybackState()
                self.pollYouTube()
                // Keep waveform redraws alive from app launch, including while
                // the startup splash is visible and before normal polling starts.
                if self.notch.mediaPlaying { self.notch.needsDisplay = true }
            }
        }
        youtubePollingTimer = youtubeTimer
        RunLoop.main.add(youtubeTimer, forMode: .common)
        notch.expanded = true
        resizeWindow(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            self.notch.startupSplash = false
            self.notch.expanded = false
            self.resizeWindow(animated: true)
            self.startPolling()
        }
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func refreshMirroredDisplays() {
        guard let primaryScreen = NSScreen.notchScreen, let primaryID = displayID(for: primaryScreen) else { return }
        let externalScreens = NSScreen.screens.filter { displayID(for: $0) != primaryID }
        let currentIDs = Set(externalScreens.compactMap { displayID(for: $0) })
        let disconnectedIDs = mirroredNotches.keys.filter { !currentIDs.contains($0) }
        for identifier in disconnectedIDs {
            mirroredNotches[identifier]?.panel.orderOut(nil)
            mirroredNotches.removeValue(forKey: identifier)
        }

        for screen in externalScreens {
            guard let identifier = displayID(for: screen), mirroredNotches[identifier] == nil else { continue }
            let width = idleWidth
            let height = NotchView.idlePanelHeight(safeAreaTop: screen.safeAreaInsets.top)
            let frame = NotchView.notchFrame(in: screen.frame, width: width, height: height)
            let mirrorPanel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            mirrorPanel.level = .statusBar
            mirrorPanel.backgroundColor = .clear
            mirrorPanel.isOpaque = false
            mirrorPanel.hasShadow = false
            mirrorPanel.ignoresMouseEvents = false
            mirrorPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let mirrorView = NotchView(frame: NSRect(origin: .zero, size: frame.size))
            mirrorView.autoresizingMask = [.width, .height]
            mirrorView.isMirror = true
            mirrorView.onDeveloperModeClick = notch.onDeveloperModeClick
            mirrorView.onControlClickLock = notch.onControlClickLock
            mirrorView.onAcceptWhatsAppCall = notch.onAcceptWhatsAppCall
            mirrorView.onDeclineWhatsAppCall = notch.onDeclineWhatsAppCall
            mirrorView.onToggleWhatsAppMute = notch.onToggleWhatsAppMute
            mirrorView.onMediaPlayPause = notch.onMediaPlayPause
            mirrorView.onMediaSeek = notch.onMediaSeek
            mirrorView.onClearIncomingMessages = notch.onClearIncomingMessages
            mirrorView.onMirrorToggleExpanded = { [weak self] in
                guard let self else { return }
                self.notch.expanded.toggle()
                self.notch.onToggleExpanded?()
            }
            mirrorPanel.contentView = mirrorView

            let mirrorHost = DeveloperHostingView(rootView: DeveloperOverlayRoot(
                manager: developerMode,
                snapshotProvider: { [weak self] in await self?.makeDeveloperSnapshot() ?? .environment },
                playbackAction: { [weak self] shouldPlay in self?.developerSetPlayback(shouldPlay: shouldPlay) },
                dismissActivity: { [weak self] identifier in self?.developerDismissActivity(identifier) },
                openSettings: { [weak self] in self?.openDeveloperSystemSettings() },
                returnToDefault: { [weak self] in self?.developerReturnToDefaultState() }
            ))
            mirrorHost.safeAreaRegions = []
            mirrorHost.onDeveloperClick = notch.onDeveloperModeClick
            mirroredNotches[identifier] = MirroredNotchDisplay(
                displayID: identifier, panel: mirrorPanel, view: mirrorView, developerHost: mirrorHost
            )
            mirrorPanel.orderFrontRegardless()
        }
        syncMirroredNotches(animated: false)
        applyDeveloperPresentationToMirrors(developerMode.presentation)
    }

    private func syncMirroredNotches(animated: Bool, durationOverride: TimeInterval? = nil) {
        guard panel != nil else { return }
        for mirror in mirroredNotches.values {
            guard let screen = NSScreen.screens.first(where: { displayID(for: $0) == mirror.displayID }) else { continue }
            mirror.view.copyVisualState(from: notch)
            let height = developerMode.presentation == .closed && abs(currentHeight - idleHeight) < 1
                ? NotchView.idlePanelHeight(safeAreaTop: screen.safeAreaInsets.top)
                : currentHeight
            let frame = NotchView.notchFrame(in: screen.frame, width: currentWidth, height: height)
            let oldFrame = mirror.panel.frame
            guard abs(oldFrame.origin.x - frame.origin.x) > 1
                    || abs(oldFrame.origin.y - frame.origin.y) > 1
                    || abs(oldFrame.width - frame.width) > 1
                    || abs(oldFrame.height - frame.height) > 1 else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = durationOverride ?? max(0.12, DeveloperAnimationSettings.shared.effectiveExpansionDuration)
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    mirror.panel.animator().setFrame(frame, display: true)
                }
            } else {
                mirror.panel.setFrame(frame, display: true)
            }
        }
    }

    private func updateNotchPointerAcceptance() {
        let developerPanelIsInteractive = developerMode.presentation != .closed
        let cursorLocation = NSEvent.mouseLocation
        if let panel, let notch {
            let shouldIgnore = !developerPanelIsInteractive
                && !notch.shouldAcceptPointer(at: notch.convert(panel.convertPoint(fromScreen: cursorLocation), from: nil))
            if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
        }
        for mirror in mirroredNotches.values {
            let shouldIgnore = !developerPanelIsInteractive
                && !mirror.view.shouldAcceptPointer(at: mirror.view.convert(mirror.panel.convertPoint(fromScreen: cursorLocation), from: nil))
            if mirror.panel.ignoresMouseEvents != shouldIgnore { mirror.panel.ignoresMouseEvents = shouldIgnore }
        }
    }

    private func applyDeveloperPresentationToMirrors(_ presentation: DeveloperModePresentation) {
        let interactive = presentation == .authenticating || presentation == .console
        for mirror in mirroredNotches.values {
            var style = mirror.panel.styleMask
            if interactive { style.remove(.nonactivatingPanel) } else { style.insert(.nonactivatingPanel) }
            mirror.panel.styleMask = style
            mirror.panel.level = .statusBar
            if presentation == .closed {
                if mirror.panel.contentView !== mirror.view { mirror.panel.contentView = mirror.view }
            } else if mirror.panel.contentView !== mirror.developerHost {
                mirror.panel.contentView = mirror.developerHost
            }
            if interactive { mirror.panel.orderFrontRegardless() }
        }
    }

    private func applyDeveloperPresentation(_ presentation: DeveloperModePresentation) {
        guard let panel, let notch, let developerHost else { return }
        let developerWindowIsInteractive = presentation == .authenticating || presentation == .console
        if developerWindowIsInteractive {
            // The notch normally uses a non-activating status-bar panel. That
            // keeps ordinary clicks from stealing focus. Keep this panel at
            // the same edge-attached level while it becomes interactive; a
            // normal-level window is placed below the menu bar on macOS.
            var styleMask = panel.styleMask
            styleMask.remove(.nonactivatingPanel)
            panel.styleMask = styleMask
            panel.level = .statusBar
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Restore the notch's passive, always-on-top behavior after a
            // failure/cancel or when the console closes.
            if panel.isKeyWindow { panel.resignKey() }
            var styleMask = panel.styleMask
            styleMask.insert(.nonactivatingPanel)
            panel.styleMask = styleMask
            panel.level = .statusBar
        }
        if presentation == .closed {
            if panel.contentView !== notch { panel.contentView = notch }
        } else if panel.contentView !== developerHost {
            panel.contentView = developerHost
        }
        // Give Developer Mode's larger panel a more deliberate transition,
        // while leaving the timing of all other notch activities untouched.
        let settings = DeveloperAnimationSettings.shared
        let transitionDuration = presentation == .closed
            ? settings.effectiveCollapseDuration * 1.75
            : settings.effectiveExpansionDuration * 1.75
        resizeWindow(animated: true, durationOverride: transitionDuration)
        DeveloperEventLog.shared.append("Console", presentation == .console ? "Developer console opened" : "Developer authentication panel shown")
        applyDeveloperPresentationToMirrors(presentation)
    }

    private func installDeveloperSessionObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let sessionObserver = center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.developerMode.lockDeveloperMode(reason: .screenLocked)
                self?.suspendInboxNotificationsForSession()
            }
        }
        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.developerMode.lockDeveloperMode(reason: .systemSleep)
                self?.suspendInboxNotificationsForSession()
            }
        }
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.developerMode.lockDeveloperMode(reason: .sessionExpired) }
        }
        let powerOffObserver = center.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.developerMode.lockDeveloperMode(reason: .userLoggedOut) }
        }
        let activeObserver = center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Becoming active never restores a previously authenticated session.
                self.developerMode.lockDeveloperMode(reason: .sessionExpired)
                self.resumeInboxNotificationsForSession()
            }
        }
        developerSessionObservers = [sessionObserver, sleepObserver, wakeObserver, powerOffObserver, activeObserver]
    }

    private func makeDeveloperSnapshot() async -> DeveloperSnapshot {
        var snapshot = DeveloperSnapshot.environment
        let presentationIsVisible: Bool
        switch developerMode.presentation {
        case .closed: presentationIsVisible = false
        default: presentationIsVisible = true
        }
        var activities: [DeveloperActivity] = []
        if notch.mediaPlaying {
            activities.append(DeveloperActivity(
                id: "youtube", name: "YouTube playback", kind: "Media",
                state: notch.mediaPaused ? "Paused" : "Playing", startedAt: nil,
                visibleInNotch: !presentationIsVisible && notch.mediaPlaying,
                details: "Playback active; media title and URL omitted",
                canTogglePlayback: currentMediaTabID != nil, canDismiss: false
            ))
        }
        if notch.systemTimerActive {
            activities.append(DeveloperActivity(
                id: "timer", name: "System timer", kind: "Timer", state: notch.systemTimerText,
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Timer continues independently of this console",
                canTogglePlayback: false, canDismiss: false
            ))
        }
        if notch.incomingNotification != nil {
            activities.append(DeveloperActivity(
                id: "inbox", name: "Incoming message", kind: "Notification", state: "Queued for notch",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Message contents omitted", canTogglePlayback: false, canDismiss: true
            ))
        }
        if notch.whatsAppMessageActive || !notch.whatsAppMessages.isEmpty {
            activities.append(DeveloperActivity(
                id: "whatsapp", name: "WhatsApp message card", kind: "Notification", state: "Active",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Sender and message contents omitted", canTogglePlayback: false, canDismiss: false
            ))
        }
        if notch.whatsAppCallActive || notch.whatsAppInCall {
            activities.append(DeveloperActivity(
                id: "whatsapp-call", name: "WhatsApp call", kind: "Communication", state: notch.whatsAppInCall ? "In call" : "Incoming",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Call controls remain active", canTogglePlayback: false, canDismiss: false
            ))
        }
        if notch.lowBatteryAlertPercent != nil || notch.noNetworkAlertActive {
            activities.append(DeveloperActivity(
                id: "system-alert", name: notch.noNetworkAlertActive ? "Network alert" : "Battery alert", kind: "System alert", state: "Visible briefly",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Alert timeout continues while the console is open", canTogglePlayback: false, canDismiss: false
            ))
        }
        if notch.chargingIndicatorActive {
            activities.append(DeveloperActivity(
                id: "charging", name: "Charging indicator", kind: "Power", state: "Active",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Automatic timeout continues", canTogglePlayback: false, canDismiss: false
            ))
        }
        if notch.volumeHUD {
            activities.append(DeveloperActivity(
                id: "volume", name: "Volume HUD", kind: "System control", state: "Visible",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "Volume level \(Int(notch.volume * 100))%",
                canTogglePlayback: false, canDismiss: false
            ))
        }
        if notch.appSwitchIcon != nil {
            activities.append(DeveloperActivity(
                id: "app-switch", name: "App switch indicator", kind: "Application", state: "Transitioning",
                startedAt: nil, visibleInNotch: !presentationIsVisible,
                details: "App icon identity omitted", canTogglePlayback: false, canDismiss: false
            ))
        }
        snapshot = DeveloperSnapshot(
            version: snapshot.version, build: snapshot.build, macOS: snapshot.macOS,
            architecture: snapshot.architecture, uptime: snapshot.uptime,
            memoryBytes: snapshot.memoryBytes, activities: activities,
            permissions: await DeveloperPermissionReader.read()
        )
        var nextPermissions: [String: String] = [:]
        for permission in snapshot.permissions {
            nextPermissions[permission.id] = permission.status
            if let previous = lastDeveloperPermissionStates[permission.id], previous != permission.status {
                DeveloperEventLog.shared.append("Permission", "\(permission.name) status changed: \(previous) → \(permission.status)")
            }
        }
        lastDeveloperPermissionStates = nextPermissions
        return snapshot
    }

    private func developerSetPlayback(shouldPlay: Bool) {
        guard let tabID = currentMediaTabID else { return }
        notch.mediaPaused = !shouldPlay
        mediaActionOverrideUntil = Date().addingTimeInterval(1.8)
        ChromeYouTube.performVideoAction(shouldPlay ? "play" : "pause", tabID: tabID, videoID: currentMediaVideoID)
        DeveloperEventLog.shared.append("Activity", shouldPlay ? "Media playback resumed by developer" : "Media playback paused by developer")
    }

    private func developerDismissActivity(_ identifier: String) {
        guard identifier == "inbox", let message = notch.incomingNotification else { return }
        incomingNotificationTimer?.invalidate()
        incomingNotificationTimer = nil
        notch.incomingNotification = nil
        pendingNotificationFingerprints.remove(message.fingerprint)
        resizeWindow(animated: true)
        showNextIncomingNotificationIfNeeded()
        DeveloperEventLog.shared.append("Activity", "Current incoming message card dismissed by developer")
    }

    private func openDeveloperSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func developerReturnToDefaultState() {
        notch.expanded = false
        developerMode.closeConsole()
        resizeWindow(animated: true)
    }

    // MARK: Call Timer

    private func startCallTimer() {
        callTimer?.invalidate()

        callTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.notch.whatsAppInCall else {
                    return
                }

                self.notch.whatsAppCallDurationSeconds += 1
            }
        }

        if let callTimer {
            RunLoop.main.add(callTimer, forMode: .common)
        }
    }

    private func stopCallTimer() {
        callTimer?.invalidate()
        callTimer = nil
        notch.whatsAppCallDurationSeconds = 0
    }

    // MARK: Lock Screen

    private func lockScreen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    // MARK: App Activation

    private func installAppActivationObserver() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != NSRunningApplication.current.processIdentifier,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            notch.currentAppIcon = frontmost.icon
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }

            Task { @MainActor in
                self?.handleAppActivation(app)
            }
        }
    }

    private func handleAppActivation(_ application: NSRunningApplication) {
        guard application.processIdentifier != NSRunningApplication.current.processIdentifier,
              application.bundleIdentifier == nil || application.bundleIdentifier != Bundle.main.bundleIdentifier,
              !notch.whatsAppCallActive,
              !notch.whatsAppInCall else {
            return
        }

        let icon = application.icon
            ?? application.bundleURL.map({ NSWorkspace.shared.icon(forFile: $0.path) })
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")
        print("[AppSwitch] showing icon for \(application.localizedName ?? application.bundleIdentifier ?? "active app")")

        beginCurrentAppIconTransition(to: icon)

        // In the clock/battery and media panels the icon belongs in the header.
        // Updating it there must not trigger the separate collapsed app-switch wing.
        if NotchView.shouldKeepExpandedShapeOnAppSwitch(isExpanded: notch.expanded) {
            appSwitchTimer?.invalidate()
            appSwitchTimer = nil
            notch.appSwitchIcon = nil
            notch.appSwitchOpacity = 0
            notch.needsDisplay = true
            return
        }

        appSwitchTimer?.invalidate()

        let alreadyVisible = notch.appSwitchIcon != nil && notch.appSwitchOpacity > 0
        notch.appSwitchIcon = icon
        notch.appSwitchOpacity = alreadyVisible ? 1 : 0

        appSwitchStartedAt = CACurrentMediaTime()
        resizeWindow()

        appSwitchTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAppSwitchAnimation()
            }
        }

        if let appSwitchTimer {
            RunLoop.main.add(appSwitchTimer, forMode: .common)
        }
    }

    private func updateAppSwitchAnimation() {
        let elapsed = CACurrentMediaTime() - appSwitchStartedAt

        if elapsed >= 1.42 {
            cancelAppSwitchAnimation()
            resizeWindow()
            return
        }

        notch.appSwitchOpacity = NotchView.appSwitchOpacity(
            after: elapsed,
            expansionDuration: appSwitchExpansionDuration
        )

        notch.needsDisplay = true
    }

    private func cancelAppSwitchAnimation() {
        appSwitchTimer?.invalidate()
        appSwitchTimer = nil

        notch.appSwitchIcon = nil
        notch.appSwitchOpacity = 0
        notch.needsDisplay = true
    }

    private func beginCurrentAppIconTransition(to icon: NSImage?) {
        currentAppIconTimer?.invalidate()
        currentAppIconTimer = nil
        guard let icon else { return }
        guard let oldIcon = notch.currentAppIcon else {
            notch.currentAppIcon = icon
            notch.previousCurrentAppIcon = nil
            notch.currentAppIconTransitionProgress = 1
            return
        }
        notch.previousCurrentAppIcon = oldIcon
        notch.currentAppIcon = icon
        notch.currentAppIconTransitionProgress = 0
        currentAppIconTransitionStartedAt = CACurrentMediaTime()
        currentAppIconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(1, (CACurrentMediaTime() - self.currentAppIconTransitionStartedAt) / 0.24)
                self.notch.currentAppIconTransitionProgress = CGFloat(progress)
                if progress >= 1 {
                    self.currentAppIconTimer?.invalidate()
                    self.currentAppIconTimer = nil
                    self.notch.previousCurrentAppIcon = nil
                }
            }
        }
        if let currentAppIconTimer {
            RunLoop.main.add(currentAppIconTimer, forMode: .common)
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollCaptureActivity()
        installBluetoothPowerObservers()
        startFocusStatusMonitoring()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                self?.handleNetworkStatus(connected: connected)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "grassIsland.network-monitor"))

        let volumeTimer = Timer.scheduledTimer(
            withTimeInterval: 0.3,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollVolume()
            }
        }

        let systemTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollSystemTimer()
            }
        }

        let clockTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollClockAndBattery()
            }
        }

        pollBluetoothState()
        let bluetoothTimer = Timer.scheduledTimer(
            withTimeInterval: 0.7,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollBluetoothState()
            }
        }

        let whatsappTimer = Timer.scheduledTimer(
            // AppleScript polling is relatively expensive. Two scans per
            // second keeps message/call detection responsive while avoiding
            // unnecessary process churn on slower Macs.
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollWhatsApp()
            }
        }

        let gmailTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollGmail()
            }
        }

        let captureActivityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCaptureActivity() }
        }

        timers = [
            volumeTimer,
            systemTimer,
            clockTimer,
            bluetoothTimer,
            whatsappTimer,
            gmailTimer,
            captureActivityTimer
        ]

        timers.forEach {
            RunLoop.main.add($0, forMode: .common)
        }
    }

    private func pollCaptureActivity() {
        guard !captureActivityCheckInProgress else { return }
        captureActivityCheckInProgress = true
        Task.detached(priority: .utility) { [weak self] in
            let state = SystemCaptureActivity.currentState()
            await self?.resolveCaptureActivity(systemState: state)
        }
    }

    @MainActor
    private func resolveCaptureActivity(systemState: CaptureActivityState) {
        ChromeMeetingCapture.fetch { [weak self] meetingState in
            guard let self else { return }
            let effectiveState = meetingState.map {
                CaptureActivityState(
                    cameraInUse: $0.cameraInUse,
                    microphoneInUse: $0.microphoneInUse
                )
            } ?? systemState
            self.applyCaptureActivity(effectiveState)
        }
    }

    private func applyCaptureActivity(_ state: CaptureActivityState) {
        captureActivityCheckInProgress = false
        guard state != notch.captureActivity else { return }
        notch.captureActivity = state
        resizeWindow(animated: true)
        notch.needsDisplay = true
    }

    // MARK: WhatsApp Avatars

    private func fetchAvatarImages(for messages: [WhatsAppMessageItem]) {
        for message in messages where !message.avatarURL.isEmpty {
            let urlString = message.avatarURL
            guard notch.whatsAppAvatarImages[urlString] == nil,
                  let url = URL(string: urlString) else { continue }
            Task.detached(priority: .utility) { [weak self] in
                let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
                guard let image else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.notch.whatsAppAvatarImages[urlString] = image
                }
            }
        }
    }

    // MARK: WhatsApp Monitoring

    private func pollWhatsApp() {
        guard !waCheckInProgress else { return }
        waCheckInProgress = true
        let chromeIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome"
        WhatsAppMonitor.checkState(chromeIsFrontmost: chromeIsFrontmost) { [weak self] state in
            guard let self = self else { return }
            self.waCheckInProgress = false
            // nil means the poll failed; preserve the currently visible state.
            guard let state else {
                if !chromeIsFrontmost && self.whatsAppPageIsActive {
                    self.whatsAppPageIsActive = false
                    self.showNextIncomingNotificationIfNeeded()
                }
                return
            }
            self.whatsAppPageIsActive = state.isActivePage
            if self.whatsAppPageIsActive {
                self.discardWhatsAppNotificationsWhilePageIsActive(state.messages)
            }
            if !state.hasIncomingCall && !self.notch.whatsAppInCall {
                let unreadFingerprints = Set(state.messages.map { "whatsapp::\($0.fingerprint.lowercased())" })
                InboxStore.shared.reconcileWhatsAppUnread(fingerprints: unreadFingerprints)
            }

            if !self.notch.whatsAppInCall {
                if self.notch.whatsAppCallActive != state.hasIncomingCall {
                    self.notch.whatsAppCallActive = state.hasIncomingCall
                    self.notch.whatsAppCallerName = state.callerName
                    self.notch.whatsAppCallTypeLabel = state.incomingCallLabel
                    self.resizeWindow()
                } else if state.hasIncomingCall {
                    self.notch.whatsAppCallerName = state.callerName
                    self.notch.whatsAppCallTypeLabel = state.incomingCallLabel
                }
            } else if !state.hasIncomingCall {
                self.stopCallTimer()
                self.notch.whatsAppInCall = false
                self.notch.whatsAppCallActive = false
                self.resizeWindow()
                self.showNextIncomingNotificationIfNeeded()
            }

            let messagesToNotify: [WhatsAppMessageItem]
            if state.hasIncomingCall {
                messagesToNotify = []
            } else {
                messagesToNotify = self.whatsAppNotificationFilter.notifications(
                    from: state.messages,
                    whilePageIsActive: state.isActivePage
                )
            }
            let inboxMessages = messagesToNotify.map { item in
                let preview = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
                return InboxMessage(
                    id: UUID().uuidString,
                    service: "WhatsApp",
                    account: "WhatsApp Web",
                    sender: item.name,
                    senderEmail: "",
                    subject: preview.isEmpty ? "New WhatsApp message" : preview,
                    preview: preview,
                    receivedAt: Date(),
                    fingerprint: "whatsapp::\(item.fingerprint.lowercased())",
                    sourceURL: "https://web.whatsapp.com/",
                    isRead: false
                )
            }
            if self.inboxSessionInactive {
                self.deferInboxMessages(inboxMessages)
                return
            }
            if self.deferWhatsAppScanToNotificationCenter {
                guard !state.isActivePage else { return }
                self.deferWhatsAppScanToNotificationCenter = false
                self.deliverInboxBundle(inboxMessages)
                return
            }
            guard !inboxMessages.isEmpty,
                  !self.notch.whatsAppCallActive,
                  !self.notch.whatsAppInCall else { return }
            if self.whatsAppPageIsActive {
                return
            }

            let freshMessages = inboxMessages.filter {
                !self.pendingNotificationFingerprints.contains($0.fingerprint)
                    && !InboxStore.shared.hasNotificationBeenDelivered(for: $0.fingerprint)
            }
            if freshMessages.count > self.maximumMessagesInNotchQueue {
                self.deliverInboxBundle(freshMessages)
                return
            }
            _ = InboxStore.shared.add(contentsOf: freshMessages)
            for message in freshMessages { self.enqueueNotification(message) }
            if !state.isActivePage, !messagesToNotify.isEmpty {
                self.fetchAvatarImages(for: Array(messagesToNotify.prefix(4)))
            }
        }
    }

    private func discardWhatsAppNotificationsWhilePageIsActive(_ unreadMessages: [WhatsAppMessageItem]) {
        whatsAppNotificationFilter.suppress(unreadMessages)

        let queuedWhatsAppMessages = incomingNotificationQueue.filter { $0.service == "WhatsApp" }
        whatsAppNotificationFilter.suppressFingerprints(queuedWhatsAppMessages.map(\.fingerprint))
        for message in queuedWhatsAppMessages {
            pendingNotificationFingerprints.remove(message.fingerprint)
        }
        incomingNotificationQueue.removeAll { $0.service == "WhatsApp" }

        guard let message = notch.incomingNotification,
              message.service == "WhatsApp" else { return }
        whatsAppNotificationFilter.suppressFingerprints([message.fingerprint])
        incomingNotificationTimer?.invalidate()
        incomingNotificationTimer = nil
        notch.incomingNotification = nil
        pendingNotificationFingerprints.remove(message.fingerprint)
        resizeWindow(animated: true)
    }

    // MARK: Notification queue and Gmail

    private func deferInboxMessages(_ messages: [InboxMessage]) {
        for message in messages where !message.fingerprint.isEmpty {
            deferredInboxMessages[message.fingerprint] = message
        }
        _ = InboxStore.shared.add(contentsOf: messages)
    }

    private func deliverInboxBundle(_ messages: [InboxMessage]) {
        _ = InboxStore.shared.add(contentsOf: messages)
        let claimedFingerprints = InboxStore.shared.claimNotifications(for: messages.map(\.fingerprint))
        let newlyDelivered = messages.filter { claimedFingerprints.contains($0.fingerprint) }
        InboxNotifications.postBundle(newlyDelivered)
    }

    private func collectPendingInboxMessages() -> [InboxMessage] {
        var messages = Array(deferredInboxMessages.values)
        messages.append(contentsOf: incomingNotificationQueue)
        if let current = notch.incomingNotification { messages.append(current) }
        var seen = Set<String>()
        return messages.filter { !$0.fingerprint.isEmpty && seen.insert($0.fingerprint).inserted }
    }

    private func suspendInboxNotificationsForSession() {
        inboxSessionInactive = true
        deferGmailScanToNotificationCenter = true
        deferWhatsAppScanToNotificationCenter = true
        let pending = collectPendingInboxMessages()
        incomingNotificationTimer?.invalidate()
        incomingNotificationTimer = nil
        incomingNotificationTransitionTimer?.invalidate()
        incomingNotificationTransitionTimer = nil
        incomingNotificationQueue.removeAll()
        deferredInboxMessages = Dictionary(uniqueKeysWithValues: pending.map { ($0.fingerprint, $0) })
        pendingNotificationFingerprints.removeAll()
        notch.incomingNotification = nil
        notch.incomingNotificationAlpha = 1
        resizeWindow(animated: true)
    }

    private func resumeInboxNotificationsForSession() {
        inboxSessionInactive = false
        let pending = collectPendingInboxMessages()
        incomingNotificationQueue.removeAll()
        deferredInboxMessages.removeAll()
        notch.incomingNotification = nil
        notch.incomingNotificationAlpha = 1
        deliverInboxBundle(pending)
        resizeWindow(animated: true)
    }

    private func clearIncomingMessagesToNotificationCenter() {
        guard !isClearingIncomingMessages else { return }
        isClearingIncomingMessages = true
        let hasVisibleNotification = notch.incomingNotification != nil
        let pending = collectPendingInboxMessages()
        incomingNotificationTimer?.invalidate()
        incomingNotificationTimer = nil
        incomingNotificationTransitionTimer?.invalidate()
        incomingNotificationTransitionTimer = nil
        incomingNotificationQueue.removeAll()
        deferredInboxMessages.removeAll()
        pendingNotificationFingerprints.removeAll()
        notch.incomingNotification = nil
        notch.incomingNotificationAlpha = 1
        deliverInboxBundle(pending)
        guard hasVisibleNotification else {
            isClearingIncomingMessages = false
            notch.needsDisplay = true
            resizeWindow(animated: true)
            return
        }
        animateIncomingNotificationAlpha(to: 0, duration: NotchView.clearAllFadeDuration) { [weak self] in
            guard let self else { return }
            self.notch.incomingNotification = nil
            self.notch.incomingNotificationAlpha = 1
            self.notch.needsDisplay = true
            self.isClearingIncomingMessages = false
            self.resizeWindow(animated: true)
        }
    }

    private func animateIncomingNotificationAlpha(
        to target: CGFloat,
        duration: TimeInterval,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        incomingNotificationTransitionTimer?.invalidate()
        let start = CACurrentMediaTime()
        let from = notch.incomingNotificationAlpha
        guard duration > 0 else {
            notch.incomingNotificationAlpha = target
            completion?()
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let progress = min(1, max(0, (CACurrentMediaTime() - start) / duration))
                let eased = progress * progress * (3 - 2 * progress)
                self.notch.incomingNotificationAlpha = from + (target - from) * CGFloat(eased)
                if progress >= 1 {
                    self.incomingNotificationTransitionTimer?.invalidate()
                    self.incomingNotificationTransitionTimer = nil
                    completion?()
                }
            }
        }
        incomingNotificationTransitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func enqueueNotification(_ message: InboxMessage) {
        if inboxSessionInactive {
            deferInboxMessages([message])
            return
        }
        guard !message.fingerprint.isEmpty,
              !pendingNotificationFingerprints.contains(message.fingerprint),
              !InboxStore.shared.hasNotificationBeenDelivered(for: message.fingerprint) else { return }
        pendingNotificationFingerprints.insert(message.fingerprint)
        _ = InboxStore.shared.add(message)
        incomingNotificationQueue.append(message)
        print("[Inbox] queued \(message.service) notch card")
        DeveloperEventLog.shared.append("Activity", "\(message.service) notification created")
        showNextIncomingNotificationIfNeeded()
    }

    private func showNextIncomingNotificationIfNeeded() {
        guard notch.incomingNotification == nil,
              !incomingNotificationQueue.isEmpty,
              !notch.whatsAppCallActive,
              !notch.whatsAppInCall else { return }

        let message = incomingNotificationQueue.removeFirst()
        cancelAppSwitchAnimation()
        notch.incomingNotificationAlpha = 0
        notch.incomingNotification = message
        resizeWindow(animated: true)
        animateIncomingNotificationAlpha(to: 1, duration: 0.22)

        incomingNotificationTimer?.invalidate()
        incomingNotificationTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.incomingNotificationTimer = nil
                self.animateIncomingNotificationAlpha(to: 0, duration: 0.16) {
                    if message.service == "WhatsApp", self.whatsAppPageIsActive {
                        self.whatsAppNotificationFilter.suppressFingerprints([message.fingerprint])
                    } else if InboxStore.shared.claimNotification(for: message.fingerprint) {
                        InboxNotifications.post(message)
                    }
                    self.pendingNotificationFingerprints.remove(message.fingerprint)
                    self.notch.incomingNotification = nil
                    self.notch.incomingNotificationAlpha = 1
                    self.resizeWindow(animated: true)
                    self.showNextIncomingNotificationIfNeeded()
                }
            }
        }
        if let incomingNotificationTimer {
            RunLoop.main.add(incomingNotificationTimer, forMode: .common)
        }
    }

    private func pollGmail() {
        guard !gmailCheckInProgress else { return }
        gmailCheckInProgress = true
        GmailMonitor.fetchUnread { [weak self] scan in
            guard let self = self else { return }
            self.gmailCheckInProgress = false
            // A missing Chrome/Gmail result is not proof that mail was read.
            guard let scan else { return }
            let messages = scan.messages
            let unreadFingerprints = Set(messages.map(\.fingerprint))
            InboxStore.shared.reconcileGmail(
                scannedAccounts: scan.scannedInboxAccounts,
                unreadFingerprints: unreadFingerprints
            )
            if self.inboxSessionInactive {
                self.deferInboxMessages(messages)
                return
            }
            if !self.didInitialGmailSync {
                guard !scan.scannedInboxAccounts.isEmpty else { return }
                self.didInitialGmailSync = true
                self.deferGmailScanToNotificationCenter = false
                self.deliverInboxBundle(messages)
                return
            }
            if self.deferGmailScanToNotificationCenter {
                self.deferGmailScanToNotificationCenter = false
                self.deliverInboxBundle(messages)
                return
            }
            let freshMessages = messages.filter {
                !self.pendingNotificationFingerprints.contains($0.fingerprint)
                    && !InboxStore.shared.hasNotificationBeenDelivered(for: $0.fingerprint)
            }
            if freshMessages.count > self.maximumMessagesInNotchQueue {
                self.deliverInboxBundle(freshMessages)
                return
            }
            _ = InboxStore.shared.add(contentsOf: freshMessages)
            for message in freshMessages { self.enqueueNotification(message) }
        }
    }

    // MARK: Clock and Battery

    private func pollClockAndBattery() {
        notch.currentTimeText = dateFormatter.string(from: Date())

        let (percent, charging) = SystemBattery.fetchInfo()
        let wasCharging = notch.batteryIsCharging

        notch.batteryPercent = percent
        notch.batteryIsCharging = charging

        let crossedThresholds = SystemBattery.crossedAlertThresholds(
            previousPercent: lastBatteryPercent,
            currentPercent: percent,
            isCharging: charging
        )
        lastBatteryPercent = percent
        if !crossedThresholds.isEmpty {
            enqueueSystemAlert(.lowBattery(percent))
        }

        // Briefly expand when external power/charging is first detected, then collapse.
        if charging && !wasCharging {
            showChargingIndicator()
        }
    }

    private func handleNetworkStatus(connected: Bool) {
        if SystemNetwork.shouldShowDisconnectAlert(
            previouslyConnected: lastNetworkConnected,
            connected: connected
        ) {
            enqueueSystemAlert(.networkDisconnected)
        }
        lastNetworkConnected = connected
    }

    private func pollBluetoothState() {
        guard let isPoweredOn = SystemBluetooth.isPoweredOn() else { return }
        recordBluetoothPowerState(isPoweredOn)
    }

    private func recordBluetoothPowerState(_ isPoweredOn: Bool, fromControllerNotification: Bool = false) {
        if fromControllerNotification {
            lastBluetoothNotificationAt = CACurrentMediaTime()
        } else if CACurrentMediaTime() - lastBluetoothNotificationAt < 1.5,
                  let lastBluetoothPoweredOn,
                  lastBluetoothPoweredOn != isPoweredOn {
            return
        }
        if SystemBluetooth.didPowerStateChange(previous: lastBluetoothPoweredOn, current: isPoweredOn) {
            enqueueSystemAlert(.bluetoothPowerChanged(isPoweredOn))
        }
        lastBluetoothPoweredOn = isPoweredOn
    }

    private func installBluetoothPowerObservers() {
        guard InboxNotifications.hasApplicationBundle else { return }
        let center = NotificationCenter.default
        let states: [(Notification.Name, Bool)] = [
            (.IOBluetoothHostControllerPoweredOn, true),
            (.IOBluetoothHostControllerPoweredOff, false)
        ]
        for (name, isPoweredOn) in states {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.recordBluetoothPowerState(isPoweredOn, fromControllerNotification: true)
                }
            }
            systemStateObservers.append(observer)
        }
    }

    private func startFocusStatusMonitoring() {
        guard !focusStatusMonitoringStarted else { return }
        focusStatusMonitoringStarted = true
        guard InboxNotifications.hasApplicationBundle else {
            NSLog("[FocusStatus] skipped: Focus access requires the packaged grassIsland.app bundle")
            return
        }
        let center = INFocusStatusCenter.default
        center.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                NSLog("[FocusStatus] access not authorized (status: %ld)", status.rawValue)
                return
            }
            Task { @MainActor in
                guard let self else { return }
                self.pollFocusStatus()
                guard self.focusStatusTimer == nil else { return }
                let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.pollFocusStatus() }
                }
                self.focusStatusTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func pollFocusStatus() {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized,
              let isFocused = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        if SystemFocus.didStatusChange(previous: lastFocusState, current: isFocused) {
            enqueueSystemAlert(.focusStateChanged(isFocused))
        }
        lastFocusState = isFocused
    }

    private func enqueueSystemAlert(_ alert: SystemAlert) {
        systemAlertQueue.append(alert)
        showNextSystemAlertIfNeeded()
    }

    private func showNextSystemAlertIfNeeded() {
        guard activeSystemAlert == nil, !systemAlertQueue.isEmpty else { return }
        let alert = systemAlertQueue.removeFirst()
        activeSystemAlert = alert
        switch alert {
        case .networkDisconnected:
            notch.noNetworkAlertActive = true
        case .lowBattery(let percent):
            notch.lowBatteryAlertPercent = percent
        case .bluetoothPowerChanged(let isPoweredOn):
            notch.bluetoothAlertState = isPoweredOn
        case .focusStateChanged(let isFocused):
            notch.focusAlertState = isFocused
        }
        resizeWindow(animated: true)

        systemAlertTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.notch.noNetworkAlertActive = false
                self.notch.lowBatteryAlertPercent = nil
                self.notch.bluetoothAlertState = nil
                self.notch.focusAlertState = nil
                self.activeSystemAlert = nil
                self.systemAlertTimer = nil
                self.resizeWindow(animated: true)
                self.showNextSystemAlertIfNeeded()
            }
        }
        systemAlertTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showChargingIndicator() {
        chargingDismissTimer?.invalidate()
        notch.chargingIndicatorActive = true
        resizeWindow()

        chargingDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.notch.chargingIndicatorActive = false
                self.chargingDismissTimer = nil
                self.resizeWindow()
            }
        }
        if let timer = chargingDismissTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    // MARK: System Timer

    private func pollSystemTimer() {
        ClockAppMonitor.fetchActiveTimer { [weak self] info in
            guard let self = self else { return }

            let active = info?.isRunning ?? false
            let text = info?.remainingText ?? ""

            if self.notch.systemTimerActive != active
                || self.notch.systemTimerText != text {
                self.notch.systemTimerActive = active
                self.notch.systemTimerText = text
                self.resizeWindow()
            }
        }
    }

    // MARK: Volume

    private func pollVolume() {
        guard let current = SystemVolume.readNative() else {
            return
        }

        if let previous = lastVolume,
           abs(current - previous) > 0.015 {
            notch.volume = current
            notch.volumeHUD = true
            animateVolumeHUD(to: 1)

            resizeWindow(animated: true)

            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(hideVolumeHUD),
                object: nil
            )

            perform(
                #selector(hideVolumeHUD),
                with: nil,
                afterDelay: 2
            )
        } else if notch.volumeHUD {
            notch.volume = current
        }

        lastVolume = current
    }

    @objc private func hideVolumeHUD() {
        notch.volumeHUD = false
        resizeWindow(animated: true)
        animateVolumeHUD(to: 0)
    }

    @MainActor

private func animateVolumeHUD(to target: CGFloat) {
    volumeAnimationTimer?.invalidate()
    volumeAnimationTimer = nil

    volumeAnimationFrom = notch.volumeHUDOpacity
    volumeAnimationTo = target
    volumeAnimationStartedAt = CACurrentMediaTime()

    let duration: TimeInterval = 0.22

    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
            guard let self = self else { return }

            let t = min(
                1.0,
                max(
                    0.0,
                    (CACurrentMediaTime() - self.volumeAnimationStartedAt) / duration
                )
            )

            let eased = t * t * (3.0 - 2.0 * t)

            self.notch.volumeHUDOpacity =
                self.volumeAnimationFrom
                + (self.volumeAnimationTo - self.volumeAnimationFrom) * CGFloat(eased)

            self.notch.needsDisplay = true

            if t >= 1.0 {
                self.volumeAnimationTimer?.invalidate()
                self.volumeAnimationTimer = nil
                self.notch.volumeHUDOpacity = self.volumeAnimationTo
            }
        }
    }

    volumeAnimationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
}

    // MARK: YouTube

    private func pollYouTube() {
        guard !mediaCheckInProgress else { return }
        let now = CACurrentMediaTime()
        let minimumInterval: CFTimeInterval = currentMediaTabID == nil ? 0.5 : 1.2
        guard now - lastFullMediaPollAt >= minimumInterval else { return }
        lastFullMediaPollAt = now
        mediaCheckInProgress = true
        let playbackRevisionAtStart = mediaPlaybackRevision
        ChromeYouTube.fetch(preferredTabID: currentMediaTabID) { [weak self] media in
            guard let self = self else { return }
            self.mediaCheckInProgress = false
            // Preserve the current state on a genuine AppleScript failure.
            guard let media else { return }

            // A missing tracked tab means it was closed (or Chrome has no windows).
            if media.tabID < 0 {
                guard self.currentMediaTabID != nil else { return }
                self.currentMediaTabID = nil
                self.currentMediaVideoID = ""
                self.currentMediaKey = ""
                self.currentMediaTitle = ""
                self.currentShortSession = false
                self.notch.mediaPlaying = false
                self.notch.mediaIsShort = false
                self.notch.mediaTitle = ""
                self.notch.expanded = false
                self.notch.mediaThumbnail = nil
                self.loadedThumbnailURL = ""
                self.resizeWindow()
                return
            }

            // Once tracking a tab, follow that exact tab even when Chrome is backgrounded.
            // Leaving the watch/Shorts route (e.g. navigating to YouTube Home) ends the session.
            guard media.isYouTube, media.isWatchPage || media.isShort else {
                self.currentMediaTabID = nil
                self.currentMediaVideoID = ""
                self.currentMediaKey = ""
                self.currentMediaTitle = ""
                self.currentShortSession = false
                self.notch.mediaPlaying = false
                self.notch.mediaIsShort = false
                self.notch.mediaTitle = ""
                self.notch.expanded = false
                self.notch.mediaThumbnail = nil
                self.loadedThumbnailURL = ""
                self.resizeWindow()
                return
            }

            let key = "\(media.tabID):\(media.isShort ? "shorts" : "watch"):\(media.videoID)"
            let isNewVideo = key != self.currentMediaKey
            self.currentMediaTabID = media.tabID
            self.currentMediaVideoID = media.videoID
            self.currentMediaKey = key
            self.currentShortSession = media.isShort

            if isNewVideo {
                self.currentMediaTitle = media.title
                self.notch.mediaTitle = media.title.isEmpty ? "YouTube video" : media.title
            } else if !media.title.isEmpty && media.title != self.currentMediaTitle {
                self.currentMediaTitle = media.title
                self.notch.mediaTitle = media.title
            }

            self.updateMediaDetails(media, updatePlaybackState: self.mediaPlaybackRevision == playbackRevisionAtStart)
            self.notch.mediaIsShort = media.isShort
            if self.notch.startupSplash && !media.isPaused {
                self.notch.startupSplash = false
            }
            if !self.notch.mediaPlaying {
                self.notch.mediaPlaying = true
                self.resizeWindow()
            } else if isNewVideo && self.notch.expanded {
                self.notch.needsDisplay = true
            }
        }
    }

    private func pollYouTubePlaybackState() {
        let now = CACurrentMediaTime()
        // The timer checks every 100 ms to keep the UI responsive, but avoid
        // spawning an AppleScript process on every tick. A 250 ms ceiling is
        // still fast enough to make play/pause changes feel immediate.
        guard let tabID = currentMediaTabID,
              !mediaPlaybackCheckInProgress,
              now - lastMediaPlaybackPollAt >= 0.25 else { return }
        lastMediaPlaybackPollAt = now
        mediaPlaybackCheckInProgress = true
        ChromeYouTube.fetchPlaybackState(tabID: tabID) { [weak self] isPlaying in
            guard let self else { return }
            self.mediaPlaybackCheckInProgress = false
            guard let isPlaying else { return }
            self.mediaPlaybackRevision &+= 1
            if Date() >= self.mediaActionOverrideUntil {
                self.notch.mediaPaused = !isPlaying
            }
            if isPlaying && self.notch.startupSplash {
                self.notch.startupSplash = false
            }
        }
    }

    private func updateMediaDetails(_ media: MediaInfo, updatePlaybackState: Bool = true) {
        if updatePlaybackState && Date() >= mediaActionOverrideUntil {
            notch.mediaPaused = media.isPaused
        }
        if Date() >= mediaTimeOverrideUntil {
            notch.mediaCurrentTime = media.currentTime
        }
        notch.mediaDuration = media.duration
        if !media.title.isEmpty && (notch.mediaTitle.isEmpty || currentMediaTitle == media.title) {
            notch.mediaTitle = media.title
        }
        guard !media.thumbnailURL.isEmpty, media.thumbnailURL != loadedThumbnailURL,
              let url = URL(string: media.thumbnailURL) else { return }
        loadedThumbnailURL = media.thumbnailURL
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loadedThumbnailURL == media.thumbnailURL else { return }
                self.notch.mediaThumbnail = image
            }
        }.resume()
    }

    // MARK: Window Geometry

    private func resizeWindow(animated: Bool = true, durationOverride: TimeInterval? = nil) {
        guard let screen = NSScreen.notchScreen else { return }

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if developerMode.presentation == .console {
            targetWidth = 720
            targetHeight = 660
        } else if developerMode.presentation == .authenticating || developerMode.presentation.isDeveloperMessage {
            targetWidth = 410
            targetHeight = 168
        } else if notch.noNetworkAlertActive {
            targetWidth = idleWidth
            targetHeight = noNetworkAlertHeight
        } else if notch.lowBatteryAlertPercent != nil {
            targetWidth = activeWidth
            targetHeight = idleHeight
        } else if notch.bluetoothAlertState != nil {
            targetWidth = SystemBluetooth.alertWidth
            targetHeight = SystemBluetooth.alertHeight
        } else if notch.focusAlertState != nil {
            targetWidth = SystemFocus.alertWidth
            targetHeight = idleHeight
        } else if notch.appSwitchIcon != nil {
            targetWidth = appSwitchWidth
            targetHeight = idleHeight
        } else if notch.startupSplash {
            targetWidth = 260
            targetHeight = 132
        } else if notch.incomingNotification != nil {
            targetWidth = 370
            targetHeight = 112
        } else if notch.whatsAppMessageActive {
            let count = max(1, min(4, notch.whatsAppMessages.count))
            // One sender gets a compact card. Each additional sender adds one
            // row of height and only a modest amount of width.
            if count == 1 && notch.whatsAppOverflowCount == 0 {
                targetWidth = cardWidth
            } else {
                targetWidth = min(
                    multiMessageBaseWidth + CGFloat(max(0, count - 2)) * 12,
                    282
                )
            }
            targetHeight = singleMessageHeight + CGFloat(max(0, count - 1)) * messageRowHeight
        } else if notch.volumeHUD || notch.whatsAppCallActive || notch.whatsAppInCall {
            targetWidth = activeWidth
            targetHeight = idleHeight
        } else if notch.expanded && notch.mediaPlaying {
            targetWidth = activeWidth
            targetHeight = 218
        } else if notch.mediaPlaying {
            targetWidth = CaptureActivityState.compactMediaWidth(for: notch.captureActivity, baseWidth: activeWidth)
            targetHeight = idleHeight
        } else if notch.expanded
                    || notch.chargingIndicatorActive
                    || notch.systemTimerActive {
            targetWidth = activeWidth
            targetHeight = idleHeight
        } else if notch.captureActivity.hasActivity {
            targetWidth = CaptureActivityState.idleWidth(for: notch.captureActivity, baseWidth: idleWidth)
            targetHeight = idleHeight
        } else {
            targetWidth = idleWidth
            targetHeight = idleHeight
        }

        let windowHeight = targetHeight

        // Keep the top edge aligned with the physical screen edge in every
        // state, so the notification grows down from the original notch.
        let panelY = screen.frame.maxY - windowHeight

        let frame = NSRect(
            x: screen.frame.midX - targetWidth / 2,
            y: panelY,
            width: targetWidth,
            height: windowHeight
        )

        guard abs(currentWidth - targetWidth) > 1
                || abs(currentHeight - windowHeight) > 1
                || abs(panel.frame.origin.y - panelY) > 1
                || abs(panel.frame.origin.x - frame.origin.x) > 1 else {
            syncMirroredNotches(animated: false)
            return
        }

        resizeAnimationGeneration += 1
        let animationGeneration = resizeAnimationGeneration
        let startingFrame = panel.frame
        currentWidth = targetWidth
        currentHeight = windowHeight

        if animated {
            let isOpening = windowHeight > panel.frame.height || targetWidth > panel.frame.width
            let settings = DeveloperAnimationSettings.shared
            let duration = isOpening
                ? settings.effectiveExpansionDuration
                : settings.effectiveCollapseDuration
            if settings.reduceMotion || duration == 0 {
                panel.setFrame(frame, display: true)
                notch.needsDisplay = true
                syncMirroredNotches(animated: false)
                return
            }
            let animationDuration = durationOverride ?? (notch.appSwitchIcon != nil
                ? appSwitchExpansionDuration
                : duration)
            animateNotchFrame(
                frame,
                from: startingFrame,
                duration: animationDuration,
                settings: settings,
                generation: animationGeneration
            )
        } else {
            panel.setFrame(frame, display: true)
            notch.needsDisplay = true
        }
        syncMirroredNotches(animated: animated, durationOverride: durationOverride)
    }

    /// Apply a subtle, adjustable overshoot to the shared notch window resize.
    /// Keeping it here makes the motion consistent across all live activities.
    private func animateNotchFrame(
        _ finalFrame: NSRect,
        from startingFrame: NSRect,
        duration: TimeInterval,
        settings: DeveloperAnimationSettings,
        generation: Int
    ) {
        guard duration > 0, settings.springResponsiveness > 0.01 else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = settings.timingFunction
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(finalFrame, display: true)
            }
            return
        }

        let widthDelta = finalFrame.width - startingFrame.width
        let heightDelta = finalFrame.height - startingFrame.height
        let bounce = settings.springResponsiveness
        let widthOvershoot = widthDelta == 0 ? 0 : min(finalFrame.width * 0.018 * bounce, abs(widthDelta) * 0.22)
        let heightOvershoot = heightDelta == 0 ? 0 : min(finalFrame.height * 0.022 * bounce, abs(heightDelta) * 0.22)
        guard widthOvershoot > 0.15 || heightOvershoot > 0.15 else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = settings.timingFunction
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(finalFrame, display: true)
            }
            return
        }

        let overshootWidth = max(1, finalFrame.width + (widthDelta > 0 ? widthOvershoot : -widthOvershoot))
        let overshootHeight = max(1, finalFrame.height + (heightDelta > 0 ? heightOvershoot : -heightOvershoot))
        let screenTop = finalFrame.maxY
        let overshootFrame = NSRect(
            x: finalFrame.midX - overshootWidth / 2,
            y: screenTop - overshootHeight,
            width: overshootWidth,
            height: overshootHeight
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration * 0.78
            context.timingFunction = settings.timingFunction
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(overshootFrame, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.resizeAnimationGeneration == generation else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration * 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    self.panel.animator().setFrame(finalFrame, display: true)
                }
            }
        })
    }

    // MARK: Cleanup

    func applicationWillTerminate(_ notification: Notification) {
        developerMode.lockDeveloperMode(reason: .applicationTerminated)
        displaySyncTimer?.invalidate()
        displaySyncTimer = nil
        pointerAcceptanceTimer?.invalidate()
        pointerAcceptanceTimer = nil
        for mirror in mirroredNotches.values { mirror.panel.orderOut(nil) }
        mirroredNotches.removeAll()
        timers.forEach { $0.invalidate() }
        timers.removeAll()

        appSwitchTimer?.invalidate()
        currentAppIconTimer?.invalidate()
        incomingNotificationTimer?.invalidate()
        volumeAnimationTimer?.invalidate()
        callTimer?.invalidate()
        chargingDismissTimer?.invalidate()
        systemAlertTimer?.invalidate()
        focusStatusTimer?.invalidate()
        youtubePollingTimer?.invalidate()
        youtubePollingTimer = nil
        networkMonitor.cancel()

        systemStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        systemStateObservers.removeAll()

        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                appActivationObserver
            )
        }
        developerSessionObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        developerSessionObservers.removeAll()
    }
}

// MARK: - Entry Point

#if !GRASS_ISLAND_REGRESSION
@main
@MainActor
enum GrassIslandMain {
    static func main() {
        if CommandLine.arguments.contains("--notification-smoke-test") {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            Task { @MainActor in
                let (success, result) = await InboxNotifications.runSmokeTest()
                print(success ? "PASS: \(result)" : "FAIL: \(result)")
                exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(45))
            exit(EXIT_FAILURE)
        }

        let app = NSApplication.shared
        let delegate = GrassIslandAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
#endif
