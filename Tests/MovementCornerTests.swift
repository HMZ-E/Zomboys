import Foundation
import Darwin

@main
struct MovementCornerTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: " + message) }
            checks += 1
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
        for city in CityScenario.allCases {
            let game = GameEngine(city: city, defaults: nil, missionSeed: city.seed)
            let map = game.map, scale = game.map.metersToWorld
            var adjacent: [Int: [Int]] = [:]
            for edge in map.navigationEdges { adjacent[edge.from, default: []].append(edge.to); adjacent[edge.to, default: []].append(edge.from) }
            var fixtures: [(CGPoint, CGPoint, [CGPoint])] = []
            for node in adjacent.keys.sorted() {
                let corner = map.navigationNodes[node]
                let links = adjacent[node]!
                for first in links {
                    for second in links where second > first {
                        let a = map.navigationNodes[first], b = map.navigationNodes[second]
                        let la = distance(a,corner), lb = distance(b,corner)
                        guard la > scale*25, lb > scale*25 else { continue }
                        let cosine = ((a.x-corner.x)*(b.x-corner.x)+(a.y-corner.y)*(b.y-corner.y))/(la*lb)
                        guard abs(cosine) < 0.65 else { continue }
                        let start = CGPoint(x:corner.x+(a.x-corner.x)*scale*22/la,y:corner.y+(a.y-corner.y)*scale*22/la)
                        let end = CGPoint(x:corner.x+(b.x-corner.x)*scale*22/lb,y:corner.y+(b.y-corner.y)*scale*22/lb)
                        let route = map.path(from:start,to:end)
                        let length = zip(route,route.dropFirst()).reduce(0.0) { $0+distance($1.0,$1.1) }
                        guard route.count >= 3, length < scale*100, !map.hasLineOfSight(from:start,to:end) else { continue }
                        var clear = true
                        for (u,v) in zip(route,route.dropFirst()) {
                            let samples = max(1,Int(ceil(distance(u,v)/scale)))
                            for i in 0...samples {
                                let t = Double(i)/Double(samples)
                                let p = CGPoint(x:u.x+(v.x-u.x)*t,y:u.y+(v.y-u.y)*t)
                                if !map.isRoad(p) || map.containsBuilding(p) { clear=false }
                            }
                        }
                        if clear { fixtures.append((start,end,route)) }
                        if fixtures.count >= 6 { break }
                    }
                    if fixtures.count >= 6 { break }
                }
                if fixtures.count >= 6 { break }
            }
            expect(!fixtures.isEmpty,"\(city): real occluded L-turn fixture exists")
            for (fixtureIndex,fixture) in fixtures.enumerated() {
                let (start,end,route) = fixture
                let initial = route.dropFirst().first(where:{distance(start,$0)>scale}) ?? end
                game.movementTestConfigure(civilians:[],zombies:[Zombie(id:200+fixtureIndex,position:start,health:60,herdID:1,heading:atan2(initial.y-start.y,initial.x-start.x))],destination:end)
                var previous=start, closest=distance(start,end), stationary=0.0, longestStationary=0.0, continuous=true
                for _ in 0..<800 {
                    game.movementTestZombies(dt:0.05)
                    let current=game.zombies[0].position
                    let moved=distance(previous,current)
                    continuous = continuous && moved <= scale*11*0.05+0.000_001 && map.isRoad(current) && !map.containsBuilding(current)
                    closest=min(closest,distance(current,end))
                    if moved < scale*0.01 && distance(current,end)>scale*3 { stationary += 0.05; longestStationary=max(longestStationary,stationary) } else { stationary=0 }
                    previous=current
                }
                print("CORNER \(city.title) #\(fixtureIndex) start=\(start) end=\(end) final=\(previous) closestM=\(closest/scale) stationaryS=\(longestStationary)")
                expect(continuous,"\(city) corner \(fixtureIndex): every step remains continuous on an open street")
                let destinationTolerance = max(scale*6, map.streetWidth(at:end)*0.55)
                fflush(stdout)
                expect(closest < destinationTolerance,"\(city) corner \(fixtureIndex): actual body traverses both legs and reaches the destination")
                expect(longestStationary < 5,"\(city) corner \(fixtureIndex): no permanently blocked body outside the destination")

                game.movementTestConfigure(civilians:[Civilian(id:500+fixtureIndex,position:start,heading:atan2(initial.y-start.y,initial.x-start.x),speed:scale*1.8)],zombies:[],destination:end)
                previous=start; closest=distance(start,end); stationary=0; longestStationary=0; continuous=true
                for _ in 0..<1_200 {
                    game.movementTestCivilians(dt:0.05)
                    let current=game.civilians[0].position
                    let moved=distance(previous,current)
                    continuous = continuous && moved <= scale*5*0.05+0.000_001 && map.isRoad(current) && !map.containsBuilding(current)
                    closest=min(closest,distance(current,end))
                    if moved < scale*0.01 && distance(current,end)>destinationTolerance { stationary += 0.05; longestStationary=max(longestStationary,stationary) } else { stationary=0 }
                    previous=current
                    if closest < destinationTolerance { break }
                }
                print("CIVILIAN CORNER \(city.title) #\(fixtureIndex) final=\(previous) closestM=\(closest/scale) stationaryS=\(longestStationary)")
                fflush(stdout)
                expect(continuous,"\(city) civilian corner \(fixtureIndex): every step remains continuous on an open street")
                expect(closest < destinationTolerance,"\(city) civilian corner \(fixtureIndex): actual body traverses both legs and reaches the destination")
                expect(longestStationary < 5,"\(city) civilian corner \(fixtureIndex): no permanently blocked body outside the destination")
            }
            if city == .casablanca {
                let trapped = [
                    Zombie(id:199,position:CGPoint(x:3621.990779498187,y:3200.4108721038283),health:60,herdID:9),
                    Zombie(id:203,position:CGPoint(x:3622.241249200196,y:3200.2507828789894),health:60,herdID:9),
                    Zombie(id:205,position:CGPoint(x:3622.3493196811296,y:3200.1754042401435),health:60,herdID:9),
                    Zombie(id:206,position:CGPoint(x:3622.0383202955363,y:3200.4057101186127),health:60,herdID:9)
                ]
                game.movementTestConfigure(civilians:[],zombies:trapped,destination:map.nearestRoadPoint(to:map.initialFocus))
                let initial=Dictionary(uniqueKeysWithValues:trapped.map{($0.id,$0.position)})
                var previous=initial, furthest:[Int:Double]=[:], continuous=true
                for _ in 0..<600 {
                    game.movementTestZombies(dt:0.05)
                    for zombie in game.zombies {
                        continuous = continuous && distance(previous[zombie.id]!,zombie.position) <= scale*11*0.05+0.000_001 && map.isRoad(zombie.position) && !map.containsBuilding(zombie.position)
                        furthest[zombie.id]=max(furthest[zombie.id,default:0],distance(initial[zombie.id]!,zombie.position))
                        previous[zombie.id]=zombie.position
                    }
                }
                print("CASABLANCA paid-run corner displacement metres: \(furthest.mapValues{$0/scale})")
                fflush(stdout)
                expect(continuous,"Paid-run corner recovery preserves bounded road movement for every body")
                expect(trapped.allSatisfy{furthest[$0.id,default:0] > scale*10},"Every previously trapped paid-run infected leaves the corner without teleporting")
            }
        }
        print("PASS: \(checks) actual road-corner movement checks")
    }
}
