import SwiftUI
import SceneKit

/// Ground-plane projection lets the SwiftUI gesture layer share the real 3D camera.
@MainActor
final class TacticalSceneInteraction: ObservableObject {
    weak var view: SCNView?
    var worldSize: CGFloat = 2_200
    var worldUnitsPerPoint: CGFloat = 2
    var focusPoint: CGPoint = .zero
    var onSimulationFrame: ((GameEngine) -> Void)?
    var recordWork: ((String,Double) -> Void)?

    func worldPoint(at point: CGPoint) -> CGPoint? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let dy = far.y - near.y
        guard abs(dy) > 0.00001 else { return nil }
        let t = -near.y / dy
        let p = CGPoint(x: CGFloat(near.x + (far.x - near.x) * t), y: CGFloat(near.z + (far.z - near.z) * t))
        return CGPoint(x: max(10,min(worldSize - 10,p.x)),y: max(10,min(worldSize - 10,p.y)))
    }
    func screenPoint(for point: CGPoint, height: Double = 0) -> CGPoint? {
        guard let view, view.bounds.width > 0 else { return nil }
        let p = view.projectPoint(SCNVector3(Float(point.x),Float(height),Float(point.y)))
        return CGPoint(x: CGFloat(p.x),y: CGFloat(p.y))
    }
}

struct TacticalSceneView: UIViewRepresentable {
    @ObservedObject var game: GameEngine
    var zoom: CGFloat
    var pan: CGSize
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var overhead = false
    var focus: CGPoint? = nil
    var trackingHerdID: Int? = nil
    @ObservedObject var interaction: TacticalSceneInteraction
    @ObservedObject private var performance = TacticalPerformance.shared

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = LayoutTacticalSCNView(frame: .zero, options: nil)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = CityModels.color(0x263C3E)
        view.isPlaying = game.phase == .running && performance.active; view.rendersContinuously = view.isPlaying
        view.delegate = context.coordinator.metrics
        view.preferredFramesPerSecond = performance.framesPerSecond
        view.contentScaleFactor = min(UIScreen.main.scale, performance.renderScale)
        // Native Retina resolution and analytically smoothed crowd discs keep
        // detail sharp without doubling the entire city's sample buffers.
        view.antialiasingMode = .none
        view.allowsCameraControl = false; view.isUserInteractionEnabled = false
        // SwiftUI supplies the map label and deployment action. SceneKit's
        // internal render nodes have no independent accessibility meaning.
        view.isAccessibilityElement = false
        view.accessibilityElements = []
        view.automationElements = []
        interaction.view = view
        interaction.onSimulationFrame = { [weak coordinator = context.coordinator] engine in coordinator?.consumeSimulation(engine) }
        interaction.recordWork = { [weak coordinator = context.coordinator] label,time in coordinator?.metrics.recordWork(label:label,milliseconds:time) }
        view.onLayout = { view in
            context.coordinator.update(view: view, game: game, zoom: zoom, pan: pan, topInset: topInset, bottomInset: bottomInset, overhead: overhead, focus: focus, trackingHerdID:trackingHerdID, interaction: interaction)
        }
        context.coordinator.update(view: view, game: game, zoom: zoom, pan: pan, topInset: topInset, bottomInset: bottomInset, overhead: overhead, focus: focus, trackingHerdID:trackingHerdID, interaction: interaction)
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        (view as? LayoutTacticalSCNView)?.onLayout = { view in
            context.coordinator.update(view: view, game: game, zoom: zoom, pan: pan, topInset: topInset, bottomInset: bottomInset, overhead: overhead, focus: focus, trackingHerdID:trackingHerdID, interaction: interaction)
        }
        context.coordinator.update(view: view, game: game, zoom: zoom, pan: pan, topInset: topInset, bottomInset: bottomInset, overhead: overhead, focus: focus, trackingHerdID:trackingHerdID, interaction: interaction)
    }
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.cancelPendingDetails()
        view.isPlaying = false; view.rendersContinuously = false; view.scene = nil
    }

    @MainActor
    final class Coordinator {
        private let diagnosticNoTerrain = ProcessInfo.processInfo.arguments.contains("--uitesting-no-terrain")
        private let diagnosticNoCrowds = ProcessInfo.processInfo.arguments.contains("--uitesting-no-crowds")
        private let diagnosticNoLandmarks = ProcessInfo.processInfo.arguments.contains("--uitesting-no-landmarks")
        let scene = SCNScene()
        let cameraNode = SCNNode()
        let metrics = TacticalFrameMetrics()
        private let animatedCrowd = TacticalAnimatedCrowd()
        private let crowdQueue = DispatchQueue(label:"com.zomboys.crowd-buffers",qos:.userInitiated)
        private struct CrowdRequest {
            let key: String
            let node: SCNNode
            let items: [CrowdRenderItem]
            let style: CrowdRenderStyle
            let materials: [SCNMaterial]
            let metersToWorld: Double
            let animating: Bool
        }
        private var pendingCrowds: [String:CrowdRequest] = [:]
        private var clearedCrowds = Set<String>()
        private var crowdWorkInFlight = false
        private var crowdGeneration = 0
        private var crowdPhase: GamePhase?
        private var trackedSnapshotFocus: CGPoint?
        private var trackedMemberID: Int?
        private var trackedMemberHerdID: Int?
        private let terrain = SCNNode(), dynamic = SCNNode(), effects = SCNNode()
        private let overviewRoofs = SCNNode()
        private let districtRoads = SCNNode(), overviewRoads = SCNNode()
        private let ruinsNode = SCNNode(), stagedHerdNode = SCNNode()
        private let guideNode = SCNNode()
        private let safeZoneNode = SCNNode(), missionBoundaryNode = SCNNode(), tacticalHistoryNode = SCNNode()
        private var strategicSignature: Int?
        private var barrierSignatures: [Int:Int] = [:]
        private var unitMarkerSignature: Int?
        private let effectModels = TacticalEffectModels()
        private var projectileNodes:[Int:SCNNode] = [:], effectNodes:[Int:SCNNode] = [:], supportNodes:[Int:SCNNode] = [:]
        private var labelNodes:[SCNNode] = []
        private let civilianNode = SCNNode(), zombieNode = SCNNode(), actorMarkers = SCNNode(), unitMarkers = SCNNode()
        private var missionID: UUID?
        private var renderedCity: CityScenario?
        private var chunks: [BuildingChunk] = []
        private var chunksByBuilding: [Int: BuildingChunk] = [:]
        private var landmarkNodes: [Int: SCNNode] = [:]
        private var landmarkRuins: [Int: SCNNode] = [:]
        private var buildingVisualDamage: [Int: Int] = [:], landmarkVisualDamage: [Int: Int] = [:]
        private var lastDestructionRevision = -1
        private var lastStagingRevision = -1
        private var stagingCameraScale = 0.0
        private var stagingBounds = CGRect.zero
        private var detailQueue: [BuildingChunk] = []
        private var baseQueue: [BuildingChunk] = []
        private var detailWorkScheduled = false
        private var detailGeneration = 0
        private var visibilityEpoch = 0
        private weak var renderView: SCNView?
        private var unitNodes: [Int:SCNNode] = [:], aircraftNodes: [Int:SCNNode] = [:]
        private var crewNodes: [Int:SCNNode] = [:]
        private var lastRenderRevision = -1
        private var dynamicSnapshotTime = 0.0
        private var previousCameraZoom: CGFloat = 1
        private var previousCameraOverhead = true
        private var lodCameraBounds = CGRect.null
        private var lodCameraScale = -1.0
        private var stagedMarkerRadius = -1.0
        private var currentGame: GameEngine?
        private var meshDamageVersion = 0
        private var overviewWorkInFlight = false, overviewDirty = false
        private var trackedHerd: Int?
        private var trackedCamera:(zoom:CGFloat,pan:CGSize,top:CGFloat,bottom:CGFloat,overhead:Bool)?
        private weak var sceneInteraction:TacticalSceneInteraction?
        private var lastRevision = -1
        private var cameraScale = 800.0
        private var center = CGPoint.zero
        private var markerScale = 1.0
        private var worldUnitsPerPoint = 2.0
        private var visibleGroundBounds = CGRect.zero
        private var actorGroundBounds = CGRect.zero
        private var bodyIDs: Set<Int> = []
        private var stagedBodyIDs: Set<Int> = []
        private var lastStagedBodyIDs: Set<Int> = []
        private var stagedVisibilityEpoch = -1
        private var stagedDotCount = 0
        private var fineCrowdDetail = true
        private var visibleCrowdPopulation = 0
        private var visibleBodies = 0, visibleDots = 0
        private var metersToWorld = 1.8
        private var wheelAngles: [Int: Double] = [:]
        private var unitSimulationPositions: [Int: CGPoint] = [:]
        private var approachGuidePaths: [Int: [CGPoint]] = [:]
        private var actorCameraCenter = CGPoint.zero
        private var actorCameraPixelScale = 0.0
        private var actorCameraAngle = -1.0
        private var actorCameraViewport = CGSize.zero
        private let buildingMaterials: [SCNMaterial]
        private let detailMaterials: [SCNMaterial]
        private let civilianMaterials = TacticalHumanModels.materials(for:.civilian)
        private let zombieMaterials = TacticalHumanModels.materials(for:.zombie)
        private let soldierMaterials = TacticalHumanModels.materials(for:.soldier)
        private let sniperMaterials = TacticalHumanModels.materials(for:.sniper)
        private let guideMaterials = [CityModels.material(0xB5D97A,emission:0x213914,alpha:0.48),CityModels.material(0x7ACDD6,alpha:0.45),CityModels.material(0xE56B57,emission:0x6B2520,alpha:0.75)]
        private let pointMaterials = TacticalHumanModels.pointMaterials()
        private let markerMaterials = TacticalHumanModels.pointRoleColors.map { CityModels.material($0) }
            + [CityModels.material(0x8ECDE8,emission:0x214A5C),CityModels.material(0xE96857,emission:0x53231C)]
        private let safeZoneMaterials: [SCNMaterial] = {
            let fill = CityModels.material(0x4C99DC)
            fill.lightingModel = .constant; fill.transparency = 0.13; fill.blendMode = .alpha
            fill.readsFromDepthBuffer = true; fill.writesToDepthBuffer = false
            let outline = CityModels.material(0x8ECDE8,alpha:0.85)
            outline.lightingModel = .constant; outline.readsFromDepthBuffer = true
            let breached = CityModels.material(0xDEAB6C,alpha:0.85)
            breached.lightingModel = .constant; breached.readsFromDepthBuffer = true
            return [fill,outline,breached]
        }()
        private let missionBoundaryMaterial: SCNMaterial = {
            let material = CityModels.material(0xD7DED5,alpha:0.65)
            material.lightingModel = .constant; material.readsFromDepthBuffer = true
            return material
        }()
        private let historyMaterials = [CityModels.material(0xE96658,emission:0x521D18),CityModels.material(0xD6DAD0),CityModels.material(0xF1A66A,emission:0x542816)]

        init() {
            buildingMaterials = [0xB3B7B2,0xD2CFBF,0x969F9E,0xC0C4BF,0x7F969A,0xA5ADB0,0xA6AD98,0xBAC0BA,0x686F68,0x39413C].map { CityModels.material(UInt32($0)) }
            detailMaterials = [CityModels.material(0x466E75),CityModels.material(0xA8B3A8),CityModels.material(0xE4DCC4),CityModels.material(0x526957)]
            scene.rootNode.addChildNode(terrain); scene.rootNode.addChildNode(dynamic); scene.rootNode.addChildNode(effects)
            effects.addChildNode(guideNode)
            effects.addChildNode(safeZoneNode); effects.addChildNode(missionBoundaryNode); effects.addChildNode(tacticalHistoryNode)
            safeZoneNode.castsShadow = false; missionBoundaryNode.castsShadow = false; tacticalHistoryNode.castsShadow = false
            dynamic.addChildNode(civilianNode); dynamic.addChildNode(zombieNode); dynamic.addChildNode(actorMarkers); dynamic.addChildNode(unitMarkers)
            dynamic.addChildNode(stagedHerdNode)
            let camera = SCNCamera(); camera.usesOrthographicProjection = true; camera.zNear = 1; camera.zFar = 50_000
            camera.wantsHDR = false; camera.wantsExposureAdaptation = false
            camera.bloomIntensity = 0
            cameraNode.camera = camera; scene.rootNode.addChildNode(cameraNode)
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
            ambient.light?.color = CityModels.color(0xB7D0D1); ambient.light?.intensity = 450; scene.rootNode.addChildNode(ambient)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional
            sun.light?.color = CityModels.color(0xFFE4B8); sun.light?.intensity = 950
            // Directional shading keeps depth without a full-city shadow pass.
            sun.light?.castsShadow = false
            sun.eulerAngles = SCNVector3(-Float.pi/3,-Float.pi/5,0); scene.rootNode.addChildNode(sun)
            scene.background.contents = CityModels.color(0x263C3E)
        }

        func update(view: SCNView, game: GameEngine, zoom: CGFloat, pan: CGSize, topInset: CGFloat, bottomInset: CGFloat, overhead: Bool, focus: CGPoint?, trackingHerdID:Int?, interaction: TacticalSceneInteraction) {
            renderView = view
            currentGame = game
            if trackedHerd != trackingHerdID { trackedHerd = trackingHerdID; trackedSnapshotFocus = trackedFocus(game) }
            trackedCamera = (zoom,pan,topInset,bottomInset,overhead); sceneInteraction = interaction
            view.preferredFramesPerSecond = TacticalPerformance.shared.framesPerSecond
            let renderScale = min(view.window?.screen.scale ?? UIScreen.main.scale, TacticalPerformance.shared.renderScale)
            if view.contentScaleFactor != renderScale { view.contentScaleFactor = renderScale }
            SCNTransaction.begin(); SCNTransaction.disableActions = true
            if missionID != game.missionID {
                missionID = game.missionID
                if renderedCity != game.city { rebuildTerrain(game.map); renderedCity = game.city }
                unitNodes.values.forEach { $0.removeFromParentNode() }; unitNodes.removeAll()
                aircraftNodes.values.forEach { $0.removeFromParentNode() }; aircraftNodes.removeAll(); lastRevision = -1
                crewNodes.values.forEach { $0.removeFromParentNode() }; crewNodes.removeAll()
                projectileNodes.values.forEach { $0.removeFromParentNode() }; projectileNodes.removeAll()
                effectNodes.values.forEach { $0.removeFromParentNode() }; effectNodes.removeAll()
                supportNodes.values.forEach { $0.removeFromParentNode() }; supportNodes.removeAll()
                metrics.reset(); lastRenderRevision = -1
                crowdGeneration += 1; pendingCrowds.removeAll(); clearedCrowds.removeAll(); crowdPhase = nil; trackedSnapshotFocus = nil
                trackedMemberID = nil; trackedMemberHerdID = nil
                civilianNode.geometry = nil; zombieNode.geometry = nil; actorMarkers.geometry = nil; stagedHerdNode.geometry = nil
                bodyIDs.removeAll(); stagedBodyIDs.removeAll(); lastStagedBodyIDs.removeAll(); stagedVisibilityEpoch = -1; stagedDotCount = 0
                wheelAngles.removeAll(); unitSimulationPositions.removeAll(); approachGuidePaths.removeAll()
                strategicSignature = nil; barrierSignatures.removeAll(); unitMarkerSignature = nil
                safeZoneNode.geometry = nil; missionBoundaryNode.geometry = nil; tacticalHistoryNode.geometry = nil
                metersToWorld = game.map.metersToWorld
                lastDestructionRevision = -1; lastStagingRevision = -1
            }
            if lastRenderRevision == -1 { trackedSnapshotFocus = trackedFocus(game) }
            let activeFocus = trackedSnapshotFocus ?? focus
            updateCamera(view: view,map:game.map,zoom:zoom,pan:pan,topInset:topInset,bottomInset:bottomInset,overhead:overhead,focus:activeFocus,interaction:interaction,follow:trackingHerdID != nil)
            ensureCrowdPhase(game)
            updateBuildingDamage(game)
            updateLOD(view: view, game: game)
            // Geometry is rebuilt only on simulation snapshots, not on every Metal frame.
            if lastRenderRevision == -1 || lastRenderRevision != game.renderRevision || (game.phase != .running && lastRevision != game.revision) {
                refreshDynamic(game)
                actorCameraCenter = center; actorCameraPixelScale = worldUnitsPerPoint
                actorCameraAngle = overhead ? 0.001 : Double.pi/6
                actorCameraViewport = view.bounds.size
            }
            lastRevision = game.revision
            SCNTransaction.commit()
            // GPU interpolation changes between simulation snapshots. SceneKit
            // cannot infer those changes from its scene graph, so active play
            // must draw continuously at the selected 60/30 FPS target.
            view.isPlaying = game.phase == .running && TacticalPerformance.shared.active
            view.rendersContinuously = view.isPlaying
            if TacticalPerformance.shared.active { requestDisplay() }
        }

        func consumeSimulation(_ game:GameEngine) {
            guard let view = renderView, missionID == game.missionID else { return }
            if lastRenderRevision != game.renderRevision || game.phase != .running {
                SCNTransaction.begin(); SCNTransaction.disableActions = true
                ensureCrowdPhase(game)
                trackedSnapshotFocus = trackedFocus(game)
                if let config = trackedCamera, let interaction = sceneInteraction, let point = trackedSnapshotFocus {
                    updateCamera(view:view,map:game.map,zoom:config.zoom,pan:config.pan,topInset:config.top,bottomInset:config.bottom,overhead:config.overhead,focus:point,interaction:interaction,follow:true)
                    updateLOD(view:view,game:game)
                }
                updateBuildingDamage(game); refreshDynamic(game)
                SCNTransaction.commit()
            }
            view.isPlaying = game.phase == .running && TacticalPerformance.shared.active
            view.rendersContinuously = view.isPlaying
        }

        private func trackedFocus(_ game:GameEngine) -> CGPoint? {
            guard let herd = trackedHerd else {
                trackedMemberID = nil; trackedMemberHerdID = nil; return nil
            }
            if trackedMemberHerdID != herd { trackedMemberID = nil; trackedMemberHerdID = herd }
            if let id = trackedMemberID {
                if let member = game.zombies.first(where: { $0.id == id && $0.herdID == herd }) { return member.position }
                if let member = game.stagedHerdMembers.first(where: { $0.id == id && $0.herdID == herd }) { return member.position }
            }
            // Follow a real member near the herd's center and retain that member
            // across street bends and activation. An average of different roads
            // can land inside a building or far from every visible infected.
            let live = game.zombies.filter { $0.herdID == herd }
            let candidates = live.isEmpty
                ? game.stagedHerdMembers.filter { $0.herdID == herd }.map { ($0.id,$0.position) }
                : live.map { ($0.id,$0.position) }
            guard !candidates.isEmpty else { trackedMemberID = nil; return nil }
            var center = CGPoint.zero
            for (_,point) in candidates { center.x += point.x; center.y += point.y }
            center.x /= CGFloat(candidates.count); center.y /= CGFloat(candidates.count)
            let nearest = candidates.min { a,b in
                let da = pow(a.1.x-center.x,2)+pow(a.1.y-center.y,2)
                let db = pow(b.1.x-center.x,2)+pow(b.1.y-center.y,2)
                return da == db ? a.0 < b.0 : da < db
            }!
            trackedMemberID = nearest.0
            return nearest.1
        }

        private func ensureCrowdPhase(_ game:GameEngine) {
            guard crowdPhase != game.phase else { return }
            crowdGeneration += 1; pendingCrowds.removeAll(); metrics.clearAnimations()
            crowdPhase = game.phase; lastStagingRevision = -1
        }

        private func refreshDynamic(_ game:GameEngine) {
            let began = CACurrentMediaTime()
            if lastRenderRevision != game.renderRevision { dynamicSnapshotTime = metrics.currentRenderTime }
            updateActors(game,smoothing:0); updateStagedHerds(game); updateUnits(game,smoothing:1); updateAircraft(game); updateEffects(game)
            updateStrategicOverlays(game)
            flushCrowds()
            lastRenderRevision = game.renderRevision
            metrics.recordWork(label:"snapshotGeometry",milliseconds:(CACurrentMediaTime()-began)*1_000)
            metrics.setWorkload(city:game.city.title,view:worldUnitsPerPoint < metersToWorld*0.4 ? "street" : (cameraScale > metersToWorld*2_500 ? "city" : "district"),live:game.zombies.count,staged:game.stagedHerdMembers.count,phase:String(describing:game.phase),renderScale:Double(renderView?.contentScaleFactor ?? 1),targetFPS:TacticalPerformance.shared.framesPerSecond,visibleBodies:visibleBodies,visibleDots:visibleDots,speed:game.speed,elapsed:game.elapsed)
        }

        private func updateCamera(view: SCNView, map: CityMap, zoom: CGFloat, pan: CGSize, topInset: CGFloat, bottomInset: CGFloat, overhead: Bool, focus: CGPoint?, interaction: TacticalSceneInteraction, follow:Bool=false) {
            let width = max(1,Double(view.bounds.width)), height = max(1,Double(view.bounds.height))
            let base = max(1_300, min(2_000,Double(max(map.coreBounds.width,map.coreBounds.height))))
            let verticalExtent = base / Double(max(0.03,zoom))
            let scale = height / verticalExtent
            let angle = overhead ? 0.001 : Double.pi/6
            let mapCenterY = (Double(topInset)+height-Double(bottomInset))/2
            let focalPoint = focus ?? map.initialFocus
            center = CGPoint(x: Double(focalPoint.x)-Double(pan.width)/scale,
                             y: Double(focalPoint.y)-(Double(pan.height)+mapCenterY-height/2)/(scale*cos(angle)))
            // Compare with the last rebuilt actor mesh. Small gesture steps
            // must accumulate even while the simulation is paused.
            let pixelScale = 1/scale
            if hypot(center.x-actorCameraCenter.x,center.y-actorCameraCenter.y) > max(0.002,pixelScale*12)
                || abs(pixelScale-actorCameraPixelScale) > max(0.000_05,actorCameraPixelScale*0.025)
                || actorCameraAngle != angle || actorCameraViewport != view.bounds.size { lastRevision = -1 }
            cameraScale = verticalExtent/2
            let animatedCamera = abs(Double(zoom/previousCameraZoom)-1) > 0.15 || overhead != previousCameraOverhead
            SCNTransaction.begin(); SCNTransaction.disableActions = !animatedCamera && !follow
            SCNTransaction.animationDuration = animatedCamera ? 0.18 : 0.05
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:animatedCamera ? .easeInEaseOut : .linear)
            cameraNode.camera?.orthographicScale = cameraScale
            let distance = max(4_000,Double(map.worldSize)*1.4)
            cameraNode.position = SCNVector3(Float(center.x),Float(cos(angle)*distance),Float(center.y+sin(angle)*distance))
            cameraNode.look(at:SCNVector3(Float(center.x),0,Float(center.y)))
            SCNTransaction.commit()
            previousCameraZoom = zoom; previousCameraOverhead = overhead
            interaction.view = view; interaction.worldSize = map.worldSize
            interaction.worldUnitsPerPoint = CGFloat(1/scale)
            interaction.focusPoint = center
            let newMarkerScale = max(0.004,min(64,1/scale))
            markerScale = newMarkerScale; worldUnitsPerPoint = 1/scale
            let padding = max(map.metersToWorld*4,worldUnitsPerPoint*20)
            actorGroundBounds = CGRect(x:Double(center.x)-verticalExtent*width/height/2-padding,
                                       y:Double(center.y)+(Double(topInset)-height/2)/(scale*cos(angle))-padding,
                                       width:verticalExtent*width/height+padding*2,
                                       height:max(1,height-Double(topInset)-Double(bottomInset))/(scale*cos(angle))+padding*2)
            // Terrain has detail at neighborhood zoom and a cheap clean roof mesh at city overview.
            _ = width
        }

        private func rebuildTerrain(_ map: CityMap) {
            terrain.isHidden = diagnosticNoTerrain
            cancelPendingDetails()
            terrain.childNodes.forEach { $0.removeFromParentNode() }; chunks.removeAll(); detailQueue.removeAll(); baseQueue.removeAll()
            districtRoads.childNodes.forEach { $0.removeFromParentNode() }; overviewRoads.geometry = nil
            terrain.addChildNode(districtRoads); terrain.addChildNode(overviewRoads)
            labelNodes.removeAll()
            chunksByBuilding.removeAll(); landmarkNodes.removeAll()
            buildingVisualDamage.removeAll(); landmarkVisualDamage.removeAll(); ruinsNode.geometry = nil
            ruinsNode.childNodes.forEach { $0.removeFromParentNode() }; landmarkRuins.removeAll()
            let extent = Double(map.worldSize)
            lodCameraBounds = .null; lodCameraScale = -1; stagedMarkerRadius = -1
            terrain.addChildNode(CityModels.box(extent,0.5,extent,color:0x35403B,at:SCNVector3(Float(extent/2),-0.5,Float(extent/2))))
            let input = TacticalTerrainMeshInput(map:map), generation = detailGeneration, damageVersion = meshDamageVersion
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let began = CACurrentMediaTime()
                let result = TacticalBuildingMesher.staticTerrain(input:input)
                let duration = (CACurrentMediaTime()-began)*1_000
                DispatchQueue.main.async {
                    guard let self, self.detailGeneration == generation else { return }
                    self.metrics.recordWork(label:"terrainCPU",milliseconds:duration)
                    let beganUpload = CACurrentMediaTime()
                    SCNTransaction.begin(); SCNTransaction.disableActions = true
                    self.terrain.addChildNode(SCNNode(geometry:result.water.geometry(materials:[CityModels.material(0x24515F),CityModels.material(0x78918A)])))
                    self.terrain.addChildNode(SCNNode(geometry:result.parks.geometry(materials:[CityModels.material(0x284E37),CityModels.material(0x647961),CityModels.material(0x254B36)])))
                    let roadMaterials = [CityModels.material(0x555D57),CityModels.material(0x181F23),CityModels.material(0x737B72),CityModels.material(0x9DA393)]
                    for mesh in result.roads { self.districtRoads.addChildNode(SCNNode(geometry:mesh.geometry(materials:roadMaterials))) }
                    self.overviewRoads.geometry = result.overviewRoads.geometry(materials:roadMaterials)
                    if self.meshDamageVersion == damageVersion {
                        self.overviewRoofs.geometry = result.overview.geometry(materials:self.buildingMaterials)
                    } else if let game = self.currentGame { self.requestOverviewRebuild(game.map) }
                    SCNTransaction.commit()
                    self.metrics.recordWork(label:"terrainUpload",milliseconds:(CACurrentMediaTime()-beganUpload)*1_000)
                    self.requestDisplay()
                }
            }
            let chunkSize: CGFloat = max(64,map.metersToWorld*220)
            let grouped = Dictionary(grouping:Array(map.buildings.enumerated())) { item in Int(item.element.rect.midX/chunkSize)*1000+Int(item.element.rect.midY/chunkSize) }
            // City overview uses a tiny roof mesh. Individual extrusions are loaded only
            // for visible neighborhood chunks, so 50,000 buildings never block the first frame.
            for entries in grouped.values {
                var bounds = CGRect.null
                for (_, building) in entries {
                    bounds = bounds.union(building.rect)
                }
                // Keep empty district nodes outside SceneKit's traversal until
                // their geometry is requested by a neighborhood camera.
                let node = SCNNode(); node.isHidden = true
                let chunk = BuildingChunk(node:node,buildings:entries.map(\.element),buildingIDs:entries.map(\.offset),bounds:bounds)
                chunks.append(chunk)
                for (id, _) in entries { chunksByBuilding[id] = chunk }
            }
            overviewRoofs.geometry = nil
            overviewRoofs.castsShadow = false; terrain.addChildNode(overviewRoofs)
            terrain.addChildNode(ruinsNode)
            for (id, landmark) in map.landmarks.enumerated() {
                if diagnosticNoLandmarks { break }
                let node = TacticalLandmarkModels.make(landmark); terrain.addChildNode(node); landmarkNodes[id] = node
            }
            for label in map.labels {
                let text = SCNText(string:label.text,extrusionDepth:0); text.font = UIFont.monospacedSystemFont(ofSize:16,weight:.medium)
                text.flatness = 0.8; text.materials = [CityModels.material(0xE5DDC2,alpha:0.75)]
                let n = SCNNode(geometry:text); n.eulerAngles.x = -.pi/2
                let b = text.boundingBox
                n.position = SCNVector3(Float(label.position.x)-(b.max.x-b.min.x)/2,1,Float(label.position.y))
                terrain.addChildNode(n)
                labelNodes.append(n)
            }
        }

        private func updateBuildingDamage(_ game: GameEngine) {
            guard lastDestructionRevision != game.destructionRevision else { return }
            lastDestructionRevision = game.destructionRevision
            func severity(_ damage: Double, destroyed: Bool) -> Int {
                destroyed || damage >= 1 ? 3 : (damage >= 0.45 ? 2 : (damage > 0 ? 1 : 0))
            }
            var changed: [ObjectIdentifier: BuildingChunk] = [:]
            let buildingIDs = Set(buildingVisualDamage.keys).union(game.buildingDamage.keys).union(game.destroyedBuildingIDs)
            for id in buildingIDs {
                let value = severity(game.buildingDamage[id,default:0],destroyed:game.destroyedBuildingIDs.contains(id))
                guard value != buildingVisualDamage[id,default:0] else { continue }
                if value == 0 { buildingVisualDamage.removeValue(forKey:id) } else { buildingVisualDamage[id] = value }
                if let chunk = chunksByBuilding[id] { changed[ObjectIdentifier(chunk)] = chunk }
            }
            for chunk in changed.values {
                chunk.detail?.removeFromParentNode(); chunk.detail = nil
                var rubble = CityMesh(materialCount:buildingMaterials.count)
                for (id, building) in zip(chunk.buildingIDs,chunk.buildings) where buildingVisualDamage[id,default:0] == 3 {
                    appendRuin(rect:building.rect,height:building.height,seed:id,to:&rubble)
                }
                if rubble.vertices.isEmpty {
                    chunk.ruins.geometry = nil; chunk.ruins.removeFromParentNode()
                } else {
                    chunk.ruins.geometry = rubble.geometry(materials:buildingMaterials)
                    if chunk.ruins.parent == nil { ruinsNode.addChildNode(chunk.ruins) }
                }
                chunk.node.geometry = nil; chunk.hasBaseGeometry = false
                chunk.node.removeFromParentNode()
                if chunk.wantsBase && !chunk.baseQueued { chunk.baseQueued = true; baseQueue.append(chunk) }
            }
            if !changed.isEmpty {
                meshDamageVersion += 1; lodCameraBounds = .null
                requestOverviewRebuild(game.map)
            }
            let landmarkIDs = Set(landmarkVisualDamage.keys).union(game.landmarkDamage.keys).union(game.destroyedLandmarkIDs)
            for id in landmarkIDs where game.map.landmarks.indices.contains(id) {
                let value = severity(game.landmarkDamage[id,default:0],destroyed:game.destroyedLandmarkIDs.contains(id))
                guard value != landmarkVisualDamage[id,default:0] else { continue }
                if value == 0 { landmarkVisualDamage.removeValue(forKey:id) } else { landmarkVisualDamage[id] = value }
                landmarkNodes[id]?.removeFromParentNode()
                landmarkRuins.removeValue(forKey:id)?.removeFromParentNode()
                if value < 3 {
                    let node = TacticalLandmarkModels.make(game.map.landmarks[id])
                    if value > 0 {
                        node.enumerateChildNodes { child, _ in
                            for material in child.geometry?.materials ?? [] { material.diffuse.contents = CityModels.color(value == 2 ? 0x69665B : 0x928B77) }
                        }
                    }
                    terrain.addChildNode(node); landmarkNodes[id] = node
                } else {
                    landmarkNodes.removeValue(forKey:id)
                    let landmark = game.map.landmarks[id]
                    let rect = CGRect(x:landmark.position.x-landmark.size.width/2,y:landmark.position.y-landmark.size.height/2,width:landmark.size.width,height:landmark.size.height)
                    var rubble = CityMesh(materialCount:buildingMaterials.count)
                    appendRuin(rect:rect,height:landmark.height,seed:id+50_000,to:&rubble)
                    let node = SCNNode(geometry:rubble.geometry(materials:buildingMaterials))
                    ruinsNode.addChildNode(node); landmarkRuins[id] = node
                }
            }
        }

        private func requestOverviewRebuild(_ map: CityMap) {
            overviewDirty = true
            guard !overviewWorkInFlight else { return }
            overviewWorkInFlight = true; overviewDirty = false
            let generation = detailGeneration, version = meshDamageVersion
            let buildings = map.buildings, damage = buildingVisualDamage
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let mesh = TacticalBuildingMesher.overview(buildings: buildings, ids: Array(buildings.indices), damage: damage)
                DispatchQueue.main.async {
                    guard let self, self.detailGeneration == generation else { return }
                    self.overviewWorkInFlight = false
                    if self.meshDamageVersion == version {
                        SCNTransaction.begin(); SCNTransaction.disableActions = true
                        self.overviewRoofs.geometry = mesh.vertices.isEmpty ? nil : mesh.geometry(materials: self.buildingMaterials)
                        SCNTransaction.commit()
                        self.requestDisplay()
                    }
                    if self.overviewDirty, let game = self.currentGame { self.requestOverviewRebuild(game.map) }
                }
            }
        }

        private func appendRuin(rect: CGRect, height: Double, seed: Int, to mesh: inout CityMesh) {
            mesh.polygon(rectPoints(rect),altitude:0.46,material:9)
            let rubbleHeight = max(metersToWorld*0.35,min(height*0.14,metersToWorld*2.5))
            for i in 0..<4 {
                let ox = Double((seed+i*7)%11)/10-0.5, oz = Double((seed+i*3)%13)/12-0.5
                let h = rubbleHeight*(0.45+Double(i)*0.15)
                mesh.orientedBox(center:SCNVector3(Float(rect.midX+rect.width*ox*0.62),Float(0.47+h/2),Float(rect.midY+rect.height*oz*0.62)),
                                 width:Double(rect.width)*(0.16+Double(i%2)*0.09),height:h,depth:Double(rect.height)*0.22,yaw:Double(seed%9+i)*0.63,material:i%2 == 0 ? 8 : 9)
            }
        }

        private func updateStagedHerds(_ game: GameEngine) {
            defer { visibleDots += stagedDotCount }
            let radius = markerScale*0.62
            guard lastStagingRevision != game.stagingRevision || stagedVisibilityEpoch != visibilityEpoch || lastStagedBodyIDs != stagedBodyIDs || abs(stagedMarkerRadius-radius) > max(0.001,radius*0.02) else { return }
            lastStagingRevision = game.stagingRevision; stagedMarkerRadius = radius
            stagedVisibilityEpoch = visibilityEpoch; lastStagedBodyIDs = stagedBodyIDs
            let bounds = visibleGroundBounds.insetBy(dx:-metersToWorld*4,dy:-metersToWorld*4)
            let items = game.stagedHerdMembers.filter { bounds.contains($0.position) && !stagedBodyIDs.contains($0.id) }.map { member -> CrowdRenderItem in
                let pose = TacticalHumanPose(position:member.position,heading:member.heading,stride:0,speed:0,variant:member.id,role:.zombie)
                return CrowdRenderItem(id:member.id,current:pose,previous:pose,material:1)
            }
            stagedDotCount = items.count
            requestCrowd(items,style:.dots(radius:radius,altitude:0.42),materials:pointMaterials,key:"staged",node:stagedHerdNode,game:game,animating:false)
        }

        private func updateLOD(view: SCNView, game: GameEngine) {
            visibleGroundBounds = actorGroundBounds
            for node in labelNodes { node.isHidden = cameraScale < metersToWorld*1_200 }
            guard lodCameraBounds.isNull || abs(lodCameraScale-cameraScale) > max(0.001,cameraScale*0.01)
                    || hypot(lodCameraBounds.midX-actorGroundBounds.midX,lodCameraBounds.midY-actorGroundBounds.midY) > worldUnitsPerPoint*10 else { return }
            lodCameraBounds = actorGroundBounds; lodCameraScale = cameraScale
            visibilityEpoch += 1
            let aspect = Double(max(1,view.bounds.width)/max(1,view.bounds.height))
            let padding = max(metersToWorld*25,worldUnitsPerPoint*12)
            let visible = CGRect(x:Double(center.x)-cameraScale*aspect-padding,y:Double(center.y)-cameraScale*1.3-padding,width:cameraScale*aspect*2+padding*2,height:cameraScale*2.6+padding*2)
            let detailed = cameraScale < metersToWorld*350, neighborhood = cameraScale < metersToWorld*2_500
            districtRoads.isHidden = !neighborhood
            overviewRoads.isHidden = neighborhood
            var waitingForBase = false
            for chunk in chunks {
                let visibleChunk = chunk.bounds.intersects(visible)
                chunk.wantsBase = visibleChunk && neighborhood
                chunk.node.isHidden = !chunk.wantsBase || !chunk.hasBaseGeometry
                if chunk.wantsBase && !chunk.hasBaseGeometry {
                    waitingForBase = true
                    if !chunk.baseQueued { chunk.baseQueued = true; baseQueue.append(chunk) }
                }
                chunk.wantsDetail = detailed && visibleChunk
                if chunk.wantsBase { chunk.lastVisibleEpoch = visibilityEpoch }
                if chunk.wantsDetail && chunk.hasBaseGeometry && chunk.detail == nil && !chunk.detailQueued {
                    chunk.detailQueued = true; detailQueue.append(chunk)
                }
                chunk.detail?.isHidden = !chunk.wantsDetail
            }
            // Keep visible geometry and a small history of nearby blocks. A full
            // city tour must not retain facade meshes for all 50,000 buildings.
            let hiddenCached = chunks.filter { !$0.wantsBase && ($0.hasBaseGeometry || $0.detail != nil) }
                .sorted { $0.lastVisibleEpoch > $1.lastVisibleEpoch }
            for chunk in hiddenCached.dropFirst(8) {
                chunk.node.geometry = nil; chunk.hasBaseGeometry = false
                chunk.node.removeFromParentNode()
                chunk.detail?.removeFromParentNode(); chunk.detail = nil
            }
            overviewRoofs.isHidden = neighborhood && !waitingForBase
            if !detailWorkScheduled && (!detailQueue.isEmpty || !baseQueue.isEmpty) { detailWorkScheduled = true; scheduleDetailBatch() }
        }

        private func scheduleDetailBatch() {
            let generation = detailGeneration
            DispatchQueue.main.asyncAfter(deadline:.now()+0.012) { [weak self] in
                guard let self, self.detailGeneration == generation else { return }
                guard TacticalPerformance.shared.active else { self.detailWorkScheduled = false; return }
                var candidate:BuildingChunk?
                var detail = false
                while !self.baseQueue.isEmpty && candidate == nil {
                    let chunk = self.baseQueue.removeFirst(); chunk.baseQueued = false
                    if chunk.wantsBase && !chunk.hasBaseGeometry { candidate = chunk }
                }
                while candidate == nil && !self.detailQueue.isEmpty {
                    let chunk = self.detailQueue.removeFirst(); chunk.detailQueued = false
                    if chunk.wantsDetail && chunk.hasBaseGeometry && chunk.detail == nil { candidate = chunk; detail = true }
                }
                guard let chunk = candidate else { self.detailWorkScheduled = false; return }
                let buildings = chunk.buildings, ids = chunk.buildingIDs, damage = self.buildingVisualDamage
                let version = self.meshDamageVersion
                let wantsDetail = detail
                DispatchQueue.global(qos:.userInitiated).async { [weak self, weak chunk] in
                    let began = CACurrentMediaTime()
                    let mesh = wantsDetail
                        ? TacticalBuildingMesher.details(buildings:zip(ids,buildings).filter { damage[$0.0,default:0] == 0 }.map { $0.1 })
                        : TacticalBuildingMesher.base(buildings:buildings,ids:ids,damage:damage)
                    let workTime = (CACurrentMediaTime()-began)*1_000
                    DispatchQueue.main.async {
                        guard let self, let chunk, self.detailGeneration == generation else { return }
                        self.metrics.recordWork(label:"chunkCPU",milliseconds:workTime)
                        let beganUpload = CACurrentMediaTime()
                        SCNTransaction.begin(); SCNTransaction.disableActions = true
                        if self.meshDamageVersion == version {
                            if wantsDetail && chunk.wantsDetail && chunk.hasBaseGeometry && chunk.detail == nil {
                                let node = SCNNode(geometry:mesh.geometry(materials:self.detailMaterials)); chunk.detail = node; self.terrain.addChildNode(node)
                            } else if !wantsDetail && chunk.wantsBase && !chunk.hasBaseGeometry {
                                chunk.node.geometry = mesh.geometry(materials:self.buildingMaterials)
                                if chunk.node.parent == nil { self.terrain.addChildNode(chunk.node) }
                                chunk.hasBaseGeometry = true; chunk.node.isHidden = false
                                if chunk.wantsDetail && !chunk.detailQueued { chunk.detailQueued = true; self.detailQueue.append(chunk) }
                            }
                        } else if chunk.wantsBase && !chunk.hasBaseGeometry && !chunk.baseQueued {
                            chunk.baseQueued = true; self.baseQueue.append(chunk)
                        } else if wantsDetail && chunk.wantsDetail && !chunk.detailQueued {
                            chunk.detailQueued = true; self.detailQueue.append(chunk)
                        }
                        SCNTransaction.commit()
                        self.metrics.recordWork(label:"chunkUpload",milliseconds:(CACurrentMediaTime()-beganUpload)*1_000)
                        self.requestDisplay()
                        if self.detailQueue.isEmpty && self.baseQueue.isEmpty { self.detailWorkScheduled = false }
                        else { self.scheduleDetailBatch() }
                    }
                }
            }
        }

        func cancelPendingDetails() {
            detailGeneration += 1
            overviewWorkInFlight = false; overviewDirty = false
            crowdGeneration += 1; pendingCrowds.removeAll(); metrics.clearAnimations()
            detailWorkScheduled = false
            detailQueue.removeAll(); baseQueue.removeAll()
            for chunk in chunks { chunk.detailQueued = false; chunk.baseQueued = false }
        }

        private func requestDisplay() {
            // Playback already schedules continuous frames. Explicit redraws
            // are needed only while planning or paused.
            guard let view = renderView, !view.rendersContinuously else { return }
            view.setNeedsDisplay()
        }

        private func motionItem(id:Int,point:CGPoint,heading:Double,stride:Double,speed:Double,role:TacticalHumanRole,material:Int=0,game:GameEngine) -> CrowdRenderItem {
            let phase = Double(abs(id) % 29) / 29 * .pi * 2
            let currentStride = speed < metersToWorld*0.03 ? game.elapsed*0.9 + phase : stride + phase
            let current = TacticalHumanPose(position:point,heading:heading,stride:currentStride,speed:speed,variant:id,role:role)
            let old = game.previousMotion(for:id)
            let oldSpeed = old?.speed ?? speed
            let oldStride = oldSpeed < metersToWorld*0.03 ? game.previousRenderElapsed*0.9 + phase : (old?.stride ?? stride) + phase
            let previous = TacticalHumanPose(position:old?.position ?? point,heading:old?.heading ?? heading,stride:oldStride,speed:oldSpeed,variant:id,role:role)
            return CrowdRenderItem(id:id,current:current,previous:previous,material:material)
        }

        private func requestCrowd(_ items:[CrowdRenderItem],style:CrowdRenderStyle,materials:[SCNMaterial],key:String,node:SCNNode,game:GameEngine,animating:Bool?=nil) {
            guard !items.isEmpty else {
                pendingCrowds.removeValue(forKey:key); clearedCrowds.insert(key); node.geometry = nil; metrics.unregisterAnimation(key:key)
                return
            }
            clearedCrowds.remove(key)
            pendingCrowds[key] = CrowdRequest(key:key,node:node,items:items,style:style,materials:materials,
                                             metersToWorld:metersToWorld,animating:animating ?? (game.phase == .running))
        }

        private func flushCrowds() {
            if diagnosticNoCrowds { pendingCrowds.removeAll(keepingCapacity:true); return }
            guard !crowdWorkInFlight, !pendingCrowds.isEmpty else { return }
            let requests = Array(pendingCrowds.values)
            pendingCrowds.removeAll(keepingCapacity:true)
            crowdWorkInFlight = true
            let generation = crowdGeneration, builder = animatedCrowd
            crowdQueue.async { [weak self] in
                let began = CACurrentMediaTime()
                let prepared = requests.map { request in
                    builder.prepare(items:request.items,style:request.style,metersToWorld:request.metersToWorld,materialCount:request.materials.count)
                }
                let duration = (CACurrentMediaTime()-began)*1_000
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.crowdWorkInFlight = false
                    self.metrics.recordWork(label:"crowdCPU",milliseconds:duration)
                    if self.crowdGeneration == generation {
                        let upload = CACurrentMediaTime()
                        for (request, data) in zip(requests,prepared) where request.node.parent != nil && !request.node.isHidden && !self.clearedCrowds.contains(request.key) {
                            self.metrics.enqueueCrowd(key:request.key,node:request.node,prepared:data,materials:request.materials,animating:request.animating)
                        }
                        self.metrics.recordWork(label:"crowdEnqueue",milliseconds:(CACurrentMediaTime()-upload)*1_000)
                        self.requestDisplay()
                    }
                    self.flushCrowds()
                }
            }
        }

        private func updateActors(_ game:GameEngine,smoothing:Double) {
            let visibleBody = trackedCamera?.overhead == false && 1.72*metersToWorld/worldUnitsPerPoint >= 5
            let bounds = visibleGroundBounds.insetBy(dx:-metersToWorld*2,dy:-metersToWorld*2)
            let residents = game.civilians.filter { bounds.contains($0.position) }
            let infected = game.zombies.filter { bounds.contains($0.position) }
            let staged = visibleBody ? game.stagedHerdMembers.filter { bounds.contains($0.position) } : []
            var candidates: [(id:Int,position:CGPoint)] = residents.map { (id:$0.id,position:$0.position) }
            candidates.append(contentsOf:infected.map { (id:$0.id,position:$0.position) })
            candidates.append(contentsOf:staged.map { (id:$0.id,position:$0.position) })
            visibleCrowdPopulation = candidates.count
            // Keep the nearest bodies inside a fixed budget even in a huge herd.
            // Population thresholds must never turn an entire street into dots.
            bodyIDs = visibleBody ? CrowdDetailSelection.choose(candidates,previous:bodyIDs,focus:center,budget:160) : []
            stagedBodyIDs = Set(staged.filter { bodyIDs.contains($0.id) }.map(\.id))
            if candidates.count > 48 { fineCrowdDetail = false } else if candidates.count < 40 { fineCrowdDetail = true }
            let detailed = 1.72*metersToWorld/worldUnitsPerPoint >= 14 && fineCrowdDetail
            var civilians:[CrowdRenderItem] = [], zombies:[CrowdRenderItem] = [], markers:[CrowdRenderItem] = []
            civilians.reserveCapacity(160); zombies.reserveCapacity(160)
            markers.reserveCapacity(residents.count+infected.count)
            for person in residents {
                let item = motionItem(id:person.id,point:person.position,heading:person.heading,stride:person.stride,speed:person.speed,role:.civilian,material:person.exposure > 0.05 ? 3 : 0,game:game)
                if bodyIDs.contains(person.id) { civilians.append(item) } else { markers.append(item) }
            }
            for person in infected {
                let item = motionItem(id:person.id,point:person.position,heading:person.heading,stride:person.stride,speed:person.speed,role:.zombie,material:person.infectiousAt > game.elapsed ? 3 : 1,game:game)
                if bodyIDs.contains(person.id) { zombies.append(item) } else { markers.append(item) }
            }
            for member in staged where stagedBodyIDs.contains(member.id) {
                let phase = Double(abs(member.id)%29)/29 * .pi*2
                let current = TacticalHumanPose(position:member.position,heading:member.heading,stride:game.elapsed*0.9+phase,speed:0,variant:member.id,role:.zombie)
                let previous = TacticalHumanPose(position:member.position,heading:member.heading,stride:game.previousRenderElapsed*0.9+phase,speed:0,variant:member.id,role:.zombie)
                zombies.append(CrowdRenderItem(id:member.id,current:current,previous:previous,material:1))
            }
            visibleBodies = civilians.count+zombies.count; visibleDots = markers.count
            requestCrowd(civilians,style:.humans(detailed:detailed),materials:civilianMaterials,key:"civilians",node:civilianNode,game:game)
            requestCrowd(zombies,style:.humans(detailed:detailed),materials:zombieMaterials,key:"zombies",node:zombieNode,game:game)
            requestCrowd(markers,style:.dots(radius:markerScale*0.7,altitude:0.42),materials:pointMaterials,key:"markers",node:actorMarkers,game:game)
        }

        private func updateUnits(_ game:GameEngine,smoothing:Double) {
            let present = Set(game.units.map(\.id))
            for id in Array(unitNodes.keys) where !present.contains(id) {
                unitNodes.removeValue(forKey:id)?.removeFromParentNode()
                crewNodes.removeValue(forKey:id)?.removeFromParentNode()
                metrics.unregisterAnimation(key:"crew.\(id)")
                pendingCrowds.removeValue(forKey:"crew.\(id)")
                unitSimulationPositions[id] = nil
                barrierSignatures[id] = nil
            }
            let gates = Dictionary(grouping:game.units.filter { $0.kind == .gate && $0.health > 0 && $0.linkedBarrierID != nil },by:{ $0.linkedBarrierID! })
            var distantUnits: [DefenseUnit] = []
            var markerSignature = Hasher(); markerSignature.combine(markerScale)
            let bodySize = 1.72*metersToWorld/worldUnitsPerPoint
            let detailed = bodySize >= 14 && visibleCrowdPopulation < 40
            var crewBodies = 0
            for unit in game.units {
                guard unit.kind != .safeZone else { continue } // Zones are drawn once as batched ground overlays.
                let count = game.crewCount(for:unit.id)
                let visible:Bool
                if unit.kind == .barricade {
                    let bounds = unit.barrierPath.reduce(CGRect.null) { $0.union(CGRect(x:$1.x,y:$1.y,width:0.01,height:0.01)) }
                    visible = bounds.insetBy(dx:-metersToWorld*2,dy:-metersToWorld*2).intersects(visibleGroundBounds)
                } else { visible = visibleGroundBounds.contains(unit.position) }
                let detailedUnit = unit.kind == .barricade || (bodySize >= 5 && crewBodies+count <= 80)
                guard visible && detailedUnit else {
                    unitNodes[unit.id]?.isHidden = true; crewNodes[unit.id]?.isHidden = true
                    metrics.unregisterAnimation(key:"crew.\(unit.id)")
                    if visible {
                        distantUnits.append(unit)
                        markerSignature.combine(unit.id); markerSignature.combine(unit.kind.rawValue)
                        markerSignature.combine(unit.position.x); markerSignature.combine(unit.position.y)
                        markerSignature.combine(unit.heading); markerSignature.combine(unit.elevation)
                    }
                    continue
                }
                crewBodies += count
                if unitNodes[unit.id] == nil {
                    let node:SCNNode
                    switch unit.kind {
                    case .humvee: node = CityModels.humvee()
                    case .mortar: node = CityModels.mortar()
                    case .evacuation: node = CityModels.station(evacuation:true)
                    case .gate: node = CityModels.civilianGate()
                    case .mine,.c4: node = CityModels.explosive(remote:unit.kind == .c4)
                    case .sniper,.squad,.safeZone,.ac130,.b2,.a10,.barricade: node = SCNNode()
                    }
                    dynamic.addChildNode(node); unitNodes[unit.id] = node
                }
                guard let node = unitNodes[unit.id] else { continue }
                let entering = node.isHidden
                node.isHidden = false
                if unit.kind == .barricade {
                    var signature = Hasher()
                    for point in unit.barrierPath { signature.combine(point.x); signature.combine(point.y) }
                    let apertures = gates[unit.id] ?? []
                    for gate in apertures { signature.combine(gate.id); signature.combine(gate.position.x); signature.combine(gate.position.y) }
                    let value = signature.finalize()
                    if barrierSignatures[unit.id] != value {
                        var mesh = CityMesh()
                        mesh.barricade(path:unit.barrierPath,apertures:apertures.map(\.position),metersToWorld:metersToWorld)
                        node.geometry = mesh.geometry(materials:[CityModels.material(0xC8BC6C)])
                        barrierSignatures[unit.id] = value
                    }
                } else {
                    SCNTransaction.begin(); SCNTransaction.disableActions = game.phase != .running || entering
                    SCNTransaction.animationDuration = 0.05
                    SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.linear)
                    node.position = SCNVector3(Float(unit.position.x),Float(0.3+unit.elevation),Float(unit.position.y))
                    let currentYaw = Double(node.presentation.eulerAngles.y), desiredYaw = -unit.heading-Double.pi/2
                    node.eulerAngles.y = Float(currentYaw+atan2(sin(desiredYaw-currentYaw),cos(desiredYaw-currentYaw)))
                    let scale = Float(metersToWorld); node.scale = SCNVector3(scale,scale,scale)
                    let old = game.previousMotion(for:unit.id)
                    let distance = old.map { hypot(unit.position.x-$0.position.x,unit.position.y-$0.position.y) } ?? 0
                    let actualSpeed = distance / max(0.001,game.renderSimulationInterval)
                    if unit.kind == .humvee {
                        wheelAngles[unit.id,default:0] += distance/metersToWorld/0.42
                        for wheel in node.childNodes where wheel.name?.hasPrefix("wheel.") == true { wheel.eulerAngles.x = Float(-wheelAngles[unit.id,default:0]) }
                        node.childNode(withName:"turret",recursively:false)?.eulerAngles.y = Float(-(unit.turretHeading-unit.heading))
                    }
                    if unit.kind.isExplosive {
                        node.childNode(withName:"armingIndicator",recursively:false)?.opacity = unit.cooldown > 0 ? 0.25 : 1
                    }
                    SCNTransaction.commit()
                    if count > 0 {
                        let role:TacticalHumanRole = unit.kind == .sniper ? .sniper : .soldier
                        var people:[CrowdRenderItem] = []
                        for index in 0..<count {
                            let point = unit.formation.indices.contains(index) ? unit.formation[index] : unit.position
                            let previous = game.previousCrewPosition(unitID:unit.id,index:index) ?? point
                            let heading = actualSpeed > metersToWorld*0.15 ? unit.heading : unit.turretHeading
                            let oldHeading = actualSpeed > metersToWorld*0.15 ? old?.heading ?? heading : old?.turretHeading ?? heading
                            let id = unit.id*10+index
                            let current = TacticalHumanPose(position:point,heading:heading,stride:game.elapsed*8+Double(index)*0.6,speed:actualSpeed,variant:id,role:role)
                            let before = TacticalHumanPose(position:previous,heading:oldHeading,stride:game.previousRenderElapsed*8+Double(index)*0.6,speed:actualSpeed,variant:id,role:role)
                            people.append(CrowdRenderItem(id:id,current:current,previous:before))
                        }
                        let crew = crewNodes[unit.id] ?? SCNNode()
                        if crew.parent == nil { dynamic.addChildNode(crew); crewNodes[unit.id] = crew }
                        crew.isHidden = false; crew.position.y = Float(unit.elevation)
                        requestCrowd(people,style:.humans(detailed:detailed),materials:unit.kind == .sniper ? sniperMaterials : soldierMaterials,key:"crew.\(unit.id)",node:crew,game:game)
                    } else {
                        crewNodes[unit.id]?.isHidden = true
                        metrics.unregisterAnimation(key:"crew.\(unit.id)")
                        pendingCrowds.removeValue(forKey:"crew.\(unit.id)")
                    }
                }
                node.opacity = unit.health < unit.maxHealth*0.3 ? 0.75 : 1
            }
            let markerValue = markerSignature.finalize()
            if unitMarkerSignature != markerValue {
                unitMarkerSignature = markerValue
                var markers = CityMesh(materialCount:markerMaterials.count)
                for unit in distantUnits {
                    let r = markerScale*(unit.kind == .humvee ? 2.1 : 1.7)
                    let material = unit.kind == .gate ? 4 : (unit.kind == .c4 ? 5 : (unit.kind == .mine ? 3 : (unit.kind == .evacuation ? 0 : 2)))
                    let altitude = 0.66+unit.elevation
                    if unit.kind.isExplosive {
                        let p = unit.position
                        markers.polygon([CGPoint(x:p.x,y:p.y-r),CGPoint(x:p.x+r,y:p.y),CGPoint(x:p.x,y:p.y+r),CGPoint(x:p.x-r,y:p.y)],altitude:altitude,material:material)
                    } else {
                        ring(unit.position,radius:r,width:markerScale*0.65,material:material,altitude:altitude,to:&markers)
                        markers.strip(from:unit.position,to:CGPoint(x:unit.position.x+cos(unit.heading)*r,y:unit.position.y+sin(unit.heading)*r),width:markerScale*0.7,altitude:altitude,material:material)
                    }
                }
                unitMarkers.geometry = markers.vertices.isEmpty ? nil : markers.geometry(materials:markerMaterials)
            }
        }

        private func updateAircraft(_ game: GameEngine) {
            let present = Set(game.flights.map(\.id))
            for id in aircraftNodes.keys where !present.contains(id) { aircraftNodes[id]?.removeFromParentNode(); aircraftNodes.removeValue(forKey:id) }
            for flight in game.flights {
                let isNew = aircraftNodes[flight.id] == nil
                if isNew { let node = CityModels.aircraft(flight.kind); dynamic.addChildNode(node); aircraftNodes[flight.id] = node }
                guard let node = aircraftNodes[flight.id] else { continue }
                SCNTransaction.begin(); SCNTransaction.disableActions = game.phase != .running || isNew
                SCNTransaction.animationDuration = 0.05
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.linear)
                node.position = SCNVector3(Float(flight.position.x),Float(flight.altitude),Float(flight.position.y))
                let desiredYaw = -flight.heading-Double.pi/2
                let currentYaw = Double(node.presentation.eulerAngles.y)
                node.eulerAngles.y = Float(currentYaw+atan2(sin(desiredYaw-currentYaw),cos(desiredYaw-currentYaw)))
                // Aircraft face local -Z; positive local roll lowers their port
                // (-X) wing into the counterclockwise gunship orbit.
                node.eulerAngles.z = flight.kind == .ac130 ? 0.13 : 0
                node.scale = SCNVector3(1,1,1)
                for propeller in node.childNodes where propeller.name?.hasPrefix("propeller.") == true { propeller.eulerAngles.z = Float(flight.age*45) }
                if flight.kind == .b2 {
                    let open = min(1,max(0,min((flight.progress-0.26)*12,(0.74-flight.progress)*12)))
                    node.childNode(withName:"bombBay.port",recursively:false)?.eulerAngles.z = Float(open*1.2)
                    node.childNode(withName:"bombBay.starboard",recursively:false)?.eulerAngles.z = Float(-open*1.2)
                }
                SCNTransaction.commit()
            }
        }

        private func updateEffects(_ game: GameEngine) {
            var guides = CityMesh(materialCount:3)
            for unit in game.units where !unit.kind.isWall && unit.kind != .safeZone && unit.range > 0 && (unit.id == game.selectedUnitID || game.phase == .planning) {
                ring(unit.position,radius:unit.range,width:max(metersToWorld*0.04,markerScale*0.9),material:unit.kind.isExplosive ? 2 : (unit.kind == .evacuation ? 1 : 0),altitude:0.65+unit.elevation,to:&guides)
                if let target = unit.targetPosition { guides.strip(from:unit.position,to:target,width:markerScale,altitude:0.5+unit.elevation) }
            }
            for arrival in game.arrivals {
                if !arrival.spawned {
                    // Ring = city entrance; its diameter stays about ten screen
                    // points even when examining a street at maximum zoom.
                    ring(arrival.position,radius:markerScale*(5+0.5*sin(game.elapsed*2)),width:markerScale*0.8,material:2,to:&guides)
                }
                guard arrival.releasedCount < arrival.size else { continue }
                if approachGuidePaths[arrival.id] == nil {
                    if let approach = game.map.herdApproaches.first(where: { $0.source == arrival.sourcePosition }),
                       let ingress = approach.route.firstIndex(of:arrival.position) {
                        approachGuidePaths[arrival.id] = Array(approach.route[...ingress])
                    } else { approachGuidePaths[arrival.id] = [arrival.sourcePosition,arrival.position] }
                }
                let path = approachGuidePaths[arrival.id] ?? []
                let source = arrival.sourcePosition
                let next = path.dropFirst().first ?? arrival.position
                let heading = atan2(next.y-source.y,next.x-source.x),radius = markerScale*6
                let forward = CGVector(dx:cos(heading),dy:sin(heading)),side = CGVector(dx:-forward.dy,dy:forward.dx)
                func offset(_ f: Double,_ s: Double) -> CGPoint { CGPoint(x:source.x+forward.dx*f+side.dx*s,y:source.y+forward.dy*f+side.dy*s) }
                // Filled arrow = outside release source. It remains until the
                // entire streamed herd has left, even after its leader arrives.
                guides.polygon([offset(radius,0),offset(-radius*0.65,radius*0.7),offset(-radius*0.28,0),offset(-radius*0.65,-radius*0.7)],altitude:0.68,material:2)
                for (a,b) in zip(path,path.dropFirst()) {
                    let bounds = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:max(0.01,abs(b.x-a.x)),height:max(0.01,abs(b.y-a.y))).insetBy(dx:-markerScale*10,dy:-markerScale*10)
                    guard bounds.intersects(visibleGroundBounds) else { continue }
                    let length = Double(hypot(b.x-a.x,b.y-a.y)),dash = max(metersToWorld*0.7,markerScale*8)
                    guard length > 0.001 else { continue }
                    let count = min(600,Int(ceil(length/dash)))
                    for i in 0..<count {
                        let ta = min(1,Double(i)*dash/length),tb = min(1,(Double(i)+0.55)*dash/length)
                        let start = CGPoint(x:a.x+(b.x-a.x)*ta,y:a.y+(b.y-a.y)*ta), end = CGPoint(x:a.x+(b.x-a.x)*tb,y:a.y+(b.y-a.y)*tb)
                        if visibleGroundBounds.contains(start) || visibleGroundBounds.contains(end) {
                            guides.strip(from:start,to:end,width:markerScale*0.45,altitude:0.62,material:2)
                        }
                    }
                }
            }
            for flight in game.flights {
                if flight.kind == .ac130 { ring(flight.target,radius:230,width:0.8*markerScale,material:0,to:&guides) }
                else { guides.strip(from:flight.start,to:flight.end,width:0.8*markerScale,altitude:0.6) }
            }
            guideNode.geometry = guides.geometry(materials:guideMaterials)
            let projectileIDs = Set(game.projectiles.map(\.id))
            for id in Array(projectileNodes.keys) where !projectileIDs.contains(id) { projectileNodes.removeValue(forKey:id)?.removeFromParentNode() }
            for projectile in game.projectiles {
                let visible = visibleGroundBounds.insetBy(dx:-projectile.arcHeight,dy:-projectile.arcHeight).contains(projectile.position)
                let fresh = projectileNodes[projectile.id] == nil
                guard visible || !fresh else { continue }
                let node = projectileNodes[projectile.id] ?? effectModels.makeProjectile(projectile,metersToWorld:metersToWorld,worldUnitsPerPoint:worldUnitsPerPoint)
                if fresh { effects.addChildNode(node); projectileNodes[projectile.id] = node }
                node.isHidden = !visible
                SCNTransaction.begin(); SCNTransaction.disableActions = fresh || game.phase != .running
                SCNTransaction.animationDuration = 0.05; SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.linear)
                effectModels.updateProjectile(node:node,projectile:projectile,metersToWorld:metersToWorld,worldUnitsPerPoint:worldUnitsPerPoint)
                SCNTransaction.commit()
            }
            let activeEffects = game.effects.suffix(128)
            let effectIDs = Set(activeEffects.map(\.id))
            for id in Array(effectNodes.keys) where !effectIDs.contains(id) { effectNodes.removeValue(forKey:id)?.removeFromParentNode() }
            for effect in activeEffects {
                let visible = visibleGroundBounds.insetBy(dx:-effect.radius,dy:-effect.radius).contains(effect.position)
                let fresh = effectNodes[effect.id] == nil
                guard visible || !fresh else { continue }
                let node = effectNodes[effect.id] ?? effectModels.makeEffect(effect,metersToWorld:metersToWorld,worldUnitsPerPoint:worldUnitsPerPoint)
                if fresh { effects.addChildNode(node); effectNodes[effect.id] = node }
                node.isHidden = !visible
                SCNTransaction.begin(); SCNTransaction.disableActions = fresh || game.phase != .running
                SCNTransaction.animationDuration = 0.05; SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.linear)
                effectModels.updateEffect(node:node,effect:effect,metersToWorld:metersToWorld,worldUnitsPerPoint:worldUnitsPerPoint)
                SCNTransaction.commit()
            }
            let supportIDs = Set(game.supportAreas.map(\.id))
            for id in Array(supportNodes.keys) where !supportIDs.contains(id) { supportNodes.removeValue(forKey:id)?.removeFromParentNode() }
            for area in game.supportAreas {
                let fresh = supportNodes[area.id] == nil
                let node = supportNodes[area.id] ?? effectModels.makeSupport(area,metersToWorld:metersToWorld)
                if fresh { effects.addChildNode(node); supportNodes[area.id] = node }
                SCNTransaction.begin(); SCNTransaction.disableActions = fresh || game.phase != .running
                SCNTransaction.animationDuration = 0.05; SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.linear)
                effectModels.updateSupport(node:node,area:area,metersToWorld:metersToWorld)
                SCNTransaction.commit()
            }
        }

        /// Static strategy annotations are three batched meshes. Their cache
        /// changes only for new evidence, changed walls, or a meaningful camera
        /// move; a crowd snapshot does not allocate a node for each flag/zone.
        private func updateStrategicOverlays(_ game: GameEngine) {
            let livingWalls = Set(game.units.filter { $0.kind == .barricade && $0.health > 0 }.map(\.id))
            let history = game.tacticalMarkers.suffix(96)
            let width = max(0.001,markerScale)
            let cameraBucket = width*16
            var signature = Hasher()
            for value in [visibleGroundBounds.minX,visibleGroundBounds.minY,visibleGroundBounds.maxX,visibleGroundBounds.maxY] {
                signature.combine(Int(floor(value/cameraBucket)))
            }
            signature.combine(Int((log2(width)*24).rounded()))
            if let district = game.missionBounds {
                signature.combine(district.minX); signature.combine(district.minY)
                signature.combine(district.width); signature.combine(district.height)
            }
            for zone in game.safeZones {
                signature.combine(zone.id)
                for point in zone.points { signature.combine(point.x); signature.combine(point.y) }
                signature.combine(zone.boundaryUnitIDs.allSatisfy { livingWalls.contains($0) })
            }
            for marker in history {
                signature.combine(marker.id); signature.combine(marker.kind.rawValue); signature.combine(marker.count)
                signature.combine(marker.position.x); signature.combine(marker.position.y)
            }
            let value = signature.finalize()
            guard strategicSignature != value else { return }
            strategicSignature = value
            let bounds = visibleGroundBounds.insetBy(dx:-width*16,dy:-width*16)
            var zones = CityMesh(materialCount:safeZoneMaterials.count)
            for zone in game.safeZones {
                let zoneBounds = zone.points.reduce(CGRect.null) { $0.union(CGRect(x:$1.x,y:$1.y,width:0.01,height:0.01)) }
                guard zoneBounds.intersects(bounds) else { continue }
                // Tint the pavement above its paint (0.24–0.27) but below the
                // building base (0.3). Depth testing preserves roofs and trees.
                zones.polygon(zone.points,altitude:0.29,material:0)
                let material = zone.boundaryUnitIDs.allSatisfy { livingWalls.contains($0) } ? 1 : 2
                var closed = zone.points
                if closed.first != closed.last, let first = closed.first { closed.append(first) }
                for (a,b) in zip(closed,closed.dropFirst()) {
                    zones.strip(from:a,to:b,width:max(metersToWorld*0.08,width*0.75),altitude:0.7,material:material)
                }
            }
            safeZoneNode.geometry = zones.vertices.isEmpty ? nil : zones.geometry(materials:safeZoneMaterials)
            var districtMesh = CityMesh()
            if let district = game.missionBounds {
                let points = rectPoints(district)+[CGPoint(x:district.minX,y:district.minY)]
                let dash = max(metersToWorld*2,width*9)
                for (a,b) in zip(points,points.dropFirst()) {
                    let length = hypot(b.x-a.x,b.y-a.y)
                    guard length > 0 else { continue }
                    let spacing = max(dash,length/256)
                    for index in 0..<min(256,Int(ceil(length/spacing))) {
                        let start = min(1,Double(index)*spacing/length), end = min(1,(Double(index)+0.55)*spacing/length)
                        let p = CGPoint(x:a.x+(b.x-a.x)*start,y:a.y+(b.y-a.y)*start)
                        let q = CGPoint(x:a.x+(b.x-a.x)*end,y:a.y+(b.y-a.y)*end)
                        if bounds.contains(p) || bounds.contains(q) {
                            districtMesh.strip(from:p,to:q,width:width*0.6,altitude:0.74)
                        }
                    }
                }
            }
            missionBoundaryNode.geometry = districtMesh.vertices.isEmpty ? nil : districtMesh.geometry(materials:[missionBoundaryMaterial])
            var flags = CityMesh(materialCount:historyMaterials.count)
            for marker in history where bounds.contains(marker.position) {
                let p = marker.position
                let scale = width*(1+min(0.3,Double(marker.count-1)*0.025))
                let height = metersToWorld*1.8
                flags.box(center:SCNVector3(Float(p.x),Float(0.4+height/2),Float(p.y)),width:scale*0.22,height:height,depth:scale*0.22,material:1)
                // A horizontal pennant remains legible from the overhead
                // camera; its small upright fold shows depth in street view.
                flags.polygon([p,CGPoint(x:p.x+scale*2.8,y:p.y-scale*0.5),CGPoint(x:p.x+scale*0.2,y:p.y-scale*1.8)],altitude:0.4+height,material:0)
                flags.triangle(SCNVector3(Float(p.x),Float(0.4+height),Float(p.y)),SCNVector3(Float(p.x+scale*2.4),Float(0.4+height*0.75),Float(p.y)),SCNVector3(Float(p.x),Float(0.4+height*0.55),Float(p.y)),normal:SCNVector3(0,0,1),material:marker.kind == .breach ? 2 : 0)
            }
            tacticalHistoryNode.geometry = flags.vertices.isEmpty ? nil : flags.geometry(materials:historyMaterials)
        }

        private func ring(_ p: CGPoint, radius: Double, width: Double, material: Int, altitude: Double = 0.65, to mesh: inout CityMesh) {
            let count = min(48,max(12,Int(ceil(radius/max(0.001,worldUnitsPerPoint)*0.9))))
            for i in 0..<count {
                let a = Double(i)*Double.pi*2/Double(count), b = Double(i+1)*Double.pi*2/Double(count)
                mesh.strip(from:CGPoint(x:Double(p.x)+cos(a)*radius,y:Double(p.y)+sin(a)*radius),to:CGPoint(x:Double(p.x)+cos(b)*radius,y:Double(p.y)+sin(b)*radius),width:width,altitude:altitude,material:material)
            }
        }
        private func footprint(_ building: MapBuilding) -> [CGPoint] {
            var p = building.footprint.count >= 3 ? building.footprint : rectPoints(building.rect)
            if p.count > 3 && p.first == p.last { p.removeLast() }
            // OSM ways can use either winding. Consistent winding keeps facade
            // normals and window offsets outside, even on concave footprints.
            var area: CGFloat = 0
            for index in p.indices {
                let a = p[index], b = p[(index+1)%p.count]
                area += a.x*b.y-b.x*a.y
            }
            if area < 0 { p.reverse() }
            return p
        }
        private func rectPoints(_ r: CGRect) -> [CGPoint] { [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)] }
    }
}

private struct RenderHumanMotion {
    var position: CGPoint
    var heading: Double
    var stride: Double
    var speed: Double
}

private final class BuildingChunk {
    let node: SCNNode
    let ruins = SCNNode()
    let buildings: [MapBuilding]
    let buildingIDs: [Int]
    let bounds: CGRect
    var detail: SCNNode?
    var wantsDetail = false
    var detailQueued = false
    var wantsBase = false
    var baseQueued = false
    var hasBaseGeometry = false
    var lastVisibleEpoch = 0
    init(node: SCNNode, buildings: [MapBuilding], buildingIDs: [Int], bounds: CGRect) {
        self.node = node; self.buildings = buildings; self.buildingIDs = buildingIDs; self.bounds = bounds
    }
}

@MainActor
private final class LayoutTacticalSCNView: SCNView {
    var onLayout: ((SCNView) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?(self) }
}
