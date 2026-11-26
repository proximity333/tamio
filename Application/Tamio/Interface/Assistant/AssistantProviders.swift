//
//  AssistantProviders.swift
//  Tamio (macOS)
//
//  Multi-provider AI configuration and Keychain-backed credential store.
//  Supports on-device Apple Intelligence (macOS 26+ FoundationModels) as well as
//  OpenAI-compatible and Anthropic Messages remote providers.
//

import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif
import Keychain
import Observation
import SwiftUI

// MARK: - Apple Intelligence Availability

enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    case requiresNewerOS
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unavailable

    static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case let .unavailable(reason):
                    switch reason {
                    case .deviceNotEligible:
                        return .deviceNotEligible
                    case .appleIntelligenceNotEnabled:
                        return .notEnabled
                    case .modelNotReady:
                        return .modelNotReady
                    @unknown default:
                        return .unavailable
                    }
                }
            }
        #endif
        return .requiresNewerOS
    }

    var localizedDescription: String {
        switch self {
        case .available:
            String(localized: "Runs on device with no API key required.")
        case .requiresNewerOS:
            String(localized: "Requires macOS 26 or later. Configure a remote AI provider instead.")
        case .deviceNotEligible:
            String(localized: "This device does not support Apple Intelligence. Configure a remote AI provider instead.")
        case .notEnabled:
            String(localized: "Enable Apple Intelligence in Settings, or configure a remote AI provider.")
        case .modelNotReady:
            String(localized: "Apple Intelligence model is downloading. You can also configure a remote AI provider.")
        case .unavailable:
            String(localized: "Apple Intelligence is currently unavailable. Configure a remote AI provider instead.")
        }
    }
}

// MARK: - Apple Intelligence Private Cloud Compute Availability (macOS 27+)

private enum PrivateCloudComputeEntitlement {
    static let key = "com.apple.developer.private-cloud-compute"

    /// Checks the app's signed `embedded.provisionprofile` before touching
    /// `PrivateCloudComputeLanguageModel`, because FoundationModels raises a
    /// fatal error on macOS 27 if the managed entitlement is missing.
    static let isGranted: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>")
        else {
            return false
        }
        let xmlString = String(text[start.lowerBound ..< end.upperBound])
        guard let plistData = xmlString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return false
        }
        return (entitlements[key] as? Bool) == true
    }()
}

enum ApplePrivateCloudComputeStatus: Equatable, Sendable {
    case available
    case missingEntitlement
    case requiresNewerOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case systemNotReady
    case unavailable

    static var current: ApplePrivateCloudComputeStatus {
        #if canImport(FoundationModels) && compiler(>=6.4)
            if #available(macOS 27.0, *) {
                guard PrivateCloudComputeEntitlement.isGranted else {
                    return .missingEntitlement
                }
                switch PrivateCloudComputeLanguageModel().availability {
                case .available:
                    return .available
                case let .unavailable(reason):
                    switch reason {
                    case .deviceNotEligible:
                        return .deviceNotEligible
                    case .systemNotReady:
                        if SystemLanguageModel.default.availability == .unavailable(.appleIntelligenceNotEnabled) {
                            return .appleIntelligenceNotEnabled
                        }
                        return .systemNotReady
                    @unknown default:
                        return .unavailable
                    }
                }
            }
        #endif
        return .requiresNewerOS
    }

    var isEligibleHardwareAndOS: Bool {
        switch self {
        case .requiresNewerOS, .deviceNotEligible, .missingEntitlement:
            false
        default:
            true
        }
    }

    var localizedDescription: String {
        switch self {
        case .available:
            String(localized: "Runs on Apple's Private Cloud Compute with end-to-end privacy and no API key required.")
        case .missingEntitlement:
            String(localized: "This build is signed without Apple's managed Private Cloud Compute entitlement.")
        case .requiresNewerOS:
            String(localized: "Requires macOS 27 or later with Private Cloud Compute entitlement.")
        case .deviceNotEligible:
            String(localized: "This device does not support Apple Intelligence Private Cloud Compute.")
        case .appleIntelligenceNotEnabled:
            String(localized: "Turn on Apple Intelligence in System Settings to use Private Cloud Compute.")
        case .systemNotReady:
            String(localized: "Private Cloud Compute is not ready yet. Check your network, iCloud sign-in, or app entitlement.")
        case .unavailable:
            String(localized: "Apple Intelligence Private Cloud Compute is currently unavailable.")
        }
    }
}

// MARK: - Wire Format

nonisolated enum AIWireFormat: String, Codable, Hashable, Sendable {
    case openAIChatCompletions
    case anthropicMessages
}

// MARK: - Provider Kind

nonisolated enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case openRouter
    case magpie
    case xAI
    case ollama
    case openAICompatible
    case anthropicCompatible

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .magpie: "Magpie"
        case .xAI: "xAI Grok"
        case .ollama: String(localized: "Ollama (Local)")
        case .openAICompatible: String(localized: "OpenAI Compatible")
        case .anthropicCompatible: String(localized: "Anthropic Compatible")
        }
    }

    var shortDescription: String {
        switch self {
        case .openAI: "GPT-4.1 · o4-mini"
        case .anthropic: "Claude Sonnet · Haiku"
        case .gemini: "Gemini 2.5 Flash / Pro"
        case .deepSeek: "DeepSeek Chat / Reasoner"
        case .openRouter: String(localized: "Multi-model router")
        case .magpie: String(localized: "Local AI gateway")
        case .xAI: "Grok 3"
        case .ollama: String(localized: "LAN / self-hosted")
        case .openAICompatible: String(localized: "Custom /v1 endpoint")
        case .anthropicCompatible: String(localized: "Custom Messages API")
        }
    }

    var systemImage: String {
        switch self {
        case .openAI: "sparkles"
        case .anthropic: "brain.head.profile"
        case .gemini: "wand.and.stars"
        case .deepSeek: "magnifyingglass.circle"
        case .openRouter: "network"
        case .magpie: "bird"
        case .xAI: "bolt.circle"
        case .ollama: "desktopcomputer"
        case .openAICompatible: "server.rack"
        case .anthropicCompatible: "slider.horizontal.3"
        }
    }

    var tintColor: Color {
        switch self {
        case .openAI: .green
        case .anthropic: .orange
        case .gemini: .blue
        case .deepSeek: .indigo
        case .openRouter: .purple
        case .magpie: .teal
        case .xAI: .primary
        case .ollama: .secondary
        case .openAICompatible: .cyan
        case .anthropicCompatible: .pink
        }
    }

    var protocolBadgeText: String {
        switch wireFormat {
        case .openAIChatCompletions: "OpenAI API"
        case .anthropicMessages: "Anthropic API"
        }
    }

    var wireFormat: AIWireFormat {
        switch self {
        case .anthropic, .anthropicCompatible:
            .anthropicMessages
        case .openAI, .gemini, .deepSeek, .openRouter, .magpie, .xAI, .ollama, .openAICompatible:
            .openAIChatCompletions
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .magpie: "http://127.0.0.1:3425/v1"
        case .xAI: "https://api.x.ai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .openAICompatible: "https://api.openai.com/v1"
        case .anthropicCompatible: "https://api.anthropic.com/v1"
        }
    }

    var defaultAppendV1Suffix: Bool {
        switch self {
        case .gemini, .openRouter:
            false
        default:
            true
        }
    }

    var requiresAPIKey: Bool {
        self != .ollama && self != .magpie
    }

    /// Whether the provider's chat endpoint and the usual models on it take
    /// images. Custom endpoints are left on and surface their own error, since
    /// a proxy can front any vision model.
    var supportsImages: Bool {
        switch self {
        case .deepSeek: false
        default: true
        }
    }

    var defaultAuthToken: String? {
        switch self {
        case .magpie:
            "magpie-tamio"
        default:
            nil
        }
    }

    var recommendedModels: [String] {
        switch self {
        case .openAI:
            ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o", "o4-mini"]
        case .anthropic:
            ["claude-sonnet-4-20250514", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .gemini:
            ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .deepSeek:
            ["deepseek-chat", "deepseek-reasoner"]
        case .openRouter:
            ["anthropic/claude-sonnet-4", "openai/gpt-4.1-mini", "google/gemini-2.5-flash", "deepseek/deepseek-chat-v3-0324"]
        case .magpie:
            ["anthropic/claude-sonnet-4-6", "openai/gpt-5.4", "google/gemini-2.5-pro", "deepseek/deepseek-chat"]
        case .xAI:
            ["grok-3-mini", "grok-3", "grok-2-latest"]
        case .ollama:
            ["qwen2.5:14b", "llama3.3", "deepseek-r1:14b", "mistral"]
        case .openAICompatible:
            ["gpt-4.1-mini", "gpt-4o-mini", "deepseek-chat"]
        case .anthropicCompatible:
            ["claude-sonnet-4-20250514", "claude-3-5-haiku-latest"]
        }
    }

    var defaultModel: String {
        recommendedModels.first ?? ""
    }
}

// MARK: - Custom Provider Icon

nonisolated struct AIProviderCustomIcon: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case brandAsset
        case symbol
    }

    var kind: Kind
    var value: String
    var tintName: String

    init(kind: Kind, value: String, tintName: String = "accent") {
        self.kind = kind
        self.value = value
        self.tintName = tintName
    }
}

// MARK: - Provider Config

nonisolated struct AIProviderConfig: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var kind: AIProviderKind
    var baseURL: String
    var appendV1Suffix: Bool
    var model: String
    var availableModels: [String]
    var customUserAgent: String?
    var customIcon: AIProviderCustomIcon?
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: AIProviderKind,
        baseURL: String? = nil,
        appendV1Suffix: Bool? = nil,
        model: String? = nil,
        availableModels: [String]? = nil,
        customUserAgent: String? = nil,
        customIcon: AIProviderCustomIcon? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.appendV1Suffix = appendV1Suffix ?? kind.defaultAppendV1Suffix
        self.model = model ?? kind.defaultModel
        self.availableModels = availableModels ?? kind.recommendedModels
        self.customUserAgent = customUserAgent
        self.customIcon = customIcon
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    var resolvedBaseURL: String {
        AIURLBuilder.normalizedBaseURL(baseURL, appendV1: appendV1Suffix)
    }

    var mergedModels: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for candidate in [model] + availableModels + kind.recommendedModels {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

// MARK: - Active Selection

nonisolated enum AIActiveSelection: Codable, Equatable, Hashable, Sendable {
    case appleIntelligence
    case applePrivateCloudCompute
    case custom(providerId: String)
}

// MARK: - URL Builder

nonisolated enum AIURLBuilder {
    static func normalizedBaseURL(_ raw: String, appendV1: Bool) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if !trimmed.isEmpty, !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard appendV1, !trimmed.isEmpty else { return trimmed }

        if let url = URL(string: trimmed) {
            let path = url.path.lowercased()
            let alreadyVersioned = path.hasSuffix("/v1")
                || path.hasSuffix("/v1beta")
                || path.hasSuffix("/v1beta/openai")
                || path.hasSuffix("/v2")
                || path.hasSuffix("/v3")
                || path.hasSuffix("/v4")
                || path.hasSuffix("/chat/completions")
                || path.hasSuffix("/messages")
            if !alreadyVersioned {
                return trimmed + "/v1"
            }
        }
        return trimmed
    }

    static func endpointURL(baseURL: String, appendV1: Bool, path: String) -> URL? {
        let base = normalizedBaseURL(baseURL, appendV1: appendV1)
        guard !base.isEmpty else { return nil }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if base.lowercased().hasSuffix("/" + cleanPath.lowercased()) {
            return URL(string: base)
        }
        return URL(string: "\(base)/\(cleanPath)")
    }
}

// MARK: - Connection Test Result

nonisolated struct AIProviderTestResult: Equatable, Sendable {
    let succeeded: Bool
    let latencyMs: Int
    let message: String
    let discoveredModels: [String]
}

// MARK: - Provider Store

@MainActor
@Observable
final class AIProviderStore {
    static let shared = AIProviderStore()

    private static let providersStorageKey = "sb.moe.tamio.ai.providers.v1"
    private static let activeSelectionStorageKey = "sb.moe.tamio.ai.activeSelection.v1"
    private static let pccEnabledStorageKey = "sb.moe.tamio.ai.pccEnabled.v1"
    private static let keychainService = "sb.moe.tamio.ai.apikeys"

    private(set) var providers: [AIProviderConfig] = []
    private(set) var activeSelection: AIActiveSelection = .appleIntelligence
    var privateCloudComputeEnabled: Bool = true {
        didSet {
            defaults.set(privateCloudComputeEnabled, forKey: Self.pccEnabledStorageKey)
        }
    }

    private let defaults: UserDefaults
    private let keychain: Keychain
    private let session: URLSession

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        keychain = Keychain(service: Self.keychainService)
        self.session = session
        if let storedPCC = defaults.object(forKey: Self.pccEnabledStorageKey) as? Bool {
            privateCloudComputeEnabled = storedPCC
        }
        loadFromDisk()
    }

    // MARK: - Queries

    var enabledProviders: [AIProviderConfig] {
        providers.filter(\.isEnabled)
    }

    func provider(id: String) -> AIProviderConfig? {
        providers.first { $0.id == id }
    }

    func effectiveSelection(
        appleIntelligenceAvailable: Bool,
        pccAvailable: Bool = ApplePrivateCloudComputeStatus.current == .available
    ) -> AIActiveSelection {
        let pccUsable = privateCloudComputeEnabled && pccAvailable
        switch activeSelection {
        case let .custom(id):
            if providers.contains(where: { $0.id == id && $0.isEnabled }) {
                return .custom(providerId: id)
            }
            if pccUsable {
                return .applePrivateCloudCompute
            }
            if appleIntelligenceAvailable {
                return .appleIntelligence
            }
            if let fallback = enabledProviders.first {
                return .custom(providerId: fallback.id)
            }
            return .appleIntelligence
        case .applePrivateCloudCompute:
            if pccUsable {
                return .applePrivateCloudCompute
            }
            if appleIntelligenceAvailable {
                return .appleIntelligence
            }
            if let fallback = enabledProviders.first {
                return .custom(providerId: fallback.id)
            }
            return .applePrivateCloudCompute
        case .appleIntelligence:
            if appleIntelligenceAvailable {
                return .appleIntelligence
            }
            if pccUsable {
                return .applePrivateCloudCompute
            }
            if let fallback = enabledProviders.first {
                return .custom(providerId: fallback.id)
            }
            return .appleIntelligence
        }
    }

    func activeDisplayName(appleIntelligenceAvailable: Bool) -> String {
        switch effectiveSelection(appleIntelligenceAvailable: appleIntelligenceAvailable) {
        case .appleIntelligence:
            String(localized: "Apple Intelligence")
        case .applePrivateCloudCompute:
            String(localized: "Apple Intelligence (PCC)")
        case let .custom(id):
            provider(id: id)?.name ?? String(localized: "Custom AI")
        }
    }

    func activeModelSummary(appleIntelligenceAvailable: Bool) -> String {
        switch effectiveSelection(appleIntelligenceAvailable: appleIntelligenceAvailable) {
        case .appleIntelligence:
            String(localized: "On-Device")
        case .applePrivateCloudCompute:
            String(localized: "Private Cloud Compute")
        case let .custom(id):
            provider(id: id)?.model ?? ""
        }
    }

    func apiKey(for providerId: String) -> String? {
        try? keychain.getString(providerId)
    }

    func hasCredential(for config: AIProviderConfig) -> Bool {
        if !config.kind.requiresAPIKey {
            return true
        }
        guard let key = apiKey(for: config.id) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Mutations

    func addProvider(_ config: AIProviderConfig, apiKey: String?, makeActive: Bool = true) throws {
        var clean = config
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.baseURL = clean.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.model = clean.model.trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            try keychain.set(key, key: clean.id)
        }
        providers.append(clean)
        if makeActive {
            activeSelection = .custom(providerId: clean.id)
        }
        persist()
    }

    func updateProvider(_ config: AIProviderConfig, apiKey: String?) throws {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        var clean = config
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.baseURL = clean.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.model = clean.model.trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = apiKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try? keychain.remove(clean.id)
            } else {
                try keychain.set(trimmed, key: clean.id)
            }
        }
        providers[index] = clean
        if !clean.isEnabled, activeSelection == .custom(providerId: clean.id) {
            activeSelection = enabledProviders.first.map { .custom(providerId: $0.id) } ?? .appleIntelligence
        }
        persist()
    }

    func deleteProvider(id: String) {
        providers.removeAll { $0.id == id }
        try? keychain.remove(id)
        if activeSelection == .custom(providerId: id) {
            activeSelection = enabledProviders.first.map { .custom(providerId: $0.id) } ?? .appleIntelligence
        }
        persist()
    }

    func selectActive(_ selection: AIActiveSelection) {
        activeSelection = selection
        persist()
    }

    func setModel(_ model: String, for providerId: String) {
        guard let index = providers.firstIndex(where: { $0.id == providerId }) else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        providers[index].model = trimmed
        if !providers[index].availableModels.contains(trimmed) {
            providers[index].availableModels.insert(trimmed, at: 0)
        }
        persist()
    }

    func importFromBackup(
        providers imported: [AIProviderConfig],
        apiKeys: [String: String],
        activeSelection importedSelection: AIActiveSelection?,
        replaceExisting: Bool
    ) {
        if replaceExisting {
            for existing in providers {
                try? keychain.remove(existing.id)
            }
            providers = imported
        } else {
            for item in imported {
                if let idx = providers.firstIndex(where: { $0.id == item.id }) {
                    providers[idx] = item
                } else {
                    providers.append(item)
                }
            }
        }
        for (providerID, rawKey) in apiKeys {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? keychain.set(trimmed, key: providerID)
            }
        }
        if let importedSelection {
            switch importedSelection {
            case .appleIntelligence:
                if replaceExisting {
                    activeSelection = .appleIntelligence
                }
            case .applePrivateCloudCompute:
                if replaceExisting {
                    activeSelection = .applePrivateCloudCompute
                }
            case let .custom(id):
                if providers.contains(where: { $0.id == id && $0.isEnabled }) {
                    activeSelection = .custom(providerId: id)
                }
            }
        }
        persist()
    }

    // MARK: - Model Discovery & Connection Test

    func fetchModels(for config: AIProviderConfig, apiKeyOverride: String? = nil) async throws -> [String] {
        let effectiveKey = (apiKeyOverride ?? apiKey(for: config.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = AIURLBuilder.endpointURL(
            baseURL: config.baseURL,
            appendV1: config.appendV1Suffix,
            path: "models"
        ) else {
            throw RemoteLLMError.invalidURL(config.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyAuthHeaders(to: &request, config: config, apiKey: effectiveKey)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteLLMError.httpError(statusCode: http.statusCode, message: Self.extractErrorMessage(from: body))
        }

        let models = Self.parseModelIDs(from: data)
        if let idx = providers.firstIndex(where: { $0.id == config.id }), !models.isEmpty {
            providers[idx].availableModels = models
            persist()
        }
        return models
    }

    func testConnection(for config: AIProviderConfig, apiKeyOverride: String? = nil) async -> AIProviderTestResult {
        let start = ContinuousClock.now
        let effectiveKey = (apiKeyOverride ?? apiKey(for: config.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if config.kind.requiresAPIKey, (effectiveKey ?? "").isEmpty {
            return AIProviderTestResult(
                succeeded: false,
                latencyMs: 0,
                message: String(localized: "Please enter an API key first."),
                discoveredModels: []
            )
        }

        do {
            let models = try await fetchModels(for: config, apiKeyOverride: effectiveKey)
            let ms = elapsedMilliseconds(since: start)
            let msg = models.isEmpty
                ? String(localized: "Connected")
                : String(localized: "Connected · \(models.count) models available")
            return AIProviderTestResult(succeeded: true, latencyMs: ms, message: msg, discoveredModels: models)
        } catch {
            // Some Anthropic-compatible relays omit /models; fall back to a minimal Messages ping.
            if config.kind.wireFormat == .anthropicMessages {
                do {
                    try await pingAnthropicEndpoint(config: config, apiKey: effectiveKey)
                    let ms = elapsedMilliseconds(since: start)
                    return AIProviderTestResult(
                        succeeded: true,
                        latencyMs: ms,
                        message: String(localized: "Connected"),
                        discoveredModels: []
                    )
                } catch {
                    return AIProviderTestResult(
                        succeeded: false,
                        latencyMs: elapsedMilliseconds(since: start),
                        message: error.localizedDescription,
                        discoveredModels: []
                    )
                }
            }
            return AIProviderTestResult(
                succeeded: false,
                latencyMs: elapsedMilliseconds(since: start),
                message: error.localizedDescription,
                discoveredModels: []
            )
        }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func pingAnthropicEndpoint(config: AIProviderConfig, apiKey: String?) async throws {
        guard let url = AIURLBuilder.endpointURL(
            baseURL: config.baseURL,
            appendV1: config.appendV1Suffix,
            path: "messages"
        ) else {
            throw RemoteLLMError.invalidURL(config.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, config: config, apiKey: apiKey)

        let body: [String: Any] = [
            "model": config.model.isEmpty ? config.kind.defaultModel : config.model,
            "max_tokens": 8,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RemoteLLMError.httpError(statusCode: http.statusCode, message: Self.extractErrorMessage(from: text))
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, config: AIProviderConfig, apiKey: String?) {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken = (trimmedKey?.isEmpty == false) ? trimmedKey : config.kind.defaultAuthToken

        switch config.kind.wireFormat {
        case .openAIChatCompletions:
            if let token = effectiveToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicMessages:
            if let token = effectiveToken, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let ua = config.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    nonisolated static func parseModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let items = json["data"] as? [[String: Any]] {
            return items.compactMap { $0["id"] as? String }.sorted()
        }
        if let items = json["models"] as? [[String: Any]] {
            return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
        }
        return []
    }

    nonisolated static func extractErrorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let errorObj = json["error"] as? [String: Any],
               let msg = errorObj["message"] as? String, !msg.isEmpty
            {
                return msg
            }
            if let msg = json["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        if let data = defaults.data(forKey: Self.providersStorageKey),
           let decoded = try? JSONDecoder().decode([AIProviderConfig].self, from: data)
        {
            providers = decoded
        }
        if let data = defaults.data(forKey: Self.activeSelectionStorageKey),
           let decoded = try? JSONDecoder().decode(AIActiveSelection.self, from: data)
        {
            activeSelection = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Self.providersStorageKey)
        }
        if let data = try? JSONEncoder().encode(activeSelection) {
            defaults.set(data, forKey: Self.activeSelectionStorageKey)
        }
    }
}
