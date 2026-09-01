import Foundation

@MainActor
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let goal = "ds.goal"
        static let model = "ds.model"
        static let intervalMinutes = "ds.intervalMinutes"
        static let onboardingStep = "ds.onboardingStep"
        static let ollamaBaseURL = "ds.ollamaBaseURL"
    }

    private let defaults: UserDefaults
    private let environment: [String: String]

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
        if environment["DS_RESET_ONBOARDING"] == "1" {
            defaults.removeObject(forKey: Key.onboardingStep)
            defaults.removeObject(forKey: Key.goal)
        }
    }

    var goal: String {
        get { defaults.string(forKey: Key.goal) ?? "" }
        set { defaults.set(newValue, forKey: Key.goal) }
    }

    var model: String {
        get {
            if let override = environment["DS_MODEL"], !override.isEmpty {
                return override
            }
            return defaults.string(forKey: Key.model) ?? "qwen3-vl:8b"
        }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    var intervalMinutes: Int {
        get {
            if let value = environment["DS_INTERVAL_MINUTES"].flatMap(Int.init), value > 0 {
                return value
            }
            guard defaults.object(forKey: Key.intervalMinutes) != nil else { return 10 }
            return defaults.integer(forKey: Key.intervalMinutes)
        }
        set { defaults.set(newValue, forKey: Key.intervalMinutes) }
    }

    var onboardingStep: OnboardingStep {
        get {
            guard let rawValue = defaults.string(forKey: Key.onboardingStep),
                  let step = OnboardingStep(rawValue: rawValue) else {
                return .welcome
            }
            return step
        }
        set { defaults.set(newValue.rawValue, forKey: Key.onboardingStep) }
    }

    var ollamaBaseURL: URL {
        get {
            if let override = environment["DS_OLLAMA_URL"],
               let url = URL(string: override) {
                return url
            }
            if let stored = defaults.string(forKey: Key.ollamaBaseURL),
               let url = URL(string: stored) {
                return url
            }
            return URL(string: "http://127.0.0.1:11434")!
        }
        set { defaults.set(newValue.absoluteString, forKey: Key.ollamaBaseURL) }
    }
}
