import Foundation

struct OllamaMessage: Codable, Equatable {
    var role: String
    var content: String
    var images: [String]?
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
}

struct OllamaDecisionFailure: Error, Equatable {
    let error: OllamaError
    let latency: TimeInterval?
    let rawContent: String?
}

actor OllamaClient {
    var model: String

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

    /// Requests a decision while preserving raw response details when parsing fails.
    func decideWithTraceMetadata(messages: [OllamaMessage]) async throws -> OllamaDecisionResult {
        let encodedMessages = try JSONEncoder().encode(messages)
        guard let messageObjects = try JSONSerialization.jsonObject(
            with: encodedMessages
        ) as? [[String: Any]] else {
            throw OllamaError.badResponse("Could not encode chat messages")
        }
        let payload: [String: Any] = [
            "model": model,
            "messages": messageObjects,
            "stream": false,
            "think": false,
            "format": Decision.jsonSchema,
            "options": [
                "temperature": 0.2,
                "num_ctx": 8192,
                "num_predict": 200,
            ],
            "keep_alive": "30m",
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw OllamaError.badResponse("Could not encode request: \(error.localizedDescription)")
        }

        var request = URLRequest(url: endpoint("api/chat"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let startedAt = Date()
        Log.info("Ollama request: \(body.count) bytes")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(request)
        } catch let error as OllamaError {
            throw OllamaDecisionFailure(
                error: error,
                latency: Date().timeIntervalSince(startedAt),
                rawContent: nil
            )
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        Log.info(String(format: "Ollama response: %d bytes in %.2fs", data.count, elapsed))
        let rawResponse = String(data: data, encoding: .utf8)

        guard (200..<300).contains(response.statusCode) else {
            let error: OllamaError
            if response.statusCode == 404 || responseMentionsMissingModel(data) {
                error = .modelMissing(model)
            } else {
                error = .http(response.statusCode)
            }
            throw OllamaDecisionFailure(
                error: error,
                latency: elapsed,
                rawContent: rawResponse
            )
        }

        struct ChatResponse: Decodable {
            struct Message: Decodable {
                let content: String
                let thinking: String?
            }

            let message: Message
            let evalCount: Int?
            let doneReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case evalCount = "eval_count"
                case doneReason = "done_reason"
            }
        }
        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw OllamaDecisionFailure(
                error: .badResponse("Invalid response from /api/chat"),
                latency: elapsed,
                rawContent: rawResponse
            )
        }

        let decisionText: String
        let responseField: String
        if chat.message.content.contains("{") {
            decisionText = chat.message.content
            responseField = "content"
        } else if let thinking = chat.message.thinking {
            decisionText = thinking
            responseField = "thinking"
        } else {
            throw OllamaDecisionFailure(
                error: .badResponse("No decision in message.content or message.thinking"),
                latency: elapsed,
                rawContent: rawResponse
            )
        }

        var details = ["field=message.\(responseField)"]
        if let evalCount = chat.evalCount {
            details.append("eval_count=\(evalCount)")
        }
        if let doneReason = chat.doneReason {
            details.append("done_reason=\(doneReason)")
        }
        Log.info("Ollama decision source: \(details.joined(separator: ", "))")

        do {
            return OllamaDecisionResult(
                decision: try Decision.parse(decisionText),
                latency: elapsed,
                sourceField: responseField,
                rawContent: decisionText,
                evalCount: chat.evalCount,
                doneReason: chat.doneReason
            )
        } catch {
            throw OllamaDecisionFailure(
                error: .badResponse(
                    "Invalid decision in message.\(responseField): \(error.localizedDescription)"
                ),
                latency: elapsed,
                rawContent: decisionText
            )
        }
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
