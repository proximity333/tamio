//
//  MacAssistantView.swift
//  Tamio (macOS)
//
//  Native macOS AI Fleet Assistant:
//  - FlowDown-style multi-session sidebar with pin, rename, duplicate, compress,
//    export Markdown, search, and per-conversation execution badges
//  - Target Server Scope bar (All Servers / Group / Selected Hosts popover)
//    & Pinned Ops Skills strip
//  - Per-conversation Provider + Model switcher
//  - Shimmering Thinking disclosure, MCP tool cards, inline approval cards,
//    per-message Copy / Regenerate / Edit & Resend / Fork Here / Delete
//  - FlowDown unified composer + morphing Send/Stop button
//  - Full AI Providers manager (Test Connection, Fetch Models, Edit/Add, PCC toggle)
//  - Full Ops Skills manager (Category filter, Pin, Run, Import SKILL.md File/URL)
//

import AppKit
import SwiftUI
import TamioDesign
import TamioModule
import UniformTypeIdentifiers

struct MacAssistantView: View {
    @EnvironmentObject private var store: TamioStore
    @State private var assistant = ServerAssistant.shared
    @State private var providerStore = AIProviderStore.shared
    @State private var skillStore = ServerOpsSkillStore.shared
    @State private var bridge = AssistantAgentBridge.shared

    @State private var inputText = ""
    @State private var showHistorySidebar = true
    @State private var showProvidersSheet = false
    @State private var showSkillsSheet = false
    @State private var showHostScopePopover = false
    @State private var historySearch = ""
    @State private var pendingImages: [AssistantAttachmentDraft] = []
    @State private var previewingImage: AssistantAttachmentDraft?
    @State private var imageError: String?
    @State private var isPreparingImages = false
    @State private var pasteMonitor: Any?
    @FocusState private var composerFocused: Bool

    // Dialog states
    @State private var renamingConversation: AssistantConversation?
    @State private var renameTitle = ""
    @State private var renameEmoji = ""
    @State private var editingMessage: AssistantChatMessage?
    @State private var editMessageText = ""

    private var appleReady: Bool {
        AppleIntelligenceStatus.current == .available
    }

    private var pccReady: Bool {
        providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available
    }

    private var activeConversation: AssistantConversation {
        assistant.activeConversation
    }

    private var activeSession: ConversationSession {
        assistant.activeSession
    }

    private var effectiveSelection: AIActiveSelection {
        assistant.effectiveSelection(for: activeConversation.id)
    }

    private var activeApprovals: [AssistantAgentBridge.PendingApproval] {
        bridge.pendingApprovals(for: activeConversation.id)
    }

    /// Apple Intelligence is text-only, and DeepSeek's API does not take
    /// images; everything else is left on and reports its own error.
    private var canAttachImages: Bool {
        switch effectiveSelection {
        case let .custom(providerId):
            providerStore.provider(id: providerId)?.kind.supportsImages ?? false
        case .appleIntelligence, .applePrivateCloudCompute:
            false
        }
    }

    private var hasContent: Bool {
        !activeSession.messages.isEmpty || !activeApprovals.isEmpty || activeSession.isStreaming
    }

    private var filteredConversations: [AssistantConversation] {
        let q = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return assistant.conversations }
        return assistant.conversations.filter {
            $0.title.lowercased().contains(q) || $0.lastMessagePreview.lowercased().contains(q)
        }
    }

    private var allGroups: [String] {
        Array(Set(store.machineGroup.machines.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    private var pinnedSkills: [ServerOpsSkill] {
        let ids = assistant.pinnedSkillIDs
        return skillStore.enabledSkills.filter { ids.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showHistorySidebar {
                conversationSidebar
                    .frame(width: 240)
                Divider()
            }

            mainChatColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            bridge.install()
            bridge.inlineApprovalActive = true
            inputText = assistant.draftText
            installPasteMonitor()
        }
        .onDisappear {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
                self.pasteMonitor = nil
            }
            bridge.inlineApprovalActive = false
            assistant.draftText = inputText
        }
        .onChange(of: assistant.activeConversationID) { _, _ in
            inputText = assistant.draftText
            pendingImages = []
            imageError = nil
        }
        .onChange(of: inputText) { _, next in
            if assistant.draftText != next {
                assistant.draftText = next
            }
        }
        .sheet(isPresented: $showProvidersSheet) {
            MacAIProviderSettingsSheet(store: providerStore, assistant: assistant) {
                showProvidersSheet = false
            }
        }
        .sheet(isPresented: $showSkillsSheet) {
            MacOpsSkillsSheet(store: skillStore, assistant: assistant) {
                showSkillsSheet = false
            }
        }
        .sheet(item: $renamingConversation) { conv in
            SheetScaffold("Rename Conversation") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("Emoji", text: $renameEmoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        TextField("Conversation Title", text: $renameTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding()
                .frame(width: 380)
            } footer: {
                Spacer()
                Button("Cancel") { renamingConversation = nil }
                    .buttonStyle(.rx)
                Button("Save") {
                    assistant.renameConversation(conv.id, title: renameTitle, icon: renameEmoji.isEmpty ? nil : renameEmoji)
                    renamingConversation = nil
                }
                .buttonStyle(.rxPrimary)
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $editingMessage) { msg in
            SheetScaffold("Edit & Resend") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Editing this message will replace all subsequent replies in this conversation.")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                    TextEditor(text: $editMessageText)
                        .font(.body)
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding()
                .frame(width: 460)
            } footer: {
                Spacer()
                Button("Cancel") { editingMessage = nil }
                    .buttonStyle(.rx)
                Button("Resend") {
                    activeSession.editAndResend(messageID: msg.id, newText: editMessageText)
                    editingMessage = nil
                }
                .buttonStyle(.rxPrimary)
                .disabled(editMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $previewingImage) { draft in
            MacImagePreviewSheet(draft: draft) {
                previewingImage = nil
            }
        }
    }

    // MARK: - Conversation History Sidebar

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Conversations")
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                Spacer()
                Button {
                    assistant.createNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("New Conversation")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            TextField("Search chats", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredConversations) { conv in
                        let isSelected = conv.id == assistant.activeConversationID
                        Button {
                            assistant.selectConversation(conv.id)
                        } label: {
                            HStack(spacing: 7) {
                                if conv.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                }
                                if !conv.icon.isEmpty {
                                    Text(conv.icon)
                                        .font(.system(size: 12))
                                }
                                Text(conv.title)
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                if assistant.executingConversationIDs.contains(conv.id) {
                                    ProgressView().controlSize(.mini)
                                }
                                if bridge.hasPendingApproval(for: conv.id) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            conversationContextMenuItems(for: conv)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func conversationContextMenuItems(for conv: AssistantConversation) -> some View {
        Button {
            renameTitle = conv.title
            renameEmoji = conv.icon
            renamingConversation = conv
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            assistant.togglePin(conv.id)
        } label: {
            Label(conv.isPinned ? "Unpin" : "Pin", systemImage: conv.isPinned ? "pin.slash" : "pin")
        }

        Button {
            _ = assistant.duplicateConversation(conv.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Button {
            assistant.compressConversation(conv.id)
        } label: {
            Label("Compress into New Chat", systemImage: "arrow.down.right.and.arrow.up.left")
        }

        Button {
            exportConversationMarkdown(conv)
        } label: {
            Label("Export Markdown…", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            assistant.deleteConversation(conv.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func exportConversationMarkdown(_ conv: AssistantConversation) {
        let md = assistant.exportMarkdown(for: conv.id)
        let panel = NSSavePanel()
        let safeTitle = conv.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(safeTitle.isEmpty ? "Conversation" : safeTitle).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Main Chat Column

    private var mainChatColumn: some View {
        VStack(spacing: 0) {
            topHeaderBar
            Divider()

            if assistant.isReadyToChat {
                scopeAndSkillsBar
                Divider()
            }

            if !assistant.isReadyToChat {
                setupRequiredView
            } else if !hasContent {
                emptyChatView
            } else {
                transcriptScrollView
            }

            if assistant.isReadyToChat {
                Divider()
                flowDownComposer
            }
        }
    }

    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showHistorySidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.rx)
            .help("Toggle Conversation History")

            providerAndModelMenu

            Spacer()

            Button {
                showSkillsSheet = true
            } label: {
                Label("Ops Skills (\(skillStore.enabledSkills.count))", systemImage: "wand.and.stars")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.rx)

            Button {
                showProvidersSheet = true
            } label: {
                Label("AI Providers", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.rx)

            Menu {
                conversationContextMenuItems(for: activeConversation)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Conversation Actions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var providerAndModelMenu: some View {
        Menu {
            if appleReady {
                Button {
                    assistant.setActiveConversationProvider(.appleIntelligence)
                } label: {
                    Label("Apple Intelligence (On-Device)", systemImage: effectiveSelection == .appleIntelligence ? "checkmark" : "sparkles")
                }
            }
            if pccReady {
                Button {
                    assistant.setActiveConversationProvider(.applePrivateCloudCompute)
                } label: {
                    Label("Apple Intelligence (PCC)", systemImage: effectiveSelection == .applePrivateCloudCompute ? "checkmark" : "cloud")
                }
            }
            if !providerStore.enabledProviders.isEmpty {
                Divider()
                ForEach(providerStore.enabledProviders) { provider in
                    let isSelectedProvider = effectiveSelection == .custom(providerId: provider.id)
                    let activeModel = isSelectedProvider ? assistant.activeModelLabel() : provider.model
                    let models = provider.mergedModels
                    if models.count > 1 {
                        Menu {
                            ForEach(models, id: \.self) { m in
                                Button {
                                    assistant.setActiveConversationModel(m, for: provider.id)
                                } label: {
                                    Label(m, systemImage: (isSelectedProvider && activeModel == m) ? "checkmark" : "cpu")
                                }
                            }
                        } label: {
                            Label(
                                "\(provider.name) (\(provider.model))",
                                systemImage: isSelectedProvider ? "checkmark" : provider.kind.systemImage
                            )
                        }
                    } else {
                        Button {
                            assistant.setActiveConversationProvider(.custom(providerId: provider.id), modelOverride: provider.model)
                        } label: {
                            Label(
                                "\(provider.name) (\(provider.model))",
                                systemImage: isSelectedProvider ? "checkmark" : provider.kind.systemImage
                            )
                        }
                    }
                }
            }
            Divider()
            Button("Manage AI Providers…") { showProvidersSheet = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(assistant.activeProviderLabel)
                    .font(.rxBodyStrong)
                let model = assistant.activeModelLabel()
                if !model.isEmpty {
                    Text("· \(model)")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Target Scope & Pinned Skills Bar

    private var scopeAndSkillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // All Servers pill
                scopePill(
                    title: String(localized: "All Servers (\(store.machineGroup.machines.count))"),
                    icon: "server.rack",
                    selected: assistant.targetScope == .all
                ) {
                    assistant.targetScope = .all
                }

                // Group pills
                ForEach(allGroups, id: \.self) { group in
                    let count = store.machineGroup.machines.filter { $0.group == group }.count
                    scopePill(
                        title: "\(group) (\(count))",
                        icon: "folder",
                        selected: assistant.targetScope == .group(group)
                    ) {
                        assistant.targetScope = .group(group)
                    }
                }

                // Custom Hosts popover pill
                let selectedHostCount: Int = {
                    if case let .hosts(ids) = assistant.targetScope {
                        return ids.count
                    }
                    return 0
                }()
                Button {
                    showHostScopePopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .semibold))
                        Text(selectedHostCount > 0 ? String(localized: "\(selectedHostCount) Selected") : String(localized: "Select Hosts"))
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        selectedHostCount > 0 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                        in: Capsule()
                    )
                    .foregroundStyle(selectedHostCount > 0 ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHostScopePopover, arrowEdge: .bottom) {
                    MacHostScopePopover(
                        machines: store.machineGroup.machines,
                        scope: Binding(
                            get: { assistant.targetScope },
                            set: { assistant.targetScope = $0 }
                        )
                    )
                }

                if !pinnedSkills.isEmpty {
                    Divider().frame(height: 14).padding(.horizontal, 2)
                    ForEach(pinnedSkills) { skill in
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text(skill.name)
                                .font(.caption.weight(.medium))
                            Button {
                                assistant.togglePinnedSkill(skill.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    private func scopePill(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var setupRequiredView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 38))
                .foregroundStyle(Color.accentColor)
            Text("Configure an AI Provider")
                .font(.title3.bold())
            Text("Connect OpenAI, Anthropic Claude, Gemini, DeepSeek, Ollama, or enable Apple Intelligence to manage your SSH servers with live metrics and approval-gated MCP tools.")
                .font(.subheadline)
                .foregroundStyle(.rxInkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Manage AI Providers…") { showProvidersSheet = true }
                .buttonStyle(.rxPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyChatView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                Text("Tamio AI Fleet Assistant")
                    .font(.title2.bold())
                Text("Inspect live metrics, diagnose services, and run approval-gated commands across your servers.")
                    .font(.subheadline)
                    .foregroundStyle(.rxInkSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    quickPromptButton("Fleet Health Check", "CPU, memory, disk & load across servers", "heart.text.square",
                                      "Run a fleet health check across my servers: summarize CPU, memory, disk usage, load average, and flag any anomalies.")
                    quickPromptButton("Batch Disk & Log Audit", "Large dirs, journalctl & Docker space", "internaldrive",
                                      "Check disk usage across my servers and find the largest directories, systemd journal size, and reclaimable Docker space.")
                    quickPromptButton("Docker Fleet Audit", "Exited, restarting & unhealthy containers", "shippingbox",
                                      "Check Docker containers across my servers and highlight any exited, restarting, or unhealthy containers.")
                    quickPromptButton("Security & SSH Baseline", "Open ports, SSH policy & failed logins", "lock.shield",
                                      "Audit open listening ports, SSH authentication policy, and recent failed login attempts across my servers.")
                }
                .frame(maxWidth: 680)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func quickPromptButton(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ icon: String, _ prompt: String) -> some View {
        Button {
            activeSession.send(prompt)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.rxBodyStrong).foregroundStyle(.rxInk)
                    Text(subtitle).font(.rxHelp).foregroundStyle(.rxInkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .rxCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript

    private var transcriptScrollView: some View {
        let session = activeSession
        let lastAssistantID = session.messages.last(where: { $0.role == .assistant })?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { msg in
                        MacChatMessageRow(
                            message: msg,
                            conversationID: activeConversation.id,
                            canMutate: !session.isStreaming,
                            isLastAssistant: msg.id == lastAssistantID,
                            onRetry: { session.retryAfterError() },
                            onRegenerate: { session.regenerateLastReply() },
                            onEdit: {
                                editMessageText = msg.text
                                editingMessage = msg
                            },
                            onFork: {
                                _ = assistant.duplicateConversation(activeConversation.id, upToMessageID: msg.id)
                            },
                            onDelete: {
                                session.deleteMessage(msg.id)
                            }
                        )
                        .id(msg.id)
                    }

                    if session.isStreaming {
                        macStreamingBubble(session)
                            .id("streaming-anchor")
                    }

                    if !activeApprovals.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Approval Required", systemImage: "checkmark.shield.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            ForEach(activeApprovals) { approval in
                                macApprovalCard(approval)
                            }
                        }
                        .id("approval-anchor")
                    }

                    Color.clear
                        .frame(height: 20)
                        .id("bottom-anchor")
                }
                .padding(18)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.streamText.count) {
                _, _ in if session.isStreaming {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: activeApprovals.count) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }

    private func macStreamingBubble(_ session: ConversationSession) -> some View {
        let isThinking = session.streamText.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let toolStatus = session.activeToolStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    MacShimmerThinkingText(text: toolStatus, isThinking: true)
                }
            }
            if !session.streamReasoning.isEmpty {
                MacReasoningBox(text: session.streamReasoning, defaultExpanded: isThinking, isThinking: isThinking)
            }
            if session.streamText.isEmpty {
                if session.activeToolStatus == nil, session.streamReasoning.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        MacShimmerThinkingText(text: String(localized: "Thinking…"), isThinking: true)
                    }
                }
            } else {
                AssistantMarkdownView(text: session.streamText)
            }
        }
        .padding(14)
        .rxCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macApprovalCard(_ approval: AssistantAgentBridge.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.request.title)
                .font(.rxBodyStrong)
            if !approval.request.hosts.isEmpty {
                Text(approval.request.hosts.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.rxInkSecondary)
            }
            if !approval.request.detail.isEmpty {
                Text(approval.request.detail)
                    .font(.caption.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Button("Approve") { bridge.resolve(approval.id, approved: true) }
                    .buttonStyle(.rxPrimary)
                Button("Allow 1 Hour") { bridge.resolve(approval.id, approved: true, allowForOneHour: true) }
                    .buttonStyle(.rx)
                Button("Deny", role: .destructive) { bridge.resolve(approval.id, approved: false) }
                    .buttonStyle(.rx)
            }
        }
        .padding(12)
        .rxCard()
    }

    // MARK: - FlowDown Unified Composer

    private var flowDownComposer: some View {
        let session = activeSession
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !session.isStreaming && !isPreparingImages && (!trimmed.isEmpty || !pendingImages.isEmpty)
        let room = AssistantImageProcessor.maxImagesPerMessage - pendingImages.count

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingImages) { draft in
                                MacPendingImageChip(
                                    draft: draft,
                                    onRemove: {
                                        pendingImages.removeAll { $0.id == draft.id }
                                    },
                                    onPreview: {
                                        previewingImage = draft
                                    }
                                )
                            }
                        }
                    }
                }

                TextField("Ask to check metrics, run batch commands, or manage servers…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(2 ... 6)
                    .focused($composerFocused)
                    .frame(minHeight: 40, alignment: .topLeading)
                    .onSubmit { sendCurrentInput() }
                    .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in
                        pasteImage()
                    }

                if let imageError {
                    Text(imageError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Menu {
                            Button("Choose Image…") { chooseImages() }
                            Button("Paste Image") { pasteImage() }
                        } label: {
                            Image(systemName: "paperclip")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(canAttachImages ? Color.secondary : Color.secondary.opacity(0.4))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!canAttachImages || isPreparingImages || room <= 0)
                        .help(canAttachImages ? Text("Attach Image") : Text("Images need a remote AI provider."))

                        if isPreparingImages {
                            ProgressView().controlSize(.mini)
                        }

                        if !pendingImages.isEmpty {
                            Text("\(pendingImages.count)/\(AssistantImageProcessor.maxImagesPerMessage)")
                                .font(.caption2)
                                .foregroundStyle(.rxInkSecondary)
                        }

                        Text(String(localized: "\(assistant.resolvedScopedMachines(for: activeConversation.id).count) servers in scope"))
                            .font(.caption)
                            .foregroundStyle(.rxInkSecondary)

                        if session.didPruneContext {
                            Text("· Context trimmed")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(height: 30)

                    Spacer()

                    Button {
                        if session.isStreaming {
                            session.stopGenerating()
                        } else if canSend {
                            sendCurrentInput()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(session.isStreaming ? Color.red : (canSend ? Color.accentColor : Color.primary.opacity(0.08)))
                                .frame(width: 30, height: 30)
                            if session.isStreaming {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Color.white)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.isStreaming && !canSend)
                }
                .frame(height: 30)
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .rxCard(padding: 0)
            .frame(maxWidth: 820)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func sendCurrentInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty, !activeSession.isStreaming, !isPreparingImages else { return }
        let images = pendingImages
        inputText = ""
        assistant.draftText = ""
        pendingImages = []
        imageError = nil
        activeSession.send(trimmed, attachments: images)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importImages(from: panel.urls)
    }

    private func importImages(from urls: [URL]) {
        let room = AssistantImageProcessor.maxImagesPerMessage - pendingImages.count
        guard room > 0 else {
            imageError = String(localized: "At most \(AssistantImageProcessor.maxImagesPerMessage) images per message.")
            return
        }
        let selected = Array(urls.prefix(room))
        let overflow = urls.count > room
        isPreparingImages = true
        imageError = nil

        Task {
            var drafts: [AssistantAttachmentDraft] = []
            var failure: String?
            for url in selected {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let draft = try await Task.detached(priority: .userInitiated) {
                        try AssistantImageProcessor.prepare(contentsOf: url)
                    }.value
                    drafts.append(draft)
                } catch {
                    failure = error.localizedDescription
                }
            }
            pendingImages.append(contentsOf: drafts)
            isPreparingImages = false
            if let failure {
                imageError = failure
            } else if overflow {
                imageError = String(localized: "At most \(AssistantImageProcessor.maxImagesPerMessage) images per message.")
            }
        }
    }

    private func pasteImage() {
        guard canAttachImages else {
            imageError = String(localized: "Images need a remote AI provider.")
            return
        }
        guard let draft = AssistantImageProcessor.fromPasteboard() else {
            imageError = String(localized: "The clipboard has no image.")
            return
        }
        guard pendingImages.count < AssistantImageProcessor.maxImagesPerMessage else {
            imageError = String(localized: "At most \(AssistantImageProcessor.maxImagesPerMessage) images per message.")
            return
        }
        pendingImages.append(draft)
        imageError = nil
    }

    /// ⌘V with an image on the clipboard attaches it instead of reaching the
    /// text field, which would drop it. Text pastes normally.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard composerFocused,
                  flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  AssistantImageProcessor.pasteboardHasImage
            else { return event }
            pasteImage()
            return nil
        }
    }
}

// MARK: - Host Scope Multi-Select Popover

private struct MacHostScopePopover: View {
    let machines: [RDMachine]
    @Binding var scope: AssistantTargetScope
    @State private var search = ""

    private var selectedIDs: Set<RDMachine.ID> {
        if case let .hosts(ids) = scope {
            return ids
        }
        return []
    }

    private var filtered: [RDMachine] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return machines }
        return machines.filter {
            $0.name.lowercased().contains(q)
                || $0.remoteAddress.lowercased().contains(q)
                || $0.group.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target Servers").font(.rxBodyStrong)
                Spacer()
                if !selectedIDs.isEmpty {
                    Button("Clear") { scope = .all }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            TextField("Filter servers", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { machine in
                        let checked = selectedIDs.contains(machine.id)
                        Button {
                            var next = selectedIDs
                            if checked {
                                next.remove(machine.id)
                            } else {
                                next.insert(machine.id)
                            }
                            scope = next.isEmpty ? .all : .hosts(next)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(machine.name).font(.subheadline)
                                    Text(machine.remoteAddress).font(.caption2.monospaced()).foregroundStyle(.rxInkSecondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct MacImagePreviewSheet: View {
    let draft: AssistantAttachmentDraft
    let close: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(draft.attachment.fileName)
                    .font(.rxBodyStrong)
                    .lineLimit(1)
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.rxPrimary)
            }
            .padding(16)

            Divider()

            ZStack {
                Color.primary.opacity(0.03)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 320)
        }
        .frame(width: 620, height: 480)
        .onAppear {
            image = NSImage(data: draft.data)
        }
    }
}

// MARK: - Message Row

private struct MacChatMessageRow: View {
    let message: AssistantChatMessage
    let conversationID: UUID
    let canMutate: Bool
    let isLastAssistant: Bool
    let onRetry: () -> Void
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    let onFork: () -> Void
    let onDelete: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.attachments) { attachment in
                                MacMessageImageThumbnail(attachment: attachment, conversationID: conversationID)
                            }
                        }
                        .contextMenu {
                            userContextMenu
                        }
                    }

                    if !message.text.isEmpty {
                        Text(message.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .textSelection(.enabled)
                            .contextMenu {
                                userContextMenu
                            }
                    }

                    HStack(spacing: 6) {
                        miniActionButton("doc.on.doc", help: "Copy") { copyText(message.text) }
                        miniActionButton("pencil", help: "Edit & Resend", action: onEdit)
                            .disabled(!canMutate)
                        miniActionButton("tuningfork", help: "Fork Conversation Here", action: onFork)
                            .disabled(!canMutate)
                        miniActionButton("trash", help: "Delete", action: onDelete)
                            .disabled(!canMutate)
                    }
                }
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty {
                    MacReasoningBox(text: message.reasoning, defaultExpanded: false, isThinking: false)
                }
                AssistantMarkdownView(text: message.text)

                HStack(spacing: 8) {
                    if let label = message.modelLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.rxInkTertiary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        miniActionButton("doc.on.doc", help: "Copy") { copyText(message.text) }
                        if isLastAssistant {
                            miniActionButton("arrow.clockwise", help: "Regenerate", action: onRegenerate)
                                .disabled(!canMutate)
                        }
                        miniActionButton("tuningfork", help: "Fork Conversation Here", action: onFork)
                            .disabled(!canMutate)
                        miniActionButton("trash", help: "Delete", action: onDelete)
                            .disabled(!canMutate)
                    }
                }
            }
            .padding(14)
            .rxCard()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button { copyText(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                if canMutate, isLastAssistant {
                    Button(action: onRegenerate) { Label("Regenerate", systemImage: "arrow.clockwise") }
                }
                if canMutate {
                    Button(action: onFork) { Label("Fork Conversation Here", systemImage: "tuningfork") }
                    Divider()
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                }
            }

        case .toolCall:
            if let exec = message.toolExecution {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        if !exec.targetHosts.isEmpty {
                            Text("Targets: \(exec.targetHosts.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.rxInkSecondary)
                        }
                        Text(exec.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: exec.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(exec.isError ? .red : .green)
                        Text(message.text).font(.caption.weight(.medium))
                        if !exec.targetHosts.isEmpty {
                            Text("· \(exec.targetHosts.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.rxInkSecondary)
                        }
                        Spacer()
                        Text("\(exec.durationMs) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.rxInkTertiary)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

        case .notice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.rxInkSecondary)
                .frame(maxWidth: .infinity)

        case .error:
            VStack(alignment: .leading, spacing: 8) {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                if canMutate {
                    HStack(spacing: 8) {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.rx)
                        Button("Delete", role: .destructive, action: onDelete)
                            .buttonStyle(.rx)
                    }
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var userContextMenu: some View {
        Button { copyText(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
        if canMutate {
            Button(action: onEdit) { Label("Edit & Resend…", systemImage: "pencil") }
            Button(action: onFork) { Label("Fork Conversation Here", systemImage: "tuningfork") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }

    private func miniActionButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Shimmer & Reasoning Box

private struct MacShimmerThinkingText: View {
    let text: String
    let isThinking: Bool
    @State private var offset: CGFloat = -0.6

    var body: some View {
        let base = Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isThinking ? Color.primary.opacity(0.75) : Color.secondary)
        if isThinking {
            base.overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(36, geo.size.width * 0.55))
                        .offset(x: offset * (geo.size.width + 48))
                }
                .mask(base)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) { offset = 1.2 }
            }
        } else {
            base
        }
    }
}

private struct MacReasoningBox: View {
    let text: String
    let isThinking: Bool
    @State private var expanded: Bool
    @State private var userToggled = false

    init(text: String, defaultExpanded: Bool, isThinking: Bool) {
        self.text = text
        self.isThinking = isThinking
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                userToggled = true
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isThinking ? "sparkles" : "brain")
                        .font(.caption2)
                        .foregroundStyle(isThinking ? Color.accentColor : .secondary)
                    MacShimmerThinkingText(
                        text: isThinking ? String(localized: "Thinking…") : String(localized: "Thinking Process"),
                        isThinking: isThinking
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(Color.accentColor.opacity(0.45)).frame(width: 2)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: isThinking) { _, thinking in
            if !thinking, !userToggled {
                withAnimation(.snappy(duration: 0.22)) { expanded = false }
            }
        }
    }
}

// MARK: - AI Providers & Preferences Sheet (Full Parity)

private struct MacAIProviderSettingsSheet: View {
    @Bindable var store: AIProviderStore
    @Bindable var assistant: ServerAssistant
    let close: () -> Void

    @State private var editingID: String?
    @State private var kind: AIProviderKind = .openAI
    @State private var name = ""
    @State private var baseURL = ""
    @State private var appendV1Suffix = true
    @State private var model = ""
    @State private var apiKey = ""
    @State private var discoveredModels: [String] = []
    @State private var isTesting = false
    @State private var isFetchingModels = false
    @State private var testResult: AIProviderTestResult?
    @State private var fetchError: String?

    private var appleStatus: AppleIntelligenceStatus {
        .current
    }

    private var pccStatus: ApplePrivateCloudComputeStatus {
        .current
    }

    private var draftConfig: AIProviderConfig {
        AIProviderConfig(
            id: editingID ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.displayName : name,
            kind: kind,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.defaultBaseURL : baseURL,
            appendV1Suffix: appendV1Suffix,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.defaultModel : model,
            availableModels: discoveredModels.isEmpty ? kind.recommendedModels : discoveredModels
        )
    }

    var body: some View {
        SheetScaffold("AI Providers") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Apple Intelligence section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Apple Intelligence").font(.rxBodyStrong)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Intelligence (On-Device)").font(.subheadline.weight(.medium))
                                Text(appleStatus.localizedDescription).font(.caption).foregroundStyle(.rxInkSecondary)
                            }
                            Spacer()
                            Button(store.activeSelection == .appleIntelligence ? "Active" : "Use") {
                                store.selectActive(.appleIntelligence)
                            }
                            .buttonStyle(.rx)
                            .disabled(appleStatus != .available)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Intelligence (PCC)").font(.subheadline.weight(.medium))
                                Text(pccStatus.localizedDescription).font(.caption).foregroundStyle(.rxInkSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $store.privateCloudComputeEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                            Button(store.activeSelection == .applePrivateCloudCompute ? "Active" : "Use") {
                                store.selectActive(.applePrivateCloudCompute)
                            }
                            .buttonStyle(.rx)
                            .disabled(pccStatus != .available || !store.privateCloudComputeEnabled)
                        }
                    }
                    .padding(12)
                    .rxCard()

                    // Configured providers list
                    if !store.providers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configured Providers").font(.rxBodyStrong)
                            ForEach(store.providers) { provider in
                                let isActive = store.activeSelection == .custom(providerId: provider.id)
                                HStack(spacing: 10) {
                                    Image(systemName: provider.kind.systemImage)
                                        .foregroundStyle(provider.kind.tintColor)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(provider.name).font(.subheadline.weight(.medium))
                                            if isActive {
                                                Text("Active")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        Text("\(provider.model) · \(provider.resolvedBaseURL)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.rxInkSecondary)
                                    }
                                    Spacer()
                                    Button("Edit") { loadForEditing(provider) }
                                        .buttonStyle(.rx)
                                    Button("Use") { store.selectActive(.custom(providerId: provider.id)) }
                                        .buttonStyle(.rx)
                                        .disabled(isActive)
                                    Button("Delete", role: .destructive) {
                                        if editingID == provider.id {
                                            resetForm()
                                        }
                                        store.deleteProvider(id: provider.id)
                                    }
                                    .buttonStyle(.rx)
                                }
                                if provider.id != store.providers.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(12)
                        .rxCard()
                    }

                    // Add / Edit Remote Provider form
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(editingID == nil ? "Add Remote Provider" : "Edit Remote Provider")
                                .font(.rxBodyStrong)
                            Spacer()
                            if editingID != nil {
                                Button("Cancel Edit") { resetForm() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }

                        Picker("Provider", selection: $kind) {
                            ForEach(AIProviderKind.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .onChange(of: kind) { _, next in
                            if editingID == nil {
                                name = next.displayName
                                baseURL = next.defaultBaseURL
                                appendV1Suffix = next.defaultAppendV1Suffix
                                model = next.defaultModel
                                discoveredModels = next.recommendedModels
                                testResult = nil
                                fetchError = nil
                            }
                        }

                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                        Toggle("Automatically append /v1 suffix", isOn: $appendV1Suffix)
                            .font(.caption)

                        HStack(spacing: 8) {
                            TextField("Model", text: $model).textFieldStyle(.roundedBorder)
                            let choices = Array(Set(discoveredModels + kind.recommendedModels)).sorted()
                            if !choices.isEmpty {
                                Menu("Presets") {
                                    ForEach(choices, id: \.self) { m in
                                        Button(m) { model = m }
                                    }
                                }
                                .fixedSize()
                            }
                            Button {
                                fetchModels()
                            } label: {
                                if isFetchingModels {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text("Fetch Models")
                                }
                            }
                            .buttonStyle(.rx)
                            .disabled(isFetchingModels)
                        }

                        SecureField(kind.requiresAPIKey ? "API Key" : "API Key (Optional)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        if let result = testResult {
                            HStack(spacing: 6) {
                                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.succeeded ? .green : .red)
                                Text(result.succeeded ? "\(result.message) (\(result.latencyMs) ms)" : result.message)
                                    .font(.caption)
                                    .foregroundStyle(result.succeeded ? .green : .red)
                            }
                        }
                        if let fetchError {
                            Text(fetchError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        HStack(spacing: 8) {
                            Button {
                                runConnectionTest()
                            } label: {
                                if isTesting {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text("Test Connection")
                                }
                            }
                            .buttonStyle(.rx)
                            .disabled(isTesting)

                            Spacer()

                            Button(editingID == nil ? "Add Provider" : "Save Changes") {
                                saveProvider()
                            }
                            .buttonStyle(.rxPrimary)
                        }
                    }
                    .padding(12)
                    .rxCard()

                    // Memory & Context Budget preferences
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Assistant Preferences").font(.rxBodyStrong)
                        Toggle("Cross-Session Memory (inject recent chat summaries)", isOn: $assistant.crossSessionMemoryEnabled)
                            .font(.subheadline)
                        HStack {
                            Text("Context Token Budget").font(.subheadline)
                            Spacer()
                            Picker("", selection: $assistant.contextTokenBudget) {
                                Text("32K").tag(32000)
                                Text("64K").tag(64000)
                                Text("128K").tag(128_000)
                                Text("200K").tag(200_000)
                                Text("256K").tag(256_000)
                                Text("512K").tag(512_000)
                                Text("1M").tag(1_000_000)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                    .padding(12)
                    .rxCard()
                }
                .padding()
            }
            .frame(width: 580, height: 580)
            .onAppear {
                if baseURL.isEmpty {
                    name = kind.displayName
                    baseURL = kind.defaultBaseURL
                    appendV1Suffix = kind.defaultAppendV1Suffix
                    model = kind.defaultModel
                    discoveredModels = kind.recommendedModels
                }
            }
        } footer: {
            Spacer()
            Button("Done", action: close).buttonStyle(.rxPrimary)
        }
    }

    private func loadForEditing(_ provider: AIProviderConfig) {
        editingID = provider.id
        kind = provider.kind
        name = provider.name
        baseURL = provider.baseURL
        appendV1Suffix = provider.appendV1Suffix
        model = provider.model
        discoveredModels = provider.availableModels
        apiKey = store.apiKey(for: provider.id) ?? ""
        testResult = nil
        fetchError = nil
    }

    private func resetForm() {
        editingID = nil
        kind = .openAI
        name = kind.displayName
        baseURL = kind.defaultBaseURL
        appendV1Suffix = kind.defaultAppendV1Suffix
        model = kind.defaultModel
        apiKey = ""
        discoveredModels = kind.recommendedModels
        testResult = nil
        fetchError = nil
    }

    private func saveProvider() {
        let cfg = draftConfig
        if editingID != nil {
            try? store.updateProvider(cfg, apiKey: apiKey)
        } else {
            try? store.addProvider(cfg, apiKey: apiKey, makeActive: true)
        }
        resetForm()
    }

    private func runConnectionTest() {
        isTesting = true
        testResult = nil
        fetchError = nil
        let cfg = draftConfig
        let key = apiKey
        Task {
            let result = await store.testConnection(for: cfg, apiKeyOverride: key.isEmpty ? nil : key)
            testResult = result
            if !result.discoveredModels.isEmpty {
                discoveredModels = result.discoveredModels
            }
            isTesting = false
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        fetchError = nil
        let cfg = draftConfig
        let key = apiKey
        Task {
            do {
                let models = try await store.fetchModels(for: cfg, apiKeyOverride: key.isEmpty ? nil : key)
                if !models.isEmpty {
                    discoveredModels = models
                    if model.isEmpty {
                        model = models[0]
                    }
                }
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }
}

// MARK: - Ops Skills Sheet (Full Parity with File & URL Import)

private struct MacOpsSkillsSheet: View {
    @Bindable var store: ServerOpsSkillStore
    let assistant: ServerAssistant
    let close: () -> Void

    @State private var search = ""
    @State private var selectedCategory: ServerOpsSkillCategory?
    @State private var importURL = ""
    @State private var isImportingURL = false
    @State private var importStatus: String?

    private var filteredSkills: [ServerOpsSkill] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.skills.filter { skill in
            if let cat = selectedCategory, skill.category != cat {
                return false
            }
            if q.isEmpty {
                return true
            }
            return skill.name.lowercased().contains(q)
                || skill.description.lowercased().contains(q)
        }
    }

    var body: some View {
        SheetScaffold("Ops Skills") {
            VStack(spacing: 0) {
                // Import bar (File + URL)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Import SKILL.md from GitHub or raw URL…", text: $importURL)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            importFromURL()
                        } label: {
                            if isImportingURL {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Import URL")
                            }
                        }
                        .buttonStyle(.rx)
                        .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingURL)

                        Button("Import File…") {
                            importFromFile()
                        }
                        .buttonStyle(.rx)
                    }

                    if let importStatus {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.rxInkSecondary)
                    }

                    HStack(spacing: 8) {
                        TextField("Search skills", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Picker("Category", selection: $selectedCategory) {
                            Text("All Categories").tag(ServerOpsSkillCategory?.none)
                            ForEach(ServerOpsSkillCategory.allCases) { cat in
                                Text(cat.displayName).tag(ServerOpsSkillCategory?.some(cat))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredSkills) { skill in
                            let isPinned = assistant.pinnedSkillIDs.contains(skill.id)
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { skill.isEnabled },
                                    set: { _ in store.toggleEnabled(id: skill.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Image(systemName: skill.category.systemImage)
                                            .font(.caption)
                                            .foregroundStyle(Color.accentColor)
                                        Text(skill.name).font(.subheadline.weight(.medium))
                                        if !skill.isBuiltIn {
                                            Text("Custom")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.purple.opacity(0.14), in: Capsule())
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    Text(skill.description)
                                        .font(.caption)
                                        .foregroundStyle(.rxInkSecondary)
                                }

                                Spacer()

                                Button {
                                    assistant.togglePinnedSkill(skill.id)
                                } label: {
                                    Image(systemName: isPinned ? "pin.fill" : "pin")
                                        .foregroundStyle(isPinned ? .orange : .secondary)
                                }
                                .buttonStyle(.rx)
                                .help(isPinned ? "Unpin from chat" : "Pin to current chat")

                                Button("Run") {
                                    assistant.activeSession.send(skill.effectiveRunPrompt)
                                    close()
                                }
                                .buttonStyle(.rx)

                                if !skill.isBuiltIn {
                                    Button(role: .destructive) {
                                        store.deleteSkill(id: skill.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.rx)
                                }
                            }
                            .padding(10)
                            .rxCard()
                        }
                    }
                    .padding(16)
                }
            }
            .frame(width: 640, height: 540)
        } footer: {
            Spacer()
            Button("Done", action: close).buttonStyle(.rxPrimary)
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let skill = store.importFromMarkdown(text, sourceURL: url.lastPathComponent)
            importStatus = String(localized: "Imported skill \"\(skill.name)\".")
        } catch {
            importStatus = error.localizedDescription
        }
    }

    private func importFromURL() {
        let raw = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isImportingURL = true
        importStatus = nil
        Task {
            do {
                let skill = try await store.importFromURL(raw)
                importURL = ""
                importStatus = String(localized: "Imported skill \"\(skill.name)\".")
            } catch {
                importStatus = error.localizedDescription
            }
            isImportingURL = false
        }
    }
}

// MARK: - Image Views

private struct MacPendingImageChip: View {
    let draft: AssistantAttachmentDraft
    let onRemove: () -> Void
    let onPreview: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onPreview) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Preview Image"))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove Image")
        }
        .help(Text(draft.attachment.fileName))
        .task(id: draft.id) {
            image = NSImage(data: draft.data)
        }
    }
}

private struct MacMessageImageThumbnail: View {
    let attachment: AssistantAttachment
    let conversationID: UUID

    @State private var image: NSImage?

    private var url: URL {
        AssistantConversationDiskStore.shared.attachmentURL(for: attachment, conversationID: conversationID)
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.primary.opacity(0.06)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 108, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text(attachment.fileName))
        .task(id: attachment.id) {
            guard image == nil else { return }
            let attachment = attachment
            let conversationID = conversationID
            let data = await Task.detached(priority: .userInitiated) {
                let url = AssistantConversationDiskStore.shared.attachmentURL(
                    for: attachment,
                    conversationID: conversationID
                )
                return try? Data(contentsOf: url)
            }.value
            if let data {
                image = NSImage(data: data)
            }
        }
    }
}

// MARK: - Markdown Renderer

/// Draws the assistant's Markdown with native SwiftUI: headings, paragraphs,
/// lists, quotes, fenced code and pipe tables, with inline bold, italic, code
/// and links. The assistant is told to answer in Markdown, so a plain `Text`
/// showed the markers instead of the formatting.
private struct AssistantMarkdownView: View {
    let text: String

    private enum Block: Identifiable {
        case text(Int, String)
        case code(Int, language: String, content: String)
        case table(Int, headers: [String], rows: [[String]])

        var id: Int {
            switch self {
            case let .text(index, _), let .code(index, _, _), let .table(index, _, _): index
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseBlocks(text)) { block in
                switch block {
                case let .text(_, content):
                    textBlock(content)
                case let .code(_, language, code):
                    codeBlock(language: language, code: code)
                case let .table(_, headers, rows):
                    table(headers: headers, rows: rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Text

    private func textBlock(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(raw.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Color.clear.frame(height: 4)
                } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    Divider()
                } else if trimmed.hasPrefix("### ") {
                    markdownSpan(String(trimmed.dropFirst(4)))
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                } else if trimmed.hasPrefix("## ") {
                    markdownSpan(String(trimmed.dropFirst(3)))
                        .font(.headline)
                        .padding(.top, 3)
                } else if trimmed.hasPrefix("# ") {
                    markdownSpan(String(trimmed.dropFirst(2)))
                        .font(.headline.weight(.bold))
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        markdownSpan(String(trimmed.dropFirst(2)))
                    }
                } else if let ordered = orderedItem(trimmed) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered.number + ".").foregroundStyle(.secondary)
                        markdownSpan(ordered.content)
                    }
                } else if trimmed.hasPrefix("> ") {
                    HStack(alignment: .top, spacing: 8) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: 2)
                        markdownSpan(String(trimmed.dropFirst(2)))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    markdownSpan(trimmed)
                }
            }
        }
    }

    private func orderedItem(_ line: String) -> (number: String, content: String)? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasSuffix("."),
              parts[0].dropLast().allSatisfy(\.isNumber)
        else { return nil }
        return (String(parts[0].dropLast()), String(parts[1]))
    }

    private func markdownSpan(_ content: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(content)
    }

    // MARK: Code & Tables

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "shell" : language)
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        markdownSpan(header)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0 ..< headers.count, id: \.self) { column in
                            markdownSpan(column < row.count ? row[column] : "")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Parsing

    private func parseBlocks(_ input: String) -> [Block] {
        var blocks: [Block] = []
        var textLines: [String] = []
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushText() {
            let joined = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.text(blocks.count, joined))
            }
            textLines.removeAll()
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushText()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(blocks.count, language: language, content: codeLines.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if next.contains("|"), next.contains("-") {
                    let headers = splitTableRow(trimmed)
                    if !headers.isEmpty {
                        flushText()
                        var rows: [[String]] = []
                        index += 2
                        while index < lines.count {
                            let row = lines[index].trimmingCharacters(in: .whitespaces)
                            guard row.contains("|") else { break }
                            rows.append(splitTableRow(row))
                            index += 1
                        }
                        blocks.append(.table(blocks.count, headers: headers, rows: rows))
                        continue
                    }
                }
            }

            textLines.append(lines[index])
            index += 1
        }
        flushText()
        return blocks
    }

    private func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
