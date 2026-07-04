import Foundation

/// Fan-out helper: AsyncStream supports a single consumer, but transports
/// have several (AppState UI, MeshSession, tests). Each `stream()` call
/// returns an independent stream; `yield` broadcasts to all of them.
final class StreamMulticaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var lastValue: Element?
    private let replayLast: Bool

    /// - Parameter replayLast: new subscribers immediately receive the most
    ///   recent value (right for state; wrong for message frames).
    init(replayLast: Bool = false) {
        self.replayLast = replayLast
    }

    func stream(bufferingNewest bufferSize: Int = 64) -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            lock.lock()
            continuations[id] = continuation
            let replay = replayLast ? lastValue : nil
            lock.unlock()
            if let replay {
                continuation.yield(replay)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func yield(_ value: Element) {
        lock.lock()
        lastValue = value
        let sinks = Array(continuations.values)
        lock.unlock()
        for sink in sinks {
            sink.yield(value)
        }
    }
}
