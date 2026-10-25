import AppKit
import SceneKit
import Metal

@main struct CrowdRenderChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is required for this render check") }
        let bank = TacticalAnimatedCrowd(), buffers = CrowdMetalBuffers(device:device), metrics = TacticalFrameMetrics()
        let scene = SCNScene(); scene.background.contents = NSColor.black
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = 6; camera.position = SCNVector3(0,10,0); camera.eulerAngles.x = -.pi/2
        scene.rootNode.addChildNode(camera)
        let node = SCNNode(); scene.rootNode.addChildNode(node)
        let materials = TacticalHumanModels.pointMaterials()
        let renderer = SCNRenderer(device:device,options:nil); renderer.scene = scene; renderer.pointOfView = camera; renderer.delegate = metrics
        _ = renderer.snapshot(atTime:0,with:CGSize(width:128,height:128),antialiasingMode:.none)
        func item(_ id:Int,_ x:Double,_ previousX:Double,material:Int?=nil) -> CrowdRenderItem {
            let palette = material ?? id%2
            let role:TacticalHumanRole = palette == 1 ? .zombie : (palette == 2 ? .soldier : .civilian)
            let current = TacticalHumanPose(position:CGPoint(x:x,y:0),heading:0,stride:0,speed:0,variant:id,role:role)
            var previous = current; previous.position.x = previousX
            return CrowdRenderItem(id:id,current:current,previous:previous,material:palette)
        }
        func draw(_ input:[CrowdRenderItem],fraction:Double) throws -> (Double,Int,SIMD3<Double>) {
            let prepared = bank.prepare(items:input,style:.dots(radius:camera.camera!.orthographicScale/32,altitude:0.42),metersToWorld:1,materialCount:4)
            precondition(prepared.minimum.x.isFinite && prepared.maximum.z.isFinite)
            precondition(prepared.indices.count == 1,"All colored dots must share one draw instead of empty material groups")
            node.geometry = buffers.update(prepared,materials:materials,uploads:metrics)!
            metrics.registerAnimation(key:"crowd",geometry:node.geometry!,startTime:1_000_000,duration:0.05,animating:true)
            // Offscreen snapshots do not consistently dispatch delegate events
            // on macOS; exercise the exact callbacks explicitly before drawing.
            metrics.renderer(renderer,updateAtTime:1_000_000+fraction*0.05)
            metrics.renderer(renderer,willRenderScene:scene,atTime:1_000_000+fraction*0.05)
            if let completion = renderer.commandQueue?.makeCommandBuffer() { completion.commit(); completion.waitUntilCompleted() }
            let image = renderer.snapshot(atTime:1_000_000+fraction*0.05,with:CGSize(width:128,height:128),antialiasingMode:.none)
            let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
            var total = 0.0, count = 0, colorSum = SIMD3<Double>.zero
            for y in 0..<128 { for x in 0..<128 {
                guard let color = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent,color.greenComponent,color.blueComponent) > 0.25 {
                    total += Double(x); count += 1
                    colorSum += SIMD3(Double(color.redComponent),Double(color.greenComponent),Double(color.blueComponent))
                }
            } }
            precondition(count > 10,"Metal upload must produce visible geometry")
            return (total/Double(count),count,colorSum/Double(count))
        }
        var centers:[Double] = []
        for fraction in [0.0,0.25,0.5,0.75,1] { centers.append(try draw([item(0,3,-3)],fraction:fraction).0) }
        for i in 1..<centers.count { precondition(abs(centers[i]-centers[i-1]-16)<1,"GPU poses must advance evenly at all five fractions") }
        print("PASS: five actual Metal crowd positions advance evenly, including the midpoint, at a million-second clock: \(centers)")
        let greenOnly = try draw([item(1,0,0)],fraction:1)
        precondition(abs(greenOnly.0-63.5)<1,"A zombie-only crowd must draw when the first material group is empty")
        precondition(greenOnly.2.y > greenOnly.2.x*1.3 && greenOnly.2.y > greenOnly.2.z*1.8,"Zombie disc vertices must retain their bright green role color")
        precondition(greenOnly.1 < 16,"A four-pixel disc must mask its square corners")
        let whiteOnly = try draw([item(0,0,0)],fraction:1)
        precondition(whiteOnly.2.min() > 0.7 && whiteOnly.2.max()-whiteOnly.2.min() < 0.12,"Civilian discs must remain pale white rather than the old cyan")
        let soldierOnly = try draw([item(2,0,0,material:2)],fraction:1)
        precondition(soldierOnly.2.y > soldierOnly.2.x && soldierOnly.2.x > soldierOnly.2.z,"Soldier discs must retain their separate olive color")
        precondition(greenOnly.2.y-greenOnly.2.x > soldierOnly.2.y-soldierOnly.2.x+0.1,"Olive soldiers must remain distinguishable from bright infected")
        let amberOnly = try draw([item(3,0,0,material:3)],fraction:1)
        precondition(amberOnly.2.x > amberOnly.2.y && amberOnly.2.y > amberOnly.2.z,"Exposure and incubation retain amber warnings")
        print("PASS: a single draw retains white civilians, bright green infected, olive soldiers and amber exposure, including infected-only crowds")
        // Allocate for eight first, then shrink and grow within the same capacity.
        var maximum:[CrowdRenderItem] = []
        for index in 0..<8 {
            let coordinate:Double = -4.5 + Double(index)*1.2
            maximum.append(item(index,coordinate,coordinate))
        }
        _ = try draw(maximum,fraction:1)
        var identities = Set<ObjectIdentifier>(), oneActorPixels:[Int] = []
        for count in [8,3,1,6,1,8,3,1,6,1] {
            let result = try draw(Array(maximum.prefix(count)),fraction:1)
            identities.insert(ObjectIdentifier(node.geometry!))
            if count == 1 { oneActorPixels.append(result.1) }
        }
        precondition(identities.count <= 3,"Movement/population changes must reuse the three meshes")
        precondition(oneActorPixels.max()! - oneActorPixels.min()! < 4,"Shrinking must clear removed points instead of leaving ghost actors")
        metrics.clearAnimations()
        metrics.renderer(renderer,updateAtTime:1_000_001)
        precondition((node.geometry!.value(forKey:"crowdFrozen") as! NSNumber).floatValue == 1)
        print("PASS: GPU population/material shrink and growth reuses three meshes, clears removed actors and empty material draws, and freezes safely on pause")
        camera.camera!.zFar = 20_000; camera.position.y = 11_200
        var distantCameraPixels:[Int] = []
        for scale in [2.0,6,1_000] {
            camera.camera!.orthographicScale = scale
            let result = try draw([item(0,0,0)],fraction:1)
            precondition(abs(result.0-63.5)<1,"City and street zoom must retain the point at the camera center")
            distantCameraPixels.append(result.1)
        }
        precondition(distantCameraPixels.max()! - distantCameraPixels.min()! < 4,"Orthographic zoom and a distant camera must not shrink crowd dots below visible pixels")
        print("PASS: actual round dots stay visible across street/city orthographic scales with the camera 11,200 world units away")
        for (count,detailed) in [(160,false),(48,true)] {
            var input:[CrowdRenderItem] = []
            for i in 0..<count {
                var person = item(i,Double(i%20),Double(i%20)-0.2)
                person.current.stride = Double(i)*0.3; person.previous.stride = person.current.stride-0.9
                person.current.speed = 3.3; person.previous.speed = 3.3
                input.append(person)
            }
            let prepared = bank.prepare(items:input,style:.humans(detailed:detailed),metersToWorld:1,materialCount:14)
            precondition(prepared.vertexCount > count*100)
            let floatStride = prepared.data.count/prepared.vertexCount
            for i in 0..<prepared.vertexCount { for offset in [0,4,8] {
                let value = prepared.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:i*floatStride+offset,as:Float.self) }
                precondition(value.isFinite,"Every human vertex must remain finite")
            } }
        }
        print("PASS: 160 ordinary and 48 detailed three-pose human buffers contain finite actual body vertices")
        // Actual baked vertices must cross the former hard gait thresholds
        // continuously for civilians, infected, troops and kneeling snipers.
        func body(_ speed:Double,_ role:TacticalHumanRole) -> PreparedCrowdGeometry {
            let pose = TacticalHumanPose(position:CGPoint(x:0,y:0),heading:0,stride:1.7,speed:speed,variant:7,role:role)
            let input = CrowdRenderItem(id:7,current:pose,previous:pose)
            return bank.prepare(items:[input],style:.humans(detailed:true),metersToWorld:1,materialCount:14)
        }
        for role in [TacticalHumanRole.civilian,.zombie,.soldier,.sniper] {
            for threshold in [0.15,1.8,2.4,3.5] {
                let a = body(threshold-0.001,role), b = body(threshold+0.001,role)
                precondition(a.vertexCount == b.vertexCount,"Gait changes must preserve body topology, including sniper scopes")
                let stride = a.data.count/a.vertexCount
                var maximum:Float = 0
                for i in 0..<a.vertexCount { for offset in [0,4,8] {
                    let x = a.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:i*stride+offset,as:Float.self) }
                    let y = b.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:i*stride+offset,as:Float.self) }
                    maximum = max(maximum,abs(x-y))
                } }
                precondition(maximum < 0.015,"A tiny speed change must not jump arms, knees, feet or torso")
            }
        }
        print("PASS: all four human roles retain continuous actual vertices through idle/walk/run transitions and sniper standing")
        for role in [TacticalHumanRole.civilian,.zombie,.soldier,.sniper] {
            for speed in [0.0,1.7,4.5] { for frame in 0..<16 {
                var mesh = CityMesh(materialCount:14)
                let pose = TacticalHumanPose(position:CGPoint(x:0,y:0),heading:0,stride:Double(frame)*2 * .pi/16,speed:speed,variant:0,role:role)
                TacticalHumanModels.append(pose,metersToWorld:1,detailed:true,to:&mesh)
                precondition(mesh.vertices.allSatisfy { $0.y >= 0.309 },"Foot stance must stay above the street while the torso leans")
            } }
        }
        print("PASS: actual walking, running and kneeling meshes keep planted feet above the street throughout the gait")
        var wall = CityMesh()
        wall.barricade(path:[CGPoint(x:-10,y:0),CGPoint(x:10,y:0)],apertures:[.zero],metersToWorld:1)
        precondition(wall.vertices.count == 48,"One gate must split a wall into exactly two boxes")
        precondition(wall.vertices.allSatisfy { abs($0.x) >= 2.199 },"No wall geometry may cover the actual gate opening")
        var overlap = CityMesh()
        overlap.barricade(path:[CGPoint(x:-10,y:0),CGPoint(x:10,y:0)],apertures:[.zero,CGPoint(x:1,y:0)],metersToWorld:1)
        precondition(overlap.vertices.count == 48,"Overlapping gate apertures must merge without an extra wall inside")
        precondition(overlap.vertices.allSatisfy { $0.x <= -2.199 || $0.x >= 3.199 },"Overlapping cuts must retain their full admission space")
        var remote = CityMesh()
        remote.barricade(path:[CGPoint(x:-10,y:0),CGPoint(x:10,y:0)],apertures:[CGPoint(x:0,y:5)],metersToWorld:1)
        precondition(remote.vertices.count == 24,"An unrelated nearby gate cannot remove a wall")
        print("PASS: gate wall meshes expose actual admission intervals, merge overlapping openings and ignore unrelated apertures")
    }
}
