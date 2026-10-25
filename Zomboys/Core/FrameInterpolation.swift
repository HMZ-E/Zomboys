import Foundation

/// The renderer runs at display cadence while street AI uses fixed, short steps.
/// A frame renders between the two most recent simulation poses instead of
/// repeatedly rebuilding or copying the full population into a new snapshot.
struct RenderMotionState {
    var position: CGPoint
    var heading: Double = 0
    var stride: Double = 0
    var speed: Double = 0
    var altitude: Double = 0
    var turretHeading: Double = 0
    var age: Double = 0
}

enum FrameInterpolation {
    static func fraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }

    static func angle(from start: Double, to end: Double, fraction value: Double) -> Double {
        start + atan2(sin(end - start), cos(end - start)) * fraction(value)
    }

    /// A running cycle always advances. At accelerated game speed it can cross
    /// more than pi in one AI tick, so the shortest angular path would make a
    /// runner's legs briefly reverse direction. Heading still uses `angle`.
    static func phase(from start: Double, to end: Double, fraction value: Double) -> Double {
        var advance = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        if advance < 0 { advance += 2 * .pi }
        return start + advance * fraction(value)
    }

    static func sample(previous: RenderMotionState?, current: RenderMotionState,
                       fraction value: Double) -> RenderMotionState {
        guard let previous else { return current }
        let amount = fraction(value)
        return RenderMotionState(
            position: CGPoint(x: previous.position.x + (current.position.x - previous.position.x) * amount,
                              y: previous.position.y + (current.position.y - previous.position.y) * amount),
            heading: angle(from: previous.heading, to: current.heading, fraction: amount),
            stride: phase(from: previous.stride, to: current.stride, fraction: amount),
            speed: previous.speed + (current.speed - previous.speed) * amount,
            altitude: previous.altitude + (current.altitude - previous.altitude) * amount,
            turretHeading: angle(from: previous.turretHeading, to: current.turretHeading, fraction: amount),
            age: previous.age + (current.age - previous.age) * amount)
    }
}

struct SimulationFramePlan {
    let steps: Int
    let interpolationFraction: Double
    let acceptedInterval: Double
}

/// Display-link jitter changes interpolation, not the size or number of tiny AI
/// passes. Inactive scenes reset this clock. A long foreground stall accepts at
/// most 100 ms so returning from a system interruption cannot spiral into a
/// multi-second catch-up on the main thread.
struct FixedSimulationClock {
    let stepDuration: Double
    let maximumFrameInterval: Double
    private(set) var interpolationFraction: Double = 0
    private(set) var accumulatedInterval: Double = 0
    private var previousTimestamp: Double?

    init(stepDuration: Double = 0.05, maximumFrameInterval: Double = 0.1) {
        precondition(stepDuration.isFinite && stepDuration > 0)
        precondition(maximumFrameInterval.isFinite && maximumFrameInterval >= stepDuration)
        self.stepDuration = stepDuration
        self.maximumFrameInterval = maximumFrameInterval
    }

    mutating func reset(at timestamp: Double? = nil) {
        previousTimestamp = timestamp?.isFinite == true ? timestamp : nil
        accumulatedInterval = 0
        interpolationFraction = 0
    }

    mutating func advance(to timestamp: Double) -> SimulationFramePlan {
        guard timestamp.isFinite else {
            return SimulationFramePlan(steps: 0, interpolationFraction: interpolationFraction, acceptedInterval: 0)
        }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return SimulationFramePlan(steps: 0, interpolationFraction: interpolationFraction, acceptedInterval: 0)
        }
        guard timestamp >= previousTimestamp else {
            return SimulationFramePlan(steps: 0, interpolationFraction: interpolationFraction, acceptedInterval: 0)
        }
        self.previousTimestamp = timestamp
        let accepted = min(maximumFrameInterval, timestamp - previousTimestamp)
        accumulatedInterval += accepted
        let steps = Int(floor((accumulatedInterval + 0.000_000_001) / stepDuration))
        accumulatedInterval = max(0, accumulatedInterval - Double(steps) * stepDuration)
        interpolationFraction = FrameInterpolation.fraction(accumulatedInterval / stepDuration)
        return SimulationFramePlan(steps: steps, interpolationFraction: interpolationFraction, acceptedInterval: accepted)
    }
}
