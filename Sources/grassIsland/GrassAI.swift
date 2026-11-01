import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private enum GrassAIBackendError: LocalizedError {
    case invalidResponse
    case server(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "grassAI returned a response this app could not read."
        case .server(let message):
            return message
        case .http(let status):
            return "grassAI could not complete the request (HTTP \(status)). Please try again."
        }
    }
}

private struct GrassAIBackendResponse: Decodable {
    let success: Bool?
    let error: String?
    let message: String?
    let token: String?
    let usageCount: Int?
    let usageLimit: Int?
    let subscription: String?
}

private actor GrassAIBackend {
    static let shared = GrassAIBackend()
    private let endpoint = URL(string: "https://script.google.com/macros/s/AKfycbxpJ7bm8l-WmKg0oBX2DVgR8kU8DxlwtooJbBxpINkf3mqiEv0mQbySJcz5jWhc1SYpDw/exec")!
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 150
        session = URLSession(configuration: configuration)
    }

    func send(message: String, history: [GrassAIMessage], clientID: String, conversationID: String) async throws -> GrassAIBackendResponse {
        let historyPayload = history.map { ["text": $0.text, "sender": $0.role.rawValue] }
        let historyData = try JSONSerialization.data(withJSONObject: historyPayload)
        guard let historyJSON = String(data: historyData, encoding: .utf8) else {
            throw GrassAIBackendError.invalidResponse
        }
        let values = [
            "message": message,
            "history": historyJSON,
            "clientId": clientID,
            "conversationId": conversationID
        ]
        let response = try await post("grassNotchChat", values: values)
        guard let answer = response.message, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GrassAIBackendError.invalidResponse
        }
        return response
    }

    private func post(_ action: String, values: [String: String]) async throws -> GrassAIBackendResponse {
        // This request is form-urlencoded because Apps Script reads e.parameter.
        // URLComponents may leave '+' unescaped in query values; form decoders
        // interpret that character as a space, corrupting base64 image data.
        let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encodeFormComponent(_ value: String) throws -> String {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: formAllowed) else {
                throw GrassAIBackendError.invalidResponse
            }
            return encoded
        }
        var pairs = [(String, String)]()
        pairs.append(("action", action))
        pairs.append(contentsOf: values.keys.sorted().compactMap { key in
            values[key].map { (key, $0) }
        })
        let encodedPairs = try pairs.map { name, value in
            "\(try encodeFormComponent(name))=\(try encodeFormComponent(value))"
        }
        let body = Data(encodedPairs.joined(separator: "&").utf8)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GrassAIBackendError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GrassAIBackendError.http(http.statusCode) }
        let decoded: GrassAIBackendResponse
        do {
            decoded = try JSONDecoder().decode(GrassAIBackendResponse.self, from: data)
        } catch {
            throw GrassAIBackendError.invalidResponse
        }
        guard decoded.success == true else {
            throw GrassAIBackendError.server(decoded.error ?? "grassAI could not complete the request.")
        }
        return decoded
    }
}

private enum GrassAIClientIdentity {
    private static let key = "com.grassisland.grassai.installation-id"

    static var identifier: String {
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil {
            return saved
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}

struct GrassAIMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum GrassAIAnswerFormatter {
    static func format(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")

        func replace(_ pattern: String, with template: String) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }

        // Convert markup structure before removing its styling markers.
        replace("(?i)<br\\s*/?>", with: "\n")
        replace("(?i)<li\\b[^>]*>", with: "\n• ")
        replace("(?i)</li\\s*>", with: "\n")
        replace("(?i)</?(?:ul|ol)\\b[^>]*>", with: "\n")
        replace("(?i)<h[1-6]\\b[^>]*>", with: "\n\n**")
        replace("(?i)</h[1-6]\\s*>", with: "**\n\n")
        replace("(?i)<(?:p|div|section|article|blockquote)\\b[^>]*>", with: "\n\n")
        replace("(?i)</(?:p|div|section|article|blockquote)\\s*>", with: "\n\n")
        replace("(?i)</(strong|b)>\\s*<(strong|b)(?=[\\s>])", with: "</$1>\n<$2")
        replace("(?i)</(strong|b)>(?=[A-Za-z0-9])", with: "</$1>\n")
        replace("(?i)<(?:strong|b)\\b[^>]*>", with: "**")
        replace("(?i)</(?:strong|b)\\s*>", with: "**")
        replace("(?i)<(?:em|i)\\b[^>]*>", with: "*")
        replace("(?i)</(?:em|i)\\s*>", with: "*")
        replace("(?i)</?[a-z][^>]*>", with: " ")

        // Keep adjacent Markdown headings separate, including malformed
        // responses that concatenate bold labels without whitespace.
        text = text.replacingOccurrences(of: "****", with: "**\n\n**")
        replace("\\*\\*([^*\\n]+)\\*\\*(?=[A-Za-z0-9])", with: "**$1**\n")
        replace("(?<=[A-Za-z0-9])\\*\\*([^*\\n]+)\\*\\*", with: "\n**$1**")
        replace("(?m)^\\s{0,3}#{1,6}\\s*", with: "\n\n**")
        replace("(?m)^\\s*[-*+]\\s+", with: "• ")
        replace("(?m)^\\s*\\d+[.)]\\s+", with: "• ")
        replace("(?m)^\\*\\*([^*\\n]+)\\*\\*\\s*$", with: "$1:")
        replace("\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "$1 ($2)")

        // Strip inline emphasis/code markers so malformed model output can
        // never expose Markdown punctuation to the person reading the answer.
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        replace("\\*+", with: "")
        replace("(?<!\\w)_{1,2}|_{1,2}(?!\\w)", with: "")
        replace("(?m)^#{1,6}\\s*", with: "")

        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&amp;", with: "&")

        // Restore spaces between accidentally concatenated CamelCase words,
        // while protecting common product names that intentionally use it.
        let protectedNames = [
            "YouTube", "YouTubeMusic", "macOS", "iOS", "iPadOS", "iPhone", "iPad",
            "tvOS", "ChatGPT", "OpenAI", "GitHub", "SwiftUI", "grassAI", "grassNotch",
            "NotchOS", "WhatsApp", "JavaScript", "TypeScript", "PowerPoint", "AppKit",
            "AppleScript", "URLSession", "Xcode", "iCloud", "iMessage", "Gmail", "GoogleDrive"
        ]
        var tokens: [String: String] = [:]
        for (index, name) in protectedNames.enumerated() {
            let token = "\u{E000}\(index)\u{E001}"
            text = text.replacingOccurrences(of: name, with: token)
            tokens[token] = name
        }
        replace("(?<=[a-z0-9])(?=[A-Z])", with: " ")
        for (token, name) in tokens {
            text = text.replacingOccurrences(of: token, with: name)
        }

        replace("[ \\t]+", with: " ")
        replace("[ \\t]+\\n", with: "\n")
        replace("\\n{3,}", with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return addPunctuation(text)
    }

    private static func addPunctuation(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            if trimmed.hasSuffix(":") { return trimmed }

            let content = trimmed.hasPrefix("• ") ? String(trimmed.dropFirst(2)) : trimmed
            guard let last = content.last else { return trimmed }
            if ".!?…:;".contains(last) { return trimmed }
            guard last.isLetter || last.isNumber || [")", "]", "}", "\"", "’", "'"].contains(String(last)) else {
                return trimmed
            }
            return trimmed + "."
        }.joined(separator: "\n")
    }
}

@MainActor
final class GrassAIModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var promptFocusRequest = 0
    @Published private(set) var isThinking = false
    @Published private(set) var messages: [GrassAIMessage] = []
    @Published var draft = ""
    @Published var errorMessage: String?
    @Published private(set) var usageCount: Int?
    @Published private(set) var usageLimit: Int?

    var onPresentationChange: ((Bool) -> Void)?
    var onConversationChange: (() -> Void)?
    var onThinkingChange: ((Bool) -> Void)?
    private var requestID: UUID?
    private var conversationID = UUID().uuidString

    var notchPanelSize: (width: CGFloat, height: CGFloat) {
        guard !messages.isEmpty || isThinking || errorMessage != nil else {
            return (430, 158)
        }

        // Only the latest answer is visible; prior prompts and replies remain
        // available to backend context without turning the notch into a chat log.
        let answer = messages.last(where: { $0.role == .assistant })?.text ?? ""
        let estimatedLines = max(1, Int(ceil(Double(answer.count) / 56)))
        let errorHeight = errorMessage == nil ? 0 : 32
        let height = min(330, max(178, 148 + CGFloat(estimatedLines) * 17 + CGFloat(errorHeight)))
        return (460, height)
    }

    func present() {
        guard !isPresented else { return }
        startNewConversation()
        isPresented = true
        onPresentationChange?(true)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        onPresentationChange?(false)
    }

    func requestPromptFocus() {
        promptFocusRequest &+= 1
    }

    func submitDraft() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }

        let currentRequest = UUID()
        requestID = currentRequest
        let userMessage = GrassAIMessage(role: .user, text: prompt)
        messages.append(userMessage)
        draft = ""
        errorMessage = nil
        isThinking = true
        onThinkingChange?(true)
        onConversationChange?()
        defer {
            if requestID == currentRequest {
                isThinking = false
                onThinkingChange?(false)
            }
        }

        do {
            let result = try await GrassAIBackend.shared.send(
                message: prompt,
                history: messages,
                clientID: GrassAIClientIdentity.identifier,
                conversationID: conversationID
            )
            guard requestID == currentRequest else { return }
            messages.append(GrassAIMessage(role: .assistant, text: result.message ?? ""))
            usageCount = result.usageCount
            usageLimit = result.usageLimit
            onConversationChange?()
        } catch {
            guard requestID == currentRequest else { return }
            messages.removeAll { $0.id == userMessage.id }
            onConversationChange?()
            draft = prompt
            errorMessage = error.localizedDescription
        }
    }

    func startNewConversation() {
        // Invalidate any in-flight reply so it cannot repopulate the cleared
        // conversation when it eventually returns.
        requestID = nil
        if isThinking {
            isThinking = false
            onThinkingChange?(false)
        }
        draft = ""
        messages.removeAll()
        onConversationChange?()
        usageCount = nil
        usageLimit = nil
        errorMessage = nil
        conversationID = UUID().uuidString
    }
}

struct GrassAIView: View {
    @ObservedObject var model: GrassAIModel
    let safeAreaTop: CGFloat
    let allowsInput: Bool
    var onPromptInteraction: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case prompt }

    var body: some View {
        Group {
            if model.isPresented {
                panelContent
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9), value: model.isPresented)
        .onChange(of: model.isPresented) { _, presented in
            guard presented, allowsInput else { return }
            focusAppropriateField()
        }
        .onChange(of: model.promptFocusRequest) { _, _ in
            focusAppropriateField()
        }
        .onChange(of: model.messages.count) { _, _ in
            guard model.isPresented, allowsInput else { return }
            focusedField = .prompt
        }
        .onChange(of: model.isThinking) { _, thinking in
            if !thinking, model.isPresented, allowsInput { focusAppropriateField() }
        }
        .onExitCommand { model.dismiss() }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(grassGradient)
                Text("grassAI")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if let usageCount = model.usageCount, let usageLimit = model.usageLimit {
                    Text("\(usageCount)/\(usageLimit)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Button(action: model.startNewConversation) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 25, height: 25)
                        .background(.white.opacity(0.075), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete conversation")
                .help("Delete conversation")
                Button(action: model.dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 27, height: 27)
                        .background(.white.opacity(0.09), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close grassAI")
                .help("Close grassAI")
            }
            .buttonStyle(.plain)
            .padding(.bottom, model.messages.isEmpty ? 7 : 9)

            if !allowsInput {
                answerContent
            } else {
                answerContent
                promptField
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, max(6, safeAreaTop + 3))
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                Color.black
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.52, blue: 0.35).opacity(0.20),
                        Color(red: 0.20, green: 0.36, blue: 0.82).opacity(0.19),
                        Color(red: 0.48, green: 0.24, blue: 0.78).opacity(0.20),
                        Color(red: 1.0, green: 0.34, blue: 0.16).opacity(0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blur(radius: 24)
                .blendMode(.screen)
            }
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(grassGradient.opacity(0.34), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.isThinking)
    }

    private var answerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let answer = model.messages.last(where: { $0.role == .assistant }) {
                    markdown(answer.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.93))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.44))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 10) {
            TextField("Message grassAI…", text: $model.draft)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .tint(Color(red: 0.42, green: 0.91, blue: 0.63))
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .prompt)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    guard allowsInput, !model.isThinking else { return }
                    onPromptInteraction?()
                })
                .onSubmit { Task { await model.submitDraft() } }
                .disabled(model.isThinking)
                .overlay(alignment: .leading) {
                    if focusedField == .prompt {
                        GeometryReader { geometry in
                            TimelineView(.periodic(from: .now, by: 0.48)) { timeline in
                                let visible = Int(timeline.date.timeIntervalSinceReferenceDate / 0.48).isMultiple(of: 2)
                                Capsule()
                                    .fill(grassGradient)
                                    .frame(width: 2, height: 17)
                                    .opacity(visible ? 1 : 0)
                                    .position(
                                        x: min(draftCaretX, max(1, geometry.size.width - 2)),
                                        y: geometry.size.height / 2
                                    )
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            Button {
                Task { await model.submitDraft() }
            } label: {
                Image(systemName: model.isThinking ? "waveform" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(
                            model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isThinking
                                ? AnyShapeStyle(Color.white.opacity(0.14))
                                : AnyShapeStyle(grassGradient)
                        )
                    }
            }
            .buttonStyle(.plain)
            .disabled(model.isThinking || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(minHeight: 44)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(grassGradient.opacity(0.42), lineWidth: 0.8))
        }
        .padding(.top, 12)
    }

    private var draftCaretX: CGFloat {
        guard !model.draft.isEmpty else { return 1 }
        let text = NSAttributedString(
            string: model.draft,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        return ceil(text.size().width) + 2
    }

    private func markdown(_ source: String) -> Text {
        Text(GrassAIAnswerFormatter.format(source))
    }

    private func focusAppropriateField() {
        guard allowsInput else { return }
        Task { @MainActor in
            // FocusState can remain `.prompt` after the panel resigns key
            // status, even though AppKit has dropped the actual text-field
            // first responder. Force a real focus transition so the field
            // becomes editable again after returning from another app.
            focusedField = nil
            await Task.yield()
            focusedField = .prompt
        }
    }

    private var grassGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.88, blue: 0.57),
                Color(red: 0.25, green: 0.72, blue: 0.91),
                Color(red: 0.53, green: 0.48, blue: 0.98),
                Color(red: 0.72, green: 0.42, blue: 0.91),
                Color(red: 1.0, green: 0.46, blue: 0.24)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

}

@MainActor
final class GrassAIEdgeGlowController {
    private var window: NSPanel?
    private var generation = UUID()

    func show(on screen: NSScreen) {
        generation = UUID()
        let currentGeneration = generation
        window?.orderOut(nil)

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar - 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let glowHost = NSHostingView(rootView: GrassAIEdgeGlowView(startedAt: Date()))
        glowHost.wantsLayer = true
        glowHost.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = glowHost
        panel.alphaValue = 1
        window = panel
        panel.orderFrontRegardless()

        // Let the traveling edge finish, hold briefly, then let the SwiftUI
        // stroke fade away before removing its transparent panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.94) { [weak self, weak panel] in
            guard let self, let panel, self.generation == currentGeneration else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    guard let self, let panel, self.generation == currentGeneration else { return }
                    panel.orderOut(nil)
                    if self.window === panel { self.window = nil }
                }
            })
        }
    }
}

private struct GrassAIEdgeGlowView: View {
    let startedAt: Date

    private let colors: [Color] = [
        Color(red: 0.38, green: 1.0, blue: 0.58),
        Color(red: 0.22, green: 0.78, blue: 1.0),
        Color(red: 0.48, green: 0.52, blue: 1.0),
        Color(red: 0.72, green: 0.43, blue: 1.0),
        Color(red: 1.0, green: 0.49, blue: 0.28)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                let progress = min(1, elapsed / 0.86)
                let easedProgress = CGFloat(1 - pow(1 - progress, 3))
                // Both ends meet at 0.86s, remain fully visible for about
                // 1.35s, then fade smoothly over 0.72s.
                let fade = max(0, 1 - max(0, elapsed - 2.21) / 0.72)
                let lineAlpha = (1 - 0.30 * easedProgress) * fade
                let lineWidth = 2.5 + 4.7 * easedProgress
                let outerGradient = Gradient(colors: colors.map { $0.opacity(lineAlpha * 0.48) })
                let middleGradient = Gradient(colors: colors.map { $0.opacity(lineAlpha * 0.64) })
                let coreGradient = Gradient(colors: colors.map { $0.opacity(lineAlpha * 0.82) })
                let start = CGPoint(x: size.width / 2, y: 0)
                let end = CGPoint(x: size.width / 2, y: size.height)

                // Two ends race from the notch down the screen edges and meet
                // once at the bottom. This is a single traveling border line.
                let inset: CGFloat = 5
                let corner: CGFloat = 42
                for leftSide in [true, false] {
                    let points = edgePathPoints(size: size, inset: inset, corner: corner, leftSide: leftSide)
                    let path = partialPath(points: points, progress: easedProgress)
                    context.stroke(
                        path,
                        with: .linearGradient(outerGradient, startPoint: start, endPoint: end),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    context.stroke(
                        path,
                        with: .linearGradient(middleGradient, startPoint: start, endPoint: end),
                        style: StrokeStyle(lineWidth: lineWidth * 0.62, lineCap: .round, lineJoin: .round)
                    )
                    context.stroke(
                        path,
                        with: .linearGradient(coreGradient, startPoint: start, endPoint: end),
                        style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edgePathPoints(size: CGSize, inset: CGFloat, corner: CGFloat, leftSide: Bool) -> [CGPoint] {
        let middle = size.width / 2
        let cornerX = leftSide ? inset + corner : size.width - inset - corner
        let outsideX = leftSide ? inset : size.width - inset
        var points = [CGPoint(x: middle, y: inset)]
        points += sampledLine(from: points[0], to: CGPoint(x: cornerX, y: inset), steps: 16)
        if leftSide {
            points += sampledCurve(
                CGPoint(x: cornerX, y: inset),
                CGPoint(x: inset + corner * 0.52, y: inset),
                CGPoint(x: inset, y: inset + corner * 0.52),
                CGPoint(x: outsideX, y: inset + corner)
            )
        } else {
            points += sampledCurve(
                CGPoint(x: cornerX, y: inset),
                CGPoint(x: size.width - inset - corner * 0.52, y: inset),
                CGPoint(x: size.width - inset, y: inset + corner * 0.52),
                CGPoint(x: outsideX, y: inset + corner)
            )
        }
        let bottomCornerY = size.height - inset - corner
        points += sampledLine(from: points[points.count - 1], to: CGPoint(x: outsideX, y: bottomCornerY), steps: 30)
        if leftSide {
            points += sampledCurve(
                CGPoint(x: outsideX, y: bottomCornerY),
                CGPoint(x: inset, y: size.height - inset - corner * 0.52),
                CGPoint(x: inset + corner * 0.52, y: size.height - inset),
                CGPoint(x: inset + corner, y: size.height - inset)
            )
        } else {
            points += sampledCurve(
                CGPoint(x: outsideX, y: bottomCornerY),
                CGPoint(x: size.width - inset, y: size.height - inset - corner * 0.52),
                CGPoint(x: size.width - inset - corner * 0.52, y: size.height - inset),
                CGPoint(x: size.width - inset - corner, y: size.height - inset)
            )
        }
        points += sampledLine(from: points[points.count - 1], to: CGPoint(x: middle, y: size.height - inset), steps: 16)
        return points
    }

    private func partialPath(points: [CGPoint], progress: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, progress > 0 else { return path }
        path.move(to: first)
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var remaining = total * progress
        for (index, length) in lengths.enumerated() {
            let from = points[index]
            let to = points[index + 1]
            if remaining >= length {
                path.addLine(to: to)
                remaining -= length
            } else {
                let fraction = length == 0 ? 0 : remaining / length
                path.addLine(to: CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction))
                break
            }
        }
        return path
    }

    private func sampledLine(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 0 else { return [end] }
        return (1...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    private func sampledCurve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> [CGPoint] {
        (1...20).map { index in
            let t = CGFloat(index) / 20
            let inverse = 1 - t
            let x = pow(inverse, 3) * p0.x + 3 * pow(inverse, 2) * t * p1.x + 3 * inverse * pow(t, 2) * p2.x + pow(t, 3) * p3.x
            let y = pow(inverse, 3) * p0.y + 3 * pow(inverse, 2) * t * p1.y + 3 * inverse * pow(t, 2) * p2.y + pow(t, 3) * p3.y
            return CGPoint(x: x, y: y)
        }
    }
}

@MainActor
final class GrassAIThinkingOrbController {
    private var window: NSPanel?
    private var generation = UUID()

    func show(on screen: NSScreen, notchHeight: CGFloat) {
        generation = UUID()
        window?.orderOut(nil)

        let finalSize = NSSize(width: 72, height: 52)
        let finalOrigin = NSPoint(
            x: screen.frame.midX - finalSize.width / 2,
            y: screen.frame.maxY - notchHeight - finalSize.height - 12
        )
        let startSize = NSSize(width: 18, height: 18)
        let startFrame = NSRect(
            x: screen.frame.midX - startSize.width / 2,
            y: screen.frame.maxY - notchHeight - startSize.height - 3,
            width: startSize.width,
            height: startSize.height
        )
        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let orbHost = NSHostingView(rootView: GrassAIThinkingOrbView())
        orbHost.wantsLayer = true
        orbHost.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = orbHost
        panel.alphaValue = 0.25
        window = panel
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.25, 1.0)
            panel.animator().setFrame(NSRect(origin: finalOrigin, size: finalSize), display: true)
            panel.animator().alphaValue = 1
        }

    }

    func reconnect(on screen: NSScreen, notchHeight: CGFloat) {
        guard let panel = window else { return }
        generation = UUID()
        let currentGeneration = generation
        let targetSize = NSSize(width: 24, height: 24)
        let targetFrame = NSRect(
            x: screen.frame.midX - targetSize.width / 2,
            y: screen.frame.maxY - max(34, notchHeight) / 2 - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.36
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.2, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.generation == currentGeneration else { return }
                panel.orderOut(nil)
                if self.window === panel { self.window = nil }
            }
        })
    }
}

private struct GrassAIThinkingOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let palette: [Color] = [
        Color(red: 0.35, green: 0.9, blue: 0.56),
        Color(red: 0.22, green: 0.72, blue: 1.0),
        Color(red: 0.55, green: 0.48, blue: 1.0),
        Color(red: 1.0, green: 0.47, blue: 0.24)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 1 : 1 + sin(time * 1.5) * 0.018
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.76))
                    .overlay {
                        Capsule().fill(
                            LinearGradient(colors: palette.map { $0.opacity(0.055) }, startPoint: .leading, endPoint: .trailing)
                        )
                    }
                Canvas { context, size in
                    let centerY = size.height / 2
                    let phase = time * 1.7
                    var waveform = Path()
                    for step in 0...72 {
                        let normalized = Double(step) / 72
                        let x = CGFloat(normalized) * size.width
                        let envelope = 0.35 + 0.65 * sin(normalized * .pi)
                        let wave = sin(normalized * 2 * .pi * 1.65 + phase) * 1.35
                            + sin(normalized * 2 * .pi * 2.4 - phase * 0.55) * 0.35
                        let y = centerY + CGFloat(wave * envelope)
                        if step == 0 { waveform.move(to: CGPoint(x: x, y: y)) }
                        else { waveform.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 3))
                        glow.stroke(
                            waveform,
                            with: .linearGradient(Gradient(colors: palette.map { $0.opacity(0.35) }), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                        )
                    }
                    context.stroke(
                        waveform,
                        with: .linearGradient(Gradient(colors: palette.map { $0.opacity(0.88) }), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                        style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)
                    )
                }
                .blendMode(.screen)
                Capsule()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(LinearGradient(colors: palette.map { $0.opacity(0.36) }, startPoint: .leading, endPoint: .trailing), lineWidth: 0.8))
            .scaleEffect(pulse)
            .background(Color.clear)
        }
        .accessibilityLabel("grassAI is thinking")
    }
}

@MainActor
final class GrassAIHostingView: NSHostingView<GrassAIView> {
    var isGrassAIActive: @MainActor () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isGrassAIActive() else { return nil }
        return super.hitTest(point)
    }
}

private struct GrassAIThinkingView: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let colors: [Color] = [
                    Color(red: 0.36, green: 0.76, blue: 1),
                    Color(red: 0.48, green: 0.48, blue: 1),
                    Color(red: 0.78, green: 0.42, blue: 0.94),
                    Color(red: 1, green: 0.53, blue: 0.44)
                ]
                for line in 0..<3 {
                    var path = Path()
                    for step in 0...36 {
                        let x = CGFloat(step) / 36 * size.width
                        let phase = time * (1.6 + Double(line) * 0.24) + Double(line) * 1.7
                        let envelope = 0.35 + 0.65 * sin(Double(step) / 36 * .pi)
                        let y = size.height / 2 + CGFloat(sin(Double(step) * 0.23 + phase) * envelope) * (3 + CGFloat(line) * 2)
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(
                        path,
                        with: .linearGradient(Gradient(colors: colors.map { $0.opacity(0.45 + Double(line) * 0.16) }), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                        style: StrokeStyle(lineWidth: line == 1 ? 1.8 : 1.1, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .accessibilityLabel("grassAI is thinking")
    }
}
