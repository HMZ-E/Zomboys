import SceneKit
import simd

/// A transient owns a fixed, small node hierarchy. Snapshot updates alter only
/// transforms and opacity; geometry and materials are shared between instances.
/// The coordinator controls transaction duration, pausing and first-frame snaps.
@MainActor
final class TacticalEffectModels {
    private enum Shape: Hashable { case sphere, cylinder, ring, canopy }
    private struct GeometryKey: Hashable { let shape: Shape; let color: UInt32; let glow: UInt32? }
    private var geometries: [GeometryKey:SCNGeometry] = [:]

    func makeProjectile(_ projectile: CombatProjectile, metersToWorld: Double,
                        worldUnitsPerPoint: Double) -> SCNNode {
        let root = SCNNode(); root.name = "projectile.\(projectile.id)"
        root.addChildNode(node("shell",shape:.sphere,color:0xF5E4A1,glow:0xC29046))
        for i in 0..<5 { root.addChildNode(node("trail.\(i)",shape:.cylinder,color:0xC6C6B1)) }
        root.addChildNode(node("shadow",shape:.cylinder,color:0x172B2A))
        updateProjectile(node:root,projectile:projectile,metersToWorld:metersToWorld,worldUnitsPerPoint:worldUnitsPerPoint)
        return root
    }

    func updateProjectile(node root: SCNNode, projectile: CombatProjectile,
                          metersToWorld: Double, worldUnitsPerPoint: Double) {
        let p = projectile.position
        root.position = SCNVector3(Float(p.x),0,Float(p.y))
        if let shell = child(root,"shell") {
            shell.position = SCNVector3(0,Float(projectile.altitude),0)
            let radius = max(metersToWorld*(projectile.kind == .mortar ? 0.085 : 0.2),worldUnitsPerPoint*0.35)
            shell.scale = uniform(radius)
        }
        for i in 0..<5 {
            guard let trail = child(root,"trail.\(i)") else { continue }
            let a = max(0,projectile.progress-Double(i+1)*0.025)
            let b = max(0,projectile.progress-Double(i)*0.025)
            beam(trail,from:projectilePoint(projectile,progress:a,relativeTo:p),
                 to:projectilePoint(projectile,progress:b,relativeTo:p),
                 radius:max(metersToWorld*0.035,worldUnitsPerPoint*0.22))
            trail.opacity = CGFloat((1-Double(i)/5)*0.65)
        }
        if let shadow = child(root,"shadow") {
            shadow.position = SCNVector3(0,0.6,0)
            let radius = max(metersToWorld*0.12,worldUnitsPerPoint*0.4)
            shadow.scale = SCNVector3(Float(radius),0.04,Float(radius)); shadow.opacity = 0.42
        }
    }

    func makeEffect(_ effect: CombatEffect, metersToWorld: Double,
                    worldUnitsPerPoint: Double) -> SCNNode {
        let root = SCNNode(); root.name = "effect.\(effect.id)"
        switch effect.kind {
        case .shot:
            root.addChildNode(node("trace",shape:.cylinder,color:0xFFD28A,glow:0xFFD28A))
            root.addChildNode(node("flash",shape:.sphere,color:0xFFE2A0,glow:0xFFBA52))
        case .explosion:
            root.addChildNode(node("flash",shape:.sphere,color:0xFFE0A0,glow:0xEF8D36))
            for i in 0..<3 { root.addChildNode(node("smoke.\(i)",shape:.sphere,color:0x687269)) }
            root.addChildNode(node("wave",shape:.ring,color:0xD3BD92))
        case .rescue,.infection:
            root.addChildNode(node("pulse",shape:.ring,color:effect.kind == .rescue ? 0x75D5D4 : 0xE97561))
        }
        updateEffect(node:root,effect:effect,metersToWorld:metersToWorld,worldUnitsPerPoint:worldUnitsPerPoint)
        return root
    }

    func updateEffect(node root: SCNNode, effect: CombatEffect,
                      metersToWorld: Double, worldUnitsPerPoint: Double) {
        let t = min(1,max(0,effect.age/max(0.01,effect.duration)))
        let p = effect.position
        root.position = SCNVector3(Float(p.x),0,Float(p.y))
        switch effect.kind {
        case .shot:
            guard let end = effect.endPosition else { root.opacity = 0; return }
            let length = max(0.001,hypot(end.x-p.x,end.y-p.y))
            let gunHeight = (effect.altitude-0.31)/max(0.001,metersToWorld)
            let barrel = effect.altitude > 10 ? 0 : metersToWorld*(gunHeight > 1.9 ? 1.04 : (gunHeight < 0.95 ? 0.85 : 0.65))
            let muzzle = SIMD3<Float>(Float((end.x-p.x)/length*barrel),Float(effect.altitude),Float((end.y-p.y)/length*barrel))
            let target = SIMD3<Float>(Float(end.x-p.x),Float(0.31+metersToWorld*0.9),Float(end.y-p.y))
            if let trace = child(root,"trace") {
                beam(trace,from:muzzle,to:target,radius:max(metersToWorld*0.013,worldUnitsPerPoint*0.12))
                trace.opacity = CGFloat((1-t)*0.75)
            }
            if let flash = child(root,"flash") {
                flash.simdPosition = muzzle
                flash.scale = uniform(max(metersToWorld*(effect.altitude > 10 ? 0.6 : 0.12),worldUnitsPerPoint*0.28))
                flash.opacity = CGFloat(max(0,1-t/0.48))
            }
        case .explosion:
            let radius = min(effect.radius*0.16,metersToWorld*12)*(0.35+t*0.65)
            if let flash = child(root,"flash") {
                flash.scale = uniform(radius*(0.55+t))
                flash.position = SCNVector3(0,Float(0.31+radius*0.45),0)
                flash.opacity = CGFloat(max(0,1-t/0.24))
            }
            for i in 0..<3 {
                guard let smoke = child(root,"smoke.\(i)") else { continue }
                let angle = Double(i)*2.4+Double(effect.id%7), growth = 0.5+Double(i)*0.16
                let offset = radius*0.4*t, r = radius*growth
                smoke.position = SCNVector3(Float(cos(angle)*offset),Float(0.31+radius*(0.45+t*1.8+Double(i)*0.13)),Float(sin(angle)*offset))
                smoke.scale = SCNVector3(Float(r),Float(r*(1.15+t*0.6)),Float(r))
                smoke.opacity = CGFloat((1-t)*0.48)
            }
            if let wave = child(root,"wave") {
                groundRing(wave,radius:max(0.01,effect.radius*t),altitude:0.65)
                wave.opacity = CGFloat(max(0,1-t/0.55)*0.18)
            }
        case .rescue,.infection:
            if let pulse = child(root,"pulse") {
                groundRing(pulse,radius:max(metersToWorld*(0.8+t*2.8),worldUnitsPerPoint*(3+t*5)),altitude:0.65)
                pulse.opacity = CGFloat(1-t)
            }
        }
    }

    func makeSupport(_ area: SupportAreaState, metersToWorld: Double) -> SCNNode {
        let root = SCNNode(); root.name = "support.\(area.id)"
        switch area.kind {
        case .paratroopers:
            for i in 0..<4 {
                let chute = SCNNode(); chute.name = "chute.\(i)"
                let canopy = node("canopy",shape:.canopy,color:0xCBD7B1)
                canopy.position = SCNVector3(0,2.8,0); canopy.scale = SCNVector3(1.2,0.52,1.2)
                chute.addChildNode(canopy)
                for (j,offset) in [SIMD2<Float>(-1,-0.5),SIMD2(1,-0.5),SIMD2(-1,0.5),SIMD2(1,0.5)].enumerated() {
                    let rope = node("rope.\(j)",shape:.cylinder,color:0xD6E0C4)
                    beam(rope,from:SIMD3(offset.x,2.8,offset.y),to:SIMD3(offset.x*0.12,0.72,offset.y*0.12),radius:0.018)
                    chute.addChildNode(rope)
                }
                let torso = node("body",shape:.sphere,color:0x7D8B54)
                torso.position = SCNVector3(0,0.48,0); torso.scale = SCNVector3(0.2,0.38,0.15); chute.addChildNode(torso)
                let head = node("head",shape:.sphere,color:0xC3A07A)
                head.position = SCNVector3(0,0.99,0); head.scale = uniform(0.115); chute.addChildNode(head)
                for (j,x) in [Float(-0.09),Float(0.09)].enumerated() {
                    let leg = node("leg.\(j)",shape:.cylinder,color:0x394B34)
                    beam(leg,from:SIMD3(x,0.25,0),to:SIMD3(x,-0.15,0.03),radius:0.065)
                    chute.addChildNode(leg)
                }
                chute.scale = uniform(metersToWorld); root.addChildNode(chute)
            }
        case .gasBomb:
            for i in 0..<3 { root.addChildNode(node("cloud.\(i)",shape:.sphere,color:0x68BCAA)) }
            root.addChildNode(node("rim",shape:.ring,color:0x8DD7BC,glow:0x24584B))
        case .fireBomb:
            for i in 0..<3 {
                root.addChildNode(node("fire.\(i)",shape:.sphere,color:i == 1 ? 0xFFD67D : 0xE88D47,glow:0xBC6529))
                root.addChildNode(node("smoke.\(i)",shape:.sphere,color:0x596960))
            }
            root.addChildNode(node("rim",shape:.ring,color:0xDE9055))
        case .callToArms:
            root.addChildNode(node("pulse.0",shape:.ring,color:0xEED57D,glow:0x5F5323))
            root.addChildNode(node("pulse.1",shape:.ring,color:0xEED57D,glow:0x5F5323))
        }
        updateSupport(node:root,area:area,metersToWorld:metersToWorld)
        return root
    }

    func updateSupport(node root: SCNNode, area: SupportAreaState, metersToWorld: Double) {
        root.position = SCNVector3(Float(area.position.x),0,Float(area.position.y))
        let t = area.progress, radius = area.radius
        switch area.kind {
        case .paratroopers:
            for i in 0..<4 {
                guard let chute = child(root,"chute.\(i)") else { continue }
                let angle = Double(i) * .pi/2 + .pi/4
                let sway = sin(area.age*2.5+Double(i))*metersToWorld*0.45
                chute.position = SCNVector3(Float(cos(angle)*radius*0.48+sway),Float(0.31+metersToWorld*65*(1-t)),Float(sin(angle)*radius*0.48))
                chute.eulerAngles.z = Float(sin(area.age*2.5+Double(i))*0.055)
                chute.opacity = CGFloat(t > 0.9 ? max(0,(1-t)*10) : 1)
            }
        case .gasBomb:
            let growth = max(0.35,min(1,area.age/0.5)), fade = min(1,max(0,(area.lifetime-area.age)/1.5))
            for i in 0..<3 {
                guard let cloud = child(root,"cloud.\(i)") else { continue }
                let angle = Double(i)*2.1+0.4, r = radius*(0.52+Double(i)*0.045)*(0.65+growth*0.35)
                cloud.position = SCNVector3(Float(cos(angle)*radius*0.32),Float(0.31+r*0.2),Float(sin(angle)*radius*0.32))
                cloud.scale = SCNVector3(Float(r),Float(r*0.3),Float(r)); cloud.opacity = CGFloat(0.2*growth*fade)
            }
            if let rim = child(root,"rim") { groundRing(rim,radius:radius,altitude:0.6); rim.opacity = CGFloat(0.34*growth*fade) }
        case .fireBomb:
            let fade = min(1,max(0,(area.lifetime-area.age)/1.5))
            for i in 0..<3 {
                let angle = Double(i)*2.1+Double(area.id%5), x = cos(angle)*radius*0.28, z = sin(angle)*radius*0.28
                let pulse = 0.8+sin(area.age*5+Double(i)*1.8)*0.16
                if let fire = child(root,"fire.\(i)") {
                    fire.position = SCNVector3(Float(x),Float(0.31+radius*0.3*pulse),Float(z))
                    fire.scale = SCNVector3(Float(radius*0.2),Float(radius*0.46*pulse),Float(radius*0.17))
                    fire.opacity = CGFloat(0.64*fade)
                }
                if let smoke = child(root,"smoke.\(i)") {
                    let drift = min(1,area.age/2), r = radius*(0.19+0.1*drift)
                    smoke.position = SCNVector3(Float(x+radius*0.12*drift),Float(0.31+radius*(0.68+0.42*drift)),Float(z))
                    smoke.scale = SCNVector3(Float(r),Float(r*1.7),Float(r)); smoke.opacity = CGFloat(0.38*fade)
                }
            }
            if let rim = child(root,"rim") { groundRing(rim,radius:radius,altitude:0.6); rim.opacity = CGFloat(0.22*fade) }
        case .callToArms:
            for i in 0..<2 {
                guard let pulse = child(root,"pulse.\(i)") else { continue }
                let progress = t*1.4-Double(i)*0.35
                let phase = max(0,min(1,progress))
                groundRing(pulse,radius:max(metersToWorld*2,radius*(0.1+phase*0.9)),altitude:0.65)
                pulse.opacity = CGFloat(progress > 0 ? (1-phase)*(1-t)*0.55 : 0)
            }
        }
    }

    private func node(_ name: String, shape: Shape, color: UInt32, glow: UInt32? = nil) -> SCNNode {
        let result = SCNNode(geometry:geometry(shape:shape,color:color,glow:glow)); result.name = name; result.castsShadow = false
        return result
    }
    private func geometry(shape: Shape, color: UInt32, glow: UInt32?) -> SCNGeometry {
        let key = GeometryKey(shape:shape,color:color,glow:glow)
        if let existing = geometries[key] { return existing }
        let geometry: SCNGeometry
        switch shape {
        case .sphere:
            let sphere = SCNSphere(radius:1); sphere.segmentCount = 10; geometry = sphere
        case .cylinder:
            let cylinder = SCNCylinder(radius:1,height:1); cylinder.radialSegmentCount = 6; geometry = cylinder
        case .ring:
            // SCNTorus lies in the XZ plane by default, matching city ground.
            let torus = SCNTorus(ringRadius:1,pipeRadius:0.008); torus.ringSegmentCount = 36; torus.pipeSegmentCount = 4; geometry = torus
        case .canopy:
            var mesh = CityMesh()
            for row in 0..<4 { for side in 0..<12 {
                let a = Double(row) * .pi/8, b = Double(row+1) * .pi/8
                let c = Double(side) * .pi/6, d = Double(side+1) * .pi/6
                func point(_ latitude: Double, _ longitude: Double) -> SCNVector3 {
                    SCNVector3(Float(sin(latitude)*cos(longitude)),Float(cos(latitude)),Float(sin(latitude)*sin(longitude)))
                }
                let normal = point((a+b)/2,(c+d)/2)
                mesh.quad(point(a,c),point(b,c),point(b,d),point(a,d),normal:normal)
            } }
            geometry = mesh.geometry(materials:[])
        }
        let material = CityModels.material(color,emission:glow)
        material.isDoubleSided = shape == .canopy
        geometry.materials = [material]; geometries[key] = geometry
        return geometry
    }
    private func child(_ root: SCNNode, _ name: String) -> SCNNode? { root.childNode(withName:name,recursively:false) }
    private func uniform(_ value: Double) -> SCNVector3 { let v = Float(max(0.0001,value)); return SCNVector3(v,v,v) }
    private func groundRing(_ node: SCNNode, radius: Double, altitude: Double) {
        node.position = SCNVector3(0,Float(altitude),0)
        let r = Float(max(0.001,radius)); node.scale = SCNVector3(r,max(0.025,r*0.2),r)
    }
    private func beam(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Double) {
        let delta = b-a, length = simd_length(delta)
        node.simdPosition = (a+b)/2
        node.scale = SCNVector3(Float(radius),max(0.0001,length),Float(radius))
        if length > 0.00001 { node.simdOrientation = simd_quatf(from:SIMD3<Float>(0,1,0),to:delta/length) }
    }
    private func projectilePoint(_ projectile: CombatProjectile, progress t: Double, relativeTo p: CGPoint) -> SIMD3<Float> {
        let x = projectile.launch.x+(projectile.target.x-projectile.launch.x)*t-p.x
        let z = projectile.launch.y+(projectile.target.y-projectile.launch.y)*t-p.y
        let altitude: Double
        switch projectile.kind {
        case .mortar: altitude = sin(t * .pi)*projectile.arcHeight
        case .cannon105: altitude = projectile.arcHeight*(1-t)+sin(t * .pi)*projectile.arcHeight*0.3
        case .bomb: altitude = projectile.arcHeight*(1-t*t)
        }
        return SIMD3(Float(x),Float(altitude),Float(z))
    }
}
