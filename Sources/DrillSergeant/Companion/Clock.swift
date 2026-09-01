import Foundation

protocol Clock {
    var now: Date { get }

    /// Schedules `block` after `seconds` and returns a token that can cancel it.
    func after(
        _ seconds: TimeInterval,
        _ block: @escaping @MainActor () -> Void
    ) -> CancelToken
}

final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (() -> Void)?

    init(cancellation: (() -> Void)? = nil) {
        self.cancellation = cancellation
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let action: (() -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }
}

final class SystemClock: Clock {
    var now: Date { Date() }

    func after(
        _ seconds: TimeInterval,
        _ block: @escaping @MainActor () -> Void
    ) -> CancelToken {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                block()
            }
        }
        let token = CancelToken(cancellation: item.cancel)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, seconds),
            execute: item
        )
        return token
    }
}

/// A deterministic clock whose scheduled work runs while `advance(by:)` advances time.
final class TestClock: Clock {
    private struct Entry {
        let id: Int
        let date: Date
        let token: CancelToken
        let block: @MainActor () -> Void
    }

    private var current: Date
    private var entries: [Entry] = []
    private var nextID = 0

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        current = now
    }

    var now: Date { current }

    func after(
        _ seconds: TimeInterval,
        _ block: @escaping @MainActor () -> Void
    ) -> CancelToken {
        let token = CancelToken()
        entries.append(
            Entry(
                id: nextID,
                date: current.addingTimeInterval(max(0, seconds)),
                token: token,
                block: block
            )
        )
        nextID += 1
        return token
    }

    @MainActor
    func advance(by seconds: TimeInterval) {
        let target = current.addingTimeInterval(max(0, seconds))

        while let entry = nextEntry(noLaterThan: target) {
            entries.removeAll { $0.id == entry.id }
            current = entry.date
            guard !entry.token.isCancelled else { continue }
            entry.block()
        }

        current = target
    }

    private func nextEntry(noLaterThan target: Date) -> Entry? {
        entries
            .filter { $0.date <= target }
            .min {
                if $0.date == $1.date { return $0.id < $1.id }
                return $0.date < $1.date
            }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
