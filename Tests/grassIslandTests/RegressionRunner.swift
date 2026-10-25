import AppKit
import Darwin

@main
@MainActor
struct GrassIslandRegressionRunner {
    static func main() async {
        var failures: [String] = []
        run("Gmail parser preserves recipient and message details", failures: &failures) {
            let payload = #"{"account":"me@example.com","inboxVisible":true,"messages":[{"sender":"Ada Lovelace","senderEmail":"ada@example.org","subject":"Build report","preview":"The report is ready","fingerprint":"me::ada::report","sourceURL":"https://mail.google.com/mail/u/0/#inbox/thread-1"}]}"#
            guard let scan = GmailMonitor.parseOutput(payload),
                  scan.scannedInboxAccounts == ["me@example.com"],
                  scan.messages.count == 1 else { return false }
            let message = scan.messages[0]
            return message.account == "me@example.com"
                && message.senderEmail == "ada@example.org"
                && message.subject == "Build report"
                && message.preview == "The report is ready"
                && message.sourceURL.contains("thread-1")
        }

        run("Gmail scan errors are not treated as an empty inbox", failures: &failures) {
            GmailMonitor.parseOutput("NO_GMAIL") == nil
                && GmailMonitor.parseOutput("GMAIL_ERROR::JavaScript from Apple Events is disabled") == nil
        }

        run("WhatsApp parser preserves contact and preview", failures: &failures) {
            let payload = #"{"type":"MSG","activePage":true,"overflowCount":0,"messages":[{"name":"Grace","avatarURL":"https://example.org/avatar.png","fingerprint":"grace::hello::10:30","preview":"Hello there"}]}"#
            guard let state = WhatsAppMonitor.parseOutput("ACTIVE_PAGE|||" + payload), state.messages.count == 1 else { return false }
            return state.hasNewMessage
                && state.messages[0].name == "Grace"
                && state.messages[0].preview == "Hello there"
                && state.messages[0].fingerprint == "grace::hello::10:30"
                && state.isActivePage
        }

        run("WhatsApp messages seen on the active page are discarded instead of replayed", failures: &failures) {
            let viewedMessage = WhatsAppMessageItem(name: "Grace", avatarURL: "", fingerprint: "grace::seen::10:30", preview: "Seen")
            let newMessage = WhatsAppMessageItem(name: "Lin", avatarURL: "", fingerprint: "lin::new::10:31", preview: "New")
            var filter = WhatsAppNotificationFilter()
            let whileViewing = filter.notifications(from: [viewedMessage], whilePageIsActive: true)
            let afterLeaving = filter.notifications(from: [viewedMessage], whilePageIsActive: false)
            let freshAfterLeaving = filter.notifications(from: [viewedMessage, newMessage], whilePageIsActive: false)
            return whileViewing.isEmpty
                && afterLeaving.isEmpty
                && freshAfterLeaving.map(\.fingerprint) == [newMessage.fingerprint]
        }

        run("WhatsApp call parser remains distinct from message parser", failures: &failures) {
            guard let state = WhatsAppMonitor.parseOutput(#"{"type":"CALL","sender":"Lin","callLabel":"Incoming Video Call"}"#) else { return false }
            return state.hasIncomingCall && state.callerName == "Lin"
                && state.incomingCallLabel == "Incoming Video Call" && state.messages.isEmpty
                && !state.isActivePage
        }

        run("WhatsApp JavaScript string is escaped for AppleScript", failures: &failures) {
            let source = WhatsAppMonitor.pollingAppleScript(chromeIsFrontmost: true)
                .replacingOccurrences(of: "set jsResult to execute t javascript", with: "set jsResult to")
            guard let script = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            if !compiled, let error { print("AppleScript compile diagnostic: \(error)") }
            return compiled && source.contains("document.hasFocus()")
        }

        run("WhatsApp rows stay below the physical notch cutout", failures: &failures) {
            let safeTop: CGFloat = 37
            let single = NotchView.whatsAppFirstRowCenterY(
                in: NSRect(x: 0, y: 0, width: 246, height: 100), safeTop: safeTop
            )
            let multiBounds = NSRect(x: 0, y: 0, width: 282, height: 214)
            let first = NotchView.whatsAppFirstRowCenterY(in: multiBounds, safeTop: safeTop)
            let last = first - 3 * 38
            let visibleHeight = multiBounds.height - safeTop
            return single + 18 <= 100 - safeTop
                && first + 18 <= visibleHeight
                && last - 16 >= 0
        }

        run("app-switch icon waits for the sideways expansion before appearing", failures: &failures) {
            let duringExpansion = NotchView.appSwitchOpacity(after: 0.2, expansionDuration: 0.38)
            let beginningFadeIn = NotchView.appSwitchOpacity(after: 0.42, expansionDuration: 0.38)
            let fullyVisible = NotchView.appSwitchOpacity(after: 0.7, expansionDuration: 0.38)
            return duringExpansion == 0
                && beginningFadeIn > 0 && beginningFadeIn < 1
                && fullyVisible == 1
        }

        run("low battery alerts fire once when descending through each threshold", failures: &failures) {
            SystemBattery.crossedAlertThresholds(previousPercent: 11, currentPercent: 10, isCharging: false) == [10]
                && SystemBattery.crossedAlertThresholds(previousPercent: 6, currentPercent: 5, isCharging: false) == [5]
                && SystemBattery.crossedAlertThresholds(previousPercent: 3, currentPercent: 2, isCharging: false) == [2]
                && SystemBattery.crossedAlertThresholds(previousPercent: 11, currentPercent: 4, isCharging: false) == [10, 5]
                && SystemBattery.crossedAlertThresholds(previousPercent: 11, currentPercent: 10, isCharging: true).isEmpty
                && SystemBattery.crossedAlertThresholds(previousPercent: 9, currentPercent: 10, isCharging: false).isEmpty
        }

        run("network alert appears only for a connected-to-disconnected transition or initial offline state", failures: &failures) {
            SystemNetwork.shouldShowDisconnectAlert(previouslyConnected: true, connected: false)
                && !SystemNetwork.shouldShowDisconnectAlert(previouslyConnected: true, connected: true)
                && !SystemNetwork.shouldShowDisconnectAlert(previouslyConnected: false, connected: false)
                && SystemNetwork.shouldShowDisconnectAlert(previouslyConnected: nil, connected: false)
        }

        run("Bluetooth power changes trigger a short sideways-only notch alert", failures: &failures) {
            !SystemBluetooth.didPowerStateChange(previous: nil, current: true)
                && !SystemBluetooth.didPowerStateChange(previous: true, current: true)
                && SystemBluetooth.didPowerStateChange(previous: true, current: false)
                && SystemBluetooth.didPowerStateChange(previous: false, current: true)
                && SystemBluetooth.alertWidth > 210
                && SystemBluetooth.alertWidth > 320
                && SystemBluetooth.alertWidth < 420
                && SystemBluetooth.alertHeight == 34
        }

        run("Focus status changes show the purple crescent alert in a narrow sideways panel", failures: &failures) {
            !SystemFocus.didStatusChange(previous: nil, current: true)
                && !SystemFocus.didStatusChange(previous: false, current: false)
                && SystemFocus.didStatusChange(previous: false, current: true)
                && SystemFocus.didStatusChange(previous: true, current: false)
                && SystemFocus.alertWidth > 320 && SystemFocus.alertWidth < 420
                && NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil) != nil
        }

        run("Developer Mode starts locked with no persisted authentication state", failures: &failures) {
            let manager = DeveloperModeManager()
            return manager.presentation == .closed && !manager.isAuthenticated
        }

        run("Developer preview states are sandbox-only and include required states", failures: &failures) {
            let previews = Set(DeveloperPreview.allCases)
            return previews.count == 9
                && previews.contains(.compact)
                && previews.contains(.music)
                && previews.contains(.notification)
                && previews.contains(.timer)
                && previews.contains(.fileTransfer)
                && previews.contains(.warning)
                && previews.contains(.authenticationSuccess)
                && previews.contains(.authenticationFailure)
        }

        run("developer event log is bounded and contains only its explicit event message", failures: &failures) {
            let logger = DeveloperEventLog.shared
            logger.clear()
            for index in 0..<(DeveloperEventLog.capacity + 5) {
                logger.append("Test", "Event \(index)")
            }
            return logger.entries.count == DeveloperEventLog.capacity
                && logger.entries.last?.message == "Event \(DeveloperEventLog.capacity + 4)"
                && !logger.plainText.localizedCaseInsensitiveContains("password")
                && !logger.plainText.localizedCaseInsensitiveContains("token")
        }

        run("Gmail Notification Center content includes recipient, sender, and subject", failures: &failures) {
            let content = InboxNotifications.content(for: InboxMessage(
                id: "test-gmail", service: "Gmail", account: "me@example.com",
                sender: "Ada Lovelace", senderEmail: "ada@example.org",
                subject: "Build report", preview: "The report is ready",
                receivedAt: Date(timeIntervalSince1970: 1), fingerprint: "gmail::test",
                sourceURL: "https://mail.google.com/", isRead: false
            ))
            return content.title == "Gmail · Ada Lovelace"
                && content.subtitle == "Build report"
                && content.body.contains("me@example.com")
                && content.body.contains("ada@example.org")
                && content.body.contains("The report is ready")
                && content.threadIdentifier.contains("gmail")
        }

        run("message bundle preserves real message content and is capped at 30 notifications", failures: &failures) {
            let messages = [
                InboxMessage(id: "1", service: "Gmail", account: "me@example.com", sender: "Ada", senderEmail: "ada@example.org", subject: "One", preview: "", receivedAt: Date(), fingerprint: "g1", sourceURL: "https://mail.google.com", isRead: false),
                InboxMessage(id: "2", service: "WhatsApp", account: "WhatsApp Web", sender: "Lin", senderEmail: "", subject: "Two", preview: "Hi", receivedAt: Date(), fingerprint: "w1", sourceURL: "https://web.whatsapp.com", isRead: false)
            ]
            let contents = InboxNotifications.bundleContents(for: messages)
            let requests = InboxNotifications.bundleRequests(for: messages)
            let largeBatch = (0..<100).map { index in
                InboxMessage(id: "\(index)", service: "Gmail", account: "me@example.com", sender: "Sender \(index)", senderEmail: "sender@example.org", subject: "Subject \(index)", preview: "Body \(index)", receivedAt: Date(), fingerprint: "g\(index)", sourceURL: "https://mail.google.com", isRead: false)
            }
            return contents.count == 2
                && contents[0].title == "Gmail · Ada"
                && contents[0].body.contains("ada@example.org")
                && contents[1].title == "WhatsApp · Lin"
                && contents[1].body == "Hi"
                && contents.allSatisfy { $0.threadIdentifier.hasPrefix("inbox-bundle-") }
                && requests.count == 2
                && requests[0].content.title == contents[0].title
                && requests[0].content.subtitle == contents[0].subtitle
                && requests[0].content.body.contains("ada@example.org")
                && InboxNotifications.bundleContents(for: largeBatch).count == InboxNotifications.maximumBundleNotifications
                && InboxNotifications.bundleRequests(for: largeBatch).count == InboxNotifications.maximumBundleNotifications
        }

        run("notch idle height follows display safe-area depth and clear-all target fits", failures: &failures) {
            let bounds = NSRect(x: 0, y: 0, width: 370, height: 112)
            let clear = NotchView.inboxClearAllRect(in: bounds, visibleHeight: 78)
            return NotchView.idlePanelHeight(safeAreaTop: 37) == 37
                && NotchView.idlePanelHeight(safeAreaTop: 44) == 44
                && NotchView.idlePanelHeight(safeAreaTop: 30) == 34
                && bounds.contains(clear)
                && clear.width >= 60 && clear.height >= 18
        }

        run("each connected display gets its own top-centered notch frame", failures: &failures) {
            let firstDisplay = NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let secondDisplay = NSRect(x: 1920, y: -120, width: 2560, height: 1440)
            let first = NotchView.notchFrame(in: firstDisplay, width: 210, height: 44)
            let second = NotchView.notchFrame(in: secondDisplay, width: 210, height: 44)
            return first.midX == firstDisplay.midX
                && second.midX == secondDisplay.midX
                && first.maxY == firstDisplay.maxY
                && second.maxY == secondDisplay.maxY
                && first.origin != second.origin
        }

        run("Gmail and WhatsApp use real bundled brand marks for notch and notification imagery", failures: &failures) {
            let gmailURL = InboxNotifications.brandLogoURL(for: "Gmail")
            let whatsappURL = InboxNotifications.brandLogoURL(for: "WhatsApp")
            let gmailAttachmentURL = InboxNotifications.brandAttachmentURL(for: "Gmail")
            let whatsappAttachmentURL = InboxNotifications.brandAttachmentURL(for: "WhatsApp")
            guard let gmailURL, let whatsappURL,
                  let gmailAttachmentURL, let whatsappAttachmentURL else { return false }
            return NSImage(contentsOf: gmailURL) != nil
                && NSImage(contentsOf: whatsappURL) != nil
                && gmailURL.lastPathComponent == "gmail.png"
                && whatsappURL.lastPathComponent == "whatsapp.png"
                && FileManager.default.fileExists(atPath: gmailAttachmentURL.path)
                && FileManager.default.fileExists(atPath: whatsappAttachmentURL.path)
        }

        run("expanded clock and YouTube app icons fit beside the time without changing panel width", failures: &failures) {
            let expandedIcon = NotchView.expandedAppIconRect(timeWidth: 46, baselineY: 30)
            let mediaIcon = NotchView.mediaHeaderAppIconRect(timeWidth: 42, panelHeight: 218)
            return NotchView.shouldKeepExpandedShapeOnAppSwitch(isExpanded: true)
                && !NotchView.shouldKeepExpandedShapeOnAppSwitch(isExpanded: false)
                && expandedIcon.minX > 16 && expandedIcon.maxX < 120
                && mediaIcon.minX > 19 && mediaIcon.maxX < 120
                && expandedIcon.width == 16 && mediaIcon.width == 15
        }

        run("YouTube timeline and controls fit the reference-style expanded panel", failures: &failures) {
            let bounds = NSRect(x: 0, y: 0, width: 360, height: 218)
            let progress = NotchView.mediaProgressRect(in: bounds)
            let back = NotchView.mediaBackControlRect(in: bounds)
            let play = NotchView.mediaPlayControlRect(in: bounds)
            let forward = NotchView.mediaForwardControlRect(in: bounds)
            return bounds.contains(progress)
                && bounds.contains(back) && bounds.contains(play) && bounds.contains(forward)
                && progress.minX > 30 && progress.maxX < bounds.maxX - 30
                && progress.height >= 6
                && back.maxX < play.minX && play.maxX < forward.minX
        }

        run("notch input surface is limited to its visible bounds", failures: &failures) {
            let bounds = NSRect(x: 0, y: 0, width: 210, height: 34)
            return NotchView.shouldReceivePointer(at: NSPoint(x: 100, y: 20), in: bounds)
                && !NotchView.shouldReceivePointer(at: NSPoint(x: 100, y: 50), in: bounds)
                && !NotchView.shouldReceivePointer(at: NSPoint(x: 230, y: 20), in: bounds)
        }

        run("expanded notch passes pointer input through outside its controls", failures: &failures) {
            let bounds = NSRect(x: 0, y: 0, width: 370, height: 112)
            let clear = NotchView.inboxClearAllRect(in: bounds, visibleHeight: 75)
            let physicalNotchPoint = NSPoint(x: bounds.midX, y: 94)
            let tabBelowNotchPoint = NSPoint(x: 30, y: 58)
            let buttonPoint = NSPoint(x: clear.midX, y: clear.midY)
            return NotchView.shouldAcceptPointer(
                at: physicalNotchPoint, in: bounds, safeAreaTop: 37
            )
                && !NotchView.shouldAcceptPointer(
                    at: tabBelowNotchPoint, in: bounds, safeAreaTop: 37, extraHitTargets: [clear]
                )
                && NotchView.shouldAcceptPointer(
                    at: buttonPoint, in: bounds, safeAreaTop: 37, extraHitTargets: [clear]
                )
        }

        run("clear-all text origin is centered in its button", failures: &failures) {
            let button = NSRect(x: 292, y: 50, width: 64, height: 19)
            let textSize = NSSize(width: 34, height: 11)
            let origin = NotchView.centeredTextOrigin(textSize, in: button)
            return abs((origin.x + textSize.width / 2) - button.midX) < 0.001
                && abs((origin.y + textSize.height / 2) - button.midY) < 0.001
        }

        run("app bundle provides a real icon for Notification Center", failures: &failures) {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let plistURL = root.appendingPathComponent("Resources/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let iconName = plist["CFBundleIconFile"] as? String else { return false }
            return NSImage(contentsOf: root.appendingPathComponent("Resources").appendingPathComponent(iconName)) != nil
        }

        let iconDrawn = await MainActor.run { drawAppSwitchIconOnLeft() }
        if iconDrawn {
            print("PASS: app-switch view draws a larger icon in the left wing without a backing badge")
        } else {
            failures.append("app-switch view draws a larger icon in the left wing without a backing badge")
            print("FAIL: app-switch view draws a larger icon in the left wing without a backing badge")
        }

        print("Regression cases: 25 total, \(25 - failures.count) passed, \(failures.count) failed")
        if !failures.isEmpty {
            for failure in failures { print("FAILED: \(failure)") }
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ name: String, failures: inout [String], test: () -> Bool) {
        if test() {
            print("PASS: \(name)")
        } else {
            failures.append(name)
            print("FAIL: \(name)")
        }
    }

    private static func drawAppSwitchIconOnLeft() -> Bool {
        let bounds = NSRect(x: 0, y: 0, width: 294, height: 34)
        let iconRect = NotchView.appSwitchIconRect(in: bounds, baseNotchWidth: 210)
        let leftWingEnd = bounds.midX - 105
        guard iconRect.width == 27,
              iconRect.minY > (bounds.height - iconRect.height) / 2,
              iconRect.maxX <= leftWingEnd,
              iconRect.minX >= 0,
              iconRect.minY >= 0,
              iconRect.maxX <= bounds.maxX,
              iconRect.maxY <= bounds.maxY else { return false }

        let view = NotchView(frame: NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: bounds.height
        ))
        guard let iconRepresentation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        for x in 0..<16 {
            for y in 0..<16 {
                iconRepresentation.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        let appIcon = NSImage(size: NSSize(width: 16, height: 16))
        appIcon.addRepresentation(iconRepresentation)
        view.appSwitchIcon = appIcon
        view.appSwitchOpacity = 1

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(view.frame.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let iconPixel = bitmap.colorAt(x: Int(iconRect.midX), y: Int(bounds.height - iconRect.midY)) else { return false }
        return iconPixel.redComponent > 0.8
            && iconPixel.greenComponent < 0.3
            && iconPixel.blueComponent < 0.3
    }
}
