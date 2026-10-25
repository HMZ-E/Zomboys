import Foundation
import Darwin

/// Standalone release-mode checks exercise actual gameplay APIs and bundled city data.
@main
struct CoreTests {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--social") { print("PASS: \(runCivilianKnowledgeChecks()) controlled social checks"); return }
        if CommandLine.arguments.contains("--benchmark") { benchmarkSimulation(); return }
        var checks = 0
        @inline(never) func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { print("FAILED: \(description)"); fflush(stdout); fatalError("FAILED: \(description)") }
            checks += 1
            if checks % 25 == 0 { print("CHECK \(checks): \(description)"); fflush(stdout) }
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        @inline(never) func game(_ seed: UInt64? = nil) -> GameEngine { GameEngine(city: .settat, defaults: nil, missionSeed: seed) }
        expect(CityScenario.allCases == [.settat, .casablanca], "only Settat and Casablanca remain playable")
        for removed in ["newYork", "paris", "losAngeles", "venice"] {
            expect(CityScenario(rawValue: removed) == nil, "removed \(removed) cannot load as a playable operation")
        }
        /// Select real connected street geometry instead of schematic coordinates.
        func straightStreet(in map: CityMap, length: Double) -> (CGPoint, CGPoint) {
            for road in map.roads {
                for (start, end) in zip(road.points, road.points.dropFirst()) {
                    let distance = hypot(end.x - start.x, end.y - start.y)
                    guard distance > length + 20, (0...map.worldSize).contains(start.x), (0...map.worldSize).contains(start.y), (0...map.worldSize).contains(end.x), (0...map.worldSize).contains(end.y), !map.containsBuilding(start), !map.containsBuilding(end) else { continue }
                    let a = CGPoint(x: start.x + (end.x - start.x) * 10 / distance, y: start.y + (end.y - start.y) * 10 / distance)
                    let b = CGPoint(x: a.x + (end.x - start.x) * length / distance, y: a.y + (end.y - start.y) * length / distance)
                    let route = map.path(from: a, to: b)
                    let actual = zip(route, route.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
                    if abs(actual - length) < 0.01 { return (a, b) }
                }
            }
            fatalError("Bundled \(map.city.title) contains no suitable connected straight street")
        }
        func separatedStreetPosts(in map: CityMap, count: Int) -> [CGPoint] {
            var posts: [CGPoint] = []
            for point in map.navigationNodes where map.coreBounds.contains(point) && !map.containsBuilding(point) {
                if posts.allSatisfy({ hypot($0.x - point.x, $0.y - point.y) > 55 }) { posts.append(point) }
                if posts.count == count { return posts }
            }
            fatalError("Bundled city has too few separate valid deployment positions")
        }
        @inline(never) func deploy(_ game: GameEngine, _ kind: UnitKind, at point: CGPoint) {
            game.selectTool(kind); game.tap(at: point)
        }
        @inline(never) func run(_ game: GameEngine, until time: Double) {
            while game.elapsed + 0.000_001 < time && !game.phase.isFinished {
                let before = game.elapsed
                game.tick(dt: min(0.25, time - game.elapsed))
                if game.elapsed == before { fatalError("Stalled test clock at \(before), target \(time), phase \(game.phase)") }
            }
        }
        @inline(never) func nearEntry(_ game: GameEngine, offset: Double = 90) -> CGPoint {
            let entry = game.arrivals[0].position
            let direction = game.map.roadDirection(at: entry)
            return game.map.nearestRoadPoint(to: CGPoint(x: entry.x + direction.dx * offset, y: entry.y + direction.dy * offset))
        }
        @inline(never) func select(_ game: GameEngine, unit: DefenseUnit) {
            game.selectTool(nil); game.tap(at: unit.position)
        }
        /// Plays a complete operation using only placements and orders available in the app.
        /// No actor state is injected: approaches are defended with paid ground teams,
        /// kill income funds later defenses, and mobile trucks clean up any breaches.
        @inline(never) func playDefense(_ game: GameEngine) {
            func defend(_ arrival: HerdArrival) {
                let direction = game.map.roadDirection(at: arrival.position)
                let sniper = game.map.nearestRoadPoint(to: CGPoint(
                    x: arrival.position.x + direction.dx * 85,
                    y: arrival.position.y + direction.dy * 85))
                deploy(game, .sniper, at: sniper)
                let mortar = game.map.nearestRoadPoint(to: CGPoint(
                    x: arrival.position.x + direction.dx * 150,
                    y: arrival.position.y + direction.dy * 150))
                deploy(game, .mortar, at: mortar)
            }
            let approaches = game.arrivals.reduce(into: [HerdArrival]()) { result, arrival in
                if !result.contains(where: { distance($0.position, arrival.position) < 50 }) { result.append(arrival) }
            }
            var defended: Set<Int> = []
            for arrival in approaches.prefix(2) {
                defend(arrival)
                defended.insert(arrival.id)
            }
            deploy(game, .evacuation, at: game.map.initialFocus)
            game.start()
            var nextOrder = 0.0
            while !game.phase.isFinished && game.elapsed < 1100 {
                if game.elapsed >= nextOrder {
                    nextOrder += 1
                    for arrival in approaches where !defended.contains(arrival.id) && arrival.arrivesAt - game.elapsed < 20 && game.budget >= 520 {
                        defend(arrival)
                        defended.insert(arrival.id)
                    }
                    let samples = game.zombies.enumerated().filter { $0.offset % max(1, game.zombies.count / 60) == 0 }.map(\.element)
                    let concentrations = samples.map { zombie in
                        (zombie, game.zombies.filter { distance(zombie.position, $0.position) < 100 }.count)
                    }
                    if let enemy = concentrations.max(by: { $0.1 < $1.1 })?.0,
                       !game.units.contains(where: { $0.kind.isCombat && distance($0.position, enemy.position) < 140 }),
                       game.budget >= UnitKind.humvee.cost {
                        let direction = game.map.roadDirection(at: enemy.position)
                        deploy(game, .humvee, at: game.map.nearestRoadPoint(to: CGPoint(
                            x: enemy.position.x + direction.dx * 80,
                            y: enemy.position.y + direction.dy * 80)))
                    }
                    if game.elapsed > game.arrivals.last!.arrivesAt + 15 {
                        for vehicle in game.units.filter({ $0.kind == .humvee && $0.targetPosition == nil }) {
                            if let enemy = game.zombies.min(by: { distance($0.position, vehicle.position) < distance($1.position, vehicle.position) }),
                               distance(enemy.position, vehicle.position) > 100 {
                                select(game, unit: vehicle)
                                game.moveSelected(to: enemy.position)
                            }
                        }
                    }
                    if game.budget < UnitKind.humvee.cost, game.emergencyAvailable {
                        _ = game.claimEmergencyReserve()
                        game.togglePause()
                    }
                }
                game.tick(dt: 0.25)
            }
        }
        let began = Date()
        let lightDefault = GameEngine(defaults: nil)
        expect(lightDefault.city == .settat && lightDefault.initialPopulation == 360 && lightDefault.budget == 2000, "compact Settat is the default operation with lighter population and its own resources")
        expect(lightDefault.map.worldSize == 3200 && (1000..<5000).contains(lightDefault.map.buildings.count), "Settat keeps real city buildings in a compact world with a much smaller dataset")
        expect(lightDefault.map.navigationNodes.count < 10000 && lightDefault.map.roads.count > 2000, "Settat retains connected real OSM roads at a fraction of the Casablanca network size")
        expect(lightDefault.map.landmarks.count == 6 && lightDefault.map.landmarks.contains { $0.kind == .kasbah } && lightDefault.map.landmarks.contains { $0.kind == .university }, "Settat contains the Kasbah, university and four other bespoke landmarks")
        expect(lightDefault.map.sourceAttribution.contains("OpenStreetMap") && lightDefault.map.buildings.allSatisfy { $0.height > 0 && $0.footprint.count >= 3 }, "Settat retains source attribution and complete 3D footprint metadata")
        expect(lightDefault.arrivals.allSatisfy { !lightDefault.map.urbanBounds.contains($0.sourcePosition) }, "Settat herds originate beyond the actual city and university envelope")
        expect(lightDefault.stagedHerdMembers.allSatisfy { !lightDefault.map.urbanBounds.contains($0.position) }, "the entire assembled Settat mass starts outside the city rather than appearing between its buildings")
        let defaultGame = GameEngine(city: .casablanca, defaults: nil)
        expect(defaultGame.initialPopulation == 720 && defaultGame.budget == 2400, "Casablanca starts with its own population and resources")
        expect(defaultGame.map.worldSize == 8000 && defaultGame.map.buildings.count > 40_000, "Casablanca loads the detailed whole-city footprint dataset")
        expect(defaultGame.map.navigationNodes.count > 60_000 && defaultGame.map.roads.count > 30_000, "Casablanca streets use the bundled OSM network")
        expect(defaultGame.map.landmarks.count >= 10 && defaultGame.map.landmarks.contains { $0.kind == .mosque && $0.height > 40 }, "major Casablanca landmarks have bespoke 3D metadata")
        expect(defaultGame.map.buildings.allSatisfy { $0.height > 0 && $0.footprint.count >= 3 }, "every Casablanca building has a height and polygon footprint")
        expect(defaultGame.map.sourceAttribution.contains("OpenStreetMap"), "city source attribution is retained")
        expect(defaultGame.arrivals.count == 6 && defaultGame.zombies.isEmpty, "Casablanca begins with six incoming herds and no instant outbreak")
        expect(defaultGame.arrivals.allSatisfy { !defaultGame.map.coreBounds.contains($0.sourcePosition) && defaultGame.map.isRoad($0.sourcePosition) && !defaultGame.map.containsWater($0.sourcePosition) }, "all Casablanca columns originate on connected exterior land roads beyond the central urban sector")
        expect(defaultGame.arrivals.allSatisfy { $0.sourcePosition != $0.position && $0.travelDistance > 25 && $0.arrivesAt > $0.departureAt }, "exterior staging and city ingress are different locations with travel-aware ETAs")
        expect(defaultGame.arrivals.allSatisfy { (560...2000).contains($0.size) } && defaultGame.arrivals.contains { $0.size > 1800 }, "Casablanca includes much larger finite exterior herds, including nearly two thousand individuals")
        expect(defaultGame.map.metersToWorld == 0.235, "Casablanca actors share the real building meters-to-world scale")
        let casaSeed = defaultGame.missionSeed
        let casaPopulation = defaultGame.civilians.map(\.position)
        defaultGame.reset(city: .casablanca)
        expect(defaultGame.missionSeed == casaSeed && defaultGame.civilians.map(\.position) == casaPopulation, "Casablanca retry repeats the same civilian placement")
        defaultGame.start(); run(defaultGame, until: 1)
        expect(defaultGame.civilians.allSatisfy { defaultGame.map.isRoad($0.position, tolerance: 0.1) }, "Casablanca civilians move on its real street graph")
        run(defaultGame, until: defaultGame.arrivals[0].arrivesAt + 8)
        expect(!defaultGame.zombies.isEmpty && defaultGame.zombies.allSatisfy { defaultGame.map.isRoad($0.position, tolerance: 0.1) }, "Casablanca flock routes and lane positions stay on narrow real-world streets")

        expect(UnitKind.allCases.count == 13, "the roster includes safe zones, gates, mines and remote C4 alongside the existing forces")
        for old in ["garrison", "turret", "airstrike", "helicopter"] { expect(UnitKind(rawValue: old) == nil, "removed \(old) is absent from the roster") }
        expect(UnitKind.squad.damage == 12 && UnitKind.squad.cost == 90 && UnitKind.humvee.isMobile, "infantry is inexpensive and modest; the Humvee is mobile")
        expect(UnitKind.sniper.range > UnitKind.humvee.range && UnitKind.sniper.reloadTime > 1.5 && UnitKind.sniper.damage >= 60, "snipers offer long clear sightlines and slow precise lethal shots")
        let losMap = game().map
        // Real OSM footprints are rotated and irregular. Query an actual wall
        // edge and its outward normal rather than a bounding-box corner.
        let wallFixture: (index: Int, start: CGPoint, end: CGPoint, clearStart: CGPoint, clearEnd: CGPoint) = {
            for (index, building) in losMap.buildings.enumerated() where building.rect.width > 25 && building.rect.height > 25 {
                let footprint = building.footprint
                for edge in footprint.indices {
                    let a = footprint[edge], b = footprint[(edge + 1) % footprint.count]
                    let length = distance(a, b)
                    guard length > 12 else { continue }
                    let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    var normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
                    if losMap.distanceToBuilding(at: index, from: CGPoint(x: middle.x + normal.x, y: middle.y + normal.y)) == 0 {
                        normal.x = -normal.x; normal.y = -normal.y
                    }
                    let outside = CGPoint(x: middle.x + normal.x, y: middle.y + normal.y)
                    let inside = CGPoint(x: middle.x - normal.x * 2, y: middle.y - normal.y * 2)
                    let clearA = CGPoint(x: a.x + (b.x - a.x) * 0.15 + normal.x * 2, y: a.y + (b.y - a.y) * 0.15 + normal.y * 2)
                    let clearB = CGPoint(x: b.x - (b.x - a.x) * 0.15 + normal.x * 2, y: b.y - (b.y - a.y) * 0.15 + normal.y * 2)
                    if abs(losMap.distanceToBuilding(at: index, from: outside) - 1) < 0.001,
                       !losMap.hasLineOfSight(from: outside, to: inside), losMap.hasLineOfSight(from: clearA, to: clearB) {
                        return (index, outside, inside, clearA, clearB)
                    }
                }
            }
            fatalError("No real building wall suitable for visibility and blast regression")
        }()
        let opaque = losMap.buildings[wallFixture.index]
        let blockedStart = wallFixture.start, blockedEnd = wallFixture.end
        expect(!losMap.hasLineOfSight(from: blockedStart, to: blockedEnd) && !losMap.hasLineOfSight(from: blockedEnd, to: blockedStart), "actual footprint intersections block front and rear shots symmetrically")
        let clearStart = wallFixture.clearStart, clearEnd = wallFixture.clearEnd
        expect(losMap.hasLineOfSight(from: clearStart, to: clearEnd), "a visible line beside the same building stays clear")
        expect(losMap.hasLineOfSight(from: clearStart, to: clearStart), "zero-length visibility queries outside an obstacle remain valid")
        let demolition = game()
        let buildingID = demolition.map.buildings.firstIndex { $0.rect == opaque.rect }!
        let blastCenter = blockedEnd
        expect(demolition.map.buildingIndices(near: blockedStart, radius: 2).contains(buildingID), "blast indexing includes the wall of a large footprint even when its center is outside the blast")
        expect(abs(demolition.map.distanceToBuilding(at: buildingID, from: blockedStart) - 1) < 0.001, "blast falloff measures the actual wall rather than the building center")
        expect(!demolition.hasLineOfSight(from: blockedStart, to: blockedEnd), "an intact building blocks shots before bombardment")
        demolition.start(); run(demolition, until: 18.01)
        deploy(demolition, .b2, at: blastCenter)
        expect(demolition.buildingDamage.isEmpty && demolition.destroyedBuildingIDs.isEmpty, "ordering a bomber does not destroy buildings before bomb impact")
        run(demolition, until: 27)
        expect(demolition.destroyedBuildingIDs.contains(buildingID) && demolition.buildingDamage[buildingID] == 1, "a real B-2 blast destroys the hit building and records persistent normalized structural damage")
        expect(demolition.hasLineOfSight(from: blockedStart, to: blockedEnd), "demolished footprints stop blocking a direct firing line")
        let ruins = demolition.destroyedBuildingIDs
        demolition.tick(dt: 0.25)
        expect(ruins.isSubset(of: demolition.destroyedBuildingIDs), "ruins survive subsequent gameplay updates")
        demolition.reset(city: .settat)
        expect(demolition.destroyedBuildingIDs.isEmpty && demolition.buildingDamage.isEmpty && !demolition.hasLineOfSight(from: blockedStart, to: blockedEnd), "retry restores buildings and their original occlusion")
        let landmarkDemolition = GameEngine(city: .settat, defaults: nil)
        let kasbahID = landmarkDemolition.map.landmarks.firstIndex { $0.kind == .kasbah }!
        let kasbah = landmarkDemolition.map.landmarks[kasbahID]
        expect(landmarkDemolition.map.distanceToLandmark(at: kasbahID, from: kasbah.position) == 0, "custom landmark blast queries include the actual structure's interior")
        landmarkDemolition.start(); run(landmarkDemolition, until: 18.01)
        deploy(landmarkDemolition, .b2, at: kasbah.position)
        run(landmarkDemolition, until: 27)
        expect(landmarkDemolition.destroyedLandmarkIDs.contains(kasbahID) && landmarkDemolition.landmarkDamage[kasbahID] == 1, "real bomber impacts also destroy a bespoke 3D Settat landmark")
        let footprint = landmarkDemolition.map.landmarkFootprint(at: kasbahID)
        let west = CGPoint(x: footprint.map(\.x).min()! - 0.1, y: kasbah.position.y)
        let east = CGPoint(x: footprint.map(\.x).max()! + 0.1, y: kasbah.position.y)
        let otherLandmarks = Set(landmarkDemolition.map.landmarks.indices.filter { $0 != kasbahID })
        let allBuildings = Set(landmarkDemolition.map.buildings.indices)
        expect(!landmarkDemolition.map.hasLineOfSight(from: west, to: east, excludingBuildings: allBuildings, excludingLandmarks: otherLandmarks) && landmarkDemolition.map.hasLineOfSight(from: west, to: east, excludingBuildings: allBuildings, excludingLandmarks: landmarkDemolition.destroyedLandmarkIDs.union(otherLandmarks)), "collapsed landmark IDs remove their parcel from visibility occlusion")
        // Exercise health and shell outcomes, not just the visibility helper:
        // these are real deployed weapons firing at an unmodified seeded herd.
        let blockedFire = game(34567)
        blockedFire.start(); run(blockedFire, until: blockedFire.arrivals[0].arrivesAt + 5)
        let hiddenPost = blockedFire.map.navigationNodes.first { post in
            blockedFire.zombies.contains { target in
                (10...UnitKind.sniper.range - 4).contains(distance(post, target.position)) && !blockedFire.map.hasLineOfSight(from: post, to: target.position)
            }
        }!
        deploy(blockedFire, .sniper, at: hiddenPost)
        let sniperLaunch = blockedFire.units[0].formation[0]
        let concealed = blockedFire.zombies.filter { distance($0.position, sniperLaunch) < UnitKind.sniper.range - 4 && !blockedFire.map.hasLineOfSight(from: sniperLaunch, to: $0.position) }
        expect(!concealed.isEmpty && concealed.allSatisfy { !blockedFire.map.hasLineOfSight(from: sniperLaunch, to: $0.position) }, "a real Settat street position has concealed enemies within sniper range")
        let concealedHealth = Dictionary(uniqueKeysWithValues: concealed.map { ($0.id, $0.health) })
        blockedFire.tick(dt: 0.05)
        expect(blockedFire.zombies.filter { concealedHealth[$0.id] != nil }.allSatisfy { $0.health == concealedHealth[$0.id] }, "snipers leave unseen enemies unharmed despite being in firing range")
        select(blockedFire, unit: blockedFire.units[0]); blockedFire.removeSelected()
        deploy(blockedFire, .sniper, at: blockedFire.zombies[0].position)
        let beforeVisibleKill = blockedFire.kills
        blockedFire.tick(dt: 0.05)
        expect(blockedFire.kills > beforeVisibleKill && blockedFire.effects.contains { $0.kind == .shot }, "the same sniper weapon kills a visible target from an open street")

        let indirectFire = game(34567)
        indirectFire.start(); run(indirectFire, until: indirectFire.arrivals[0].arrivesAt + 5)
        let mortarPost = indirectFire.map.navigationNodes.first { post in
            let targets = indirectFire.zombies.filter { distance($0.position, post) < UnitKind.mortar.range - 4 }
            guard let nearest = targets.min(by: { distance($0.position, post) < distance($1.position, post) }) else { return false }
            return !indirectFire.hasLineOfSight(from: post, to: nearest.position)
        } ?? { fatalError("The seeded real Settat herd lacks a covered mortar firing position") }()
        deploy(indirectFire, .mortar, at: mortarPost)
        indirectFire.tick(dt: 0.05)
        expect(indirectFire.projectiles.contains { $0.kind == .mortar && !indirectFire.map.hasLineOfSight(from: $0.launch, to: $0.target) }, "mortars launch an indirect shell over a building that blocks direct fire")
        expect(indirectFire.kills == 0 && indirectFire.zombies.allSatisfy { $0.health == 60 }, "an obscured mortar target is unharmed until the shell arrives")
        run(indirectFire, until: indirectFire.elapsed + 3.1)
        expect(indirectFire.kills > 0, "indirect mortar shells damage the hidden herd only after their ballistic flight")
        let plan = game()
        expect(plan.phase == .planning && plan.zombies.isEmpty && plan.civilians.count == plan.city.population, "planning starts frozen with civilians and incoming threats")
        expect(plan.arrivals.count == 4 && plan.pendingHerdCount == 4, "smaller city missions have four finite incoming herds")
        expect((20...35).contains(plan.arrivals[0].departureAt) && plan.arrivals[0].arrivesAt > plan.arrivals[0].departureAt, "exterior columns depart after a preparation window and arrive after road travel")
        expect(zip(plan.arrivals, plan.arrivals.dropFirst()).allSatisfy { $0.arrivesAt < $1.arrivesAt }, "arrival ETAs are strictly increasing")
        expect(plan.arrivals.allSatisfy { plan.map.isRoad($0.position, tolerance: 0.1) && $0.size >= 24 }, "incoming herds have meaningful sizes on road approaches")
        expect(zip(plan.arrivals, plan.arrivals.dropFirst()).allSatisfy { $0.position != $1.position }, "consecutive herds arrive from different roads")
        let initialCivilians = plan.civilians.map(\.position)
        let initialETAs = plan.arrivals.map(\.arrivesAt)
        plan.tick(dt: 1)
        expect(plan.elapsed == 0 && plan.civilians.map(\.position) == initialCivilians, "planning cannot advance actors or the ETA clock")
        plan.reset(city: .settat)
        expect(plan.civilians.map(\.position) == initialCivilians && plan.arrivals.map(\.arrivesAt) == initialETAs, "retry preserves both population and randomized arrival schedule")
        plan.reset(city: .settat, missionSeed: 99999)
        expect(plan.missionSeed == 99999 && plan.arrivals.map(\.arrivesAt) != initialETAs, "explicit mission seed can start a fresh city operation")
        let priorSeed = plan.missionSeed
        plan.newOutbreak()
        expect(plan.missionSeed != priorSeed && plan.arrivals.map(\.arrivesAt) != initialETAs, "new outbreak rolls a new schedule")
        let rerolled = plan.arrivals.map(\.arrivesAt)
        plan.reset(city: .settat)
        expect(plan.arrivals.map(\.arrivesAt) == rerolled, "retry also preserves a rerolled mission")
        let sameA = game(34567), sameB = game(34567)
        expect(sameA.arrivals.map(\.arrivesAt) == sameB.arrivals.map(\.arrivesAt) && sameA.civilians.map(\.position) == sameB.civilians.map(\.position), "explicit seeds reproduce the full initial state")
        let firstETA = sameA.arrivals[0].arrivesAt
        let stagedFirst = sameA.stagedHerdMembers.filter { $0.herdID == sameA.arrivals[0].id }
        expect(stagedFirst.count == sameA.arrivals[0].size && stagedFirst.count >= 560, "the complete first incoming mass already exists visibly during planning")
        expect(stagedFirst.allSatisfy { sameA.map.isRoad($0.position, tolerance: 0.1) && !sameA.map.containsBuilding($0.position) }, "pre-existing columns fill navigable exterior roads without appearing inside buildings")
        let stagedBounds = stagedFirst.reduce(CGRect.null) { $0.union(CGRect(x: $1.position.x, y: $1.position.y, width: 0.01, height: 0.01)) }
        expect(max(stagedBounds.width, stagedBounds.height) > sameA.map.metersToWorld * 40, "the first herd occupies a long street frontage rather than a single spawn point")
        let stagedIdentity = Dictionary(uniqueKeysWithValues: stagedFirst.map { ($0.id, $0.position) })
        sameA.start(); run(sameA, until: sameA.arrivals[0].departureAt - 0.01)
        expect(sameA.zombies.isEmpty && sameA.arrivals[0].releasedCount == 0 && sameA.phase == .running, "planning warning and outside departure are separate from city ingress")
        run(sameA, until: sameA.arrivals[0].departureAt + 0.5)
        expect(sameA.arrivals[0].releasedCount == sameA.arrivals[0].size && sameA.zombies.count >= 560, "hundreds of pre-existing dispersed bodies begin moving together as one large mass")
        expect(sameA.zombies.allSatisfy { stagedIdentity[$0.id] != nil && distance($0.position, stagedIdentity[$0.id]!) < sameA.map.metersToWorld * 6 }, "activation preserves body identity and exact staging locations without fountain spawning")
        expect(sameA.stagedHerdMembers.allSatisfy { $0.herdID != sameA.arrivals[0].id }, "active bodies are removed from the dormant render snapshot exactly once")
        run(sameA, until: firstETA - 0.001)
        expect(sameA.phase == .running && !sameA.zombies.isEmpty && sameA.pendingHerdCount == 4, "exterior columns travel before the city-ingress ETA and cannot trigger an early win")
        sameA.tick(dt: 0.01)
        expect(sameA.pendingHerdCount == 3 && sameA.arrivals[0].releasedCount > 0, "city-ingress ETA advances once while members release in a staged column")
        expect(sameA.audioEvents.contains { $0.cue == .warningAlarm } && sameA.audioEvents.contains { $0.cue == .herdArrival }, "herd approach and arrival emit distinct sound cues")
        let spawnedCount = sameA.zombies.count
        sameA.tick(dt: 0.05)
        expect(sameA.zombies.count >= spawnedCount && sameA.arrivals[0].releasedCount <= sameA.arrivals[0].size, "a column releases only its finite scheduled population")
        let enemyPositions = Dictionary(uniqueKeysWithValues: sameA.zombies.map { ($0.id, $0.position) })
        sameA.tick(dt: 0.05)
        expect(sameA.zombies.filter { enemyPositions[$0.id] != nil }.allSatisfy { distance($0.position, enemyPositions[$0.id]!) < 2 }, "flocking remains continuous rather than teleporting")
        expect(Set(sameA.zombies.map { Int(($0.lateralOffset * 10).rounded()) }).count > 3, "herd members occupy varied street lanes instead of one perfect line")
        run(sameA, until: firstETA + 15)
        expect(sameA.zombies.allSatisfy { sameA.map.isRoad($0.position, tolerance: 0.1) }, "messy flocking is constrained to navigable streets")
        expect(sameA.casualties < sameA.initialPopulation / 2 && sameA.phase == .running, "the first arrival leaves an adaptation window")
        expect(sameA.budget == sameA.city.startingBudget && sameA.kills == 0, "unopposed time gives no passive money or fictional kills")
        expect(sameA.saved + sameA.casualties + sameA.civilians.count == sameA.initialPopulation, "spread conserves civilians")
        expect(sameA.zombies.allSatisfy { $0.speed <= sameA.map.metersToWorld * 11.001 && $0.heading.isFinite && (0..<Double.pi * 2).contains($0.stride) }, "zombie snapshots expose bounded physical speed, continuous heading and cyclic stride")
        expect(sameA.zombies.contains { $0.stride > 0 && $0.speed > 0 }, "actual zombie travel advances gait animation")
        run(sameA, until: sameA.arrivals[0].departureAt + sameA.arrivals[0].releaseDuration + 0.3)
        expect(sameA.arrivals[0].releasedCount == sameA.arrivals[0].size, "every member of a finite first column is eventually released exactly once")
        expect(sameA.zombies.count <= sameA.activeZombieLimit && sameA.arrivals.allSatisfy { $0.releasedCount <= $0.size }, "streaming has a hard active population bound without overflowing scheduled sizes")

        let exteriorStrike = game(34567)
        let futureHerd = exteriorStrike.arrivals.last!
        let futureBodies = exteriorStrike.stagedHerdMembers.filter { $0.herdID == futureHerd.id }
        let strikeTarget = futureBodies[futureBodies.count / 2].position
        let stagedBeforeStrike = Set(futureBodies.map(\.id))
        exteriorStrike.start(); run(exteriorStrike, until: 18.01)
        deploy(exteriorStrike, .b2, at: strikeTarget)
        run(exteriorStrike, until: 27)
        let survivingTail = Set(exteriorStrike.stagedHerdMembers.filter { $0.herdID == futureHerd.id }.map(\.id))
        expect(survivingTail.count < stagedBeforeStrike.count && exteriorStrike.kills > 0 && exteriorStrike.earnedMoney == exteriorStrike.kills * GameBalance.killIncome, "a paid bomber can kill visible dormant exterior members and pay real kill income before their departure")
        expect(exteriorStrike.arrivals.last!.releasedCount == 0 && exteriorStrike.phase != .won, "destroying an exterior tail cannot trigger victory while other scheduled bodies remain")

        let saturated = game(998)
        saturated.start()
        var peakInfected = 0
        while !saturated.phase.isFinished && saturated.elapsed < 240 {
            saturated.tick(dt: 0.25)
            peakInfected = max(peakInfected, saturated.zombies.count)
        }
        expect(peakInfected <= saturated.activeZombieLimit && peakInfected >= 560, "all incoming and newly infected bodies obey the same hard active AI population cap")
        expect(saturated.phase != .won && saturated.stagedHerdMembers.count > 0, "a crowded unopposed battlefield preserves its exterior reserves without false victory or silently discarded members")

        let (placementStart, placementEnd) = straightStreet(in: game().map, length: 195)
        let placement = CGPoint(x: (placementStart.x + placementEnd.x) / 2, y: (placementStart.y + placementEnd.y) / 2)
        for kind in UnitKind.allCases where !kind.isAirSupport && kind != .safeZone && kind != .gate {
            let tool = game()
            deploy(tool, kind, at: placement)
            expect(tool.units.count == 1 && tool.units[0].kind == kind, "\(kind.title) deploys through the gameplay API")
            expect(tool.budget == tool.city.startingBudget - kind.cost, "\(kind.title) spends the precise price")
            let unit = tool.units[0]
            tool.tap(at: unit.position)
            expect(tool.units.count == 1 && tool.selectedUnitID == unit.id, "\(kind.title) overlapping taps select without another charge")
            tool.removeSelected()
            expect(tool.units.isEmpty && tool.budget == tool.city.startingBudget, "\(kind.title) planning withdrawal refunds its actual purchase")
        }
        for kind in [UnitKind.ac130, .b2, .a10] {
            let air = game()
            deploy(air, kind, at: air.map.initialFocus)
            expect(air.flights.isEmpty && air.budget == air.city.startingBudget, "\(kind.title) cannot launch during planning")
            air.start(); deploy(air, kind, at: air.map.initialFocus)
            expect(air.flights.isEmpty && air.aircraftReadyIn(kind) == 18, "\(kind.title) observes the initial response window")
            run(air, until: 18.01)
            deploy(air, kind, at: air.civilians[0].position)
            expect(air.flights.count == 1 && air.flights[0].kind == kind && air.budget == air.city.startingBudget - kind.cost, "\(kind.title) creates a paid visible flight")
            expect(air.sortiesRemaining(kind) == 2 && air.aircraftReadyIn(kind) > 35, "\(kind.title) consumes sortie inventory and rearms")
            let money = air.budget
            deploy(air, kind, at: air.map.initialFocus)
            expect(air.flights.count == 1 && air.budget == money, "\(kind.title) cannot double-charge during a live sortie")
            let original = air.flights[0].position
            air.tick(dt: 0.25)
            expect(distance(air.flights[0].position, original) > 1 && air.flights[0].altitude > 40, "\(kind.title) actually flies above the map")
            if kind == .b2 {
                run(air, until: 25.0)
                expect(air.casualties > 0, "a badly aimed B-2 causes real civilian casualties")
                expect(!air.buildingDamage.isEmpty && !air.destroyedBuildingIDs.isEmpty, "the same bomber blast damages and destroys buildings around its civilian victims")
                expect(air.projectiles.count > 0 || air.effects.contains { $0.kind == .explosion }, "B-2 bombs descend before producing blast effects")
                run(air, until: 31)
                expect(air.flights.isEmpty, "B-2 leaves after its committed pass")
            } else if kind == .a10 {
                run(air, until: 25)
                expect(air.audioEvents.contains { $0.cue == .a10Burst }, "the GAU-8 strafing phase emits synchronized BRRRT cues")
                expect(air.flights[0].ammo < 540, "A-10 consumes finite cannon ammunition during its run")
                run(air, until: 31)
                expect(air.flights.isEmpty, "A-10 departs after its strafing pass")
            } else {
                air.cycleAC130WeaponMode()
                expect(air.ac130WeaponMode == .cannon105 && air.flights[0].weaponMode == .cannon105, "AC-130 changes the live aircraft cannon mode")
                let target = CGPoint(x: air.map.initialFocus.x + 80, y: air.map.initialFocus.y + 80)
                let oldPosition = air.flights[0].position
                air.retargetAC130(at: target)
                expect(air.flights[0].target == target && air.flights[0].position == oldPosition, "retargeting updates the orbit target without teleporting")
                run(air, until: 65)
                expect(air.flights.isEmpty, "AC-130 eventually returns to base")
            }
        }
        for kind in [UnitKind.ac130, .b2, .a10] {
            let combatAir = game()
            combatAir.start(); run(combatAir, until: combatAir.arrivals[0].arrivesAt + 0.05)
            let group = combatAir.zombies
            let target = CGPoint(x: group.reduce(0) { $0 + $1.position.x } / Double(group.count),
                                 y: group.reduce(0) { $0 + $1.position.y } / Double(group.count))
            let direction = combatAir.map.roadDirection(at: target)
            combatAir.setAttackHeading(atan2(direction.dy, direction.dx))
            deploy(combatAir, kind, at: target)
            let callTime = combatAir.elapsed
            run(combatAir, until: callTime + 10)
            expect(combatAir.kills > 0, "\(kind.title) destroys zombies during its real firing pass")
            expect(combatAir.earnedMoney == combatAir.kills * 12 && combatAir.budget == combatAir.city.startingBudget - kind.cost + combatAir.earnedMoney, "\(kind.title) air kills pay exactly once")
            if kind == .ac130 {
                expect(combatAir.flights[0].ammo < 180 && combatAir.audioEvents.contains { $0.cue == .ac130Cannon30 }, "AC-130 side-mounted 30 mm fire consumes ammunition")
                combatAir.setAirWeaponMode(.cannon105)
                run(combatAir, until: callTime + 14)
                expect(combatAir.audioEvents.contains { $0.cue == .ac130Cannon105 }, "AC-130 105 mm mode launches delayed explosive cannon shells")
            }
        }
        let orbitA = game(), orbitB = game()
        for orbit in [orbitA, orbitB] { orbit.start(); run(orbit, until: 18.01); deploy(orbit, .ac130, at: orbit.map.initialFocus) }
        orbitA.cycleAttackHeading()
        run(orbitA, until: 25); run(orbitB, until: 25)
        expect(orbitA.flights[0].position == orbitB.flights[0].position && orbitA.flights[0].heading == orbitB.flights[0].heading, "new aircraft pass directions do not alter an AC-130 already orbiting")
        let orbit = orbitA.flights[0]
        let towardCenter = CGPoint(x: orbit.target.x - orbit.position.x, y: orbit.target.y - orbit.position.y)
        expect(towardCenter.x * sin(orbit.heading) - towardCenter.y * cos(orbit.heading) > 200, "AC-130 port-side guns face inward during its left-hand orbit")
        let retargetBudget = orbitA.budget
        deploy(orbitA, .ac130, at: CGPoint(x: orbit.target.x + 90, y: orbit.target.y))
        expect(orbitA.flights.count == 1 && orbitA.budget == retargetBudget && orbitA.flights[0].target.x == orbit.target.x + 90, "an active AC-130 map tap retargets without paying for another sortie")
        let directionGame = game()
        directionGame.cycleAttackHeading()
        expect(abs(directionGame.attackHeading - .pi / 4) < 0.001, "direction control rotates planned passes by forty-five degrees")
        directionGame.setAttackHeading(.pi / 2)
        expect(directionGame.attackHeading == .pi / 2, "air attack direction can be selected explicitly")
        directionGame.setAttackHeading(.nan)
        expect(directionGame.attackHeading == .pi / 2, "nonfinite attack headings are rejected")

        // Every ground weapon must produce damage; mortar damage happens only at impact.
        for kind in [UnitKind.squad, .humvee, .mortar, .sniper] {
            let weapon = game()
            deploy(weapon, kind, at: nearEntry(weapon))
            expect(weapon.units.count == 1, "\(kind.title) can defend a herd approach")
            let deployedWeapon = weapon.units[0]
            if kind == .squad { expect(weapon.units[0].formation.count == 5 && Set(weapon.units[0].formation.map { "\($0.x),\($0.y)" }).count == 5, "a squad contains five separate soldier positions") }
            weapon.start()
            if kind == .mortar {
                while weapon.projectiles.isEmpty && weapon.elapsed < weapon.arrivals[0].arrivesAt + 30 { weapon.tick(dt: 0.05) }
            } else { run(weapon, until: weapon.arrivals[0].arrivesAt + 0.05) }
            if kind == .mortar {
                expect(!weapon.projectiles.isEmpty, "mortar fire launches a visible airborne shell")
                expect(weapon.kills == 0 && weapon.zombies.allSatisfy { $0.health == 60 }, "mortar launch does not apply immediate damage")
                let shell = weapon.projectiles[0]
                expect(shell.duration >= 1.2 && shell.arcHeight > 80 && shell.altitude >= 0, "mortar shells have flight time and a real ballistic arc")
            }
            run(weapon, until: max(weapon.elapsed + 8, weapon.arrivals[0].arrivesAt + 25))
            expect(weapon.kills > 0 || weapon.zombies.contains { $0.health < 60 }, "\(kind.title) damages enemies in actual combat")
            expect(weapon.earnedMoney == weapon.kills * 12 && weapon.budget == weapon.city.startingBudget - kind.cost + weapon.earnedMoney, "\(kind.title) kills credit exactly twelve dollars once")
            expect(weapon.audioEvents.contains { $0.cue == (kind == .squad ? .rifle : (kind == .mortar ? .mortarLaunch : (kind == .sniper ? .sniper : .heavyGun))) }, "\(kind.title) emits its weapon sound")
            if kind != .mortar {
                var visibleRays = true
                for _ in 0..<80 {
                    weapon.tick(dt: 0.05)
                    visibleRays = visibleRays && weapon.effects.filter { $0.kind == .shot }.allSatisfy { effect in
                        guard let target = effect.endPosition else { return false }
                        return weapon.map.hasLineOfSight(from: effect.position, to: target)
                    }
                }
                expect(visibleRays, "\(kind.title) every emitted direct-fire ray obeys building visibility")
            }
            if kind == .squad || kind == .sniper {
                let cue: AudioCue = kind == .squad ? .rifle : .sniper
                expect(weapon.audioEvents.filter { $0.cue == cue }.allSatisfy { $0.variant == deployedWeapon.soundVariant && $0.sourceID == deployedWeapon.id }, "\(kind.title) sound events retain the deployment profile and source identity after combat, including a destroyed team")
            }
        }
        let mortarArc = CombatProjectile(id: 1, kind: .mortar, launch: .zero, target: CGPoint(x: 100, y: 0), age: 1, duration: 2, arcHeight: 90, radius: 10, damage: 10, civilianRadius: 0)
        expect(mortarArc.position == CGPoint(x: 50, y: 0) && abs(mortarArc.altitude - 90) < 0.001, "mortar trajectory reaches its apex halfway through flight")
        let fallingBomb = CombatProjectile(id: 2, kind: .bomb, launch: .zero, target: CGPoint(x: 10, y: 20), age: 2, duration: 2, arcHeight: 85, radius: 10, damage: 10, civilianRadius: 0)
        expect(fallingBomb.position == fallingBomb.target && fallingBomb.altitude == 0, "a falling bomb reaches ground at its target")

        let vehicle = game()
        let (roadA, roadB) = straightStreet(in: vehicle.map, length: 195)
        deploy(vehicle, .humvee, at: roadA)
        select(vehicle, unit: vehicle.units[0])
        expect(vehicle.setPatrol(through: [roadA, roadB]), "a Humvee accepts a player-drawn street patrol")
        expect(!vehicle.units[0].holding && vehicle.units[0].patrolWaypoints.count == 2, "patrol state is visible to the renderer")
        vehicle.start(); run(vehicle, until: 3)
        expect(distance(vehicle.units[0].position, roadA) > vehicle.map.metersToWorld * 45 && vehicle.map.isRoad(vehicle.units[0].position, tolerance: 0.1), "the Humvee drives along roads rather than staying a static turret")
        vehicle.holdSelected()
        let holding = vehicle.units[0].position
        run(vehicle, until: 4)
        expect(vehicle.units[0].position == holding && vehicle.units[0].holding, "hold stops the patrol")
        expect(!vehicle.setPatrol(through: [roadA]), "a one-point patrol is rejected")
        let denseStroke = (0...80).map { sample in CGPoint(x: roadA.x + (roadB.x - roadA.x) * Double(sample) / 80, y: roadA.y + (roadB.y - roadA.y) * Double(sample) / 80) }
        expect(vehicle.setPatrol(through: denseStroke) && distance(vehicle.units[0].patrolWaypoints.last!, roadB) < 0.000_001, "dense touch sampling preserves the full patrol stroke")
        let blocked = game()
        deploy(blocked, .humvee, at: roadA)
        let vehicleID = blocked.units[0].id
        let roadMiddle = CGPoint(x: (roadA.x + roadB.x) / 2, y: (roadA.y + roadB.y) / 2)
        expect(blocked.drawBarricade(through: [roadMiddle]), "a roadblock can be built across the patrol route")
        select(blocked, unit: blocked.units.first { $0.id == vehicleID }!)
        blocked.start(); blocked.moveSelected(to: roadB); run(blocked, until: 30)
        expect(distance(blocked.units.first { $0.id == vehicleID }!.position, roadA) < distance(roadMiddle, roadA), "a Humvee stops before an intact barricade")

        let drawn = game()
        let wallPlan = drawn.barricadePlan(through: [roadA, roadB])!
        expect(abs(wallPlan.length - 195) < 0.01 && wallPlan.cost == 160 && wallPlan.modules == 4, "drawn barricades quote proportional cost")
        expect(wallPlan.points.allSatisfy { drawn.map.isRoad($0, tolerance: 0.1) }, "wall vertices follow road geometry")
        expect(drawn.drawBarricade(through: [roadA, roadB]), "a valid street stroke builds one wall")
        expect(drawn.units.count == 1 && drawn.units[0].maxHealth == 1280 && drawn.budget == drawn.city.startingBudget - wallPlan.cost, "one drawn wall has finite durability proportional to purchased length")
        expect(!drawn.drawBarricade(through: [roadA, roadB]) && drawn.budget == drawn.city.startingBudget - wallPlan.cost, "overlapping wall rejection is atomic")
        drawn.selectTool(nil); drawn.tap(at: roadA)
        expect(drawn.selectedUnitID == drawn.units[0].id, "any point along a wall can select it")
        drawn.removeSelected()
        expect(drawn.units.isEmpty && drawn.budget == drawn.city.startingBudget, "planning refunds a full multi-module wall")
        let longRoute = drawn.map.path(from: drawn.map.herdApproaches[0].source, to: drawn.map.nearestRoadPoint(to: drawn.map.initialFocus))
        expect(zip(longRoute, longRoute.dropFirst()).reduce(0.0) { $0 + distance($1.0, $1.1) } > 300, "the maximum-wall test uses a real route longer than the purchase cap")
        let capped = drawn.barricadePlan(through: longRoute)!
        expect(abs(capped.length - 300) < 0.01 && capped.cost == 200, "long strokes stop at the maximum purchasable wall length")
        let coastalWall = GameEngine(city: .casablanca, defaults: nil)
        let openWater = CityMap.casaPoint(latitude: 33.65, longitude: -7.72)
        expect(coastalWall.map.containsWater(openWater) && !coastalWall.map.isRoad(openWater), "the sea placement test targets real open Atlantic water")
        expect(coastalWall.barricadePlan(through: [openWater]) == nil, "open-water barricade strokes are rejected")
        deploy(coastalWall, .squad, at: openWater)
        expect(coastalWall.units.isEmpty && coastalWall.budget == coastalWall.city.startingBudget, "open water cannot accept a ground squad")
        deploy(drawn, .squad, at: roadA)
        expect(drawn.units.count == 1 && drawn.map.isRoad(drawn.units[0].position) && !drawn.map.containsWater(drawn.units[0].position), "real road surfaces accept ground units")

        let attacked = game()
        let entry = attacked.arrivals[0].position
        expect(attacked.drawBarricade(through: [entry]), "a perimeter wall can defend an incoming herd")
        attacked.start()
        while attacked.units.first?.health == attacked.units.first?.maxHealth && attacked.elapsed < attacked.arrivals[0].arrivesAt + 60 { attacked.tick(dt: 0.05) }
        expect(!attacked.units.isEmpty, "wall is inspected at first real contact before its larger wave can break it")
        expect(attacked.units[0].health < attacked.units[0].maxHealth, "zombies attack finite barricade durability")
        select(attacked, unit: attacked.units[0]); attacked.togglePause()
        let repairCost = attacked.selectedRepairCost, beforeRepair = attacked.budget
        expect(repairCost > 0 && attacked.repairSelected(), "damaged barricades can be repaired during a regroup")
        expect(attacked.units[0].health == attacked.units[0].maxHealth && attacked.budget == beforeRepair - repairCost, "repair pays a quoted fee and restores durability")
        expect(!attacked.repairSelected(), "a pristine barricade cannot charge another repair fee")
        attacked.togglePause(); run(attacked, until: attacked.elapsed + 90)
        expect(attacked.units.isEmpty, "sustained herd attack eventually breaks a barricade")

        let movement = game()
        deploy(movement, .squad, at: roadA); select(movement, unit: movement.units[0])
        movement.moveSelected(to: roadB)
        expect(distance(movement.units[0].position, roadB) < 0.000_001 && movement.units[0].targetPosition == nil, "planning movement is immediate")
        movement.start(); movement.moveSelected(to: roadA); movement.tick(dt: 0.25)
        expect(distance(movement.units[0].position, roadB) > 0.001 && movement.map.isRoad(movement.units[0].position, tolerance: 0.1), "live squad movement follows roads")
        movement.togglePause()
        let paused = movement.units[0].position, pausedTime = movement.elapsed
        movement.tick(dt: 0.25)
        expect(movement.units[0].position == paused && movement.elapsed == pausedTime, "pause freezes actors and all timers")
        movement.setSpeed(); movement.togglePause(); movement.tick(dt: 0.25)
        expect(abs(movement.elapsed - pausedTime - 0.5) < 0.001, "two-times speed advances exactly twice as much simulation time")
        movement.setSpeed(); expect(movement.speed == 3, "speed cycles to three-times")
        movement.setSpeed(); expect(movement.speed == 1, "speed cycles back to normal")
        movement.tick(dt: .nan); movement.tick(dt: -.infinity)
        expect(movement.elapsed.isFinite, "invalid frame deltas cannot corrupt the clock")
        let jitter = game(); jitter.start()
        jitter.tick(dt: 0.0501)
        expect(jitter.simulationStepCount == 1 && abs(jitter.elapsed - 0.0501) < 0.000_000_001, "a jittered 20 Hz frame performs one full simulation pass without dropping its remainder")
        jitter.setSpeed(3)
        let jitterBefore = jitter.elapsed, passesBefore = jitter.simulationStepCount
        jitter.tick(dt: 0.0501)
        expect(jitter.simulationStepCount - passesBefore == 3 && abs(jitter.elapsed - jitterBefore - 0.1503) < 0.000_000_001, "the same jittered frame at three-times speed performs three passes and preserves 150.3 ms")
        let delayedBefore = jitter.elapsed, delayedPasses = jitter.simulationStepCount
        jitter.tick(dt: 0.25)
        expect(jitter.simulationStepCount - delayedPasses == 15 && abs(jitter.elapsed - delayedBefore - 0.75) < 0.000_000_001, "a delayed accelerated frame still uses bounded short steps and the complete accepted interval")
        jitter.togglePause()
        let pausedPasses = jitter.simulationStepCount
        jitter.tick(dt: 0.0501)
        expect(jitter.simulationStepCount == pausedPasses, "paused frames perform no AI or collision passes")
        jitter.reset(city: .settat)
        expect(jitter.simulationStepCount == 0 && jitter.elapsed == 0, "retry clears the simulation clock and profiling pass counter")
        movement.removeSelected()
        expect(movement.budget == movement.city.startingBudget - UnitKind.squad.cost + UnitKind.squad.cost / 3, "live withdrawal recovers one third of paid squad cost")
        let fixed = game(); deploy(fixed, .sniper, at: roadA); select(fixed, unit: fixed.units[0]); fixed.moveSelected(to: roadB)
        expect(distance(fixed.units[0].position, roadA) < 0.000_001 && fixed.units[0].targetPosition == nil, "fixed snipers cannot move")
        let extraction = game(); deploy(extraction, .evacuation, at: extraction.civilians[0].position); extraction.start(); run(extraction, until: 1)
        expect(extraction.saved > 0 && extraction.audioEvents.contains { $0.cue == .civilianRescue }, "evacuation actually rescues civilians with a sound cue")
        expect(extraction.saved + extraction.casualties + extraction.civilians.count == extraction.initialPopulation && extraction.earnedMoney == 0, "evacuation conserves civilians and does not regenerate money")

        let exhausted = game()
        let affordableSnipers = exhausted.city.startingBudget / UnitKind.sniper.cost
        let remainder = exhausted.city.startingBudget % UnitKind.sniper.cost
        for point in separatedStreetPosts(in: exhausted.map, count: affordableSnipers) { deploy(exhausted, .sniper, at: point) }
        expect(exhausted.units.count == affordableSnipers && exhausted.budget == remainder, "limited funds permit exactly the affordable deployments")
        let unitCount = exhausted.units.count
        deploy(exhausted, .sniper, at: roadB)
        expect(exhausted.units.count == unitCount && exhausted.budget == remainder, "unaffordable deployment cannot debit a negative budget")
        expect(!exhausted.claimEmergencyReserve(), "planning cannot claim emergency funds")
        exhausted.start(); run(exhausted, until: 19.9)
        expect(!exhausted.emergencyAvailable, "reserve waits at least twenty seconds")
        run(exhausted, until: 20.1)
        expect(exhausted.emergencyAvailable, "low funds unlock a once-per-mission emergency reserve")
        let beforeReserve = exhausted.budget
        expect(exhausted.claimEmergencyReserve() && exhausted.budget == beforeReserve + 350 && exhausted.phase == .paused, "reserve grants money and a real paused regroup window")
        expect(!exhausted.claimEmergencyReserve() && exhausted.budget == beforeReserve + 350, "reserve cannot be claimed twice")
        exhausted.reset(city: .settat)
        expect(!exhausted.emergencyUsed && exhausted.earnedMoney == 0 && exhausted.pendingHerdCount == 4, "a new mission clears reserve, economy, and arrivals")

        let suiteName = "ZomboysCore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["points": 1, "levels": ["sniper": 2, "garrison": 2, "squad": 1, "turret": 2, "airstrike": 1, "helicopter": 3], "completedCities": ["paris", "casablanca"]] as [String: Any], forKey: "zomboys.progression.v1")
        let legacy = GameEngine(city: .settat, defaults: defaults)
        expect(legacy.upgradePoints == 3 && legacy.upgradeLevels[.squad] == 1, "removed sniper investments are refunded")
        expect(legacy.upgradeLevels[.humvee] == 2 && legacy.upgradeLevels[.b2] == 1 && legacy.upgradeLevels[.ac130] == 3, "old turret and aircraft upgrades migrate to replacement units")
        expect(legacy.upgradeLevels[.sniper] == 2, "garrison investments migrate to the new sniper without restoring already removed legacy sniper upgrades")
        expect(legacy.completedCities == [.casablanca], "valid city completions survive roster migration while obsolete city IDs are discarded")
        let reloaded = GameEngine(city: .settat, defaults: defaults)
        expect(reloaded.upgradePoints == 3 && reloaded.upgradeLevels[.humvee] == 2, "migration cannot pay a second refund")
        expect(reloaded.upgradeLevels[.sniper] == 2, "new sniper upgrades persist on the versioned roster and are not refunded again")
        expect(reloaded.purchaseUpgrade(.squad), "an affordable between-mission specialization succeeds")
        expect(GameEngine(city: .settat, defaults: defaults).upgradeLevels[.squad] == 2, "new upgrade levels persist")
        expect(reloaded.purchaseUpgrade(.squad), "third specialization level is supported")
        let pointsAtMaximum = reloaded.upgradePoints
        expect(!reloaded.purchaseUpgrade(.squad) && reloaded.upgradePoints == pointsAtMaximum, "maximum levels reject purchases without spending")
        deploy(reloaded, .squad, at: roadA)
        expect(reloaded.units[0].maxHealth > UnitKind.squad.maxHealth && reloaded.units[0].range > UnitKind.squad.range, "upgrades specialize future deployments")
        reloaded.start()
        expect(!reloaded.purchaseUpgrade(.humvee), "combat cannot modify loadout progression")

        for kind in [UnitKind.squad, .sniper] {
            let profiles = game()
            for point in separatedStreetPosts(in: profiles.map, count: 5) { deploy(profiles, kind, at: point) }
            expect(profiles.units.count == 5 && profiles.units.map(\.soundVariant) == [0, 1, 2, 3, 0], "\(kind.title) changes its sound profile on each successful deployment")
            let first = profiles.units[0]
            select(profiles, unit: first); profiles.removeSelected(); deploy(profiles, kind, at: first.position)
            expect(profiles.units.last?.soundVariant == 1, "\(kind.title) replacement deployment receives the next profile instead of repeating the withdrawn unit")
            expect(profiles.units.allSatisfy { unit in unit.formation.allSatisfy { point in profiles.map.isRoad(point) && distance(point, unit.position) < profiles.map.metersToWorld * 4 } }, "\(kind.title) figures occupy a physical street-clamped formation")
            let team = profiles.units[0]
            let outerSoldier = team.formation.max { distance($0, team.position) < distance($1, team.position) }!
            let beforeSelectionBudget = profiles.budget
            profiles.selectTool(kind)
            profiles.tap(at: outerSoldier, selectionRadius: 0.15)
            expect(distance(outerSoldier, team.position) > 0.15 && profiles.selectedUnitID == team.id && profiles.units.count == 5 && profiles.budget == beforeSelectionBudget, "\(kind.title) outer figures select their existing team with a street-level radius and no duplicate purchase")
            profiles.selectTool(nil)
            profiles.tap(at: CGPoint(x: team.position.x, y: team.position.y + 15), selectionRadius: 0.15)
            expect(profiles.selectedUnitID == nil && profiles.units.count == 5 && profiles.budget == beforeSelectionBudget, "\(kind.title) close-view hit testing does not enlarge the selection footprint across the street")
            profiles.reset(city: .settat); deploy(profiles, kind, at: first.position)
            expect(profiles.units[0].soundVariant == 0, "\(kind.title) retry repeats deterministic deployment profiles")
        }

        let social = game()
        let socialStation = social.civilians[0].position
        deploy(social, .evacuation, at: socialStation)
        let stationID = social.units[0].id
        expect(social.civilians.allSatisfy { $0.evacuationID == nil && $0.evacuationAwareness == 0 }, "civilians start without global evacuation knowledge")
        social.start(); run(social, until: 0.7)
        expect(social.civilians.allSatisfy { $0.evacuationID == nil }, "evacuation signage takes sustained local discovery instead of an immediate global order")
        run(social, until: 5)
        expect(social.civilians.contains { $0.evacuationID == stationID } && social.civilians.contains { $0.evacuationID == nil }, "only locally informed civilians learn the station while the distant city stays unaware")
        expect(social.civilians.allSatisfy { $0.speed <= social.map.metersToWorld * 5 && $0.heading.isFinite && $0.stride >= 0 && $0.stride < .pi * 2 }, "civilian movement publishes smooth physical walking/fleeing gait state")
        let learnedIDs = Set(social.civilians.filter { $0.evacuationID != nil }.map(\.id))
        select(social, unit: social.units[0]); social.removeSelected(); run(social, until: 5.7)
        expect(social.civilians.filter { learnedIDs.contains($0.id) }.allSatisfy { $0.evacuationID == nil && $0.evacuationAwareness < 1 }, "withdrawn evacuation stations invalidate people's knowledge and old routes")

        checks += runCivilianKnowledgeChecks()

        let clearSuiteName = "ZomboysFullClear.\(UUID().uuidString)"
        let clearDefaults = UserDefaults(suiteName: clearSuiteName)!
        defer { clearDefaults.removePersistentDomain(forName: clearSuiteName) }
        let fullClear = GameEngine(city: .settat, defaults: clearDefaults)
        for city in [CityScenario.settat, .casablanca] {
            fullClear.reset(city: city)
            let initialPoints = fullClear.upgradePoints
            playDefense(fullClear)
            expect(fullClear.phase == .won, "\(city.title) can be cleared through ordinary paid player orders")
            expect(fullClear.saved >= city.population * 9 / 10 && fullClear.saved + fullClear.casualties == city.population, "\(city.title) permits a ninety-percent civilian survival strategy")
            expect(fullClear.zombies.isEmpty && fullClear.pendingHerdCount == 0 && fullClear.projectiles.isEmpty, "\(city.title) victory waits for every scheduled herd and airborne shell")
            expect(fullClear.arrivals.allSatisfy { $0.releasedCount == $0.size } && fullClear.kills >= fullClear.arrivals.reduce(0) { $0 + $1.size }, "\(city.title) cannot win while any member of its finite exterior columns remains unreleased or alive")
            expect(fullClear.earnedMoney == fullClear.kills * GameBalance.killIncome && fullClear.budget >= 0, "\(city.title) full-operation finances use real kill income and remain nonnegative")
            expect(fullClear.upgradePoints == initialPoints + 3 && fullClear.completedCities.contains(city), "\(city.title) first high-survival victory grants three specialization points")
            expect(fullClear.activeCivilianCount == 0 && abs(fullClear.survivalRate - Double(fullClear.saved) / Double(city.population)) < 0.000_001, "\(city.title) completed counters report the actual rescued population")
            let expectedScore = fullClear.saved * 10_000 + min(9_999, fullClear.kills + max(0, 180 - Int(fullClear.elapsed)))
            expect(fullClear.resultScore == expectedScore, "\(city.title) survival controls the score and all combat/time tie breakers stay below one saved civilian")
            let complete = GameEngine(city: city, defaults: clearDefaults)
            expect(complete.upgradePoints == fullClear.upgradePoints && complete.completedCities.contains(city), "\(city.title) earned completion and specialization points survive relaunch")
            let finishedTime = fullClear.elapsed
            fullClear.tick(dt: 0.25)
            expect(fullClear.elapsed == finishedTime && fullClear.upgradePoints == initialPoints + 3, "\(city.title) finished frames cannot pay the victory reward again")
            print("FULL CLEAR: \(city.title) · \(fullClear.saved)/\(city.population) survivors · \(fullClear.kills) kills · \(Int(fullClear.elapsed))s")
            fflush(stdout)
        }
        let awardedPoints = fullClear.upgradePoints
        fullClear.reset(city: .settat)
        playDefense(fullClear)
        expect(fullClear.phase == .won && fullClear.upgradePoints == awardedPoints, "replaying a completed city cannot farm specialization rewards")

        for city in CityScenario.allCases {
            let scenario = GameEngine(city: city, defaults: nil)
            let map = scenario.map
            expect(scenario.initialPopulation == city.population && scenario.budget == city.startingBudget, "\(city.title) resources match its scenario")
            expect(scenario.civilians.allSatisfy { map.isRoad($0.position, tolerance: 0.1) }, "\(city.title) civilians spawn on road surfaces")
            expect(map.navigationNodes.contains { !map.coreBounds.contains($0) }, "\(city.title) includes playable outer neighborhoods")
            expect(map.herdEntryPoints.allSatisfy { map.isRoad($0, tolerance: 0.1) }, "\(city.title) arrival approaches are navigable")
            let route = map.path(from: map.herdEntryPoints[0], to: map.nearestRoadPoint(to: map.initialFocus))
            expect(route.count >= 2 && route.allSatisfy { map.isRoad($0, tolerance: 0.1) }, "\(city.title) district approaches connect to the central mission area")
            scenario.start(); run(scenario, until: 2)
            expect(scenario.civilians.allSatisfy { map.isRoad($0.position, tolerance: 0.1) } && scenario.phase == .running, "\(city.title) updates actors without early victory")
        }
        let soundGame = game(); soundGame.start(); run(soundGame, until: 70)
        expect(soundGame.audioEvents.count <= 96, "sound event buffering is bounded")
        let drained = soundGame.drainAudioEvents()
        expect(!drained.isEmpty && soundGame.audioEvents.isEmpty, "audio mixer consumes each queued event once")
        expect(Set(drained.map(\.id)).count == drained.count, "sound events have unique identities")
        expect(drained.allSatisfy { $0.cue != .zombieGroan && $0.cue != .zombieAttack && $0.cue != .civilianScream }, "removed zombie and civilian voices are never queued by the simulation")
        print("PASS: \(checks) deterministic gameplay checks in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
        print("Verified: compact OSM Settat and Casablanca; pre-existing 560–2000-member exterior masses; bounded AI and shared route junctions; road-constrained flocking; persistent building/landmark destruction and opened LOS; explosive civilian casualties; Humvee patrols; specialized ground forces; ballistic shells and aircraft; kill money; durable walls; reserve; complete paid-strategy victories; social evacuation; persistent progression.")
    }
    /// Optimized native core timing separates ordinary motion from shared-route
    /// refreshes. This is CPU evidence, not a physical iPhone thermal measurement.
    @MainActor
    private static func benchmarkSimulation() {
        func threadMilliseconds() -> Double {
            var stamp = timespec()
            guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &stamp) == 0 else { fatalError("Thread CPU clock unavailable") }
            return Double(stamp.tv_sec) * 1000 + Double(stamp.tv_nsec) / 1_000_000
        }
        for city in [CityScenario.settat, .casablanca] {
            let game = GameEngine(city: city, defaults: nil)
            game.selectTool(.evacuation)
            game.tap(at: game.civilians[0].position)
            game.start()
            let denseAt = game.arrivals[1].departureAt + 8
            while game.elapsed < denseAt && game.phase == .running { game.tick(dt: 0.25) }
            var normal: [Double] = [], refreshed: [Double] = []
            var normalCPU: [Double] = [], refreshedCPU: [Double] = []
            let connectionsBefore = game.herdConnectionSearches
            var continuous = true
            for _ in 0..<240 {
                let revision = game.herdRouteRevision
                let prior = Dictionary(uniqueKeysWithValues: game.zombies.map { ($0.id, $0.position) })
                let before = ProcessInfo.processInfo.systemUptime
                let cpuBefore = threadMilliseconds()
                game.tick(dt: 0.05)
                let cpuMilliseconds = threadMilliseconds() - cpuBefore
                let milliseconds = (ProcessInfo.processInfo.systemUptime - before) * 1000
                if game.herdRouteRevision == revision { normal.append(milliseconds); normalCPU.append(cpuMilliseconds) }
                else { refreshed.append(milliseconds); refreshedCPU.append(cpuMilliseconds) }
                for zombie in game.zombies {
                    if let point = prior[zombie.id], hypot(zombie.position.x - point.x, zombie.position.y - point.y) > game.map.metersToWorld * 11.001 * 0.05 { continuous = false }
                }
            }
            func summary(_ samples: [Double]) -> String {
                guard !samples.isEmpty else { return "none" }
                let sorted = samples.sorted()
                return String(format: "n=%d median=%.3f ms p95=%.3f ms peak=%.3f ms", samples.count, sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!)
            }
            let onRoad = game.zombies.allSatisfy { game.map.isRoad($0.position, tolerance: 0.1) }
            print("BENCH \(city.title): \(game.zombies.count)/\(game.activeZombieLimit) live, \(game.stagedHerdMembers.count) staged, \(game.civilians.count) civilians")
            print("  wall normal \(summary(normal)); route refresh \(summary(refreshed))")
            print("  CPU normal \(summary(normalCPU)); route refresh \(summary(refreshedCPU))")
            print("  shared connection A* searches=\(game.herdConnectionSearches - connectionsBefore); onRoad=\(onRoad); continuous=\(continuous)")
            fflush(stdout)
            guard game.zombies.count <= game.activeZombieLimit, onRoad, continuous, game.phase == .running, !normal.isEmpty, !refreshed.isEmpty else { fatalError("Dense simulation benchmark invariant failed") }
        }
    }

}
