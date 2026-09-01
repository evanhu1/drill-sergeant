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
            "format": Decision.jsonSchema,
            "options": ["temperature": 0.2, "num_ctx": 8192],
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
        let (data, response) = try await perform(request)
        let elapsed = Date().timeIntervalSince(startedAt)
        Log.info(String(format: "Ollama response: %d bytes in %.2fs", data.count, elapsed))

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 || responseMentionsMissingModel(data) {
                throw OllamaError.modelMissing(model)
            }
            throw OllamaError.http(response.statusCode)
        }

        struct ChatResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw OllamaError.badResponse("Invalid response from /api/chat")
        }
        do {
            return try Decision.parse(chat.message.content)
        } catch {
            throw OllamaError.badResponse("Invalid decision: \(error.localizedDescription)")
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
