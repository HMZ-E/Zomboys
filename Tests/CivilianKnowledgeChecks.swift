import Foundation

/// Stable social-perception fixtures on real, unobstructed city streets.
/// Holding positions isolates the conversation timer from walking into sign range.
@MainActor
func runCivilianKnowledgeChecks() -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAILED: \(message)") }
        checks += 1
    }
    for city in CityScenario.allCases {
        let game = GameEngine(city: city, defaults: nil, missionSeed: 34567)
        let map = game.map, scale = map.metersToWorld
        var street: (CGPoint, CGPoint)?
        search: for road in map.roads {
            for (a, b) in zip(road.points, road.points.dropFirst()) {
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > scale * 110 else { continue }
                func point(_ metres: Double) -> CGPoint {
                    CGPoint(x: a.x + (b.x - a.x) * scale * metres / length,
                            y: a.y + (b.y - a.y) * scale * metres / length)
                }
                let start = point(5), end = point(105)
                guard map.isRoad(start), map.isRoad(end), !map.containsBuilding(start),
                      !map.containsBuilding(end), map.hasLineOfSight(from: start, to: end) else { continue }
                street = (start, end); break search
            }
        }
        guard let (start, end) = street else { fatalError("No social street in \(city)") }
        let length = hypot(end.x - start.x, end.y - start.y)
        func point(_ metres: Double) -> CGPoint {
            CGPoint(x: start.x + (end.x - start.x) * scale * metres / length,
                    y: start.y + (end.y - start.y) * scale * metres / length)
        }
        game.selectTool(.evacuation); game.tap(at: start)
        guard let station = game.units.first else { fatalError("EVAC deployment failed") }
        game.movementTestConfigure(civilians: [Civilian(id: 100, position: point(60)),
                                              Civilian(id: 101, position: point(68))],
                                   zombies: [], destination: end, units: [station])
        expect(game.civilians.allSatisfy { map.isRoad($0.position) && !map.containsBuilding($0.position) }, "\(city): social fixture uses real road surfaces")
        expect(map.hasLineOfSight(from: station.position, to: point(60)) &&
               map.hasLineOfSight(from: point(60), to: point(68)), "\(city): teacher sees signs and neighbor sees teacher")
        func run(until time: Double) {
            while game.elapsed < time - 0.000001 { game.movementTestKnowledge(dt: min(0.05, time - game.elapsed)) }
        }
        run(until: 0.7)
        expect(game.civilians.allSatisfy { $0.evacuationID == nil }, "\(city): signs require sustained discovery")
        run(until: 2)
        expect(game.civilians[0].evacuationID == station.id && game.civilians[0].evacuationLearnedFrom == nil, "\(city): teacher learns directly from local signage")
        expect(game.civilians[1].evacuationID == nil && game.civilians[1].followingID == nil, "\(city): outside sign range, neighbor cannot relay immediately")
        run(until: 3.5)
        expect(game.civilians[1].followingID == 100 && game.civilians[1].evacuationID == nil, "\(city): learner follows an informed person before conversation completes")
        run(until: 6)
        expect(game.civilians[1].evacuationID == station.id && game.civilians[1].evacuationLearnedFrom == 100 && game.civilians[1].evacuationAwareness == 1, "\(city): delayed conversation records the actual teacher and correct station")
        expect(game.civilians[0].evacuationLearnedFrom == nil, "\(city): knowledge does not circulate back as a self-informing chain")
        game.selectTool(nil); game.tap(at: station.position); game.removeSelected()
        run(until: 6.7)
        expect(game.units.isEmpty && game.civilians.allSatisfy { $0.evacuationID == nil && $0.evacuationLearnedFrom == nil && $0.followingID == nil && $0.evacuationAwareness < 1 }, "\(city): closing the station invalidates direct/social directions and leaders")
    }
    return checks
}
