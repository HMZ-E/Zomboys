import SceneKit

/// Original procedural landmark silhouettes; detail is geometry, not map imagery.
@MainActor
enum TacticalLandmarkModels {
    static func make(_ landmark: MapLandmark) -> SCNNode {
        let root = SCNNode()
        let w = Double(landmark.size.width), d = Double(landmark.size.height)
        let h = landmark.height
        switch landmark.kind {
        case .localMosque:
            let tower = w * 0.13, tx = Float(-w * 0.30), tz = Float(-d * 0.30)
            root.addChildNode(CityModels.box(w * 0.90, h * 0.25, d * 0.86, color: 0xDDD2B9,
                                            at: SCNVector3(0, Float(h * 0.125), 0)))
            root.addChildNode(CityModels.box(w * 0.94, h * 0.025, d * 0.90, color: 0x568575,
                                            at: SCNVector3(0, Float(h * 0.262), 0)))
            root.addChildNode(CityModels.box(tower, h * 0.87, tower, color: 0xE4D8BD,
                                            at: SCNVector3(tx, Float(h * 0.435), tz)))
            root.addChildNode(CityModels.box(tower * 1.10, h * 0.025, tower * 1.10, color: 0x51816E,
                                            at: SCNVector3(tx, Float(h * 0.83), tz)))
            root.addChildNode(CityModels.box(tower * 0.66, h * 0.10, tower * 0.66, color: 0xD9C9A5,
                                            at: SCNVector3(tx, Float(h * 0.93), tz)))
            let crown = SCNPyramid(width: tower * 0.73, height: h * 0.05, length: tower * 0.73)
            crown.materials = [CityModels.material(0x3D826B)]
            let top = SCNNode(geometry: crown)
            top.position = SCNVector3(tx, Float(h * 0.995), tz)
            root.addChildNode(top)
            for i in 0..<5 {
                root.addChildNode(CityModels.box(w * 0.08, h * 0.12, d * 0.006, color: 0x78907D,
                    at: SCNVector3(Float(-w * 0.34 + Double(i) * w * 0.17), Float(h * 0.12), Float(d * 0.434))))
            }
        case .municipalPalace:
            root.addChildNode(CityModels.box(w, h * 0.10, d, color: 0xBBAF93,
                                            at: SCNVector3(0, Float(h * 0.05), 0)))
            for x in [-w * 0.34, w * 0.34] {
                root.addChildNode(CityModels.box(w * 0.24, h * 0.79, d * 0.92, color: 0xD9CFB8,
                                                at: SCNVector3(Float(x), Float(h * 0.495), 0)))
            }
            root.addChildNode(CityModels.box(w * 0.94, h * 0.79, d * 0.20, color: 0xD9CFB8,
                                            at: SCNVector3(0, Float(h * 0.495), Float(-d * 0.35))))
            root.addChildNode(CityModels.box(w * 0.50, h * 0.86, d * 0.17, color: 0xE3D8BC,
                                            at: SCNVector3(0, Float(h * 0.53), Float(d * 0.34))))
            root.addChildNode(CityModels.box(w * 0.90, h * 0.03, d * 0.87, color: 0x738A77,
                                            at: SCNVector3(0, Float(h * 0.915), 0)))
            for i in 0..<6 {
                root.addChildNode(CityModels.box(w * 0.07, h * 0.30, d * 0.006, color: 0x598281,
                    at: SCNVector3(Float(-w * 0.34 + Double(i) * w * 0.135), Float(h * 0.55), Float(d * 0.427))))
            }
            root.addChildNode(CityModels.box(w * 0.10, h * 0.39, d * 0.007, color: 0x6F6B52,
                                            at: SCNVector3(0, Float(h * 0.275), Float(d * 0.43))))
        case .kasbah:
            // Low, ochre courtyard walls and square bastions distinguish the
            // Kasbah from apartment blocks without expensive surface detail.
            let thickness = min(w, d) * 0.075
            root.addChildNode(CityModels.box(w, h * 0.035, d, color: 0xB9AB89,
                                            at: SCNVector3(0, Float(h * 0.018), 0)))
            for z in [-d * 0.45, d * 0.45] {
                root.addChildNode(CityModels.box(w, h * 0.64, thickness, color: 0xB79160,
                                                at: SCNVector3(0, Float(h * 0.32), Float(z))))
                for i in 0..<8 {
                    root.addChildNode(CityModels.box(w * 0.06, h * 0.09, thickness * 1.06, color: 0xC0A06D,
                        at: SCNVector3(Float(-w * 0.44 + Double(i) * w * 0.125), Float(h * 0.685), Float(z))))
                }
            }
            for x in [-w * 0.45, w * 0.45] {
                root.addChildNode(CityModels.box(thickness, h * 0.64, d, color: 0xB79160,
                                                at: SCNVector3(Float(x), Float(h * 0.32), 0)))
                for z in [-d * 0.43, d * 0.43] {
                    root.addChildNode(CityModels.box(w * 0.13, h, d * 0.15, color: 0xC1A16E,
                        at: SCNVector3(Float(x), Float(h / 2), Float(z))))
                    root.addChildNode(CityModels.box(w * 0.15, h * 0.055, d * 0.17, color: 0xCBBB91,
                        at: SCNVector3(Float(x), Float(h * 1.025), Float(z))))
                }
            }
            root.addChildNode(CityModels.box(w * 0.10, h * 0.44, thickness * 1.02, color: 0x665745,
                                            at: SCNVector3(0, Float(h * 0.22), Float(d * 0.455))))
            root.addChildNode(CityModels.box(w * 0.29, h * 0.42, d * 0.16, color: 0xC4A56F,
                                            at: SCNVector3(0, Float(h * 0.21), Float(-d * 0.29))))
        case .university:
            // An original compact campus silhouette with open central courtyard.
            root.addChildNode(CityModels.box(w, h * 0.025, d, color: 0xCEC7B3,
                                            at: SCNVector3(0, Float(h * 0.0125), 0)))
            for x in [-w * 0.34, w * 0.34] {
                root.addChildNode(CityModels.box(w * 0.22, h * 0.67, d * 0.86, color: 0xDED7C4,
                                                at: SCNVector3(Float(x), Float(h * 0.335), 0)))
                root.addChildNode(CityModels.box(w * 0.23, h * 0.03, d * 0.87, color: 0x648B82,
                                                at: SCNVector3(Float(x), Float(h * 0.685), 0)))
            }
            root.addChildNode(CityModels.box(w * 0.91, h * 0.87, d * 0.18, color: 0xDACDB3,
                                            at: SCNVector3(0, Float(h * 0.435), Float(-d * 0.36))))
            root.addChildNode(CityModels.box(w * 0.24, h, d * 0.14, color: 0xE7DDC5,
                                            at: SCNVector3(0, Float(h / 2), Float(d * 0.40))))
            root.addChildNode(CityModels.box(w * 0.11, h * 0.49, d * 0.02, color: 0x598B91,
                                            at: SCNVector3(0, Float(h * 0.255), Float(d * 0.476))))
            for i in 0..<8 {
                root.addChildNode(CityModels.box(w * 0.055, h * 0.25, d * 0.005, color: 0x5A8D95,
                    at: SCNVector3(Float(-w * 0.38 + Double(i) * w * 0.108), Float(h * 0.46), Float(-d * 0.265))))
            }
        case .mosque:
            root.addChildNode(CityModels.box(w * 1.3,1,d * 1.35,color:0xBEBAA4,at:SCNVector3(0,0.5,0)))
            root.addChildNode(CityModels.box(w * 0.9,h * 0.24,d * 0.72,color:0xE4DDC9,at:SCNVector3(0,Float(h * 0.12),0)))
            root.addChildNode(CityModels.box(w * 0.94,2,d * 0.76,color:0x467F73,at:SCNVector3(0,Float(h * 0.24+1),0)))
            let tx = Float(-w * 0.29), tz = Float(-d * 0.39), towerWidth = max(8,w * 0.12)
            root.addChildNode(CityModels.box(towerWidth,h * 0.85,towerWidth,color:0xEDE5D0,at:SCNVector3(tx,Float(h * 0.425),tz)))
            root.addChildNode(CityModels.box(towerWidth*1.12,2,towerWidth*1.12,color:0x47796A,at:SCNVector3(tx,Float(h*0.72),tz)))
            root.addChildNode(CityModels.box(towerWidth * 0.6,h * 0.11,towerWidth * 0.6,color:0xD7D5B8,at:SCNVector3(tx,Float(h * 0.9),tz)))
            let crown = SCNPyramid(width:towerWidth*0.8,height:h*0.08,length:towerWidth*0.8); crown.materials = [CityModels.material(0x3A8776)]
            let cn = SCNNode(geometry:crown); cn.position = SCNVector3(tx,Float(h*0.96),tz); root.addChildNode(cn)
            for level in 0..<7 {
                let elevation = Float(h * 0.13 + Double(level) * h * 0.08)
                root.addChildNode(CityModels.box(towerWidth*0.38,h*0.045,0.3,color:0x548B7C,at:SCNVector3(tx,elevation,tz+Float(towerWidth/2+0.1))))
                root.addChildNode(CityModels.box(0.3,h*0.045,towerWidth*0.38,color:0x548B7C,at:SCNVector3(tx+Float(towerWidth/2+0.1),elevation,tz)))
            }
            for i in 0..<8 {
                let x = Float(-w * 0.39 + Double(i) * w * 0.11)
                root.addChildNode(CityModels.box(w*0.045,h*0.12,0.5,color:0x8B9C89,at:SCNVector3(x,Float(h*0.08),Float(d*0.365))))
                let arch = SCNTorus(ringRadius:w*0.022,pipeRadius:w*0.005); arch.ringSegmentCount = 12; arch.pipeSegmentCount = 5; arch.materials = [CityModels.material(0xD5BE94)]
                let a = SCNNode(geometry:arch); a.position = SCNVector3(x,Float(h*0.14),Float(d*0.37)); a.eulerAngles.x = .pi/2; root.addChildNode(a)
            }
            for x in [-w*0.42,w*0.42] { for z in [-d*0.52,d*0.52] {
                let palm = palmTree(height:max(9,h*0.2)); palm.position = SCNVector3(Float(x),0,Float(z)); root.addChildNode(palm)
            } }
        case .twinCenter:
            for x in [-w*0.23,w*0.23] {
                root.addChildNode(CityModels.box(w*0.3,h,d*0.75,color:0xAEBDC0,at:SCNVector3(Float(x),Float(h/2),0),chamfer:1))
                root.addChildNode(CityModels.box(w*0.23,5,d*0.65,color:0xDEDFCB,at:SCNVector3(Float(x),Float(h),0)))
                for row in 1..<15 { root.addChildNode(CityModels.box(w*0.31,0.8,d*0.76,color:0x577D87,at:SCNVector3(Float(x),Float(Double(row)*h/15),0))) }
            }
            root.addChildNode(CityModels.box(w*0.95,6,d*0.95,color:0xC5C4B1,at:SCNVector3(0,3,0)))
        case .moroccoMall:
            root.addChildNode(CityModels.box(w,12,d,color:0xDFD2BB,at:SCNVector3(0,6,0),chamfer:4))
            root.addChildNode(CityModels.box(w*0.9,1,d*0.9,color:0xB4B59D,at:SCNVector3(0,12.5,0),chamfer:3))
            let dome = CityModels.sphere(min(w,d)*0.15,color:0x7CA6AA,at:SCNVector3(0,13,0)); dome.scale.y = 0.38; root.addChildNode(dome)
            for i in 0..<10 {
                root.addChildNode(CityModels.box(w*0.055,5,0.3,color:0x61959B,at:SCNVector3(Float(-w*0.4+Double(i)*w*0.09),7,Float(d/2+0.2))))
            }
            for x in [-w*0.55,w*0.55] { for z in [-d*0.25,d*0.25] { let palm = palmTree(height:12); palm.position = SCNVector3(Float(x),0,Float(z)); root.addChildNode(palm) } }
        case .cathedral:
            root.addChildNode(CityModels.box(w*0.55,h*0.42,d,color:0xE0E2CF,at:SCNVector3(0,Float(h*0.21),0)))
            for x in [-w*0.33,w*0.33] {
                root.addChildNode(CityModels.box(w*0.2,h,d*0.18,color:0xECEBDD,at:SCNVector3(Float(x),Float(h/2),Float(d*0.36))))
                for row in 0..<4 { root.addChildNode(CityModels.box(w*0.08,h*0.11,0.4,color:0x6B8A86,at:SCNVector3(Float(x),Float(h*0.3+Double(row)*h*0.15),Float(d*0.452)))) }
            }
            for i in 0..<7 { root.addChildNode(CityModels.box(w*0.7,1,d*0.022,color:0xB2B9A9,at:SCNVector3(0,Float(h*0.43),Float(-d*0.43+Double(i)*d*0.14)))) }
        case .mohammedSquare:
            let paving = min(0.6, h * 0.04), basin = min(2, h * 0.20), water = min(0.3, h * 0.035)
            let jet = min(6, h * 0.70)
            root.addChildNode(CityModels.box(w,paving,d,color:0xC5BFA5,at:SCNVector3(0,Float(paving/2),0)))
            root.addChildNode(CityModels.cylinder(min(w,d)*0.18,basin,color:0xAAA988,at:SCNVector3(0,Float(basin/2),0),sides:24))
            root.addChildNode(CityModels.cylinder(min(w,d)*0.155,water,color:0x50A6AF,at:SCNVector3(0,Float(basin+water/2),0),sides:24))
            root.addChildNode(CityModels.cylinder(min(1.5,h*0.12),jet,color:0xB9D9CB,at:SCNVector3(0,Float(basin+jet/2),0)))
            for i in 0..<8 { let angle = Double(i)*Double.pi/4; let p = palmTree(height:min(10,h*1.4)); p.position = SCNVector3(Float(cos(angle)*w*0.43),0,Float(sin(angle)*d*0.43)); root.addChildNode(p) }
        case .port:
            for i in 0..<3 {
                let x = Float(-w*0.32+Double(i)*w*0.32)
                root.addChildNode(CityModels.box(3,h,3,color:0xC6B768,at:SCNVector3(x,Float(h/2),0)))
                root.addChildNode(CityModels.box(w*0.38,3,4,color:0xC6B768,at:SCNVector3(x+Float(w*0.1),Float(h),0)))
                root.addChildNode(CityModels.line(from:SCNVector3(x,Float(h),0),to:SCNVector3(x+Float(w*0.23),Float(h-8),0),radius:0.4,color:0x596764))
            }
            for i in 0..<8 { root.addChildNode(CityModels.box(w*0.09,4,d*0.2,color:i % 2 == 0 ? 0xA1634C : 0x597C84,at:SCNVector3(Float(-w*0.35+Double(i%4)*w*0.22),2,Float(d*0.25+Double(i/4)*d*0.22)))) }
        case .clockTower, .lighthouse:
            let radius = max(3,min(w,d)*0.24)
            if landmark.kind == .lighthouse {
                root.addChildNode(CityModels.cylinder(radius,h,color:0xE7DDD1,at:SCNVector3(0,Float(h/2),0),sides:16))
                for i in 1..<4 { root.addChildNode(CityModels.cylinder(radius*1.01,h*0.12,color:0xAC4D40,at:SCNVector3(0,Float(Double(i)*h*0.23),0),sides:16)) }
                root.addChildNode(CityModels.cylinder(radius*1.4,2,color:0x566D68,at:SCNVector3(0,Float(h),0)))
                root.addChildNode(CityModels.cylinder(radius*0.75,4,color:0xB8D5BC,at:SCNVector3(0,Float(h+3),0)))
            } else {
                root.addChildNode(CityModels.box(radius*2,h,radius*2,color:0xD9CDA9,at:SCNVector3(0,Float(h/2),0)))
                root.addChildNode(CityModels.box(radius*2.3,2,radius*2.3,color:0x719280,at:SCNVector3(0,Float(h*0.85),0)))
                let clock = CityModels.cylinder(radius*0.55,0.3,color:0xF4EBCD,at:SCNVector3(0,Float(h*0.76),Float(radius+0.2))); clock.eulerAngles.x = .pi/2; root.addChildNode(clock)
                root.addChildNode(CityModels.box(0.3,radius*0.6,0.3,color:0x4B665B,at:SCNVector3(0,Float(h*0.76+radius*0.2),Float(radius+0.45))))
            }
        case .stadium:
            root.addChildNode(CityModels.box(w,h*0.3,d,color:0xCAC7B7,at:SCNVector3(0,Float(h*0.15),0),chamfer:8))
            root.addChildNode(CityModels.box(w*0.74,h*0.31,d*0.7,color:0x547B48,at:SCNVector3(0,Float(h*0.16),0),chamfer:5))
            root.addChildNode(CityModels.box(w*0.57,0.5,d*0.45,color:0x719251,at:SCNVector3(0,Float(h*0.32),0)))
            for x in [-w*0.43,w*0.43] { for z in [-d*0.4,d*0.4] { root.addChildNode(CityModels.cylinder(0.8,h,color:0xA1AC9E,at:SCNVector3(Float(x),Float(h/2),Float(z)))); root.addChildNode(CityModels.box(6,2,3,color:0xE9E5BC,at:SCNVector3(Float(x),Float(h),Float(z)))) } }
        case .railwayStation:
            let roof = min(2,h*0.07), trim = min(0.3,d*0.012)
            root.addChildNode(CityModels.box(w,h*0.6,d,color:0xD6CFAD,at:SCNVector3(0,Float(h*0.3),0),chamfer:min(1,w*0.015)))
            root.addChildNode(CityModels.box(w*0.92,roof,d*0.9,color:0x80A59D,at:SCNVector3(0,Float(h*0.6+roof/2),0)))
            for i in 0..<7 { root.addChildNode(CityModels.box(w*0.075,h*0.35,trim,color:0x478B97,at:SCNVector3(Float(-w*0.38+Double(i)*w*0.125),Float(h*0.25),Float(d/2+trim)))) }
        }
        // These landmarks are static. Sharing equivalent materials within this
        // one model lets SceneKit combine their triangles without losing any
        // arches, palms, facade pieces, or their local transforms.
        deduplicateMaterials(in: root)
        let container = SCNNode()
        container.addChildNode(root.flattenedClone())
        // Flatten in local coordinates first; apply the geographical transform
        // only once. Geometry remains on a child for damage recoloring.
        container.position = SCNVector3(Float(landmark.position.x),0,Float(landmark.position.y))
        container.eulerAngles.y = Float(-landmark.heading)
        return container
    }

    private static func deduplicateMaterials(in root: SCNNode) {
        // This bank belongs to a single landmark. Damage to one building must
        // never recolor another model, a vehicle, or a later replacement.
        var bank: [SCNMaterial] = []
        root.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            geometry.materials = geometry.materials.map { material in
                if let existing = bank.first(where: { sameMaterial($0, material) }) { return existing }
                bank.append(material)
                return material
            }
        }
    }

    private static func sameMaterial(_ first: SCNMaterial, _ second: SCNMaterial) -> Bool {
        // CityModels supplies solid-color Lambert materials. Compare their full
        // render configuration conservatively, rather than merging by color
        // alone or assuming that a future texture/emission has the same effect.
        guard first.program == nil, second.program == nil,
              first.shaderModifiers == nil, second.shaderModifiers == nil,
              first.animationKeys.isEmpty, second.animationKeys.isEmpty,
              first.lightingModel == second.lightingModel,
              first.isLitPerPixel == second.isLitPerPixel,
              first.isDoubleSided == second.isDoubleSided,
              first.fillMode == second.fillMode, first.cullMode == second.cullMode,
              first.shininess == second.shininess,
              first.fresnelExponent == second.fresnelExponent,
              first.transparency == second.transparency,
              first.transparencyMode == second.transparencyMode,
              first.blendMode == second.blendMode,
              first.locksAmbientWithDiffuse == second.locksAmbientWithDiffuse,
              first.writesToDepthBuffer == second.writesToDepthBuffer,
              first.readsFromDepthBuffer == second.readsFromDepthBuffer,
              first.colorBufferWriteMask == second.colorBufferWriteMask else { return false }
        let firstProperties = [first.diffuse, first.ambient, first.specular, first.emission,
                               first.transparent, first.reflective, first.multiply, first.normal,
                               first.displacement, first.ambientOcclusion, first.selfIllumination,
                               first.metalness, first.roughness, first.clearCoat,
                               first.clearCoatRoughness, first.clearCoatNormal]
        let secondProperties = [second.diffuse, second.ambient, second.specular, second.emission,
                                second.transparent, second.reflective, second.multiply, second.normal,
                                second.displacement, second.ambientOcclusion, second.selfIllumination,
                                second.metalness, second.roughness, second.clearCoat,
                                second.clearCoatRoughness, second.clearCoatNormal]
        return zip(firstProperties, secondProperties).allSatisfy { pair in sameProperty(pair.0, pair.1) }
    }

    private static func sameProperty(_ first: SCNMaterialProperty, _ second: SCNMaterialProperty) -> Bool {
        let sameContents: Bool
        switch (first.contents, second.contents) {
        case (nil, nil): sameContents = true
        case let (left as NSObject, right as NSObject): sameContents = left.isEqual(right)
        default: sameContents = false
        }
        return sameContents && first.animationKeys.isEmpty && second.animationKeys.isEmpty
            && first.intensity == second.intensity
            && first.minificationFilter == second.minificationFilter
            && first.magnificationFilter == second.magnificationFilter
            && first.mipFilter == second.mipFilter
            && SCNMatrix4EqualToMatrix4(first.contentsTransform, second.contentsTransform)
            && first.wrapS == second.wrapS && first.wrapT == second.wrapT
            && first.mappingChannel == second.mappingChannel
            && first.textureComponents == second.textureComponents
            && first.maxAnisotropy == second.maxAnisotropy
    }

    static func palmTree(height: Double) -> SCNNode {
        let root = SCNNode()
        root.addChildNode(CityModels.cylinder(0.65,height,color:0x84795A,at:SCNVector3(0,Float(height/2),0),sides:6))
        for i in 0..<7 {
            let angle = Double(i)*Double.pi*2/7
            let leaf = CityModels.box(height*0.7,0.4,1.8,color:0x517651,at:SCNVector3(Float(cos(angle)*height*0.25),Float(height),Float(sin(angle)*height*0.25)))
            leaf.eulerAngles.y = Float(-angle); leaf.eulerAngles.z = Float(sin(angle)*0.22); root.addChildNode(leaf)
        }
        return root
    }
}
