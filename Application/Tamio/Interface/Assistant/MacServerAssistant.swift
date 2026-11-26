//
//  MacServerAssistant.swift
//  Tamio (macOS)
//
//  FlowDown-inspired multi-session AI Server Assistant built directly on
//  Tamio's MCP engine (`AgentServer`, `AgentTools`, `AgentRunner`,
//  `AgentActivityLog`):
//  - `AssistantAgentBridge`: isolates inline approval cards per conversation via
//    Swift `@TaskLocal` propagation so parallel sessions never collide.
//  - `ConversationSession`: owns one conversation's message list (single
//    source of truth), streaming state, tool calls, reasoning, regeneration,
//    editing, auto-title, and cross-session summarization.
//  - `ServerAssistant`: manages conversation index, lazy session caching,
//    background execution tracking, context compression, search, and CRUD.
//

import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif
import MachineStatus
import MachineStatusView
import Observation
import SwiftUI
import TamioModule

// MARK: - Task-Local Conversation Routing

enum AssistantTaskContext {
    @TaskLocal static var conversationID: UUID?
}

// MARK: - Assistant Agent Bridge (Per-Conversation Approval Isolation)

@MainActor
@Observable
final class AssistantAgentBridge: AgentEnvironment {
    static let shared = AssistantAgentBridge()

    struct PendingApproval: Identifiable {
        let id = UUID()
        let conversationID: UUID?
        let request: AgentRequest
        let createdAt = Date()
        fileprivate let continuation: CheckedContinuation<Bool, Never>

        var isDestructive: Bool {
            request.tool.hasPrefix("remove_") || request.title.localizedCaseInsensitiveContains("sudo")
        }
    }

    private(set) var pendingApprovals: [PendingApproval] = []
    /// True while `AssistantView` is visible so approvals render inline.
    var inlineApprovalActive = false

    private init() {}

    func install() {
        AgentBridge.shared.inlineApprovalHandler = { [weak self] request in
            guard let self, inlineApprovalActive, AssistantTaskContext.conversationID != nil else { return nil }
            return await approve(request)
        }
    }

    func pendingApprovals(for conversationID: UUID) -> [PendingApproval] {
        pendingApprovals.filter { $0.conversationID == conversationID || $0.conversationID == nil }
    }

    func hasPendingApproval(for conversationID: UUID) -> Bool {
        pendingApprovals.contains { $0.conversationID == conversationID }
    }

    var totalPendingApprovalCount: Int {
        pendingApprovals.count
    }

    // MARK: Approval Resolution

    func resolve(_ id: UUID, approved: Bool, allowForOneHour: Bool = false) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let item = pendingApprovals.remove(at: index)
        if approved, allowForOneHour {
            AgentServer.shared.allowForAnHour(item.request.client)
        }
        item.continuation.resume(returning: approved)
    }

    func denyPending(for conversationID: UUID) {
        let matching = pendingApprovals.filter { $0.conversationID == conversationID }
        pendingApprovals.removeAll { $0.conversationID == conversationID }
        for item in matching {
            item.continuation.resume(returning: false)
        }
    }

    func denyAllPending() {
        let items = pendingApprovals
        pendingApprovals.removeAll()
        for item in items {
            item.continuation.resume(returning: false)
        }
    }

    // MARK: AgentEnvironment

    func approve(_ request: AgentRequest) async -> Bool {
        let cid = AssistantTaskContext.conversationID
        if inlineApprovalActive || cid != nil {
            return await withCheckedContinuation { continuation in
                pendingApprovals.append(
                    PendingApproval(conversationID: cid, request: request, continuation: continuation)
                )
            }
        }
        let hostsText = request.hosts.isEmpty
            ? ""
            : "\n\n" + String(localized: "Servers: ") + request.hosts.prefix(10).joined(separator: ", ")
        let message = "\(request.title)\n\n\(request.detail)\(hostsText)"
        return await withCheckedContinuation { continuation in
            Mac.alert(
                message: request.title,
                informative: message,
                buttons: [String(localized: "Allow"), String(localized: "Deny")]
            ) { index, _ in
                continuation.resume(returning: index == 0)
            }
        }
    }

    func prepareMetrics(for machines: [RDMachine.ID]) {
        LiveStatusCenter.shared.lease(machines)
    }

    func metrics(for machine: RDMachine.ID) async -> JSONValue? {
        guard let session = await LiveStatusCenter.shared.requestSession(for: machine),
              session.status.hasData
        else { return nil }

        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        func number(_ value: Double) -> JSONValue {
            .number((value * 10).rounded() / 10)
        }

        return [
            "os": .string(status.system.releaseName),
            "hostname": .string(status.system.hostname),
            "uptimeSeconds": number(status.system.uptimeSec),
            "cores": .number(Double(status.cores)),
            "cpuPercent": number(Double(status.processor.summary.sumUsed)),
            "load": [
                number(Double(status.system.load1)),
                number(Double(status.system.load5)),
                number(Double(status.system.load15)),
            ],
            "memoryPercent": number(status.memoryUsedPercent),
            "memoryUsedBytes": number(status.memoryUsedKB * 1000),
            "memoryTotalBytes": number(status.memory.memTotal * 1000),
            "swapUsedBytes": number(max(0, status.memory.swapTotal - status.memory.swapFree) * 1000),
            "disks": .array(status.fileSystem.elements.map {
                [
                    "mount": .string($0.mountPoint),
                    "usedPercent": number(Double($0.percent)),
                    "used": .string($0.used),
                    "size": .string($0.size),
                ]
            }),
            "rootDiskPercent": root.map { number(Double($0.percent)) } ?? .null,
            "networkUpBytesPerSecond": number(Double(physical.map(\.txBytesPerSec).reduce(0, +))),
            "networkDownBytesPerSecond": number(Double(physical.map(\.rxBytesPerSec).reduce(0, +))),
            "trafficSinceBootUpBytes": number(Double(physical.map(\.txBytesTotal).reduce(0, +))),
            "trafficSinceBootDownBytes": number(Double(physical.map(\.rxBytesTotal).reduce(0, +))),
            "updated": .string(session.lastUpdate.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
        ]
    }

    func isForwarding(_ forward: RDPortForward.ID) -> Bool {
        PortForwardBackend.shared.sessionExists(withPortForwardID: forward)
    }

    func startForward(_ forward: RDPortForward.ID) {
        PortForwardBackend.shared.createSession(withPortForwardID: forward)
    }

    func stopForward(_ forward: RDPortForward.ID) {
        PortForwardBackend.shared.endSession(withPortForwardID: forward)
    }
}

// MARK: - On-Device FoundationModels Tools (macOS 26+)

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private struct ListHostsOnDeviceTool: Tool {
        let name = "list_hosts"
        let description = "List saved SSH servers (name, address, port, group, tags). Never returns passwords or private keys."

        @Generable
        struct Arguments {
            @Guide(description: "Optional group filter; leave empty for all servers.")
            var group: String?
        }

        func call(arguments: Arguments) async throws -> String {
            var args: [String: JSONValue] = [:]
            if let group = arguments.group, !group.isEmpty {
                args["group"] = .string(group)
            }
            let reply = await AgentServer.shared.invokeTool("list_hosts", arguments: .object(args), client: "Tamio AI (On-Device)")
            return String(reply.text.prefix(4000))
        }
    }

    @available(macOS 26.0, *)
    private struct GetMetricsOnDeviceTool: Tool {
        let name = "get_metrics"
        let description = "Fetch live CPU, memory, disk, load, and network metrics for saved servers."

        @Generable
        struct Arguments {
            @Guide(description: "Comma-separated server names, or empty for all servers.")
            var hostsCSV: String?
        }

        func call(arguments: Arguments) async throws -> String {
            var args: [String: JSONValue] = [:]
            if let csv = arguments.hostsCSV, !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let names = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !names.isEmpty {
                    args["hosts"] = .array(names.map { .string($0) })
                }
            }
            let reply = await AgentServer.shared.invokeTool("get_metrics", arguments: .object(args), client: "Tamio AI (On-Device)")
            return String(reply.text.prefix(4000))
        }
    }

    @available(macOS 26.0, *)
    private struct RunCommandOnDeviceTool: Tool {
        let name = "run_command"
        let description = "Run a shell command in parallel on one or more servers after the user approves."

        @Generable
        struct Arguments {
            @Guide(description: "Shell command to run.")
            var command: String
            @Guide(description: "Comma-separated server names, or 'all' for every server.")
            var targets: String
            @Guide(description: "Short task title for server history, e.g. 'Check disk space'.")
            var task: String
        }

        func call(arguments: Arguments) async throws -> String {
            let trimmedTargets = arguments.targets.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetSpec: JSONValue
            if trimmedTargets.lowercased() == "all" || trimmedTargets.isEmpty {
                targetSpec = ["all": .bool(true)]
            } else {
                let names = trimmedTargets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                targetSpec = ["hosts": .array(names.map { .string($0) })]
            }
            let payload: JSONValue = [
                "targets": targetSpec,
                "command": .string(arguments.command),
                "task": .string(arguments.task),
            ]
            let reply = await AgentServer.shared.invokeTool("run_command", arguments: payload, client: "Tamio AI (On-Device)")
            return String(reply.text.prefix(4000))
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private final class OnDeviceServerSessionHolder {
        var session: LanguageModelSession

        init(instructions: String) {
            session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: [
                    ListHostsOnDeviceTool(),
                    GetMetricsOnDeviceTool(),
                    RunCommandOnDeviceTool(),
                ],
                instructions: instructions
            )
        }
    }

    #if compiler(>=6.4)
        @available(macOS 27.0, *)
        @MainActor
        private final class PrivateCloudComputeSessionHolder {
            var session: LanguageModelSession

            init(instructions: String) {
                session = LanguageModelSession(
                    model: PrivateCloudComputeLanguageModel(),
                    tools: [
                        ListHostsOnDeviceTool(),
                        GetMetricsOnDeviceTool(),
                        RunCommandOnDeviceTool(),
                    ],
                    instructions: instructions
                )
            }
        }
    #endif
#endif

// MARK: - Single Conversation Runtime Session

@MainActor
@Observable
final class ConversationSession {
    let conversationID: UUID

    private(set) var messages: [AssistantChatMessage]
    private(set) var streamText = ""
    private(set) var streamReasoning = ""
    private(set) var isStreaming = false
    private(set) var activeToolStatus: String?
    private(set) var didPruneContext = false

    private static let maxRemoteToolRounds = 12
    private static let maxStoredToolOutputChars = 32768
    private static let clientName = "Tamio AI"

    private weak var manager: ServerAssistant?
    private let remoteClient: RemoteLLMClient
    private var activeTask: Task<Void, Never>?
    private var onDeviceSessionBox: AnyObject?
    private var onDeviceExchangeCount = 0

    init(
        conversationID: UUID,
        messages: [AssistantChatMessage],
        manager: ServerAssistant,
        remoteClient: RemoteLLMClient = RemoteLLMClient()
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.manager = manager
        self.remoteClient = remoteClient
    }

    // MARK: - Message Mutations

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        appendMessage(AssistantChatMessage(role: .user, text: text))
        applyImmediateFallbackTitleIfNeeded(from: text)
        startInference()
    }

    func regenerateLastReply() {
        guard !isStreaming else { return }
        // Remove trailing non-user messages back to the last user prompt.
        while let last = messages.last, last.role != .user {
            messages.removeLast()
        }
        guard messages.last?.role == .user else { return }
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    /// Resumes after a network or stream error without discarding completed
    /// tool calls from earlier rounds in the same turn.
    func retryAfterError() {
        guard !isStreaming else { return }
        while let last = messages.last, last.role == .error {
            messages.removeLast()
        }
        guard !messages.isEmpty else { return }
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    func editAndResend(messageID: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming,
              let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .user })
        else { return }
        messages[index].text = trimmed
        messages[index].timestamp = Date()
        if index + 1 < messages.count {
            messages.removeSubrange((index + 1)...)
        }
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    func deleteMessage(_ id: UUID) {
        guard !isStreaming else { return }
        messages.removeAll { $0.id == id }
        onDeviceSessionBox = nil
        persistMessages()
    }

    func stopGenerating() {
        activeTask?.cancel()
        activeTask = nil
        manager?.bridge.denyPending(for: conversationID)
        let partial = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialReasoning = streamReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty || !partialReasoning.isEmpty {
            appendMessage(
                AssistantChatMessage(
                    role: .assistant,
                    text: partial.isEmpty ? String(localized: "(Stopped)") : partial,
                    reasoning: partialReasoning,
                    modelLabel: manager?.activeModelLabel(for: conversationID)
                )
            )
        }
        finishStreamingState()
    }

    func resetOnDeviceContext() {
        onDeviceSessionBox = nil
        onDeviceExchangeCount = 0
    }

    /// Used by `ServerAssistant.compressConversation` to stream a summary directly into this fresh session.
    func runCompressionStream(
        sourceTitle: String,
        sourceTranscript: String,
        config: AIProviderConfig,
        apiKey: String?
    ) {
        appendMessage(
            AssistantChatMessage(
                role: .notice,
                text: String(localized: "Compressed from \"\(sourceTitle)\"")
            )
        )
        isStreaming = true
        streamText = ""
        streamReasoning = ""
        manager?.markExecuting(conversationID, running: true)

        let systemPrompt = """
        You are an expert infrastructure & DevOps summarization assistant.
        Compress the previous SSH server operations conversation into a crisp, structured Markdown brief:
        1. Preserve every server name, IP/group, confirmed finding, root cause, and command outcome.
        2. List completed changes and open follow-up items clearly as bullet points.
        3. Drop redundant raw logs and chatter while keeping exact file paths, error codes, and config values.
        4. Reply in the same language as the original conversation. Do not wrap the whole reply in a markdown code fence.
        """

        let cid = conversationID
        activeTask = Task { [weak self] in
            await AssistantTaskContext.$conversationID.withValue(cid) {
                guard let self else { return }
                do {
                    let clipped = sourceTranscript.count > 48000
                        ? String(sourceTranscript.suffix(48000))
                        : sourceTranscript
                    let turn = try await self.remoteClient.streamCompletion(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: systemPrompt,
                        messages: [.user("Please summarize and compress this server operations conversation so we can continue seamlessly:\n\n\(clipped)")],
                        tools: [],
                        onReasoningDelta: { @MainActor [weak self] delta in
                            self?.streamReasoning += delta
                        },
                        onTextDelta: { @MainActor [weak self] delta in
                            self?.streamText += delta
                        }
                    )
                    let finalText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalText.isEmpty {
                        self.appendMessage(
                            AssistantChatMessage(
                                role: .assistant,
                                text: finalText,
                                reasoning: turn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
                                modelLabel: config.model
                            )
                        )
                    }
                } catch is CancellationError {
                    // Handled by stopGenerating()
                } catch {
                    self.appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
                }
                self.finishStreamingState()
            }
        }
    }

    // MARK: - Inference Pipeline

    private func startInference() {
        guard let manager else { return }
        let selection = manager.effectiveSelection(for: conversationID)
        let cid = conversationID
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await AssistantTaskContext.$conversationID.withValue(cid) {
                guard let self else { return }
                switch selection {
                case .appleIntelligence:
                    await self.runAppleIntelligenceTurn()
                case .applePrivateCloudCompute:
                    await self.runPrivateCloudComputeTurn()
                case let .custom(providerId):
                    guard let config = manager.resolvedProviderConfig(for: cid, providerId: providerId) else {
                        self.appendMessage(
                            AssistantChatMessage(
                                role: .error,
                                text: String(localized: "Selected AI provider was not found. Choose one in AI Providers.")
                            )
                        )
                        return
                    }
                    await self.runRemoteProviderLoop(config: config)
                }
            }
        }
    }

    private func runRemoteProviderLoop(config: AIProviderConfig) async {
        guard let manager else { return }
        isStreaming = true
        streamText = ""
        streamReasoning = ""
        activeToolStatus = nil
        manager.markExecuting(conversationID, running: true)

        let apiKey = manager.providerStore.apiKey(for: config.id)
        let tools = manager.remoteToolSchemas
        let budget = manager.contextTokenBudget

        do {
            for round in 0 ..< Self.maxRemoteToolRounds {
                try Task.checkCancellation()
                streamText = ""
                streamReasoning = ""

                // Single-source-of-truth rebuild + atomic token pruning on every round.
                let baseSystem = manager.buildInstructions(for: conversationID, compactForOnDevice: false)
                let prepared = ConversationContextBuilder.build(
                    messages: messages,
                    baseSystemPrompt: baseSystem,
                    tools: tools,
                    tokenBudget: budget
                )
                didPruneContext = prepared.didPrune

                let turn = try await streamCompletionWithRetry(
                    config: config,
                    apiKey: apiKey,
                    systemPrompt: prepared.systemPrompt,
                    messages: prepared.turns,
                    tools: tools
                )

                let replyText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let replyReasoning = turn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)

                if turn.toolCalls.isEmpty {
                    if !replyText.isEmpty || !replyReasoning.isEmpty {
                        appendMessage(
                            AssistantChatMessage(
                                role: .assistant,
                                text: replyText.isEmpty ? String(localized: "(No response)") : replyText,
                                reasoning: replyReasoning,
                                modelLabel: config.model
                            )
                        )
                    }
                    break
                }

                // Preserve any intermediate explanation or reasoning before tool execution.
                if !replyText.isEmpty || !replyReasoning.isEmpty {
                    appendMessage(
                        AssistantChatMessage(
                            role: .assistant,
                            text: replyText,
                            reasoning: replyReasoning,
                            modelLabel: config.model
                        )
                    )
                }
                streamText = ""
                streamReasoning = ""

                for call in turn.toolCalls {
                    try Task.checkCancellation()
                    activeToolStatus = ServerAssistant.localizedToolActivity(for: call.name)
                    let execution = await executeTool(call)
                    appendMessage(
                        AssistantChatMessage(
                            role: .toolCall,
                            text: ServerAssistant.localizedToolTitle(for: call.name),
                            toolExecution: execution
                        )
                    )
                }
                activeToolStatus = nil

                if round == Self.maxRemoteToolRounds - 1 {
                    appendMessage(
                        AssistantChatMessage(
                            role: .notice,
                            text: String(localized: "Completed multiple tool rounds. Send a follow-up to continue.")
                        )
                    )
                }
            }

            finishStreamingState()
            schedulePostActions(using: config, apiKey: apiKey)
        } catch is CancellationError {
            // Handled by stopGenerating()
        } catch {
            preservePartialStreamIfNeeded(modelLabel: config.model)
            appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
            finishStreamingState()
        }
    }

    /// Retries transient connection drops and 429/5xx responses automatically
    /// when no output has been delivered yet, preventing abrupt session failures
    /// on brief network handovers or rate limits.
    private func streamCompletionWithRetry(
        config: AIProviderConfig,
        apiKey: String?,
        systemPrompt: String,
        messages: [LLMConversationTurn],
        tools: [LLMToolSchema]
    ) async throws -> LLMResponseTurn {
        let maxRetries = 2
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let turn = try await remoteClient.streamCompletion(
                    config: config,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools,
                    onReasoningDelta: { @MainActor [weak self] delta in
                        self?.activeToolStatus = nil
                        self?.streamReasoning += delta
                    },
                    onTextDelta: { @MainActor [weak self] delta in
                        self?.activeToolStatus = nil
                        self?.streamText += delta
                    }
                )
                activeToolStatus = nil
                return turn
            } catch {
                let receivedAnyOutput = !streamText.isEmpty || !streamReasoning.isEmpty
                guard attempt < maxRetries,
                      !receivedAnyOutput,
                      RemoteLLMClient.isRetryableError(error)
                else {
                    throw error
                }
                attempt += 1
                activeToolStatus = String(localized: "Connection interrupted, retrying (\(attempt)/\(maxRetries))…")
                let delaySeconds: Double = attempt == 1 ? 1.5 : 3.5
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
    }

    private func preservePartialStreamIfNeeded(modelLabel: String?) {
        let partialText = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialReasoning = streamReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partialText.isEmpty || !partialReasoning.isEmpty else { return }
        appendMessage(
            AssistantChatMessage(
                role: .assistant,
                text: partialText.isEmpty ? String(localized: "(Interrupted)") : partialText,
                reasoning: partialReasoning,
                modelLabel: modelLabel
            )
        )
        streamText = ""
        streamReasoning = ""
    }

    private func executeTool(_ call: LLMToolCall) async -> AssistantToolExecution {
        let start = ContinuousClock.now
        let args = call.decodedJSONValue()

        if call.name == "load_skill" {
            let query = args["skill"]?.string ?? ""
            let output: String
            let isError: Bool
            if let skill = manager?.skillStore.skill(idOrName: query) {
                output = "# \(skill.name)\n\n\(skill.instructions)"
                isError = false
            } else {
                output = "Skill not found: \(query)"
                isError = true
            }
            return AssistantToolExecution(
                callID: call.id,
                toolName: call.name,
                argumentsJSON: call.argumentsJSON,
                output: output,
                isError: isError,
                targetHosts: [],
                durationMs: elapsedMilliseconds(since: start)
            )
        }

        let reply = await AgentServer.shared.invokeTool(call.name, arguments: args, client: Self.clientName)
        let storedOutput: String = if reply.text.count > Self.maxStoredToolOutputChars {
            String(reply.text.prefix(Self.maxStoredToolOutputChars)) + "\n… [truncated]"
        } else {
            reply.text
        }
        let hosts = extractTargetHosts(from: args)
        return AssistantToolExecution(
            callID: call.id,
            toolName: call.name,
            argumentsJSON: call.argumentsJSON,
            output: storedOutput,
            isError: reply.isError,
            targetHosts: hosts,
            durationMs: elapsedMilliseconds(since: start)
        )
    }

    private func extractTargetHosts(from args: JSONValue) -> [String] {
        var found: [String] = []
        if let single = args["host"]?.string, !single.isEmpty {
            found.append(single)
        }
        if let list = args["hosts"]?.strings {
            found.append(contentsOf: list)
        }
        if let targets = args["targets"] {
            if let list = targets["hosts"]?.strings {
                found.append(contentsOf: list)
            }
            if let group = targets["group"]?.string, !group.isEmpty {
                found.append("#\(group)")
            }
            if let tag = targets["tag"]?.string, !tag.isEmpty {
                found.append("@\(tag)")
            }
            if targets["all"]?.bool == true {
                found.append(String(localized: "All Servers"))
            }
        }
        return Array(NSOrderedSet(array: found)) as? [String] ?? found
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - On-Device Apple Intelligence (macOS 26+)

    private func runAppleIntelligenceTurn() async {
        guard let manager else { return }
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                guard AppleIntelligenceStatus.current == .available else {
                    appendMessage(AssistantChatMessage(role: .error, text: AppleIntelligenceStatus.current.localizedDescription))
                    return
                }
                guard let prompt = messages.last(where: { $0.role == .user })?.text else { return }

                isStreaming = true
                streamText = ""
                streamReasoning = ""
                manager.markExecuting(conversationID, running: true)

                if onDeviceExchangeCount >= 8 {
                    onDeviceSessionBox = nil
                    onDeviceExchangeCount = 0
                    appendMessage(
                        AssistantChatMessage(
                            role: .notice,
                            text: String(localized: "On-device context refreshed with recent summary.")
                        )
                    )
                }

                do {
                    let holder: OnDeviceServerSessionHolder
                    if let existing = onDeviceSessionBox as? OnDeviceServerSessionHolder {
                        holder = existing
                    } else {
                        var instructions = manager.buildInstructions(for: conversationID, compactForOnDevice: true)
                        // Rehydrate prior history when resuming a saved conversation on-device.
                        let prior = Array(messages.dropLast())
                        let digest = ConversationContextBuilder.buildOnDeviceHistoryDigest(from: prior)
                        if !digest.isEmpty {
                            instructions += "\n\n" + digest
                        }
                        holder = OnDeviceServerSessionHolder(instructions: instructions)
                        onDeviceSessionBox = holder
                    }

                    for try await snapshot in holder.session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        streamText = snapshot.content
                    }
                    let finalText = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
                    appendMessage(
                        AssistantChatMessage(
                            role: .assistant,
                            text: finalText.isEmpty ? String(localized: "(No response)") : finalText,
                            modelLabel: String(localized: "Apple Intelligence")
                        )
                    )
                    onDeviceExchangeCount += 1
                } catch is CancellationError {
                    // Handled by stopGenerating()
                } catch {
                    preservePartialStreamIfNeeded(modelLabel: String(localized: "Apple Intelligence"))
                    appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
                }

                finishStreamingState()
                return
            }
        #endif
        appendMessage(AssistantChatMessage(role: .error, text: AppleIntelligenceStatus.current.localizedDescription))
    }

    // MARK: - Apple Intelligence Private Cloud Compute (macOS 27+)

    private func runPrivateCloudComputeTurn() async {
        guard let manager else { return }
        #if canImport(FoundationModels) && compiler(>=6.4)
            if #available(macOS 27.0, *) {
                let status = ApplePrivateCloudComputeStatus.current
                guard status == .available else {
                    appendMessage(AssistantChatMessage(role: .error, text: status.localizedDescription))
                    return
                }
                guard let prompt = messages.last(where: { $0.role == .user })?.text else { return }

                isStreaming = true
                streamText = ""
                streamReasoning = ""
                manager.markExecuting(conversationID, running: true)

                do {
                    let holder: PrivateCloudComputeSessionHolder
                    if let existing = onDeviceSessionBox as? PrivateCloudComputeSessionHolder {
                        holder = existing
                    } else {
                        var instructions = manager.buildInstructions(for: conversationID, compactForOnDevice: false)
                        let prior = Array(messages.dropLast())
                        let digest = ConversationContextBuilder.buildOnDeviceHistoryDigest(from: prior)
                        if !digest.isEmpty {
                            instructions += "\n\n" + digest
                        }
                        holder = PrivateCloudComputeSessionHolder(instructions: instructions)
                        onDeviceSessionBox = holder
                    }

                    for try await snapshot in holder.session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        streamText = snapshot.content
                    }
                    let finalText = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
                    appendMessage(
                        AssistantChatMessage(
                            role: .assistant,
                            text: finalText.isEmpty ? String(localized: "(No response)") : finalText,
                            modelLabel: String(localized: "Apple Intelligence (PCC)")
                        )
                    )
                } catch is CancellationError {
                    // Handled by stopGenerating()
                } catch let pccError as PrivateCloudComputeLanguageModel.Error {
                    preservePartialStreamIfNeeded(modelLabel: String(localized: "Apple Intelligence (PCC)"))
                    let friendly: String = switch pccError {
                    case .networkFailure:
                        String(localized: "Unable to reach Apple Private Cloud Compute. Check your network connection and retry.")
                    case .quotaLimitReached:
                        String(localized: "Apple Private Cloud Compute usage limit reached. Try again later or switch to On-Device / another provider.")
                    case .serviceUnavailable:
                        String(localized: "Apple Private Cloud Compute is temporarily unavailable. Try again in a moment.")
                    @unknown default:
                        pccError.localizedDescription
                    }
                    appendMessage(AssistantChatMessage(role: .error, text: friendly))
                } catch {
                    preservePartialStreamIfNeeded(modelLabel: String(localized: "Apple Intelligence (PCC)"))
                    appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
                }

                finishStreamingState()
                return
            }
        #endif
        appendMessage(AssistantChatMessage(role: .error, text: ApplePrivateCloudComputeStatus.current.localizedDescription))
    }

    // MARK: - Post-Actions (Auto-Rename + Optional Cross-Session Summary)

    private func applyImmediateFallbackTitleIfNeeded(from userPrompt: String) {
        guard let manager,
              let conv = manager.conversation(id: conversationID),
              conv.shouldAutoRename,
              conv.title == String(localized: "New Conversation") || conv.title.isEmpty
        else { return }

        let cleaned = userPrompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? userPrompt
        let title = cleaned.count > 28 ? String(cleaned.prefix(28)) + "…" : cleaned
        manager.updateMetadata(conversationID) { item in
            item.title = title
        }
    }

    private func schedulePostActions(using config: AIProviderConfig, apiKey: String?) {
        guard let manager, let conv = manager.conversation(id: conversationID) else { return }

        // 1. Background LLM Auto-Title + Emoji on first completed exchange.
        if conv.shouldAutoRename {
            let sample = messages
                .filter { $0.role == .user || $0.role == .assistant }
                .prefix(4)
                .map { "\($0.role == .user ? "User" : "Assistant"): \(String($0.text.prefix(260)))" }
                .joined(separator: "\n")

            if !sample.isEmpty {
                let cid = conversationID
                Task.detached(priority: .utility) { [remoteClient] in
                    let sys = """
                    Generate a very short title (3–12 words or 4–14 Chinese characters) and one relevant emoji for this server operations chat.
                    Match the user's language. Reply in exactly two lines with no quotes or markdown:
                    EMOJI: <single emoji>
                    TITLE: <short title>
                    """
                    guard let raw = try? await remoteClient.completeText(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: sys,
                        userPrompt: sample,
                        maxTokens: 64
                    ) else { return }

                    var parsedEmoji = ""
                    var parsedTitle = ""
                    for line in raw.components(separatedBy: .newlines) {
                        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.uppercased().hasPrefix("EMOJI:") {
                            parsedEmoji = String(t.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if t.uppercased().hasPrefix("TITLE:") {
                            parsedTitle = String(t.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    guard !parsedTitle.isEmpty else { return }
                    await MainActor.run {
                        ServerAssistant.shared.applyAutoTitle(
                            for: cid,
                            title: String(parsedTitle.prefix(40)),
                            emoji: parsedEmoji.first.map(String.init)
                        )
                    }
                }
            }
        }

        // 2. Optional Cross-Session Memory Summary (FlowDown ConversationSummarizer pattern).
        if manager.crossSessionMemoryEnabled {
            let userCount = messages.filter { $0.role == .user }.count
            let delta = messages.count - conv.summaryMessageCount
            if userCount >= 3, delta >= 2 {
                let digest = messages
                    .filter { $0.role == .user || $0.role == .assistant }
                    .suffix(12)
                    .map { "\($0.role == .user ? "User" : "Assistant"): \(String($0.text.prefix(320)))" }
                    .joined(separator: "\n")
                let msgCount = messages.count
                let cid = conversationID

                Task.detached(priority: .utility) { [remoteClient] in
                    let sys = """
                    Summarize this SSH server operations conversation in 1–2 concise sentences (preserve key server names, findings, and changes). Plain text only.
                    """
                    guard let summary = try? await remoteClient.completeText(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: sys,
                        userPrompt: String(digest.prefix(3600)),
                        maxTokens: 160
                    ), !summary.isEmpty else { return }

                    await MainActor.run {
                        ServerAssistant.shared.saveSummary(summary, messageCount: msgCount, for: cid)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func appendMessage(_ message: AssistantChatMessage) {
        messages.append(message)
        persistMessages()
    }

    private func persistMessages() {
        manager?.persistMessages(messages, for: conversationID)
    }

    private func finishStreamingState() {
        activeToolStatus = nil
        streamText = ""
        streamReasoning = ""
        isStreaming = false
        activeTask = nil
        manager?.markExecuting(conversationID, running: false)
    }
}

// MARK: - Multi-Session Manager (`ConversationManager` + `ConversationSessionManager`)

@MainActor
@Observable
final class ServerAssistant {
    static let shared = ServerAssistant()

    private static let crossSessionMemoryKey = "sb.moe.tamio.ai.crossSessionMemory"
    private static let contextBudgetKey = "sb.moe.tamio.ai.contextTokenBudget"

    private(set) var conversations: [AssistantConversation] = []
    private(set) var activeConversationID: UUID
    private(set) var executingConversationIDs: Set<UUID> = []

    var crossSessionMemoryEnabled: Bool {
        didSet { UserDefaults.standard.set(crossSessionMemoryEnabled, forKey: Self.crossSessionMemoryKey) }
    }

    var contextTokenBudget: Int {
        didSet { UserDefaults.standard.set(contextTokenBudget, forKey: Self.contextBudgetKey) }
    }

    let providerStore: AIProviderStore
    let skillStore: ServerOpsSkillStore
    let bridge: AssistantAgentBridge

    /// True while the user is actively typing in AssistantView's keyboard-docked
    /// composer, so ContentView hides the TabView bottom accessory cleanly.
    var isComposerActive = false

    private let diskStore: AssistantConversationDiskStore
    private let remoteClient: RemoteLLMClient
    private var sessions: [UUID: ConversationSession] = [:]

    init(
        providerStore: AIProviderStore? = nil,
        skillStore: ServerOpsSkillStore? = nil,
        bridge: AssistantAgentBridge? = nil,
        diskStore: AssistantConversationDiskStore = .shared,
        remoteClient: RemoteLLMClient = RemoteLLMClient()
    ) {
        self.providerStore = providerStore ?? .shared
        self.skillStore = skillStore ?? .shared
        self.bridge = bridge ?? .shared
        self.diskStore = diskStore
        self.remoteClient = remoteClient
        crossSessionMemoryEnabled = UserDefaults.standard.bool(forKey: Self.crossSessionMemoryKey)
        let savedBudget = UserDefaults.standard.integer(forKey: Self.contextBudgetKey)
        contextTokenBudget = savedBudget > 0 ? savedBudget : 64000

        let loaded = diskStore.loadIndex()
        if let first = Self.sorted(loaded).first {
            conversations = Self.sorted(loaded)
            activeConversationID = first.id
        } else {
            let initial = AssistantConversation()
            conversations = [initial]
            activeConversationID = initial.id
            diskStore.saveIndex([initial])
        }
    }

    // MARK: - Active Conversation & Session Accessors

    var activeConversation: AssistantConversation {
        conversation(id: activeConversationID) ?? conversations.first ?? AssistantConversation()
    }

    var activeSession: ConversationSession {
        session(for: activeConversationID)
    }

    func conversation(id: UUID) -> AssistantConversation? {
        conversations.first { $0.id == id }
    }

    func session(for id: UUID) -> ConversationSession {
        if let cached = sessions[id] {
            return cached
        }
        let msgs = diskStore.loadMessages(for: id)
        let created = ConversationSession(conversationID: id, messages: msgs, manager: self, remoteClient: remoteClient)
        sessions[id] = created
        return created
    }

    var backgroundActivityCount: Int {
        let runningOthers = executingConversationIDs.filter { $0 != activeConversationID }.count
        let approvalOthers = bridge.pendingApprovals.filter { $0.conversationID != nil && $0.conversationID != activeConversationID }.count
        return runningOthers + approvalOthers
    }

    // MARK: - Convenience Forwarding for Active Conversation

    var messages: [AssistantChatMessage] {
        activeSession.messages
    }

    var streamText: String {
        activeSession.streamText
    }

    var streamReasoning: String {
        activeSession.streamReasoning
    }

    var isStreaming: Bool {
        activeSession.isStreaming
    }

    var activeToolStatus: String? {
        activeSession.activeToolStatus
    }

    var targetScope: AssistantTargetScope {
        get { sanitizedScope(activeConversation.targetScope) }
        set {
            updateMetadata(activeConversationID) { $0.targetScope = newValue }
        }
    }

    var pinnedSkillIDs: Set<String> {
        get { activeConversation.pinnedSkillIDs }
        set {
            updateMetadata(activeConversationID) { $0.pinnedSkillIDs = newValue }
            activeSession.resetOnDeviceContext()
        }
    }

    var draftText: String {
        get { activeConversation.draftText }
        set {
            guard let idx = conversations.firstIndex(where: { $0.id == activeConversationID }),
                  conversations[idx].draftText != newValue
            else { return }
            conversations[idx].draftText = newValue
            diskStore.saveIndex(conversations)
        }
    }

    func togglePinnedSkill(_ skillID: String) {
        var set = pinnedSkillIDs
        if set.contains(skillID) {
            set.remove(skillID)
        } else {
            set.insert(skillID)
        }
        pinnedSkillIDs = set
    }

    func send(_ text: String) {
        activeSession.send(text)
    }

    func stopGenerating() {
        activeSession.stopGenerating()
    }

    // MARK: - Provider Resolution (Per-Conversation Override or Global Default)

    func effectiveSelection(for conversationID: UUID? = nil) -> AIActiveSelection {
        let appleReady = AppleIntelligenceStatus.current == .available
        let pccReady = providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available
        if let cid = conversationID ?? Optional(activeConversationID),
           let override = conversation(id: cid)?.providerSelection
        {
            switch override {
            case .appleIntelligence where appleReady:
                return .appleIntelligence
            case .applePrivateCloudCompute where pccReady:
                return .applePrivateCloudCompute
            case let .custom(id) where providerStore.providers.contains(where: { $0.id == id && $0.isEnabled }):
                return .custom(providerId: id)
            default:
                break
            }
        }
        return providerStore.effectiveSelection(appleIntelligenceAvailable: appleReady, pccAvailable: pccReady)
    }

    func resolvedProviderConfig(for conversationID: UUID, providerId: String) -> AIProviderConfig? {
        guard var config = providerStore.provider(id: providerId), config.isEnabled else { return nil }
        if let overrideModel = conversation(id: conversationID)?.modelOverride, !overrideModel.isEmpty {
            config.model = overrideModel
        }
        return config
    }

    var isReadyToChat: Bool {
        switch effectiveSelection(for: activeConversationID) {
        case .appleIntelligence:
            return AppleIntelligenceStatus.current == .available
        case .applePrivateCloudCompute:
            return providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available
        case let .custom(providerId):
            guard let config = resolvedProviderConfig(for: activeConversationID, providerId: providerId) else { return false }
            return providerStore.hasCredential(for: config) && !config.model.isEmpty
        }
    }

    var activeProviderLabel: String {
        let appleReady = AppleIntelligenceStatus.current == .available
        switch effectiveSelection(for: activeConversationID) {
        case .appleIntelligence:
            return String(localized: "Apple Intelligence")
        case .applePrivateCloudCompute:
            return String(localized: "Apple Intelligence (PCC)")
        case let .custom(id):
            return providerStore.provider(id: id)?.name ?? providerStore.activeDisplayName(appleIntelligenceAvailable: appleReady)
        }
    }

    func activeModelLabel(for conversationID: UUID? = nil) -> String {
        let cid = conversationID ?? activeConversationID
        switch effectiveSelection(for: cid) {
        case .appleIntelligence:
            return String(localized: "On-Device")
        case .applePrivateCloudCompute:
            return String(localized: "Private Cloud Compute")
        case let .custom(id):
            return resolvedProviderConfig(for: cid, providerId: id)?.model ?? ""
        }
    }

    func setActiveConversationProvider(_ selection: AIActiveSelection, modelOverride: String? = nil) {
        providerStore.selectActive(selection)
        updateMetadata(activeConversationID) { conv in
            conv.providerSelection = selection
            conv.modelOverride = modelOverride
        }
    }

    func setActiveConversationModel(_ model: String, for providerId: String) {
        providerStore.setModel(model, for: providerId)
        updateMetadata(activeConversationID) { conv in
            conv.providerSelection = .custom(providerId: providerId)
            conv.modelOverride = model
        }
    }

    // MARK: - Conversation CRUD

    @discardableResult
    func createNewConversation(
        targetScope: AssistantTargetScope? = nil,
        pinnedSkills: Set<String>? = nil,
        select: Bool = true
    ) -> AssistantConversation {
        // Reuse an already-empty newest conversation if the user taps New Chat on a blank one.
        if select,
           let current = conversation(id: activeConversationID),
           current.messageCount == 0,
           activeSession.messages.isEmpty,
           !activeSession.isStreaming,
           targetScope == nil
        {
            return current
        }

        let conv = AssistantConversation(
            targetScope: targetScope ?? .all,
            pinnedSkillIDs: pinnedSkills ?? []
        )
        conversations.insert(conv, at: 0)
        conversations = Self.sorted(conversations)
        diskStore.saveIndex(conversations)
        if select {
            activeConversationID = conv.id
        }
        return conv
    }

    func selectConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeConversationID = id
        _ = session(for: id)
    }

    func renameConversation(_ id: UUID, title: String, icon: String? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateMetadata(id) { conv in
            conv.title = trimmed
            if let icon, !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conv.icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            conv.shouldAutoRename = false
        }
    }

    func togglePin(_ id: UUID) {
        updateMetadata(id) { conv in
            conv.isPinned.toggle()
        }
    }

    @discardableResult
    func duplicateConversation(_ id: UUID, upToMessageID: UUID? = nil) -> AssistantConversation? {
        guard let source = conversation(id: id) else { return nil }
        var sourceMessages = session(for: id).messages
        if let cutoff = upToMessageID, let idx = sourceMessages.firstIndex(where: { $0.id == cutoff }) {
            sourceMessages = Array(sourceMessages[...idx])
        }
        let clonedMessages = sourceMessages.map { msg in
            AssistantChatMessage(
                id: UUID(),
                role: msg.role,
                text: msg.text,
                reasoning: msg.reasoning,
                toolExecution: msg.toolExecution,
                timestamp: msg.timestamp,
                modelLabel: msg.modelLabel
            )
        }
        let copyTitle = String(localized: "\(source.title) Copy")
        let cloned = AssistantConversation(
            title: copyTitle,
            icon: source.icon,
            shouldAutoRename: false,
            isPinned: false,
            lastMessagePreview: Self.previewText(from: clonedMessages),
            messageCount: clonedMessages.count,
            providerSelection: source.providerSelection,
            modelOverride: source.modelOverride,
            targetScope: source.targetScope,
            pinnedSkillIDs: source.pinnedSkillIDs
        )
        conversations.insert(cloned, at: 0)
        conversations = Self.sorted(conversations)
        diskStore.saveMessages(clonedMessages, for: cloned.id)
        diskStore.saveIndex(conversations)
        sessions[cloned.id] = ConversationSession(conversationID: cloned.id, messages: clonedMessages, manager: self, remoteClient: remoteClient)
        activeConversationID = cloned.id
        return cloned
    }

    /// FlowDown `ConversationManager+Compress`: summarizes a conversation into a fresh,
    /// low-token session carrying all server conclusions and open follow-ups.
    func compressConversation(_ id: UUID) {
        guard let source = conversation(id: id) else { return }
        let sourceMessages = session(for: id).messages
        guard !sourceMessages.isEmpty else { return }

        guard case let .custom(providerId) = effectiveSelection(for: id),
              let config = resolvedProviderConfig(for: id, providerId: providerId)
        else {
            // On-device fallback: copy a compact digest into a new session directly.
            let digest = ConversationContextBuilder.buildOnDeviceHistoryDigest(from: sourceMessages, maxChars: 2400)
            let fresh = AssistantConversation(
                title: source.title,
                icon: "🗜️",
                shouldAutoRename: false,
                lastMessagePreview: String(digest.prefix(120)),
                messageCount: 1,
                targetScope: source.targetScope,
                pinnedSkillIDs: source.pinnedSkillIDs
            )
            let msg = AssistantChatMessage(role: .assistant, text: digest)
            conversations.insert(fresh, at: 0)
            conversations = Self.sorted(conversations)
            diskStore.saveMessages([msg], for: fresh.id)
            diskStore.saveIndex(conversations)
            sessions[fresh.id] = ConversationSession(conversationID: fresh.id, messages: [msg], manager: self, remoteClient: remoteClient)
            activeConversationID = fresh.id
            return
        }

        let transcript = ConversationContextBuilder.exportMarkdown(conversation: source, messages: sourceMessages)
        let fresh = AssistantConversation(
            title: source.title,
            icon: "🗜️",
            shouldAutoRename: false,
            providerSelection: source.providerSelection,
            modelOverride: source.modelOverride,
            targetScope: source.targetScope,
            pinnedSkillIDs: source.pinnedSkillIDs
        )
        conversations.insert(fresh, at: 0)
        conversations = Self.sorted(conversations)
        diskStore.saveIndex(conversations)
        activeConversationID = fresh.id

        let newSession = session(for: fresh.id)
        let apiKey = providerStore.apiKey(for: config.id)
        newSession.runCompressionStream(
            sourceTitle: source.title,
            sourceTranscript: transcript,
            config: config,
            apiKey: apiKey
        )
    }

    func deleteConversation(_ id: UUID) {
        sessions[id]?.stopGenerating()
        sessions.removeValue(forKey: id)
        executingConversationIDs.remove(id)
        bridge.denyPending(for: id)
        conversations.removeAll { $0.id == id }
        diskStore.deleteMessages(for: id)

        if conversations.isEmpty {
            let fresh = AssistantConversation()
            conversations = [fresh]
            activeConversationID = fresh.id
        } else if activeConversationID == id {
            activeConversationID = conversations[0].id
        }
        diskStore.saveIndex(conversations)
    }

    func eraseAllConversations() {
        for (_, sess) in sessions {
            sess.stopGenerating()
        }
        sessions.removeAll()
        executingConversationIDs.removeAll()
        bridge.denyAllPending()
        diskStore.eraseAll()

        let fresh = AssistantConversation()
        conversations = [fresh]
        activeConversationID = fresh.id
        diskStore.saveIndex(conversations)
    }

    func exportMarkdown(for id: UUID) -> String {
        guard let conv = conversation(id: id) else { return "" }
        let msgs = session(for: id).messages
        return ConversationContextBuilder.exportMarkdown(conversation: conv, messages: msgs)
    }

    func searchConversationIDs(query: String) async -> Set<UUID> {
        await diskStore.matchingConversationIDs(query: query, in: conversations)
    }

    // MARK: - Internal Session Callbacks

    func persistMessages(_ messages: [AssistantChatMessage], for id: UUID) {
        diskStore.saveMessages(messages, for: id)
        updateMetadata(id, touchUpdatedAt: true) { conv in
            conv.messageCount = messages.count
            conv.lastMessagePreview = Self.previewText(from: messages)
        }
    }

    func markExecuting(_ id: UUID, running: Bool) {
        if running {
            executingConversationIDs.insert(id)
        } else {
            executingConversationIDs.remove(id)
        }
        // macOS has no background grace controller to hand over to.
    }

    func applyAutoTitle(for id: UUID, title: String, emoji: String?) {
        guard let conv = conversation(id: id), conv.shouldAutoRename else { return }
        updateMetadata(id) { item in
            item.title = title
            if let emoji, !emoji.isEmpty {
                item.icon = emoji
            }
            item.shouldAutoRename = false
        }
    }

    func saveSummary(_ summary: String, messageCount: Int, for id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        updateMetadata(id) { item in
            item.summary = summary
            item.summaryMessageCount = messageCount
        }
    }

    func updateMetadata(_ id: UUID, touchUpdatedAt: Bool = false, _ mutate: (inout AssistantConversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[idx])
        if touchUpdatedAt {
            conversations[idx].updatedAt = Date()
        }
        conversations = Self.sorted(conversations)
        diskStore.saveIndex(conversations)
    }

    // MARK: - Server Scope & Prompt Construction

    func sanitizedScope(_ scope: AssistantTargetScope) -> AssistantTargetScope {
        let validIDs = Set(TamioStore.shared.machineGroup.machines.map(\.id))
        let validGroups = Set(TamioStore.shared.machineGroup.machines.map(\.group).filter { !$0.isEmpty })
        switch scope {
        case .all:
            return .all
        case let .group(group):
            return validGroups.contains(group) ? .group(group) : .all
        case let .hosts(ids):
            let remaining = ids.intersection(validIDs)
            return remaining.isEmpty ? .all : .hosts(remaining)
        }
    }

    func resolvedScopedMachines(for conversationID: UUID? = nil) -> [RDMachine] {
        let all = TamioStore.shared.machineGroup.machines
        let rawScope = (conversationID.flatMap { conversation(id: $0)?.targetScope }) ?? activeConversation.targetScope
        switch sanitizedScope(rawScope) {
        case .all:
            return all
        case let .group(group):
            return all.filter { $0.group == group }
        case let .hosts(ids):
            return all.filter { ids.contains($0.id) }
        }
    }

    var remoteToolSchemas: [LLMToolSchema] {
        var schemas: [LLMToolSchema] = AgentServer.toolDefinitions.compactMap { def in
            guard let name = def["name"]?.string,
                  let description = def["description"]?.string,
                  let inputSchema = def["inputSchema"]
            else { return nil }
            return LLMToolSchema(name: name, description: description, inputSchema: inputSchema)
        }
        schemas.append(
            LLMToolSchema(
                name: "load_skill",
                description: "Load the full instructions of an enabled server operations skill by its id or name.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "skill": ["type": "string", "description": "Skill id or name from <available_skills>"],
                    ],
                    "required": ["skill"],
                ]
            )
        )
        return schemas
    }

    func buildInstructions(for conversationID: UUID, compactForOnDevice: Bool) -> String {
        let conv = conversation(id: conversationID) ?? activeConversation
        let scope = sanitizedScope(conv.targetScope)
        let scoped = resolvedScopedMachines(for: conversationID)

        let scopeDescription: String
        switch scope {
        case .all:
            let names = scoped.prefix(20).map(\.name).joined(separator: ", ")
            scopeDescription = scoped.isEmpty
                ? "The user has not added any SSH servers yet."
                : "Active target scope: ALL servers (\(scoped.count) total: \(names)\(scoped.count > 20 ? ", …" : ""))."
        case let .group(group):
            let names = scoped.map(\.name).joined(separator: ", ")
            scopeDescription = "Active target scope: group \"\(group)\" (\(scoped.count) servers: \(names)). Default batch operations to this group unless the user names different servers."
        case .hosts:
            let names = scoped.map(\.name).joined(separator: ", ")
            scopeDescription = "Active target scope: selected \(scoped.count) server(s): \(names). Default batch operations to these exact hosts unless the user names different servers."
        }

        var prompt = """
        You are Tamio AI, the built-in SSH fleet management assistant inside Tamio.
        You have direct access to Tamio's MCP tools (`list_hosts`, `get_host`, `get_metrics`, `run_command`, `run_snippet`, `add_host`, `update_host`, `remove_host`, `list_identities`, `add_identity`, `list_snippets`, `add_snippet`, `list_port_forwards`, `add_port_forward`, `start_port_forward`, `stop_port_forward`, `get_activity`, `export_ssh_config`, etc.).

        \(scopeDescription)

        Rules:
        1. Reply in the same language the user writes in (e.g. Simplified Chinese if the user writes in Chinese).
        2. Always query real data with tools before answering about servers, metrics, logs, services, or containers. Never fabricate hostnames, IP addresses, or command outputs.
        3. For batch operations across multiple servers, prefer a single `run_command` call with `targets` (`{"all": true}`, `{"group": "..."}`, `{"tag": "..."}`, or `{"hosts": [...]}`): Tamio executes across servers concurrently and asks the user to confirm once.
        4. Every write or command execution (`run_command`, `run_snippet`, `add_*`, `update_*`, `remove_*`) prompts the user for inline approval in the chat UI and is recorded in server activity history. Always pass a concise `task` label (e.g. "Check disk usage", "Restart nginx") so related steps stay grouped in history.
        5. Never ask for or expose passwords or private keys; Tamio authenticates automatically with its saved credentials.
        6. Keep answers crisp and scannable: lead with a 1-sentence conclusion, then use clean Markdown tables or bullet lists for per-server results, highlighting anomalies and actionable next steps.
        7. If the user declines an approval card, acknowledge it calmly and do not retry the declined action without being asked.
        """

        let skillFragment = skillStore.buildSystemPromptFragment(
            pinnedSkillIDs: conv.pinnedSkillIDs,
            compactForOnDevice: compactForOnDevice
        )
        if !skillFragment.isEmpty {
            prompt += "\n\n" + skillFragment
        }

        if crossSessionMemoryEnabled, !compactForOnDevice {
            let recent = recentMemorySummaries(excluding: conversationID)
            if !recent.isEmpty {
                prompt += "\n\n" + recent
            }
        }
        return prompt
    }

    private func recentMemorySummaries(excluding currentID: UUID) -> String {
        let items = conversations
            .filter { $0.id != currentID && !($0.summary ?? "").isEmpty }
            .prefix(8)
        guard !items.isEmpty else { return "" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        var lines = ["Recent server ops conversation summaries (background context only):"]
        for (i, item) in items.enumerated() {
            lines.append("\(i + 1). [\(df.string(from: item.updatedAt))] \(item.title): \(item.summary ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func sorted(_ items: [AssistantConversation]) -> [AssistantConversation] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned {
                return a.isPinned
            }
            return a.updatedAt > b.updatedAt
        }
    }

    private static func previewText(from messages: [AssistantChatMessage]) -> String {
        guard let last = messages.last(where: { $0.role == .assistant || $0.role == .user }) else {
            return ""
        }
        let cleaned = last.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 120 ? String(cleaned.prefix(120)) + "…" : cleaned
    }

    static func localizedToolActivity(for name: String) -> String {
        switch name {
        case "list_hosts": String(localized: "Listing saved servers…")
        case "get_host": String(localized: "Inspecting server details…")
        case "get_metrics": String(localized: "Reading live server metrics…")
        case "export_ssh_config": String(localized: "Exporting SSH config…")
        case "run_command": String(localized: "Running command on servers…")
        case "run_snippet": String(localized: "Running saved snippet…")
        case "add_host": String(localized: "Adding server…")
        case "update_host": String(localized: "Updating server…")
        case "remove_host": String(localized: "Removing server…")
        case "list_identities": String(localized: "Listing SSH identities…")
        case "add_identity": String(localized: "Creating SSH identity…")
        case "remove_identity": String(localized: "Removing SSH identity…")
        case "list_snippets": String(localized: "Listing saved snippets…")
        case "add_snippet", "update_snippet": String(localized: "Saving snippet…")
        case "remove_snippet": String(localized: "Removing snippet…")
        case "list_port_forwards": String(localized: "Listing port forwards…")
        case "add_port_forward", "start_port_forward", "stop_port_forward", "remove_port_forward":
            String(localized: "Updating port forward…")
        case "get_activity": String(localized: "Reading agent history…")
        case "log_activity": String(localized: "Recording activity…")
        case "load_skill": String(localized: "Loading operations skill…")
        default: String(localized: "Running \(name)…")
        }
    }

    static func localizedToolTitle(for name: String) -> String {
        switch name {
        case "list_hosts": String(localized: "List Servers")
        case "get_host": String(localized: "Inspect Server")
        case "get_metrics": String(localized: "Live Metrics")
        case "export_ssh_config": String(localized: "Export SSH Config")
        case "run_command": String(localized: "Run Command")
        case "run_snippet": String(localized: "Run Snippet")
        case "add_host": String(localized: "Add Server")
        case "update_host": String(localized: "Update Server")
        case "remove_host": String(localized: "Remove Server")
        case "list_identities": String(localized: "List Identities")
        case "add_identity": String(localized: "Add Identity")
        case "remove_identity": String(localized: "Remove Identity")
        case "list_snippets": String(localized: "List Snippets")
        case "add_snippet": String(localized: "Add Snippet")
        case "update_snippet": String(localized: "Update Snippet")
        case "remove_snippet": String(localized: "Remove Snippet")
        case "list_port_forwards": String(localized: "List Port Forwards")
        case "add_port_forward": String(localized: "Add Port Forward")
        case "start_port_forward": String(localized: "Start Port Forward")
        case "stop_port_forward": String(localized: "Stop Port Forward")
        case "remove_port_forward": String(localized: "Remove Port Forward")
        case "get_activity": String(localized: "Agent History")
        case "log_activity": String(localized: "Log Activity")
        case "load_skill": String(localized: "Load Ops Skill")
        default: name
        }
    }
}
