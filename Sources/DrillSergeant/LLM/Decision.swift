import Foundation

enum Tool: String, Codable {
    case set_idle
    case snooze
    case set_angry
}

struct Decision: Codable, Equatable {
    let tool: Tool
    let snoozeMinutes: Int?
    let message: String

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "tool": [
                "type": "string",
                "enum": ["set_idle", "snooze", "set_angry"],
            ],
            "snooze_minutes": [
                "type": "integer",
                "minimum": 1,
                "maximum": 120,
            ],
            "message": ["type": "string"],
        ],
        "required": ["tool", "message"],
    ]

    init(tool: Tool, snoozeMinutes: Int?, message: String) {
        self.tool = tool
        if tool == .snooze {
            self.snoozeMinutes = min(120, max(1, snoozeMinutes ?? 10))
        } else {
            self.snoozeMinutes = snoozeMinutes.map { min(120, max(1, $0)) }
        }
        self.message = message
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tool = try container.decode(Tool.self, forKey: .tool)
        let minutes = try container.decodeIfPresent(Int.self, forKey: .snoozeMinutes)
        let message = try container.decode(String.self, forKey: .message)
        self.init(tool: tool, snoozeMinutes: minutes, message: message)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(snoozeMinutes, forKey: .snoozeMinutes)
        try container.encode(message, forKey: .message)
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
