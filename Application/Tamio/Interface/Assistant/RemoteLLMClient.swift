//
//  RemoteLLMClient.swift
//  Tamio (macOS)
//
//  Streaming SSE client supporting OpenAI Chat Completions and Anthropic
//  Messages APIs with full multi-round JSON Schema tool calling and
//  reasoning/thinking stream separation.
//

import Foundation
import TamioModule

// MARK: - Errors

nonisolated enum RemoteLLMError: LocalizedError, Sendable {
    case invalidURL(String)
    case missingAPIKey(String)
    case missingModel
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return String(localized: "Invalid provider URL: \(url)")
        case let .missingAPIKey(providerName):
            return String(localized: "Missing API key for \(providerName). Configure it in AI Providers.")
        case .missingModel:
            return String(localized: "No model selected. Choose or enter a model in AI Providers.")
        case .invalidResponse:
            return String(localized: "The AI provider returned an unreadable response.")
        case let .httpError(code, message):
            if message.isEmpty {
                return String(localized: "AI request failed (HTTP \(code)).")
            }
            return "HTTP \(code): \(message)"
        case let .decodingError(detail):
            return String(localized: "Failed to decode AI response: \(detail)")
        }
    }
}

// MARK: - Wire Types

nonisolated struct LLMToolCall: Equatable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String

    func decodedJSONValue() -> JSONValue {
        guard let data = argumentsJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return [:]
        }
        return value
    }

    func decodedDictionary() -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return dict
    }
}

/// JSON Schema tool definition convertible directly from Tamio's MCP `JSONValue` definitions.
nonisolated struct LLMToolSchema: Sendable {
    let name: String
    let description: String
    /// Raw JSON bytes of the `inputSchema` object so nested schemas (like `targets`) pass through verbatim.
    let inputSchemaJSON: Data

    init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        inputSchemaJSON = (try? JSONEncoder().encode(inputSchema)) ?? Data("{\"type\":\"object\",\"properties\":{}}".utf8)
    }

    func inputSchemaObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: inputSchemaJSON) as? [String: Any])
            ?? ["type": "object", "properties": [:]]
    }
}

nonisolated struct LLMImageAttachment: Sendable, Equatable {
    let id: UUID
    let mediaType: String
    let data: Data
    let estimatedTokens: Int

    var base64: String {
        data.base64EncodedString()
    }
}

nonisolated enum LLMConversationTurn: Sendable {
    case user(text: String, images: [LLMImageAttachment] = [])
    case assistant(text: String, toolCalls: [LLMToolCall])
    case toolResult(toolCallId: String, name: String, content: String)
}

nonisolated struct LLMResponseTurn: Sendable {
    let text: String
    let reasoning: String
    let toolCalls: [LLMToolCall]
}

// MARK: - Streaming Client

nonisolated struct RemoteLLMClient: Sendable {
    /// Dedicated streaming session that tolerates slow thinking models and brief
    /// Wi-Fi/cellular transitions instead of aborting on URLSession.shared's defaults.
    static let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    init(session: URLSession = RemoteLLMClient.streamingSession) {
        self.session = session
    }

    static func isRetryableError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let llmError = error as? RemoteLLMError {
            switch llmError {
            case let .httpError(code, _):
                return code == 408 || code == 429 || (500 ... 599).contains(code)
            case .invalidResponse:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorSecureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    func streamCompletion(
        config: AIProviderConfig,
        apiKey: String?,
        systemPrompt: String,
        messages: [LLMConversationTurn],
        tools: [LLMToolSchema],
        maxTokens: Int? = nil,
        onReasoningDelta: (@Sendable (String) async -> Void)? = nil,
        onTextDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> LLMResponseTurn {
        let trimmedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw RemoteLLMError.missingModel }

        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.kind.requiresAPIKey, (trimmedKey ?? "").isEmpty {
            throw RemoteLLMError.missingAPIKey(config.name)
        }

        switch config.kind.wireFormat {
        case .openAIChatCompletions:
            return try await streamOpenAI(
                config: config,
                model: trimmedModel,
                apiKey: trimmedKey,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                onReasoningDelta: onReasoningDelta,
                onTextDelta: onTextDelta
            )
        case .anthropicMessages:
            return try await streamAnthropic(
                config: config,
                model: trimmedModel,
                apiKey: trimmedKey,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                onReasoningDelta: onReasoningDelta,
                onTextDelta: onTextDelta
            )
        }
    }

    /// Lightweight helper for background tasks (auto-titling, conversation summary).
    func completeText(
        config: AIProviderConfig,
        apiKey: String?,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 256
    ) async throws -> String {
        let turn = try await streamCompletion(
            config: config,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            messages: [.user(text: userPrompt, images: [])],
            tools: [],
            maxTokens: maxTokens,
            onReasoningDelta: nil,
            onTextDelta: { _ in }
        )
        return turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI Chat Completions (SSE)

    private func streamOpenAI(
        config: AIProviderConfig,
        model: String,
        apiKey: String?,
        systemPrompt: String,
        messages: [LLMConversationTurn],
        tools: [LLMToolSchema],
        maxTokens: Int?,
        onReasoningDelta: (@Sendable (String) async -> Void)?,
        onTextDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> LLMResponseTurn {
        guard let url = AIURLBuilder.endpointURL(
            baseURL: config.baseURL,
            appendV1: config.appendV1Suffix,
            path: "chat/completions"
        ) else {
            throw RemoteLLMError.invalidURL(config.baseURL)
        }

        var wireMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for turn in messages {
            switch turn {
            case let .user(text, images):
                if images.isEmpty {
                    wireMessages.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = []
                    if !text.isEmpty {
                        parts.append(["type": "text", "text": text])
                    }
                    for image in images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64)"],
                        ])
                    }
                    wireMessages.append(["role": "user", "content": parts])
                }
            case let .assistant(text, toolCalls):
                var dict: [String: Any] = ["role": "assistant"]
                if !text.isEmpty {
                    dict["content"] = text
                } else if toolCalls.isEmpty {
                    dict["content"] = ""
                }
                if !toolCalls.isEmpty {
                    dict["tool_calls"] = toolCalls.map { call -> [String: Any] in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.argumentsJSON,
                            ],
                        ]
                    }
                }
                wireMessages.append(dict)
            case let .toolResult(toolCallId, name, content):
                wireMessages.append([
                    "role": "tool",
                    "tool_call_id": toolCallId,
                    "name": name,
                    "content": content,
                ])
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "stream": true,
        ]
        if let maxTokens {
            payload["max_tokens"] = maxTokens
        }
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchemaObject(),
                    ],
                ]
            }
            payload["tool_choice"] = "auto"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let effectiveToken = (apiKey?.isEmpty == false) ? apiKey : config.kind.defaultAuthToken
        if let token = effectiveToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let ua = config.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let errorBody = try await collectBody(from: bytes)
            throw RemoteLLMError.httpError(
                statusCode: http.statusCode,
                message: AIProviderStore.extractErrorMessage(from: errorBody)
            )
        }

        var fullText = ""
        var fullReasoning = ""
        var toolSlots: [Int: (id: String, name: String, args: String)] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let dataStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if dataStr == "[DONE]" {
                break
            }
            guard let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any]
            else {
                continue
            }

            if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                fullReasoning += reasoning
                await onReasoningDelta?(reasoning)
            }

            if let content = delta["content"] as? String, !content.isEmpty {
                fullText += content
                await onTextDelta(content)
            }

            if let deltaCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in deltaCalls {
                    let index = (call["index"] as? Int) ?? 0
                    var slot = toolSlots[index] ?? (id: "call_\(index)_\(UUID().uuidString.prefix(8))", name: "", args: "")
                    if let id = call["id"] as? String, !id.isEmpty {
                        slot.id = id
                    }
                    if let fn = call["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty {
                            slot.name += name
                        }
                        if let args = fn["arguments"] as? String {
                            slot.args += args
                        }
                    }
                    toolSlots[index] = slot
                }
            }
        }

        let orderedCalls = toolSlots.keys.sorted().compactMap { idx -> LLMToolCall? in
            guard let slot = toolSlots[idx], !slot.name.isEmpty else { return nil }
            let args = slot.args.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMToolCall(id: slot.id, name: slot.name, argumentsJSON: args.isEmpty ? "{}" : args)
        }

        return LLMResponseTurn(text: fullText, reasoning: fullReasoning, toolCalls: orderedCalls)
    }

    // MARK: - Anthropic Messages (SSE)

    private func streamAnthropic(
        config: AIProviderConfig,
        model: String,
        apiKey: String?,
        systemPrompt: String,
        messages: [LLMConversationTurn],
        tools: [LLMToolSchema],
        maxTokens: Int?,
        onReasoningDelta: (@Sendable (String) async -> Void)?,
        onTextDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> LLMResponseTurn {
        guard let url = AIURLBuilder.endpointURL(
            baseURL: config.baseURL,
            appendV1: config.appendV1Suffix,
            path: "messages"
        ) else {
            throw RemoteLLMError.invalidURL(config.baseURL)
        }

        var wireMessages: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            wireMessages.append([
                "role": "user",
                "content": pendingToolResults,
            ])
            pendingToolResults.removeAll()
        }

        for turn in messages {
            switch turn {
            case let .user(text, images):
                flushToolResults()
                if images.isEmpty {
                    wireMessages.append(["role": "user", "content": text])
                } else {
                    var blocks: [[String: Any]] = images.map { image in
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": image.mediaType,
                                "data": image.base64,
                            ],
                        ]
                    }
                    if !text.isEmpty {
                        blocks.append(["type": "text", "text": text])
                    }
                    wireMessages.append(["role": "user", "content": blocks])
                }
            case let .assistant(text, toolCalls):
                flushToolResults()
                var blocks: [[String: Any]] = []
                if !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.decodedDictionary(),
                    ])
                }
                if !blocks.isEmpty {
                    wireMessages.append(["role": "assistant", "content": blocks])
                }
            case let .toolResult(toolCallId, _, content):
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": toolCallId,
                    "content": content,
                ])
            }
        }
        flushToolResults()

        var payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens ?? 4096,
            "system": systemPrompt,
            "messages": wireMessages,
            "stream": true,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchemaObject(),
                ]
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key = apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        if let ua = config.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let errorBody = try await collectBody(from: bytes)
            throw RemoteLLMError.httpError(
                statusCode: http.statusCode,
                message: AIProviderStore.extractErrorMessage(from: errorBody)
            )
        }

        var fullText = ""
        var fullReasoning = ""
        var toolSlots: [Int: (id: String, name: String, args: String)] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let dataStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String
            else {
                continue
            }

            switch eventType {
            case "content_block_start":
                if let index = json["index"] as? Int,
                   let block = json["content_block"] as? [String: Any],
                   (block["type"] as? String) == "tool_use"
                {
                    let id = (block["id"] as? String) ?? "toolu_\(UUID().uuidString.prefix(8))"
                    let name = (block["name"] as? String) ?? ""
                    toolSlots[index] = (id: id, name: name, args: "")
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String
                {
                    if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        fullText += text
                        await onTextDelta(text)
                    } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                        fullReasoning += thinking
                        await onReasoningDelta?(thinking)
                    } else if deltaType == "input_json_delta",
                              let index = json["index"] as? Int,
                              let partial = delta["partial_json"] as? String,
                              var slot = toolSlots[index]
                    {
                        slot.args += partial
                        toolSlots[index] = slot
                    }
                }
            case "error":
                if let err = json["error"] as? [String: Any],
                   let msg = err["message"] as? String
                {
                    throw RemoteLLMError.httpError(statusCode: 500, message: msg)
                }
            default:
                break
            }
        }

        let orderedCalls = toolSlots.keys.sorted().compactMap { idx -> LLMToolCall? in
            guard let slot = toolSlots[idx], !slot.name.isEmpty else { return nil }
            let args = slot.args.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMToolCall(id: slot.id, name: slot.name, argumentsJSON: args.isEmpty ? "{}" : args)
        }

        return LLMResponseTurn(text: fullText, reasoning: fullReasoning, toolCalls: orderedCalls)
    }

    private func collectBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= 8192 {
                break
            }
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }
}
