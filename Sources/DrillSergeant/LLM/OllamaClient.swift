import Foundation

struct OllamaMessage: Codable, Equatable {
    var role: String
    var content: String
    var images: [String]?
    var thinking: String?
    var toolCalls: [OllamaToolCall]?
    var toolName: String?
    var toolCallID: String?

    init(
        role: String,
        content: String,
        images: [String]? = nil,
        thinking: String? = nil,
        toolCalls: [OllamaToolCall]? = nil,
        toolName: String? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.toolCallID = toolCallID
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case images
        case thinking
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        images = try container.decodeIfPresent([String].self, forKey: .images)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        toolCalls = try container.decodeIfPresent([OllamaToolCall].self, forKey: .toolCalls)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }
}

enum OllamaError: Error, Equatable {
    case unreachable
    case modelMissing(String)
    case badResponse(String)
    case http(Int)
}

struct OllamaDecisionResult: Equatable {
    let decision: Decision
    let latency: TimeInterval
    let sourceField: String
    let rawContent: String
    let evalCount: Int?
    let doneReason: String?
    let conversationMessages: [OllamaMessage]
}

struct OllamaDecisionFailure: Error, Equatable {
    let error: OllamaError
    let latency: TimeInterval?
    let rawContent: String?
}

actor OllamaClient {
    var model: String

    private struct ChatResponse: Decodable {
        let message: OllamaMessage
        let evalCount: Int?
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case evalCount = "eval_count"
            case doneReason = "done_reason"
        }
    }

    private struct ChatExchange {
        let response: ChatResponse
        let rawResponse: String
    }

    private struct ChatRequestFailure: Error {
        let error: OllamaError
        let rawResponse: String?
    }

    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String
    ) {
        self.baseURL = baseURL
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    init(baseURL: URL, model: String, session: URLSession) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    func isReachable() async -> Bool {
        do {
            let (_, response) = try await session.data(from: endpoint("api/tags"))
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    func hasModel() async throws -> Bool {
        let request = URLRequest(url: endpoint("api/tags"), timeoutInterval: 120)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaError.http(response.statusCode)
        }

        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }

        guard let tags = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            throw OllamaError.badResponse("Invalid response from /api/tags")
        }
        let wanted = normalizedModelName(model)
        return tags.models.contains { normalizedModelName($0.name) == wanted }
    }

    func decide(messages: [OllamaMessage]) async throws -> Decision {
        try await decideWithMetadata(messages: messages).decision
    }

    /// Requests a decision and includes diagnostics used by the developer toolbar.
    func decideWithMetadata(messages: [OllamaMessage]) async throws -> OllamaDecisionResult {
        do {
            return try await decideWithTraceMetadata(messages: messages)
        } catch let failure as OllamaDecisionFailure {
            throw failure.error
        }
    }

    /// Runs one native tool call and, when needed, one assistant-text follow-up.
    func decideWithTraceMetadata(messages: [OllamaMessage]) async throws -> OllamaDecisionResult {
        let startedAt = Date()
        var rawResponses: [String] = []

        do {
            let first = try await chat(
                messages: messages,
                tools: Decision.toolDefinitions
            )
            rawResponses.append(first.rawResponse)

            let calls = first.response.message.toolCalls ?? []
            guard calls.count == 1, let call = calls.first else {
                throw ChatRequestFailure(
                    error: .badResponse("Expected exactly one native tool call, got \(calls.count)"),
                    rawResponse: first.rawResponse
                )
            }

            var decision: Decision
            do {
                decision = try Decision(
                    toolCall: call,
                    message: first.response.message.content
                )
            } catch {
                throw ChatRequestFailure(
                    error: .badResponse("Invalid native tool call: \(error.localizedDescription)"),
                    rawResponse: first.rawResponse
                )
            }

            var assistantToolCall = first.response.message
            assistantToolCall.thinking = nil
            let needsFollowUp = decision.tool != .set_idle && decision.message.isEmpty
            let toolResult = OllamaMessage(
                role: "tool",
                content: needsFollowUp
                    ? "Accepted. Respond now with only the short user-facing message."
                    : "Accepted.",
                toolName: call.function.name,
                toolCallID: call.id
            )
            var conversationMessages = [assistantToolCall, toolResult]
            var sourceField = decision.message.isEmpty ? "tool_calls" : "content"
            var evalCount = first.response.evalCount
            var doneReason = first.response.doneReason

            if needsFollowUp {
                let historyWithoutImages = messages.map { message in
                    var copy = message
                    copy.images = nil
                    return copy
                }
                let followUp = try await chat(
                    messages: historyWithoutImages + conversationMessages,
                    tools: nil
                )
                rawResponses.append(followUp.rawResponse)
                let content = followUp.response.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else {
                    throw ChatRequestFailure(
                        error: .badResponse("No assistant text after native tool result"),
                        rawResponse: followUp.rawResponse
                    )
                }
                decision = try Decision(toolCall: call, message: content)
                var assistantText = followUp.response.message
                assistantText.thinking = nil
                conversationMessages.append(assistantText)
                sourceField = "followup.content"
                evalCount = combined(first.response.evalCount, followUp.response.evalCount)
                doneReason = followUp.response.doneReason ?? first.response.doneReason
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            Log.info(
                "Ollama decision source: message.\(sourceField), "
                    + "tool=\(call.function.name), "
                    + "eval_count=\(evalCount.map(String.init) ?? "none"), "
                    + "done_reason=\(doneReason ?? "none")"
            )
            return OllamaDecisionResult(
                decision: decision,
                latency: elapsed,
                sourceField: sourceField,
                rawContent: rawResponses.joined(separator: "\n\n--- follow-up response\n"),
                evalCount: evalCount,
                doneReason: doneReason,
                conversationMessages: conversationMessages
            )
        } catch let failure as ChatRequestFailure {
            if let rawResponse = failure.rawResponse,
               !rawResponses.contains(rawResponse) {
                rawResponses.append(rawResponse)
            }
            throw OllamaDecisionFailure(
                error: failure.error,
                latency: Date().timeIntervalSince(startedAt),
                rawContent: rawResponses.isEmpty
                    ? failure.rawResponse
                    : rawResponses.joined(separator: "\n\n--- follow-up response\n")
            )
        } catch let error as OllamaError {
            throw OllamaDecisionFailure(
                error: error,
                latency: Date().timeIntervalSince(startedAt),
                rawContent: rawResponses.isEmpty
                    ? nil
                    : rawResponses.joined(separator: "\n\n--- follow-up response\n")
            )
        } catch {
            throw OllamaDecisionFailure(
                error: .badResponse(error.localizedDescription),
                latency: Date().timeIntervalSince(startedAt),
                rawContent: rawResponses.isEmpty
                    ? nil
                    : rawResponses.joined(separator: "\n\n--- follow-up response\n")
            )
        }
    }

    private func chat(
        messages: [OllamaMessage],
        tools: [[String: Any]]?
    ) async throws -> ChatExchange {
        let encodedMessages = try JSONEncoder().encode(messages)
        guard let messageObjects = try JSONSerialization.jsonObject(
            with: encodedMessages
        ) as? [[String: Any]] else {
            throw OllamaError.badResponse("Could not encode chat messages")
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messageObjects,
            "stream": false,
            "think": "low",
            "options": [
                "temperature": 0.2,
                "num_ctx": 8192,
            ],
            "keep_alive": "30m",
        ]
        if let tools {
            payload["tools"] = tools
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw OllamaError.badResponse(
                "Could not encode request: \(error.localizedDescription)"
            )
        }

        var request = URLRequest(url: endpoint("api/chat"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let requestStartedAt = Date()
        Log.info("Ollama request: \(body.count) bytes")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as OllamaError {
            throw ChatRequestFailure(error: error, rawResponse: nil)
        }
        Log.info(
            String(
                format: "Ollama response: %d bytes in %.2fs",
                data.count,
                Date().timeIntervalSince(requestStartedAt)
            )
        )
        let rawResponse = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(response.statusCode) else {
            let error: OllamaError
            if response.statusCode == 404 || responseMentionsMissingModel(data) {
                error = .modelMissing(model)
            } else {
                error = .http(response.statusCode)
            }
            throw ChatRequestFailure(error: error, rawResponse: rawResponse)
        }

        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ChatRequestFailure(
                error: .badResponse("Invalid response from /api/chat"),
                rawResponse: rawResponse
            )
        }
        return ChatExchange(response: chat, rawResponse: rawResponse)
    }

    private func combined(_ first: Int?, _ second: Int?) -> Int? {
        if first == nil, second == nil { return nil }
        return (first ?? 0) + (second ?? 0)
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.badResponse("Response was not HTTP")
            }
            return (data, httpResponse)
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.unreachable
        }
    }

    private func normalizedModelName(_ name: String) -> String {
        name.hasSuffix(":latest") ? String(name.dropLast(7)) : name
    }

    private func responseMentionsMissingModel(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else {
            return false
        }
        return text.contains("model") && text.contains("not found")
    }
}
