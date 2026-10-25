import Foundation

@main
struct TacticalPlanningTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        func unit(_ id: Int, _ kind: UnitKind, at position: CGPoint, path: [CGPoint] = []) -> DefenseUnit {
            DefenseUnit(id: id, kind: kind, position: position, targetPosition: nil, health: kind.maxHealth,
                        maxHealth: kind.maxHealth, range: kind.range, cooldown: 0, barrierPath: path, purchaseCost: kind.cost)
        }
        func fixture(_ map: CityMap) -> (CGPoint, CGPoint) {
            for road in map.roads {
                for (a, b) in zip(road.points, road.points.dropFirst()) where distance(a, b) > map.metersToWorld * 50 {
                    let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    if map.isRoad(midpoint), !map.containsBuilding(midpoint), map.hasLineOfSight(from: a, to: b) { return (midpoint, b) }
                }
            }
            fatalError("No road fixture")
        }

        for city in CityScenario.allCases {
            let game = GameEngine(city: city, defaults: nil, missionSeed: 98_765)
            let scale = game.map.metersToWorld, (point, roadEnd) = fixture(game.map)
            let heading = atan2(roadEnd.y - point.y, roadEnd.x - point.x)
            func offset(_ metres: Double, across: Double = 0) -> CGPoint {
                CGPoint(x: point.x + cos(heading) * scale * metres - sin(heading) * scale * across,
                        y: point.y + sin(heading) * scale * metres + cos(heading) * scale * across)
            }
            let wall = unit(50, .barricade, at: point, path: [offset(0, across: -20), offset(0, across: 20)])
            game.tacticalTestConfigure(units: [wall])
            expect(game.movementBlocked(from: offset(-1), to: offset(1), forCivilians: true), "\(city): an ungated paid wall stops civilians")
            expect(game.placeGate(at: point), "\(city): gate attaches to the drawn wall")
            expect(game.budget == 5_000 - UnitKind.gate.cost, "\(city): gate costs money exactly once")
            expect(game.units.last?.linkedBarrierID == wall.id, "\(city): gate links to the correct perimeter")
            expect(!game.movementBlocked(from: offset(-1), to: offset(1), forCivilians: true), "\(city): aperture is passable to civilians")
            expect(game.movementBlocked(from: offset(-1), to: offset(1)), "\(city): the same gate keeps zombies out")
            expect(!game.placeGate(at: point), "\(city): duplicate aperture cannot double-purchase")
            expect(game.tacticalTestGateAllows(100, from: offset(-1), to: point), "\(city): first civilian admitted")
            expect(!game.tacticalTestGateAllows(101, from: offset(-1), to: point), "\(city): second civilian queues instead of overlapping")
            let gateID = game.units.first(where: { $0.kind == .gate })!.id
            game.selectTool(nil); game.tap(at: point)
            expect(game.selectedUnitID == gateID, "\(city): a normal aperture tap inspects the gate before its older parent wall")
            game.tacticalTestSetPhase(.running)
            let beforeWithdrawal = game.budget
            game.removeSelected()
            expect(game.units.count == 2 && game.budget == beforeWithdrawal && game.selectedUnitID == gateID, "\(city): combat gate withdrawal cannot refund or magically reseal the wall")
            game.tacticalTestSetPhase(.paused)
            game.removeSelected()
            expect(game.units.count == 2 && game.budget == beforeWithdrawal, "\(city): tactical pause cannot bypass the active-gate withdrawal guard")
            game.tacticalTestSetPhase(.planning)
            game.removeSelected()
            expect(game.units.count == 1 && game.units.first?.id == wall.id && game.budget == 5_000 && game.movementBlocked(from: offset(-1), to: offset(1), forCivilians: true), "\(city): planning gate removal refunds the gate and restores the paid solid wall")
            expect(game.placeGate(at: point), "\(city): gate may be rebuilt before combat")
            let rebuiltGateID = game.units.first(where: { $0.kind == .gate })!.id
            game.tacticalTestDamageUnit(rebuiltGateID)
            expect(game.units.isEmpty && !game.movementBlocked(from: offset(-1), to: offset(1)), "\(city): destroying the gate also destroys its parent wall and opens zombie passage")
            game.tacticalTestConfigure(units: [wall])
            expect(game.placeGate(at: point), "\(city): parent-wall breach fixture has a linked gate")
            game.tacticalTestDamageUnit(wall.id)
            expect(!game.units.contains { $0.kind == .gate }, "\(city): breached wall removes linked gate hardware")
            expect(game.tacticalMarkers.contains { $0.kind == .breach }, "\(city): a persistent breach flag records the failure")
            game.tacticalTestConfigure(civilians: [Civilian(id: 100, position: offset(-6)), Civilian(id: 101, position: offset(-8))], units: [wall])
            expect(game.placeGate(at: point), "\(city): a real traffic gate can be installed")
            game.tacticalTestRouteCivilian(100, to: offset(15)); game.tacticalTestRouteCivilian(101, to: offset(15))
            for _ in 0..<700 { game.tacticalTestStep(dt: 0.05, moveResidents: true) }
            expect(game.civilians.allSatisfy { ($0.position.x - point.x) * cos(heading) + ($0.position.y - point.y) * sin(heading) > scale * 4 }, "\(city): queued residents actually cross the gate and release it for the next person")
            game.tacticalTestConfigure(units: [wall])
            game.selectTool(.mine); game.tap(at: offset(10))
            expect(game.units.count == 2 && game.units.last?.kind == .mine && game.budget == 5_000 - UnitKind.mine.cost, "\(city): explicit mine placement near a wall is not swallowed by wall inspection")
            let mineID = game.units.last!.id, beforeMineTap = game.budget
            game.tap(at: game.units.last!.position)
            expect(game.selectedUnitID == mineID && game.units.count == 2 && game.budget == beforeMineTap, "\(city): tapping an existing same-kind mine inspects it instead of charging twice")
            game.selectTool(.c4); game.tap(at: offset(18))
            expect(game.units.count == 3 && game.units.last?.kind == .c4, "\(city): explicit C4 placement near walls and mines keeps the requested tool")
            let chargeID = game.units.last!.id, beforeChargeTap = game.budget
            game.tap(at: game.units.last!.position)
            expect(game.selectedUnitID == chargeID && game.units.count == 3 && game.budget == beforeChargeTap, "\(city): a normal same-kind C4 tap exposes the manual detonation selection")

            // The full rectangle transaction contains actual street closures;
            // affordability and overlap reject the whole plan atomically.
            var safePlan: SafeZonePlan?
            var from = game.map.initialFocus, to = from
            for size in [100.0, 180, 260, 360] where safePlan == nil {
                from = CGPoint(x: game.map.initialFocus.x - size * scale, y: game.map.initialFocus.y - size * scale)
                to = CGPoint(x: game.map.initialFocus.x + size * scale, y: game.map.initialFocus.y + size * scale)
                safePlan = game.safeZonePlan(from: from, to: to)
            }
            guard let plan = safePlan else { fatalError("No real city perimeter fixture in \(city)") }
            game.tacticalTestConfigure(budget: plan.cost - 1)
            expect(!game.drawSafeZone(from: from, to: to) && game.units.isEmpty && game.budget == plan.cost - 1, "\(city): unaffordable safe zone is atomic")
            game.tacticalTestConfigure(units: [unit(80, .squad, at: plan.walls[0].points[0])])
            expect(!game.drawSafeZone(from: from, to: to) && game.units.count == 1 && game.budget == 5_000, "\(city): overlapping safe zone is atomic")
            let inside = CGPoint(x: (plan.points[0].x + plan.points[2].x) / 2, y: (plan.points[0].y + plan.points[2].y) / 2)
            game.tacticalTestConfigure(civilians: [Civilian(id: 100, position: inside), Civilian(id: 101, position: CGPoint(x: 20, y: 20))])
            expect(game.drawSafeZone(from: from, to: to), "\(city): valid safe zone creates every closure")
            expect(game.units.count == plan.walls.count && game.budget == 5_000 - plan.cost, "\(city): every perimeter section is paid")
            let zoneID = game.safeZones[0].id
            expect(game.safeZoneOccupancy(zoneID) == 1 && game.isSafeZoneIntact(zoneID), "\(city): occupancy counts actual residents inside the polygon")
            game.tacticalTestDuplicateSafeZone()
            expect(game.shelteredCivilianCount == 1, "\(city): overlapping protected districts never double-count one resident")
            game.tacticalTestDamageUnit(game.safeZones[0].boundaryUnitIDs[0])
            expect(!game.isSafeZoneIntact(zoneID), "\(city): a single lost crossing invalidates containment")

            let infected = Zombie(id: 200, position: offset(1), health: 60, herdID: 7)
            game.tacticalTestConfigure(zombies: [infected], units: [unit(60, .squad, at: point)], phase: .running)
            for _ in 0..<27 { game.tacticalTestStep(dt: 0.05) }
            expect(game.crewCount(for: 60) == 5, "\(city): soldier bites need sustained physical contact")
            for _ in 0..<3 { game.tacticalTestStep(dt: 0.05) }
            expect(game.crewCount(for: 60) == 4 && game.zombies.count == 2, "\(city): an actually bitten soldier turns and reduces team strength")
            expect(game.casualties == 0 && game.zombies.last?.herdID == 7, "\(city): military conversion does not invent civilian casualties")
            game.tacticalTestConfigure(zombies: [infected], units: [unit(60, .humvee, at: point)], phase: .running)
            for _ in 0..<40 { game.tacticalTestStep(dt: 0.05) }
            expect(game.zombies.count == 1, "\(city): an armored Humvee cannot become infected")
            game.tacticalTestConfigure(zombies: [Zombie(id: 200, position: offset(-0.6), health: 60)], units: [wall, unit(60, .mortar, at: offset(0.6))], phase: .running)
            for _ in 0..<40 { game.tacticalTestStep(dt: 0.05) }
            expect(game.crewCount(for: 60) == 2 && game.zombies.count == 1, "\(city): infantry cannot be bitten through a barricade")

            game.tacticalTestConfigure(civilians: [Civilian(id: 100, position: point)], zombies: [], units: [unit(70, .mine, at: point)], phase: .running)
            game.tacticalTestStep(dt: 3)
            expect(game.units.count == 1 && game.casualties == 0, "\(city): civilians do not trigger mines")
            var mine = unit(70, .mine, at: point); mine.cooldown = 2
            game.tacticalTestConfigure(civilians: [Civilian(id: 100, position: offset(5))], zombies: [infected], units: [mine], phase: .running)
            game.tacticalTestStep(dt: 1)
            expect(game.units.count == 1 && game.kills == 0, "\(city): freshly placed mine has a real arming delay")
            game.tacticalTestStep(dt: 1.1)
            expect(game.units.isEmpty && game.kills == 1 && game.earnedMoney == GameBalance.killIncome, "\(city): armed mine triggers once and pays actual kills")
            expect(game.casualties == 1 && game.tacticalMarkers.contains { $0.kind == .casualty }, "\(city): mine collateral kills civilians and leaves evidence")
            let c4 = unit(71, .c4, at: point)
            game.tacticalTestConfigure(zombies: [infected], units: [c4])
            expect(!game.detonateAllC4() && game.units.count == 1, "\(city): C4 cannot detonate during planning")
            game.tacticalTestSetPhase(.paused)
            expect(game.detonateAllC4() && game.units.isEmpty && game.kills == 1, "\(city): C4 manually detonates while tactical pause is active")
            expect(!game.detonateAllC4(), "\(city): spent C4 cannot be used twice")

            // Armed residents must stay in the exact civilian accounting ledger
            // when bitten: active + mobilized + saved + casualties = population.
            game.tacticalTestConfigure(civilians: [Civilian(id: 100, position: point)], zombies: [infected], phase: .paused)
            expect(game.performSupport(.callToArms, at: point), "\(city): resident can be mobilized")
            expect(game.mobilizedCivilianCount == 1 && game.civilians.isEmpty, "\(city): mobilization transfers one actual resident")
            for _ in 0..<30 { game.tacticalTestStep(dt: 0.05) }
            expect(game.mobilizedCivilianCount == 0 && game.casualties == 1 && game.zombies.count == 2, "\(city): bitten armed resident converts exactly once")
            expect(game.civilians.count + game.mobilizedCivilianCount + game.saved + game.casualties == game.initialPopulation, "\(city): resident conversion preserves population accounting")

            // Real city roofs change cost and line of sight; destroy the host and
            // the sniper disappears rather than floating above cleared terrain.
            // Select a real roof beside a real street. The first tall building
            // in an OSM extract may be an enormous parcel whose center is far
            // from a road; that cannot exercise the nearby-unit tap regression.
            let host = game.map.buildings.indices.first { index in
                let building = game.map.buildings[index]
                let center = CGPoint(x: building.rect.midX, y: building.rect.midY)
                guard building.height > scale * 8, building.rect.width > 10, building.rect.height > 10,
                      TacticalGeometry.contains(center, in: building.footprint) else { return false }
                let street = game.map.nearestRoadPoint(to: center)
                return distance(street, center) < 26 && game.map.isRoad(street) && !game.map.containsBuilding(street)
            }
            guard let host else { fatalError("No real furnished roof beside a street in \(city)") }
            do {
                let building = game.map.buildings[host], roof = CGPoint(x: building.rect.midX, y: building.rect.midY)
                game.tacticalTestConfigure()
                let cost = game.sniperPlacementCost(at: roof)
                game.selectTool(.sniper); game.tap(at: roof)
                expect(game.units.first?.hostBuildingID == host && game.units.first?.elevation == building.height, "\(city): sniper occupies the actual tapped roof")
                if building.rect.width > 10 && building.rect.height > 10, let placed = game.units.first {
                    let vent = CGRect(x: building.rect.midX - min(6, building.rect.width * 0.22) / 2,
                                      y: building.rect.midY - min(6, building.rect.height * 0.22) / 2,
                                      width: min(6, building.rect.width * 0.22), height: min(6, building.rect.height * 0.22))
                    expect(placed.formation.allSatisfy { !vent.contains($0) && TacticalGeometry.contains($0, in: building.footprint) }, "\(city): actual roof crew avoid the modeled central vent")
                }
                expect(game.budget == 5_000 - cost && cost >= UnitKind.sniper.cost && (game.units.first?.range ?? 0) > UnitKind.sniper.range, "\(city): roof area affects price and height improves range")
                let sniperID = game.units.first!.id, beforeRoofTap = game.budget
                game.selectTool(.sniper); game.tap(at: roof)
                expect(game.selectedUnitID == sniperID && game.units.count == 1 && game.budget == beforeRoofTap, "\(city): tapping a deployed sniper's roof inspects it instead of buying a duplicate")
                if let roofUnit = game.units.first {
                    var checkedOcclusion = false
                    for blocker in game.map.buildings.indices where blocker != host && !checkedOcclusion {
                        let b = game.map.buildings[blocker], target = CGPoint(x: b.rect.midX, y: b.rect.midY)
                        if distance(roof, target) < 500 {
                            expect(!game.defenseHasLineOfSight(roofUnit, from: roof, to: target), "\(city): a rooftop sniper cannot shoot through an intact target building")
                            checkedOcclusion = true
                        }
                    }
                    expect(checkedOcclusion, "\(city): real intervening roof fixture was inspected")
                }
                game.tacticalTestExplosion(at: roof, radius: scale * 35, damage: 5_000)
                expect(game.destroyedBuildingIDs.contains(host) && game.units.isEmpty, "\(city): host collapse removes the rooftop team")
                let nearbyStreet = game.map.nearestRoadPoint(to: roof)
                expect(distance(nearbyStreet, roof) < 26 && game.map.isRoad(nearbyStreet), "\(city): the roof has a real nearby street-team fixture")
                game.tacticalTestConfigure(units: [unit(99, .squad, at: nearbyStreet)])
                game.selectTool(.sniper); game.tap(at: roof)
                expect(game.units.count == 2 && game.units.contains(where: { $0.id == 99 && $0.kind == .squad }) && game.units.contains(where: { $0.kind == .sniper && $0.hostBuildingID == host }) && game.budget == 5_000 - cost, "\(city): an explicit roof order deploys above a nearby street team without replacing it or double charging")
            }

            // A finger may land on a footprint even though charge placement
            // snaps onto its adjacent street. Repeating that exact tap must
            // select the snapped charge, not attempt another purchase.
            let offRoadTap = game.map.buildings.compactMap { building -> CGPoint? in
                let center = CGPoint(x: building.rect.midX, y: building.rect.midY)
                guard center.x > 10, center.y > 10, center.x < game.map.worldSize - 10, center.y < game.map.worldSize - 10,
                      TacticalGeometry.contains(center, in: building.footprint),
                      !game.map.isRoad(center), !game.map.containsWater(center) else { return nil }
                let snapped = game.map.nearestRoadPoint(to: center)
                guard distance(center, snapped) > scale * 3, game.map.isRoad(snapped), !game.map.containsBuilding(snapped) else { return nil }
                return center
            }.first
            guard let offRoadTap else { fatalError("No off-road footprint tap beside a real street in \(city)") }
            let snappedTap = game.map.nearestRoadPoint(to: offRoadTap)
            expect(distance(offRoadTap, snappedTap) > scale * 3, "\(city): raw charge tap is farther than the physical inspection radius from its street projection")
            for kind in [UnitKind.mine, .c4] {
                game.tacticalTestConfigure()
                game.selectTool(kind); game.tap(at: offRoadTap)
                expect(game.units.count == 1 && game.units.first?.kind == kind && game.units.first?.position == snappedTap && game.budget == 5_000 - kind.cost, "\(city): an off-road \(kind.shortTitle) tap buys one charge at the actual projected street position")
                let existingID = game.units.first!.id, paidBudget = game.budget
                game.tap(at: offRoadTap)
                expect(game.selectedUnitID == existingID && game.selectedTool == nil && game.units.count == 1 && game.budget == paidBudget, "\(city): repeating the identical off-road \(kind.shortTitle) tap selects the snapped charge without another fee")
            }
            game.tacticalTestConfigure()
            for index in 0..<140 { game.tacticalTestRecordMarker(at: CGPoint(x: Double(index % 14) * scale * 30 + 20, y: Double(index / 14) * scale * 30 + 20)) }
            expect(game.tacticalMarkers.count == 96, "\(city): after-action flags are bounded for mobile rendering")
            game.reset(city: city)
            expect(game.safeZones.isEmpty && game.tacticalMarkers.isEmpty, "\(city): retry clears previous tactical state")
        }
        print("PASS: \(checks) tactical planning, gates, explosives, bite and rooftop checks")
    }
}
