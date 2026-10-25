import Foundation
import Darwin

@main
struct MovementBehaviorTests {
    @MainActor
    static func main() {
        var checks = 0
        let began = Date()
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAILED: \(description)") }
            checks += 1
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        func game(_ city: CityScenario = .settat) -> GameEngine { GameEngine(city: city, defaults: nil, missionSeed: 34567) }
        func street(in map: CityMap) -> (CGPoint, CGPoint) {
            for road in map.roads where road.width >= map.metersToWorld * 4 {
                for (a, b) in zip(road.points, road.points.dropFirst()) {
                    let length = distance(a, b)
                    guard length > map.metersToWorld * 120 else { continue }
                    let margin = map.metersToWorld * 8 / length
                    let start = CGPoint(x: a.x + (b.x - a.x) * margin, y: a.y + (b.y - a.y) * margin)
                    let end = CGPoint(x: b.x - (b.x - a.x) * margin, y: b.y - (b.y - a.y) * margin)
                    let route = map.path(from: start, to: end)
                    if route.count >= 2, !map.containsBuilding(start), !map.containsBuilding(end), map.hasLineOfSight(from: start, to: end) { return (start, end) }
                }
            }
            fatalError("No open real street fixture in \(map.city)")
        }
        func point(_ start: CGPoint, _ end: CGPoint, metres: Double, scale: Double) -> CGPoint {
            let fraction = metres * scale / distance(start, end)
            return CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        }
        func wallFixture(in map: CityMap) -> (outside: CGPoint, inside: CGPoint, visible: CGPoint) {
            let offset = map.metersToWorld * 0.35
            for building in map.buildings {
                for (a, b) in zip(building.footprint, building.footprint.dropFirst() + [building.footprint.first!]) {
                    let length = distance(a, b)
                    guard length > map.metersToWorld * 3 else { continue }
                    let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    let nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
                    for sign in [-1.0, 1.0] {
                        let outside = CGPoint(x: middle.x + nx * offset * sign, y: middle.y + ny * offset * sign)
                        let inside = CGPoint(x: middle.x - nx * offset * sign, y: middle.y - ny * offset * sign)
                        let visible = CGPoint(x: outside.x + nx * map.metersToWorld * 2 * sign, y: outside.y + ny * map.metersToWorld * 2 * sign)
                        if !map.containsBuilding(outside), map.containsBuilding(inside), !map.containsBuilding(visible), !map.hasLineOfSight(from: outside, to: inside), map.hasLineOfSight(from: outside, to: visible) { return (outside, inside, visible) }
                    }
                }
            }
            fatalError("No footprint visibility fixture")
        }

        for city in CityScenario.allCases {
            let contact = game(city), scale = contact.map.metersToWorld
            let (start, end) = street(in: contact.map)
            let heading = atan2(end.y - start.y, end.x - start.x)
            let wall = wallFixture(in: contact.map)
            contact.movementTestConfigure(civilians: [Civilian(id: 100, position: wall.outside)],
                                         zombies: [Zombie(id: 200, position: wall.inside, health: 60)], destination: end)
            for _ in 0..<40 { contact.movementTestContact(dt: 0.05) }
            expect(contact.civilians.count == 1 && contact.civilians[0].exposure == 0, "\(city): contact cannot transmit through an intact footprint")
            expect(contact.casualties == 0, "\(city): a wall-protected resident remains part of the survival objective")

            contact.movementTestConfigure(civilians: [Civilian(id: 100, position: start)],
                                         zombies: [Zombie(id: 200, position: point(start, end, metres: 1, scale: scale), health: 60, herdID: 9)], destination: end)
            for _ in 0..<27 { contact.movementTestContact(dt: 0.05) }
            expect(contact.civilians.count == 1, "\(city): open contact still requires sustained exposure")
            for _ in 0..<3 { contact.movementTestContact(dt: 0.05) }
            expect(contact.civilians.isEmpty && contact.casualties == 1 && contact.zombies.last?.herdID == 9, "\(city): real open contact converts the civilian and preserves the infecting herd")
            expect((contact.zombies.last?.infectiousAt ?? 0) > contact.elapsed + 2, "\(city): conversion retains the grace incubation window")

            let perception = game(city)
            perception.movementTestConfigure(civilians: [Civilian(id: 100, position: wall.outside)],
                                            zombies: [Zombie(id: 200, position: wall.inside, health: 60), Zombie(id: 201, position: wall.visible, health: 60)], destination: end)
            expect(perception.movementTestVisibleThreat(at: wall.outside, radius: scale * 65) == 201, "\(city): a nearer hidden zombie does not mask a visible threat")
            perception.movementTestCivilians(dt: 0.05)
            expect(perception.civilians[0].panic > 0, "\(city): actual civilian perception reacts to the visible threat")

            let pursuit = game(city)
            let leftZombie = point(start, end, metres: 35, scale: scale), rightZombie = point(start, end, metres: 65, scale: scale)
            let leftPrey = point(start, end, metres: 25, scale: scale), rightPrey = point(start, end, metres: 75, scale: scale)
            pursuit.movementTestConfigure(civilians: [Civilian(id: 100, position: leftPrey), Civilian(id: 101, position: rightPrey)],
                                         zombies: [Zombie(id: 200, position: leftZombie, health: 60, herdID: 1, heading: heading + .pi), Zombie(id: 201, position: rightZombie, health: 60, herdID: 1, heading: heading)], destination: end)
            pursuit.movementTestZombies(dt: 0.05)
            expect(pursuit.movementTestPursuit(for: 200) == 100 && pursuit.movementTestPursuit(for: 201) == 101, "\(city): individual members peel toward different nearby visible prey")
            expect(distance(pursuit.zombies[0].position, leftPrey) < distance(leftZombie, leftPrey), "\(city): local pursuit overrides the herd's opposite distant direction")
            pursuit.movementTestRemoveCivilian(100)
            for _ in 0..<20 { pursuit.movementTestZombies(dt: 0.05) }
            expect(pursuit.movementTestPursuit(for: 200) == nil && pursuit.zombies[0].position != leftZombie, "\(city): a lost target releases local pursuit and rejoins the shared route")
            expect(pursuit.zombies.allSatisfy { pursuit.map.isRoad($0.position) && !pursuit.map.containsBuilding($0.position) }, "\(city): pursuit and route rejoin remain on open road surfaces")

            let surge = game(city)
            surge.movementTestConfigure(civilians:[],zombies:[Zombie(id:901,position:point(start,end,metres:20,scale:scale),health:60,herdID:3,heading:heading)],destination:end)
            var speedSamples:[Double] = []
            var lastHeading = heading
            var boundedTurns = true
            for _ in 0..<40 {
                surge.movementTestZombies(dt:0.05)
                let actor = surge.zombies[0]
                speedSamples.append(actor.speed/scale)
                let delta = abs(atan2(sin(actor.heading-lastHeading),cos(actor.heading-lastHeading)))
                boundedTurns = boundedTurns && delta <= 5.5*0.05+0.000001
                lastHeading = actor.heading
            }
            expect(speedSamples[0]<0.7 && speedSamples.last!>2,"\(city): a real infected body eases out of rest instead of jumping into its running speed")
            expect(boundedTurns,"\(city): physical headings remain within the visible turn-rate limit")
            expect(surge.zombies.allSatisfy { surge.map.isRoad($0.position) && !surge.map.containsBuilding($0.position) },"\(city): accelerating bodies remain on actual streets")

            let people = game(city)
            let residents = (0..<20).map { index in Civilian(id: 100 + index, position: point(start, end, metres: 20 + Double(index) * 0.7, scale: scale), heading: heading, speed: scale * 1.5) }
            people.movementTestConfigure(civilians: residents, zombies: [], destination: end)
            var last = Dictionary(uniqueKeysWithValues: residents.map { ($0.id, $0.position) })
            var continuous = true
            for _ in 0..<60 {
                people.movementTestCivilians(dt: 0.05)
                continuous = continuous && people.civilians.allSatisfy { distance(last[$0.id]!, $0.position) <= scale * 5 * 0.05 + 0.000_001 && people.map.isRoad($0.position) && !people.map.containsBuilding($0.position) }
                last = Dictionary(uniqueKeysWithValues: people.civilians.map { ($0.id, $0.position) })
            }
            let lateral = people.civilians.map { civilian in -sin(heading) * (civilian.position.x - start.x) + cos(heading) * (civilian.position.y - start.y) }
            expect(continuous && people.civilians.count == residents.count, "\(city): crowd spacing preserves actors and bounded continuous road movement")
            expect((lateral.max()! - lateral.min()!) > scale * 0.4, "\(city): civilians use distinct personal street lanes instead of one centerline")

            let barrier = game(city)
            let middle = point(start, end, metres: 30, scale: scale)
            let halfWidth = max(scale * 2, barrier.map.streetWidth(at: middle))
            let a = CGPoint(x: middle.x - sin(heading) * halfWidth, y: middle.y + cos(heading) * halfWidth)
            let b = CGPoint(x: middle.x + sin(heading) * halfWidth, y: middle.y - cos(heading) * halfWidth)
            let wallUnit = DefenseUnit(id: 500, kind: .barricade, position: middle, targetPosition: nil, health: 320, maxHealth: 320, range: 0, cooldown: 0, barrierPath: [a, b])
            barrier.movementTestConfigure(civilians: [Civilian(id: 100, position: point(start, end, metres: 27, scale: scale), heading: heading, speed: scale * 1.8)], zombies: [], destination: end, units: [wallUnit])
            expect(barrier.movementBlocked(from: start, to: end, forCivilians: true) && barrier.movementBlocked(from: end, to: start, forCivilians: true), "\(city): wall checks cover the entire segment in both travel directions")
            var previous = barrier.civilians[0].position
            var smoothQueue = true
            for _ in 0..<100 {
                barrier.movementTestCivilians(dt: 0.05)
                smoothQueue = smoothQueue && distance(previous, barrier.civilians[0].position) <= scale * 5 * 0.05 + 0.000_001
                previous = barrier.civilians[0].position
            }
            let progress = cos(heading) * (barrier.civilians[0].position.x - middle.x) + sin(heading) * (barrier.civilians[0].position.y - middle.y)
            expect(smoothQueue && progress < 0, "\(city): civilians queue before intact walls without stepping or teleporting through")
        }
        print("PASS: \(checks) movement behavior checks in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
    }
}
