import Foundation

/// Build a small static city-selector thumbnail; never construct navigation in the sheet.
@main
struct CreateMapPreview {
    static func main() throws {
        let city = CommandLine.arguments.dropFirst().first.flatMap(CityScenario.init(rawValue:)) ?? .casablanca
        let map = CityMap(city: city)
        let samplingStride = city == .settat ? 3 : 22
        let buildings = stride(from: 0, to: map.buildings.count, by: samplingStride).map { index -> [Double] in
            let b = map.buildings[index]
            return [b.rect.minX,b.rect.minY,b.rect.width,b.rect.height,Double(b.style)]
        }
        let roads = map.roads.sorted { $0.width > $1.width }.prefix(900).map { road -> [String: Any] in
            ["p":road.points.map { [Double($0.x),Double($0.y)] },"w":road.width]
        }
        let json: [String: Any] = ["worldSize":Double(map.worldSize),"focus":[Double(map.initialFocus.x),Double(map.initialFocus.y)],
            "roads":roads,"buildings":buildings,"water":map.water.map { $0.points.map { [Double($0.x),Double($0.y)] } },
            "parks":map.parks.map { [Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)] }]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let filename = city == .settat ? "SettatPreview" : "CasablancaPreview"
        try data.write(to: URL(fileURLWithPath: "Zomboys/Resources/\(filename).json"))
        print("\(city.title) thumbnail: \(data.count) bytes")
    }
}
