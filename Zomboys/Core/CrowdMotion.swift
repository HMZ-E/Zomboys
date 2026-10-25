import Foundation

/// Shared physical and visual locomotion. The gait never jumps at one speed.
enum CrowdMotion {
    static let infectedCruiseSpeed = 5.6
    struct Gait {
        let idle: Double
        let walk: Double
        let run: Double
    }
    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
    }
    static func gait(at speed: Double) -> Gait {
        let moving = smooth((max(0, speed) - 0.03) / 0.87)
        let running = smooth((max(0, speed) - 1.8) / 1.7)
        return Gait(idle: 1 - moving, walk: moving * (1 - running), run: moving * running)
    }
    static func cycleLength(at speed: Double) -> Double { 1.2 + gait(at: speed).run }
    static func speed(from current: Double, toward desired: Double, dt: Double,
                      acceleration: Double, braking: Double) -> Double {
        guard dt.isFinite, dt > 0 else { return max(0, current) }
        let target = max(0, desired), rate = target > current ? acceleration : braking
        return max(0, current + min(max(target - current, -rate * dt), rate * dt))
    }
    static func heading(from current: Double, toward desired: Double, dt: Double, rate: Double) -> Double {
        let delta = atan2(sin(desired - current), cos(desired - current))
        return current + min(max(delta * min(1, dt * 8), -rate * dt), rate * dt)
    }
}

/// Retained near-camera people get a small preference, preventing detail flicker
/// as a dense crowd crosses the view. A dense view still keeps actual bodies.
enum CrowdDetailSelection {
    static func choose(_ candidates: [(id: Int, position: CGPoint)], previous: Set<Int>,
                       focus: CGPoint, budget: Int) -> Set<Int> {
        guard budget > 0 else { return [] }
        struct Rank { let id: Int; let distance: Double }
        var ranked: [Rank] = []
        ranked.reserveCapacity(candidates.count)
        for person in candidates {
            let dx = Double(person.position.x - focus.x)
            let dy = Double(person.position.y - focus.y)
            let weight: Double = previous.contains(person.id) ? 0.80 : 1.0
            ranked.append(Rank(id:person.id,distance:(dx*dx+dy*dy)*weight))
        }
        ranked.sort { left, right in
            if left.distance == right.distance { return left.id < right.id }
            return left.distance < right.distance
        }
        var selected = Set<Int>()
        for person in ranked.prefix(budget) { selected.insert(person.id) }
        return selected
    }
}
