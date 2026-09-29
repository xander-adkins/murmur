import CoreAudio
import Foundation
import Testing
@testable import MurmurCore

@Suite struct GraphReusePolicyTests {
    private let airpods = AudioInputDevice(id: 7, name: "AirPods")
    private let macbook = AudioInputDevice(id: 91, name: "MacBook Pro Microphone")

    @Test func nothingPreparedMeansRebuild() {
        #expect(!GraphReusePolicy.canReuse(prepared: nil, requested: .systemDefault(id: 42), formatsStillMatch: true))
    }

    @Test func defaultDeviceGraphIsReusedWhileTheDefaultIsUnchanged() {
        #expect(GraphReusePolicy.canReuse(prepared: .systemDefault(id: 42), requested: .systemDefault(id: 42), formatsStillMatch: true))
        #expect(!GraphReusePolicy.canReuse(prepared: .systemDefault(id: 42), requested: .systemDefault(id: 43), formatsStillMatch: true), "AirPods connected: rebuild")
    }

    @Test func unknownDefaultDeviceNeverMatches() {
        // "Could not determine the default device" twice is not evidence that nothing changed.
        #expect(!GraphReusePolicy.canReuse(prepared: .systemDefault(id: nil), requested: .systemDefault(id: nil), formatsStillMatch: true))
        #expect(!GraphReusePolicy.canReuse(prepared: .systemDefault(id: nil), requested: .systemDefault(id: 42), formatsStillMatch: true))
        #expect(!GraphReusePolicy.canReuse(prepared: .systemDefault(id: 42), requested: .systemDefault(id: nil), formatsStillMatch: true))
    }

    @Test func pinnedDeviceGraphIsReusedByDeviceIdentity() {
        #expect(GraphReusePolicy.canReuse(prepared: .pinned(airpods), requested: .pinned(airpods), formatsStillMatch: true))
        #expect(!GraphReusePolicy.canReuse(prepared: .pinned(airpods), requested: .pinned(macbook), formatsStillMatch: true))
    }

    @Test func switchingBetweenPinnedAndDefaultRebuilds() {
        #expect(!GraphReusePolicy.canReuse(prepared: .pinned(airpods), requested: .systemDefault(id: 7), formatsStillMatch: true))
        #expect(!GraphReusePolicy.canReuse(prepared: .systemDefault(id: 7), requested: .pinned(airpods), formatsStillMatch: true))
    }

    @Test func formatMismatchAlwaysRebuilds() {
        // This is the case that raised an uncatchable CoreAudio exception before the policy existed.
        #expect(!GraphReusePolicy.canReuse(prepared: .systemDefault(id: 42), requested: .systemDefault(id: 42), formatsStillMatch: false))
        #expect(!GraphReusePolicy.canReuse(prepared: .pinned(airpods), requested: .pinned(airpods), formatsStillMatch: false))
    }
}

/// Exactly one of {completion, timeout} runs, and never more than once.
@Suite struct OneShotCompletionLaws {
    final class ManualClock {
        var pending: [DispatchWorkItem] = []
        func advance() {
            let items = pending
            pending = []
            items.forEach { $0.perform() }
        }
    }

    private func make() -> (OneShotCompletion<String>, ManualClock) {
        let clock = ManualClock()
        return (OneShotCompletion(schedule: { _, item in clock.pending.append(item) }), clock)
    }

    @Test func firesAtMostOnce() {
        let (completion, _) = make()
        var got: [String] = []
        completion.arm({ got.append($0) }, timeout: 1) {}
        #expect(completion.fire("a"))
        #expect(!completion.fire("b"))
        #expect(!completion.isPending)
        #expect(got == ["a"])
    }

    @Test func fireWithoutArmIsANoOp() {
        let (completion, _) = make()
        #expect(!completion.fire("nobody"))
    }

    @Test func timeoutMakesALateFireImpossible() {
        let (completion, clock) = make()
        var got: [String] = []
        var timedOut = 0
        completion.arm({ got.append($0) }, timeout: 1) { timedOut += 1 }
        clock.advance()
        #expect(timedOut == 1)
        #expect(!completion.isPending)
        #expect(!completion.fire("late"))
        #expect(got.isEmpty)
    }

    @Test func fireCancelsTheTimeout() {
        let (completion, clock) = make()
        var timedOut = 0
        completion.arm({ _ in }, timeout: 1) { timedOut += 1 }
        completion.fire("v")
        clock.advance()
        #expect(timedOut == 0)
    }

    @Test func disarmCancelsBoth() {
        let (completion, clock) = make()
        var got = 0
        var timedOut = 0
        completion.arm({ _ in got += 1 }, timeout: 1) { timedOut += 1 }
        completion.disarm()
        clock.advance()
        #expect(!completion.fire("x"))
        #expect((got, timedOut) == (0, 0))
    }

    @Test func completionMayReArm() {
        let (completion, _) = make()
        var second: String?
        completion.arm({ _ in completion.arm({ second = $0 }, timeout: 1) {} }, timeout: 1) {}
        completion.fire("first")
        #expect(completion.isPending)
        completion.fire("second")
        #expect(second == "second")
    }
}
