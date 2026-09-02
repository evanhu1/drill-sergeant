import Foundation

struct RuntimeProfile: Equatable {
    static let lowMemoryThreshold: UInt64 = 8 * 1_024 * 1_024 * 1_024

    let contextTokens: Int
    let screenshotMaxEdge: Int
    let conversationMaxTurns: Int
    let keepAlive: String
    let unloadAfterDecision: Bool

    static let standard = RuntimeProfile(
        contextTokens: 8_192,
        screenshotMaxEdge: 1_280,
        conversationMaxTurns: 12,
        keepAlive: "30m",
        unloadAfterDecision: false
    )

    static let lowMemory = RuntimeProfile(
        contextTokens: 4_096,
        screenshotMaxEdge: 960,
        conversationMaxTurns: 4,
        keepAlive: "30s",
        unloadAfterDecision: true
    )

    /// Chooses conservative inference settings on Macs with 8 GB of memory or less.
    static var current: RuntimeProfile {
        forPhysicalMemory(ProcessInfo.processInfo.physicalMemory)
    }

    static func forPhysicalMemory(_ bytes: UInt64) -> RuntimeProfile {
        bytes <= lowMemoryThreshold ? .lowMemory : .standard
    }
}
