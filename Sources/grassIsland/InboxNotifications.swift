import AppKit
import Foundation
import UserNotifications

/// Delivers incoming inbox messages through the system Notification Center.
enum InboxNotifications {
    static let maximumBundleNotifications = 30
    /// UserNotifications requires the process to have a registered .app bundle.
    /// A bare `swift run` executable has no bundle proxy, and asking for the
    /// system notification center in that process raises an Objective-C
    /// exception instead of returning an error.
    static var hasApplicationBundle: Bool {
        let bundle = Bundle.main
        return bundle.bundleURL.pathExtension == "app"
            && bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == "com.grassisland.app"
    }

    static func configure() {
        guard hasApplicationBundle else {
            NSLog("[InboxNotifications] skipped: system notifications require the packaged grassIsland.app bundle")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("[InboxNotifications] authorization failed: %@", error.localizedDescription)
                print("[InboxNotifications] authorization failed: \(error.localizedDescription)")
            } else if !granted {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    NSLog("[InboxNotifications] alerts are unavailable (authorization status: %ld)", settings.authorizationStatus.rawValue)
                    print("[InboxNotifications] alerts unavailable; authorization status \(settings.authorizationStatus.rawValue)")
                }
            } else {
                NSLog("[InboxNotifications] notification access is authorized")
                print("[InboxNotifications] notification access is authorized")
            }
        }
    }

    static func content(for message: InboxMessage) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(message.service) · \(message.sender.isEmpty ? message.account : message.sender)"
        content.subtitle = message.subject
        if message.service == "Gmail" {
            let sender = message.senderEmail.isEmpty ? message.sender : "\(message.sender) <\(message.senderEmail)>"
            let preview = message.preview.isEmpty ? "" : "\n\(message.preview)"
            content.body = "To: \(message.account)\nFrom: \(sender)\(preview)"
        } else {
            content.body = message.preview.isEmpty ? "New WhatsApp message" : message.preview
        }
        content.sound = .default
        content.threadIdentifier = "inbox-\(message.service.lowercased())-\(message.account)"
        content.userInfo = ["sourceURL": message.sourceURL]
        if let logoURL = brandAttachmentURL(for: message.service) {
            do {
                let attachment = try UNNotificationAttachment(
                    identifier: "\(message.service.lowercased())-logo",
                    url: logoURL,
                    options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
                )
                content.attachments = [attachment]
            } catch {
                NSLog("[InboxNotifications] logo attachment failed: %@", error.localizedDescription)
            }
        }
        return content
    }

    static func brandLogoURL(for service: String) -> URL? {
        let name = service.caseInsensitiveCompare("Gmail") == .orderedSame ? "gmail" : "whatsapp"
        if let bundled = Bundle.main.url(forResource: name, withExtension: "png") {
            return bundled
        }
#if !GRASS_ISLAND_REGRESSION
        if let packaged = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Assets") {
            return packaged
        }
#endif
        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(name).png")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    static func brandAttachmentURL(for service: String) -> URL? {
        let name = service.caseInsensitiveCompare("Gmail") == .orderedSame ? "gmail" : "whatsapp"
        if let bundled = Bundle.main.url(forResource: name, withExtension: "jpg") {
            return bundled
        }
#if !GRASS_ISLAND_REGRESSION
        if let packaged = Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "Assets") {
            return packaged
        }
#endif
        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(name).jpg")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    static func brandLogo(for service: String) -> NSImage? {
        brandLogoURL(for: service).flatMap(NSImage.init(contentsOf:))
    }

    static func post(_ message: InboxMessage) {
        guard hasApplicationBundle else { return }
        let request = UNNotificationRequest(
            identifier: message.id,
            content: content(for: message),
            trigger: nil
        )
        let service = message.service
        let sender = message.sender
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[InboxNotifications] failed to post notification: %@", error.localizedDescription)
                print("[InboxNotifications] failed to post notification: \(error.localizedDescription)")
            } else {
                NSLog("[InboxNotifications] posted %@ notification for %@", service, sender)
                print("[InboxNotifications] posted \(service) notification")
            }
        }
    }

    /// Posts at most 30 original messages, grouped into one Notification Center
    /// thread. This bounds Notification Center work even after a long offline period.
    static func postBundle(_ messages: [InboxMessage]) {
        guard hasApplicationBundle, !messages.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let requests = bundleRequests(for: messages)
        for request in requests {
            let notificationTitle = request.content.title
            center.add(request) { error in
                if let error {
                    NSLog("[InboxNotifications] failed to post bundled message: %@", error.localizedDescription)
                    print("[InboxNotifications] failed to post bundled message: \(error.localizedDescription)")
                } else {
                    NSLog("[InboxNotifications] queued message notification: %@", notificationTitle)
                    print("[InboxNotifications] queued message notification: \(notificationTitle)")
                }
            }
        }
    }

    static func bundleContents(for messages: [InboxMessage], limit: Int = 30) -> [UNMutableNotificationContent] {
        guard limit > 0 else { return [] }
        return messages.prefix(min(limit, maximumBundleNotifications)).map { message in
            let messageContent = content(for: message)
            messageContent.threadIdentifier = "inbox-bundle-\(message.service.lowercased())"
            return messageContent
        }
    }

    static func bundleRequests(for messages: [InboxMessage]) -> [UNNotificationRequest] {
        let batchID = UUID().uuidString
        return bundleContents(for: messages).enumerated().map { index, messageContent in
            UNNotificationRequest(
                identifier: "grassIsland.inbox.bundle.\(batchID).\(index)",
                content: messageContent,
                trigger: nil
            )
        }
    }

    @MainActor
    static func runSmokeTest() async -> (Bool, String) {
        guard hasApplicationBundle else {
            return (false, "System notifications require the packaged grassIsland.app bundle.")
        }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                settings = await center.notificationSettings()
            } catch {
                return (false, "Notification authorization request failed: \(error.localizedDescription)")
            }
        }
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return (false, "Notification authorization status: \(settings.authorizationStatus.rawValue)")
        }
        let identifier = "grassIsland-regression-\(UUID().uuidString)"
        let sample = InboxMessage(
            id: identifier,
            service: "Gmail",
            account: "recipient@example.com",
            sender: "Regression Sender",
            senderEmail: "sender@example.com",
            subject: "Notification delivery check",
            preview: "Sample message content",
            receivedAt: Date(),
            fingerprint: identifier,
            sourceURL: "https://mail.google.com/",
            isRead: false
        )
        guard let request = bundleRequests(for: [sample]).first else {
            return (false, "Could not create a message notification request.")
        }
        let smokeRequest = UNNotificationRequest(identifier: identifier, content: request.content, trigger: nil)
        do {
            try await center.add(smokeRequest)
            try await Task.sleep(for: .seconds(1))
            let found = await center.deliveredNotifications().contains {
                $0.request.identifier == identifier
                    && $0.request.content.title == "Gmail · Regression Sender"
                    && $0.request.content.subtitle == "Notification delivery check"
                    && $0.request.content.body.contains("Sample message content")
            }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return (found, found
                ? "A real Gmail message notification appeared in Notification Center with its subject and body."
                : "The message notification request was accepted but the expected title, subject, and body were not found in Notification Center.")
        } catch {
            return (false, "Notification add failed: \(error.localizedDescription)")
        }
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static let shared = NotificationDelegate()
    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["sourceURL"] as? String,
           let url = URL(string: urlString) {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
