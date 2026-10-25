import Foundation

/// A rectangular protected district closes every road crossing its boundary.
/// Solid city blocks already stop people; each road opening buys a real wall.
struct SafeZonePlan {
    let points: [CGPoint]
    let walls: [BarricadePlan]
    let cost: Int
    let civilianCount: Int
}

struct SafeZone: Identifiable {
    let id: Int
    let points: [CGPoint]
    let boundaryUnitIDs: [Int]

    func contains(_ point: CGPoint) -> Bool { TacticalGeometry.contains(point, in: points) }
}

enum TacticalMarkerKind: String { case casualty, breach }

/// Persistent, bounded after-action evidence. Nearby losses share one flag.
struct TacticalMarker: Identifiable {
    let id: Int
    let kind: TacticalMarkerKind
    let position: CGPoint
    let elapsed: Double
    var count: Int
}

enum TacticalGeometry {
    static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var result = false
        var previous = polygon.last!
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                result.toggle()
            }
            previous = current
        }
        return result
    }

    static func nearestPoint(to point: CGPoint, on path: [CGPoint]) -> CGPoint? {
        var nearest: CGPoint?
        var nearestSquared = Double.infinity
        for (a, b) in zip(path, path.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.000_001, dx * dx + dy * dy)))
            let candidate = CGPoint(x: a.x + dx * fraction, y: a.y + dy * fraction)
            let squared = pow(candidate.x - point.x, 2) + pow(candidate.y - point.y, 2)
            if squared < nearestSquared { nearest = candidate; nearestSquared = squared }
        }
        return nearest
    }

    static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let rx = b.x - a.x, ry = b.y - a.y
        let sx = d.x - c.x, sy = d.y - c.y
        let denominator = rx * sy - ry * sx
        guard abs(denominator) > 0.000_001 else { return nil }
        let t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / denominator
        let u = ((c.x - a.x) * ry - (c.y - a.y) * rx) / denominator
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return CGPoint(x: a.x + rx * t, y: a.y + ry * t)
    }
}
