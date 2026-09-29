import Foundation

/// Delivers a value to exactly one waiting completion, or invokes the timeout fallback instead —
/// never both. Both speech engines use it for "the button was released; hand over the transcript once".
///
/// Main-queue only. The scheduler is injectable so the laws can be tested with a manual clock.
final class OneShotCompletion<Value> {
    typealias Scheduler = (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void

    private let schedule: Scheduler
    private var completion: ((Value) -> Void)?
    private var timeout: DispatchWorkItem?

    init(schedule: @escaping Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.schedule = schedule
    }

    deinit {
        timeout?.cancel()
    }

    var isPending: Bool {
        completion != nil
    }

    /// Arms a completion. Arming while one is already pending is a programming error; the earlier
    /// waiter would be dropped without ever hearing back.
    func arm(_ completion: @escaping (Value) -> Void, timeout seconds: TimeInterval, onTimeout: @escaping () -> Void) {
        assert(!isPending, "OneShotCompletion armed twice")
        disarm()
        self.completion = completion
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPending else { return }
            self.disarm()
            onTimeout()
        }
        timeout = work
        schedule(seconds, work)
    }

    /// Fires the waiting completion; later calls are ignored. Returns false when nothing was waiting.
    @discardableResult
    func fire(_ value: Value) -> Bool {
        guard let completion else {
            return false
        }
        disarm()
        completion(value)
        return true
    }

    func disarm() {
        completion = nil
        timeout?.cancel()
        timeout = nil
    }
}

extension Date {
    /// Whole milliseconds between this instant and now.
    var millisecondsAgo: Int {
        Int(Date().timeIntervalSince(self) * 1000)
    }

    func milliseconds(until other: Date) -> Int {
        Int(other.timeIntervalSince(self) * 1000)
    }
}

extension String {
    /// The string with surrounding whitespace and newlines removed.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// True when launched from a `.app` bundle rather than as a bare executable.
let isRunningFromBundle = Bundle.main.bundleURL.pathExtension == "app"
