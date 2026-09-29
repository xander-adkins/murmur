import Testing
@testable import MurmurCore

@Suite struct SwipeRecognizerTests {
    private typealias Stroke = SwipeRecognizer.Stroke

    /// Strokes recorded from a Siri Remote through MultitouchSupport at ~60 Hz: normalized
    /// (x, y) with y running bottom to top. The up-swipe is verbatim; the others keep the
    /// recorded start and end with the path interpolated.
    static let recordedUp: [TouchPoint] = [
        (0.608, 0.158), (0.601, 0.158), (0.596, 0.158), (0.592, 0.160), (0.589, 0.161), (0.586, 0.165),
        (0.583, 0.173), (0.579, 0.184), (0.576, 0.206), (0.576, 0.238), (0.584, 0.295), (0.605, 0.381),
        (0.647, 0.503), (0.678, 0.575), (0.707, 0.634), (0.736, 0.679),
    ].map(TouchPoint.init)
    static let recordedDown = path(from: (0.539, 0.545), to: (0.424, 0.129))
    static let recordedLeft = path(from: (0.754, 0.329), to: (0.191, 0.221))
    static let recordedRight = path(from: (0.320, 0.345), to: (0.859, 0.460))
    /// A tap: nine frames that barely move.
    static let recordedTap = path(from: (0.506, 0.473), to: (0.518, 0.492), frames: 9)

    static func path(from start: (Double, Double), to end: (Double, Double), frames: Int = 20) -> [TouchPoint] {
        (0..<frames).map { index in
            let t = Double(index) / Double(frames - 1)
            return TouchPoint(x: start.0 + (end.0 - start.0) * t, y: start.1 + (end.1 - start.1) * t)
        }
    }

    private func stroke(_ points: [TouchPoint]) -> [TouchEvent] {
        points.map(TouchEvent.contact) + [.lift]
    }

    @Test(arguments: [
        (recordedUp, SwipeDirection.up), (recordedDown, .down), (recordedLeft, .left), (recordedRight, .right),
    ])
    func recordedStrokeIsExactlyOneSwipe(points: [TouchPoint], expected: SwipeDirection) {
        #expect(SwipeRecognizer.swipes(in: stroke(points)) == [expected])
    }

    @Test func tapIsNotASwipe() {
        #expect(SwipeRecognizer.swipes(in: stroke(Self.recordedTap)).isEmpty)
    }

    @Test func swipeIsReportedBeforeTheFingerLifts() {
        let events = Self.recordedUp.map(TouchEvent.contact)
        #expect(SwipeRecognizer.swipes(in: events) == [.up], "a menu should move while the thumb is still on the glass")
    }

    @Test func oneStrokeYieldsAtMostOneSwipeHoweverFarItGoes() {
        let edgeToEdge = Self.path(from: (0.05, 0.5), to: (0.95, 0.5), frames: 40)
        #expect(SwipeRecognizer.swipes(in: stroke(edgeToEdge)) == [.right])

        let thereAndBack = Self.path(from: (0.2, 0.5), to: (0.8, 0.5)) + Self.path(from: (0.8, 0.5), to: (0.2, 0.5))
        #expect(SwipeRecognizer.swipes(in: stroke(thereAndBack)) == [.right], "a reversal within a stroke is not a second swipe")
    }

    @Test func liftingStartsANewStroke() {
        let events = stroke(Self.recordedUp) + stroke(Self.recordedDown) + stroke(Self.recordedUp)
        #expect(SwipeRecognizer.swipes(in: events) == [.up, .down, .up])
    }

    @Test func aDriftThatNeverReachesTheThresholdIsIgnoredEvenIfLong() {
        let creeping = Self.path(from: (0.5, 0.5), to: (0.5 + 0.17, 0.5), frames: 200)
        #expect(SwipeRecognizer.swipes(in: stroke(creeping)).isEmpty)
    }

    @Test func diagonalsPickTheDominantAxisAndTiesGoVertical() {
        let min = 0.18
        #expect(SwipeRecognizer.direction(from: TouchPoint(x: 0, y: 0), to: TouchPoint(x: 0.3, y: 0.2), minimumDistance: min) == .right)
        #expect(SwipeRecognizer.direction(from: TouchPoint(x: 0, y: 0), to: TouchPoint(x: 0.2, y: -0.3), minimumDistance: min) == .down)
        #expect(SwipeRecognizer.direction(from: TouchPoint(x: 0, y: 0), to: TouchPoint(x: 0.3, y: 0.3), minimumDistance: min) == .up)
        #expect(SwipeRecognizer.direction(from: TouchPoint(x: 0, y: 0), to: TouchPoint(x: -0.3, y: -0.3), minimumDistance: min) == .down)
    }

    /// Direction is nil exactly below the threshold, agrees with the sign of the dominant
    /// displacement, and reversing the displacement reverses the direction.
    @Test func directionLaws() {
        var rng = SplitMix64(seed: 7)
        let opposite: [SwipeDirection: SwipeDirection] = [.up: .down, .down: .up, .left: .right, .right: .left]
        for _ in 0..<5000 {
            let a = TouchPoint(x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng))
            let b = TouchPoint(x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng))
            let minimum = Double.random(in: 0.01...0.5, using: &rng)
            let forward = SwipeRecognizer.direction(from: a, to: b, minimumDistance: minimum)
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            #expect((forward == nil) == (max(abs(dx), abs(dy)) < minimum))
            switch forward {
            case .right?: #expect(dx > 0 && abs(dx) > abs(dy))
            case .left?: #expect(dx < 0 && abs(dx) > abs(dy))
            case .up?: #expect(dy > 0 && abs(dy) >= abs(dx))
            case .down?: #expect(dy < 0 && abs(dy) >= abs(dx))
            case nil: break
            }
            #expect(SwipeRecognizer.direction(from: b, to: a, minimumDistance: minimum) == forward.flatMap { opposite[$0] })
        }
    }

    /// The stroke machine over every state and event class: lift always idles, a recognized stroke
    /// absorbs contacts, and a swipe is only ever produced from `tracking`.
    @Test func strokeLaws() {
        let far = TouchPoint(x: 0.9, y: 0.5)
        let near = TouchPoint(x: 0.1, y: 0.5)
        let states: [Stroke] = [.idle, .tracking(origin: near), .recognized]
        for state in states {
            #expect(SwipeRecognizer.step(state, .lift) == (.idle, nil))
            let (next, swipe) = SwipeRecognizer.step(state, .contact(far))
            switch state {
            case .idle:
                #expect(next == .tracking(origin: far) && swipe == nil)
            case .tracking:
                #expect(next == .recognized && swipe == .right)
            case .recognized:
                #expect(next == .recognized && swipe == nil)
            }
        }
    }

    @Test func swipesInIsTheFoldOfStep() {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<300 {
            let events: [TouchEvent] = (0..<Int.random(in: 0...60, using: &rng)).map { _ in
                Bool.random(using: &rng)
                    ? .contact(TouchPoint(x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng)))
                    : .lift
            }
            var state = Stroke.idle
            var folded: [SwipeDirection] = []
            for event in events {
                let (next, swipe) = SwipeRecognizer.step(state, event)
                state = next
                folded += swipe.map { [$0] } ?? []
            }
            #expect(SwipeRecognizer.swipes(in: events) == folded)
            let strokes = 1 + events.filter { $0 == .lift }.count
            #expect(folded.count <= strokes, "at most one swipe per stroke")
        }
    }
}

@Suite struct MultitouchFrameTests {
    private func contact(_ state: MultitouchState, x: Double = 0.5, y: Double = 0.5) -> MultitouchContact {
        MultitouchContact(state: state, position: TouchPoint(x: x, y: y))
    }

    @Test func emptyFrameIsALift() {
        #expect(TouchEvent(frame: []) == .lift)
    }

    @Test func hoveringAndDepartingFingersDoNotCount() {
        for state in [MultitouchState.notTracking, .startInRange, .hoverInRange, .breakTouch, .lingerInRange, .outOfRange] {
            #expect(TouchEvent(frame: [contact(state)]) == .lift, "\(state)")
        }
    }

    @Test func theFirstFingerOnTheGlassWins() {
        let frame = [contact(.hoverInRange, x: 0.1), contact(.makeTouch, x: 0.4), contact(.touching, x: 0.7)]
        #expect(TouchEvent(frame: frame) == .contact(TouchPoint(x: 0.4, y: 0.5)))
    }

    /// The raw record layout: state at byte 20 and the normalized position at 32, in 96-byte steps.
    @Test func decodesRawRecords() {
        let count = 2
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MultitouchFramework.touchStride * count, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: MultitouchFramework.touchStride * count)
        for (index, (state, x, y)) in [(Int32(2), Float(0.1), Float(0.2)), (4, 0.6, 0.7)].enumerated() {
            let record = buffer + index * MultitouchFramework.touchStride
            record.storeBytes(of: state, toByteOffset: 20, as: Int32.self)
            record.storeBytes(of: x, toByteOffset: 32, as: Float.self)
            record.storeBytes(of: y, toByteOffset: 36, as: Float.self)
        }
        let contacts = MultitouchFramework.contacts(in: buffer, count: count)
        #expect(contacts.map(\.state) == [.hoverInRange, .touching])
        #expect(contacts.map(\.position.x).map { ($0 * 10).rounded() } == [1, 6])
        #expect(TouchEvent(frame: contacts) == .contact(contacts[1].position))
        #expect(MultitouchFramework.contacts(in: nil, count: 3).isEmpty)
        #expect(MultitouchFramework.contacts(in: buffer, count: 0).isEmpty)
    }
}
