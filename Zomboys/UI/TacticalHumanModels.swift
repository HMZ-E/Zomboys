import SceneKit
import UIKit

/// Small original articulated silhouettes are baked into a shared mesh instead
/// of giving every person a node, skeleton and independent animation timer.
enum TacticalHumanRole { case civilian, zombie, soldier, sniper }

struct TacticalHumanPose {
    var position: CGPoint
    var heading: Double
    var stride: Double
    var speed: Double
    var variant: Int
    var role: TacticalHumanRole
}

@MainActor
enum TacticalHumanModels {
    // One source for overhead role colors, including the Metal shader palette.
    nonisolated static let pointRoleColors: [UInt32] = [0xEEF2E7,0x89DF4C,0xA0B26E,0xD2B277]
    nonisolated static func pointShaderColor(_ index: Int) -> String {
        let color = pointRoleColors[index]
        return "float4(\((color >> 16) & 255).0/255.0,\((color >> 8) & 255).0/255.0,\(color & 255).0/255.0,1.0)"
    }
    // Clothing, skin, trousers and equipment have separate materials. Civilian
    // colors vary within a crowd; infected use worn green and gray clothing.
    static func materials(for role: TacticalHumanRole) -> [SCNMaterial] {
        let shirts: [UInt32]
        switch role {
        case .civilian: shirts = [0x55A9AE,0xD6B76F,0x8092BA,0xDDDDD0,0x9E6B96,0x649179]
        case .zombie: shirts = [0x71944D,0x758669,0x8A9E5C,0x5E7C62,0x7D8980,0x67795B]
        case .soldier,.sniper: shirts = [0x79815B,0x65704C,0x87916B,0x798562,0x737B57,0x566447]
        }
        return shirts.map { CityModels.material($0) } + [
            CityModels.material(role == .zombie ? 0x9AA381 : 0xC98E69),
            CityModels.material(role == .zombie ? 0xA6AA8D : 0xE0B893),
            CityModels.material(0x354C56),CityModels.material(0x505952),
            CityModels.material(0x25322D),CityModels.material(0x3F4735),
            CityModels.material(0x192B2B),CityModels.material(0xA9B095)
        ]
    }

    /// Round discs use four interpolated vertices and one shared material.
    /// Colors travel with each actor, avoiding empty per-role material groups.
    static func pointMaterials() -> [SCNMaterial] {
        // Role colors travel in each point vertex, allowing one draw for the
        // entire crowd even when civilians or infected are absent.
        [UInt32(0xFFFFFF)].map { color in
            let material = CityModels.material(color)
            material.lightingModel = .constant; material.blendMode = .alpha
            material.writesToDepthBuffer = false
            return material
        }
    }

    /// Coordinates are in meters until the final transform. Head, shoulders,
    /// hips, knees, feet, elbows and hands remain distinct at street zoom.
    nonisolated static func append(_ pose: TacticalHumanPose, metersToWorld: Double, detailed: Bool,
                       to mesh: inout CityMesh) {
        let variant = abs(pose.variant), armed = pose.role == .soldier || pose.role == .sniper
        let zombie = pose.role == .zombie, kneeling = pose.role == .sniper && pose.speed <= metersToWorld * 0.15
        let moving = pose.speed > metersToWorld * 0.15 && !kneeling
        let running = pose.speed > metersToWorld * 2.4
        let gait = pose.stride
        let gaitWeight = min(1,max(0,pose.speed/(metersToWorld*1.7)))
        let swing = moving ? (running ? 0.42 : 0.25)*gaitWeight : 0
        let side = sin(gait), opposite = sin(gait + .pi)
        let lean = kneeling ? -0.08 : (zombie ? (running ? -0.18 : -0.09) : (running ? -0.13 : -0.025))
        let bob = moving ? abs(sin(gait))*0.025*gaitWeight : sin(gait)*0.006
        let h = 0.94 + bob - (kneeling ? 0.34 : 0)
        let yaw = -pose.heading - .pi/2
        let scale = metersToWorld * (0.97 + Double(variant % 7)*0.01)
        let skin = 6 + variant % 2, shirt = variant % 6, pants = 8 + variant % 2
        func world(_ p: SCNVector3) -> SCNVector3 {
            let py = Double(p.y), pz = Double(p.z)
            // Lean through hips and torso; rotating the entire figure also
            // tilted planted feet through the street during a running stance.
            let upperBody = min(1,max(0,(py-0.6)/0.8))
            let bend = lean*upperBody
            let y = py*cos(bend)-pz*sin(bend), z = py*sin(bend)+pz*cos(bend)
            let x = Double(p.x)*cos(yaw)+z*sin(yaw)
            let depth = -Double(p.x)*sin(yaw)+z*cos(yaw)
            return SCNVector3(Float(Double(pose.position.x)+x*scale),Float(0.31+y*scale),Float(Double(pose.position.y)+depth*scale))
        }
        func ellipsoid(_ center: SCNVector3, _ radii: SCNVector3, _ material: Int, rings: Int = 3) {
            let sides = detailed ? 8 : 6
            for row in 0..<rings {
                let a = -Double.pi/2 + Double(row)*Double.pi/Double(rings)
                let b = -Double.pi/2 + Double(row+1)*Double.pi/Double(rings)
                for i in 0..<sides {
                    let t = Double(i)*Double.pi*2/Double(sides), u = Double(i+1)*Double.pi*2/Double(sides)
                    func vertex(_ latitude: Double,_ longitude: Double) -> SCNVector3 {
                        world(SCNVector3(center.x + radii.x*Float(cos(latitude)*cos(longitude)),center.y+radii.y*Float(sin(latitude)),center.z+radii.z*Float(cos(latitude)*sin(longitude))))
                    }
                    let v0 = vertex(a,t), v1 = vertex(a,u), v2 = vertex(b,u), v3 = vertex(b,t)
                    let normal = normalOf(v0,v3,v2)
                    mesh.quad(v0,v3,v2,v1,normal:normal,material:material)
                }
            }
        }
        func segment(_ a: SCNVector3,_ b: SCNVector3,_ radiusA: Double,_ radiusB: Double,_ material: Int) {
            let delta = SIMD3<Double>(Double(b.x-a.x),Double(b.y-a.y),Double(b.z-a.z))
            let length = max(0.001,sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z))
            let axis = delta/length
            let crossWith = abs(axis.y) < 0.9 ? SIMD3<Double>(0,1,0) : SIMD3<Double>(0,0,1)
            let rawU = SIMD3<Double>(axis.y*crossWith.z-axis.z*crossWith.y,axis.z*crossWith.x-axis.x*crossWith.z,axis.x*crossWith.y-axis.y*crossWith.x)
            let u = rawU/sqrt(rawU.x*rawU.x+rawU.y*rawU.y+rawU.z*rawU.z)
            let v = SIMD3<Double>(axis.y*u.z-axis.z*u.y,axis.z*u.x-axis.x*u.z,axis.x*u.y-axis.y*u.x)
            let sides = detailed ? 7 : 5
            func point(_ center: SCNVector3,_ radius: Double,_ angle: Double) -> SCNVector3 {
                let r = (u*cos(angle)+v*sin(angle))*radius
                return world(SCNVector3(center.x+Float(r.x),center.y+Float(r.y),center.z+Float(r.z)))
            }
            for i in 0..<sides {
                let angle = Double(i)*Double.pi*2/Double(sides), next = Double(i+1)*Double.pi*2/Double(sides)
                let p0 = point(a,radiusA,angle),p1 = point(a,radiusA,next),p2 = point(b,radiusB,next),p3 = point(b,radiusB,angle)
                mesh.quad(p0,p1,p2,p3,normal:normalOf(p0,p1,p2),material:material)
            }
        }
        // Tapered torso and pelvis leave a shoulder/waist silhouette rather than
        // a block. Head is oval, with a small forward nose at the closest LOD.
        ellipsoid(SCNVector3(0,Float(h+0.22),0),SCNVector3(0.23,0.3,0.145),shirt)
        ellipsoid(SCNVector3(0,Float(h-0.05),0),SCNVector3(0.17,0.12,0.13),pants,rings:2)
        ellipsoid(SCNVector3(0,Float(h+0.63),-0.015),SCNVector3(0.115,0.145,0.12),skin)
        if detailed {
            ellipsoid(SCNVector3(0,Float(h+0.62),-0.14),SCNVector3(0.028,0.032,0.036),skin,rings:2)
            ellipsoid(SCNVector3(0,Float(h+0.715),0.007),SCNVector3(0.12,0.075,0.12),armed ? 11 : 10,rings:2)
        }
        for (i,s) in [-1.0,1.0].enumerated() {
            let phase = i == 0 ? side : opposite
            let hip = SCNVector3(Float(s*0.1),Float(h-0.12),0)
            // Stance travels front-to-back with grounded feet; swing lifts the
            // foot and folds the knee. Distance-driven phase limits foot sliding.
            let cycle = (gait / (2 * .pi) + Double(i) * 0.5).truncatingRemainder(dividingBy:1)
            let t = cycle < 0 ? cycle + 1 : cycle
            let stance = running ? 0.42 : 0.62
            let strideLength = running ? 2.2 : 1.2
            let reach = strideLength * stance * 0.5 * gaitWeight
            let swingTime = max(0,(t - stance) / (1 - stance))
            let footZ = t < stance ? -reach + 2 * reach * t / stance : reach * cos(swingTime * .pi)
            let lift = moving && t >= stance ? sin(swingTime * .pi) * (running ? 0.20 : 0.10) * gaitWeight : 0
            let knee = SCNVector3(Float(s*0.12),Float(kneeling ? 0.34 : 0.44 + lift * 0.6),Float(kneeling ? (i == 0 ? -0.3 : 0.2) : footZ*0.45 - lift*0.65))
            let foot = SCNVector3(Float(s*0.12),Float(0.055 + lift),Float(kneeling ? (i == 0 ? -0.45 : 0.38) : footZ))
            segment(hip,knee,0.085,0.065,pants)
            segment(knee,foot,0.063,0.045,pants)
            if detailed { ellipsoid(SCNVector3(foot.x,foot.y,foot.z-0.045),SCNVector3(0.058,0.045,0.115),10,rings:2) }
            let shoulder = SCNVector3(Float(s*0.23),Float(h+0.37),0)
            let elbow: SCNVector3, hand: SCNVector3
            if armed {
                elbow = SCNVector3(Float(s*0.29),Float(h+0.1),-0.08)
                hand = SCNVector3(Float(i == 0 ? -0.04 : 0.09),Float(h+0.22),Float(i == 0 ? -0.32 : -0.2))
            } else if zombie && !running {
                elbow = SCNVector3(Float(s*0.28),Float(h+0.18+phase*0.035),Float(-0.15-phase*0.09))
                hand = SCNVector3(Float(s*0.2),Float(h+0.1),Float(-0.34-phase*0.1))
            } else {
                elbow = SCNVector3(Float(s*0.26),Float(h+0.08),Float(-phase*swing*0.65))
                hand = SCNVector3(Float(s*0.2),Float(h-0.16+(running ? 0.27 : 0)),Float(-phase*swing*0.85))
            }
            segment(shoulder,elbow,0.071,0.052,shirt)
            segment(elbow,hand,0.05,0.036,skin)
            if detailed { ellipsoid(hand,SCNVector3(0.045,0.057,0.035),skin,rings:2) }
        }
        if armed {
            let z = kneeling ? -0.85 : -0.65
            segment(SCNVector3(0.08,Float(h+0.2),-0.13),SCNVector3(0.08,Float(h+0.2),Float(z)),0.035,0.021,12)
            if detailed {
                ellipsoid(SCNVector3(0.08,Float(h+0.19),-0.25),SCNVector3(0.045,0.075,0.13),10,rings:2)
                ellipsoid(SCNVector3(0,Float(h+0.25),0.16),SCNVector3(0.14,0.21,0.08),11,rings:2)
                if pose.role == .sniper { segment(SCNVector3(0.08,Float(h+0.27),-0.3),SCNVector3(0.08,Float(h+0.27),-0.47),0.027,0.027,12) }
            }
        } else if zombie && detailed {
            // Asymmetric torn sleeves and clothing patches keep the infected
            // varied without adding film-specific costume or character assets.
            ellipsoid(SCNVector3(-0.12,Float(h+0.12),-0.14),SCNVector3(0.06,0.11,0.014),variant % 3,rings:2)
        }
    }

    nonisolated private static func normalOf(_ a: SCNVector3,_ b: SCNVector3,_ c: SCNVector3) -> SCNVector3 {
        let u = SIMD3<Float>(b.x-a.x,b.y-a.y,b.z-a.z),v = SIMD3<Float>(c.x-a.x,c.y-a.y,c.z-a.z)
        let n = SIMD3<Float>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
        let length = max(0.00001,sqrt(n.x*n.x+n.y*n.y+n.z*n.z))
        return SCNVector3(n.x/length,n.y/length,n.z/length)
    }
}
