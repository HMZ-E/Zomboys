import SwiftUI

/// SwiftUI controls stay above the native, depth-tested 3D scene.
struct TacticalMapView: View {
    @ObservedObject var game: GameEngine
    @ObservedObject var interaction: TacticalSceneInteraction
    @Binding var drawingPatrol: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var previousZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var previousPan: CGSize = .zero
    @State private var drawingPoints: [CGPoint] = []
    @State private var drawingZonePlan: SafeZonePlan?
    @State private var lastZonePreviewAt: TimeInterval = 0
    @State private var overhead = true
    @State private var cameraFocus: CGPoint?
    @State private var trackingHerdID: Int?
    @State private var picker: MapPicker = .landmarks
    @State private var showingPicker = false
    @State private var pinchWorldAnchor: CGPoint?
    @State private var pinchScreenAnchor: CGPoint?
    private let maximumZoom: CGFloat = 120

    private enum MapPicker { case landmarks, arrivals }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TacticalSceneView(game: game, zoom: zoom, pan: pan, topInset: topInset,
                                  bottomInset: bottomInset, overhead: overhead, focus: cameraFocus, trackingHerdID:trackingHerdID, interaction: interaction)
                    .overlay { drawingPreview.allowsHitTesting(false) }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("3D tactical map of \(game.city.title)")
                    .accessibilityHint("Tap streets to deploy. Draw a Safe Zone or Barrier. Drag to pan and pinch to zoom.")
                    .accessibilityIdentifier("command.map")
                    .accessibilityAction(named: "Deploy at map center") {
                        if let point = interaction.worldPoint(at: usableCenter(in: geometry.size)) {
                            game.tap(at: point, selectionRadius: selectionRadius)
                        }
                    }
                    .gesture(SpatialTapGesture().exclusively(before: DragGesture(minimumDistance: 8))
                        .onChanged { value in
                            if case .second(let drag) = value {
                                if isDrawing {
                                    if drawingPoints.isEmpty, let first = interaction.worldPoint(at: drag.startLocation) { drawingPoints = [first] }
                                    if let point = interaction.worldPoint(at: drag.location), let last = drawingPoints.last,
                                       hypot(last.x - point.x, last.y - point.y) > max(0.12, min(8, interaction.worldUnitsPerPoint * 4)), drawingPoints.count < 200 {
                                        drawingPoints.append(point)
                                        if game.selectedTool == .safeZone, let first = drawingPoints.first {
                                            let now = Date.timeIntervalSinceReferenceDate
                                            if now - lastZonePreviewAt >= 0.05 {
                                                drawingZonePlan = game.safeZonePlan(from: first, to: point)
                                                lastZonePreviewAt = now
                                            }
                                        }
                                    }
                                } else {
                                    if trackingHerdID != nil {
                                        cameraFocus = interaction.worldPoint(at:usableCenter(in:geometry.size))
                                        trackingHerdID = nil; previousPan = .zero
                                    }
                                    pan = CGSize(width: previousPan.width + drag.translation.width, height: previousPan.height + drag.translation.height)
                                }
                            }
                        }.onEnded { value in
                            switch value {
                            case .first(let tap):
                                if !game.phase.isFinished, let point = interaction.worldPoint(at: tap.location) { game.tap(at: point, selectionRadius: selectionRadius) }
                            case .second(let drag):
                                if isDrawing {
                                    if let point = interaction.worldPoint(at: drag.location) { drawingPoints.append(point) }
                                    if drawingPatrol { _ = game.setPatrol(through: drawingPoints); drawingPatrol = false }
                                    else if game.selectedTool == .safeZone, let first = drawingPoints.first, let last = drawingPoints.last { _ = game.drawSafeZone(from: first, to: last) }
                                    else { game.drawBarricade(through: drawingPoints) }
                                    drawingPoints.removeAll(); drawingZonePlan = nil
                                } else { previousPan = pan }
                            }
                            CommandTheme.haptic()
                        })
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        drawingPoints.removeAll(); drawingZonePlan = nil
                        if pinchWorldAnchor == nil {
                            let anchor = CGPoint(x: value.startAnchor.x * geometry.size.width, y: value.startAnchor.y * geometry.size.height)
                            pinchScreenAnchor = anchor
                            pinchWorldAnchor = interaction.worldPoint(at: anchor)
                            trackingHerdID = nil
                        }
                        if let world = pinchWorldAnchor, let anchor = pinchScreenAnchor {
                            cameraFocus = world
                            let center = usableCenter(in: geometry.size)
                            pan = CGSize(width: anchor.x - center.x, height: anchor.y - center.y)
                        }
                        zoom = min(maximumZoom, max(0.03, previousZoom * value.magnification))
                    }.onEnded { _ in
                        previousZoom = zoom; previousPan = pan
                        pinchWorldAnchor = nil; pinchScreenAnchor = nil
                    })
                chrome(in: geometry.size)
            }
            .confirmationDialog(picker == .landmarks ? "\(game.city.title) landmarks" : "Incoming herds",
                                isPresented: $showingPicker, titleVisibility: .visible) {
                if picker == .landmarks {
                    ForEach(Array(game.map.landmarks.enumerated()), id: \.offset) { _, landmark in
                        Button(landmark.name) { focus(on: landmark.position, in: geometry.size) }
                    }
                } else {
                    ForEach(Array(game.arrivals.enumerated()), id: \.element.id) { index, arrival in
                        Button("HERD \(index + 1) · \(arrival.direction) · \(arrival.size) INFECTED · TRACK") {
                            game.selectTool(nil)
                            let members = game.zombies.filter { $0.herdID == arrival.id }
                            let point = members.isEmpty ? arrival.sourcePosition : members[members.count / 2].position
                            focus(on: point, in: geometry.size)
                            trackingHerdID = arrival.id
                        }
                        .accessibilityIdentifier("map.herd.\(index).track")
                        Button("HERD \(index + 1) · CITY ENTRY · " + (arrival.spawned ? "ENTERING" : "ETA \(arrivalTime(arrival.arrivesAt - game.elapsed))")) {
                            game.selectTool(nil)
                            focus(on: arrival.position, in: geometry.size)
                        }
                        .accessibilityIdentifier("map.herd.\(index).entry")
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
            .onAppear { configureProfile(in:geometry.size) }
        }
        .background(CommandTheme.panel)
        .onChange(of: game.missionID) { _, _ in resetCamera() }
        .onChange(of: game.selectedTool) { _, _ in drawingPoints.removeAll(); drawingZonePlan = nil; drawingPatrol = false }
        .onChange(of: game.selectedUnitID) { _, _ in drawingPoints.removeAll(); drawingZonePlan = nil; drawingPatrol = false }
    }
    private var isDrawing: Bool { !game.phase.isFinished && (game.selectedTool == .barricade || game.selectedTool == .safeZone || drawingPatrol) }
    private var drawingPreview: some View {
        Canvas { context, _ in
            let zone = game.selectedTool == .safeZone ? drawingZonePlan : nil
            let plan = drawingPatrol || game.selectedTool == .safeZone ? nil : game.barricadePlan(through: drawingPoints)
            let points = (zone?.points ?? plan?.points ?? drawingPoints).compactMap { interaction.screenPoint(for: $0, height: 2) }
            guard let first = points.first else { return }
            let cost = zone?.cost ?? plan?.cost
            let valid = drawingPatrol || (cost != nil && cost! <= game.budget)
            let tint = valid ? (game.selectedTool == .safeZone || drawingPatrol ? CommandTheme.cyan : .orange) : CommandTheme.red
            let path = Path { p in p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) } }
            if zone != nil { context.fill(path, with: .color(tint.opacity(0.12))) }
            context.stroke(path, with: .color(tint.opacity(0.3)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3]))
            if let end = points.last {
                let label = drawingPatrol ? "PATROL ROUTE" : (zone.map { "$\($0.cost) · \($0.civilianCount) CIVILIANS" } ?? cost.map { "$\($0)" } ?? "DRAW A VALID STREET PERIMETER")
                context.draw(Text(label)
                    .font(CommandTheme.mono(10, weight: .bold)).foregroundStyle(tint), at: CGPoint(x: end.x, y: end.y - 20))
            }
        }
    }
    private func chrome(in size: CGSize) -> some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if game.outbreakMode == .siege { Button {
                        picker = .arrivals; showingPicker = true
                    } label: {
                        Label("HERD APPROACHES", systemImage: "scope").font(CommandTheme.mono(7, weight: .bold))
                            .foregroundStyle(CommandTheme.red).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("map.arrivals") }
                    else {
                        Text(game.phase == .planning ? "OUTBREAK LOCATION UNKNOWN" : "PROTECT THE CIVILIANS")
                            .font(CommandTheme.mono(7, weight: .bold)).foregroundStyle(CommandTheme.lime)
                        Text(game.campaignDistrict.title).font(CommandTheme.mono(7)).foregroundStyle(CommandTheme.muted)
                    }
                    if !game.safeZones.isEmpty {
                        Text("\(game.shelteredCivilianCount) SHELTERED · \(game.safeZones.count) \(game.safeZones.count == 1 ? "ZONE" : "ZONES")")
                            .font(CommandTheme.mono(7, weight: .bold)).foregroundStyle(CommandTheme.cyan)
                            .accessibilityIdentifier("map.sheltered")
                    }
                }.padding(8).background(CommandTheme.background.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                if game.phase == .paused {
                    Text("PAUSED").font(CommandTheme.mono(8, weight: .bold)).foregroundStyle(CommandTheme.lime)
                        .padding(8).background(CommandTheme.background.opacity(0.9)).clipShape(Capsule())
                }
                VStack(spacing: 2) {
                    Text("N").font(CommandTheme.mono(8, weight: .bold))
                    Image(systemName: "location.north.fill").font(.system(size: 13))
                }.padding(7).allowsHitTesting(false)
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        legend("LIVING", color:Color(red:238/255,green:242/255,blue:231/255)); legend("HORDE", color:CommandTheme.lime)
                        if !game.map.landmarks.isEmpty {
                            Button { picker = .landmarks; showingPicker = true } label: {
                                Label("LANDMARKS",systemImage:"building.2.crop.circle")
                                    .font(CommandTheme.mono(7,weight:.bold)).foregroundStyle(CommandTheme.lime)
                                    .fixedSize(horizontal:true,vertical:false)
                                    .frame(minHeight:44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("map.landmarks")
                        }
                    }
                    Text("© OpenStreetMap contributors · estimated heights")
                        .font(CommandTheme.mono(6)).foregroundStyle(CommandTheme.muted).lineLimit(2)
                        .frame(maxWidth:220,alignment:.leading)
                }.padding(8).background(CommandTheme.background.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                Group {
                    if size.width > size.height { HStack(spacing: 1) { cameraControls(in: size) } }
                    else if size.height - topInset - bottomInset < 360 {
                        LazyVGrid(columns: [GridItem(.fixed(33), spacing:1), GridItem(.fixed(33), spacing:1)], spacing:1) {
                            cameraControls(in:size)
                        }.frame(width:67)
                    }
                    else { VStack(spacing: 1) { cameraControls(in: size) } }
                }.background(CommandTheme.background.opacity(0.92)).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }.padding(.horizontal, 12).padding(.top, topInset + 8).padding(.bottom, bottomInset + 10)
    }
    private func cameraControls(in size: CGSize) -> some View {
        Group {
            control("hand.draw", "Move map") { game.selectTool(nil); drawingPatrol = false; drawingPoints.removeAll() }
            control(overhead ? "cube" : "map", "Toggle 3D camera") { overhead.toggle() }
            control("plus", "Zoom in") { changeZoom(1.35, in: size) }
            control("minus", "Zoom out") { changeZoom(1 / 1.35, in: size) }
            control("person.fill.viewfinder", "Street level") {
                cameraFocus = game.selectedUnit?.position
                    ?? game.supportAreas.last(where: { $0.kind == game.selectedSupport })?.position
                    ?? interaction.worldPoint(at:usableCenter(in:size)) ?? game.map.initialFocus
                overhead = false
                zoom = min(maximumZoom, max(10, CGFloat(17 / game.map.metersToWorld)))
                previousZoom = zoom; pan = .zero; previousPan = .zero
            }
            control("globe.europe.africa", "Whole city overview") {
                trackingHerdID = nil
                cameraFocus = CGPoint(x: game.map.worldSize / 2, y: game.map.worldSize / 2)
                let base = max(1300, min(2000, game.map.coreBounds.width))
                let height = max(1, size.height)
                let visibleHeight = max(100, height - topInset - bottomInset - 24)
                let fitX = base * max(100, size.width - 24) / (game.map.worldSize * height)
                let fitY = base * visibleHeight / (game.map.worldSize * (overhead ? 1 : cos(.pi / 6)) * height)
                zoom = max(0.03, min(fitX, fitY) / 1.08); previousZoom = zoom; pan = .zero; previousPan = .zero
            }
            control("scope", "Reset map camera") { resetCamera() }
        }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 4, height: 4); Text(title).font(CommandTheme.mono(7)).fixedSize(horizontal:true,vertical:false) }
    }
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 34, height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
    private var selectionRadius: Double { max(0.5, min(24, Double(interaction.worldUnitsPerPoint) * 16)) }
    private func arrivalTime(_ seconds: Double) -> String {
        let value = Int(ceil(max(0, seconds)))
        return value < 60 ? "\(value)s" : "\(value / 60):\(String(format: "%02d", value % 60))"
    }
    private func usableCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: (topInset + size.height - bottomInset) / 2)
    }
    private func resetCamera() {
        zoom = 1; previousZoom = 1; pan = .zero; previousPan = .zero
        drawingPoints.removeAll(); drawingZonePlan = nil; drawingPatrol = false; cameraFocus = nil
        pinchWorldAnchor = nil; pinchScreenAnchor = nil
        trackingHerdID = nil
    }
    private func changeZoom(_ multiplier: CGFloat, in size: CGSize) {
        if let point = interaction.worldPoint(at: usableCenter(in: size)) { cameraFocus = point }
        pan = .zero; previousPan = .zero
        zoom = min(maximumZoom, max(0.03, zoom * multiplier)); previousZoom = zoom
    }
    private func focus(on point: CGPoint, in size: CGSize) {
        trackingHerdID = nil
        cameraFocus = point
        pan = .zero; previousPan = .zero
        zoom = max(2, zoom); previousZoom = zoom
    }
    private func configureProfile(in size:CGSize) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting-profile") else { return }
        if arguments.contains("--uitesting-view=herd") || arguments.contains("--uitesting-view=herd3d"), let arrival = game.arrivals.first {
            cameraFocus = arrival.sourcePosition; trackingHerdID = arrival.id
            overhead = !arguments.contains("--uitesting-view=herd3d")
            zoom = min(maximumZoom,max(10,CGFloat(24/game.map.metersToWorld))); previousZoom = zoom
        } else if arguments.contains("--uitesting-view=city") {
            cameraFocus = CGPoint(x:game.map.worldSize/2,y:game.map.worldSize/2)
            let base = max(1300,min(2000,game.map.coreBounds.width))
            zoom = max(0.03,min(base*size.width/(game.map.worldSize*size.height),base*max(100,size.height-topInset-bottomInset)/(game.map.worldSize*size.height))/1.08)
            previousZoom = zoom
        }
    }
}
