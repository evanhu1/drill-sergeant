import Foundation

enum Tool: String, Codable {
    case set_idle
    case snooze
    case set_angry
    case save_user_preference
}

struct Decision: Codable, Equatable {
    let tool: Tool
    let snoozeMinutes: Int?
    let message: String
    let text: String?

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "description": "save_user_preference(text): This tool writes a user preference to memory forever. Use it when a user gives feedback or rules on what does or does not count as a distraction or work. Call this sparingly. Negotiate with the user on preferences that seem like they could potentially be excuses or overly generous.",
        "properties": [
            "tool": [
                "type": "string",
                "enum": ["set_idle", "snooze", "set_angry", "save_user_preference"],
            ],
            "snooze_minutes": [
                "type": "integer",
                "minimum": 1,
                "maximum": 120,
            ],
            "message": ["type": "string"],
            "text": [
                "type": "string",
                "description": "The durable rule to save when tool is save_user_preference.",
            ],
        ],
        "required": ["tool", "message"],
    ]

    init(tool: Tool, snoozeMinutes: Int?, message: String, text: String? = nil) {
        self.tool = tool
        if tool == .snooze {
            self.snoozeMinutes = min(120, max(1, snoozeMinutes ?? 10))
        } else {
            self.snoozeMinutes = snoozeMinutes.map { min(120, max(1, $0)) }
        }
        self.message = message
        self.text = tool == .save_user_preference ? text : nil
    }

    static func parse(_ text: String) throws -> Decision {
        guard let object = firstJSONObject(in: text),
              let data = object.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "No JSON object found")
            )
        }
        return try JSONDecoder().decode(Decision.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case tool
        case snoozeMinutes = "snooze_minutes"
        case message
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tool = try container.decode(Tool.self, forKey: .tool)
        let minutes = try container.decodeIfPresent(Int.self, forKey: .snoozeMinutes)
        let message = try container.decode(String.self, forKey: .message)
        let text = if tool == .save_user_preference {
            try container.decode(String.self, forKey: .text)
        } else {
            try container.decodeIfPresent(String.self, forKey: .text)
        }
        self.init(tool: tool, snoozeMinutes: minutes, message: message, text: text)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(snoozeMinutes, forKey: .snoozeMinutes)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(text, forKey: .text)
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var isInString = false
        var isEscaped = false

        for index in text.indices[start...] {
            let character = text[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }
        return nil
    }
}
