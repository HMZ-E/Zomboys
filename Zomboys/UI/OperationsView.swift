import SwiftUI

struct OperationsView: View {
    @ObservedObject var game: GameEngine
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: OutbreakMode = .siege
    @State private var selectedDistrict: CampaignDistrict = .neighborhood

    var body: some View {
        SheetShell(eyebrow: "MOROCCO RESPONSE NETWORK", title: "OPERATIONS", close: { dismiss() }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Two cities. One objective.\nKeep the living alive.")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(CommandTheme.muted)
                HStack(spacing: 8) {
                    ForEach(OutbreakMode.allCases) { mode in
                        Button { selectedMode = mode } label: {
                            Text(mode.title).font(CommandTheme.mono(9, weight: .bold))
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .foregroundStyle(selectedMode == mode ? CommandTheme.background : CommandTheme.text)
                                .background(selectedMode == mode ? CommandTheme.lime : CommandTheme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityIdentifier("operations.mode.\(mode.rawValue)")
                    }
                }
                Text(selectedMode.detail).font(.system(size: 12)).foregroundStyle(CommandTheme.muted)
                if selectedMode == .cityOutbreak {
                    HStack(spacing: 6) {
                        ForEach(CampaignDistrict.allCases) { district in
                            Button { selectedDistrict = district } label: {
                                VStack(spacing: 5) {
                                    Text("0\(district.index + 1)").font(CommandTheme.mono(13, weight: .bold))
                                    Text(district.title).font(CommandTheme.mono(7, weight: .semibold))
                                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .foregroundStyle(selectedDistrict == district ? CommandTheme.lime : CommandTheme.muted)
                                    .background(CommandTheme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedDistrict == district ? CommandTheme.lime : CommandTheme.line))
                            }.buttonStyle(.plain).accessibilityIdentifier("operations.stage.\(district.rawValue)")
                        }
                    }
                    Text("Begin with a neighborhood, then expand to the inner districts and whole city. Meet the survival objective to advance with surviving paid defenses. The marked catchment shows where civilians begin; the full city stays active.")
                        .font(.system(size: 11)).foregroundStyle(CommandTheme.muted).lineSpacing(3)
                }
                Button {
                    game.beginOperation(city: game.city, mode: selectedMode, district: selectedDistrict, missionSeed: UInt64.random(in: 1...UInt64.max))
                    dismiss()
                } label: { Label("NEW RANDOM OUTBREAK · " + game.city.title, systemImage: "shuffle") }
                    .buttonStyle(TacticalButton()).accessibilityIdentifier("operations.random")
                    .disabled(selectedMode == .cityOutbreak && !game.isDistrictUnlocked(selectedDistrict, in: game.city))
                VStack(spacing: 12) {
                    ForEach(Array(CityScenario.allCases.enumerated()), id: \.element) { index, city in
                        let unlocked = selectedMode == .siege || game.isDistrictUnlocked(selectedDistrict, in: city)
                        let population = selectedMode == .siege ? city.population : selectedDistrict.population(in: city)
                        let credits = selectedMode == .siege ? city.startingBudget : selectedDistrict.startingBudget(in: city)
                        let best = game.missionBests[CampaignRules.missionKey(city: city, mode: selectedMode, district: selectedDistrict)]
                        Button {
                            game.beginOperation(city: city, mode: selectedMode, district: selectedDistrict, missionSeed: ProcessInfo.processInfo.arguments.contains("--uitesting") ? city.seed : UInt64.random(in: 1...UInt64.max))
                            CommandTheme.haptic(.medium)
                            dismiss()
                        } label: {
                            HStack(spacing: 15) {
                                CityPreview(city: city).frame(width: 108, height: 118).clipped()
                                VStack(alignment: .leading, spacing: 9) {
                                    Eyebrow(text: "SECTOR 0\(index + 1)", color: game.city == city ? CommandTheme.lime : CommandTheme.muted)
                                    Text(city.title).font(.system(size: 19, weight: .black, design: .rounded)).tracking(-0.4)
                                    Text(city.district).font(CommandTheme.mono(8)).foregroundStyle(CommandTheme.muted)
                                    HStack(spacing: 5) {
                                        Circle().fill(CommandTheme.lime).frame(width: 4, height: 4)
                                        Text(!unlocked ? "PREVIOUS STAGE REQUIRED" : (best.map { "BEST \(Int(($0.survivalRate * 100).rounded()))% · \($0.grade.title)" } ?? city.difficulty)).font(CommandTheme.mono(7, weight: .semibold)).tracking(0.4)
                                    }.foregroundStyle(CommandTheme.muted)
                                    Text("\(population) civilians  /  \(credits) credits")
                                        .font(CommandTheme.mono(8)).foregroundStyle(CommandTheme.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: game.city == city ? "checkmark.circle.fill" : "arrow.up.right")
                                    .font(.system(size: 17)).foregroundStyle(game.city == city ? CommandTheme.lime : CommandTheme.muted)
                                    .padding(.trailing, 14)
                            }
                            .foregroundStyle(CommandTheme.text)
                            .background(CommandTheme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(game.city == city ? CommandTheme.lime.opacity(0.5) : CommandTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!unlocked).opacity(unlocked ? 1 : 0.5)
                        .accessibilityIdentifier("operations.city.\(city.rawValue)")
                        .accessibilityLabel("\(city.title), \(city.difficulty). Start operation with \(population) civilians and \(credits) credits")
                    }
                }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "map").font(.system(size: 12)).foregroundStyle(CommandTheme.lime)
                    Text("Settat and Casablanca use offline OpenStreetMap roads and footprints, with estimated building heights and custom landmarks. Every displayed civilian is simulated. Reassign loadout points freely in planning; repeated identical results never grant more power.")
                        .font(.system(size: 11)).foregroundStyle(CommandTheme.muted).lineSpacing(3)
                }.padding(.vertical, 4)
            }
        }
        .onAppear {
            selectedMode = game.outbreakMode
            selectedDistrict = game.outbreakMode == .siege ? .neighborhood : game.campaignDistrict
        }
    }
}

private struct CityPreview: View {
    private let map: CityPreviewGeometry
    init(city: CityScenario) { map = CityPreviewCache.geometry(for: city) }
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x242C22)))
            let scale = max(size.width, size.height) / map.worldSize
            context.translateBy(x: size.width / 2 - map.worldSize / 2 * scale, y: size.height / 2 - map.worldSize / 2 * scale)
            context.scaleBy(x: scale, y: scale)
            for park in map.parks { context.fill(Path(park), with: .color(Color(hex: 0x425037))) }
            for water in map.water {
                let path = Path { p in
                    if let first = water.first { p.move(to: first) }
                    water.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
                }
                context.fill(path, with: .color(Color(hex: 0x33524D)))
            }
            var streets = Path()
            for road in map.roads {
                if let first = road.first { streets.move(to: first) }
                road.dropFirst().forEach { streets.addLine(to: $0) }
            }
            context.stroke(streets, with: .color(Color(hex: 0x151C16)), lineWidth: max(10, 0.65 / scale))
            var blocks = Path()
            for building in map.buildings { blocks.addRect(building) }
            context.fill(blocks, with: .color(Color(hex: 0x666B51)))
            let radius = map.worldSize * 0.035
            context.stroke(Path(ellipseIn: CGRect(x: map.focus.x - radius, y: map.focus.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(CommandTheme.red), style: StrokeStyle(lineWidth: 1.3 / scale, dash: [3 / scale, 2 / scale]))
        }
    }
}

private struct CityPreviewGeometry {
    let worldSize: CGFloat
    let focus: CGPoint
    let roads: [[CGPoint]]
    let buildings: [CGRect]
    let parks: [CGRect]
    let water: [[CGPoint]]
}

@MainActor
private enum CityPreviewCache {
    private static var cached: [CityScenario: CityPreviewGeometry] = [:]
    private struct Snapshot: Decodable {
        struct Road: Decodable { let p: [[Double]] }
        let worldSize: Double, focus: [Double]
        let roads: [Road], buildings: [[Double]], parks: [[Double]], water: [[[Double]]]
    }
    static func geometry(for city: CityScenario) -> CityPreviewGeometry {
        if let existing = cached[city] { return existing }
        let geometry: CityPreviewGeometry
        let resource = city == .settat ? "SettatPreview" : "CasablancaPreview"
        let url = Bundle.main.url(forResource: resource, withExtension: "json")
            ?? Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "Resources")
        if let url, let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            func point(_ p: [Double]) -> CGPoint { CGPoint(x: p[0], y: p[1]) }
            func rect(_ p: [Double]) -> CGRect { CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
            geometry = CityPreviewGeometry(worldSize: snapshot.worldSize, focus: point(snapshot.focus), roads: snapshot.roads.map { $0.p.map(point) },
                                           buildings: snapshot.buildings.map(rect), parks: snapshot.parks.map(rect), water: snapshot.water.map { $0.map(point) })
        } else {
            let extent: CGFloat = city == .settat ? 3200 : 8000
            geometry = CityPreviewGeometry(worldSize: extent, focus: CGPoint(x: extent / 2, y: extent / 2), roads: [], buildings: [], parks: [], water: [])
        }
        cached[city] = geometry
        return geometry
    }
}

struct LoadoutView: View {
    @ObservedObject var game: GameEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(eyebrow: "TASK FORCE SPECIALIZATION", title: "LOADOUT", close: { dismiss() }) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "AVAILABLE UPGRADE POINTS")
                        Text("Build your own defense.")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(CommandTheme.muted)
                    }
                    Spacer()
                    Text(String(format: "%02d", game.upgradePoints))
                        .font(CommandTheme.mono(34, weight: .bold)).foregroundStyle(CommandTheme.lime)
                }
                .padding(18).background(CommandTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Rearrange your points to try another plan. Successful survival improvements unlock up to three points per operation; retries and defeats never grant grinding rewards.")
                    .font(.system(size: 12)).foregroundStyle(CommandTheme.muted).lineSpacing(4)

                Button {
                    if game.respecLoadout() { CommandTheme.haptic(.medium) }
                } label: { Label("REASSIGN ALL POINTS · FREE", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(TacticalButton())
                    .disabled(game.phase != .planning || !game.upgradeLevels.values.contains(where: { $0 > 0 }))
                    .accessibilityIdentifier("loadout.respec")

                ForEach(CampaignRules.upgradeableKinds) { kind in
                    let level = game.upgradeLevels[kind, default: 0]
                    HStack(alignment: .center, spacing: 13) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 22)).foregroundStyle(CommandTheme.lime)
                            .frame(width: 46, height: 54)
                            .background(CommandTheme.lime.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 7) {
                            Text(kind.title).font(CommandTheme.mono(10, weight: .bold)).tracking(0.5)
                            Text(CampaignRules.upgradeDescription(kind)).font(.system(size: 10)).foregroundStyle(CommandTheme.muted)
                            HStack(spacing: 4) {
                                ForEach(0..<3) { index in
                                    RoundedRectangle(cornerRadius: 1).fill(index < level ? CommandTheme.lime : CommandTheme.line).frame(width: 25, height: 3)
                                }
                                Text("LV. \(level)").font(CommandTheme.mono(7)).foregroundStyle(CommandTheme.muted).padding(.leading, 5)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            game.purchaseUpgrade(kind)
                            CommandTheme.haptic(.medium)
                        } label: {
                            Image(systemName: level >= 3 ? "checkmark" : "plus")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(game.upgradePoints > 0 && level < 3 ? CommandTheme.background : CommandTheme.muted)
                                .frame(width: 34, height: 34)
                                .background(game.upgradePoints > 0 && level < 3 ? CommandTheme.lime : CommandTheme.raised)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(game.upgradePoints == 0 || level >= 3 || game.phase != .planning)
                        .accessibilityLabel("Upgrade \(kind.title) for one point. Current level \(level)")
                        .accessibilityIdentifier("upgrade.\(kind.rawValue)")
                    }
                    .padding(13).background(CommandTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(game.phase == .planning ? "Upgrades cost one point per level. Aircraft ammunition and flight duration remain fixed. Reassigning points also updates already placed defenses without repairing their damage. Your choices are saved on this device." : "Return to planning to invest your upgrade points.")
                    .font(.system(size: 11)).foregroundStyle(CommandTheme.muted).lineSpacing(3)
            }
        }
    }
}

struct BriefingView: View {
    @Environment(\.dismiss) private var dismiss
    private let instructions: [(String, String, String)] = [
        ("01", "CHOOSE THE OPERATION", "Exterior Siege keeps the enormous visible columns and randomized city-entry ETAs. City Outbreak conceals an initial infection until you begin. Its three operations expand the actual population from a neighborhood to the inner districts and whole city. The marked catchment only shows starting population; people keep moving and remain simulated outside it."),
        ("02", "PROTECT THE LIVING", "White figures are civilians; green figures are infected. Crowds branch along streets, pursue nearby visible people and compress at bottlenecks. Infection requires sustained contact and incubation. Soldiers can also be bitten and turn: protect their firing positions and pull teams back before the crowd reaches them. Walls and buildings block bites as well as direct fire."),
        ("03", "BUILD A PROTECTED DISTRICT", "Drag Safe Zone around a district to close its street crossings with real, paid walls. The price depends on the required closures. Walls block civilians too. Add a $60 Gate directly to a wall so people can enter in single file while zombies stay blocked. Gates can queue; protect several approaches. Barricade draws individual walls for $40 per section. All walls have finite durability and can be repaired."),
        ("04", "SHAPE THE KILL ZONE", "Squads spread into five separate soldiers and shoot with modest accuracy. Humvees patrol a drawn route or hold a position. Snipers fire slowly and need clear sightlines; tap a building for a rooftop position with height-based reach and price. Mortars arc over buildings. $75 Mines trigger when infected approach; $95 C4 waits for your detonation order. Both can kill civilians and damage buildings."),
        ("05", "GUIDE THE SURVIVORS", "Civilians discover nearby evacuation stations, share directions and follow informed neighbors. People already inside an intact safe zone shelter there; nearby civilians can discover its gates and seek protection. Defend these routes. Evacuation removes people from the danger permanently; shelter keeps them alive inside the city until containment succeeds."),
        ("06", "WATCH THE SKY", "AC-130 orbits its target with switchable 30 mm and 105 mm side fire. Choose a heading for a B-2 four-bomb corridor or A-10 GAU-8 strafe. Each aircraft has three finite sorties, an initial response delay and a rearming interval shown on its card. Explosions can kill civilians and collapse buildings, opening sightlines. Aircraft upgrades improve their weapons; ammunition and flight time stay fixed."),
        ("07", "USE YOUR RESERVES", "Each tactical reserve can be used once per operation. $350 Paratroopers land two squads after three seconds; dropping them into a horde risks infection. $250 gas stuns infected for eight seconds without hurting civilians. $450 fire creates three impacts and burning streets. $200 Call to Arms equips up to twelve nearby residents; they still count toward civilian survival. Every kill earns $12. Under pressure, request the one-time $350 emergency reserve; money never regenerates."),
        ("08", "LEARN. REPLAN. SURVIVE.", "Red loss and breach flags show where a defense failed. Review the field before retrying; retry keeps the same random seed. One additional survivor outweighs every kill and speed bonus in the score. Better successful survival results can unlock up to three finite loadout points per operation; repeated results and defeats grant none. Reassign all invested points for free during planning. Meet each outbreak district's survival objective to expand with surviving paid defenses.")
    ]
    var body: some View {
        SheetShell(eyebrow: "COMMANDER’S FIELD MANUAL", title: "THE BRIEFING", close: { dismiss() }) {
            VStack(alignment: .leading, spacing: 26) {
                Link("Settat & Casablanca map data · © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .font(.system(size: 11)).foregroundStyle(CommandTheme.cyan)
                Text("The city is counting on you.").font(.system(size: 20, weight: .medium)).foregroundStyle(CommandTheme.lime)
                ForEach(instructions, id: \.0) { number, title, body in
                    HStack(alignment: .top, spacing: 16) {
                        Text(number).font(CommandTheme.mono(13, weight: .semibold)).foregroundStyle(CommandTheme.lime).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(title).font(CommandTheme.mono(11, weight: .bold)).tracking(0.7)
                            Text(body).font(.system(size: 13)).foregroundStyle(CommandTheme.muted).lineSpacing(5)
                        }
                    }
                }
                HStack(spacing: 9) {
                    Image(systemName: "hand.draw").foregroundStyle(CommandTheme.lime)
                    Text("Draw with Barrier or Patrol selected. Drag to pan; pinch to zoom. The globe shows the whole city. The cube/map switches 3D and overhead. Use Landmarks to visit Settat or Casablanca’s major sites. Overhead crowds appear as flowing dots. Street Level switches to a tilted close view of people, vehicles and your selected support area.").font(.system(size: 12)).foregroundStyle(CommandTheme.muted)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(CommandTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct SheetShell<Content: View>: View {
    let eyebrow: String
    let title: String
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            CommandTheme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: eyebrow)
                        Text(title).font(.system(size: 29, weight: .black, design: .rounded)).tracking(-0.6)
                    }
                    Spacer()
                    IconButton(symbol: "xmark", label: "Close", action: close).accessibilityIdentifier("sheet.close")
                }.padding(.horizontal, 22).padding(.top, 28)
                ScrollView {
                    content().padding(.horizontal, 22).padding(.bottom, 30)
                }
            }
        }
        .foregroundStyle(CommandTheme.text)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(22)
    }
}
