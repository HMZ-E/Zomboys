import Foundation
import SceneKit

/// A value-only terrain snapshot. The map's immutable arrays share storage until
/// changed; background mesh work never retains its routing graph or UI objects.
struct TacticalTerrainMeshInput {
    let city: CityScenario
    let worldSize: CGFloat
    let metersToWorld: Double
    let coreBounds: CGRect
    let initialFocus: CGPoint
    let roads: [MapRoad]
    let water: [MapWater]
    let parks: [CGRect]
    let buildings: [MapBuilding]

    init(map: CityMap) {
        city = map.city
        worldSize = map.worldSize
        metersToWorld = map.metersToWorld
        coreBounds = map.coreBounds
        initialFocus = map.initialFocus
        roads = map.roads
        water = map.water
        parks = map.parks
        buildings = map.buildings
    }
}

struct TacticalTerrainMeshes {
    let water: CityMesh
    let parks: CityMesh
    let roads: [CityMesh]
    let overviewRoads: CityMesh
    let overview: CityMesh
}

/// CPU-only triangle construction for background queues. SceneKit nodes,
/// materials and geometry uploads remain owned by the main-thread coordinator.
enum TacticalBuildingMesher {
    /// The city-scale roof mesh uses the same stable building IDs and damage
    /// palette as neighborhood geometry, so zooming out cannot restore a ruin.
    static func overview(buildings: [MapBuilding], ids: [Int], damage: [Int: Int]) -> CityMesh {
        var mesh = CityMesh(materialCount: 10)
        for (building, id) in zip(buildings, ids) {
            let severity = damage[id, default: 0]
            guard severity < 3 else { continue }
            let material = severity == 2 ? 9 : (severity == 1 ? 8 : abs(building.style) % 8)
            mesh.polygon(rectPoints(building.rect), altitude: 0.38, material: material)
        }
        return mesh
    }

    static func base(buildings: [MapBuilding], ids: [Int], damage: [Int: Int]) -> CityMesh {
        var mesh = CityMesh(materialCount: 10)
        for (building, id) in zip(buildings, ids) {
            let severity = damage[id, default: 0]
            guard severity < 3 else { continue }
            let points = footprint(building), height = building.height
            let material = severity == 2 ? 9 : (severity == 1 ? 8 : abs(building.style) % 8)
            mesh.polygon(points, altitude: height, material: material)
            for index in points.indices {
                let first = points[index], second = points[(index + 1) % points.count]
                let dx = second.x - first.x, dz = second.y - first.y
                let length = max(0.001, hypot(dx, dz))
                mesh.quad(SCNVector3(Float(first.x), 0.3, Float(first.y)),
                          SCNVector3(Float(second.x), 0.3, Float(second.y)),
                          SCNVector3(Float(second.x), Float(height), Float(second.y)),
                          SCNVector3(Float(first.x), Float(height), Float(first.y)),
                          normal: SCNVector3(Float(dz / length), 0, Float(-dx / length)), material: material)
            }
        }
        return mesh
    }

    static func details(buildings: [MapBuilding]) -> CityMesh {
        var mesh = CityMesh(materialCount: 4)
        for building in buildings {
            let points = footprint(building), height = building.height, rect = building.rect
            if rect.width > 10 && rect.height > 10 {
                let ventWidth = min(6, Double(rect.width) * 0.22)
                let ventDepth = min(6, Double(rect.height) * 0.22)
                mesh.box(center: SCNVector3(Float(rect.midX), Float(height + 1), Float(rect.midY)),
                         width: ventWidth, height: 2, depth: ventDepth, material: 1)
                if rect.width > 30 {
                    mesh.box(center: SCNVector3(Float(rect.midX + rect.width * 0.25), Float(height + 0.6), Float(rect.midY)),
                             width: 5, height: 1.2, depth: 5, material: 3)
                }
            }
            for index in points.indices {
                let first = points[index], second = points[(index + 1) % points.count]
                let dx = second.x - first.x, dz = second.y - first.y
                let length = max(0.001, hypot(dx, dz)), nx = dz / length, nz = -dx / length
                let columns = min(8, max(1, Int(length / 8)))
                let floors = min(8, max(1, Int(height / 5)))
                for row in 0..<floors {
                    for column in 0..<columns {
                        let fraction = CGFloat(column + 1) / CGFloat(columns + 1)
                        let cx = first.x + dx * fraction + nx * 0.15
                        let cz = first.y + dz * fraction + nz * 0.15
                        let cy = height * Double(row + 1) / Double(floors + 1)
                        let halfWidth = min(1.3, Double(length) / Double(columns + 1) * 0.25)
                        let windowHeight = min(2, height / Double(floors + 1) * 0.45)
                        let tx = Double(dx / length) * halfWidth, tz = Double(dz / length) * halfWidth
                        mesh.quad(SCNVector3(Float(cx) - Float(tx), Float(cy - windowHeight / 2), Float(cz) - Float(tz)),
                                  SCNVector3(Float(cx) + Float(tx), Float(cy - windowHeight / 2), Float(cz) + Float(tz)),
                                  SCNVector3(Float(cx) + Float(tx), Float(cy + windowHeight / 2), Float(cz) + Float(tz)),
                                  SCNVector3(Float(cx) - Float(tx), Float(cy + windowHeight / 2), Float(cz) - Float(tz)),
                                  normal: SCNVector3(Float(nx), 0, Float(nz)), material: 0)
                    }
                }
                mesh.strip(from: first, to: second, width: 0.65, altitude: height + 0.2, material: 2)
            }
        }
        return mesh
    }

    static func staticTerrain(input: TacticalTerrainMeshInput) -> TacticalTerrainMeshes {
        var water = CityMesh(materialCount: 2)
        for region in input.water {
            water.polygon(region.points, altitude: 0.1)
            for index in region.points.indices {
                water.strip(from: region.points[index], to: region.points[(index + 1) % region.points.count],
                            width: 2.5, altitude: 0.12, material: 1)
            }
        }

        var parks = CityMesh(materialCount: 3)
        for (index, park) in input.parks.enumerated() {
            parks.polygon(rectPoints(park), altitude: 0.15)
            let insetRect = park.insetBy(dx: 5, dy: 5)
            if !insetRect.isNull && insetRect.width > 0 && insetRect.height > 0 {
                let inset = rectPoints(insetRect)
                for point in inset.indices {
                    parks.strip(from: inset[point], to: inset[(point + 1) % inset.count],
                                width: 2, altitude: 0.18, material: 1)
                }
            }
            let spacing: CGFloat = 25
            for x in stride(from: park.minX + 10, to: park.maxX - 6, by: spacing) {
                for z in stride(from: park.minY + 10, to: park.maxY - 6, by: spacing) where (Int(x + z) + index) % 3 != 0 {
                    parks.box(center: SCNVector3(Float(x), 3.5, Float(z)), width: 7, height: 6, depth: 7, material: 2)
                }
            }
        }

        // Long road ways are partitioned by segment, retaining every original
        // strip and bridge while allowing SceneKit to cull distant districts.
        let roadChunkSize = max(160,input.metersToWorld*800)
        var roadChunks:[Int:CityMesh] = [:]
        for road in input.roads {
            for (first, second) in zip(road.points, road.points.dropFirst()) {
                let key = Int((first.x+second.x)/2/roadChunkSize)*100_000 + Int((first.y+second.y)/2/roadChunkSize)
                // Remove before appending so Array's copy-on-write does not
                // duplicate an existing district for every road segment.
                var roads = roadChunks.removeValue(forKey:key) ?? CityMesh(materialCount:4)
                roads.strip(from: first, to: second, width: road.width + 3.5,
                            altitude: road.isBridge ? 1.1 : 0.22, material: 0)
                roads.strip(from: first, to: second, width: road.width,
                            altitude: road.isBridge ? 1.15 : 0.24, material: 1)
                if road.width >= 15 {
                    let length = hypot(second.x - first.x, second.y - first.y)
                    let count = min(300, Int(length / 15))
                    for mark in 0..<count {
                        let start = CGFloat(mark) * 15 / max(1, length)
                        let end = min(1, (CGFloat(mark) * 15 + 6) / max(1, length))
                        roads.strip(from: CGPoint(x: first.x + (second.x - first.x) * start,
                                                  y: first.y + (second.y - first.y) * start),
                                    to: CGPoint(x: first.x + (second.x - first.x) * end,
                                                y: first.y + (second.y - first.y) * end),
                                    width: 0.7, altitude: road.isBridge ? 1.2 : 0.27, material: 2)
                    }
                }
                if road.isBridge {
                    roads.strip(from: first, to: second, width: road.width + 5, altitude: 0.8, material: 3)
                }
                roadChunks[key] = roads
            }
        }

        let overview = Self.overview(buildings: input.buildings, ids: Array(input.buildings.indices), damage: [:])
        let districtRoads = roadChunks.keys.sorted().compactMap { roadChunks[$0] }
        var overviewRoads = CityMesh(materialCount:4)
        for mesh in districtRoads { overviewRoads.append(mesh) }
        return TacticalTerrainMeshes(water: water, parks: parks, roads: districtRoads, overviewRoads:overviewRoads, overview: overview)
    }

    private static func footprint(_ building: MapBuilding) -> [CGPoint] {
        var points = building.footprint.count >= 3 ? building.footprint : rectPoints(building.rect)
        if points.count > 3 && points.first == points.last { points.removeLast() }
        // Normalize both OSM winding orders so facade normals and the slightly
        // offset windows point outside rectangular and concave footprints alike.
        var area: CGFloat = 0
        for index in points.indices {
            let first = points[index], second = points[(index + 1) % points.count]
            area += first.x * second.y - second.x * first.y
        }
        if area < 0 { points.reverse() }
        return points
    }

    private static func rectPoints(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}
