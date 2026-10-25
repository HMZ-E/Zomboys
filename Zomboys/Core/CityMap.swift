import Foundation
import CoreGraphics

struct MapRoad {
    let points: [CGPoint]
    let width: Double
    let name: String?
    let isBridge: Bool

    init(points: [CGPoint], width: Double = 12, name: String? = nil, isBridge: Bool = false) {
        self.points = points
        self.width = width
        self.name = name
        self.isBridge = isBridge
    }
}

struct MapBuilding {
    let rect: CGRect
    let style: Int
    let footprint: [CGPoint]
    /// Height in the same game-space units as the footprint. OSM heights are
    /// used where present; missing heights are deterministic visual estimates.
    let height: Double

    init(rect: CGRect, style: Int, footprint: [CGPoint] = [], height: Double? = nil) {
        self.rect = rect
        self.style = style
        self.footprint = footprint.isEmpty ? [CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)] : footprint
        self.height = height ?? Double(10 + style * 5)
    }
}

enum MapLandmarkKind: String, Codable {
    case mosque, twinCenter, moroccoMall, cathedral, mohammedSquare, port
    case clockTower, lighthouse, stadium, railwayStation
    case kasbah, university, localMosque, municipalPalace
}

struct MapLandmark {
    let kind: MapLandmarkKind
    let position: CGPoint
    let size: CGSize
    let heading: Double
    let height: Double
    let name: String
}

struct MapWater {
    let points: [CGPoint]
}

struct MapLabel {
    let position: CGPoint
    let text: String
}

struct HerdApproach {
    let source: CGPoint
    let ingress: CGPoint
    let route: [CGPoint]
    let approachDistance: Double
}

struct NavigationEdge {
    let from: Int
    let to: Int
}

/// Casablanca and Settat use bundled OpenStreetMap centerlines and footprints.
/// Rendering and routing work entirely offline; no map imagery is included.
final class CityMap {
    var metersToWorld: Double { city == .casablanca ? 0.235 : 0.35 }
    var worldSize: CGFloat { city == .casablanca ? 8_000 : 3_200 }
    var initialFocus: CGPoint {
        switch city {
        case .casablanca: return Self.casaPoint(latitude: 33.5905, longitude: -7.6255)
        case .settat: return Self.settatPoint(latitude: 33.0038013449, longitude: -7.6207871656)
        }
    }
    var coreBounds: CGRect {
        if city == .casablanca { return CGRect(x: initialFocus.x - 900, y: initialFocus.y - 900, width: 1_800, height: 1_800) }
        return CGRect(x: initialFocus.x - 500, y: initialFocus.y - 500, width: 1_000, height: 1_000)
    }
    /// Estimated built-up Settat envelope, including the university campus.
    /// This routes exterior columns across the city edge despite sparse OSM
    /// house coverage; it is a gameplay boundary, not a municipal border.
    var urbanBounds: CGRect {
        guard city == .settat else { return coreBounds }
        let northWest = Self.settatPoint(latitude: 33.039, longitude: -7.649)
        let southEast = Self.settatPoint(latitude: 32.981, longitude: -7.592)
        return CGRect(x: northWest.x, y: northWest.y, width: southEast.x - northWest.x, height: southEast.y - northWest.y)
    }
    func corePoint(_ point: CGPoint) -> CGPoint {
        if city == .casablanca { return CGPoint(x: coreBounds.minX + point.x * 1.8, y: coreBounds.minY + point.y * 1.8) }
        return CGPoint(x: coreBounds.minX + point.x, y: coreBounds.minY + point.y)
    }
    let city: CityScenario
    let roads: [MapRoad]
    let buildings: [MapBuilding]
    let parks: [CGRect]
    let water: [MapWater]
    let labels: [MapLabel]
    let landmarks: [MapLandmark]
    let sourceAttribution: String
    let navigationNodes: [CGPoint]
    let navigationEdges: [NavigationEdge]

    private let adjacency: [[Neighbor]]
    private let edgeGrid: [GridKey: [Int]]
    private let nodeGrid: [GridKey: [Int]]
    private let roadSegments: [RoadSegment]
    private let roadGrid: [GridKey: [Int]]
    private let buildingGrid: [GridKey: [Int]]
    /// Immutable landmark geometry is shared by every sight/contact query.
    private let landmarkFootprints: [[CGPoint]]

    /// Sources are connected public roads outside dense neighborhoods. The route
    /// identifies the first built-up street as ingress; it never starts in water.
    private(set) var herdApproaches: [HerdApproach] = []
    var herdEntryPoints: [CGPoint] { herdApproaches.map(\.ingress) }

    init(city: CityScenario) {
        self.city = city
        let layout: Layout
        switch city {
        case .settat: layout = Self.settat()
        case .casablanca: layout = Self.casablanca()
        }
        water = layout.water
        parks = layout.parks
        labels = layout.labels
        buildings = layout.buildings
        landmarks = layout.landmarks
        landmarkFootprints = layout.landmarks.map(Self.makeLandmarkFootprint)
        let available = city == .casablanca ? Self.bundledCasablanca != nil : Self.bundledSettat != nil
        sourceAttribution = available ? "© OpenStreetMap contributors · ODbL · heights partly estimated" : "\(city.title) schematic fallback · offline data missing"
        // Water crossings, where present, are retained from the OSM extract.
        roads = layout.roads
        let graph = layout.graph ?? Self.makeGraph(roads: roads)
        navigationNodes = graph.nodes
        navigationEdges = graph.edges
        adjacency = graph.adjacency
        edgeGrid = Self.segmentGrid(graph.edges.map { (graph.nodes[$0.from], graph.nodes[$0.to]) })
        nodeGrid = Self.pointGrid(graph.nodes)
        roadSegments = roads.flatMap { road in zip(road.points, road.points.dropFirst()).map { RoadSegment(a: $0.0, b: $0.1, width: CGFloat(road.width)) } }
        roadGrid = Self.segmentGrid(roadSegments.map { ($0.a, $0.b) }, padding: 12)
        buildingGrid = Self.rectGrid(buildings.map(\.rect))
        herdApproaches = makeHerdApproaches()
    }

    func nearestRoadPoint(to point: CGPoint) -> CGPoint {
        guard let edge = nearestEdge(to: point) else { return point }
        return edge.point
    }

    func roadDirection(at point: CGPoint) -> CGVector {
        guard let projection = nearestEdge(to: point) else { return CGVector(dx: 1, dy: 0) }
        let edge = navigationEdges[projection.edge]
        let a = navigationNodes[edge.from], b = navigationNodes[edge.to]
        let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
        return CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
    }

    func nearestNode(to point: CGPoint) -> Int {
        var best = 0
        var closest = CGFloat.infinity
        for ring in 0...Int(ceil(worldSize / Self.gridSize)) {
            for key in Self.ringKeys(around: point, ring: ring) {
                for index in nodeGrid[key] ?? [] {
                    let d = Self.squaredDistance(navigationNodes[index], point)
                    if d < closest { closest = d; best = index }
                }
            }
            if closest < pow(Self.distanceToOutsideGrid(point, ring: ring), 2) { break }
        }
        return best
    }

    /// Gameplay water excludes the deck of a bridge. The unchanged `water`
    /// polygons still describe the complete river or canal for rendering.
    func containsWater(_ point: CGPoint) -> Bool {
        guard water.contains(where: { Self.polygon($0.points, contains: point) }) else { return false }
        for road in roads where road.isBridge {
            for (a, b) in zip(road.points, road.points.dropFirst()) {
                let projected = Self.project(point, onto: a, b)
                let deckRadius = CGFloat(road.width) / 2
                if Self.squaredDistance(point, projected) <= deckRadius * deckRadius { return false }
            }
        }
        return true
    }

    func containsBuilding(_ point: CGPoint) -> Bool {
        for index in buildingGrid[Self.gridKey(point)] ?? [] {
            let building = buildings[index]
            if building.rect.contains(point) && Self.polygon(building.footprint, contains: point) { return true }
        }
        return false
    }

    /// Exact segment/footprint intersections, using the spatial building index.
    /// A narrow street next to a block stays visible; the opposite side does not.
    func hasLineOfSight(from start: CGPoint, to end: CGPoint,
                        excludingBuildings: Set<Int> = [], excludingLandmarks: Set<Int> = []) -> Bool {
        let lowX = min(start.x, end.x), highX = max(start.x, end.x)
        let lowY = min(start.y, end.y), highY = max(start.y, end.y)
        let low = Self.gridKey(CGPoint(x: lowX, y: lowY))
        let high = Self.gridKey(CGPoint(x: highX, y: highY))
        var candidates: Set<Int> = []
        for x in low.x...high.x { for y in low.y...high.y {
            candidates.formUnion(buildingGrid[GridKey(x: x, y: y)] ?? [])
        } }
        func intersects(_ polygon: [CGPoint]) -> Bool {
            if Self.polygon(polygon, contains: start) || Self.polygon(polygon, contains: end) { return true }
            guard polygon.count > 2 else { return false }
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                let rx = end.x - start.x, ry = end.y - start.y
                let sx = b.x - a.x, sy = b.y - a.y
                let denominator = rx * sy - ry * sx
                if abs(denominator) < 0.000_001 { continue }
                let qx = a.x - start.x, qy = a.y - start.y
                let t = (qx * sy - qy * sx) / denominator
                let u = (qx * ry - qy * rx) / denominator
                if t > 0.000_01 && t < 0.999_99 && u >= 0 && u <= 1 { return true }
            }
            return false
        }
        for index in candidates where !excludingBuildings.contains(index) {
            let building = buildings[index]
            if building.rect.maxX >= lowX && building.rect.minX <= highX && building.rect.maxY >= lowY && building.rect.minY <= highY,
               intersects(building.footprint) { return false }
        }
        for index in landmarks.indices where !excludingLandmarks.contains(index) {
            guard landmarks[index].kind != .mohammedSquare && landmarks[index].kind != .port else { continue }
            if intersects(landmarkFootprint(at: index)) { return false }
        }
        return true
    }

    /// Stable array indices let blast damage update only affected render chunks.
    /// Distance is to the footprint, so a hit on a wall damages a large building
    /// even when its center is outside the blast radius.
    func buildingIndices(near point: CGPoint, radius: Double) -> [Int] {
        let r = CGFloat(max(0, radius))
        let low = Self.gridKey(CGPoint(x: point.x - r, y: point.y - r))
        let high = Self.gridKey(CGPoint(x: point.x + r, y: point.y + r))
        var candidates: Set<Int> = []
        for x in low.x...high.x { for y in low.y...high.y {
            candidates.formUnion(buildingGrid[GridKey(x: x, y: y)] ?? [])
        } }
        return candidates.filter { distanceToBuilding(at: $0, from: point) <= radius }.sorted()
    }

    func distanceToBuilding(at index: Int, from point: CGPoint) -> Double {
        guard buildings.indices.contains(index) else { return .infinity }
        return Self.distanceToPolygon(buildings[index].footprint, from: point)
    }

    func landmarkFootprint(at index: Int) -> [CGPoint] {
        guard landmarkFootprints.indices.contains(index) else { return [] }
        return landmarkFootprints[index]
    }

    private static func makeLandmarkFootprint(_ landmark: MapLandmark) -> [CGPoint] {
        let c = CGFloat(cos(landmark.heading)), s = CGFloat(sin(landmark.heading))
        let halfX = landmark.size.width / 2, halfY = landmark.size.height / 2
        let corners: [CGPoint] = [CGPoint(x: -halfX, y: -halfY), CGPoint(x: halfX, y: -halfY),
                                 CGPoint(x: halfX, y: halfY), CGPoint(x: -halfX, y: halfY)]
        var rotated: [CGPoint] = []
        for corner in corners {
            let x = landmark.position.x + corner.x * c - corner.y * s
            let y = landmark.position.y + corner.x * s + corner.y * c
            rotated.append(CGPoint(x: x, y: y))
        }
        return rotated
    }

    func distanceToLandmark(at index: Int, from point: CGPoint) -> Double {
        Self.distanceToPolygon(landmarkFootprint(at: index), from: point)
    }

    private static func distanceToPolygon(_ footprint: [CGPoint], from point: CGPoint) -> Double {
        guard footprint.count > 2 else { return .infinity }
        if polygon(footprint, contains: point) { return 0 }
        return footprint.indices.reduce(Double.infinity) { result, index in
            min(result, Double(distance(point, project(point, onto: footprint[index], footprint[(index + 1) % footprint.count]))))
        }
    }

    func streetWidth(at point: CGPoint) -> Double {
        var bestDistance = CGFloat.infinity, width = metersToWorld * 5
        for index in roadGrid[Self.gridKey(point)] ?? [] {
            let segment = roadSegments[index]
            let d = Self.squaredDistance(point, Self.project(point, onto: segment.a, segment.b))
            if d < bestDistance { bestDistance = d; width = Double(segment.width) }
        }
        return width
    }

    private func makeHerdApproaches() -> [HerdApproach] {
        let candidates: [CGPoint]
        if city == .casablanca {
            candidates = [(33.49, -7.74), (33.48, -7.68), (33.51, -7.46),
                          (33.65, -7.45), (33.53, -7.78), (33.478, -7.515)].map {
                Self.casaPoint(latitude: $0.0, longitude: $0.1)
            }
        } else {
            candidates = [(33.0436, -7.625), (32.972, -7.626), (33.006, -7.658),
                          (33.011, -7.582), (32.976, -7.591)].map {
                Self.settatPoint(latitude: $0.0, longitude: $0.1)
            }
        }
        let focus = nearestRoadPoint(to: initialFocus)
        var density: [GridKey: Int] = [:]
        for building in buildings { density[Self.gridKey(CGPoint(x: building.rect.midX, y: building.rect.midY)), default: 0] += 1 }
        // Intersect the real road segment with the urban envelope, rather than
        // using its next graph node (which can be well inside the neighborhood).
        func envelopeEntry(from start: CGPoint, to end: CGPoint) -> CGPoint? {
            let bounds = urbanBounds
            let dx = end.x - start.x, dy = end.y - start.y
            var low: CGFloat = 0, high: CGFloat = 1
            func clipped(_ p: CGFloat, _ q: CGFloat) -> Bool {
                if abs(p) < 0.000_001 { return q >= 0 }
                let ratio = q / p
                if p < 0 { low = max(low, ratio) } else { high = min(high, ratio) }
                return low <= high
            }
            guard clipped(-dx, start.x - bounds.minX), clipped(dx, bounds.maxX - start.x),
                  clipped(-dy, start.y - bounds.minY), clipped(dy, bounds.maxY - start.y) else { return nil }
            return CGPoint(x: start.x + dx * low, y: start.y + dy * low)
        }
        var result: [HerdApproach] = []
        for requested in candidates {
            let distantSource = nearestRoadPoint(to: requested)
            let fullRoute = path(from: distantSource, to: focus)
            guard fullRoute.count > 2 else { continue }
            // Move source to the last rural approach just before built-up ingress.
            // This keeps actual road travel readable without spawning a city-centre horde.
            var ingressIndex = 1
            var exactIngress: CGPoint?
            if city == .settat {
                for index in fullRoute.indices.dropFirst() {
                    if let entry = envelopeEntry(from: fullRoute[index - 1], to: fullRoute[index]) {
                        ingressIndex = index
                        exactIngress = entry
                        break
                    }
                }
            } else {
                ingressIndex = fullRoute.indices.dropFirst().first { density[Self.gridKey(fullRoute[$0]), default: 0] >= 12 } ?? min(12, fullRoute.count - 1)
            }
            let ingress = exactIngress ?? fullRoute[ingressIndex]
            var sourceIndex = max(0, ingressIndex - 1)
            var length = Double(Self.distance(fullRoute[sourceIndex], ingress))
            // Reserve enough real approach road for a long, already assembled
            // crowd. Sparse OSM coverage must not pull Settat's origin into
            // its city/campus envelope merely because a density cell is low.
            let desiredDistance = city == .casablanca ? 90.0 : metersToWorld * 450
            while sourceIndex > 0 && (length < desiredDistance || (city == .settat && urbanBounds.contains(fullRoute[sourceIndex]))) {
                sourceIndex -= 1
                length += Double(Self.distance(fullRoute[sourceIndex], fullRoute[sourceIndex + 1]))
            }
            let source = fullRoute[sourceIndex]
            let approach = Array(fullRoute[sourceIndex..<ingressIndex]) + [ingress]
            let approachDistance = zip(approach, approach.dropFirst()).reduce(0.0) { $0 + Double(Self.distance($1.0, $1.1)) }
            guard !containsWater(source), isRoad(source), !containsBuilding(source), approachDistance > 1 else { continue }
            result.append(HerdApproach(source: source, ingress: ingress,
                                       route: approach + Array(fullRoute[ingressIndex...]), approachDistance: approachDistance))
        }
        return result
    }

    func isRoad(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let ring = max(0, Int(ceil(tolerance / Self.gridSize)))
        for key in Self.squareKeys(around: point, ring: ring) {
            for index in roadGrid[key] ?? [] {
                let segment = roadSegments[index]
                let projected = Self.project(point, onto: segment.a, segment.b)
                let limit = segment.width / 2 + tolerance
                if Self.squaredDistance(point, projected) <= limit * limit { return true }
            }
        }
        return false
    }

    /// Routes along the street graph. Endpoint projections remain on their actual
    /// street segments, preventing corner cutting through a block or river.
    func path(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        guard let startEdge = nearestEdge(to: start), let endEdge = nearestEdge(to: end) else { return [] }
        if startEdge.edge == endEdge.edge {
            return Self.compact([startEdge.point, endEdge.point])
        }
        // A* keeps local civilian/vehicle routes local even on Casablanca's
        // citywide network. Sparse scores avoid clearing eighty thousand nodes
        // for every short civilian movement.
        var distance: [Int: CGFloat] = [:]
        var previous: [Int: Int] = [:]
        var heap = MinHeap()
        func heuristic(_ node: Int) -> CGFloat { Self.distance(navigationNodes[node], endEdge.point) }
        let a = navigationEdges[startEdge.edge]
        for node in [a.from, a.to] {
            let cost = Self.distance(startEdge.point, navigationNodes[node])
            distance[node] = cost
            heap.push(node: node, priority: cost + heuristic(node))
        }
        let b = navigationEdges[endEdge.edge]
        var bestFinish = -1
        var bestCost = CGFloat.infinity
        while let item = heap.pop() {
            if item.priority > distance[item.node, default: .infinity] + heuristic(item.node) + 0.001 { continue }
            if item.priority > bestCost { break }
            if item.node == b.from || item.node == b.to {
                let cost = distance[item.node, default: .infinity] + Self.distance(navigationNodes[item.node], endEdge.point)
                if cost < bestCost {
                    bestFinish = item.node
                    bestCost = cost
                }
            }
            for neighbor in adjacency[item.node] {
                let candidate = distance[item.node, default: .infinity] + neighbor.cost
                if candidate < distance[neighbor.node, default: .infinity] {
                    distance[neighbor.node] = candidate
                    previous[neighbor.node] = item.node
                    heap.push(node: neighbor.node, priority: candidate + heuristic(neighbor.node))
                }
            }
        }
        guard bestFinish >= 0 else { return [startEdge.point] }
        var chain: [CGPoint] = []
        var current = bestFinish
        while current >= 0 {
            chain.append(navigationNodes[current])
            current = previous[current] ?? -1
        }
        return Self.compact([startEdge.point] + chain.reversed() + [endEdge.point])
    }

    private struct Neighbor {
        let node: Int
        let cost: CGFloat
    }

    private struct Projection {
        let edge: Int
        let point: CGPoint
    }

    private func nearestEdge(to point: CGPoint) -> Projection? {
        var best: Projection?
        var closest = CGFloat.infinity
        for ring in 0...Int(ceil(worldSize / Self.gridSize)) {
            for key in Self.ringKeys(around: point, ring: ring) {
                for index in edgeGrid[key] ?? [] {
                    let edge = navigationEdges[index]
                    let projected = Self.project(point, onto: navigationNodes[edge.from], navigationNodes[edge.to])
                    let distance = Self.squaredDistance(projected, point)
                    if distance < closest {
                        closest = distance
                        best = Projection(edge: index, point: projected)
                    }
                }
            }
            if closest < pow(Self.distanceToOutsideGrid(point, ring: ring), 2) { break }
        }
        return best
    }

    private static let gridSize: CGFloat = 64
    private struct GridKey: Hashable { let x: Int; let y: Int }
    private struct RoadSegment { let a: CGPoint; let b: CGPoint; let width: CGFloat }
    private typealias Graph = (nodes: [CGPoint], edges: [NavigationEdge], adjacency: [[Neighbor]])

    private static func gridKey(_ point: CGPoint) -> GridKey {
        GridKey(x: Int(floor(point.x / gridSize)), y: Int(floor(point.y / gridSize)))
    }

    private static func squareKeys(around point: CGPoint, ring: Int) -> [GridKey] {
        let key = gridKey(point)
        return (-ring...ring).flatMap { y in (-ring...ring).map { x in GridKey(x: key.x + x, y: key.y + y) } }
    }

    private static func ringKeys(around point: CGPoint, ring: Int) -> [GridKey] {
        let key = gridKey(point)
        if ring == 0 { return [key] }
        var keys: [GridKey] = []
        for x in -ring...ring {
            keys.append(GridKey(x: key.x + x, y: key.y - ring))
            keys.append(GridKey(x: key.x + x, y: key.y + ring))
        }
        for y in (-ring + 1)...(ring - 1) {
            keys.append(GridKey(x: key.x - ring, y: key.y + y))
            keys.append(GridKey(x: key.x + ring, y: key.y + y))
        }
        return keys
    }

    private static func distanceToOutsideGrid(_ point: CGPoint, ring: Int) -> CGFloat {
        let key = gridKey(point)
        return min(point.x - CGFloat(key.x - ring) * gridSize,
                   CGFloat(key.x + ring + 1) * gridSize - point.x,
                   point.y - CGFloat(key.y - ring) * gridSize,
                   CGFloat(key.y + ring + 1) * gridSize - point.y)
    }

    private static func pointGrid(_ points: [CGPoint]) -> [GridKey: [Int]] {
        var grid: [GridKey: [Int]] = [:]
        for (index, point) in points.enumerated() { grid[gridKey(point), default: []].append(index) }
        return grid
    }

    private static func rectGrid(_ rects: [CGRect]) -> [GridKey: [Int]] {
        var grid: [GridKey: [Int]] = [:]
        for (index, rect) in rects.enumerated() {
            let first = gridKey(rect.origin), last = gridKey(CGPoint(x: rect.maxX, y: rect.maxY))
            for y in first.y...last.y { for x in first.x...last.x { grid[GridKey(x: x, y: y), default: []].append(index) } }
        }
        return grid
    }

    private static func segmentGrid(_ segments: [(CGPoint, CGPoint)], padding: CGFloat = 0) -> [GridKey: [Int]] {
        let rects = segments.map { a, b in CGRect(x: min(a.x, b.x) - padding, y: min(a.y, b.y) - padding,
                                                width: abs(a.x - b.x) + padding * 2, height: abs(a.y - b.y) + padding * 2) }
        return rectGrid(rects)
    }

    private struct Layout {
        var roads: [MapRoad] = []
        var buildings: [MapBuilding] = []
        var parks: [CGRect] = []
        var water: [MapWater] = []
        var labels: [MapLabel] = []
        var landmarks: [MapLandmark] = []
        var graph: Graph?

        mutating func road(_ points: [(CGFloat, CGFloat)], width: Double = 12, name: String? = nil) {
            roads.append(MapRoad(points: points.map { CGPoint(x: $0.0, y: $0.1) }, width: width, name: name))
        }

        mutating func label(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            labels.append(MapLabel(position: CGPoint(x: x, y: y), text: text))
        }

    }

    /// Equirectangular projection centered on Casablanca. One game unit is
    /// about 4.26 meters. North is up; east increases x and south increases y.
    static func casaPoint(latitude: Double, longitude: Double) -> CGPoint {
        CGPoint(x: 75 + (longitude + 7.79) * 111_320 * cos(33.57 * .pi / 180) * 0.235,
                y: 800 + (33.67 - latitude) * 111_320 * 0.235)
    }

    /// Settat uses an approximately 8.5 km city-and-approaches extract, at
    /// 0.35 game units per meter. North is up, matching the OSM database.
    static func settatPoint(latitude: Double, longitude: Double) -> CGPoint {
        CGPoint(x: 100 + (longitude + 7.668) * 111_320 * cos(33.006 * .pi / 180) * 0.35,
                y: 100 + (33.044 - latitude) * 111_320 * 0.35)
    }

    private struct CasablancaData: Decodable {
        struct Road: Decodable {
            let p: [[Double]]; let w: Double; let name: String; let bridge: Bool
        }
        struct Building: Decodable { let p: [[Double]]; let h: Double; let s: Int }
        struct Park: Decodable { let p: [[Double]]; let name: String }
        let roads: [Road]
        let buildings: [Building]
        let coastline: [[[Double]]]
        let parks: [Park]
        let navigationNodes: [[Double]]
        let navigationEdges: [[Int]]
    }

    private static func bundledMap(_ filename: String) -> CasablancaData? {
        let candidates = [Bundle.main.url(forResource: filename, withExtension: "json"),
                          Bundle.main.url(forResource: filename, withExtension: "json", subdirectory: "Resources"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            .appendingPathComponent("Zomboys/Resources/\(filename).json")].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(CasablancaData.self, from: data) {
                return decoded
            }
        }
        return nil
    }
    private static let bundledCasablanca = bundledMap("CasablancaMap")
    private static let bundledSettat = bundledMap("SettatMap")

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points { minX = min(minX, point.x); maxX = max(maxX, point.x); minY = min(minY, point.y); maxY = max(maxY, point.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func settat() -> Layout {
        var map = Layout()
        map.landmarks = settatLandmarks()
        map.labels = [MapLabel(position: settatPoint(latitude: 33.0038013449, longitude: -7.6207871656), text: "SETTAT · CITY CENTER"),
                      MapLabel(position: settatPoint(latitude: 33.029, longitude: -7.6165), text: "HASSAN I UNIVERSITY"),
                      MapLabel(position: settatPoint(latitude: 32.993, longitude: -7.623), text: "RAILWAY QUARTER"),
                      MapLabel(position: settatPoint(latitude: 32.983, longitude: -7.602), text: "SOUTHERN APPROACH"),
                      MapLabel(position: settatPoint(latitude: 33.033, longitude: -7.643), text: "CHAOUIA COUNTRYSIDE")]
        guard let data = bundledSettat else {
            map.label("MAP DATA MISSING · SCHEMATIC FALLBACK", 1600, 1400)
            map.road([(1600, 60), (1600, 3140)], width: 5)
            map.road([(60, 1600), (3140, 1600)], width: 5)
            return map
        }
        func cg(_ pair: [Double]) -> CGPoint { CGPoint(x: pair[0], y: pair[1]) }
        map.roads = data.roads.map { MapRoad(points: $0.p.map(cg), width: $0.w, name: $0.name.isEmpty ? nil : $0.name, isBridge: $0.bridge) }
        map.buildings = data.buildings.map {
            let footprint = $0.p.map(cg)
            return MapBuilding(rect: bounds(footprint), style: $0.s, footprint: footprint, height: $0.h)
        }
        map.parks = data.parks.map { bounds($0.p.map(cg)) }.filter { $0.width > 1 && $0.height > 1 }
        let nodes = data.navigationNodes.map(cg)
        let edges = data.navigationEdges.map { NavigationEdge(from: $0[0], to: $0[1]) }
        var adjacency = Array(repeating: [Neighbor](), count: nodes.count)
        for edge in edges {
            let cost = distance(nodes[edge.from], nodes[edge.to])
            adjacency[edge.from].append(Neighbor(node: edge.to, cost: cost))
            adjacency[edge.to].append(Neighbor(node: edge.from, cost: cost))
        }
        map.graph = (nodes, edges, adjacency)
        // A dedicated original silhouette replaces each landmark parcel's OSM
        // mesh, avoiding duplicate structures and allowing independent damage.
        map.buildings.removeAll { building in
            map.landmarks.contains { landmark in
                CGRect(x: landmark.position.x - landmark.size.width / 2,
                       y: landmark.position.y - landmark.size.height / 2,
                       width: landmark.size.width, height: landmark.size.height)
                    .contains(CGPoint(x: building.rect.midX, y: building.rect.midY))
            }
        }
        return map
    }

    private static func settatLandmarks() -> [MapLandmark] {
        func mark(_ kind: MapLandmarkKind, _ name: String, _ lat: Double, _ lon: Double,
                  _ width: Double, _ depth: Double, _ height: Double, _ heading: Double = 0) -> MapLandmark {
            MapLandmark(kind: kind, position: settatPoint(latitude: lat, longitude: lon),
                        size: CGSize(width: width * 0.35, height: depth * 0.35),
                        heading: heading, height: height * 0.35, name: name)
        }
        // Locations come from OSM; authored silhouettes use approximate physical
        // dimensions, rather than claiming survey-quality architectural models.
        return [
            mark(.kasbah, "KASBAH ISMAILIA", 33.0038013449, -7.6207871656, 90, 57, 8),
            mark(.localMosque, "SIDI LOGHLIMI MOSQUE", 33.0040173246, -7.6201114001, 34, 29, 34),
            mark(.mohammedSquare, "PLACE MOHAMED V", 33.0017790, -7.6187798, 144, 69, 7),
            mark(.municipalPalace, "SETTAT MUNICIPAL PALACE", 33.0002455, -7.6192486, 64, 58, 12),
            mark(.university, "HASSAN I UNIVERSITY", 33.0247473, -7.6162166, 39, 35, 18),
            mark(.railwayStation, "SETTAT RAILWAY STATION", 32.9940142, -7.6233573, 31, 34, 12)]
    }

    private static func casablanca() -> Layout {
        var map = Layout()
        map.landmarks = casablancaLandmarks()
        let districtLocations: [(String, Double, Double)] = [
            ("AIN DIAB · CORNICHE", 33.589, -7.692), ("ANFA", 33.585, -7.666),
            ("BOURGOGNE", 33.600, -7.647), ("ANCIENNE MÉDINA", 33.601, -7.621),
            ("GAUTHIER", 33.591, -7.635), ("MAÂRIF", 33.581, -7.640),
            ("HABOUS", 33.575, -7.606), ("BELVÉDÈRE", 33.597, -7.596),
            ("HAY MOHAMMADI", 33.609, -7.563), ("SIDI MOUMEN", 33.610, -7.527),
            ("AIN SEBAÂ", 33.623, -7.523), ("SIDI BERNOUSSI", 33.631, -7.496),
            ("HAY HASSANI", 33.559, -7.680), ("LISSASFA", 33.532, -7.680),
            ("SIDI MAÂROUF", 33.531, -7.633), ("CALIFORNIE", 33.542, -7.609),
            ("ATLANTIC OCEAN", 33.641, -7.697)]
        map.labels = districtLocations.map { MapLabel(position: casaPoint(latitude: $0.1, longitude: $0.2), text: $0.0) }
        func cg(_ pair: [Double]) -> CGPoint { CGPoint(x: pair[0], y: pair[1]) }
        if let data = bundledCasablanca {
            map.roads = data.roads.map { MapRoad(points: $0.p.map(cg), width: $0.w, name: $0.name.isEmpty ? nil : $0.name, isBridge: $0.bridge) }
            map.buildings = data.buildings.map {
                let footprint = $0.p.map(cg)
                return MapBuilding(rect: bounds(footprint), style: $0.s, footprint: footprint, height: $0.h)
            }
            map.parks = data.parks.map { bounds($0.p.map(cg)) }.filter { $0.width > 1 && $0.height > 1 }
            let nodes = data.navigationNodes.map(cg)
            let edges = data.navigationEdges.map { NavigationEdge(from: $0[0], to: $0[1]) }
            var adjacency = Array(repeating: [Neighbor](), count: nodes.count)
            for edge in edges {
                let cost = distance(nodes[edge.from], nodes[edge.to])
                adjacency[edge.from].append(Neighbor(node: edge.to, cost: cost))
                adjacency[edge.to].append(Neighbor(node: edge.from, cost: cost))
            }
            map.graph = (nodes, edges, adjacency)
            let coast = joinedCoastline(data.coastline.map { $0.map(cg) })
            if let first = coast.first, let last = coast.last {
                map.water = [MapWater(points: [CGPoint(x: 0, y: 0), CGPoint(x: 8_000, y: 0),
                                               CGPoint(x: 8_000, y: last.y)] + coast.reversed() + [CGPoint(x: 0, y: first.y)])]
            }
            // Custom landmark models replace their original footprint meshes.
            map.buildings.removeAll { building in
                map.landmarks.contains { landmark in
                    let parcel = CGRect(x: landmark.position.x - landmark.size.width / 2,
                                        y: landmark.position.y - landmark.size.height / 2,
                                        width: landmark.size.width, height: landmark.size.height)
                    return parcel.contains(CGPoint(x: building.rect.midX, y: building.rect.midY))
                }
            }
        } else {
            // A clearly identified emergency fallback protects saved missions if
            // a development build omits its resource. Release validation checks
            // the real OSM data is bundled; this fallback is never called accurate.
            map.label("MAP DATA MISSING · SCHEMATIC FALLBACK", 3_600, 2_600)
            let locations = districtLocations.dropLast().map { casaPoint(latitude: $0.1, longitude: $0.2) }
            for pair in zip(locations, locations.dropFirst()) {
                map.roads.append(MapRoad(points: [pair.0, pair.1], width: 8))
            }
            map.water = [MapWater(points: points([(0, 0), (8_000, 0), (8_000, 1300), (4200, 1900), (3000, 2800), (0, 4200)]))]
        }
        return map
    }

    private static func joinedCoastline(_ input: [[CGPoint]]) -> [CGPoint] {
        var chains = input.filter { $0.count > 1 }
        var merged = true
        while merged {
            merged = false
            outer: for i in chains.indices {
                for j in chains.indices where j > i {
                    let a = chains[i], b = chains[j]
                    let joined: [CGPoint]?
                    if squaredDistance(a.last!, b.first!) < 0.05 { joined = a + b.dropFirst() }
                    else if squaredDistance(a.first!, b.last!) < 0.05 { joined = b + a.dropFirst() }
                    else if squaredDistance(a.first!, b.first!) < 0.05 { joined = Array(a.reversed()) + b.dropFirst() }
                    else if squaredDistance(a.last!, b.last!) < 0.05 { joined = a + b.reversed().dropFirst() }
                    else { joined = nil }
                    if let joined { chains[i] = joined; chains.remove(at: j); merged = true; break outer }
                }
            }
        }
        var coast = chains.max { polylineLength($0) < polylineLength($1) } ?? []
        if let first = coast.first, let last = coast.last, first.x > last.x { coast.reverse() }
        return coast
    }

    private static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func casablancaLandmarks() -> [MapLandmark] {
        func mark(_ kind: MapLandmarkKind, _ name: String, _ lat: Double, _ lon: Double,
                  _ width: Double, _ depth: Double, _ height: Double, _ heading: Double = 0) -> MapLandmark {
            MapLandmark(kind: kind, position: casaPoint(latitude: lat, longitude: lon),
                        size: CGSize(width: width * 0.235, height: depth * 0.235),
                        heading: heading, height: height * 0.235, name: name)
        }
        // Landmark locations are georeferenced. The models are authored game
        // interpretations; dimensions below are approximate presentation sizes.
        return [
            mark(.mosque, "HASSAN II MOSQUE", 33.6085, -7.6326, 250, 180, 210, -0.26),
            mark(.twinCenter, "TWIN CENTER", 33.5865844, -7.6322923, 120, 100, 115, 0.32),
            mark(.moroccoMall, "MOROCCO MALL", 33.5758, -7.70685, 420, 180, 24, -0.38),
            mark(.cathedral, "SACRÉ-CŒUR", 33.59119, -7.62450, 95, 52, 38, 0.20),
            mark(.mohammedSquare, "PLACE MOHAMMED V", 33.5904, -7.6188, 230, 180, 28, 0.10),
            mark(.port, "PORT OF CASABLANCA", 33.6080, -7.6054, 700, 380, 60, -0.28),
            mark(.clockTower, "MÉDINA CLOCK TOWER", 33.5992, -7.6187, 12, 12, 25),
            mark(.lighthouse, "EL HANK LIGHTHOUSE", 33.6099770, -7.6547193, 25, 25, 51),
            mark(.stadium, "STADE MOHAMMED V", 33.5827, -7.6465, 260, 215, 34, 0.18),
            mark(.railwayStation, "CASA VOYAGEURS", 33.5899958, -7.5900469, 290, 95, 22, -0.15),
            mark(.railwayStation, "CASA PORT", 33.5993825, -7.6123131, 240, 110, 20, -0.32)]
    }

    private static func points(_ coordinates: [(CGFloat, CGFloat)]) -> [CGPoint] {
        coordinates.map { CGPoint(x: $0.0, y: $0.1) }
    }

    private static func makeGraph(roads: [MapRoad]) -> (nodes: [CGPoint], edges: [NavigationEdge], adjacency: [[Neighbor]]) {
        let segments = roads.flatMap { road in zip(road.points, road.points.dropFirst()).map { ($0.0, $0.1) } }
        var cuts = Array(repeating: [CGFloat(0), CGFloat(1)], count: segments.count)
        for i in segments.indices {
            for j in segments.indices where j > i {
                let a = segments[i]
                let b = segments[j]
                if let hit = intersection(a.0, a.1, b.0, b.1) {
                    cuts[i].append(hit.first)
                    cuts[j].append(hit.second)
                } else {
                    // Preserve intersections at shared endpoints and overlapping
                    // boulevards even when two segments are collinear.
                    for point in [b.0, b.1] {
                        if let t = parameter(point, on: a.0, a.1) { cuts[i].append(t) }
                    }
                    for point in [a.0, a.1] {
                        if let t = parameter(point, on: b.0, b.1) { cuts[j].append(t) }
                    }
                }
            }
        }
        var nodes: [CGPoint] = []
        var indices: [String: Int] = [:]
        func index(for point: CGPoint) -> Int {
            let key = "\(Int((point.x * 100).rounded())):\(Int((point.y * 100).rounded()))"
            if let existing = indices[key] { return existing }
            let next = nodes.count
            indices[key] = next
            nodes.append(point)
            return next
        }
        var edges: [NavigationEdge] = []
        var seen: Set<String> = []
        for i in segments.indices {
            let line = segments[i]
            let sorted = uniqueSorted(cuts[i])
            for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 0.00001 {
                let from = index(for: interpolate(line.0, line.1, a))
                let to = index(for: interpolate(line.0, line.1, b))
                guard from != to else { continue }
                let key = "\(min(from, to)):\(max(from, to))"
                if seen.insert(key).inserted { edges.append(NavigationEdge(from: from, to: to)) }
            }
        }
        var adjacency = Array(repeating: [Neighbor](), count: nodes.count)
        for edge in edges {
            let cost = distance(nodes[edge.from], nodes[edge.to])
            adjacency[edge.from].append(Neighbor(node: edge.to, cost: cost))
            adjacency[edge.to].append(Neighbor(node: edge.from, cost: cost))
        }
        return (nodes, edges, adjacency)
    }

    private static func uniqueSorted(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values.sorted() {
            if result.last.map({ abs($0 - value) > 0.00001 }) ?? true { result.append(value) }
        }
        return result
    }

    private static func project(_ point: CGPoint, onto a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0.0001 else { return a }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return interpolate(a, b, t)
    }

    private static func parameter(_ point: CGPoint, on a: CGPoint, _ b: CGPoint) -> CGFloat? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0.0001 else { return nil }
        let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / length
        guard t >= -0.00001, t <= 1.00001,
              squaredDistance(interpolate(a, b, t), point) < 0.001 else { return nil }
        return max(0, min(1, t))
    }

    private static func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(squaredDistance(a, b))
    }

    private static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> (first: CGFloat, second: CGFloat)? {
        let rx = b.x - a.x
        let ry = b.y - a.y
        let sx = d.x - c.x
        let sy = d.y - c.y
        let denominator = rx * sy - ry * sx
        guard abs(denominator) > 0.00001 else { return nil }
        let dx = c.x - a.x
        let dy = c.y - a.y
        let t = (dx * sy - dy * sx) / denominator
        let u = (dx * ry - dy * rx) / denominator
        guard t >= -0.00001, t <= 1.00001, u >= -0.00001, u <= 1.00001 else { return nil }
        return (max(0, min(1, t)), max(0, min(1, u)))
    }

    private static func closedSegments(_ points: [CGPoint]) -> [(CGPoint, CGPoint)] {
        guard points.count > 1 else { return [] }
        return points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
    }

    private static func polygon(_ vertices: [CGPoint], contains point: CGPoint) -> Bool {
        guard vertices.count > 2 else { return false }
        var inside = false
        var j = vertices.count - 1
        for i in vertices.indices {
            let a = vertices[i]
            let b = vertices[j]
            if (a.y > point.y) != (b.y > point.y) {
                let crossX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossX { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for (c, d) in closedSegments(corners) {
            if intersection(a, b, c, d) != nil { return true }
        }
        return false
    }

    private static func compact(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if result.last.map({ squaredDistance($0, point) > 0.01 }) ?? true { result.append(point) }
        }
        return result
    }

    private struct MinHeap {
        struct Item {
            let node: Int
            let priority: CGFloat
        }
        var items: [Item] = []

        mutating func push(node: Int, priority: CGFloat) {
            items.append(Item(node: node, priority: priority))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].priority < items[parent].priority else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Item? {
            guard !items.isEmpty else { return nil }
            if items.count == 1 { return items.removeLast() }
            let first = items[0]
            items[0] = items.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < items.count else { break }
                let right = left + 1
                let child = right < items.count && items[right].priority < items[left].priority ? right : left
                guard items[child].priority < items[parent].priority else { break }
                items.swapAt(parent, child)
                parent = child
            }
            return first
        }
    }
}
