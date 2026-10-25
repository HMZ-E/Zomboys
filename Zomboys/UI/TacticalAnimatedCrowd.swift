import SceneKit
import Metal
import Foundation

struct CrowdRenderItem {
    let id: Int
    var current: TacticalHumanPose
    var previous: TacticalHumanPose
    var material: Int = 0
}

enum CrowdRenderStyle {
    case dots(radius: Double, altitude: Double)
    case humans(detailed: Bool)
}

/// Geometry changes only with a simulation snapshot. The vertex shader blends
/// its previous, midpoint and current poses on every rendered frame,
/// independently of simulation rate.
final class TacticalAnimatedCrowd: @unchecked Sendable {
    private let poses = CrowdPoseBank()

    init() {
        poses.prepareCommonPoses()
    }

    func geometry(items: [CrowdRenderItem], style: CrowdRenderStyle,
                  metersToWorld: Double, materials: [SCNMaterial],
                  snapshotTime: TimeInterval, snapshotDuration: TimeInterval,
                  animating: Bool) -> SCNGeometry {
        let prepared = prepare(items:items,style:style,metersToWorld:metersToWorld,materialCount:materials.count)
        return prepared.geometry(materials:materials,snapshotTime:snapshotTime,snapshotDuration:snapshotDuration,animating:animating)
    }

    /// CPU-only world poses and index buffers are built away from display work.
    /// The renderer attaches SceneKit geometry using the shared materials.
    func prepare(items: [CrowdRenderItem], style: CrowdRenderStyle,
                 metersToWorld: Double, materialCount: Int) -> PreparedCrowdGeometry {
        var vertices: [AnimatedCrowdVertex] = []
        let dots: Bool
        switch style { case .dots: dots = true; case .humans: dots = false }
        var indices = Array(repeating: [Int32](), count: dots ? 1 : max(1, materialCount))
        vertices.reserveCapacity(items.count * (dots ? 4 : 1_000))
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        func include(_ p: SIMD3<Float>) {
            minimum = SIMD3(min(minimum.x,p.x),min(minimum.y,p.y),min(minimum.z,p.z))
            maximum = SIMD3(max(maximum.x,p.x),max(maximum.y,p.y),max(maximum.z,p.z))
        }

        for item in items {
            let base = Int32(vertices.count)
            switch style {
            case let .dots(radius, altitude):
                let current = SIMD3<Float>(Float(item.current.position.x),Float(altitude),Float(item.current.position.y))
                let previous = SIMD3<Float>(Float(item.previous.position.x),Float(altitude),Float(item.previous.position.y))
                let midpoint = (previous+current)/2
                let r = Float(radius)
                let corners:[(SIMD3<Float>,SIMD3<Float>)] = [
                    (SIMD3(-r,0,-r),SIMD3(0,0,0)),(SIMD3(-r,0,r),SIMD3(0,1,0)),
                    (SIMD3(r,0,r),SIMD3(1,1,0)),(SIMD3(r,0,-r),SIMD3(1,0,0))]
                for (offset,uv) in corners {
                    include(current+offset); include(previous+offset)
                    vertices.append(AnimatedCrowdVertex(position:current+offset,previous:SIMD4(previous+offset,1),midpoint:SIMD4(midpoint+offset,Float(item.material)),normal:uv))
                }
                indices[0].append(contentsOf:[base,base+1,base+2,base,base+2,base+3])

            case let .humans(detailed):
                let current = poses.sample(for: item.current, metersToWorld: metersToWorld, detailed: detailed)
                var previous = poses.sample(for: item.previous, metersToWorld: metersToWorld, detailed: detailed)
                var middlePose = item.current
                middlePose.position = CGPoint(x:(item.previous.position.x+item.current.position.x)/2,y:(item.previous.position.y+item.current.position.y)/2)
                middlePose.heading = FrameInterpolation.angle(from:item.previous.heading,to:item.current.heading,fraction:0.5)
                // Forward phase avoids reversing legs when 3x speed advances
                // more than pi radians in one accepted simulation snapshot.
                middlePose.stride = FrameInterpolation.phase(from:item.previous.stride,to:item.current.stride,fraction:0.5)
                middlePose.speed = (item.previous.speed+item.current.speed)/2
                var middle = poses.sample(for:middlePose,metersToWorld:metersToWorld,detailed:detailed)
                // A kneeling sniper has a scope detail absent from the moving
                // pose. A topology transition uses the new shape at both ends.
                if current.a.vertices.count != previous.a.vertices.count { previous = current }
                if current.a.vertices.count != middle.a.vertices.count { middle = current }
                let currentTransform = CrowdWorldTransform(item.current, metersToWorld: metersToWorld)
                let previousTransform = CrowdWorldTransform(item.previous, metersToWorld: metersToWorld)
                let middleTransform = CrowdWorldTransform(middlePose,metersToWorld:metersToWorld)
                for index in current.a.vertices.indices {
                    let local = current.vertex(at: index)
                    let oldLocal = previous.vertex(at: index)
                    let p = currentTransform.point(local), old = previousTransform.point(oldLocal)
                    let mid = middleTransform.point(middle.vertex(at:index))
                    include(p); include(old); include(mid)
                    vertices.append(AnimatedCrowdVertex(position:p,previous:SIMD4(old,1),midpoint:SIMD4(mid,0),normal:currentTransform.normal(current.normal(at:index))))
                }
                for (prototypeMaterial, element) in current.a.indices.enumerated() where !element.isEmpty {
                    let material: Int
                    switch prototypeMaterial {
                    case 0: material = abs(item.id) % 6
                    case 6: material = 6 + abs(item.id) % 2
                    case 8: material = 8 + abs(item.id) % 2
                    default: material = prototypeMaterial
                    }
                    let destination = max(0,min(indices.count-1,material))
                    indices[destination].append(contentsOf:element.map { $0 + base })
                }
            }
        }

        let margin: Float
        switch style { case let .dots(radius,_): margin = Float(radius); case .humans: margin = 0 }
        return PreparedCrowdGeometry(data:vertices.withUnsafeBufferPointer { Data(buffer:$0) },
                                     vertexCount:vertices.count,indices:indices,
                                     minimum:minimum-SIMD3(margin,0,margin),maximum:maximum+SIMD3(margin,0,margin),pointRadius:dots ? Double(margin) : nil)
    }

    static func setAnimation(on geometry: SCNGeometry, snapshotTime: TimeInterval,
                             snapshotDuration: TimeInterval, animating: Bool,
                             frozenFraction: Double = 1) {
        geometry.setValue(Float(snapshotTime),forKey:"crowdStart")
        geometry.setValue(Float(max(0.001,snapshotDuration)),forKey:"crowdSpan")
        geometry.setValue(Float(animating ? 1 : 0),forKey:"crowdEnabled")
        geometry.setValue(Float(max(0,min(1,frozenFraction))),forKey:"crowdFrozen")
    }

    /// A renderer may supply a fraction computed with a Double clock instead
    /// when its scene time has a large epoch. That avoids Float clock precision
    /// loss while preserving GPU vertex interpolation and cached geometry.
    static func setRenderFraction(on geometry: SCNGeometry, fraction: Double) {
        geometry.setValue(Float(0),forKey:"crowdEnabled")
        geometry.setValue(Float(max(0,min(1,fraction))),forKey:"crowdFrozen")
    }

    fileprivate static let interpolationShader = """
    #pragma arguments
    float crowdStart;
    float crowdSpan;
    float crowdEnabled;
    float crowdFrozen;
    float crowdPointColors;
    #pragma body
    float4 crowdTint = float4(1.0);
    if (crowdPointColors > 0.5) {
        float role = _geometry.tangent.w;
        crowdTint = role < 0.5 ? \(TacticalHumanModels.pointShaderColor(0)) :
                    role < 1.5 ? \(TacticalHumanModels.pointShaderColor(1)) :
                    role < 2.5 ? \(TacticalHumanModels.pointShaderColor(2)) :
                                 \(TacticalHumanModels.pointShaderColor(3));
        // Vertex colors are linear; decode the palette's sRGB components.
        crowdTint.rgb = pow((crowdTint.rgb + 0.055) / 1.055, float3(2.4));
        _geometry.normal = float3(0.0,1.0,0.0);
    }
    float crowdBlend = crowdEnabled > 0.5 ? clamp((scn_frame.time - crowdStart) / crowdSpan, 0.0, 1.0) : crowdFrozen;
    _geometry.position.xyz = crowdBlend <= 0.5 ? mix(_geometry.color.xyz, _geometry.tangent.xyz, crowdBlend * 2.0) : mix(_geometry.tangent.xyz, _geometry.position.xyz, (crowdBlend - 0.5) * 2.0);
    _geometry.color = crowdTint;
    _geometry.tangent = float4(1.0, 0.0, 0.0, 1.0);
    """

    fileprivate static let discFragment = """
    #pragma transparent
    #pragma body
    float discDistance = length(_surface.diffuseTexcoord * 2.0 - 1.0);
    if (discDistance >= 1.0) { discard_fragment(); }
    _output.color *= 1.0 - smoothstep(0.72, 1.0, discDistance);
    """

    fileprivate static func shaders(dots:Bool) -> [SCNShaderModifierEntryPoint:String] {
        var result:[SCNShaderModifierEntryPoint:String] = [.geometry:interpolationShader]
        if dots { result[.fragment] = discFragment }
        return result
    }
}

struct PreparedCrowdGeometry {
    let data: Data
    let vertexCount: Int
    let indices: [[Int32]]
    let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    let pointRadius: Double?
    var primitiveDivisor:Int { 3 }
    var primitiveType:SCNGeometryPrimitiveType { .triangles }

    func geometry(materials:[SCNMaterial],snapshotTime:TimeInterval,snapshotDuration:TimeInterval,animating:Bool) -> SCNGeometry {
        let stride = MemoryLayout<AnimatedCrowdVertex>.stride
        func source(_ semantic: SCNGeometrySource.Semantic, components: Int, offset: Int) -> SCNGeometrySource {
            SCNGeometrySource(data:data,semantic:semantic,vectorCount:vertexCount,usesFloatComponents:true,
                              componentsPerVector:components,bytesPerComponent:MemoryLayout<Float>.size,
                              dataOffset:offset,dataStride:stride)
        }
        let sources = [source(.vertex,components:3,offset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.position)!),
                       source(.color,components:4,offset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.previous)!),
                       source(.tangent,components:4,offset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.midpoint)!),
                       source(.normal,components:3,offset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.normal)!),
                       source(.texcoord,components:2,offset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.normal)!)]
        let elements = indices.map { SCNGeometryElement(indices:$0,primitiveType:primitiveType) }
        let result = SCNGeometry(sources:sources,elements:elements)
        result.materials = materials
        result.shaderModifiers = TacticalAnimatedCrowd.shaders(dots:pointRadius != nil)
        result.setValue(Float(pointRadius == nil ? 0 : 1),forKey:"crowdPointColors")
        if vertexCount > 0 {
            result.boundingBox = (SCNVector3(minimum.x,minimum.y,minimum.z),SCNVector3(maximum.x,maximum.y,maximum.z))
        }
        TacticalAnimatedCrowd.setAnimation(on:result,snapshotTime:snapshotTime,snapshotDuration:snapshotDuration,animating:animating)
        return result
    }
}

/// Three reusable meshes rotate at snapshot cadence. Geometry, shader programs,
/// materials and index allocations survive ordinary movement frames.
final class CrowdMetalBuffers {
    private struct Slot {
        let vertices: MTLBuffer
        let indices: [MTLBuffer]
        let geometry: SCNGeometry
    }
    private let device: MTLDevice
    private var slots: [Slot] = []
    private var vertexCapacity = 0
    private var indexCapacities: [Int] = []
    private var nextSlot = 0
    private var pointMode = false
    init(device:MTLDevice) { self.device = device }

    func update(_ prepared:PreparedCrowdGeometry,materials:[SCNMaterial],uploads:TacticalFrameMetrics) -> SCNGeometry? {
        let divisor = prepared.primitiveDivisor
        let required = prepared.indices.map { max(divisor,$0.count) }
        if slots.isEmpty || pointMode != (prepared.pointRadius != nil) || prepared.vertexCount > vertexCapacity || required.count != indexCapacities.count || zip(required,indexCapacities).contains(where: { $0 > $1 }) {
            vertexCapacity = capacity(max(1,prepared.vertexCount))
            indexCapacities = required.map { capacity(($0+divisor-1)/divisor)*divisor }
            pointMode = prepared.pointRadius != nil
            slots.removeAll(keepingCapacity:true); nextSlot = 0
            for _ in 0..<3 {
                guard let vertices = device.makeBuffer(length:vertexCapacity*MemoryLayout<AnimatedCrowdVertex>.stride,options:.storageModeShared) else { return nil }
                var buffers:[MTLBuffer] = []
                for count in indexCapacities {
                    guard let buffer = device.makeBuffer(length:count*MemoryLayout<Int32>.stride,options:.storageModeShared) else { return nil }
                    buffers.append(buffer)
                }
                let stride = MemoryLayout<AnimatedCrowdVertex>.stride
                let sources = [SCNGeometrySource(buffer:vertices,vertexFormat:.float3,semantic:.vertex,vertexCount:vertexCapacity,dataOffset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.position)!,dataStride:stride),
                               SCNGeometrySource(buffer:vertices,vertexFormat:.float4,semantic:.color,vertexCount:vertexCapacity,dataOffset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.previous)!,dataStride:stride),
                               SCNGeometrySource(buffer:vertices,vertexFormat:.float4,semantic:.tangent,vertexCount:vertexCapacity,dataOffset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.midpoint)!,dataStride:stride),
                               SCNGeometrySource(buffer:vertices,vertexFormat:.float3,semantic:.normal,vertexCount:vertexCapacity,dataOffset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.normal)!,dataStride:stride),
                               SCNGeometrySource(buffer:vertices,vertexFormat:.float2,semantic:.texcoord,vertexCount:vertexCapacity,dataOffset:MemoryLayout<AnimatedCrowdVertex>.offset(of:\.normal)!,dataStride:stride)]
                let elements = zip(buffers,indexCapacities).map { buffer,count in
                    SCNGeometryElement(buffer:buffer,primitiveType:prepared.primitiveType,primitiveCount:count/divisor,bytesPerIndex:MemoryLayout<Int32>.stride)
                }
                let geometry = SCNGeometry(sources:sources,elements:elements)
                geometry.materials = materials
                geometry.shaderModifiers = TacticalAnimatedCrowd.shaders(dots:pointMode)
                geometry.setValue(Float(pointMode ? 1 : 0),forKey:"crowdPointColors")
                TacticalAnimatedCrowd.setRenderFraction(on:geometry,fraction:1)
                slots.append(Slot(vertices:vertices,indices:buffers,geometry:geometry))
            }
        }
        let slot = slots[nextSlot]; nextSlot = (nextSlot+1)%slots.count
        for (element,indices) in zip(slot.geometry.elements,prepared.indices) {
            // Keep one zero-area triangle for empty groups. Clearing unused
            // indices prevents stale actors on backends that cache draw ranges.
            element.primitiveRange = NSRange(location:0,length:max(1,indices.count/divisor))
        }
        uploads.enqueueUpload(vertices:slot.vertices,indices:slot.indices,vertexData:prepared.data,
                              indexData:prepared.indices.map { $0.withUnsafeBufferPointer { Data(buffer:$0) } })
        slot.geometry.boundingBox = (SCNVector3(prepared.minimum.x,prepared.minimum.y,prepared.minimum.z),
                                     SCNVector3(prepared.maximum.x,prepared.maximum.y,prepared.maximum.z))
        return slot.geometry
    }
    private func capacity(_ required:Int) -> Int {
        var result = 1
        while result < required { result *= 2 }
        return result
    }
}

private struct AnimatedCrowdVertex {
    var position: SIMD3<Float>
    var previous: SIMD4<Float>
    var midpoint: SIMD4<Float>
    var normal: SIMD3<Float>
}

private struct CrowdWorldTransform {
    let position: SIMD3<Float>
    let scale: Float
    let cosine: Float, sine: Float
    init(_ pose: TacticalHumanPose, metersToWorld: Double) {
        position = SIMD3(Float(pose.position.x),0.31,Float(pose.position.y))
        scale = Float(metersToWorld * (0.97 + Double(abs(pose.variant)%7)*0.01) / 0.97)
        let yaw = -pose.heading - .pi/2
        cosine = Float(cos(yaw)); sine = Float(sin(yaw))
    }
    func point(_ point: SCNVector3) -> SIMD3<Float> {
        // Prototype append uses meters and a fixed 0.31 ground-plane altitude.
        position + SIMD3(point.x*cosine+point.z*sine,point.y-0.31,-point.x*sine+point.z*cosine)*scale
    }
    func normal(_ normal: SCNVector3) -> SIMD3<Float> {
        SIMD3(normal.x*cosine+normal.z*sine,normal.y,-normal.x*sine+normal.z*cosine)
    }
}

/// Only local vertices are cached; this background cache creates no SceneKit objects.
/// Civilian clothing and height are assigned during batching rather than
/// multiplying the pose cache by every crowd member's visual variant.
private final class CrowdPoseBank: @unchecked Sendable {
    private struct Key: Hashable { let role: Int, movement: Int; let detailed: Bool; let frame: Int }
    struct Sample {
        let a: CityMesh, b: CityMesh, c: CityMesh, d: CityMesh
        let fraction: Float, blend: Float
        func vertex(at index: Int) -> SCNVector3 {
            if blend >= 1 {
                let x = c.vertices[index], y = d.vertices[index]
                return SCNVector3(x.x+(y.x-x.x)*fraction,x.y+(y.y-x.y)*fraction,x.z+(y.z-x.z)*fraction)
            }
            let x = a.vertices[index], y = b.vertices[index]
            let z = c.vertices[index], w = d.vertices[index]
            let low = SCNVector3(x.x+(y.x-x.x)*fraction,x.y+(y.y-x.y)*fraction,x.z+(y.z-x.z)*fraction)
            if blend <= 0 { return low }
            let high = SCNVector3(z.x+(w.x-z.x)*fraction,z.y+(w.y-z.y)*fraction,z.z+(w.z-z.z)*fraction)
            return SCNVector3(low.x+(high.x-low.x)*blend,low.y+(high.y-low.y)*blend,low.z+(high.z-low.z)*blend)
        }
        func normal(at index: Int) -> SCNVector3 {
            if blend >= 1 {
                let x = c.normals[index], y = d.normals[index]
                return SCNVector3(x.x+(y.x-x.x)*fraction,x.y+(y.y-x.y)*fraction,x.z+(y.z-x.z)*fraction)
            }
            let x = a.normals[index], y = b.normals[index]
            let z = c.normals[index], w = d.normals[index]
            let low = SCNVector3(x.x+(y.x-x.x)*fraction,x.y+(y.y-x.y)*fraction,x.z+(y.z-x.z)*fraction)
            if blend <= 0 { return low }
            let high = SCNVector3(z.x+(w.x-z.x)*fraction,z.y+(w.y-z.y)*fraction,z.z+(w.z-z.z)*fraction)
            return SCNVector3(low.x+(high.x-low.x)*blend,low.y+(high.y-low.y)*blend,low.z+(high.z-low.z)*blend)
        }
    }
    private let lock = NSLock()
    private let warming = DispatchQueue(label:"com.zomboys.crowd-pose-cache",qos:.utility)
    private var cache: [Key: CityMesh] = [:]
    private var preparing = Set<String>()
    private static let frames = 32

    func prepareCommonPoses() {
        for role in [TacticalHumanRole.civilian,.zombie,.soldier,.sniper] {
            for detailed in [false,true] { for movement in [0,1,2] { prepare(role:role,movement:movement,detailed:detailed) } }
        }
    }
    func sample(for pose: TacticalHumanPose, metersToWorld: Double, detailed: Bool) -> Sample {
        let physicalSpeed = pose.speed / max(0.0001,metersToWorld)
        let weights = CrowdMotion.gait(at: physicalSpeed)
        let lower = physicalSpeed < 1.8 ? 0 : 1
        let upper = lower + 1
        let mix = lower == 0 ? 1 - weights.idle : weights.run
        let phase = ((pose.stride.truncatingRemainder(dividingBy:2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy:2 * .pi))
        let coordinate = phase / (2 * .pi) * Double(Self.frames)
        let frame = Int(coordinate) % Self.frames, next = (frame+1) % Self.frames
        let a = mesh(role:pose.role,movement:lower,detailed:detailed,frame:frame)
        let b = mesh(role:pose.role,movement:lower,detailed:detailed,frame:next)
        let c = mesh(role:pose.role,movement:upper,detailed:detailed,frame:frame)
        let d = mesh(role:pose.role,movement:upper,detailed:detailed,frame:next)
        return Sample(a:a,b:b,c:c,d:d,fraction:Float(coordinate-floor(coordinate)),blend:Float(mix))
    }
    private func prepare(role: TacticalHumanRole, movement: Int, detailed: Bool) {
        let identifier = "\(roleIndex(role)).\(movement).\(detailed)"
        lock.lock(); let fresh = preparing.insert(identifier).inserted; lock.unlock()
        guard fresh else { return }
        warming.async { [weak self] in
            guard let self else { return }
            for frame in 0..<Self.frames { _ = self.mesh(role:role,movement:movement,detailed:detailed,frame:frame) }
        }
    }
    private func mesh(role: TacticalHumanRole, movement: Int, detailed: Bool, frame: Int) -> CityMesh {
        let frame = movement == 0 ? (frame/4)*4 : frame
        let key = Key(role:roleIndex(role),movement:movement,detailed:detailed,frame:frame)
        lock.lock(); let existing = cache[key]; lock.unlock()
        if let existing { return existing }
        let speed = movement == 0 ? 0 : (movement == 1 ? 1.7 : 4.5)
        let pose = TacticalHumanPose(position:.zero,heading:-Double.pi/2,stride:Double(frame)*2 * .pi/Double(Self.frames),speed:speed,variant:0,role:role)
        var mesh = CityMesh(materialCount:14)
        TacticalHumanModels.append(pose,metersToWorld:1,detailed:detailed,to:&mesh)
        mesh = compactQuads(mesh)
        lock.lock(); cache[key] = mesh; lock.unlock()
        return mesh
    }
    /// CityMesh stores a quad as (a,b,c,a,c,d). Keeping its four distinct
    /// vertices reduces cached memory and per-snapshot world transforms by a
    /// third, with identical triangles, material assignments and flat normals.
    private func compactQuads(_ original: CityMesh) -> CityMesh {
        guard original.vertices.count.isMultiple(of:6) else { return original }
        func equal(_ a: SCNVector3, _ b: SCNVector3) -> Bool { a.x == b.x && a.y == b.y && a.z == b.z }
        var result = CityMesh(materialCount:original.indices.count)
        result.vertices.reserveCapacity(original.vertices.count/3*2)
        result.normals.reserveCapacity(original.normals.count/3*2)
        for base in stride(from:0,to:original.vertices.count,by:6) {
            // If a future human model adds independent triangles, retain it
            // verbatim instead of assuming its topology is made from quads.
            guard equal(original.vertices[base],original.vertices[base+3]),
                  equal(original.vertices[base+2],original.vertices[base+4]),
                  equal(original.normals[base],original.normals[base+3]),
                  equal(original.normals[base+2],original.normals[base+4]) else { return original }
            for offset in [0,1,2,5] {
                result.vertices.append(original.vertices[base+offset])
                result.normals.append(original.normals[base+offset])
            }
        }
        let local: [Int32] = [0,1,2,0,2,3]
        result.indices = original.indices.map { element in element.map { index in (index/6)*4+local[Int(index%6)] } }
        return result
    }
    private func roleIndex(_ role: TacticalHumanRole) -> Int {
        switch role { case .civilian: return 0; case .zombie: return 1; case .soldier: return 2; case .sniper: return 3 }
    }
}
