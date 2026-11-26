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
    var timestamp: Date
    var modelLabel: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        reasoning: String = "",
        toolExecution: AssistantToolExecution? = nil,
        timestamp: Date = Date(),
        modelLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolExecution = toolExecution
        self.timestamp = timestamp
        self.modelLabel = modelLabel
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
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
    }

    private func messagesURL(for id: UUID) -> URL {
        conversationsDirectory.appendingPathComponent("\(id.uuidString).json")
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
        ioQueue.async { [indexURL, conversationsDirectory] in
            try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: conversationsDirectory)
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
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
        tokenBudget: Int
    ) -> PreparedContext {
        let recentCutoff = max(0, messages.count - 8)
        var turns: [LLMConversationTurn] = []

        for (idx, msg) in messages.enumerated() {
            switch msg.role {
            case .user:
                let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                turns.append(.user(text))

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
            case let .user(text):
                line = "user: \(firstLine(text, limit: 140))"
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
            let clipped = msg.text.count > 360 ? String(msg.text.prefix(360)) + "…" : msg.text
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
        case let .user(text):
            return 6 + estimateTokens(text)
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
                out.append("## User\n\n\(msg.text)\n")
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
