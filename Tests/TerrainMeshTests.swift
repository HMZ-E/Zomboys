import Foundation
import SceneKit

@main
struct TerrainMeshTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        let buildings = [
            MapBuilding(rect: CGRect(x: 0, y: 0, width: 8, height: 5), style: 3),
            MapBuilding(rect: CGRect(x: 20, y: 10, width: 6, height: 9), style: 12),
            MapBuilding(rect: CGRect(x: 40, y: 20, width: 5, height: 7), style: -5)
        ]
        // Deliberately nonsequential IDs expose accidental damage-by-array-offset.
        let ids = [41, 7, 93]
        func roof(_ damage: [Int: Int]) -> CityMesh {
            TacticalBuildingMesher.overview(buildings: buildings, ids: ids, damage: damage)
        }
        func triangleCount(_ mesh: CityMesh, _ material: Int) -> Int { mesh.indices[material].count / 3 }
        func positions(_ mesh: CityMesh) -> [[Double]] {
            mesh.vertices.map { [Double($0.x), Double($0.y), Double($0.z)] }
        }
        let intact = roof([:])
        expect(intact.indices.count == 10, "overview retains the complete building and damage palette")
        expect(intact.indices.reduce(0) { $0 + $1.count } == 18, "three intact rectangular roofs contain six triangles")
        for material in [3, 4, 5] {
            expect(triangleCount(intact, material) == 2, "intact roof style \(material) retains its existing color")
        }
        expect(intact.vertices.allSatisfy { abs(Double($0.y) - 0.38) < 0.000_001 }, "overview roofs retain altitude 0.38")
        expect(intact.normals.allSatisfy { $0.x == 0 && $0.y == 1 && $0.z == 0 }, "all roof triangles face upward")

        let light = roof([7: 1, 999: 3])
        expect(triangleCount(light, 8) == 2 && triangleCount(light, 4) == 0,
               "light damage recolors the correct stable building ID to material 8")
        expect(positions(light) == positions(intact), "damage outside the map and light damage preserve roof geometry")
        let heavy = roof([41: 2])
        expect(triangleCount(heavy, 9) == 2 && triangleCount(heavy, 3) == 0,
               "heavy damage uses material 9 and removes the intact material assignment")
        expect(positions(heavy) == positions(intact), "heavy damage changes appearance without moving the building")

        let destroyed = roof([93: 3])
        expect(destroyed.indices.reduce(0) { $0 + $1.count } == 12 && triangleCount(destroyed, 5) == 0,
               "a destroyed building contributes no roof triangles")
        expect(destroyed.vertices.allSatisfy { Double($0.x) < 40 }, "destroyed roof vertices are removed, leaving room for rubble")
        let allDestroyed = roof([41: 3, 7: 3, 93: 3])
        expect(allDestroyed.vertices.isEmpty && allDestroyed.indices.allSatisfy(\.isEmpty),
               "a destroyed city has no lingering overview roofs")

        let mixed = roof([41: 1, 7: 2, 93: 3])
        expect(triangleCount(mixed, 8) == 2 && triangleCount(mixed, 9) == 2,
               "one snapshot can combine light damage, heavy damage, and destruction")
        expect(mixed.indices.enumerated().allSatisfy { [8, 9].contains($0.offset) || $0.element.isEmpty },
               "mixed damage cannot leave original roof materials behind")
        let repaired = roof([41: 0, 7: 0, 93: 0])
        expect(positions(repaired) == positions(intact) && repaired.indices == intact.indices,
               "repair and mission reset restore exactly the original mesh")
        let district = TacticalBuildingMesher.base(buildings: buildings, ids: ids, damage: [41: 1, 7: 2, 93: 3])
        expect(district.indices.enumerated().allSatisfy { [8, 9].contains($0.offset) || $0.element.isEmpty },
               "overview and neighborhood geometry agree about damage colors and destroyed IDs")
        print("Passed \(checks) terrain mesh checks.")
    }
}
