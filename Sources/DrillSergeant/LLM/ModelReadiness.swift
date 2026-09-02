import Foundation

/// How close the local model is to being usable.
enum ModelReadinessState: Equatable {
    /// Ollama is not answering yet.
    case waitingForOllama
    /// Ollama is up and the model is on disk.
    case ready
    /// The model is downloading. `fraction` is nil until Ollama reports layer sizes.
    case downloading(fraction: Double?, detail: String?)
    /// The download failed and will be retried.
    case retrying(reason: String)

    var isReady: Bool { self == .ready }
}

/// Gets the local model onto the Mac without anyone waiting on a terminal.
///
/// The installer used to run `ollama pull` and hold the shell for the length of a 6 GB
/// download. Doing it here instead means the app is in the notch within seconds, and the
/// download overlaps the time the user spends granting Screen Recording.
@MainActor
final class ModelReadiness {
    private(set) var state: ModelReadinessState = .waitingForOllama {
        didSet {
            guard state != oldValue else { return }
            onChange?(state)
        }
    }

    /// Called on every state change, including each progress tick.
    var onChange: ((ModelReadinessState) -> Void)?

    /// Seconds between attempts when Ollama is missing or a download fails.
    var retryInterval: TimeInterval = 3

    private let ollama: OllamaClient
    private var task: Task<Void, Never>?

    init(ollama: OllamaClient) {
        self.ollama = ollama
    }

    deinit {
        task?.cancel()
    }

    /// Starts, and keeps retrying until the model is ready. Safe to call more than once.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await attempt() { return }
                guard await Self.sleep(for: retryInterval) else { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One full pass. Returns true once the model is ready.
    private func attempt() async -> Bool {
        guard await ollama.isReachable() else {
            state = .waitingForOllama
            return false
        }

        do {
            if try await ollama.hasModel() {
                state = .ready
                return true
            }
        } catch {
            state = .retrying(reason: error.localizedDescription)
            return false
        }

        state = .downloading(fraction: nil, detail: nil)
        // Layer totals step backwards between layers; the largest one seen is the model.
        let tracker = DownloadProgressTracker()
        do {
            // Ollama streams progress many times a second. Only whole percents reach the
            // bubble, so a 6 GB download costs a hundred main-actor hops rather than
            // thousands.
            try await ollama.pullModel { progress in
                guard let scaled = tracker.scaleIfPercentChanged(progress) else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.state.isReady else { return }
                    self.state = .downloading(
                        fraction: scaled.fraction,
                        detail: scaled.sizeSummary
                    )
                }
            }
        } catch {
            Log.warn("Model download failed: \(error.localizedDescription)")
            state = .retrying(reason: error.localizedDescription)
            return false
        }

        state = .ready
        return true
    }

    private static func sleep(for interval: TimeInterval) async -> Bool {
        let nanoseconds = UInt64(max(0.001, interval) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// Keeps the download reading forwards across Ollama's per-layer progress lines.
///
/// Ollama reports `completed` and `total` per layer, so the numbers step backwards every
/// time a new layer starts. The largest total seen is the model itself, which is the only
/// part worth showing; smaller layers are ignored.
final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private var completed: Int64 = 0
    private var lastPercent = -1

    /// Returns the scaled progress only when the whole percent moved, or nil to skip it.
    func scaleIfPercentChanged(_ progress: ModelDownloadProgress) -> ModelDownloadProgress? {
        lock.lock()
        defer { lock.unlock() }

        if progress.total > total {
            // A bigger layer supersedes the one being tracked; its progress starts over.
            total = progress.total
            completed = progress.completed
        } else if progress.total == total, total > 0 {
            completed = max(completed, progress.completed)
        }

        let scaled = ModelDownloadProgress(
            status: progress.status,
            completed: completed,
            total: total
        )
        let percent = scaled.fraction.map { Int(($0 * 100).rounded()) } ?? -1
        guard percent != lastPercent else { return nil }
        lastPercent = percent
        return scaled
    }
}
