//
//  AssistantConversationStore.swift
//  Tamio (macOS)
//
//  FlowDown-inspired conversation & message models, two-tier atomic disk
//  persistence (index.json + per-conversation JSON), Markdown export,
//  deterministic single-source-of-truth request reconstruction, and
//  atomic token-budget pruning that never orphans tool results.
//

import Foundation
import TamioModule

// MARK: - Target Scope (Persisted per Conversation)

nonisolated enum AssistantTargetScope: Codable, Equatable, Hashable, Sendable {
    case all
    case group(String)
    case hosts(Set<RDMachine.ID>)

    var isFiltered: Bool {
        switch self {
        case .all: false
        case .group, .hosts: true
        }
    }
}

// MARK: - Tool Execution Record (Persisted inside Message)

nonisolated struct AssistantToolExecution: Codable, Equatable, Hashable, Sendable {
    let callID: String
    let toolName: String
    let argumentsJSON: String
    let output: String
    let isError: Bool
    let targetHosts: [String]
    let durationMs: Int

    init(
        callID: String,
        toolName: String,
        argumentsJSON: String,
        output: String,
        isError: Bool = false,
        targetHosts: [String] = [],
        durationMs: Int = 0
    ) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.output = output
        self.isError = isError
        self.targetHosts = targetHosts
        self.durationMs = durationMs
    }
}

// MARK: - Image Attachments

/// One image on a message. The pixels live in the conversation's attachment
/// folder, not in the conversation JSON: a screenshot is megabytes of base64
/// that would be rewritten on every keystroke's save otherwise.
nonisolated struct AssistantAttachment: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var fileName: String
    var mediaType: String
    var byteCount: Int
    var width: Int
    var height: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        fileName: String,
        mediaType: String,
        byteCount: Int,
        width: Int,
        height: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.createdAt = createdAt
    }

    var fileExtension: String {
        mediaType == "image/png" ? "png" : "jpg"
    }

    /// Rough image cost in the context budget: Anthropic bills pixels, and
    /// OpenAI a base charge plus tiles. Capped so one huge screenshot cannot
    /// evict a whole conversation on its own.
    var estimatedTokens: Int {
        let pixels = max(1, width * height)
        return min(2000, max(85, pixels / 750))
    }
}

/// An image being prepared for a message but not yet written to disk.
nonisolated struct AssistantAttachmentDraft: Identifiable, Sendable {
    let attachment: AssistantAttachment
    let data: Data

    var id: UUID {
        attachment.id
    }
}

// MARK: - Persistent Chat Message (Single Source of Truth)

nonisolated struct AssistantChatMessage: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum Role: String, Codable, Equatable, Hashable, Sendable {
        case user
        case assistant
        case toolCall
        case notice
        case error
    }

    let id: UUID
    let role: Role
    var text: String
    var reasoning: String
    var toolExecution: AssistantToolExecution?
    var attachments: [AssistantAttachment]
    var timestamp: Date
    var modelLabel: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        reasoning: String = "",
        toolExecution: AssistantToolExecution? = nil,
        attachments: [AssistantAttachment] = [],
        timestamp: Date = Date(),
        modelLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolExecution = toolExecution
        self.attachments = attachments
        self.timestamp = timestamp
        self.modelLabel = modelLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, toolExecution, attachments, timestamp, modelLabel
    }

    /// Conversations saved before images existed have no `attachments` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        reasoning = try container.decode(String.self, forKey: .reasoning)
        toolExecution = try container.decodeIfPresent(AssistantToolExecution.self, forKey: .toolExecution)
        attachments = try container.decodeIfPresent([AssistantAttachment].self, forKey: .attachments) ?? []
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        modelLabel = try container.decodeIfPresent(String.self, forKey: .modelLabel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(toolExecution, forKey: .toolExecution)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(modelLabel, forKey: .modelLabel)
    }
}

// MARK: - Conversation Metadata

nonisolated struct AssistantConversation: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var title: String
    var icon: String
    var shouldAutoRename: Bool
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastMessagePreview: String
    var messageCount: Int
    var providerSelection: AIActiveSelection?
    var modelOverride: String?
    var targetScope: AssistantTargetScope
    var pinnedSkillIDs: Set<String>
    var draftText: String
    var summary: String?
    var summaryMessageCount: Int

    init(
        id: UUID = UUID(),
        title: String = String(localized: "New Conversation"),
        icon: String = "💬",
        shouldAutoRename: Bool = true,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMessagePreview: String = "",
        messageCount: Int = 0,
        providerSelection: AIActiveSelection? = nil,
        modelOverride: String? = nil,
        targetScope: AssistantTargetScope = .all,
        pinnedSkillIDs: Set<String> = [],
        draftText: String = "",
        summary: String? = nil,
        summaryMessageCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shouldAutoRename = shouldAutoRename
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessagePreview = lastMessagePreview
        self.messageCount = messageCount
        self.providerSelection = providerSelection
        self.modelOverride = modelOverride
        self.targetScope = targetScope
        self.pinnedSkillIDs = pinnedSkillIDs
        self.draftText = draftText
        self.summary = summary
        self.summaryMessageCount = summaryMessageCount
    }
}

// MARK: - Two-Tier Atomic Disk Storage

/// Stores lightweight conversation index in `index.json` for instant startup,
/// and each conversation's message list in `conversations/<uuid>.json`.
final nonisolated class AssistantConversationDiskStore: Sendable {
    static let shared = AssistantConversationDiskStore()

    private let baseDirectory: URL
    private let conversationsDirectory: URL
    private let attachmentsDirectory: URL
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "sb.moe.tamio.assistant.disk", qos: .utility)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "sb.moe.tamio"
        let base = support
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("TamioAssistant", isDirectory: true)
        baseDirectory = base
        conversationsDirectory = base.appendingPathComponent("conversations", isDirectory: true)
        attachmentsDirectory = base.appendingPathComponent("attachments", isDirectory: true)
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    }

    private func messagesURL(for id: UUID) -> URL {
        conversationsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func attachmentDirectory(for conversationID: UUID) -> URL {
        attachmentsDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    /// Where a message's image lives, for the thumbnail and the provider.
    func attachmentURL(for attachment: AssistantAttachment, conversationID: UUID) -> URL {
        attachmentDirectory(for: conversationID)
            .appendingPathComponent("\(attachment.id.uuidString).\(attachment.fileExtension)")
    }

    func saveAttachment(_ attachment: AssistantAttachment, data: Data, conversationID: UUID) {
        let directory = attachmentDirectory(for: conversationID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: attachmentURL(for: attachment, conversationID: conversationID), options: .atomic)
    }

    func attachmentData(for attachment: AssistantAttachment, conversationID: UUID) -> Data? {
        try? Data(contentsOf: attachmentURL(for: attachment, conversationID: conversationID))
    }

    func deleteAttachmentFiles(_ attachments: [AssistantAttachment], conversationID: UUID) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachmentURL(for: attachment, conversationID: conversationID))
        }
    }

    func deleteAttachmentDirectory(for conversationID: UUID) {
        try? FileManager.default.removeItem(at: attachmentDirectory(for: conversationID))
    }

    /// Copies the images of the messages into a new conversation's folder.
    /// Each conversation owns its images, so deleting either is independent.
    func copyAttachmentFiles(from messages: [AssistantChatMessage], source: UUID, destination: UUID) {
        let destinationDirectory = attachmentDirectory(for: destination)
        try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        for message in messages {
            for attachment in message.attachments {
                let sourceURL = attachmentURL(for: attachment, conversationID: source)
                let destinationURL = attachmentURL(for: attachment, conversationID: destination)
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                }
            }
        }
    }

    func loadIndex() -> [AssistantConversation] {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: indexURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([AssistantConversation].self, from: data)) ?? []
        }
    }

    func saveIndex(_ conversations: [AssistantConversation]) {
        ioQueue.async { [indexURL, conversationsDirectory] in
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(conversations) else { return }
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func loadMessages(for id: UUID) -> [AssistantChatMessage] {
        ioQueue.sync {
            let url = messagesURL(for: id)
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([AssistantChatMessage].self, from: data)) ?? []
        }
    }

    func saveMessages(_ messages: [AssistantChatMessage], for id: UUID) {
        let url = messagesURL(for: id)
        ioQueue.async { [conversationsDirectory] in
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(messages) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func deleteMessages(for id: UUID) {
        let url = messagesURL(for: id)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func eraseAll() {
        ioQueue.async { [indexURL, conversationsDirectory, attachmentsDirectory] in
            try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: conversationsDirectory)
            try? FileManager.default.removeItem(at: attachmentsDirectory)
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Searches titles, previews, and persisted message contents on a background thread.
    func matchingConversationIDs(query: String, in conversations: [AssistantConversation]) async -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Set(conversations.map(\.id)) }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                var matches = Set<UUID>()
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                for conv in conversations {
                    let meta = "\(conv.title) \(conv.lastMessagePreview) \(conv.summary ?? "")".lowercased()
                    if tokens.allSatisfy({ meta.contains($0) }) {
                        matches.insert(conv.id)
                        continue
                    }
                    let url = messagesURL(for: conv.id)
                    if let data = try? Data(contentsOf: url),
                       let msgs = try? decoder.decode([AssistantChatMessage].self, from: data)
                    {
                        let haystack = msgs.map { "\($0.text) \($0.toolExecution?.toolName ?? "") \($0.toolExecution?.targetHosts.joined(separator: " ") ?? "")" }
                            .joined(separator: "\n")
                            .lowercased()
                        if tokens.allSatisfy({ haystack.contains($0) }) {
                            matches.insert(conv.id)
                        }
                    }
                }
                continuation.resume(returning: matches)
            }
        }
    }
}

// MARK: - Context Builder & Atomic Token Pruner (FlowDown Pattern)

nonisolated enum ConversationContextBuilder {
    struct PreparedContext: Sendable {
        let systemPrompt: String
        let turns: [LLMConversationTurn]
        let didPrune: Bool
        let estimatedTokens: Int
    }

    /// Reconstructs wire-ready `[LLMConversationTurn]` directly from stored messages,
    /// then atomically prunes earliest non-system turns if above `tokenBudget` without
    /// ever separating a tool result from its preceding assistant tool call.
    static func build(
        messages: [AssistantChatMessage],
        baseSystemPrompt: String,
        tools: [LLMToolSchema],
        tokenBudget: Int,
        images: [UUID: LLMImageAttachment] = [:]
    ) -> PreparedContext {
        let recentCutoff = max(0, messages.count - 8)
        var turns: [LLMConversationTurn] = []

        for (idx, msg) in messages.enumerated() {
            switch msg.role {
            case .user:
                let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let attached = msg.attachments.compactMap { images[$0.id] }
                guard !text.isEmpty || !attached.isEmpty else { continue }
                turns.append(.user(text: text, images: attached))

            case .assistant:
                let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                turns.append(.assistant(text: text, toolCalls: []))

            case .toolCall:
                guard let exec = msg.toolExecution else { continue }
                let call = LLMToolCall(
                    id: exec.callID,
                    name: exec.toolName,
                    argumentsJSON: exec.argumentsJSON.isEmpty ? "{}" : exec.argumentsJSON
                )
                // Keep full output for recent turns; compact older verbose shell outputs to save context.
                let cap = idx >= recentCutoff ? 16000 : 2000
                let rawOut = exec.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let output: String = if rawOut.isEmpty {
                    exec.isError ? "Tool failed with no output." : "Tool completed with no output."
                } else if rawOut.count > cap {
                    String(rawOut.prefix(cap)) + "\n… [earlier tool output condensed]"
                } else {
                    rawOut
                }
                turns.append(.assistant(text: "", toolCalls: [call]))
                turns.append(.toolResult(toolCallId: exec.callID, name: exec.toolName, content: output))

            case .notice, .error:
                continue
            }
        }

        // Compute baseline token budget overhead for system prompt + tool definitions.
        let toolsTokens = tools.reduce(0) { acc, tool in
            acc + estimateTokens(tool.name) + estimateTokens(tool.description) + (tool.inputSchemaJSON.count / 4)
        }
        let systemTokens = estimateTokens(baseSystemPrompt)
        let effectiveBudget = max(4000, tokenBudget)

        func totalTokens(for candidate: [LLMConversationTurn]) -> Int {
            systemTokens + toolsTokens + candidate.reduce(0) { $0 + estimateTurnTokens($1) }
        }

        let initialTotal = totalTokens(for: turns)
        guard initialTotal > effectiveBudget, turns.count > 1 else {
            return PreparedContext(
                systemPrompt: baseSystemPrompt,
                turns: turns,
                didPrune: false,
                estimatedTokens: initialTotal
            )
        }

        // Phase 1: Identify eviction indices front-to-back, never evicting the latest message.
        let upperBound = turns.count - 1
        var evictEnd = 0
        var current = initialTotal

        while evictEnd < upperBound, current > effectiveBudget {
            current -= estimateTurnTokens(turns[evictEnd])
            evictEnd += 1
        }

        // Atomic pairing: never leave an orphaned .toolResult after an evicted .assistant(toolCalls:).
        while evictEnd < upperBound {
            if case .toolResult = turns[evictEnd] {
                current -= estimateTurnTokens(turns[evictEnd])
                evictEnd += 1
            } else {
                break
            }
        }

        guard evictEnd > 0 else {
            return PreparedContext(
                systemPrompt: baseSystemPrompt,
                turns: turns,
                didPrune: false,
                estimatedTokens: initialTotal
            )
        }

        // Phase 2: Build compact extractive summary of evicted turns (capped at 10% of budget).
        let evicted = Array(turns[..<evictEnd])
        let remaining = Array(turns[evictEnd...])
        let summaryBudget = max(300, effectiveBudget / 10)
        var summaryLines: [String] = []
        var summaryTokens = 0

        for turn in evicted {
            let line: String
            switch turn {
            case let .user(text, images):
                let imageNote = images.isEmpty ? "" : " [\(images.count) image\(images.count == 1 ? "" : "s")]"
                line = "user: \(text.isEmpty ? "" : firstLine(text, limit: 140))\(imageNote)"
            case let .assistant(text, calls):
                if !text.isEmpty {
                    line = "assistant: \(firstLine(text, limit: 160))"
                } else if let firstCall = calls.first {
                    line = "tool_call: \(firstCall.name)"
                } else {
                    continue
                }
            case let .toolResult(_, name, content):
                line = "tool(\(name)): \(firstLine(content, limit: 120))"
            }
            let cost = estimateTokens(line)
            guard summaryTokens + cost <= summaryBudget else { break }
            summaryLines.append(line)
            summaryTokens += cost
        }

        var updatedSystemPrompt = baseSystemPrompt
        if !summaryLines.isEmpty {
            let digest = """
            [Earlier conversation turns condensed due to context limit]
            \(summaryLines.joined(separator: "\n"))
            """
            if current + estimateTokens(digest) <= effectiveBudget {
                updatedSystemPrompt += "\n\n" + digest
                current += estimateTokens(digest)
            }
        }

        return PreparedContext(
            systemPrompt: updatedSystemPrompt,
            turns: remaining,
            didPrune: true,
            estimatedTokens: current
        )
    }

    /// Compact conversation history digest for on-device Apple Intelligence (4096-token window).
    static func buildOnDeviceHistoryDigest(from messages: [AssistantChatMessage], maxChars: Int = 1800) -> String {
        let relevant = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(8)
        guard !relevant.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for msg in relevant.reversed() {
            let prefix = msg.role == .user ? "User: " : "Assistant: "
            let body = msg.text.isEmpty && !msg.attachments.isEmpty ? "[image]" : msg.text
            let clipped = body.count > 360 ? String(body.prefix(360)) + "…" : body
            let entry = prefix + clipped.replacingOccurrences(of: "\n", with: " ")
            if used + entry.count > maxChars {
                break
            }
            lines.insert(entry, at: 0)
            used += entry.count
        }
        guard !lines.isEmpty else { return "" }
        return "Previous conversation context:\n" + lines.joined(separator: "\n")
    }

    /// CJK-aware lightweight token estimator (~1 token/CJK char, ~1 token/3.8 ASCII chars).
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        return cjkCount + max(1, (otherCount + 3) / 4)
    }

    private static func estimateTurnTokens(_ turn: LLMConversationTurn) -> Int {
        switch turn {
        case let .user(text, images):
            let imagesCost = images.reduce(0) { $0 + $1.estimatedTokens }
            return 6 + estimateTokens(text) + imagesCost
        case let .assistant(text, calls):
            let callsCost = calls.reduce(0) { $0 + 12 + estimateTokens($1.name) + estimateTokens($1.argumentsJSON) }
            return 6 + estimateTokens(text) + callsCost
        case let .toolResult(_, name, content):
            return 10 + estimateTokens(name) + estimateTokens(content)
        }
    }

    private static func firstLine(_ text: String, limit: Int) -> String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Exports a conversation cleanly as a shareable Markdown transcript.
    static func exportMarkdown(conversation: AssistantConversation, messages: [AssistantChatMessage]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var out: [String] = [
            "# \(conversation.icon) \(conversation.title)",
            "",
            "- Created: \(formatter.string(from: conversation.createdAt))",
            "- Updated: \(formatter.string(from: conversation.updatedAt))",
            "",
            "---",
            "",
        ]

        for msg in messages {
            switch msg.role {
            case .user:
                var lines = ["## User", ""]
                if !msg.text.isEmpty {
                    lines.append(msg.text)
                    lines.append("")
                }
                for attachment in msg.attachments {
                    lines.append("> **Image**: \(attachment.fileName) (\(attachment.width)×\(attachment.height))")
                }
                out.append(lines.joined(separator: "\n") + "\n")
            case .assistant:
                if !msg.reasoning.isEmpty {
                    out.append("<details><summary>Thinking</summary>\n\n\(msg.reasoning)\n\n</details>\n")
                }
                out.append("## Assistant\n\n\(msg.text)\n")
            case .toolCall:
                if let exec = msg.toolExecution {
                    let hosts = exec.targetHosts.isEmpty ? "" : " (\(exec.targetHosts.joined(separator: ", ")))"
                    out.append("> **Tool**: `\(exec.toolName)`\(hosts) · \(exec.isError ? "Failed" : "OK") (\(exec.durationMs) ms)\n")
                    let snippet = exec.output.count > 1200 ? String(exec.output.prefix(1200)) + "\n…" : exec.output
                    if !snippet.isEmpty {
                        out.append("```\n\(snippet)\n```\n")
                    }
                }
            case .notice:
                out.append("*\(msg.text)*\n")
            case .error:
                out.append("> **Error**: \(msg.text)\n")
            }
        }
        return out.joined(separator: "\n")
    }
}
