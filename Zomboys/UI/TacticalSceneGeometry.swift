import SceneKit
import UIKit

/// Batched meshes keep a city of individual footprints inexpensive to draw.
struct CityMesh {
    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var indices: [[Int32]] = []

    init(materialCount: Int = 1) { indices = Array(repeating: [], count: materialCount) }

    mutating func append(_ mesh:CityMesh) {
        let base = Int32(vertices.count)
        vertices.append(contentsOf:mesh.vertices); normals.append(contentsOf:mesh.normals)
        while indices.count < mesh.indices.count { indices.append([]) }
        for (material,element) in mesh.indices.enumerated() {
            indices[material].append(contentsOf:element.map { $0+base })
        }
    }

    mutating func triangle(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, normal: SCNVector3, material: Int = 0) {
        let base = Int32(vertices.count)
        vertices.append(contentsOf: [a, b, c]); normals.append(contentsOf: [normal, normal, normal])
        indices[material].append(contentsOf: [base, base + 1, base + 2])
    }

    mutating func quad(_ a: SCNVector3, _ b: SCNVector3, _ c: SCNVector3, _ d: SCNVector3, normal: SCNVector3, material: Int = 0) {
        let base = Int32(vertices.count)
        vertices.append(contentsOf: [a, b, c, d])
        normals.append(contentsOf: [normal, normal, normal, normal])
        indices[material].append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    mutating func box(center: SCNVector3, width: Double, height: Double, depth: Double, material: Int = 0) {
        let x0 = center.x - Float(width / 2), x1 = center.x + Float(width / 2)
        let y0 = center.y - Float(height / 2), y1 = center.y + Float(height / 2)
        let z0 = center.z - Float(depth / 2), z1 = center.z + Float(depth / 2)
        quad(SCNVector3(x0,y1,z0), SCNVector3(x0,y1,z1), SCNVector3(x1,y1,z1), SCNVector3(x1,y1,z0), normal: SCNVector3(0,1,0), material: material)
        quad(SCNVector3(x0,y0,z1), SCNVector3(x0,y0,z0), SCNVector3(x1,y0,z0), SCNVector3(x1,y0,z1), normal: SCNVector3(0,-1,0), material: material)
        quad(SCNVector3(x0,y0,z1), SCNVector3(x1,y0,z1), SCNVector3(x1,y1,z1), SCNVector3(x0,y1,z1), normal: SCNVector3(0,0,1), material: material)
        quad(SCNVector3(x1,y0,z0), SCNVector3(x0,y0,z0), SCNVector3(x0,y1,z0), SCNVector3(x1,y1,z0), normal: SCNVector3(0,0,-1), material: material)
        quad(SCNVector3(x1,y0,z1), SCNVector3(x1,y0,z0), SCNVector3(x1,y1,z0), SCNVector3(x1,y1,z1), normal: SCNVector3(1,0,0), material: material)
        quad(SCNVector3(x0,y0,z0), SCNVector3(x0,y0,z1), SCNVector3(x0,y1,z1), SCNVector3(x0,y1,z0), normal: SCNVector3(-1,0,0), material: material)
    }

    mutating func orientedBox(center: SCNVector3, width: Double, height: Double, depth: Double,
                              yaw: Double, material: Int = 0) {
        var local = CityMesh()
        local.box(center:SCNVector3Zero,width:width,height:height,depth:depth)
        let offset = Int32(vertices.count),c = Float(cos(yaw)),s = Float(sin(yaw))
        vertices.append(contentsOf:local.vertices.map { p in SCNVector3(center.x+p.x*c+p.z*s,center.y+p.y,center.z-p.x*s+p.z*c) })
        normals.append(contentsOf:local.normals.map { n in SCNVector3(n.x*c+n.z*s,n.y,-n.x*s+n.z*c) })
        indices[material].append(contentsOf:local.indices[0].map { $0+offset })
    }

    /// A gate removes a real interval from the paid wall mesh. Geometry and
    /// movement share the same 2.2 m passage radius rather than drawing a solid
    /// wall behind an otherwise functioning gate.
    mutating func barricade(path: [CGPoint], apertures: [CGPoint], metersToWorld: Double) {
        let radius = metersToWorld * 2.2
        for (a,b) in zip(path,path.dropFirst()) {
            let dx = Double(b.x-a.x), dz = Double(b.y-a.y), length = hypot(dx,dz)
            guard length > 0.001 else { continue }
            var cuts: [(Double,Double)] = []
            for gate in apertures {
                let along = (Double(gate.x-a.x)*dx+Double(gate.y-a.y)*dz)/length
                let across = abs(Double(gate.x-a.x)*dz-Double(gate.y-a.y)*dx)/length
                guard across < radius else { continue }
                let half = sqrt(max(0,radius*radius-across*across))
                let lower = max(0,along-half), upper = min(length,along+half)
                if lower < upper { cuts.append((lower,upper)) }
            }
            cuts.sort { $0.0 < $1.0 }
            var cursor = 0.0
            func point(_ distance: Double) -> CGPoint {
                CGPoint(x:Double(a.x)+dx*distance/length,y:Double(a.y)+dz*distance/length)
            }
            func appendSegment(_ from: Double,_ to: Double,_ mesh: inout CityMesh) {
                guard to-from > 0.001 else { return }
                let start = point(from), end = point(to)
                mesh.orientedBox(center:SCNVector3(Float((start.x+end.x)/2),Float(0.3+metersToWorld*0.625),Float((start.y+end.y)/2)),
                                 width:to-from,height:metersToWorld*1.25,depth:metersToWorld*0.5,yaw:-atan2(dz,dx))
            }
            for cut in cuts {
                appendSegment(cursor,cut.0,&self)
                cursor = max(cursor,cut.1)
            }
            appendSegment(cursor,length,&self)
        }
    }

    mutating func strip(from a: CGPoint, to b: CGPoint, width: Double, altitude: Double = 0.2, material: Int = 0) {
        let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
        let ox = -(b.y - a.y) / length * width / 2, oz = (b.x - a.x) / length * width / 2
        quad(SCNVector3(Float(a.x + ox),Float(altitude),Float(a.y + oz)),
             SCNVector3(Float(b.x + ox),Float(altitude),Float(b.y + oz)),
             SCNVector3(Float(b.x - ox),Float(altitude),Float(b.y - oz)),
             SCNVector3(Float(a.x - ox),Float(altitude),Float(a.y - oz)), normal: SCNVector3(0,1,0), material: material)
    }

    /// Shared-vertex dots avoid triangulation work for dense crowds.
    mutating func dot(at p: CGPoint, radius: Double, altitude: Double, material: Int = 0) {
        let base = Int32(vertices.count)
        vertices.append(SCNVector3(Float(p.x),Float(altitude),Float(p.y)))
        normals.append(SCNVector3(0,1,0))
        for i in 0..<6 {
            let angle = Double(i)*Double.pi/3
            vertices.append(SCNVector3(Float(Double(p.x)+cos(angle)*radius),Float(altitude),Float(Double(p.y)+sin(angle)*radius)))
            normals.append(SCNVector3(0,1,0))
        }
        for i in 0..<6 { indices[material].append(contentsOf:[base,base+Int32((i+1)%6)+1,base+Int32(i)+1]) }
    }

    mutating func polygon(_ input: [CGPoint], altitude: Double, material: Int = 0) {
        var points = input
        if points.count > 3, points.first == points.last { points.removeLast() }
        guard points.count >= 3 else { return }
        var remaining = Array(points.indices)
        var area: CGFloat = 0
        for i in points.indices {
            let a = points[i], b = points[(i+1)%points.count]
            area += a.x*b.y-b.x*a.y
        }
        if area < 0 { remaining.reverse() }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        func inside(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            cross(a,b,p) >= -0.001 && cross(b,c,p) >= -0.001 && cross(c,a,p) >= -0.001
        }
        var attempts = 0
        while remaining.count > 2 && attempts < points.count * points.count {
            var clipped = false
            for j in remaining.indices {
                let ia = remaining[(j + remaining.count - 1) % remaining.count]
                let ib = remaining[j], ic = remaining[(j + 1) % remaining.count]
                let a = points[ia], b = points[ib], c = points[ic]
                guard cross(a,b,c) > 0.0001 else { continue }
                guard !remaining.contains(where: { $0 != ia && $0 != ib && $0 != ic && inside(points[$0],a,b,c) }) else { continue }
                triangle(SCNVector3(Float(a.x),Float(altitude),Float(a.y)), SCNVector3(Float(c.x),Float(altitude),Float(c.y)), SCNVector3(Float(b.x),Float(altitude),Float(b.y)), normal: SCNVector3(0,1,0), material: material)
                remaining.remove(at: j); clipped = true; break
            }
            if !clipped { break }; attempts += 1
        }
    }

    func geometry(materials: [SCNMaterial]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices), normal = SCNGeometrySource(normals: normals)
        let elements = indices.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        let result = SCNGeometry(sources: [source, normal], elements: elements)
        result.materials = materials
        return result
    }
}

@MainActor
enum CityModels {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static func material(_ hex: UInt32, emission: UInt32? = nil, alpha: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = color(hex, alpha: alpha); m.lightingModel = .lambert
        m.roughness.contents = 0.85; m.isDoubleSided = true
        if let emission { m.emission.contents = color(emission) }
        if alpha < 1 { m.transparency = alpha; m.writesToDepthBuffer = false }
        return m
    }
    static func box(_ width: Double, _ height: Double, _ depth: Double, color: UInt32, at: SCNVector3 = SCNVector3Zero, chamfer: Double = 0) -> SCNNode {
        let geometry = SCNBox(width: width, height: height, length: depth, chamferRadius: chamfer)
        geometry.materials = [material(color)]; let node = SCNNode(geometry: geometry); node.position = at; return node
    }
    static func cylinder(_ radius: Double, _ height: Double, color: UInt32, at: SCNVector3 = SCNVector3Zero, sides: Int = 12) -> SCNNode {
        let geometry = SCNCylinder(radius: radius, height: height); geometry.radialSegmentCount = sides; geometry.materials = [material(color)]
        let node = SCNNode(geometry: geometry); node.position = at; return node
    }
    static func sphere(_ radius: Double, color: UInt32, at: SCNVector3 = SCNVector3Zero) -> SCNNode {
        let geo = SCNSphere(radius: radius); geo.segmentCount = 10; geo.materials = [material(color)]
        let node = SCNNode(geometry: geo); node.position = at; return node
    }
    static func line(from a: SCNVector3, to b: SCNVector3, radius: Double, color: UInt32, glowing: Bool = false) -> SCNNode {
        let dx = b.x-a.x, dy = b.y-a.y, dz = b.z-a.z
        let length = sqrt(dx*dx + dy*dy + dz*dz)
        let geometry = SCNCylinder(radius: radius, height: CGFloat(length)); geometry.radialSegmentCount = 6
        geometry.materials = [material(color, emission: glowing ? color : nil)]
        let n = SCNNode(geometry: geometry); n.position = SCNVector3((a.x+b.x)/2,(a.y+b.y)/2,(a.z+b.z)/2)
        n.look(at: b, up: SCNVector3(0,1,0), localFront: SCNVector3(0,1,0)); return n
    }

    /// Vehicle dimensions are meters. The coordinator applies map scale once;
    /// zoom changes markers, never the truck's footprint on the roadway.
    static func humvee() -> SCNNode {
        let root = SCNNode()
        root.addChildNode(box(2.02,0.55,4.6,color:0x7D8157,at:SCNVector3(0,0.87,0),chamfer:0.1))
        root.addChildNode(box(1.85,0.8,2.15,color:0x899066,at:SCNVector3(0,1.48,0.12),chamfer:0.12))
        root.addChildNode(box(1.58,0.43,0.045,color:0x29454C,at:SCNVector3(0,1.59,-1)))
        root.addChildNode(box(1.58,0.43,0.045,color:0x29454C,at:SCNVector3(0,1.59,1.22)))
        for x: Float in [-0.94,0.94] {
            root.addChildNode(box(0.035,0.42,0.7,color:0x29454C,at:SCNVector3(x,1.58,-0.35)))
            root.addChildNode(box(0.035,0.42,0.7,color:0x29454C,at:SCNVector3(x,1.58,0.5)))
        }
        root.addChildNode(box(2.1,0.24,0.16,color:0x303A31,at:SCNVector3(0,0.65,-2.38)))
        root.addChildNode(box(2.1,0.24,0.16,color:0x303A31,at:SCNVector3(0,0.65,2.38)))
        for (i,x) in [-0.93,0.93].enumerated() { for (j,z) in [-1.45,1.45].enumerated() {
            let pivot = SCNNode(); pivot.name = "wheel.\(i).\(j)"; pivot.position = SCNVector3(Float(x),0.42,Float(z))
            let tire = cylinder(0.42,0.34,color:0x141B1B,sides:12)
            tire.eulerAngles.z = .pi/2; pivot.addChildNode(tire)
            let hub = cylinder(0.22,0.36,color:0x555E4E,sides:8); hub.eulerAngles.z = .pi/2; pivot.addChildNode(hub)
            // A colored lug lets wheel rotation be perceived rather than making
            // the tire appear to slide along the pavement.
            pivot.addChildNode(box(0.37,0.075,0.075,color:0x89937C,at:SCNVector3(0,0.2,0)))
            root.addChildNode(pivot)
        } }
        let turret = SCNNode(); turret.name = "turret"; turret.position = SCNVector3(0,1.92,0)
        turret.addChildNode(cylinder(0.45,0.14,color:0x59654A))
        turret.addChildNode(box(0.34,0.3,0.52,color:0x485840,at:SCNVector3(0,0.2,-0.04)))
        turret.addChildNode(line(from:SCNVector3(0,0.22,-0.25),to:SCNVector3(0,0.22,-1.04),radius:0.04,color:0x25332D))
        root.addChildNode(turret)
        for x: Float in [-0.73,0.73] {
            let light = box(0.22,0.18,0.03,color:0xEDDFC0,at:SCNVector3(x,0.88,-2.31))
            light.geometry?.firstMaterial?.emission.contents = color(0xE7DBAE); root.addChildNode(light)
        }
        root.addChildNode(line(from:SCNVector3(0.87,1.8,1),to:SCNVector3(0.87,3,1),radius:0.013,color:0x29382C))
        return root
    }

    static func mortar() -> SCNNode {
        let root = SCNNode()
        root.addChildNode(cylinder(0.28,0.045,color:0x505B43,at:SCNVector3(0,0.06,0)))
        root.addChildNode(line(from:SCNVector3(0,0.1,0.18),to:SCNVector3(0,0.95,-0.22),radius:0.07,color:0x6E7F51))
        for x: Float in [-0.25,0.25] { root.addChildNode(line(from:SCNVector3(x,0.05,-0.28),to:SCNVector3(0,0.55,-0.06),radius:0.022,color:0x384D33)) }
        return root
    }

    /// Original compact street equipment, in meters like the other models.
    static func civilianGate() -> SCNNode {
        let root = SCNNode()
        for side in [-1.0,1.0] {
            root.addChildNode(box(0.42,2.1,0.55,color:0x456B7A,at:SCNVector3(Float(side*2.45),1.05,0),chamfer:0.05))
            root.addChildNode(box(0.46,0.16,0.6,color:0x9ED9E9,at:SCNVector3(Float(side*2.45),2.16,0)))
            // Open leaves sit beside the passage, leaving its center visible
            // even from straight overhead. The simulation controls admission.
            let leaf = box(1.5,0.65,0.09,color:0x7298A5,at:SCNVector3(Float(side*1.92),0.95,-0.65))
            leaf.eulerAngles.y = Float(side*0.95); root.addChildNode(leaf)
        }
        var arrow = CityMesh()
        arrow.polygon([CGPoint(x:0,y:-1.35),CGPoint(x:0.55,y:-0.5),CGPoint(x:0.18,y:-0.5),CGPoint(x:0.18,y:1.1),CGPoint(x:-0.18,y:1.1),CGPoint(x:-0.18,y:-0.5),CGPoint(x:-0.55,y:-0.5)],altitude:0.04)
        root.addChildNode(SCNNode(geometry:arrow.geometry(materials:[material(0x9ED9E9,emission:0x285362)])))
        return root
    }

    static func explosive(remote: Bool) -> SCNNode {
        let root = SCNNode()
        if remote {
            for side: Float in [-0.19,0.19] {
                root.addChildNode(box(0.34,0.18,0.6,color:0x657350,at:SCNVector3(side,0.1,0),chamfer:0.035))
                root.addChildNode(box(0.37,0.03,0.11,color:0xB3AB7B,at:SCNVector3(side,0.2,0.1)))
            }
            root.addChildNode(box(0.23,0.12,0.27,color:0x3E4740,at:SCNVector3(0,0.22,-0.15)))
        } else {
            root.addChildNode(cylinder(0.44,0.15,color:0x697552,at:SCNVector3(0,0.09,0),sides:10))
            root.addChildNode(cylinder(0.27,0.07,color:0xA79F6E,at:SCNVector3(0,0.19,0),sides:10))
        }
        let indicator = box(0.1,0.055,0.1,color:0xE4B875,at:SCNVector3(0,0.31,remote ? -0.15 : 0))
        indicator.name = "armingIndicator"; root.addChildNode(indicator)
        return root
    }

    static func station(evacuation: Bool) -> SCNNode {
        let root = SCNNode()
        let tint: UInt32 = evacuation ? 0x4C9B96 : 0x697B4E
        root.addChildNode(box(5.8,2.2,4.2,color:tint,at:SCNVector3(0,1.1,0),chamfer:0.1))
        let roof = SCNPyramid(width:6.2,height:1.1,length:4.6); roof.materials = [material(evacuation ? 0x76D5C3 : 0xA7BA71)]
        let node = SCNNode(geometry:roof); node.position = SCNVector3(0,2.2,0); root.addChildNode(node)
        root.addChildNode(box(0.9,1.75,0.045,color:0x153438,at:SCNVector3(0,0.88,2.12)))
        root.addChildNode(box(1.3,0.85,0.04,color:0xACE1D4,at:SCNVector3(-1.85,1.2,2.13)))
        if evacuation {
            root.addChildNode(box(1.4,0.14,0.14,color:0xD5ECE2,at:SCNVector3(0,3.3,0)))
            root.addChildNode(box(0.14,0.14,1.4,color:0xD5ECE2,at:SCNVector3(0,3.3,0)))
        }
        return root
    }

    static func aircraft(_ kind: UnitKind) -> SCNNode {
        let root = SCNNode()
        if kind == .b2 {
            var mesh = CityMesh()
            mesh.polygon([CGPoint(x:0,y:-29),CGPoint(x:46,y:10),CGPoint(x:22,y:7),CGPoint(x:17,y:17),CGPoint(x:7,y:12),CGPoint(x:0,y:20),CGPoint(x:-7,y:12),CGPoint(x:-17,y:17),CGPoint(x:-22,y:7),CGPoint(x:-46,y:10)],altitude:0)
            let wing = SCNNode(geometry:mesh.geometry(materials:[material(0x353F49)])); root.addChildNode(wing)
            root.addChildNode(box(8,2,19,color:0x48515B,at:SCNVector3(0,0.8,-7),chamfer:1))
            root.addChildNode(box(5,0.4,5,color:0x183C4B,at:SCNVector3(0,2.1,-12),chamfer:0.4))
            for x: Float in [-11,11] { root.addChildNode(box(4,0.8,8,color:0x20282E,at:SCNVector3(x,0.5,3))) }
            root.addChildNode(box(7,0.35,9,color:0x10191E,at:SCNVector3(0,-0.3,2)))
            for x: Float in [-3.5,3.5] {
                let pivot = SCNNode(); pivot.name = x < 0 ? "bombBay.port" : "bombBay.starboard"; pivot.position = SCNVector3(x,-0.4,2)
                pivot.addChildNode(box(3.5,0.15,9,color:0x3C454F,at:SCNVector3(x < 0 ? 1.75 : -1.75,0,0))); root.addChildNode(pivot)
            }
        } else {
            let ac130 = kind == .ac130
            let fuselageLength: Double = ac130 ? 55 : 38
            let radius: Double = ac130 ? 3.7 : 2.5
            let body = cylinder(radius,fuselageLength,color:ac130 ? 0x83918D : 0x939D9B,sides:12)
            body.eulerAngles.x = .pi/2; root.addChildNode(body)
            let nose = sphere(radius,color:0x657773,at:SCNVector3(0,0,Float(-fuselageLength/2)))
            nose.scale = SCNVector3(1,0.7,1.4); root.addChildNode(nose)
            root.addChildNode(box(ac130 ? 69 : 48,1.3,ac130 ? 8 : 7,color:ac130 ? 0x899A91 : 0x9BACAA,at:SCNVector3(0,1,ac130 ? -3 : 1)))
            root.addChildNode(box(ac130 ? 25 : 22,1,5,color:0x708681,at:SCNVector3(0,2,Float(fuselageLength/2-5))))
            root.addChildNode(box(1,10,9,color:0x728782,at:SCNVector3(0,6,Float(fuselageLength/2-6))))
            root.addChildNode(box(4,1.1,5,color:0x183E4D,at:SCNVector3(0,Float(radius+0.3),Float(-fuselageLength/2+7)),chamfer:0.5))
            if ac130 {
                for x: Float in [-26,-13,13,26] {
                    let engine = cylinder(2,10,color:0x5D716B,at:SCNVector3(x,0,-6)); engine.eulerAngles.x = .pi/2; root.addChildNode(engine)
                    let propeller = SCNNode(); propeller.position = SCNVector3(x,0,-12)
                    propeller.addChildNode(box(0.8,12,0.4,color:0xCDD9C9)); propeller.addChildNode(box(12,0.8,0.4,color:0xCDD9C9))
                    propeller.name = "propeller.\(Int(x))"; root.addChildNode(propeller)
                }
                root.addChildNode(line(from:SCNVector3(-3,0,7),to:SCNVector3(-12,-1,7),radius:1,color:0x344B43))
                root.addChildNode(line(from:SCNVector3(-3,0,14),to:SCNVector3(-9,0,14),radius:0.6,color:0x344B43))
            } else {
                for x: Float in [-6,6] {
                    let nacelle = cylinder(3,13,color:0x738682,at:SCNVector3(x,4,12)); nacelle.eulerAngles.x = .pi/2; root.addChildNode(nacelle)
                    let intake = cylinder(2.1,0.5,color:0x182F32,at:SCNVector3(x,4,5.4)); intake.eulerAngles.x = .pi/2; root.addChildNode(intake)
                    root.addChildNode(box(1,8,6,color:0x819792,at:SCNVector3(x,6,17)))
                }
                for angle in stride(from:0.0,to:Double.pi*2,by:Double.pi/4) { root.addChildNode(line(from:SCNVector3(Float(cos(angle)*0.7),Float(sin(angle)*0.7),-18),to:SCNVector3(Float(cos(angle)*0.7),Float(sin(angle)*0.7),-23),radius:0.15,color:0x243E3B)) }
                for x: Float in [-19,-11,11,19] { root.addChildNode(box(1.5,2,5,color:0x3F6058,at:SCNVector3(x,-1,1))) }
            }
        }
        for x: Float in [-23,23] {
            let light = sphere(0.6,color:x < 0 ? 0xFF5F50 : 0x88EA93,at:SCNVector3(x,1,2))
            light.geometry?.firstMaterial?.emission.contents = color(x < 0 ? 0xFF5F50 : 0x88EA93); root.addChildNode(light)
        }
        return root
    }
}
