import AppKit
import Foundation
import UserNotifications

/// Delivers incoming inbox messages through the system Notification Center.
enum InboxNotifications {
    static func configure() {
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
        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(name).jpg")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    static func brandLogo(for service: String) -> NSImage? {
        brandLogoURL(for: service).flatMap(NSImage.init(contentsOf:))
    }

    static func post(_ message: InboxMessage) {
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

    @MainActor
    static func runSmokeTest() async -> (Bool, String) {
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
        let content = UNMutableNotificationContent()
        content.title = "grassIsland regression test"
        content.subtitle = "Notification Center delivery"
        content.body = "This test notification verifies system delivery."
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            try await Task.sleep(for: .seconds(1))
            let found = await center.deliveredNotifications().contains { $0.request.identifier == identifier }
            return (found, found
                ? "Test notification is present in Notification Center."
                : "Notification was accepted but is not in the delivered list.")
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
