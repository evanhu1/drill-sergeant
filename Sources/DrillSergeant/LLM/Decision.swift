import Foundation

enum Tool: String, Codable {
    case set_idle
    case snooze
    case set_angry
    case save_user_preference
    case set_work_hours
}

struct OllamaToolArguments: Codable, Equatable {
    let minutes: Int?
    let text: String?
    let days: [Weekday]?
    let startTime: String?
    let endTime: String?

    init(
        minutes: Int? = nil,
        text: String? = nil,
        days: [Weekday]? = nil,
        startTime: String? = nil,
        endTime: String? = nil
    ) {
        self.minutes = minutes
        self.text = text
        self.days = days
        self.startTime = startTime
        self.endTime = endTime
    }

    private enum CodingKeys: String, CodingKey {
        case minutes
        case text
        case days
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

struct OllamaToolCall: Codable, Equatable {
    struct Function: Codable, Equatable {
        let index: Int?
        let name: String
        let arguments: OllamaToolArguments

        init(index: Int? = nil, name: String, arguments: OllamaToolArguments) {
            self.index = index
            self.name = name
            self.arguments = arguments
        }
    }

    let id: String?
    let type: String?
    let function: Function

    init(id: String? = nil, type: String? = nil, function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

enum DecisionError: Error, Equatable, LocalizedError {
    case unknownTool(String)
    case missingPreferenceText
    case missingWorkHours
    case invalidWorkHours(WorkHoursError)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name): return "Unknown tool: \(name)"
        case .missingPreferenceText: return "save_user_preference requires text"
        case .missingWorkHours: return "set_work_hours requires days, start_time, and end_time"
        case let .invalidWorkHours(error): return "Invalid work hours: \(error)"
        }
    }
}

struct Decision: Equatable {
    let tool: Tool
    let snoozeMinutes: Int?
    let message: String
    let text: String?
    let workHours: WorkHours?

    static let toolDefinitions: [[String: Any]] = [
        toolDefinition(
            name: Tool.set_idle.rawValue,
            description: "The user is working, or the window is ambiguous but plausibly work.",
            parameters: emptyParameters
        ),
        toolDefinition(
            name: Tool.set_angry.rawValue,
            description: "The user is clearly slacking off and should be told to stop.",
            parameters: emptyParameters
        ),
        toolDefinition(
            name: Tool.snooze.rawValue,
            description: "Pause monitoring because the user has a legitimate break or asked for time.",
            parameters: [
                "type": "object",
                "properties": [
                    "minutes": [
                        "type": "integer",
                        "description": "Number of minutes to pause monitoring.",
                        "minimum": 1,
                        "maximum": 120,
                    ],
                ],
                "required": ["minutes"],
                "additionalProperties": false,
            ]
        ),
        toolDefinition(
            name: Tool.save_user_preference.rawValue,
            description: "Save a durable user rule about what counts as work or a distraction. Use sparingly and negotiate rules that could be excuses.",
            parameters: [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The complete durable rule to remember.",
                    ],
                ],
                "required": ["text"],
                "additionalProperties": false,
            ]
        ),
        toolDefinition(
            name: Tool.set_work_hours.rawValue,
            description: "Replace the complete weekly schedule for automatic monitoring using local time.",
            parameters: [
                "type": "object",
                "properties": [
                    "days": [
                        "type": "array",
                        "description": "Every active day in the replacement schedule.",
                        "items": [
                            "type": "string",
                            "enum": Weekday.allCases.map(\.rawValue),
                        ],
                        "minItems": 1,
                        "uniqueItems": true,
                    ],
                    "start_time": [
                        "type": "string",
                        "description": "Local start time in HH:mm 24-hour format, such as 09:00.",
                        "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$",
                    ],
                    "end_time": [
                        "type": "string",
                        "description": "Local end time in HH:mm 24-hour format. Use 24:00 for end of day.",
                        "pattern": "^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$",
                    ],
                ],
                "required": ["days", "start_time", "end_time"],
                "additionalProperties": false,
            ]
        ),
    ]

    /// The tools a screenshot check may call. `save_user_preference` and `set_work_hours`
    /// answer a user reply and are rejected during a check, so offering them there only
    /// spends prompt tokens — `set_work_hours` alone costs 198 of them.
    static let checkToolDefinitions: [[String: Any]] = toolDefinitions.filter { definition in
        guard let function = definition["function"] as? [String: Any],
              let name = function["name"] as? String else { return false }
        return [Tool.set_idle, .set_angry, .snooze].map(\.rawValue).contains(name)
    }

    init(
        tool: Tool,
        snoozeMinutes: Int?,
        message: String,
        text: String? = nil,
        workHours: WorkHours? = nil
    ) {
        self.tool = tool
        if tool == .snooze {
            self.snoozeMinutes = min(120, max(1, snoozeMinutes ?? 10))
        } else {
            self.snoozeMinutes = snoozeMinutes.map { min(120, max(1, $0)) }
        }
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = tool == .save_user_preference ? text : nil
        self.workHours = tool == .set_work_hours ? workHours : nil
    }

    init(toolCall: OllamaToolCall, message: String) throws {
        guard let tool = Tool(rawValue: toolCall.function.name) else {
            throw DecisionError.unknownTool(toolCall.function.name)
        }
        let arguments = toolCall.function.arguments

        switch tool {
        case .set_idle, .set_angry:
            self.init(tool: tool, snoozeMinutes: nil, message: message)
        case .snooze:
            self.init(tool: tool, snoozeMinutes: arguments.minutes, message: message)
        case .save_user_preference:
            guard let text = arguments.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecisionError.missingPreferenceText
            }
            self.init(
                tool: tool,
                snoozeMinutes: nil,
                message: message,
                text: text
            )
        case .set_work_hours:
            guard let days = arguments.days,
                  let startTime = arguments.startTime,
                  let endTime = arguments.endTime else {
                throw DecisionError.missingWorkHours
            }
            let workHours: WorkHours
            do {
                workHours = try WorkHours(
                    days: days,
                    startTime: startTime,
                    endTime: endTime
                )
            } catch let error as WorkHoursError {
                throw DecisionError.invalidWorkHours(error)
            }
            self.init(
                tool: tool,
                snoozeMinutes: nil,
                message: message,
                workHours: workHours
            )
        }
    }

    private static let emptyParameters: [String: Any] = [
        "type": "object",
        "properties": [String: Any](),
        "additionalProperties": false,
    ]

    private static func toolDefinition(
        name: String,
        description: String,
        parameters: [String: Any]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}
