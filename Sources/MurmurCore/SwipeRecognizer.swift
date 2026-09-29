import Foundation

/// A point on the remote's touch surface in normalized coordinates: x runs left to right and
/// y bottom to top, both 0…1, as MultitouchSupport reports them.
struct TouchPoint: Equatable {
    var x: Double
    var y: Double
}

/// What one frame from the touch surface amounts to: where the finger is, or that it is gone.
enum TouchEvent: Equatable {
    case contact(TouchPoint)
    case lift
}

enum SwipeDirection: String, CaseIterable {
    case up, down, left, right

    var displayName: String {
        rawValue.capitalized
    }
}

/// Recognizes single-finger swipes. Pure: `step` maps a stroke state and a touch event to the next
/// state and at most one swipe. A stroke yields its swipe as soon as the finger has travelled
/// `minimumDistance` from where it landed, and nothing more until it lifts, so one flick is one
/// step through a menu however far it continues.
enum SwipeRecognizer {
    struct Thresholds: Equatable {
        /// Fraction of the surface the finger must travel along the dominant axis. Taps drift
        /// by a few hundredths; deliberate swipes cover 0.4 or more.
        var minimumDistance = 0.18
    }

    enum Stroke: Equatable {
        case idle
        case tracking(origin: TouchPoint)
        case recognized
    }

    static func step(
        _ stroke: Stroke,
        _ event: TouchEvent,
        thresholds: Thresholds = Thresholds()
    ) -> (stroke: Stroke, swipe: SwipeDirection?) {
        switch (stroke, event) {
        case (_, .lift):
            return (.idle, nil)
        case (.idle, .contact(let point)):
            return (.tracking(origin: point), nil)
        case (.tracking(let origin), .contact(let point)):
            guard let swipe = direction(from: origin, to: point, minimumDistance: thresholds.minimumDistance) else {
                return (stroke, nil)
            }
            return (.recognized, swipe)
        case (.recognized, .contact):
            return (stroke, nil)
        }
    }

    /// Every swipe in a sequence of events, starting idle.
    static func swipes(in events: [TouchEvent], thresholds: Thresholds = Thresholds()) -> [SwipeDirection] {
        events.reduce(into: (stroke: Stroke.idle, swipes: [SwipeDirection]())) { acc, event in
            let (stroke, swipe) = step(acc.stroke, event, thresholds: thresholds)
            acc.stroke = stroke
            acc.swipes += swipe.map { [$0] } ?? []
        }.swipes
    }

    /// The dominant axis of a displacement of at least `minimumDistance`; nil for anything shorter.
    /// A perfect diagonal counts as vertical, which is what menus want.
    static func direction(from origin: TouchPoint, to point: TouchPoint, minimumDistance: Double) -> SwipeDirection? {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        guard max(abs(dx), abs(dy)) >= minimumDistance else {
            return nil
        }
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .up : .down
    }
}

// MARK: - Multitouch frames

/// A contact's phase as MultitouchSupport reports it. Only `makeTouch` and `touching` carry a
/// finger on the glass; the rest are approach and departure.
enum MultitouchState: Int32 {
    case notTracking = 0
    case startInRange = 1
    case hoverInRange = 2
    case makeTouch = 3
    case touching = 4
    case breakTouch = 5
    case lingerInRange = 6
    case outOfRange = 7

    var isTouching: Bool {
        self == .makeTouch || self == .touching
    }
}

/// One contact in a multitouch frame, reduced to the fields swipe recognition reads.
struct MultitouchContact: Equatable {
    var state: MultitouchState
    var position: TouchPoint
}

extension TouchEvent {
    /// A frame is the first finger on the glass, or a lift when there is none. Extra fingers and
    /// hovering ones are ignored.
    init(frame contacts: [MultitouchContact]) {
        self = contacts.first(where: \.state.isTouching).map { .contact($0.position) } ?? .lift
    }
}
