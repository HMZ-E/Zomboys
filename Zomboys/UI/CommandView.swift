import SwiftUI
import Combine

private enum DeploymentCategory: String, CaseIterable {
    case ground = "GROUND", infrastructure = "STREETS", air = "AIR SUPPORT", support = "TACTICAL"
    var kinds: [UnitKind] {
        switch self {
        case .ground: return [.squad, .humvee, .mortar, .sniper]
        case .infrastructure: return [.safeZone, .barricade, .gate, .evacuation, .mine, .c4]
        case .air: return [.ac130, .b2, .a10]
        case .support: return []
        }
    }
}
private enum CommandSheet: String, Identifiable {
    case operations, loadout, briefing, sound
    var id: String { rawValue }
}

struct CommandView: View {
    @ObservedObject var game: GameEngine
    @State private var category: DeploymentCategory = .ground
    @State private var sheet: CommandSheet?
    @StateObject private var loop = TacticalGameLoop()
    @State private var trayExpanded = true
    @State private var drawingPatrol = false
    @State private var reviewingAfterAction = false
    @StateObject private var mapInteraction = TacticalSceneInteraction()
    @StateObject private var audio = GameAudioController()
    @ObservedObject private var performance = TacticalPerformance.shared

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let dockHeight: CGFloat = trayExpanded ? (landscape ? 125 : (category == .air ? 209 : 185)) : (category == .air ? 144 : 118)
            let collateralHeight: CGFloat = game.buildingDamage.isEmpty && game.landmarkDamage.isEmpty ? 0 : 28
            let reserveHeight: CGFloat = game.emergencyAvailable ? 44 : 0
            ZStack {
                TacticalMapView(game: game, interaction: mapInteraction, drawingPatrol: $drawingPatrol,
                                topInset: geometry.safeAreaInsets.top + (landscape ? 82 : 126),
                                bottomInset: geometry.safeAreaInsets.bottom + dockHeight + collateralHeight + reserveHeight)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    commandHUD(landscape: landscape)
                        .padding(.horizontal, landscape ? 18 : 12)
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                    if !game.buildingDamage.isEmpty || !game.landmarkDamage.isEmpty {
                        Text("\(game.buildingDamage.count + game.landmarkDamage.count) STRUCTURES DAMAGED · \(game.destroyedBuildingIDs.count + game.destroyedLandmarkIDs.count) DESTROYED · \(game.casualties) CIVILIAN CASUALTIES")
                            .font(CommandTheme.mono(7, weight:.bold)).foregroundStyle(CommandTheme.red)
                            .padding(.horizontal,10).padding(.vertical,7)
                            .background(CommandTheme.background.opacity(0.9)).clipShape(Capsule())
                            .accessibilityIdentifier("command.collateral")
                            .padding(.bottom,6)
                    }
                    if game.emergencyAvailable {
                        Button {
                            game.claimEmergencyReserve()
                            CommandTheme.haptic(.medium)
                        } label: {
                            Label("EMERGENCY RESERVE +$350", systemImage: "lifepreserver.fill")
                                .font(CommandTheme.mono(10, weight: .bold)).tracking(0.4)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .foregroundStyle(CommandTheme.background).background(CommandTheme.lime)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("command.emergency.ready")
                        .padding(.bottom, 10)
                    }
                    commandDock(landscape: landscape)
                        .padding(.horizontal, landscape ? 18 : 10)
                        .padding(.bottom, 5)
                }
                .disabled(game.phase.isFinished)
                if game.phase.isFinished && !reviewingAfterAction { resultPanel }
                if game.phase.isFinished && reviewingAfterAction {
                    VStack { Spacer(); Button { reviewingAfterAction = false } label: {
                        Label("RETURN TO DEBRIEF", systemImage: "chart.bar.doc.horizontal")
                            .font(CommandTheme.mono(10, weight: .bold)).padding(14)
                            .foregroundStyle(CommandTheme.background).background(CommandTheme.lime).clipShape(Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("result.return").padding(.bottom, 18) }
                }
            }
        }
        .background(CommandTheme.background)
        .foregroundStyle(CommandTheme.text)
        .sheet(item: $sheet, onDismiss: {
            if game.phase == .planning && game.selectedTool == .squad { category = .ground }
        }) { item in
            switch item {
            case .operations: OperationsView(game: game)
            case .loadout: LoadoutView(game: game)
            case .briefing: BriefingView()
            case .sound: SoundSettingsView(audio: audio)
            }
        }
        .onAppear { loop.attach(game:game,audio:audio,interaction:mapInteraction) }
        .onDisappear { loop.stop(); audio.stop() }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.willResignActiveNotification)) { _ in loop.stop(); audio.stop() }
        .onChange(of:game.phase) { _, _ in loop.synchronize() }
        .onChange(of:game.missionID) { _, _ in reviewingAfterAction = false; loop.synchronize() }
        .onChange(of:performance.framesPerSecond) { _, _ in loop.updateCadence() }

    }

    private func commandHUD(landscape: Bool) -> some View {
        Group {
            if landscape {
                VStack(spacing: 5) {
                    HStack(spacing: 18) { commandIdentity.frame(maxWidth: .infinity); missionMetrics.frame(maxWidth: .infinity) }
                    arrivalStatus
                }
            } else {
                VStack(spacing: 8) { commandIdentity; missionMetrics; arrivalStatus }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, landscape ? 8 : 10)
        .tacticalGlass()
    }
    private var commandIdentity: some View {
        HStack(spacing: 9) {
            Text("Z").font(.system(size: 21, weight: .black, design: .rounded)).italic()
                .foregroundStyle(CommandTheme.background).frame(width: 27, height: 27)
                .background(CommandTheme.lime).clipShape(RoundedRectangle(cornerRadius: 7))
            Button { open(.operations) } label: {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(game.city.title).font(.system(size: 14, weight: .heavy, design: .rounded)).lineLimit(1)
                        Text(game.phase == .planning ? "PLAN YOUR DEFENSE" : game.formattedTime)
                            .font(CommandTheme.mono(7)).tracking(0.8).foregroundStyle(phaseColor)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("command.city")
            .accessibilityLabel("Choose city. Current city \(game.city.title)")
            Spacer(minLength: 0)
            IconButton(symbol: "slider.horizontal.3", label: "Loadout", size: 32) { open(.loadout) }
                .accessibilityIdentifier("command.loadout")
            IconButton(symbol: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Sound settings", size: 28) { open(.sound) }
                .accessibilityIdentifier("command.sound")
            IconButton(symbol: "questionmark", label: "Field manual", size: 28) { open(.briefing) }
                .accessibilityIdentifier("command.help")
        }
    }
    private var missionMetrics: some View {
        HStack(spacing: 0) {
            metric("SURVIVORS", value: "\(game.activeCivilianCount + game.saved)", color: CommandTheme.text)
            divider
            metric("INFECTED", value: "\(game.infectedCount)", color: CommandTheme.lime)
                .accessibilityIdentifier("command.infected")
            divider
            metric("KILLS", value: "\(game.kills)", color: CommandTheme.text)
            divider
            metric("FUNDS · +12/KILL", value: "$\(game.budget)", color: CommandTheme.lime)
        }
    }
    private var arrivalStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path").foregroundStyle(CommandTheme.red)
            if game.outbreakMode == .cityOutbreak {
                Text(game.phase == .planning ? "\(game.campaignDistrict.title.uppercased()) · OUTBREAK LOCATION UNKNOWN" : "\(game.campaignDistrict.title.uppercased()) · CONTAIN THE SPREAD")
                    .foregroundStyle(CommandTheme.text)
                Spacer(minLength: 2)
                Text("SAVE \(Int((game.survivalObjective * 100).rounded()))%+").foregroundStyle(CommandTheme.lime)
            } else if let arrival = game.nextHerdArrival {
                Text("CITY ENTRY · \(arrival.direction.uppercased()) · \(arrivalTime(arrival.arrivesAt - game.elapsed))")
                    .foregroundStyle(CommandTheme.text)
                Spacer(minLength: 2)
                Text("\(arrival.size) INFECTED · \(game.pendingHerdCount) LEFT").foregroundStyle(CommandTheme.muted)
            } else if game.arrivals.contains(where: { $0.releasedCount < $0.size }) {
                Text("COLUMNS STILL ENTERING · HOLD THE PERIMETER").foregroundStyle(CommandTheme.red); Spacer()
            } else { Text("ALL HERDS ARRIVED · CLEAR THE CITY").foregroundStyle(CommandTheme.lime); Spacer() }
        }.font(CommandTheme.mono(7, weight: .bold)).lineLimit(1)
            .accessibilityElement(children: .combine).accessibilityIdentifier("command.arrival")
    }
    private func arrivalTime(_ seconds: Double) -> String {
        let value = Int(ceil(max(0, seconds)))
        return value < 60 ? "\(value)s" : "\(value / 60):\(String(format: "%02d", value % 60))"
    }
    private var phaseColor: Color { game.phase == .running ? CommandTheme.red : CommandTheme.lime }
    private var divider: some View { Rectangle().fill(CommandTheme.line).frame(width: 1, height: 23) }
    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(CommandTheme.mono(7)).tracking(0.6).foregroundStyle(CommandTheme.muted)
            Text(value).font(CommandTheme.mono(16, weight: .semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }

    private func commandDock(landscape: Bool) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ForEach(DeploymentCategory.allCases, id: \.self) { item in
                    Button {
                        category = item
                        if item == .support { game.chooseSupport(.paratroopers) }
                        else { game.selectTool(item.kinds.first) }
                        trayExpanded = true
                        CommandTheme.haptic()
                    } label: {
                        Text(item.rawValue).font(CommandTheme.mono(8, weight: .bold)).tracking(0.6)
                            .foregroundStyle(category == item ? CommandTheme.lime : CommandTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("category.\(item)")
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
                Button { withAnimation(.easeInOut(duration: 0.18)) { trayExpanded.toggle() } } label: {
                    Image(systemName: trayExpanded ? "chevron.compact.down" : "chevron.compact.up")
                        .font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(trayExpanded ? "Collapse deployment tray" : "Expand deployment tray")
                .accessibilityIdentifier("command.tray")
            }
            if landscape {
                HStack(spacing: 14) {
                    if trayExpanded { toolsRow }
                    VStack(spacing: 5) {
                        if category == .air { airControls }
                        selectionHint
                        commandControls
                    }.frame(width: trayExpanded ? 272 : nil)
                }
            } else {
                if trayExpanded { toolsRow }
                if category == .air { airControls }
                selectionHint
                commandControls
            }
        }
        .padding(10)
        .tacticalGlass(cornerRadius: 17)
    }

    private var toolsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if category == .support { ForEach(TacticalSupportKind.allCases) { supportCard($0) } }
                else { ForEach(category.kinds) { kind in unitCard(kind) } }
            }
        }.frame(height: 56)
    }
    private func supportCard(_ kind:TacticalSupportKind) -> some View {
        let selected = game.selectedSupport == kind
        return Button { game.chooseSupport(kind); CommandTheme.haptic() } label: {
            VStack(spacing:3) {
                Label(kind.shortTitle.uppercased(),systemImage:kind.symbol).font(CommandTheme.mono(8,weight:.bold))
                Text(game.supportUsesRemaining(kind) > 0 ? "$\(kind.cost) · 1 USE" : "EXPENDED").font(CommandTheme.mono(7))
            }.frame(width:103,height:54)
                .foregroundStyle(selected ? CommandTheme.lime : CommandTheme.text)
                .background(selected ? CommandTheme.lime.opacity(0.12) : CommandTheme.raised.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius:9))
                .overlay(RoundedRectangle(cornerRadius:9).stroke(selected ? CommandTheme.lime : CommandTheme.line,lineWidth:1))
                .opacity(game.supportUsesRemaining(kind) > 0 && game.budget >= kind.cost ? 1 : 0.45)
        }.buttonStyle(.plain).accessibilityIdentifier("support.\(kind.rawValue)")
            .accessibilityLabel("\(kind.title), \(kind.cost) credits. \(kind.subtitle). \(game.supportUsesRemaining(kind)) use remaining.")
    }
    private func unitCard(_ kind: UnitKind) -> some View {
        let selected = game.selectedTool == kind
        return Button {
            game.selectTool(kind)
            CommandTheme.haptic()
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: kind.symbol).font(.system(size: 12))
                    Text(kind.shortTitle.uppercased()).font(CommandTheme.mono(8, weight: .bold))
                }
                Text(unitCardStatus(kind))
                    .font(CommandTheme.mono(8)).foregroundStyle(selected ? CommandTheme.lime : CommandTheme.muted)
            }
            .frame(width: 80, height: 54)
            .foregroundStyle(selected ? CommandTheme.lime : CommandTheme.text)
            .background(selected ? CommandTheme.lime.opacity(0.12) : CommandTheme.raised.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? CommandTheme.lime.opacity(0.7) : CommandTheme.line, lineWidth: 1))
            .opacity(unitCardReady(kind) ? 1 : 0.45)
        }
        .buttonStyle(.plain).accessibilityIdentifier("tool.\(kind.rawValue)")
        .accessibilityLabel("\(kind.title), \(kind.cost) credits. \(kind.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func unitCardStatus(_ kind: UnitKind) -> String {
        if kind == .safeZone { return "DRAW · PAID WALLS" }
        if kind == .barricade { return "$40 / SECTION" }
        if kind.isAirSupport {
            if game.flights.contains(where: { $0.kind == kind }) { return "ON STATION" }
            if game.sortiesRemaining(kind) == 0 { return "EXPENDED" }
            if game.phase != .planning && game.aircraftReadyIn(kind) > 0 { return "READY IN \(Int(ceil(game.aircraftReadyIn(kind))))s" }
        }
        return "$\(kind.cost)"
    }
    private func unitCardReady(_ kind: UnitKind) -> Bool {
        if kind == .safeZone { return game.budget >= UnitKind.barricade.cost }
        if kind.isAirSupport {
            if game.flights.contains(where: { $0.kind == kind }) { return true }
            return game.canAfford(kind) && game.sortiesRemaining(kind) > 0 && (game.phase == .planning || game.aircraftReadyIn(kind) == 0)
        }
        return game.canAfford(kind)
    }
    private var selectionHint: some View {
        HStack(spacing: 6) {
            if let unit = game.selectedUnit {
                Text("\(unit.kind.shortTitle.uppercased()) · \(Int(unit.health))/\(Int(unit.maxHealth)) HP")
                    .font(CommandTheme.mono(8)).foregroundStyle(unit.kind == .barricade ? .orange : CommandTheme.lime).accessibilityIdentifier("unit.status")
                Spacer(minLength: 0)
                if unit.kind == .humvee {
                    Button(drawingPatrol ? "DRAW ROUTE" : (unit.holding ? "PATROL" : "PATROLLING")) { drawingPatrol.toggle() }.font(CommandTheme.mono(7, weight: .bold)).foregroundStyle(CommandTheme.cyan)
                        .accessibilityLabel(drawingPatrol ? "DRAW ROUTE" : (unit.holding ? "HOLDING · PATROL" : "PATROLLING"))
                        .accessibilityIdentifier("unit.patrol")
                    Button("HOLD") { game.holdSelected(); drawingPatrol = false }.font(CommandTheme.mono(7, weight: .bold)).accessibilityIdentifier("unit.hold")
                }
                if unit.kind == .c4 {
                    Button(unit.cooldown > 0 ? "ARMING \(Int(ceil(unit.cooldown)))s" : "DETONATE") { _ = game.detonateSelectedC4(); CommandTheme.haptic(.heavy) }
                        .font(CommandTheme.mono(8, weight: .bold)).foregroundStyle(CommandTheme.red)
                        .disabled((game.phase != .running && game.phase != .paused) || unit.cooldown > 0).accessibilityIdentifier("unit.detonate")
                }
                if game.selectedRepairCost > 0 {
                    let cost = game.selectedRepairCost
                    Button("REPAIR $\(cost)") { _ = game.repairSelected() }.font(CommandTheme.mono(7, weight: .bold)).foregroundStyle(.orange).accessibilityIdentifier("unit.repair")
                }
                Button { game.removeSelected() } label: {
                    Image(systemName: "trash").font(.system(size: 12)).frame(width: 26, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Remove selected unit")
                    .disabled(unit.kind == .gate && game.phase != .planning)
            } else {
                Text(game.selectedSupport?.subtitle ?? deploymentHint).font(.system(size: 9)).foregroundStyle(CommandTheme.muted).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text("\(game.units.count + game.flights.count) DEPLOYED").font(CommandTheme.mono(7)).foregroundStyle(CommandTheme.muted).fixedSize()
                .accessibilityIdentifier("command.units")
        }.frame(height: 18)
    }

    private var airControls: some View {
        HStack(spacing: 8) {
            if game.selectedTool == .ac130 {
                Button { game.cycleAC130WeaponMode() } label: { Label(game.ac130WeaponMode.title, systemImage: "scope") }
                    .accessibilityIdentifier("air.weapon")
            } else {
                Button { game.cycleAttackHeading() } label: {
                    Label("HEADING \((Int((game.attackHeading * 180 / .pi).rounded()) + 90) % 360)°", systemImage: "arrow.up.right")
                }.accessibilityIdentifier("air.heading")
            }
            Spacer(minLength: 0)
            if let kind = game.selectedTool, kind.isAirSupport {
                Text(game.flights.first(where: { $0.kind == kind }).map {
                    "\($0.ammo) AMMO · \(Int(ceil(max(0, $0.duration - $0.age))))s"
                } ?? (game.aircraftReadyIn(kind) > 0 ? "REARM \(Int(ceil(game.aircraftReadyIn(kind))))s" : "\(game.sortiesRemaining(kind)) SORTIES"))
                    .foregroundStyle(CommandTheme.muted)
            }
        }.font(CommandTheme.mono(8, weight: .bold)).foregroundStyle(CommandTheme.lime).buttonStyle(.plain).frame(height: 20)
    }
    private var commandControls: some View {
        HStack(spacing: 7) {
            Button {
                if game.phase == .planning { game.start() } else { game.togglePause() }
                CommandTheme.haptic(.medium)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: game.phase == .running ? "pause.fill" : "play.fill").font(.system(size: 9))
                    Text(game.phase == .planning ? "BEGIN CONTAINMENT" : (game.phase == .paused ? "RESUME" : "PAUSE"))
                        .font(CommandTheme.mono(9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .buttonStyle(TacticalButton(primary: game.phase != .running, height: 38))
            .accessibilityIdentifier(game.phase == .planning ? "command.start" : (game.phase == .paused ? "command.resume" : "command.pause"))
            if game.phase != .planning {
                Button { game.setSpeed() } label: {
                    Text("\(Int(game.speed))×").font(CommandTheme.mono(11, weight: .bold)).frame(width: 34, height: 38)
                        .background(CommandTheme.raised).clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityIdentifier("command.speed")
                .accessibilityLabel("Simulation speed \(Int(game.speed)) times")
                Button { game.claimEmergencyReserve(); CommandTheme.haptic(.medium) } label: {
                    Image(systemName: game.emergencyUsed ? "checkmark" : "lifepreserver.fill")
                        .font(.system(size: 15)).foregroundStyle(game.emergencyAvailable ? CommandTheme.lime : CommandTheme.muted)
                        .frame(width: 38, height: 38).background(CommandTheme.raised).clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityIdentifier("command.emergency")
                .accessibilityLabel(game.emergencyUsed ? "Emergency reserve used" : "Request 350 credit emergency reserve")
            }
            Button { restart() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 13)).frame(width: 38, height: 38)
                    .background(CommandTheme.raised).clipShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).accessibilityLabel("Restart scenario").accessibilityIdentifier("command.restart")
        }
    }

    private var resultPanel: some View {
        GeometryReader { geometry in
          ZStack {
            CommandTheme.background.opacity(0.86).ignoresSafeArea()
            ScrollView {
              VStack(spacing: 22) {
                Image(systemName: game.phase == .won ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(game.phase == .won ? CommandTheme.lime : CommandTheme.red)
                VStack(spacing: 9) {
                    Eyebrow(text: "MISSION DEBRIEF")
                    Text(game.phase == .won ? "OUTBREAK\nCONTAINED" : "PERIMETER\nLOST")
                        .font(.system(size: 32, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                    Text(game.phase == .won ? "\(game.resultGrade.title) · Civilian survival comes first." : "Review the red flags, then adjust your plan.")
                        .font(.system(size: 13)).foregroundStyle(CommandTheme.muted)
                }
                HStack {
                    resultMetric("SURVIVAL", value: "\(Int((game.survivalRate * 100).rounded()))%", color: CommandTheme.lime)
                    resultMetric("RESCUED", value: "\(game.saved)", color: CommandTheme.cyan)
                    resultMetric("SCORE", value: "\(game.resultScore)", color: CommandTheme.text)
                }
                Text("\(game.kills) infected eliminated  ·  \(game.casualties) civilian casualties")
                    .font(CommandTheme.mono(9)).foregroundStyle(CommandTheme.muted)
                if let best = game.bestMissionResult {
                    Text("BEST \(Int((best.survivalRate * 100).rounded()))% · \(best.grade.title.uppercased())" + (game.lastProgressReward > 0 ? " · +\(game.lastProgressReward) LOADOUT" : ""))
                        .font(CommandTheme.mono(9, weight: .bold)).foregroundStyle(CommandTheme.lime)
                }
                VStack(spacing: 9) {
                    if game.canContinueCampaign {
                        Button { _ = game.continueCampaign(); category = .ground } label: { Text("EXPAND TO NEXT DISTRICT") }
                            .buttonStyle(TacticalButton(primary: true)).accessibilityIdentifier("result.continue")
                    }
                    Button { restart() } label: { Text("RETRY OPERATION") }
                        .buttonStyle(TacticalButton(primary: true)).accessibilityIdentifier("result.retry")
                    Button { reviewingAfterAction = true } label: { Text("REVIEW BREACHES ON MAP") }
                        .buttonStyle(TacticalButton()).accessibilityIdentifier("result.review")
                    Button { open(.operations) } label: { Text("CHOOSE OPERATION") }
                        .buttonStyle(TacticalButton()).accessibilityIdentifier("result.operations")
                }
            }
            .padding(28)
            .frame(maxWidth: 400)
            .background(CommandTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(CommandTheme.line, lineWidth: 1))
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
          }
        }
    }

    private func resultMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 7) {
            Text(value).font(CommandTheme.mono(24, weight: .bold)).foregroundStyle(color)
            Eyebrow(text: title)
        }.frame(maxWidth: .infinity)
    }

    private func open(_ item: CommandSheet) {
        if game.phase == .running { game.togglePause() }
        sheet = item
    }
    private var deploymentHint: String {
        if game.selectedTool == .safeZone { return "Drag around a district · price covers street closures · gates sold separately" }
        if game.selectedTool == .gate { return "Tap an intact barrier · civilians pass one at a time · infected stay outside" }
        if game.selectedTool == .mine { return "Tap a street · triggers near infected · blast can harm civilians" }
        if game.selectedTool == .c4 { return "Place on a street · select the charge and DETONATE · civilian risk" }
        if game.selectedTool == .barricade { return "Draw a street line · $40 per section · up to five sections" }
        if drawingPatrol { return "Draw a patrol route on streets · tap HOLD to stop" }
        if let kind = game.selectedTool, kind.isAirSupport {
            if game.phase == .planning { return "Air support launches after containment begins" }
            if game.aircraftReadyIn(kind) > 0 && !game.flights.contains(where: { $0.kind == kind }) { return "Rearming · \(Int(ceil(game.aircraftReadyIn(kind))))s" }
            if kind == .ac130 {
                return game.flights.contains(where: { $0.kind == .ac130 }) ? "Tap to redirect the orbit · switch cannon above" : "Tap an orbit center · \(game.ac130WeaponMode.title) side fire"
            }
            return "Tap the strike center · set heading before launch"
        }
        if !game.notice.isEmpty { return game.notice }
        return game.selectedTool?.subtitle ?? "Tap a unit to reposition · +$12 per kill"
    }
    private func restart() {
        game.reset(city: game.city)
        category = .ground

        CommandTheme.haptic(.medium)
    }
}
