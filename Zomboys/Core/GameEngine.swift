import Foundation
import Combine

/// The map and every actor share an expanded city world, independent of screen size.
/// Street AI uses short simulation steps; the renderer interpolates at display
/// cadence and the HUD receives separate, throttled publication.
@MainActor
final class GameEngine: ObservableObject {
    @Published var revision = 0
    private(set) var missionID = UUID()
    private(set) var missionSeed: UInt64
    private(set) var arrivals: [HerdArrival] = []
    private(set) var stagedHerdMembers: [StagedHerdMember] = []
    private(set) var stagingRevision = 0
    private(set) var buildingDamage: [Int: Double] = [:]
    private(set) var landmarkDamage: [Int: Double] = [:]
    private(set) var destroyedBuildingIDs: Set<Int> = []
    private(set) var destroyedLandmarkIDs: Set<Int> = []
    private(set) var destructionRevision = 0
    private(set) var herdRouteRevision = 0
    private(set) var herdConnectionSearches = 0
    /// Counts actual physics passes for frame-jitter and CPU profiling checks.
    private(set) var simulationStepCount = 0
    /// Non-published: rendering observes simulation changes without invalidating
    /// the entire SwiftUI command interface at display cadence.
    private(set) var simulationRevision = 0
    /// Advances only when a complete presentation group is ready. HUD updates
    /// between accelerated physics steps must not expose half-built motion.
    private(set) var renderRevision = 0
    private(set) var previousRenderElapsed: Double = 0
    private(set) var renderSimulationInterval: Double = 0
    private var previousRenderMotion: [Int: RenderMotionState] = [:]
    private var previousUnitFormations: [Int: [CGPoint]] = [:]
    private var metersToWorld = 1.0
    /// Exterior tails stay visible without running several thousand extra AIs.
    let activeZombieLimit = 1_400
    private(set) var projectiles: [CombatProjectile] = []
    private(set) var flights: [AircraftFlight] = []
    private(set) var audioEvents: [GameAudioEvent] = []
    private(set) var attackHeading: Double = 0
    private(set) var ac130WeaponMode: AirWeaponMode = .cannon30
    var nextHerdArrival: HerdArrival? { arrivals.filter { !$0.spawned }.min { $0.arrivesAt < $1.arrivesAt } }
    var pendingHerdCount: Int { arrivals.filter { !$0.spawned }.count }

    private(set) var phase: GamePhase = .planning
    private(set) var city: CityScenario
    private(set) var map: CityMap
    private(set) var budget = 0
    private(set) var civilians: [Civilian] = []
    private(set) var zombies: [Zombie] = []
    private(set) var units: [DefenseUnit] = []
    private(set) var effects: [CombatEffect] = []
    private(set) var infectionOrigins: [CGPoint] = []
    private(set) var selectedUnitID: Int?
    private(set) var selectedTool: UnitKind? = .squad
    private(set) var selectedSupport: TacticalSupportKind?
    private(set) var supportAreas: [SupportAreaState] = []
    private(set) var safeZones: [SafeZone] = []
    private(set) var tacticalMarkers: [TacticalMarker] = []
    private var troopExposure: [Int: Double] = [:]
    private var gatePasses: [Int: (gateID: Int, expires: Double)] = [:]
    private var nextGatePassAt: [Int: Double] = [:]
    private var civilianKnownZones: [Int: Int] = [:]
    private var defenseTargetIDs: [Int: Int] = [:]
    private var defenseSearchOffsets: [Int: Int] = [:]
    private var supportUses: [TacticalSupportKind: Int] = [:]
    private var recruitedCivilians: [Int: [Civilian]] = [:]
    private var supportAutoUnits: Set<Int> = []
    private var nextSupportOrderAt: Double = 0
    private var stunnedZombieIDs: Set<Int> = []
    /// Armed residents remain part of the civilian survival objective. They are
    /// neither counted as evacuated nor silently removed from the population.
    var mobilizedCivilianCount: Int { recruitedCivilians.values.reduce(0) { $0 + $1.count } }
    private(set) var elapsed: Double = 0
    private(set) var speed: Double = 1
    private(set) var saved = 0
    private(set) var casualties = 0
    private(set) var kills = 0
    private(set) var earnedMoney = 0
    private(set) var emergencyUsed = false
    var emergencyAvailable: Bool {
        !emergencyUsed && (phase == .running || phase == .paused) && elapsed >= 20 &&
        (budget <= 240 || casualties >= initialPopulation * 18 / 100 || zombies.count >= initialInfected * 3)
    }
    private(set) var initialPopulation = 0
    private(set) var notice = ""
    private(set) var upgradePoints = 3
    private(set) var upgradeLevels: [UnitKind: Int] = [:]
    private(set) var completedCities: Set<CityScenario> = []
    private(set) var outbreakMode: OutbreakMode = .siege
    private(set) var campaignDistrict: CampaignDistrict = .citywide
    private(set) var missionBests: [String: MissionBest] = [:]
    private(set) var lastProgressReward = 0
    var missionBounds: CGRect? { outbreakMode == .cityOutbreak ? campaignDistrict.catchment(in: map) : nil }
    var missionTitle: String { outbreakMode == .siege ? "EXTERIOR SIEGE" : campaignDistrict.title + " OUTBREAK" }
    var survivalObjective: Double { outbreakMode == .siege ? 0.50 : campaignDistrict.survivalObjective }
    var currentMissionKey: String { CampaignRules.missionKey(city: city, mode: outbreakMode, district: campaignDistrict) }
    var bestMissionResult: MissionBest? { missionBests[currentMissionKey] }
    var resultGrade: SurvivalGrade { SurvivalGrade.grade(survival: survivalRate, objective: survivalObjective, won: phase == .won) }
    var canContinueCampaign: Bool {
        outbreakMode == .cityOutbreak && phase == .won && survivalRate >= survivalObjective && campaignDistrict.next != nil
    }

    /// Sorties have an initial response window, finite inventory, and rearming time.
    func aircraftReadyIn(_ kind: UnitKind) -> Double {
        guard kind.isAirSupport else { return 0 }
        return max(0, 18 - elapsed, nextSortieAt[kind, default: 0] - elapsed)
    }
    func sortiesRemaining(_ kind: UnitKind) -> Int { max(0, 3 - sortieCounts[kind, default: 0]) }
    var airstrikeReadyIn: Double { aircraftReadyIn(.b2) }

    private struct Motion {
        var waypoints: [CGPoint]
        var index: Int = 0
        var reconsiderAt: Double = 0
        var destination: CGPoint
    }

    private struct GridCell: Hashable { let x: Int; let y: Int }
    private let gridSize = 80.0
    private var zombieCellSize: Double { max(0.5, metersToWorld * 3) }
    private var nextHerdReleaseAt: Double = 0
    private var stagedColumns: [Int: [StagedHerdMember]] = [:]
    private var stagedDamage: [Int: Double] = [:]
    private var neutralizedStagedIDs: Set<Int> = []
    private var pendingInfections: [Int: Zombie] = [:]
    private var civilianGrid: [GridCell: [Int]] = [:]
    private var zombieGrid: [GridCell: [Int]] = [:]
    private var flockGrid: [GridCell: [Int]] = [:]
    private var random: SeededRandom
    private var nextID = 1
    private var civilianMotion: [Int: Motion] = [:]
    private var civilianRoutePositions: [Int: CGPoint] = [:]
    private var civilianLanes: [Int: Double] = [:]
    private var civilianForwardSpeeds: [Int: Double] = [:]
    private var zombieForwardSpeeds: [Int: Double] = [:]
    private var civilianRejoinCenters: [Int: CGPoint] = [:]
    private var civilianLaneRecoveryUntil: [Int: Double] = [:]
    private struct PerceivedThreat { var position: CGPoint }
    private var civilianThreats: [Int: PerceivedThreat] = [:]
    private var civilianThreatChecks: [Int: Double] = [:]
    private var civilianDetourChecks: [Int: Double] = [:]
    private var zombieMotion: [Int: Motion] = [:]
    private struct LocalPursuit { var civilianID: Int; var position: CGPoint }
    private var zombiePursuits: [Int: LocalPursuit] = [:]
    private var zombiePerceptionChecks: [Int: Double] = [:]
    private var unitMotion: [Int: Motion] = [:]
    private struct HerdState {
        var center: CGPoint
        var destination: CGPoint
        var reconsiderAt: Double
        var route: [CGPoint]
    }
    private var herds: [Int: HerdState] = [:]
    private var zombieRoutePositions: [Int: CGPoint] = [:]
    private var zombieLanes: [Int: Double] = [:]
    /// A blocked personal lane contracts to its current physical route center
    /// before attempting the next turn. The graph cursor waits for the body.
    private var zombieRejoinCenters: [Int: CGPoint] = [:]
    private var zombieLaneRecoveryUntil: [Int: Double] = [:]
    private var zombieHeadings: [Int: Double] = [:]
    private var squadFireIndex: [Int: Int] = [:]
    private var flightFireAt: [Int: Double] = [:]
    private var flightBombsReleased: [Int: Int] = [:]
    private var nextSortieAt: [UnitKind: Double] = [:]
    private var sortieCounts: [UnitKind: Int] = [:]
    private struct SoundKey: Hashable { let cue: AudioCue; let sourceID: Int? }
    private var lastSoundAt: [SoundKey: Double] = [:]
    private var deploymentVariants: [UnitKind: Int] = [:]
    private var arrivalRoutes: [Int: [CGPoint]] = [:]
    private var civilianLearnedAt: [Int: Double] = [:]
    private var civilianInformAt: [Int: Double] = [:]
    private var civilianSeeingStation: [Int: (stationID: Int, since: Double)] = [:]
    private var nextSocialUpdate: Double = 0
    private var warnedArrivals: Set<Int> = []
    private var herdPopulationTotal = 0
    private var evacuationProgress: [Int: Double] = [:]
    private var adjacency: [[Int]] = []
    private var coreSpawnEdges: [NavigationEdge] = []
    private var initialInfected = 0
    private var noticeUntil: Double = .infinity
    private var rewardPaid = false
    private let defaults: UserDefaults?
    private let progressionKey = "zomboys.progression.v1"

    init(city: CityScenario = .settat, defaults: UserDefaults? = .standard, missionSeed: UInt64? = nil) {
        self.city = city
        self.map = CityMap(city: city)
        self.missionSeed = missionSeed ?? city.seed
        self.random = SeededRandom(seed: missionSeed ?? city.seed)
        self.defaults = defaults
        metersToWorld = map.metersToWorld
        readProgression()
        reset(city: city)
    }

    var activeCivilianCount: Int { phase.isFinished ? 0 : civilians.count + mobilizedCivilianCount }
    var infectedCount: Int { zombies.count }
    var survivalRate: Double {
        guard initialPopulation > 0 else { return 0 }
        return Double(saved + (phase == .won ? 0 : civilians.count + mobilizedCivilianCount)) / Double(initialPopulation)
    }
    var resultScore: Int {
        let survivors = phase == .won ? saved : saved + civilians.count + mobilizedCivilianCount
        return CampaignRules.score(survivors: survivors, kills: kills, elapsed: elapsed, won: phase == .won)
    }
    var phaseLabel: String {
        switch phase {
        case .planning: return "PLAN YOUR DEFENSE"
        case .running: return "OUTBREAK ACTIVE"
        case .paused: return "OPERATION PAUSED"
        case .won: return "CITY SECURED"
        case .lost: return "CONTAINMENT LOST"
        }
    }
    var formattedTime: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    var selectedUnit: DefenseUnit? { units.first { $0.id == selectedUnitID } }

    func reset(city: CityScenario, missionSeed newSeed: UInt64? = nil) {
        missionID = UUID()
        if self.city != city {
            missionSeed = city.seed
            self.city = city
            map = CityMap(city: city)
            metersToWorld = map.metersToWorld
        }
        if let newSeed { missionSeed = newSeed }
        random = SeededRandom(seed: missionSeed)
        phase = .planning
        budget = outbreakMode == .siege ? city.startingBudget : campaignDistrict.startingBudget(in: city)
        initialPopulation = outbreakMode == .siege ? city.population : campaignDistrict.population(in: city)
        lastProgressReward = 0
        elapsed = 0
        simulationStepCount = 0
        simulationRevision = 0
        previousRenderElapsed = 0
        renderSimulationInterval = 0
        previousRenderMotion.removeAll(keepingCapacity: true)
        previousUnitFormations.removeAll(keepingCapacity: true)
        speed = 1
        saved = 0
        casualties = 0
        kills = 0
        earnedMoney = 0
        emergencyUsed = false
        nextID = 1
        rewardPaid = false
        nextSortieAt.removeAll(keepingCapacity: true)
        sortieCounts.removeAll(keepingCapacity: true)
        warnedArrivals.removeAll(keepingCapacity: true)
        lastSoundAt.removeAll(keepingCapacity: true)
        deploymentVariants.removeAll(keepingCapacity: true)
        arrivalRoutes.removeAll(keepingCapacity: true)
        civilianLearnedAt.removeAll(keepingCapacity: true)
        civilianInformAt.removeAll(keepingCapacity: true)
        civilianSeeingStation.removeAll(keepingCapacity: true)
        nextSocialUpdate = 0
        selectedUnitID = nil
        selectedTool = .squad
        selectedSupport = nil
        supportAreas.removeAll(keepingCapacity: true)
        supportUses.removeAll(keepingCapacity: true)
        recruitedCivilians.removeAll(keepingCapacity: true)
        supportAutoUnits.removeAll(keepingCapacity: true)
        stunnedZombieIDs.removeAll(keepingCapacity: true)
        nextSupportOrderAt = 0
        units.removeAll(keepingCapacity: true)
        safeZones.removeAll(keepingCapacity: true)
        tacticalMarkers.removeAll(keepingCapacity: true)
        troopExposure.removeAll(keepingCapacity: true)
        gatePasses.removeAll(keepingCapacity: true)
        nextGatePassAt.removeAll(keepingCapacity: true)
        civilianKnownZones.removeAll(keepingCapacity: true)
        defenseTargetIDs.removeAll(keepingCapacity: true)
        defenseSearchOffsets.removeAll(keepingCapacity: true)
        effects.removeAll(keepingCapacity: true)
        civilianMotion.removeAll(keepingCapacity: true)
        civilianRoutePositions.removeAll(keepingCapacity: true)
        civilianLanes.removeAll(keepingCapacity: true)
        civilianForwardSpeeds.removeAll(keepingCapacity: true)
        zombieForwardSpeeds.removeAll(keepingCapacity: true)
        civilianRejoinCenters.removeAll(keepingCapacity: true)
        civilianLaneRecoveryUntil.removeAll(keepingCapacity: true)
        civilianThreats.removeAll(keepingCapacity: true)
        civilianThreatChecks.removeAll(keepingCapacity: true)
        civilianDetourChecks.removeAll(keepingCapacity: true)
        zombieMotion.removeAll(keepingCapacity: true)
        zombiePursuits.removeAll(keepingCapacity: true)
        zombiePerceptionChecks.removeAll(keepingCapacity: true)
        unitMotion.removeAll(keepingCapacity: true)
        herds.removeAll(keepingCapacity: true)
        zombieRoutePositions.removeAll(keepingCapacity: true)
        zombieLanes.removeAll(keepingCapacity: true)
        zombieRejoinCenters.removeAll(keepingCapacity: true)
        zombieLaneRecoveryUntil.removeAll(keepingCapacity: true)
        zombieHeadings.removeAll(keepingCapacity: true)
        squadFireIndex.removeAll(keepingCapacity: true)
        flightFireAt.removeAll(keepingCapacity: true)
        flightBombsReleased.removeAll(keepingCapacity: true)
        arrivals.removeAll(keepingCapacity: true)
        stagedHerdMembers.removeAll(keepingCapacity: true)
        stagedColumns.removeAll(keepingCapacity: true)
        stagedDamage.removeAll(keepingCapacity: true)
        neutralizedStagedIDs.removeAll(keepingCapacity: true)
        pendingInfections.removeAll(keepingCapacity: true)
        nextHerdReleaseAt = 0
        stagingRevision += 1
        buildingDamage.removeAll(keepingCapacity: true)
        landmarkDamage.removeAll(keepingCapacity: true)
        destroyedBuildingIDs.removeAll(keepingCapacity: true)
        destroyedLandmarkIDs.removeAll(keepingCapacity: true)
        destructionRevision += 1
        herdRouteRevision = 0
        herdConnectionSearches = 0
        projectiles.removeAll(keepingCapacity: true)
        flights.removeAll(keepingCapacity: true)
        audioEvents.removeAll(keepingCapacity: true)
        evacuationProgress.removeAll(keepingCapacity: true)
        civilianGrid.removeAll(keepingCapacity: true)
        zombieGrid.removeAll(keepingCapacity: true)
        flockGrid.removeAll(keepingCapacity: true)
        adjacency = Array(repeating: [], count: map.navigationNodes.count)
        for edge in map.navigationEdges {
            guard adjacency.indices.contains(edge.from), adjacency.indices.contains(edge.to) else { continue }
            if !adjacency[edge.from].contains(edge.to) { adjacency[edge.from].append(edge.to) }
            if !adjacency[edge.to].contains(edge.from) { adjacency[edge.to].append(edge.from) }
        }
        coreSpawnEdges = map.navigationEdges.filter { edge in
            let a = map.navigationNodes[edge.from], b = map.navigationNodes[edge.to]
            let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if let bounds = missionBounds { return bounds.contains(a) && bounds.contains(b) }
            return map.coreBounds.contains(midpoint)
        }
        if outbreakMode == .siege {
            makeArrivalSchedule()
            assembleExteriorColumns()
        }
        infectionOrigins = arrivals.map(\.position)
        civilians = (0..<initialPopulation).map { _ in
            var position = randomStreetPoint()
            for _ in 0..<12 where infectionOrigins.contains(where: { distance(position, $0) < 100 }) {
                position = randomStreetPoint()
            }
            return Civilian(id: allocateID(), position: position)
        }
        zombies = []
        initialInfected = outbreakMode == .siege ? (arrivals.first?.size ?? 1) : campaignDistrict.initialInfected
        setNotice(outbreakMode == .siege ? "Incoming herds marked in red. Fortify streets, then begin the countdown." : "Unknown outbreak location. Protect the district before infection begins. Save \(Int(survivalObjective * 100))% to unlock the next operation.", duration: .infinity)
        publish()
    }

    func start() {
        guard phase == .planning else { return }
        if outbreakMode == .cityOutbreak { seedCityOutbreak() }
        phase = .running
        setNotice(outbreakMode == .siege ? "Recon is tracking incoming herds. Protect civilians before the first arrival." : "Infection confirmed inside the city. Contain the first cluster and protect evacuation routes.", duration: 6)
        publish()
    }

    func togglePause() {
        if phase == .running {
            phase = .paused
        } else if phase == .paused {
            phase = .running
        } else {
            return
        }
        publish()
    }

    func setSpeed(_ newSpeed: Double) {
        speed = min(3, max(1, newSpeed.rounded()))
        publish()
    }

    func setSpeed() { setSpeed(speed >= 3 ? 1 : speed + 1) }

    func selectTool(_ tool: UnitKind?) {
        selectedTool = tool
        selectedSupport = nil
        selectedUnitID = nil
        publish()
    }

    func chooseSupport(_ kind: TacticalSupportKind?) {
        selectedSupport = kind
        selectedTool = nil
        selectedUnitID = nil
        publish()
    }

    func supportUsesRemaining(_ kind: TacticalSupportKind) -> Int { max(0, 1 - supportUses[kind, default: 0]) }

    /// The renderer uses the actual number of armed residents in a partial
    /// team. Regular rifle squads and airborne squads still contain five.
    func crewCount(for unitID: Int) -> Int {
        if let civilians = recruitedCivilians[unitID] { return civilians.count }
        guard let unit = units.first(where: { $0.id == unitID }) else { return 0 }
        return unit.crewRemaining ?? (unit.kind == .squad ? 5 : ((unit.kind == .sniper || unit.kind == .mortar) ? 2 : 0))
    }

    @discardableResult
    func performSupport(_ kind: TacticalSupportKind, at requested: CGPoint) -> Bool {
        func reject(_ message: String) -> Bool {
            setNotice(message, duration: 5); publish(); return false
        }
        guard phase == .running || phase == .paused else { return reject("Tactical support is available after the operation begins.") }
        guard requested.x.isFinite, requested.y.isFinite else { return false }
        guard supportUsesRemaining(kind) > 0 else { return reject("\(kind.shortTitle) reserve already used this operation.") }
        guard budget >= kind.cost else { return reject("\(kind.shortTitle) requires $\(kind.cost).") }
        let target = clamped(requested)
        let radius = metersToWorld * kind.radiusMeters
        if kind == .paratroopers, map.containsWater(target) && !map.isRoad(target) {
            return reject("Choose a street or open land for the airborne drop.")
        }
        let recruits = kind == .callToArms ? Array(civilians.filter {
            distance($0.position, target) <= radius && hasLineOfSight(from: target, to: $0.position)
        }.sorted { squaredDistance($0.position, target) < squaredDistance($1.position, target) }.prefix(12)) : []
        if kind == .callToArms, recruits.isEmpty { return reject("Call to arms needs civilians within 150 metres with a clear sightline.") }
        budget -= kind.cost
        supportUses[kind, default: 0] += 1
        switch kind {
        case .paratroopers:
            let landing = map.nearestRoadPoint(to: target)
            supportAreas.append(SupportAreaState(id: allocateID(), kind: kind, position: landing,
                                                radius: radius, lifetime: kind.duration))
            emitAudio(.aircraftApproach, at: landing, volume: 0.65)
            setNotice("Airborne reserve inbound. Two squads land in 3 seconds and seek the horde.", duration: 5)
        case .gasBomb:
            supportAreas.append(SupportAreaState(id: allocateID(), kind: kind, position: target,
                                                radius: radius, lifetime: kind.duration))
            emitAudio(.bombRelease, at: target, volume: 0.45)
            setNotice("Stun cloud active for 8 seconds. Civilians remain safe inside it.", duration: 5)
        case .fireBomb:
            for offset in [-22.0, 0, 22] {
                let point = clamped(CGPoint(x: target.x + cos(attackHeading) * metersToWorld * offset,
                                           y: target.y + sin(attackHeading) * metersToWorld * offset))
                supportAreas.append(SupportAreaState(id: allocateID(), kind: kind, position: point,
                                                    radius: radius, lifetime: kind.duration, nextPulseAt: 0.5))
                applyExplosion(at: point, radius: radius, damage: 140, civilianRadius: radius * 0.85)
            }
            setNotice("Three incendiary impacts. Streets burn for 10 seconds — keep civilians and teams clear.", duration: 6)
        case .callToArms:
            let recruitedIDs = Set(recruits.map(\.id))
            civilians.removeAll { recruitedIDs.contains($0.id) }
            for civilian in recruits {
                civilianMotion[civilian.id] = nil
                let id = allocateID()
                // Each resident arms where they stand, rather than teleporting
                // distant people into an invented full-sized rifle formation.
                let health = upgradedHealth(.squad) / 5
                units.append(DefenseUnit(id: id, kind: .squad, position: civilian.position, targetPosition: nil,
                                         health: health, maxHealth: health, range: upgradedRange(.squad) * 0.65,
                                         cooldown: 0, purchaseCost: max(1, kind.cost / recruits.count),
                                         soundVariant: deploymentVariants[.squad, default: 0] % 4))
                deploymentVariants[.squad, default: 0] += 1
                recruitedCivilians[id] = [civilian]
                updateFormation(at: units.count - 1)
            }
            supportAreas.append(SupportAreaState(id: allocateID(), kind: kind, position: target,
                                                radius: radius, lifetime: kind.duration))
            emitAudio(.warningAlarm, at: target, volume: 0.45)
            setNotice("\(recruits.count) residents armed. They still count as civilians to protect.", duration: 5)
        }
        publish()
        return true
    }

    private func returnRecruitedCivilians(from unit: DefenseUnit) {
        guard let residents = recruitedCivilians.removeValue(forKey: unit.id) else { return }
        for (index, var civilian) in residents.enumerated() {
            civilian.position = unit.formation.indices.contains(index) ? unit.formation[index] : unit.position
            civilian.speed = 0
            civilians.append(civilian)
        }
    }

    private func updateTacticalSupport(dt: Double) {
        for index in supportAreas.indices { supportAreas[index].age += dt }
        let landed = supportAreas.filter { $0.kind == .paratroopers && $0.age >= $0.lifetime }
        for drop in landed {
            let direction = map.roadDirection(at: drop.position)
            for offset in [-5.0, 5] {
                let position = map.nearestRoadPoint(to: CGPoint(x: drop.position.x + direction.dx * metersToWorld * offset,
                                                               y: drop.position.y + direction.dy * metersToWorld * offset))
                let id = allocateID(), health = upgradedHealth(.squad)
                units.append(DefenseUnit(id: id, kind: .squad, position: position, targetPosition: nil,
                                         health: health, maxHealth: health, range: upgradedRange(.squad), cooldown: 0,
                                         purchaseCost: UnitKind.squad.cost,
                                         soundVariant: deploymentVariants[.squad, default: 0] % 4))
                deploymentVariants[.squad, default: 0] += 1
                supportAutoUnits.insert(id)
                updateFormation(at: units.count - 1)
            }
            setNotice("Airborne squads landed. They seek the horde; select a team to give your own orders.", duration: 5)
        }
        for index in supportAreas.indices where supportAreas[index].kind == .fireBomb
            && supportAreas[index].age < supportAreas[index].lifetime
            && supportAreas[index].age >= supportAreas[index].nextPulseAt {
            supportAreas[index].nextPulseAt += 0.5
            let area = supportAreas[index]
            for target in zombies.indices where distance(zombies[target].position, area.position) < area.radius {
                zombies[target].health -= 22
            }
            let victims = Set(civilians.filter { distance($0.position, area.position) < area.radius * 0.85 }.map(\.id))
            removeCivilianVictims(victims, at: area.position)
            for target in units.indices where units[target].health > 0 && distance(units[target].position, area.position) < area.radius * 0.85 {
                units[target].health -= 16
            }
            applyStructuralDamage(at: area.position, radius: area.radius, damage: 24)
            applyBlastToStagedMembers(at: area.position, radius: area.radius, damage: 22)
        }
        supportAreas.removeAll { $0.age >= $0.lifetime }
        stunnedZombieIDs.removeAll(keepingCapacity: true)
        let clouds = supportAreas.filter { $0.kind == .gasBomb }
        if !clouds.isEmpty {
            for zombie in zombies where clouds.contains(where: { distance(zombie.position, $0.position) < $0.radius }) {
                stunnedZombieIDs.insert(zombie.id)
            }
        }
        guard elapsed >= nextSupportOrderAt, !supportAutoUnits.isEmpty else { return }
        nextSupportOrderAt = elapsed + 1.5
        for index in units.indices where supportAutoUnits.contains(units[index].id) && units[index].health > 0 {
            let unit = units[index]
            let threat = zombies.filter { $0.health > 0 }.min { squaredDistance($0.position, unit.position) < squaredDistance($1.position, unit.position) }?.position
                ?? stagedHerdMembers.min { squaredDistance($0.position, unit.position) < squaredDistance($1.position, unit.position) }?.position
            guard let threat else { continue }
            if distance(unit.position, threat) <= unit.range * 0.6 && hasLineOfSight(from: unit.position, to: threat) {
                units[index].targetPosition = nil; unitMotion[unit.id] = nil
            } else {
                let destination = map.nearestRoadPoint(to: threat)
                units[index].targetPosition = destination
                unitMotion[unit.id] = Motion(waypoints: map.path(from: unit.position, to: destination), destination: destination)
            }
        }
    }

    func canAfford(_ kind: UnitKind) -> Bool { budget >= kind.cost }

    @discardableResult
    func claimEmergencyReserve() -> Bool {
        guard emergencyAvailable else {
            setNotice(emergencyUsed ? "Emergency reserve already used this operation." : "Reserve unlocks after 20s when funds are low or the city is in danger.", duration: 5)
            publish()
            return false
        }
        emergencyUsed = true
        budget += GameBalance.emergencyFunds
        phase = .paused
        setNotice("Emergency reserve: +$\(GameBalance.emergencyFunds). Combat paused — regroup, then resume.", duration: 8)
        publish()
        return true
    }

    func barricadePlan(through input: [CGPoint]) -> BarricadePlan? {
        guard let first = input.first else { return nil }
        var requested = input.map(clamped)
        if requested.contains(where: { map.containsWater($0) && !map.isRoad($0) }) { return nil }
        let start = map.nearestRoadPoint(to: clamped(first))
        guard distance(start, clamped(first)) < 55 else { return nil }
        if requested.count == 1 {
            let direction = map.roadDirection(at: start)
            requested = [CGPoint(x: start.x - direction.dx * 29.5, y: start.y - direction.dy * 29.5),
                         CGPoint(x: start.x + direction.dx * 29.5, y: start.y + direction.dy * 29.5)]
        }
        var points = [map.nearestRoadPoint(to: requested[0])]
        var length = 0.0
        routeLoop: for raw in requested.dropFirst() {
            let target = map.nearestRoadPoint(to: raw)
            guard distance(raw, target) < 55 else { return nil }
            for next in map.path(from: points.last!, to: target).dropFirst() {
                let previous = points.last!
                let segment = distance(previous, next)
                if segment < 0.01 { continue }
                let remaining = GameBalance.maxBarricadeLength - length
                if segment > remaining {
                    points.append(CGPoint(x: previous.x + (next.x - previous.x) * remaining / segment,
                                          y: previous.y + (next.y - previous.y) * remaining / segment))
                    length += remaining
                    break routeLoop
                }
                points.append(next)
                length += segment
            }
        }
        guard length >= 12, points.count >= 2 else { return nil }
        let modules = max(1, Int(ceil((length - 0.0001) / GameBalance.barricadeModuleLength)))
        return BarricadePlan(points: points, length: length, cost: modules * UnitKind.barricade.cost, modules: modules)
    }

    @discardableResult
    func drawBarricade(through points: [CGPoint]) -> Bool {
        guard !phase.isFinished, let plan = barricadePlan(through: points) else {
            setNotice("Draw along a street or bridge. Maximum: five paid sections.", duration: 5)
            publish()
            return false
        }
        guard budget >= plan.cost else {
            setNotice("This barricade costs $\(plan.cost). Draw a shorter line.", duration: 5)
            publish()
            return false
        }
        var traversed = 0.0
        var midpoint = plan.points[0]
        for (a, b) in zip(plan.points, plan.points.dropFirst()) {
            let segment = distance(a, b)
            if traversed + segment >= plan.length / 2 {
                let fraction = (plan.length / 2 - traversed) / max(segment, 0.001)
                midpoint = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
                break
            }
            traversed += segment
        }
        // Reject intersecting placements atomically; no partial wall or partial charge.
        for unit in units where unit.kind.isAirSupport == false {
            for (a, b) in zip(plan.points, plan.points.dropFirst()) {
                let steps = max(1, Int(ceil(distance(a, b) / 12)))
                for index in 0...steps {
                    let fraction = Double(index) / Double(steps)
                    let sample = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
                    if unitDistance(unit, to: sample) < (unit.kind == .barricade ? 14 : 20) {
                        setNotice("Leave room beside existing defenses. Draw another street section.", duration: 5)
                        publish()
                        return false
                    }
                }
            }
        }
        let health = upgradedHealth(.barricade) * Double(plan.modules)
        budget -= plan.cost
        units.append(DefenseUnit(id: allocateID(), kind: .barricade, position: midpoint, targetPosition: nil,
                                 health: health, maxHealth: health, range: UnitKind.barricade.range, cooldown: 0,
                                 barrierPath: plan.points, purchaseCost: plan.cost))
        setNotice("\(plan.modules) barricade sections built · $\(plan.cost) · \(Int(health)) durability.", duration: 5)
        publish()
        return true
    }

    /// Every road through this rectangle must be closed. Walls are perpendicular
    /// to the road, so their durability protects an actual crossing, not a line
    /// running down the middle of a street that people can walk around.
    func safeZonePlan(from first: CGPoint, to second: CGPoint) -> SafeZonePlan? {
        guard first.x.isFinite, first.y.isFinite, second.x.isFinite, second.y.isFinite else { return nil }
        let a = map.nearestRoadPoint(to: clamped(first)), b = map.nearestRoadPoint(to: clamped(second))
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard rect.width >= metersToWorld * 35, rect.height >= metersToWorld * 35,
              rect.width <= 1_000, rect.height <= 1_000 else { return nil }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
        var walls: [BarricadePlan] = []
        var crossings: [CGPoint] = []
        for road in map.roads {
            for (start, end) in zip(road.points, road.points.dropFirst()) {
                let length = distance(start, end)
                guard length > 0.001 else { continue }
                for (edgeStart, edgeEnd) in zip(corners, corners.dropFirst()) {
                    guard let crossing = TacticalGeometry.intersection(start, end, edgeStart, edgeEnd),
                          !crossings.contains(where: { distance($0, crossing) < max(road.width, metersToWorld * 4) }) else { continue }
                    let halfWidth = road.width / 2 + metersToWorld * 1.1
                    let nx = -(end.y - start.y) / length, ny = (end.x - start.x) / length
                    let points = [CGPoint(x: crossing.x - nx * halfWidth, y: crossing.y - ny * halfWidth),
                                  CGPoint(x: crossing.x + nx * halfWidth, y: crossing.y + ny * halfWidth)]
                    let wallLength = halfWidth * 2
                    let modules = max(1, Int(ceil(wallLength / GameBalance.barricadeModuleLength)))
                    walls.append(BarricadePlan(points: points, length: wallLength, cost: modules * UnitKind.barricade.cost, modules: modules))
                    crossings.append(crossing)
                }
            }
        }
        guard !walls.isEmpty, walls.count <= 64 else { return nil }
        return SafeZonePlan(points: corners, walls: walls, cost: walls.reduce(0) { $0 + $1.cost },
                            civilianCount: civilians.filter { rect.contains($0.position) }.count)
    }

    @discardableResult
    func drawSafeZone(from start: CGPoint, to end: CGPoint) -> Bool {
        guard !phase.isFinished, let plan = safeZonePlan(from: start, to: end) else {
            setNotice("Draw a district at least 35 metres wide and high, with streets crossing its boundary.", duration: 5); publish(); return false
        }
        guard budget >= plan.cost else {
            setNotice("This safe zone needs \(plan.walls.count) street closures: $\(plan.cost). Draw a smaller zone.", duration: 5); publish(); return false
        }
        // Validate the whole purchase before altering either money or defenses.
        for wall in plan.walls {
            for unit in units where unit.health > 0 {
                guard let nearest = TacticalGeometry.nearestPoint(to: unit.position, on: wall.points) else { continue }
                if unitDistance(unit, to: nearest) < metersToWorld * 5 {
                    setNotice("An existing defense occupies the perimeter. Adjust the zone before confirming.", duration: 5); publish(); return false
                }
            }
        }
        budget -= plan.cost
        var boundaryIDs: [Int] = []
        for wall in plan.walls {
            let id = allocateID(), health = upgradedHealth(.barricade) * Double(wall.modules)
            let a = wall.points[0], b = wall.points[1]
            units.append(DefenseUnit(id: id, kind: .barricade, position: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                                     targetPosition: nil, health: health, maxHealth: health, range: UnitKind.barricade.range, cooldown: 0,
                                     barrierPath: wall.points, purchaseCost: wall.cost))
            boundaryIDs.append(id)
        }
        safeZones.append(SafeZone(id: allocateID(), points: plan.points, boundaryUnitIDs: boundaryIDs))
        setNotice("Safe zone: \(plan.civilianCount) residents inside · $\(plan.cost). Add gates so others can enter.", duration: 6)
        publish(); return true
    }

    func safeZoneOccupancy(_ zoneID: Int) -> Int {
        guard let zone = safeZones.first(where: { $0.id == zoneID }) else { return 0 }
        return civilians.filter { zone.contains($0.position) }.count + units.filter { zone.contains($0.position) }.reduce(0) { $0 + (recruitedCivilians[$1.id]?.count ?? 0) }
    }

    func isSafeZoneIntact(_ zoneID: Int) -> Bool {
        guard let zone = safeZones.first(where: { $0.id == zoneID }) else { return false }
        let alive = Set(units.filter { $0.kind == .barricade && $0.health > 0 }.map(\.id))
        return zone.boundaryUnitIDs.allSatisfy { alive.contains($0) }
    }

    var shelteredCivilianCount: Int {
        let aliveWalls = Set(units.filter { $0.kind == .barricade && $0.health > 0 }.map(\.id))
        let intact = safeZones.filter { zone in zone.boundaryUnitIDs.allSatisfy { aliveWalls.contains($0) } }
        guard !intact.isEmpty else { return 0 }
        var residentIDs = Set(civilians.filter { person in intact.contains { $0.contains(person.position) } }.map(\.id))
        for unit in units where intact.contains(where: { $0.contains(unit.position) }) {
            residentIDs.formUnion(recruitedCivilians[unit.id, default: []].map(\.id))
        }
        return residentIDs.count
    }

    @discardableResult
    func placeGate(at requested: CGPoint) -> Bool {
        guard !phase.isFinished, budget >= UnitKind.gate.cost,
              let wall = units.filter({ $0.kind == .barricade && $0.health > 0 }).min(by: { unitDistance($0, to: requested) < unitDistance($1, to: requested) }),
              unitDistance(wall, to: requested) < max(12, metersToWorld * 12),
              let point = TacticalGeometry.nearestPoint(to: requested, on: wall.barrierPath), map.isRoad(point) else {
            setNotice("Tap an intact wall where it crosses a street. A civilian gate costs $60.", duration: 5); publish(); return false
        }
        guard !units.contains(where: { $0.kind == .gate && distance($0.position, point) < metersToWorld * 8 }) else {
            setNotice("A gate already serves this crossing.", duration: 4); publish(); return false
        }
        budget -= UnitKind.gate.cost
        let health = upgradedHealth(.gate)
        let direction = map.roadDirection(at: point)
        units.append(DefenseUnit(id: allocateID(), kind: .gate, position: point, targetPosition: nil, health: health, maxHealth: health,
                                 range: 0, cooldown: 0, purchaseCost: UnitKind.gate.cost,
                                 heading: atan2(direction.dy, direction.dx), linkedBarrierID: wall.id))
        setNotice("Civilian gate installed. Single-file passage; zombies remain blocked.", duration: 5); publish(); return true
    }

    @discardableResult
    func detonateSelectedC4() -> Bool {
        guard let unit = selectedUnit, unit.kind == .c4 else { return false }
        return detonateCharges(ids: [unit.id])
    }

    @discardableResult
    func detonateAllC4() -> Bool { detonateCharges(ids: units.filter { $0.kind == .c4 }.map(\.id)) }

    private func detonateCharges(ids: [Int]) -> Bool {
        guard phase == .running || phase == .paused else {
            setNotice("C4 can be detonated once the operation begins.", duration: 4); publish(); return false
        }
        let charges = units.filter { ids.contains($0.id) && $0.kind == .c4 && $0.health > 0 && $0.cooldown <= 0 }
        guard !charges.isEmpty else { return false }
        let spentIDs = Set(charges.map(\.id))
        units.removeAll { spentIDs.contains($0.id) }
        if let selectedUnitID, spentIDs.contains(selectedUnitID) { self.selectedUnitID = nil }
        for charge in charges {
            applyExplosion(at: charge.position, radius: metersToWorld * 48, damage: charge.kind.damage, civilianRadius: metersToWorld * 29)
        }
        removeDestroyedUnits(); removeDeadZombies()
        setNotice("\(charges.count) C4 charge\(charges.count == 1 ? "" : "s") detonated. Check for collateral damage.", duration: 5)
        publish(); return true
    }

    private func unitDistance(_ unit: DefenseUnit, to point: CGPoint) -> Double {
        guard unit.kind == .barricade && unit.barrierPath.count > 1 else { return distance(unit.position, point) }
        var nearest = Double.infinity
        for (a, b) in zip(unit.barrierPath, unit.barrierPath.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(lengthSquared, 0.001)))
            nearest = min(nearest, distance(point, CGPoint(x: a.x + dx * fraction, y: a.y + dy * fraction)))
        }
        return nearest
    }

    func tap(at point: CGPoint, selectionRadius: Double? = nil) {
        guard !phase.isFinished else { return }
        let point = clamped(point)
        if let selectedSupport {
            performSupport(selectedSupport, at: point)
            return
        }
        if selectedTool == .gate { placeGate(at: point); return }
        if selectedTool == .safeZone {
            setNotice("Drag across a district to preview its street closures and total cost.", duration: 5); publish(); return
        }
        // Close camera views expose individual soldiers away from the team
        // center. Hit their actual positions rather than expanding the radius
        // and accidentally selecting teams across the whole viewport.
        func selectionDistance(_ unit: DefenseUnit) -> Double {
            min(unitDistance(unit, to: point), unit.formation.map { distance($0, point) }.min() ?? .infinity)
        }
        func inspect(_ unit: DefenseUnit) {
            selectedTool = nil
            selectedUnitID = unit.id
            setNotice(unit.kind.isMobile ? "\(unit.kind.shortTitle) selected. Tap a road to reposition." : "\(unit.kind.shortTitle) selected · \(Int(unit.health))/\(Int(unit.maxHealth)) durability.", duration: 5)
        }
        // A selected charge is an explicit placement order. A nearby wall or
        // different defense must not swallow it as an inspection tap.
        let physicalTouch = min(selectionRadius ?? 32, metersToWorld * 3)
        if let kind = selectedTool, kind.isExplosive {
            // Placement snaps to the road. Repeating the same finger tap must
            // inspect that snapped charge even if the finger was over a roof.
            let placementPoint = map.nearestRoadPoint(to: point)
            if let existing = units.filter({ $0.kind == kind && distance($0.position, placementPoint) <= physicalTouch }).min(by: { distance($0.position, placementPoint) < distance($1.position, placementPoint) }) {
                inspect(existing)
            } else { deploy(kind, at: point) }
            publish(); return
        }
        if selectedTool == .sniper, let host = sniperHostBuilding(at: point) {
            if let existing = units.first(where: { $0.kind == .sniper && $0.hostBuildingID == host }) { inspect(existing) }
            else { deploy(.sniper, at: point) }
            publish(); return
        }
        // The wall's segment distance is always smaller than its gate's point
        // distance. Give a genuine aperture tap priority so gates stay inspectable.
        if selectedTool?.isAirSupport != true,
           let gate = units.filter({ $0.kind == .gate && distance($0.position, point) <= physicalTouch }).min(by: { distance($0.position, point) < distance($1.position, point) }) {
            inspect(gate); publish(); return
        }
        if selectedTool?.isAirSupport != true, let unit = units.min(by: { selectionDistance($0) < selectionDistance($1) }), selectionDistance(unit) < (selectionRadius ?? 32) {
            inspect(unit)
        } else if let kind = selectedTool {
            deploy(kind, at: point)
        } else if selectedUnitID != nil {
            moveSelected(to: point)
        } else {
            setNotice("Choose a unit below, or tap a deployed unit to inspect it.", duration: 4)
        }
        publish()
    }

    func moveSelected(to point: CGPoint) {
        guard !phase.isFinished, let id = selectedUnitID, let index = units.firstIndex(where: { $0.id == id }) else { return }
        guard units[index].kind.isMobile else {
            setNotice("This defense is fixed. Select a squad, Humvee, or mortar team to move.", duration: 4)
            publish()
            return
        }
        guard !map.containsWater(point) || map.isRoad(point) else {
            setNotice("Ground teams need a road or bridge.", duration: 4)
            publish()
            return
        }
        let destination = map.nearestRoadPoint(to: clamped(point))
        supportAutoUnits.remove(id)
        if phase == .planning {
            if units.contains(where: { $0.id != id && unitDistance($0, to: destination) < 26 }) {
                setNotice("Leave space between defenses. Choose another road position.", duration: 4)
                publish()
                return
            }
            units[index].position = destination
            units[index].targetPosition = nil
            unitMotion[id] = nil
            updateFormation(at: index)
        } else {
            units[index].targetPosition = destination
            units[index].holding = true
            units[index].patrolWaypoints.removeAll()
            unitMotion[id] = Motion(waypoints: map.path(from: units[index].position, to: destination), destination: destination)
        }
        setNotice("\(units[index].kind.shortTitle) moving to new position.", duration: 3)
        publish()
    }

    /// A patrol is a road-following loop; barricades stop vehicles rather than being driven through.
    @discardableResult
    func setPatrol(through points: [CGPoint]) -> Bool {
        guard !phase.isFinished, let id = selectedUnitID, let index = units.firstIndex(where: { $0.id == id }), units[index].kind == .humvee, points.count >= 2 else { return false }
        let totalLength = zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        guard totalLength > 30 else { return false }
        let count = min(12, points.count)
        let route = (0..<count).map { sample in
            let sourceIndex = Int((Double(sample) * Double(points.count - 1) / Double(count - 1)).rounded())
            return map.nearestRoadPoint(to: clamped(points[sourceIndex]))
        }
        units[index].patrolWaypoints = route
        units[index].patrolIndex = 0
        units[index].holding = false
        let destination = route[0]
        units[index].targetPosition = destination
        unitMotion[id] = Motion(waypoints: map.path(from: units[index].position, to: destination), destination: destination)
        setNotice("Humvee patrol ordered. It will stop at intact barricades.", duration: 4)
        publish()
        return true
    }

    func holdSelected() {
        guard let id = selectedUnitID, let index = units.firstIndex(where: { $0.id == id }), units[index].kind == .humvee else { return }
        units[index].holding = true
        units[index].targetPosition = nil
        units[index].patrolWaypoints.removeAll()
        unitMotion[id] = nil
        setNotice("Humvee holding this intersection.", duration: 3)
        publish()
    }

    var selectedRepairCost: Int {
        guard let unit = selectedUnit, unit.kind.isWall else { return 0 }
        return Int(ceil(Double(unit.purchaseCost) * (1 - unit.health / unit.maxHealth) * 0.7))
    }

    @discardableResult
    func repairSelected() -> Bool {
        guard !phase.isFinished, let id = selectedUnitID, let index = units.firstIndex(where: { $0.id == id }), units[index].kind.isWall else { return false }
        let cost = selectedRepairCost
        guard cost > 0, budget >= cost else { return false }
        budget -= cost
        units[index].health = units[index].maxHealth
        setNotice("\(units[index].kind.shortTitle) repaired · $\(cost).", duration: 4)
        publish()
        return true
    }

    /// Select an operation explicitly; retry/reset retain its current rules.
    func beginOperation(city: CityScenario, mode: OutbreakMode, district: CampaignDistrict = .neighborhood, missionSeed seed: UInt64? = nil) {
        guard mode == .siege || isDistrictUnlocked(district, in: city) else {
            setNotice("Meet the previous district’s survival objective to expand the operation.", duration: 5)
            publish()
            return
        }
        outbreakMode = mode
        campaignDistrict = mode == .siege ? .citywide : district
        reset(city: city, missionSeed: seed)
    }

    func isDistrictUnlocked(_ district: CampaignDistrict, in city: CityScenario) -> Bool {
        guard district != .neighborhood else { return true }
        let previous = CampaignDistrict.allCases[district.index - 1]
        let key = CampaignRules.missionKey(city: city, mode: .cityOutbreak, district: previous)
        return (missionBests[key]?.survivalRate ?? 0) >= previous.survivalObjective
    }

    /// Advancing restores only surviving, paid defenses. Fresh mission population
    /// receives fresh IDs; the retained blueprints receive new IDs as well.
    @discardableResult
    func continueCampaign() -> Bool {
        guard canContinueCampaign, let next = campaignDistrict.next else { return false }
        let retained = units.filter { $0.health > 0 && $0.purchaseCost > 0 && !supportAutoUnits.contains($0.id) }
        let oldZones = safeZones
        campaignDistrict = next
        reset(city: city)
        var ids: [Int: Int] = [:]
        for original in retained { ids[original.id] = allocateID() }
        units = retained.compactMap { original in
            guard let id = ids[original.id] else { return nil }
            var unit = DefenseUnit(id: id, kind: original.kind, position: original.position, targetPosition: nil,
                                   health: original.health, maxHealth: original.maxHealth, range: original.range,
                                   cooldown: 0, barrierPath: original.barrierPath, purchaseCost: original.purchaseCost,
                                   formation: original.formation, heading: original.heading, turretHeading: original.turretHeading,
                                   patrolWaypoints: [], holding: true, soundVariant: original.soundVariant)
            unit.linkedBarrierID = original.linkedBarrierID.flatMap { ids[$0] }
            unit.crewRemaining = original.crewRemaining
            unit.hostBuildingID = original.hostBuildingID
            unit.elevation = original.elevation
            return unit
        }
        safeZones = oldZones.compactMap { zone in
            let boundaries = zone.boundaryUnitIDs.compactMap { ids[$0] }
            guard !boundaries.isEmpty, boundaries.count == zone.boundaryUnitIDs.count else { return nil }
            return SafeZone(id: allocateID(), points: zone.points, boundaryUnitIDs: boundaries)
        }
        setNotice("Expanded to \(campaignDistrict.title). Surviving paid defenses retained; \(initialPopulation) civilians now need protection.", duration: .infinity)
        publish()
        return true
    }

    @discardableResult
    func respecLoadout() -> Bool {
        guard phase == .planning else { return false }
        let refund = upgradeLevels.reduce(0) { $0 + $1.value * $1.key.upgradeCost }
        guard refund > 0 else { return false }
        let oldLevels = upgradeLevels
        upgradePoints += refund
        upgradeLevels.removeAll()
        for index in units.indices {
            let kind = units[index].kind
            let oldLevel = oldLevels[kind, default: 0]
            guard oldLevel > 0 else { continue }
            let ratio = units[index].health / max(1, units[index].maxHealth)
            units[index].maxHealth /= 1 + Double(oldLevel) * 0.22
            units[index].health = units[index].maxHealth * ratio
            let heightBonus = kind == .sniper ? 1 + min(0.60, units[index].elevation / metersToWorld / 120) : 1
            units[index].range = upgradedRange(kind) * heightBonus
        }
        writeProgression()
        setNotice("Loadout reassigned. \(refund) points returned; choose a new strategy.", duration: 5)
        publish()
        return true
    }

    private func seedCityOutbreak() {
        guard outbreakMode == .cityOutbreak, zombies.isEmpty else { return }
        // Choose among the district's real populated streets only when play starts.
        let origin = civilians.isEmpty ? randomStreetPoint() : civilians[random.index(count: civilians.count)].position
        let nearby = map.navigationEdges.filter { edge in
            let a = map.navigationNodes[edge.from], b = map.navigationNodes[edge.to]
            return distance(a, origin) < metersToWorld * 100 && distance(b, origin) < metersToWorld * 100 &&
                (missionBounds == nil || (missionBounds!.contains(a) && missionBounds!.contains(b)))
        }
        let herdID = allocateID()
        for _ in 0..<campaignDistrict.initialInfected {
            var point = origin
            if !nearby.isEmpty {
                let edge = nearby[random.index(count: nearby.count)]
                let a = map.navigationNodes[edge.from], b = map.navigationNodes[edge.to]
                let fraction = random.double(in: 0.05...0.95)
                point = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
            }
            let road = map.roadDirection(at: point)
            let lateral = random.double(in: -0.7...0.7) * metersToWorld
            let position = CGPoint(x: point.x - road.dy * lateral, y: point.y + road.dx * lateral)
            zombies.append(Zombie(id: allocateID(), position: position, health: 60, herdID: herdID,
                                  lateralOffset: lateral, heading: atan2(road.dy, road.dx)))
        }
        initialInfected = zombies.count
        herdPopulationTotal = zombies.count
        infectionOrigins = [origin]
    }

    func newOutbreak() {
        missionSeed = UInt64.random(in: 1...UInt64.max) ^ city.seed
        reset(city: city)
    }
    func rerollOutbreak() { newOutbreak() }

    func cycleAttackHeading() {
        attackHeading = (attackHeading + .pi / 4).truncatingRemainder(dividingBy: .pi * 2)
        publish()
    }
    func setAttackHeading(_ heading: Double) {
        guard heading.isFinite else { return }
        attackHeading = heading
        publish()
    }
    func cycleAC130WeaponMode() {
        setAirWeaponMode(ac130WeaponMode == .cannon30 ? .cannon105 : .cannon30)
    }
    func setAirWeaponMode(_ mode: AirWeaponMode) {
        ac130WeaponMode = mode
        for index in flights.indices where flights[index].kind == .ac130 { flights[index].weaponMode = mode }
        publish()
    }
    func retargetAC130(at target: CGPoint) {
        guard !phase.isFinished else { return }
        for index in flights.indices where flights[index].kind == .ac130 { flights[index].target = clamped(target) }
        publish()
    }
    func drainAudioEvents() -> [GameAudioEvent] {
        let result = audioEvents
        audioEvents.removeAll(keepingCapacity: true)
        return result
    }

    func removeSelected() {
        guard !phase.isFinished, let id = selectedUnitID, let index = units.firstIndex(where: { $0.id == id }) else { return }
        let kind = units[index].kind
        guard kind != .gate || phase == .planning else {
            setNotice("An active gate is part of its perimeter. Repair it or withdraw the entire wall.", duration: 5)
            publish()
            return
        }
        let purchaseCost = units[index].purchaseCost > 0 ? units[index].purchaseCost : kind.cost
        let refund = phase == .planning ? purchaseCost : Int(Double(purchaseCost) * units[index].health / units[index].maxHealth) / 3
        budget += refund
        returnRecruitedCivilians(from: units[index])
        supportAutoUnits.remove(id)
        units.remove(at: index)
        if kind == .barricade {
            let gates = units.filter { $0.linkedBarrierID == id }
            if phase == .planning { budget += gates.reduce(0) { $0 + $1.purchaseCost } }
            units.removeAll { $0.linkedBarrierID == id }
        }
        unitMotion[id] = nil
        evacuationProgress[id] = nil
        troopExposure[id] = nil
        selectedUnitID = nil
        setNotice(refund > 0 ? "\(kind.shortTitle) withdrawn. $\(refund) returned to command." : "Defense withdrawn.", duration: 4)
        publish()
    }

    /// Equal short steps preserve the whole elapsed interval. A 1 ms allowance
    /// avoids another full AI/collision pass for timer jitter around 20 Hz.
    func tick(dt: Double, publishSnapshot: Bool = true, captureRenderHistory: Bool = true) {
        guard phase == .running, dt.isFinite, dt > 0 else { return }
        let previousPhase = phase
        if captureRenderHistory { beginRenderFrame() }
        let interval = min(dt, 0.25) * speed
        let stepCount = max(1, Int(ceil(interval / 0.051)))
        let step = interval / Double(stepCount)
        for _ in 0..<stepCount {
            guard phase == .running else { break }
            simulate(dt: step)
        }
        if captureRenderHistory { endRenderFrame() }
        simulationRevision &+= 1
        // A result screen must appear immediately even when the driver is
        // between its regular HUD publications.
        if publishSnapshot || phase != previousPhase { publish() }
    }

    /// Display drivers call this at their HUD cadence; player orders continue to
    /// publish immediately through their existing gameplay methods.
    func publishUI() { publish() }

    /// A display driver can distribute accelerated physics over several wall
    /// frames while retaining one previous pose for the 20 Hz geometry snapshot.
    func beginRenderFrame() { captureRenderMotion() }

    func endRenderFrame() {
        renderSimulationInterval = elapsed - previousRenderElapsed
        renderRevision += 1
    }

    func previousMotion(for id: Int) -> RenderMotionState? { previousRenderMotion[id] }

    func interpolatedMotion(for id: Int, current: RenderMotionState, fraction: Double) -> RenderMotionState {
        FrameInterpolation.sample(previous: previousRenderMotion[id], current: current, fraction: fraction)
    }

    func interpolatedElapsed(fraction: Double) -> Double {
        previousRenderElapsed + renderSimulationInterval * FrameInterpolation.fraction(fraction)
    }

    func previousCrewPosition(unitID: Int, index: Int) -> CGPoint? {
        guard let formation = previousUnitFormations[unitID], formation.indices.contains(index) else { return nil }
        return formation[index]
    }

    func interpolatedCrewPosition(unitID: Int, index: Int, current: CGPoint, fraction: Double) -> CGPoint {
        guard let previous = previousCrewPosition(unitID: unitID, index: index) else { return current }
        let amount = FrameInterpolation.fraction(fraction)
        return CGPoint(x: previous.x + (current.x - previous.x) * amount,
                       y: previous.y + (current.y - previous.y) * amount)
    }

    private func captureRenderMotion() {
        previousRenderElapsed = elapsed
        previousRenderMotion.removeAll(keepingCapacity: true)
        previousUnitFormations.removeAll(keepingCapacity: true)
        previousRenderMotion.reserveCapacity(civilians.count + zombies.count + units.count + flights.count + projectiles.count + effects.count + supportAreas.count)
        for civilian in civilians {
            previousRenderMotion[civilian.id] = RenderMotionState(position: civilian.position, heading: civilian.heading,
                                                                 stride: civilian.stride, speed: civilian.speed)
        }
        for zombie in zombies {
            previousRenderMotion[zombie.id] = RenderMotionState(position: zombie.position, heading: zombie.heading,
                                                               stride: zombie.stride, speed: zombie.speed)
        }
        for unit in units {
            previousRenderMotion[unit.id] = RenderMotionState(position: unit.position, heading: unit.heading,
                                                             stride: elapsed * 8, turretHeading: unit.turretHeading)
            if !unit.formation.isEmpty { previousUnitFormations[unit.id] = unit.formation }
        }
        for flight in flights {
            previousRenderMotion[flight.id] = RenderMotionState(position: flight.position, heading: flight.heading,
                                                               altitude: flight.altitude, age: flight.age)
        }
        for projectile in projectiles {
            previousRenderMotion[projectile.id] = RenderMotionState(position: projectile.position,
                                                                   altitude: projectile.altitude, age: projectile.age)
        }
        for effect in effects {
            previousRenderMotion[effect.id] = RenderMotionState(position: effect.position, altitude: effect.altitude, age: effect.age)
        }
        for area in supportAreas {
            previousRenderMotion[area.id] = RenderMotionState(position: area.position, age: area.age)
        }
    }

    @discardableResult
    func purchaseUpgrade(_ kind: UnitKind) -> Bool {
        guard phase == .planning, CampaignRules.upgradeableKinds.contains(kind) else {
            setNotice("Reassign your loadout during planning.", duration: 4)
            publish()
            return false
        }
        let level = upgradeLevels[kind, default: 0]
        guard level < 3 else {
            setNotice("\(kind.shortTitle) is fully upgraded.", duration: 4)
            publish()
            return false
        }
        guard upgradePoints >= kind.upgradeCost else {
            setNotice("Improve a successful survival result to earn more points.", duration: 4)
            publish()
            return false
        }
        upgradePoints -= kind.upgradeCost
        upgradeLevels[kind] = level + 1
        if phase == .planning {
            for index in units.indices where units[index].kind == kind {
                let oldMaximum = units[index].maxHealth
                let multiplier = kind == .barricade ? Double(max(1, units[index].purchaseCost / kind.cost)) : 1
                let newMaximum = upgradedHealth(kind) * multiplier
                units[index].maxHealth = newMaximum
                units[index].health = newMaximum * min(1, units[index].health / max(1, oldMaximum))
                let heightBonus = kind == .sniper ? 1 + min(0.60, units[index].elevation / metersToWorld / 120) : 1
                units[index].range = upgradedRange(kind) * heightBonus
            }
        }
        writeProgression()
        setNotice("\(kind.shortTitle) upgraded to level \(level + 1).", duration: 5)
        publish()
        return true
    }

    private func deploy(_ kind: UnitKind, at requested: CGPoint) {
        if kind == .barricade { drawBarricade(through: [requested]); return }
        if kind == .gate { placeGate(at: requested); return }
        if kind == .safeZone { return }
        if kind == .ac130, flights.contains(where: { $0.kind == .ac130 }), !phase.isFinished {
            retargetAC130(at: requested)
            setNotice("AC-130 orbit retargeted. \(ac130WeaponMode.title) fire remains on station.", duration: 4)
            return
        }
        guard canAfford(kind) else {
            setNotice("Insufficient funds. \(kind.shortTitle) costs $\(kind.cost).", duration: 4)
            return
        }
        if kind.isAirSupport {
            guard phase == .running || phase == .paused else {
                setNotice("Air support becomes available after the operation begins.", duration: 4)
                return
            }
            guard sortiesRemaining(kind) > 0 else {
                setNotice("All three \(kind.shortTitle) sorties have been used this operation.", duration: 5)
                return
            }
            guard aircraftReadyIn(kind) <= 0.001 else {
                setNotice("\(kind.shortTitle) ready in \(Int(ceil(aircraftReadyIn(kind))))s. Hold the perimeter.", duration: 4)
                return
            }
            guard !flights.contains(where: { $0.kind == kind }) else {
                setNotice("\(kind.shortTitle) is already on station. Wait for it to return.", duration: 4)
                return
            }
            budget -= kind.cost
            callAircraft(kind, at: clamped(requested))
            return
        }
        let rooftop = kind == .sniper ? sniperHostBuilding(at: requested) : nil
        let placementCost = kind == .sniper ? sniperPlacementCost(at: requested) : kind.cost
        guard budget >= placementCost else {
            setNotice("This rooftop requires $\(placementCost). Choose a smaller building or deploy on a street.", duration: 5); return
        }
        let position = rooftop.map(sniperRoofPosition) ?? map.nearestRoadPoint(to: requested)
        guard !map.containsWater(requested) || map.isRoad(requested) else {
            setNotice("Deploy ground defenses on a road or bridge.", duration: 4)
            return
        }
        let overlapsDefense = units.contains { unit in
            if let rooftop { return unit.hostBuildingID == rooftop }
            return unitDistance(unit, to: position) < (kind.isExplosive ? metersToWorld * 3 : 26)
        }
        guard !overlapsDefense else {
            setNotice("Leave space between defenses. Choose another road position.", duration: 4)
            return
        }
        budget -= placementCost
        let id = allocateID()
        let health = upgradedHealth(kind)
        let elevation = rooftop.map { map.buildings[$0].height } ?? 0
        let heightBonus = 1 + min(0.60, elevation / metersToWorld / 120)
        units.append(DefenseUnit(id: id, kind: kind, position: position, targetPosition: nil, health: health, maxHealth: health,
                                 range: kind.isExplosive ? kind.range * metersToWorld : upgradedRange(kind) * (kind == .sniper ? heightBonus : 1), cooldown: kind.isExplosive ? 2 : 0,
                                 purchaseCost: placementCost, soundVariant: deploymentVariants[kind, default: 0] % 4,
                                 hostBuildingID: rooftop, elevation: elevation))
        deploymentVariants[kind, default: 0] += 1
        updateFormation(at: units.count - 1)
        setNotice("\(kind.shortTitle) deployed. $\(budget) remaining.", duration: 3)
    }

    private func simulate(dt: Double) {
        simulationStepCount += 1
        elapsed += dt
        ageEffects(dt: dt)
        spawnArrivingHerds()
        updateTacticalSupport(dt: dt)
        moveUnits(dt: dt)
        rebuildZombieGrid()
        rebuildCivilianGrid()
        updateCivilianKnowledge(dt: dt)
        moveCivilians(dt: dt)
        rebuildCivilianGrid()
        moveZombies(dt: dt)
        rebuildZombieGrid()
        updateInfantryInfection(dt: dt)
        updatePlantedExplosives(dt: dt)
        fireDefenses(dt: dt)
        updateAircraft(dt: dt)
        updateProjectiles(dt: dt)
        evacuateCivilians(dt: dt)
        spreadInfection(dt: dt)
        removeDestroyedUnits()
        removeDeadZombies()
        if elapsed > noticeUntil { notice = "" }
        resolveOutcome()
    }

    private func moveUnits(dt: Double) {
        for index in units.indices where units[index].health > 0 {
            let id = units[index].id
            if units[index].kind == .humvee, !units[index].holding,
               unitMotion[id] == nil, !units[index].patrolWaypoints.isEmpty {
                units[index].patrolIndex = (units[index].patrolIndex + 1) % units[index].patrolWaypoints.count
                let destination = units[index].patrolWaypoints[units[index].patrolIndex]
                units[index].targetPosition = destination
                unitMotion[id] = Motion(waypoints: map.path(from: units[index].position, to: destination), destination: destination)
            }
            guard var motion = unitMotion[id] else { updateFormation(at: index); continue }
            let previous = units[index].position
            let pace = metersToWorld * (units[index].kind == .humvee ? 20 : (units[index].kind == .mortar ? 1.5 : 2.0))
            let next = advance(from: previous, motion: &motion, amount: pace * dt)
            if units.contains(where: { $0.kind == .barricade && $0.id != id && unitDistance($0, to: next) < metersToWorld * (units[index].kind == .humvee ? 3.5 : 1.3) }) {
                if units[index].kind == .humvee { emitAudio(.humveeEngine, at: previous, volume: 0.25, interval: 3) }
                continue
            }
            units[index].position = next
            if distance(previous, next) > 0.01 { units[index].heading = atan2(next.y - previous.y, next.x - previous.x) }
            if motion.index >= motion.waypoints.count {
                unitMotion[id] = nil
                units[index].targetPosition = nil
            } else { unitMotion[id] = motion }
            updateFormation(at: index)
            if units[index].kind == .humvee { emitAudio(.humveeEngine, at: next, volume: 0.35, interval: 1.5) }
        }
    }

    private func updateFormation(at index: Int) {
        guard units[index].kind.hasHumanCrew else { return }
        if units[index].hostBuildingID != nil {
            let center = units[index].position, spacing = metersToWorld * 0.8
            units[index].formation = (0..<crewCount(for: units[index].id)).map { slot in
                CGPoint(x: center.x + (Double(slot) - 0.5) * spacing, y: center.y)
            }
            return
        }
        let center = units[index].position
        let direction = map.roadDirection(at: center)
        let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
        let spacing = metersToWorld * 1.5
        let width = min(metersToWorld * 0.7, map.streetWidth(at: center) * 0.22)
        let availableSlots: [(Double, Double)] = units[index].kind != .squad ? [(-0.45, 0), (0.45, 0)] : [(-2, -1), (-1, 1), (0, 0), (1, -1), (2, 1)]
        let slots: [(Double, Double)] = recruitedCivilians[units[index].id] == nil ? availableSlots : [(0, 0)]
        units[index].formation = slots.prefix(crewCount(for: units[index].id)).map { along, across in
            let point = CGPoint(x: center.x + direction.dx * along * spacing + perpendicular.dx * across * width,
                                y: center.y + direction.dy * along * spacing + perpendicular.dy * across * width)
            return map.isRoad(point) && !map.containsBuilding(point) ? point : map.nearestRoadPoint(to: point)
        }
        if unitMotion[units[index].id] == nil { units[index].heading = atan2(direction.dy, direction.dx) }
    }

    private func civilianNeighbors(near point: CGPoint, radius: Double) -> [Int] {
        let low = cell(for: CGPoint(x: point.x - radius, y: point.y - radius))
        let high = cell(for: CGPoint(x: point.x + radius, y: point.y + radius))
        var result: [Int] = []
        for x in low.x...high.x { for y in low.y...high.y {
            for index in civilianGrid[GridCell(x: x, y: y)] ?? [] where squaredDistance(civilians[index].position, point) < radius * radius { result.append(index) }
        } }
        return result
    }

    /// Deterministic continuous variation avoids repeating a few visible lanes
    /// and never consumes the mission RNG or changes retry reproducibility.
    private func movementVariation(_ id: Int, salt: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(id)) &+ salt &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992.0
    }

    private func movementDirection(from position: CGPoint, motion: Motion, fallback: Double) -> Double {
        for waypoint in motion.waypoints.dropFirst(motion.index) where squaredDistance(position, waypoint) > 0.000_001 {
            return atan2(waypoint.y - position.y, waypoint.x - position.x)
        }
        return fallback
    }

    /// Used only for local pursuit and tiny presentation-lane steps. Long
    /// routes still use the shared street graph rather than visibility rays.
    private func roadSegmentIsClear(from start: CGPoint, to end: CGPoint) -> Bool {
        let samples = max(1, Int(ceil(distance(start, end) / max(0.1, metersToWorld))))
        for index in 0...samples {
            let fraction = Double(index) / Double(samples)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                y: start.y + (end.y - start.y) * fraction)
            if !map.isRoad(point) || map.containsBuilding(point) { return false }
        }
        return true
    }

    private func boundedRoadStep(from start: CGPoint, to requested: CGPoint, maximumStep: Double, rejoinPoint: CGPoint? = nil, directIsClear: Bool? = nil) -> CGPoint {
        func limited(_ destination: CGPoint) -> CGPoint {
            let fraction = min(1, max(0, maximumStep) / max(0.000_001, distance(start, destination)))
            return CGPoint(x: start.x + (destination.x - start.x) * fraction,
                           y: start.y + (destination.y - start.y) * fraction)
        }
        let next = limited(requested)
        if directIsClear ?? (roadSegmentIsClear(from: start, to: next) && hasLineOfSight(from: start, to: next)) { return next }
        // Narrow turns can temporarily remove a personal lane. Recover toward
        // the graph center with the same speed bound instead of snapping there.
        let recovery = limited(rejoinPoint ?? map.nearestRoadPoint(to: start))
        return roadSegmentIsClear(from: start, to: recovery) && hasLineOfSight(from: start, to: recovery) ? recovery : start
    }

    /// A person's nearest street center can lie behind a projecting building
    /// corner. Recover through a visible point just outside that corner first;
    /// every returned leg is checked against the actual street and footprint.
    /// This bounded local visibility check runs only after a rejected lane step.
    private func roadRecoveryPoint(from start: CGPoint, toward preferred: CGPoint) -> CGPoint {
        func clear(_ a: CGPoint, _ b: CGPoint) -> Bool {
            roadSegmentIsClear(from: a, to: b) && hasLineOfSight(from: a, to: b)
        }
        if clear(start, preferred) { return preferred }
        let radius = metersToWorld * 20
        var polygons = map.buildingIndices(near: start, radius: radius).sorted().map { map.buildings[$0].footprint }
        for index in map.landmarks.indices where !destroyedLandmarkIDs.contains(index) {
            let polygon = map.landmarkFootprint(at: index)
            if polygon.contains(where: { distance($0, start) <= radius }) { polygons.append(polygon) }
        }
        var best: CGPoint?, bestLength = Double.infinity
        func consider(_ candidate: CGPoint) {
            guard distance(start, candidate) <= radius, distance(start, candidate) > metersToWorld * 0.03,
                  clear(start, candidate), clear(candidate, preferred) else { return }
            let length = distance(start, candidate) + distance(candidate, preferred)
            if length < bestLength { best = candidate; bestLength = length }
        }
        for polygon in polygons where polygon.count > 2 {
            let centroid = CGPoint(x: polygon.reduce(0) { $0 + $1.x } / Double(polygon.count),
                                   y: polygon.reduce(0) { $0 + $1.y } / Double(polygon.count))
            for vertex in polygon where distance(vertex, start) <= radius {
                let dx = vertex.x - centroid.x, dy = vertex.y - centroid.y
                let length = max(0.000_001, hypot(dx, dy)), clearance = metersToWorld * 0.6
                consider(CGPoint(x: vertex.x + dx / length * clearance, y: vertex.y + dy / length * clearance))
            }
        }
        // Concave parcels do not necessarily have an exterior centroid ray.
        // Test a small, fixed set around their vertices only if that ray failed.
        if best == nil {
            for polygon in polygons {
                for vertex in polygon where distance(vertex, start) <= radius {
                    for index in 0..<8 {
                        let angle = Double(index) * .pi / 4, clearance = metersToWorld * 0.6
                        consider(CGPoint(x: vertex.x + cos(angle) * clearance, y: vertex.y + sin(angle) * clearance))
                    }
                }
            }
        }
        return best ?? preferred
    }

    /// Gate filtering can live here: every proposed movement segment uses this
    /// single wall check before any position or graph cursor is committed.
    func movementBlocked(from start: CGPoint, to end: CGPoint, forCivilians: Bool = false) -> Bool {
        let clearance = metersToWorld * (forCivilians ? 0.65 : 0.85)
        let samples = max(1, Int(ceil(distance(start, end) / max(0.1, metersToWorld * 0.45))))
        for unit in units where unit.kind == .barricade && unit.health > 0 {
            for index in 0...samples {
                let fraction = Double(index) / Double(samples)
                let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                    y: start.y + (end.y - start.y) * fraction)
                if unitDistance(unit, to: point) < clearance {
                    let aperture = forCivilians && units.contains { gate in
                        gate.kind == .gate && gate.health > 0 && gate.linkedBarrierID == unit.id &&
                        distance(gate.position, point) < metersToWorld * 2.2
                    }
                    if !aperture { return true }
                }
            }
        }
        return false
    }

    /// Only the admitted resident may use this narrow aperture until they have
    /// cleared it. Others wait on the approach rather than passing through bodies.
    private func civilianGateAllows(_ civilianID: Int, from start: CGPoint, to end: CGPoint) -> Bool {
        let gates = units.filter { $0.kind == .gate && $0.health > 0 && distance($0.position, end) < metersToWorld * 3.2 }
        guard let gate = gates.min(by: { distance($0.position, end) < distance($1.position, end) }) else { return true }
        if gatePasses[civilianID]?.gateID == gate.id { return true }
        if gatePasses.values.contains(where: { $0.gateID == gate.id && $0.expires > elapsed }) { return false }
        guard elapsed >= nextGatePassAt[gate.id, default: 0] else { return false }
        gatePasses[civilianID] = (gate.id, elapsed + 7)
        nextGatePassAt[gate.id] = elapsed + 0.6
        return true
    }

    private func civilianGateDetour(from start: CGPoint, blockedAt point: CGPoint, destination: CGPoint) -> [CGPoint]? {
        guard let wall = units.filter({ $0.kind == .barricade && $0.health > 0 && unitDistance($0, to: point) < metersToWorld * 2 }).first,
              let gate = units.filter({ $0.kind == .gate && $0.health > 0 && $0.linkedBarrierID == wall.id }).min(by: { distance($0.position, start) < distance($1.position, start) }) else { return nil }
        let direction = map.roadDirection(at: gate.position)
        let sign = (destination.x - gate.position.x) * direction.dx + (destination.y - gate.position.y) * direction.dy >= 0 ? 1.0 : -1.0
        let beyond = map.nearestRoadPoint(to: CGPoint(x: gate.position.x + direction.dx * metersToWorld * 5 * sign,
                                                    y: gate.position.y + direction.dy * metersToWorld * 5 * sign))
        return map.path(from: start, to: gate.position) + [beyond] + map.path(from: beyond, to: destination).dropFirst()
    }

    private func nearestVisibleZombie(to position: CGPoint, within radius: Double) -> Zombie? {
        var best: Zombie?
        var bestDistance = radius * radius
        let low = cell(for: CGPoint(x: position.x - radius, y: position.y - radius))
        let high = cell(for: CGPoint(x: position.x + radius, y: position.y + radius))
        for x in low.x...high.x { for y in low.y...high.y {
            for index in zombieGrid[GridCell(x: x, y: y)] ?? [] where zombies[index].health > 0 {
                let candidate = squaredDistance(zombies[index].position, position)
                if candidate < bestDistance, hasLineOfSight(from: position, to: zombies[index].position) {
                    bestDistance = candidate; best = zombies[index]
                }
            }
        } }
        return best
    }

    private func nearestVisibleCivilian(to position: CGPoint, within radius: Double) -> Civilian? {
        var best: Civilian?
        var bestDistance = radius * radius
        for index in civilianNeighbors(near: position, radius: radius) {
            let candidate = squaredDistance(civilians[index].position, position)
            if candidate < bestDistance, hasLineOfSight(from: position, to: civilians[index].position),
               roadSegmentIsClear(from: position, to: civilians[index].position) {
                bestDistance = candidate; best = civilians[index]
            }
        }
        return best
    }

    /// Signage is learned locally. Information propagates through nearby people
    /// after a delay, using a snapshot so a single frame cannot inform the city.
    private func updateCivilianKnowledge(dt: Double) {
        guard elapsed >= nextSocialUpdate else { return }
        let interval = 0.35
        nextSocialUpdate = elapsed + interval
        let stations = units.filter { $0.kind == .evacuation && $0.health > 0 }
        let stationIDs = Set(stations.map(\.id))
        let snapshot = civilians
        for index in civilians.indices {
            let civilian = snapshot[index]
            if let known = civilian.evacuationID, !stationIDs.contains(known) {
                civilians[index].evacuationID = nil
                civilians[index].evacuationAwareness = 0
                civilians[index].evacuationLearnedFrom = nil
                civilians[index].followingID = nil
                civilianLearnedAt[civilian.id] = nil
                civilianInformAt[civilian.id] = nil
                civilianMotion[civilian.id] = nil
            }
            if civilians[index].evacuationID != nil { continue }
            if let station = stations.filter({ distance($0.position, civilian.position) < min($0.range, metersToWorld * 65) && hasLineOfSight(from: civilian.position, to: $0.position) }).min(by: { distance($0.position, civilian.position) < distance($1.position, civilian.position) }) {
                if civilianSeeingStation[civilian.id]?.stationID != station.id { civilianSeeingStation[civilian.id] = (station.id, elapsed) }
                let seenAt = civilianSeeingStation[civilian.id]?.since ?? elapsed
                civilians[index].evacuationAwareness = min(1, (elapsed - seenAt) / 1.4)
                if civilians[index].evacuationAwareness >= 1 {
                    civilians[index].evacuationID = station.id
                    civilianLearnedAt[civilian.id] = elapsed
                    civilianMotion[civilian.id] = nil
                }
            } else if let neighbor = civilianNeighbors(near: civilian.position, radius: metersToWorld * 12).filter({ $0 != index && snapshot[$0].evacuationID != nil && stationIDs.contains(snapshot[$0].evacuationID!) && elapsed - civilianLearnedAt[snapshot[$0].id, default: elapsed] > 1.2 && hasLineOfSight(from: civilian.position, to: snapshot[$0].position) }).min(by: { squaredDistance(snapshot[$0].position, civilian.position) < squaredDistance(snapshot[$1].position, civilian.position) }) {
                civilianSeeingStation[civilian.id] = nil
                let informAt = civilianInformAt[civilian.id] ?? elapsed
                civilianInformAt[civilian.id] = informAt
                civilians[index].followingID = snapshot[neighbor].id
                if elapsed - informAt > 1.0 + Double(civilian.id % 4) * 0.2 {
                    civilians[index].evacuationID = snapshot[neighbor].evacuationID
                    civilians[index].evacuationLearnedFrom = snapshot[neighbor].id
                    civilians[index].evacuationAwareness = 1
                    civilianLearnedAt[civilian.id] = elapsed
                    civilianMotion[civilian.id] = nil
                }
            } else {
                civilianInformAt[civilian.id] = nil
                civilianSeeingStation[civilian.id] = nil
                civilians[index].evacuationAwareness = max(0, civilians[index].evacuationAwareness - interval * 0.15)
            }
        }
    }

    private func moveCivilians(dt: Double) {
        let stations = Dictionary(uniqueKeysWithValues: units.filter { $0.kind == .evacuation && $0.health > 0 }.map { ($0.id, $0) })
        let intactZones = safeZones.filter { isSafeZoneIntact($0.id) }
        let zoneGates = units.filter { $0.kind == .gate && $0.health > 0 }
        let snapshot = civilians
        for index in civilians.indices {
            let id = civilians[index].id
            let position = civilians[index].position
            // Perception is staggered, rather than casting visibility rays for
            // every resident on every physics step. Hidden nearest bodies must
            // never suppress a second, genuinely visible threat.
            if elapsed >= civilianThreatChecks[id, default: 0] {
                let nextCheck = elapsed + 0.22 + movementVariation(id, salt: 31) * 0.12
                civilianThreatChecks[id] = nextCheck
                civilianThreats[id] = nearestVisibleZombie(to: position, within: metersToWorld * 65).map {
                    PerceivedThreat(position: $0.position)
                }
            }
            let threat = civilianThreats[id]?.position
            let fear = threat == nil ? 0.0 : 1.0
            civilians[index].panic += (fear - civilians[index].panic) * min(1, dt * (fear > 0 ? 3 : 0.5))
            let center = civilianRoutePositions[id] ?? map.nearestRoadPoint(to: position)
            var motion = civilianMotion[id]
            if let join = civilianRejoinCenters[id], let previous = motion {
                let recovery = roadRecoveryPoint(from: position, toward: join)
                civilianRejoinCenters[id] = recovery
                let recoveryTarget = max(metersToWorld * 1.3, min(metersToWorld * 5, civilians[index].speed))
                let recoverySpeed = CrowdMotion.speed(from:civilianForwardSpeeds[id,default:civilians[index].speed],toward:recoveryTarget,dt:dt,acceleration:metersToWorld*3,braking:metersToWorld*6)
                civilianForwardSpeeds[id] = recoverySpeed
                let next = boundedRoadStep(from: position, to: recovery, maximumStep: recoverySpeed * dt, rejoinPoint: recovery)
                let blocked = movementBlocked(from: position, to: next, forCivilians: true)
                guard !blocked && civilianGateAllows(id, from: position, to: next) else {
                    civilians[index].speed = 0
                    continue
                }
                let moved = distance(position, next)
                civilians[index].position = next
                civilians[index].speed = min(metersToWorld * 5, moved / dt)
                civilians[index].stride = (civilians[index].stride + moved / (metersToWorld * CrowdMotion.cycleLength(at: civilians[index].speed / metersToWorld)) * .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
                if moved > 0.000_001 {
                    let heading = atan2(next.y - position.y, next.x - position.x)
                    civilians[index].heading = CrowdMotion.heading(from: civilians[index].heading, toward: heading, dt: dt, rate: 5)
                }
                civilianLanes[id] = 0
                if distance(next, recovery) <= metersToWorld * 0.08 {
                    civilianRejoinCenters[id] = nil
                    civilianLaneRecoveryUntil[id] = elapsed + 1.5
                    civilianRoutePositions[id] = recovery
                    civilianMotion[id] = Motion(waypoints: map.path(from: recovery, to: previous.destination), reconsiderAt: previous.reconsiderAt, destination: previous.destination)
                }
                continue
            }
            if motion == nil || motion!.index >= motion!.waypoints.count || elapsed >= motion!.reconsiderAt {
                let neighbors = civilianNeighbors(near: position, radius: metersToWorld * 14).filter { $0 != index }
                if !intactZones.contains(where: { $0.id == civilianKnownZones[id] }) { civilianKnownZones[id] = nil }
                if civilianKnownZones[id] == nil {
                    if let nearby = intactZones.first(where: { zone in
                        zone.contains(position) || zoneGates.contains { gate in
                            zone.boundaryUnitIDs.contains(gate.linkedBarrierID ?? -1) && distance(position, gate.position) < metersToWorld * 65 && hasLineOfSight(from: position, to: gate.position)
                        }
                    }) { civilianKnownZones[id] = nearby.id }
                    else if let informed = neighbors.first(where: { civilianKnownZones[snapshot[$0].id] != nil && hasLineOfSight(from: position, to: snapshot[$0].position) }) {
                        civilianKnownZones[id] = civilianKnownZones[snapshot[informed].id]
                    }
                }
                let leader = neighbors.filter { snapshot[$0].panic > 0.3 || snapshot[$0].evacuationID != nil }.min { squaredDistance(snapshot[$0].position, position) < squaredDistance(snapshot[$1].position, position) }
                let destination: CGPoint
                if let threat, distance(threat, position) < metersToWorld * 16 {
                    destination = escapeDestination(from: center, threat: threat)
                } else if let known = civilians[index].evacuationID, let station = stations[known] {
                    destination = station.position
                } else if let zone = intactZones.first(where: { $0.id == civilianKnownZones[id] }) {
                    if zone.contains(position) {
                        // Protected residents mill about inside rather than all
                        // taking the same artificial point in the district.
                        let nearby = neighbors.map { snapshot[$0].position }.filter { zone.contains($0) }
                        destination = nearby.isEmpty ? center : nearby[id % nearby.count]
                    } else if let gate = zoneGates.filter({ zone.boundaryUnitIDs.contains($0.linkedBarrierID ?? -1) }).min(by: { distance($0.position, center) < distance($1.position, center) }) {
                        let centerOfZone = CGPoint(x: zone.points.reduce(0) { $0 + $1.x } / Double(zone.points.count), y: zone.points.reduce(0) { $0 + $1.y } / Double(zone.points.count))
                        let dx = centerOfZone.x - gate.position.x, dy = centerOfZone.y - gate.position.y, length = max(0.001, hypot(dx, dy))
                        destination = map.nearestRoadPoint(to: CGPoint(x: gate.position.x + dx / length * metersToWorld * 7,
                                                                       y: gate.position.y + dy / length * metersToWorld * 7))
                    } else { destination = wanderingDestination(from: position) }
                } else if let leader, hasLineOfSight(from: position, to: snapshot[leader].position) {
                    civilians[index].followingID = snapshot[leader].id
                    destination = civilianMotion[snapshot[leader].id]?.destination ?? snapshot[leader].position
                } else if let threat {
                    destination = escapeDestination(from: center, threat: threat)
                } else {
                    civilians[index].followingID = nil
                    destination = wanderingDestination(from: position)
                }
                motion = Motion(waypoints: map.path(from: center, to: destination), reconsiderAt: elapsed + (threat == nil ? 3 + Double(id % 5) * 0.7 : 0.7), destination: destination)
            }
            guard var nextMotion = motion else { continue }
            let desiredSpeed = metersToWorld * (civilians[index].exposure > 0.05 ? 1.1 : 1.3 + Double(id % 5) * 0.14 + civilians[index].panic * 3.3)
            let previousPace = civilianForwardSpeeds[id, default:civilians[index].speed]
            let pace = CrowdMotion.speed(from:previousPace,toward:desiredSpeed,dt:dt,acceleration:metersToWorld*3,braking:metersToWorld*6)
            civilianForwardSpeeds[id] = pace
            let direction = movementDirection(from: center, motion: nextMotion, fallback: civilians[index].heading)
            let neighbors = civilianNeighbors(near: position, radius: metersToWorld * 2.0)
            var separation = 0.0
            var forwardFactor = 1.0
            for other in neighbors where other != index {
                let dx = snapshot[other].position.x - position.x, dy = snapshot[other].position.y - position.y
                let along = cos(direction) * dx + sin(direction) * dy
                let across = -sin(direction) * dx + cos(direction) * dy
                let length = max(metersToWorld * 0.25, hypot(dx, dy))
                // Stable, different personal spaces prevent centerline stacks.
                separation -= across / (length * length) * metersToWorld * metersToWorld * 0.20
                if along > 0, abs(across) < metersToWorld * 0.48 {
                    forwardFactor = min(forwardFactor, max(0.20, (along / metersToWorld - 0.45) / 1.1))
                }
            }
            let laneLimit = max(0, map.streetWidth(at: center) * 0.32 - metersToWorld * 0.25)
            let gateApproach = zoneGates.contains { distance($0.position, center) < metersToWorld * 8 }
            let recoveringLane = elapsed < civilianLaneRecoveryUntil[id, default: 0]
            let preferredLane = gateApproach || recoveringLane ? 0 : (movementVariation(id, salt: 7) * 2 - 1) * laneLimit * 0.75
            let desiredLane = recoveringLane ? 0 : min(laneLimit, max(-laneLimit, preferredLane + separation))
            let previousLane = civilianLanes[id, default: 0]
            let lane = previousLane + (desiredLane - previousLane) * min(1, dt * 3.5)
            let nextCenter = advance(from: center, motion: &nextMotion, amount: pace * forwardFactor * dt)
            let roadHeading = distance(center, nextCenter) > 0.000_01 ? atan2(nextCenter.y - center.y, nextCenter.x - center.x) : direction
            let requested = CGPoint(x: nextCenter.x - sin(roadHeading) * lane, y: nextCenter.y + cos(roadHeading) * lane)
            let maxStep = metersToWorld * 5 * dt
            let directFraction = min(1, maxStep / max(0.000_001, distance(position, requested)))
            let direct = CGPoint(x: position.x + (requested.x - position.x) * directFraction, y: position.y + (requested.y - position.y) * directFraction)
            let directStepIsClear = roadSegmentIsClear(from: position, to: direct) && hasLineOfSight(from: position, to: direct)
            if !directStepIsClear {
                let preferred = roadSegmentIsClear(from: position, to: center) && hasLineOfSight(from: position, to: center) ? center : map.nearestRoadPoint(to: position)
                civilianRejoinCenters[id] = roadRecoveryPoint(from: position, toward: preferred)
                civilianMotion[id] = motion
            }
            let next = boundedRoadStep(from: position, to: requested, maximumStep: maxStep, rejoinPoint: civilianRejoinCenters[id], directIsClear: directStepIsClear)
            let blocked = movementBlocked(from: position, to: next, forCivilians: true)
            let gateAllows = !blocked && civilianGateAllows(id, from: position, to: next)
            if blocked {
                if elapsed >= civilianDetourChecks[id, default: 0], let gateRoute = civilianGateDetour(from: center, blockedAt: next, destination: nextMotion.destination) {
                    civilianMotion[id] = Motion(waypoints: gateRoute, reconsiderAt: elapsed + 6, destination: nextMotion.destination)
                    civilianDetourChecks[id] = elapsed + 2
                } else if elapsed >= civilianDetourChecks[id, default: 0], let known = civilians[index].evacuationID, let station = stations[known] {
                    // A blocked street chooses a neighboring intersection away
                    // from the wall; knowledge of the station is retained.
                    let detour = escapeDestination(from: center, threat: next)
                    civilianMotion[id] = Motion(waypoints: map.path(from: center, to: detour), reconsiderAt: elapsed + 2.5, destination: station.position)
                    civilianDetourChecks[id] = elapsed + 1.0
                }
                civilians[index].speed *= max(0, 1 - dt * 5)
                civilianForwardSpeeds[id] = civilians[index].speed
            } else if !gateAllows {
                civilians[index].speed *= max(0, 1 - dt * 5)
                civilianForwardSpeeds[id] = civilians[index].speed
            } else {
                civilians[index].position = next
                let moved = distance(position, next)
                civilians[index].speed = min(metersToWorld * 5, moved / dt)
                // Keep the graph cursor separate from the personal street lane.
                // A rejected corner step must not advance an invisible route.
                if moved > 0.000_01 && directStepIsClear {
                    civilianRoutePositions[id] = nextCenter
                    civilianLanes[id] = lane
                    civilianMotion[id] = nextMotion
                } else if distance(requested, position) < 0.000_01 {
                    civilianMotion[id] = nextMotion
                }
                if moved > 0.000_01 {
                    let heading = atan2(next.y - position.y, next.x - position.x)
                    civilians[index].heading = CrowdMotion.heading(from: civilians[index].heading, toward: heading, dt: dt, rate: 5)
                    civilians[index].stride = (civilians[index].stride + moved / (metersToWorld * CrowdMotion.cycleLength(at: civilians[index].speed / metersToWorld)) * .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
                }
            }
        }
        let civilianPositions = Dictionary(uniqueKeysWithValues: civilians.map { ($0.id, $0.position) })
        gatePasses = gatePasses.filter { id, pass in
            guard pass.expires > elapsed, let position = civilianPositions[id], let gate = units.first(where: { $0.id == pass.gateID }) else { return false }
            return distance(position, gate.position) < metersToWorld * 5
        }
        if simulationStepCount.isMultiple(of: 40) {
            let living = Set(civilians.map(\.id))
            civilianRoutePositions = civilianRoutePositions.filter { living.contains($0.key) }
            civilianLanes = civilianLanes.filter { living.contains($0.key) }
            civilianForwardSpeeds = civilianForwardSpeeds.filter { living.contains($0.key) }
            civilianRejoinCenters = civilianRejoinCenters.filter { living.contains($0.key) }
            civilianLaneRecoveryUntil = civilianLaneRecoveryUntil.filter { living.contains($0.key) && $0.value > elapsed }
            civilianThreats = civilianThreats.filter { living.contains($0.key) }
            civilianThreatChecks = civilianThreatChecks.filter { living.contains($0.key) }
            civilianDetourChecks = civilianDetourChecks.filter { living.contains($0.key) }
        }
    }

    private func moveZombies(dt: Double) {
        let groundIndices = units.indices.filter { units[$0].health > 0 && !units[$0].kind.isExplosive && units[$0].hostBuildingID == nil }
        let civilianByID = Dictionary(uniqueKeysWithValues: civilians.map { ($0.id, $0) })
        updateHerdRoutes()
        let snapshot = zombies
        for index in zombies.indices {
            guard zombies[index].health > 0 else { continue }
            let id = zombies[index].id
            if stunnedZombieIDs.contains(id) { zombies[index].speed = 0; zombieForwardSpeeds[id] = 0; continue }
            let position = zombies[index].position
            if let defender = groundIndices.min(by: { unitDistance(units[$0], to: position) < unitDistance(units[$1], to: position) }),
               unitDistance(units[defender], to: position) < metersToWorld * (units[defender].kind.isWall ? 3 : 2.5) &&
               hasLineOfSight(from: position, to: TacticalGeometry.nearestPoint(to: position, on: units[defender].barrierPath) ?? units[defender].position),
               units[defender].kind.isWall || !movementBlocked(from: position, to: units[defender].position) {
                units[defender].health -= dt * 5
                emitAudio(units[defender].kind.isWall ? .barrierHit : .zombieAttack, at: position, volume: 0.6, interval: 0.7)
                zombies[index].speed *= max(0, 1 - dt * 6)
                zombieForwardSpeeds[id] = zombies[index].speed
                continue
            }
            // Close, visible people can pull individual bodies out of a distant
            // shared route. This is straight local pursuit over open pavement;
            // it performs no per-person A* and cannot cut through a city block.
            if elapsed >= zombiePerceptionChecks[id, default: 0] {
                zombiePerceptionChecks[id] = elapsed + 0.35 + movementVariation(id, salt: 43) * 0.2
                let existing = zombiePursuits[id].flatMap { civilianByID[$0.civilianID] }
                let prey: Civilian?
                if let existing, distance(position, existing.position) < metersToWorld * 27,
                   hasLineOfSight(from: position, to: existing.position), roadSegmentIsClear(from: position, to: existing.position) {
                    prey = existing
                } else { prey = nearestVisibleCivilian(to: position, within: metersToWorld * 24) }
                if let prey { zombiePursuits[id] = LocalPursuit(civilianID: prey.id, position: prey.position) }
                else if zombiePursuits.removeValue(forKey: id) != nil { zombieMotion[id] = nil }
            }
            if let pursuit = zombiePursuits[id] {
                if let person = civilianByID[pursuit.civilianID] { zombiePursuits[id]?.position = person.position }
                else { zombiePursuits[id] = nil; zombieMotion[id] = nil }
            }
            if let join = zombieRejoinCenters[id] {
                let recoveryPace = CrowdMotion.speed(from:zombieForwardSpeeds[id,default:zombies[index].speed],toward:metersToWorld*4,dt:dt,acceleration:metersToWorld*5,braking:metersToWorld*8)
                zombieForwardSpeeds[id] = recoveryPace
                let maxStep = recoveryPace * dt
                let recovery = roadRecoveryPoint(from: position, toward: join)
                zombieRejoinCenters[id] = recovery
                let next = boundedRoadStep(from: position, to: recovery, maximumStep: maxStep, rejoinPoint: recovery)
                guard !movementBlocked(from: position, to: next) else {
                    zombies[index].speed = 0
                    zombieForwardSpeeds[id] = 0
                    continue
                }
                let moved = distance(position, next)
                zombies[index].position = next
                zombies[index].speed = moved / dt
                zombies[index].stride = (zombies[index].stride + moved / (metersToWorld * CrowdMotion.cycleLength(at: zombies[index].speed / metersToWorld)) * .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
                if moved > 0.000_001 {
                    let direction = atan2(next.y - position.y, next.x - position.x)
                    let oldHeading = zombies[index].heading
                    zombies[index].heading = CrowdMotion.heading(from:oldHeading,toward:direction,dt:dt,rate:5.5)
                    zombieHeadings[id] = zombies[index].heading
                }
                zombieLanes[id] = 0
                zombies[index].lateralOffset = 0
                if distance(next, recovery) <= metersToWorld * 0.08 {
                    zombieRejoinCenters[id] = nil
                    zombieLaneRecoveryUntil[id] = elapsed + 1.5
                    zombieRoutePositions[id] = recovery
                    zombieMotion[id] = nil
                }
                continue
            }
            guard var motion = zombieMotion[id] else { continue }
            let previousMotion = motion
            let center = zombieRoutePositions[id] ?? map.nearestRoadPoint(to: position)
            let personalRadius = metersToWorld * 2.3
            let neighbors = zombieNeighbors(near: position, radius: personalRadius, maximumCount: 24)
            var separation = 0.0
            var crowd = 0
            let heading = zombieHeadings[id, default: 0]
            var forwardFactor = 1.0
            var alignmentX = 0.0, alignmentY = 0.0, alignmentCount = 0
            var neighborLane = 0.0
            for other in neighbors where other != index {
                let dx = position.x - snapshot[other].position.x, dy = position.y - snapshot[other].position.y
                let length = max(metersToWorld * 0.35, hypot(dx, dy))
                separation += (-sin(heading) * dx + cos(heading) * dy) / (length * length) * metersToWorld * metersToWorld * 0.35
                if length < metersToWorld * 0.75 { crowd += 1 }
                let along = -(cos(heading) * dx + sin(heading) * dy)
                let across = -sin(heading) * dx + cos(heading) * dy
                if along > 0, abs(across) < metersToWorld * 0.55 {
                    forwardFactor = min(forwardFactor, max(0.08, (along / metersToWorld - 0.55) / 1.4))
                }
                if cos(snapshot[other].heading - heading) > 0.5 {
                    alignmentX += cos(snapshot[other].heading); alignmentY += sin(snapshot[other].heading); alignmentCount += 1
                    neighborLane += -sin(heading)*(snapshot[other].position.x-center.x) + cos(heading)*(snapshot[other].position.y-center.y)
                }
            }
            let phase = movementVariation(id, salt: 19) * .pi * 2
            let laneLimit = max(metersToWorld * 0.3, map.streetWidth(at: center) * 0.38)
            let pursuing = zombiePursuits[id]
            let recoveringLane = elapsed < zombieLaneRecoveryUntil[id, default: 0]
            // Broad streams share a gently changing pack direction. Local
            // separation keeps distinct bodies inside that stream, even in pursuit.
            let packPosition = Double(center.x + center.y) / (metersToWorld*28)
            let packPhase = elapsed*0.48 + Double(zombies[index].herdID%7)*0.9 + packPosition
            let packWave = sin(packPhase)
            let cohesionLane = alignmentCount > 0 ? neighborLane/Double(alignmentCount)*0.18 : 0
            let personalLane = (movementVariation(id,salt:11)*2-1)*laneLimit*0.72
            let preferredLane = recoveringLane ? 0 : (pursuing == nil ? personalLane + packWave*metersToWorld*0.25 + cohesionLane : personalLane*0.18)
            // A completed route must converge on its real destination instead
            // of leaving a stationary body several metres away in a wide lane.
            let destinationDistance = distance(center,pursuing?.position ?? motion.destination)
            let arrivalLaneScale = min(1,max(0,destinationDistance-metersToWorld*0.5)/(metersToWorld*6))
            let desiredLane = recoveringLane ? 0 : min(laneLimit,max(-laneLimit,(preferredLane+separation)*arrivalLaneScale))
            let occupiedLane = -sin(heading)*(position.x-center.x) + cos(heading)*(position.y-center.y)
            let oldLane = zombieLanes[id, default: occupiedLane]
            let maxLaneChange = max(metersToWorld*0.2,zombieForwardSpeeds[id,default:0]*0.45)*dt
            let lane = oldLane + min(max((desiredLane-oldLane)*min(1,dt*3),-maxLaneChange),maxLaneChange)
            let herdCenter = herds[zombies[index].herdID]?.center ?? center
            let cohesion = distance(center, herdCenter) > metersToWorld * 25 ? 1.12 : 1.0
            // Anticipate the next bend before accelerating into it. This uses
            // the existing shared path and does not add per-body route searches.
            let routeHeading = movementDirection(from:center,motion:motion,fallback:heading)
            let turnAngle = abs(atan2(sin(routeHeading-heading),cos(routeHeading-heading)))
            let bendPace = 0.48 + 0.52 * max(0,cos(min(.pi/2,turnAngle)))
            let surge = 1 + max(0,sin(elapsed*0.65+Double(zombies[index].herdID%7)))*0.12
            let desiredPace = metersToWorld*(CrowdMotion.infectedCruiseSpeed-0.8+movementVariation(id,salt:23)*1.6+sin(elapsed*0.43+phase)*0.3)*cohesion*surge*bendPace*forwardFactor/(1+Double(crowd)*0.08)
            let oldPace = zombieForwardSpeeds[id,default:zombies[index].speed]
            let pace = CrowdMotion.speed(from:oldPace,toward:desiredPace,dt:dt,acceleration:metersToWorld*5,braking:metersToWorld*8)
            zombieForwardSpeeds[id] = pace
            let travel = max(0,pace)*dt
            var nextCenter: CGPoint
            if let pursuing {
                let separation = distance(center, pursuing.position)
                let fraction = min(1, travel / max(0.000_01, separation))
                nextCenter = CGPoint(x: center.x + (pursuing.position.x - center.x) * fraction,
                                     y: center.y + (pursuing.position.y - center.y) * fraction)
            } else { nextCenter = advance(from: center, motion: &motion, amount: travel) }
            if !map.isRoad(nextCenter) { nextCenter = map.nearestRoadPoint(to: nextCenter) }
            let rawHeading = distance(center, nextCenter) > 0.001 ? atan2(nextCenter.y - center.y, nextCenter.x - center.x) : heading
            let neighborHeading = alignmentCount > 0 ? atan2(alignmentY, alignmentX) : rawHeading
            let alignmentDelta = atan2(sin(neighborHeading - rawHeading), cos(neighborHeading - rawHeading))
            let alignedHeading = rawHeading + max(-0.2, min(0.2, alignmentDelta)) * 0.15
            let smoothHeading = CrowdMotion.heading(from:heading,toward:alignedHeading,dt:dt,rate:5.5)
            zombieHeadings[id] = smoothHeading
            var next = CGPoint(x: nextCenter.x - sin(smoothHeading) * lane, y: nextCenter.y + cos(smoothHeading) * lane)
            if !map.isRoad(next) { next = nextCenter }
            // Narrowing streets and sharp turns must not snap a lane offset in one frame.
            // Recover toward the previous road center if a direct lateral transition crosses a corner.
            let separationToNext = distance(position, next)
            let maxStep = metersToWorld * 11 * dt
            if separationToNext > maxStep {
                let fraction = maxStep / separationToNext
                let smooth = CGPoint(x: position.x + (next.x - position.x) * fraction,
                                     y: position.y + (next.y - position.y) * fraction)
                if map.isRoad(smooth) {
                    next = smooth
                } else {
                    let recovery = map.nearestRoadPoint(to: position)
                    let recoveryDistance = distance(position, recovery)
                    let fraction = min(1, maxStep / max(0.001, recoveryDistance))
                    let safe = CGPoint(x: position.x + (recovery.x - position.x) * fraction,
                                       y: position.y + (recovery.y - position.y) * fraction)
                    next = map.isRoad(safe) ? safe : position
                    nextCenter = center
                    motion = zombieMotion[id] ?? motion
                }
            }
            let directStepIsClear = roadSegmentIsClear(from: position, to: next) && hasLineOfSight(from: position, to: next)
            if !directStepIsClear {
                // Contract on the street we actually occupy. Recovering toward
                // the next street's center would cut across the same building
                // corner again while an invisible cursor ran farther ahead.
                let join = roadSegmentIsClear(from: position, to: center) && hasLineOfSight(from: position, to: center) ? center : map.nearestRoadPoint(to: position)
                zombieRejoinCenters[id] = roadRecoveryPoint(from: position, toward: join)
            }
            next = boundedRoadStep(from: position, to: next, maximumStep: maxStep, rejoinPoint: zombieRejoinCenters[id], directIsClear: directStepIsClear)
            if movementBlocked(from: position, to: next) {
                if let barrier = groundIndices.first(where: { units[$0].kind == .barricade && unitDistance(units[$0], to: next) < metersToWorld * 3.5 }) {
                    units[barrier].health -= dt * 5
                    emitAudio(.barrierHit, at: next, volume: 0.65, interval: 0.7)
                }
                zombies[index].speed *= max(0, 1 - dt * 6)
            } else {
                let moved = distance(position, next)
                zombies[index].speed = moved / dt
                zombies[index].heading = smoothHeading
                zombies[index].stride = (zombies[index].stride + moved / (metersToWorld * CrowdMotion.cycleLength(at: zombies[index].speed / metersToWorld)) * .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
                zombies[index].position = next
                zombies[index].lateralOffset = lane
                zombieLanes[id] = lane
                if moved > 0.000_001 && directStepIsClear {
                    // The body crossed the proposed open-road segment. A
                    // stationary or recovering body never advances this cursor.
                    zombieRoutePositions[id] = nextCenter
                    zombieMotion[id] = motion
                } else if !directStepIsClear {
                    zombieRoutePositions[id] = center
                    zombieMotion[id] = previousMotion
                }
            }
        }
        if simulationStepCount.isMultiple(of: 40) {
            let living = Set(zombies.filter { $0.health > 0 }.map(\.id))
            zombieForwardSpeeds = zombieForwardSpeeds.filter { living.contains($0.key) }
            zombiePursuits = zombiePursuits.filter { living.contains($0.key) }
            zombiePerceptionChecks = zombiePerceptionChecks.filter { living.contains($0.key) }
            zombieRejoinCenters = zombieRejoinCenters.filter { living.contains($0.key) }
            zombieLaneRecoveryUntil = zombieLaneRecoveryUntil.filter { living.contains($0.key) && $0.value > elapsed }
        }
    }

    private func updateHerdRoutes() {
        var members: [Int: [Int]] = [:]
        for index in zombies.indices where zombies[index].health > 0 { members[zombies[index].herdID, default: []].append(index) }
        for herdID in members.keys.sorted() {
            guard let indices = members[herdID], let first = indices.first else { continue }
            if let state = herds[herdID], elapsed < state.reconsiderAt {
                var connections: [RouteConnectionKey: [CGPoint]] = [:]
                for index in indices where zombieMotion[zombies[index].id] == nil {
                    let id = zombies[index].id
                    let start = map.nearestRoadPoint(to: zombies[index].position)
                    zombieMotion[id] = splicedMotion(from: start, to: state.route, destination: state.destination, previous: nil, junctions: [:], connections: &connections)
                    zombieRoutePositions[id] = start
                }
                continue
            }
            let centroid = CGPoint(x: indices.reduce(0) { $0 + zombies[$1].position.x } / Double(indices.count),
                                   y: indices.reduce(0) { $0 + zombies[$1].position.y } / Double(indices.count))
            let leaderIndex = indices.min { squaredDistance(zombies[$0].position, centroid) < squaredDistance(zombies[$1].position, centroid) } ?? first
            let center = zombieRoutePositions[zombies[leaderIndex].id] ?? map.nearestRoadPoint(to: zombies[leaderIndex].position)
            herdRouteRevision += 1
            let arrival = arrivals.first { $0.id == herdID }
            if let arrival, elapsed < arrival.arrivesAt, let route = arrivalRoutes[herdID] {
                herds[herdID] = HerdState(center: center, destination: route.last ?? arrival.position, reconsiderAt: min(arrival.arrivesAt, elapsed + 6), route: route)
                let junctions = routeJunctions(route)
                var connections: [RouteConnectionKey: [CGPoint]] = [:]
                for index in indices {
                    let id = zombies[index].id
                    if zombiePursuits[id] != nil { continue }
                    let start = zombieRoutePositions[id] ?? map.nearestRoadPoint(to: zombies[index].position)
                    zombieMotion[id] = splicedMotion(from: start, to: route, destination: route.last ?? arrival.position, previous: zombieMotion[id], junctions: junctions, connections: &connections)
                    zombieRoutePositions[id] = start
                }
                continue
            }
            let destination = nearestCivilian(to: center)?.position ?? units.min { distance($0.position, center) < distance($1.position, center) }?.position ?? wanderingDestination(from: center)
            let route = map.path(from: center, to: destination)
            herds[herdID] = HerdState(center: center, destination: destination, reconsiderAt: elapsed + 3.2 + Double(herdID % 4) * 0.4, route: route)
            // Tail members retain their valid street path until a shared junction.
            // At most one A* connection per distinct branch is needed on refresh.
            let junctions = routeJunctions(route)
            var connections: [RouteConnectionKey: [CGPoint]] = [:]
            for index in indices {
                let id = zombies[index].id
                if zombiePursuits[id] != nil { continue }
                let start = zombieRoutePositions[id] ?? map.nearestRoadPoint(to: zombies[index].position)
                zombieMotion[id] = splicedMotion(from: start, to: route, destination: destination, previous: zombieMotion[id], junctions: junctions, connections: &connections)
                zombieRoutePositions[id] = start
            }
        }
        herds = herds.filter { members[$0.key] != nil }
    }

    private struct RoutePoint: Hashable {
        let x: Int
        let y: Int
        init(_ point: CGPoint) {
            x = Int((point.x * 1000).rounded())
            y = Int((point.y * 1000).rounded())
        }
    }

    private struct RouteConnectionKey: Hashable {
        let from: RoutePoint
        let to: RoutePoint
    }

    private func routeJunctions(_ route: [CGPoint]) -> [RoutePoint: Int] {
        var result: [RoutePoint: Int] = [:]
        for (index, point) in route.enumerated() where result[RoutePoint(point)] == nil { result[RoutePoint(point)] = index }
        return result
    }

    private func joinedMotion(from start: CGPoint, to route: [CGPoint], destination: CGPoint) -> Motion {
        var connections: [RouteConnectionKey: [CGPoint]] = [:]
        return splicedMotion(from: start, to: route, destination: destination, previous: nil, junctions: [:], connections: &connections)
    }

    private func splicedMotion(from start: CGPoint, to route: [CGPoint], destination: CGPoint, previous: Motion?, junctions: [RoutePoint: Int], connections: inout [RouteConnectionKey: [CGPoint]]) -> Motion {
        if let previous, previous.index < previous.waypoints.count {
            for index in previous.index..<previous.waypoints.count {
                if let junction = junctions[RoutePoint(previous.waypoints[index])] {
                    let prefix = Array(previous.waypoints[previous.index...index])
                    return Motion(waypoints: prefix + route.dropFirst(junction + 1), destination: destination)
                }
            }
        }
        let segment = nearestSegment(to: start, on: route)
        let suffix = Array(route.dropFirst(min(route.count, segment + 1)))
        guard let join = suffix.first else { return Motion(waypoints: [start], destination: destination) }
        if let previous, previous.index < previous.waypoints.count {
            let anchor = previous.waypoints[previous.index]
            let key = RouteConnectionKey(from: RoutePoint(anchor), to: RoutePoint(join))
            let connection: [CGPoint]
            if let cached = connections[key] { connection = cached }
            else {
                connection = map.path(from: anchor, to: join)
                connections[key] = connection
                herdConnectionSearches += 1
            }
            return Motion(waypoints: [anchor] + connection + suffix.dropFirst(), destination: destination)
        }
        let count = max(1, Int(ceil(distance(start, join) / 1.5)))
        let visible = (0...count).allSatisfy { sample in
            let fraction = Double(sample) / Double(count)
            return map.isRoad(CGPoint(x: start.x + (join.x - start.x) * fraction,
                                      y: start.y + (join.y - start.y) * fraction))
        }
        let connection: [CGPoint]
        if visible { connection = [start, join] }
        else { connection = map.path(from: start, to: join); herdConnectionSearches += 1 }
        return Motion(waypoints: connection + suffix.dropFirst(), destination: destination)
    }

    private func nearestSegment(to point: CGPoint, on route: [CGPoint]) -> Int {
        guard route.count > 1 else { return 0 }
        var best = 0, bestDistance = Double.infinity
        for index in 0..<(route.count - 1) {
            let a = route[index], b = route[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.001, dx * dx + dy * dy)))
            let projected = CGPoint(x: a.x + dx * fraction, y: a.y + dy * fraction)
            let candidate = squaredDistance(point, projected)
            if candidate < bestDistance { best = index; bestDistance = candidate }
        }
        return best
    }

    private func zombieNeighbors(near point: CGPoint, radius: Double, maximumCount: Int? = nil) -> [Int] {
        let local = radius <= metersToWorld * 4
        let bucketSize = local ? zombieCellSize : gridSize
        let grid = local ? flockGrid : zombieGrid
        let low = GridCell(x: Int(floor((point.x - radius) / bucketSize)), y: Int(floor((point.y - radius) / bucketSize)))
        let high = GridCell(x: Int(floor((point.x + radius) / bucketSize)), y: Int(floor((point.y + radius) / bucketSize)))
        var result: [Int] = []
        result.reserveCapacity(maximumCount ?? 32)
        for x in low.x...high.x { for y in low.y...high.y {
            for index in grid[GridCell(x: x, y: y)] ?? [] where zombies[index].health > 0 {
                if squaredDistance(zombies[index].position, point) < radius * radius {
                    result.append(index)
                    if let maximumCount, result.count >= maximumCount { return result }
                }
            }
        } }
        return result
    }

    private func fireDefenses(dt: Double) {
        for index in units.indices {
            guard units[index].health > 0, units[index].kind.isCombat else { continue }
            units[index].cooldown -= dt
            guard units[index].cooldown <= 0 else { continue }
            let unit = units[index]
            let resident = recruitedCivilians[unit.id] != nil
            var launch = unit.position
            if unit.kind == .squad, !unit.formation.isEmpty {
                launch = unit.formation[squadFireIndex[unit.id, default: 0] % unit.formation.count]
            } else if unit.kind == .sniper, let sniper = unit.formation.first { launch = sniper }
            func canEngage(_ target: Int) -> Bool {
                zombies[target].health > 0 && distance(zombies[target].position, unit.position) <= unit.range &&
                (unit.kind == .mortar ? distance(zombies[target].position, unit.position) > 42 : defenseHasLineOfSight(unit, from: launch, to: zombies[target].position))
            }
            var targetIndex = defenseTargetIDs[unit.id].flatMap { id in zombies.firstIndex(where: { $0.id == id }) }.flatMap { canEngage($0) ? $0 : nil }
            if targetIndex == nil {
                let candidates = zombieNeighbors(near: unit.position, radius: unit.range)
                let ordered = candidates.sorted { squaredDistance(zombies[$0].position, unit.position) < squaredDistance(zombies[$1].position, unit.position) }
                // Recheck the nearest 24 plus a rotating window through EVERY
                // remaining candidate. Dense occluded bodies cannot permanently
                // hide a farther visible target, and each pass remains bounded.
                let nearby = min(24, ordered.count), tailCount = ordered.count - nearby
                let offset = defenseSearchOffsets[unit.id, default: 0]
                var search = Array(ordered.prefix(nearby))
                if tailCount > 0 {
                    for step in 0..<min(104, tailCount) { search.append(ordered[nearby + (offset + step) % tailCount]) }
                    defenseSearchOffsets[unit.id] = (offset + min(104, tailCount)) % tailCount
                }
                targetIndex = search.first(where: canEngage)
            }
            guard let targetIndex else { defenseTargetIDs[unit.id] = nil; continue }
            defenseTargetIDs[unit.id] = zombies[targetIndex].id
            let target = zombies[targetIndex].position
            units[index].turretHeading = atan2(target.y - unit.position.y, target.x - unit.position.x)
            let strengthFactor = unit.kind.hasHumanCrew && !resident ? Double(unit.kind == .squad ? 5 : 2) / Double(max(1, crewCount(for: unit.id))) : 1
            units[index].cooldown = unit.kind.reloadTime * (resident ? 2 : 1) * strengthFactor / (1 + Double(upgradeLevels[unit.kind, default: 0]) * 0.08)
            if unit.kind == .mortar {
                let duration = max(1.2, min(3.0, distance(unit.position, target) / 110))
                let heading = zombieHeadings[zombies[targetIndex].id, default: 0]
                let predicted = clamped(CGPoint(x: target.x + cos(heading) * duration * zombies[targetIndex].speed,
                                               y: target.y + sin(heading) * duration * zombies[targetIndex].speed))
                projectiles.append(CombatProjectile(id: allocateID(), kind: .mortar, launch: unit.position, target: predicted, duration: duration, arcHeight: 80 + distance(unit.position, target) * 0.2, radius: 49, damage: upgradedDamage(unit.kind), civilianRadius: 25))
                emitAudio(.mortarLaunch, at: unit.position, volume: 0.8, interval: 0.1)
            } else {
                if unit.kind == .squad, !unit.formation.isEmpty {
                    let soldier = squadFireIndex[unit.id, default: 0] % unit.formation.count
                    launch = unit.formation[soldier]
                    squadFireIndex[unit.id] = soldier + 1
                    // Infantry shoot individually; movement and crowding lower their accuracy.
                    let accuracy = resident ? 0.55 : (unitMotion[unit.id] == nil ? 0.80 : 0.52)
                    if random.double(in: 0...1) <= accuracy { zombies[targetIndex].health -= upgradedDamage(unit.kind) * (resident ? 0.55 : 1) }
                    emitAudio(.rifle, at: launch, volume: 0.6, interval: 0.08, variant: unit.soundVariant, sourceID: unit.id)
                } else {
                    zombies[targetIndex].health -= upgradedDamage(unit.kind)
                    emitAudio(unit.kind == .sniper ? .sniper : .heavyGun, at: launch, volume: unit.kind == .sniper ? 0.82 : 0.75, interval: 0.07, variant: unit.soundVariant, sourceID: unit.id)
                }
                effects.append(CombatEffect(id: allocateID(), position: launch, endPosition: target, kind: .shot, age: 0, duration: 0.14, radius: unit.kind == .humvee ? 1.7 : 1, altitude: unit.elevation + 0.31 + metersToWorld * (unit.kind == .humvee ? 2.14 : (unit.kind == .sniper ? 0.80 : 1.14))))
            }
        }
    }

    private func sniperHostBuilding(at requested: CGPoint) -> Int? {
        map.buildingIndices(near: requested, radius: 0).first { !destroyedBuildingIDs.contains($0) }
    }

    private func sniperRoofPosition(_ index: Int) -> CGPoint {
        let building = map.buildings[index], rect = building.rect
        var furniture: [CGRect] = []
        if rect.width > 10 && rect.height > 10 {
            let width = min(6, rect.width * 0.22), depth = min(6, rect.height * 0.22)
            furniture.append(CGRect(x: rect.midX - width / 2, y: rect.midY - depth / 2, width: width, height: depth).insetBy(dx: -metersToWorld, dy: -metersToWorld))
            if rect.width > 30 { furniture.append(CGRect(x: rect.midX + rect.width * 0.25 - 2.5, y: rect.midY - 2.5, width: 5, height: 5).insetBy(dx: -metersToWorld, dy: -metersToWorld)) }
        }
        let fractions = [0.5, 0.22, 0.78, 0.35, 0.65, 0.12, 0.88]
        for y in fractions { for x in fractions {
            let center = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            let bodies = [CGPoint(x: center.x - metersToWorld * 0.4, y: center.y), CGPoint(x: center.x + metersToWorld * 0.4, y: center.y)]
            if bodies.allSatisfy({ body in TacticalGeometry.contains(body, in: building.footprint) && !furniture.contains(where: { $0.contains(body) }) }) {
                return center
            }
        } }
        // Tiny or unusually concave roofs may have no furnished two-body bay;
        // fall back to a verified interior point, never the bounding box outside.
        for y in fractions { for x in fractions {
            let point = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            if TacticalGeometry.contains(point, in: building.footprint) { return point }
        } }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func sniperPlacementCost(at requested: CGPoint) -> Int {
        guard let index = sniperHostBuilding(at: requested) else { return UnitKind.sniper.cost }
        let building = map.buildings[index]
        let area = Double(building.rect.width * building.rect.height) / (metersToWorld * metersToWorld)
        // Larger properties cost more to secure, capped so landmark-scale blocks
        // cannot silently consume an entire mission's allocation.
        return UnitKind.sniper.cost + min(200, Int(sqrt(max(1, area)) * 1.3 / 10) * 10)
    }

    func defenseHasLineOfSight(_ unit: DefenseUnit, from start: CGPoint, to end: CGPoint) -> Bool {
        guard let host = unit.hostBuildingID, unit.elevation > 0 else { return hasLineOfSight(from: start, to: end) }
        guard !destroyedBuildingIDs.contains(host) else { return false }
        let startHeight = unit.elevation + metersToWorld * 1.2, endHeight = metersToWorld * 1.2
        let length = max(0.0001, distance(start, end))
        func blocks(_ polygon: [CGPoint], height: Double) -> Bool {
            let hits = zip(polygon, polygon.dropFirst() + [polygon[0]]).compactMap { TacticalGeometry.intersection(start, end, $0.0, $0.1) }
            if TacticalGeometry.contains(end, in: polygon), height > endHeight { return true }
            // The descending ray is lowest at the far edge of an obstruction.
            return hits.contains { point in
                let fraction = distance(start, point) / length
                return height > startHeight + (endHeight - startHeight) * fraction
            }
        }
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        for index in map.buildingIndices(near: middle, radius: length / 2) where index != host && !destroyedBuildingIDs.contains(index) {
            if blocks(map.buildings[index].footprint, height: map.buildings[index].height) { return false }
        }
        for index in map.landmarks.indices where !destroyedLandmarkIDs.contains(index) {
            let landmark = map.landmarks[index]
            if landmark.kind != .mohammedSquare && landmark.kind != .port,
               blocks(map.landmarkFootprint(at: index), height: landmark.height) { return false }
        }
        return true
    }

    private func appendInfected(_ infected: Zombie) {
        if zombies.count < activeZombieLimit { zombies.append(infected) }
        else {
            pendingInfections[infected.id] = infected
            stagedHerdMembers.append(StagedHerdMember(id: infected.id, herdID: infected.herdID, position: infected.position, heading: infected.heading, routePosition: infected.position, lateralOffset: 0))
            stagingRevision += 1
        }
    }

    private func updateInfantryInfection(dt: Double) {
        var conversions: [Zombie] = []
        for index in units.indices where units[index].health > 0 && units[index].kind.hasHumanCrew && units[index].hostBuildingID == nil {
            let unit = units[index]
            let bodies = unit.formation.isEmpty ? [unit.position] : unit.formation
            let bite = bodies.compactMap { point -> (CGPoint, Zombie)? in
                guard let attacker = infectiousZombie(near: point, radius: metersToWorld * 1.6) else { return nil }
                return (point, attacker)
            }.first
            troopExposure[unit.id, default: 0] = bite == nil ? max(0, troopExposure[unit.id, default: 0] - dt * 0.8) : troopExposure[unit.id, default: 0] + dt
            guard let (point, attacker) = bite, troopExposure[unit.id, default: 0] >= GameBalance.infectionContactTime else { continue }
            troopExposure[unit.id] = 0
            let remaining = max(0, crewCount(for: unit.id) - 1)
            if var recruited = recruitedCivilians[unit.id], !recruited.isEmpty {
                recruited.removeFirst()
                recruitedCivilians[unit.id] = recruited
                casualties += 1
                recordTacticalMarker(.casualty, at: point)
            }
            units[index].crewRemaining = remaining
            units[index].health = remaining == 0 ? 0 : min(units[index].health, units[index].maxHealth * Double(remaining) / Double(unit.kind == .squad ? 5 : 2))
            conversions.append(Zombie(id: allocateID(), position: point, health: 55, infectiousAt: elapsed + GameBalance.infectionIncubation, herdID: attacker.herdID))
            updateFormation(at: index)
            setNotice("\(unit.kind.shortTitle) bitten: one defender infected. Pull the remaining team back.", duration: 4)
        }
        for infected in conversions { appendInfected(infected) }
    }

    private func updatePlantedExplosives(dt: Double) {
        var triggered: [DefenseUnit] = []
        for index in units.indices where units[index].kind.isExplosive && units[index].health > 0 {
            units[index].cooldown = max(0, units[index].cooldown - dt)
            if units[index].kind == .mine && units[index].cooldown <= 0,
               let trigger = nearestVisibleZombie(to: units[index].position, within: metersToWorld * 4),
               !movementBlocked(from: units[index].position, to: trigger.position) {
                triggered.append(units[index])
            }
        }
        guard !triggered.isEmpty else { return }
        let triggeredIDs = Set(triggered.map(\.id))
        units.removeAll { triggeredIDs.contains($0.id) }
        if let selectedUnitID, triggeredIDs.contains(selectedUnitID) { self.selectedUnitID = nil }
        for mine in triggered {
            applyExplosion(at: mine.position, radius: metersToWorld * 30, damage: mine.kind.damage, civilianRadius: metersToWorld * 18)
        }
    }

    private func recordTacticalMarker(_ kind: TacticalMarkerKind, at position: CGPoint, count: Int = 1) {
        if let index = tacticalMarkers.lastIndex(where: { $0.kind == kind && distance($0.position, position) < metersToWorld * 14 }) {
            tacticalMarkers[index].count += count
        } else {
            tacticalMarkers.append(TacticalMarker(id: allocateID(), kind: kind, position: position, elapsed: elapsed, count: count))
            if tacticalMarkers.count > 96 { tacticalMarkers.removeFirst(tacticalMarkers.count - 96) }
        }
    }

    private func makeArrivalSchedule() {
        let approaches = map.herdApproaches
        let count = city == .casablanca ? 6 : 4
        var departure = random.double(in: 20...35)
        var previousEntry = -1
        var previousETA = 0.0
        for wave in 0..<count {
            var chosen = random.index(count: approaches.count)
            if chosen == previousEntry, approaches.count > 1 { chosen = (chosen + 1) % approaches.count }
            previousEntry = chosen
            let approach = approaches.isEmpty ? HerdApproach(source: map.nearestRoadPoint(to: map.initialFocus), ingress: map.nearestRoadPoint(to: map.initialFocus), route: [map.nearestRoadPoint(to: map.initialFocus)], approachDistance: 1) : approaches[chosen]
            let position = approach.ingress
            let angle = atan2(position.y - map.initialFocus.y, position.x - map.initialFocus.x)
            let names = ["EAST", "SOUTHEAST", "SOUTH", "SOUTHWEST", "WEST", "NORTHWEST", "NORTH", "NORTHEAST"]
            let sector = (Int((angle / (.pi / 4)).rounded()) + 8) % 8
            let size = min(2_000, 560 + wave * 270 + random.index(count: 101))
            // The head is already assembled on the rural approach. Its ETA uses
            // the remaining road distance rather than pretending it starts at a point.
            let stagingLength = min(approach.approachDistance * 0.65, metersToWorld * 220)
            let travel = max(metersToWorld * 15, approach.approachDistance - stagingLength) / (metersToWorld * CrowdMotion.infectedCruiseSpeed)
            // Spacing applies between herds; applying it to wave zero would
            // silently extend its randomized 20–35 s preparation window.
            let arrivalTime = max(wave == 0 ? 0 : previousETA + 45, departure + travel + 2)
            departure = arrivalTime - travel - 2
            let id = allocateID()
            arrivals.append(HerdArrival(id: id, position: position, arrivesAt: arrivalTime, size: size, direction: names[sector], sourcePosition: approach.source, departureAt: departure, travelDistance: approach.approachDistance, releaseDuration: 0.2, stagingLength: stagingLength))
            arrivalRoutes[id] = approach.route
            previousETA = arrivalTime
            departure += random.double(in: 72...90)
        }
        herdPopulationTotal = arrivals.reduce(0) { $0 + $1.size }
    }

    /// Build every planned body once, over a long connected exterior road corridor.
    /// Jittered rows fill the road width; no per-person route search is performed.
    private func assembleExteriorColumns() {
        for arrival in arrivals {
            let route = arrivalRoutes[arrival.id] ?? [arrival.sourcePosition, arrival.position]
            var cumulative: [Double] = [0]
            for (a, b) in zip(route, route.dropFirst()) { cumulative.append(cumulative.last! + distance(a, b)) }
            var members: [StagedHerdMember] = []
            members.reserveCapacity(arrival.size)
            for sequence in 0..<arrival.size {
                let progress = arrival.size > 1 ? Double(sequence) / Double(arrival.size - 1) : 0
                let along = max(0, arrival.stagingLength * (1 - progress) + random.double(in: -0.3...0.3) * metersToWorld)
                var low = 0, high = max(0, route.count - 1)
                while low < high {
                    let middle = (low + high + 1) / 2
                    if cumulative[middle] <= along { low = middle } else { high = middle - 1 }
                }
                let segment = min(low, max(0, route.count - 2))
                let a = route[segment], b = route[min(route.count - 1, segment + 1)]
                let length = max(0.001, distance(a, b))
                let fraction = min(1, max(0, (along - cumulative[segment]) / length))
                let center = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
                let heading = atan2(b.y - a.y, b.x - a.x)
                let halfWidth = max(metersToWorld * 0.4, map.streetWidth(at: center) * 0.38)
                let lane = random.double(in: -halfWidth...halfWidth)
                let requested = CGPoint(x: center.x - sin(heading) * lane, y: center.y + cos(heading) * lane)
                let safeLane = map.isRoad(requested) && !map.containsBuilding(requested) ? lane : 0
                let point = CGPoint(x: center.x - sin(heading) * safeLane, y: center.y + cos(heading) * safeLane)
                members.append(StagedHerdMember(id: allocateID(), herdID: arrival.id, position: point, heading: heading, routePosition: center, lateralOffset: safeLane))
            }
            stagedColumns[arrival.id] = members
            stagedHerdMembers.append(contentsOf: members)
        }
        stagingRevision += 1
    }

    private func spawnArrivingHerds() {
        let releaseNow = elapsed >= nextHerdReleaseAt
        if releaseNow { nextHerdReleaseAt = elapsed + 0.2 }
        var activatedIDs: Set<Int> = []
        if releaseNow {
            for id in pendingInfections.keys.sorted() where zombies.count < activeZombieLimit {
                guard var infected = pendingInfections.removeValue(forKey: id) else { continue }
                infected.health -= stagedDamage[id, default: 0]
                stagedDamage[id] = nil
                zombies.append(infected)
                previousRenderMotion[id] = RenderMotionState(position: infected.position, heading: infected.heading,
                                                             stride: infected.stride, speed: infected.speed)
                activatedIDs.insert(id)
            }
        }
        for index in arrivals.indices {
            let arrival = arrivals[index]
            let remaining = arrival.arrivesAt - elapsed
            if remaining <= 10, !warnedArrivals.contains(arrival.id) {
                warnedArrivals.insert(arrival.id)
                emitAudio(.warningAlarm, at: arrival.position, volume: 0.8)
                setNotice("\(arrival.direction) surge approaching · \(Int(ceil(max(0, remaining))))s · \(arrival.size) infected.", duration: 5)
            }
            if !arrival.spawned && remaining <= 0 {
                arrivals[index].spawned = true
                emitAudio(.herdArrival, at: arrival.position, volume: 0.85)
                setNotice("\(arrival.direction) mass entering the city · \(arrival.size) infected.", duration: 6)
            }
            guard releaseNow, elapsed >= arrival.departureAt, arrival.releasedCount < arrival.size,
                  let members = stagedColumns[arrival.id] else { continue }
            var cursor = arrival.releasedCount
            var newlyActive = 0
            while cursor < members.count {
                let member = members[cursor]
                if neutralizedStagedIDs.contains(member.id) { cursor += 1; continue }
                guard zombies.count < activeZombieLimit else { break }
                zombies.append(Zombie(id: member.id, position: member.position, health: 60 - stagedDamage[member.id, default: 0], herdID: arrival.id, lateralOffset: member.lateralOffset, heading: member.heading, stride: (elapsed*0.9).truncatingRemainder(dividingBy:.pi*2)))
                // This person was already visible in the exterior mass. Seed
                // their display history at that exact point so activation does
                // not skip the first frame of actual road movement.
                previousRenderMotion[member.id] = RenderMotionState(position: member.position, heading: member.heading, stride: (elapsed*0.9).truncatingRemainder(dividingBy:.pi*2))
                zombieRoutePositions[member.id] = member.routePosition
                zombieLanes[member.id] = member.lateralOffset
                zombieHeadings[member.id] = member.heading
                let route = arrivalRoutes[arrival.id] ?? [arrival.sourcePosition, arrival.position]
                let segment = nearestSegment(to: member.routePosition, on: route)
                zombieMotion[member.id] = Motion(waypoints: Array(route.dropFirst(min(route.count, segment + 1))), destination: route.last ?? arrival.position)
                stagedDamage[member.id] = nil
                activatedIDs.insert(member.id)
                cursor += 1
                newlyActive += 1
            }
            arrivals[index].releasedCount = cursor
            if arrival.releasedCount == 0 && newlyActive > 0 {
                emitAudio(.herdArrival, at: arrival.sourcePosition, volume: 0.65)
                setNotice("\(arrival.direction) exterior mass moving · \(arrival.size) infected. Follow the red approach marker.", duration: 6)
            }
        }
        if !activatedIDs.isEmpty {
            stagedHerdMembers.removeAll { activatedIDs.contains($0.id) }
            stagingRevision += 1
        }
    }

    private func callAircraft(_ kind: UnitKind, at target: CGPoint) {
        let id = allocateID()
        let dx = cos(attackHeading), dy = sin(attackHeading)
        let span = kind == .ac130 ? 320.0 : 950.0
        let start = CGPoint(x: target.x - dx * span, y: target.y - dy * span)
        let end = CGPoint(x: target.x + dx * span, y: target.y + dy * span)
        let duration: Double = kind == .ac130 ? 46 : (kind == .b2 ? 11 : 12)
        let ammo = kind == .ac130 ? 180 : (kind == .b2 ? 4 : 540)
        flights.append(AircraftFlight(id: id, kind: kind, position: start, altitude: kind == .ac130 ? 140 : (kind == .b2 ? 85 : 70), heading: attackHeading, duration: duration, target: target, start: start, end: end, ammo: ammo, weaponMode: ac130WeaponMode))
        sortieCounts[kind, default: 0] += 1
        nextSortieAt[kind] = elapsed + duration + (kind == .ac130 ? 50 : 35)
        flightFireAt[id] = elapsed + (kind == .ac130 ? 4 : duration * 0.37)
        flightBombsReleased[id] = 0
        emitAudio(.aircraftApproach, at: start, volume: 0.8)
        setNotice("\(kind.shortTitle) inbound. \(sortiesRemaining(kind)) sorties remain · keep civilians clear.", duration: 6)
    }

    private func updateAircraft(dt: Double) {
        for index in flights.indices {
            flights[index].age += dt
            let flight = flights[index]
            let progress = flight.progress
            if flight.kind == .ac130 {
                let launchHeading = atan2(flight.end.y - flight.start.y, flight.end.x - flight.start.x)
                let angle = -(flight.age - 4) * 0.21 + launchHeading
                let radius = 230.0
                let orbitPosition = CGPoint(x: flight.target.x + cos(angle) * radius, y: flight.target.y + sin(angle) * radius)
                if flight.age < 4 {
                    let approach = flight.age / 4
                    flights[index].position = CGPoint(x: flight.start.x + (orbitPosition.x - flight.start.x) * approach,
                                                       y: flight.start.y + (orbitPosition.y - flight.start.y) * approach)
                    flights[index].heading = atan2(orbitPosition.y - flight.start.y, orbitPosition.x - flight.start.x)
                } else {
                    let current = flights[index].position
                    // Retargeting changes the orbit smoothly instead of teleporting the aircraft.
                    let vector = distance(current, orbitPosition)
                    let fraction = min(1, 105 * dt / max(0.001, vector))
                    flights[index].position = CGPoint(x: current.x + (orbitPosition.x - current.x) * fraction,
                                                       y: current.y + (orbitPosition.y - current.y) * fraction)
                    flights[index].heading = angle - .pi / 2
                }
                flights[index].altitude = 140 + sin(flight.age * 0.35) * 8
                emitAudio(.ac130Engine, at: flights[index].position, volume: 0.45, interval: 2.8)
                if flight.age >= 4, flight.age < flight.duration - 4, flight.ammo > 0, elapsed >= flightFireAt[flight.id, default: 0] {
                    fireAC130(at: index)
                }
            } else {
                let x = flight.start.x + (flight.end.x - flight.start.x) * progress
                let y = flight.start.y + (flight.end.y - flight.start.y) * progress
                flights[index].position = CGPoint(x: x, y: y)
                flights[index].altitude = (flight.kind == .b2 ? 85 : 70) + cos(progress * .pi * 2) * 16
                emitAudio(flight.kind == .b2 ? .b2Engine : .a10Engine, at: flights[index].position, volume: 0.7, interval: 1.6)
                if flight.kind == .b2 { dropB2Bombs(at: index) }
                else if progress >= 0.37, progress <= 0.67, flight.ammo > 0, elapsed >= flightFireAt[flight.id, default: 0] { fireA10(at: index) }
            }
        }
        let finished = flights.filter { $0.age >= $0.duration }
        flights.removeAll { $0.age >= $0.duration }
        for flight in finished { flightFireAt[flight.id] = nil; flightBombsReleased[flight.id] = nil }
    }

    private func fireAC130(at index: Int) {
        let flight = flights[index]
        let candidates = zombieNeighbors(near: flight.target, radius: upgradedRange(.ac130)).filter {
            let dx = zombies[$0].position.x - flight.position.x
            let dy = zombies[$0].position.y - flight.position.y
            return dx * sin(flight.heading) - dy * cos(flight.heading) > 0
        }
        guard !candidates.isEmpty else { flightFireAt[flight.id] = elapsed + 0.3; return }
        // The 105 mm mode chooses a dense group; 30 mm picks individual threats in the orbit.
        let targetIndex: Int
        if flight.weaponMode == .cannon105 {
            targetIndex = candidates.prefix(30).max { zombieNeighbors(near: zombies[$0].position, radius: 45).count < zombieNeighbors(near: zombies[$1].position, radius: 45).count } ?? candidates[0]
        } else {
            targetIndex = candidates.min { squaredDistance(zombies[$0].position, flight.target) < squaredDistance(zombies[$1].position, flight.target) } ?? candidates[0]
        }
        let target = zombies[targetIndex].position
        let portGun = CGPoint(x: flight.position.x + sin(flight.heading) * 9,
                              y: flight.position.y - cos(flight.heading) * 9)
        if flight.weaponMode == .cannon105 {
            guard flight.ammo >= 16 else { return }
            flights[index].ammo -= 16
            flightFireAt[flight.id] = elapsed + 3.4
            projectiles.append(CombatProjectile(id: allocateID(), kind: .cannon105, launch: portGun, target: target, duration: 1.2, arcHeight: flight.altitude, radius: 55, damage: upgradedDamage(.ac130) * 3.2, civilianRadius: 34))
            emitAudio(.ac130Cannon105, at: flight.position, volume: 0.95, interval: 0.1)
        } else {
            guard flight.ammo >= 2 else { return }
            flights[index].ammo -= 2
            flightFireAt[flight.id] = elapsed + 0.24
            zombies[targetIndex].health -= upgradedDamage(.ac130)
            applyStructuralDamage(at: target, radius: metersToWorld * 5, damage: upgradedDamage(.ac130) * 0.30)
            effects.append(CombatEffect(id: allocateID(), position: portGun, endPosition: target, kind: .shot, age: 0, duration: 0.18, radius: 2, altitude: flight.altitude))
            emitAudio(.ac130Cannon30, at: flight.position, volume: 0.85, interval: 0.16)
        }
    }

    private func dropB2Bombs(at index: Int) {
        let flight = flights[index]
        let released = flightBombsReleased[flight.id, default: 0]
        guard released < 4, flight.progress >= 0.40 + Double(released) * 0.065 else { return }
        let offset = Double(released) * 90 - 135
        let target = CGPoint(x: flight.target.x + cos(flight.heading) * offset, y: flight.target.y + sin(flight.heading) * offset)
        flights[index].ammo -= 1
        flightBombsReleased[flight.id] = released + 1
        projectiles.append(CombatProjectile(id: allocateID(), kind: .bomb, launch: flight.position, target: target, duration: 1.65, arcHeight: flight.altitude, radius: upgradedRange(.b2), damage: upgradedDamage(.b2), civilianRadius: upgradedRange(.b2) * 0.72))
        emitAudio(.bombRelease, at: flight.position, volume: 0.65, interval: 0.1)
    }

    private func fireA10(at index: Int) {
        let flight = flights[index]
        let strafeProgress = min(1, max(0, (flight.progress - 0.37) / 0.3))
        let offset = -250 + strafeProgress * 500
        let aim = CGPoint(x: flight.target.x + cos(flight.heading) * offset, y: flight.target.y + sin(flight.heading) * offset)
        flights[index].ammo -= 18
        flightFireAt[flight.id] = elapsed + 0.10
        // Each cannon packet sweeps a corridor. Tracers, damage, and BRRRT share this exact event.
        for shot in 0..<3 {
            let across = Double(shot - 1) * 9 + random.double(in: -3...3)
            let point = CGPoint(x: aim.x - sin(flight.heading) * across, y: aim.y + cos(flight.heading) * across)
            effects.append(CombatEffect(id: allocateID(), position: flight.position, endPosition: point, kind: .shot, age: 0, duration: 0.20, radius: 1.8, altitude: flight.altitude))
            for targetIndex in zombieNeighbors(near: point, radius: 15) { zombies[targetIndex].health -= upgradedDamage(.a10) * 0.45 }
            applyStructuralDamage(at: point, radius: metersToWorld * 6, damage: upgradedDamage(.a10) * 0.35)
            let victims = Set(civilians.filter { squaredDistance($0.position, point) < 7 * 7 }.map(\.id))
            removeCivilianVictims(victims, at: point)
        }
        emitAudio(.a10Burst, at: flight.position, volume: 1, interval: 0.55)
    }

    private func updateProjectiles(dt: Double) {
        for index in projectiles.indices { projectiles[index].age += dt }
        let landed = projectiles.filter { $0.age >= $0.duration }
        projectiles.removeAll { $0.age >= $0.duration }
        for projectile in landed {
            applyExplosion(at: projectile.target, radius: projectile.radius, damage: projectile.damage, civilianRadius: projectile.civilianRadius)
        }
    }

    private func emitAudio(_ cue: AudioCue, at position: CGPoint, volume: Double = 1, interval: Double = 0, variant: Int = 0, sourceID: Int? = nil) {
        guard cue != .zombieGroan, cue != .zombieAttack, cue != .civilianScream else { return }
        let key = SoundKey(cue: cue, sourceID: sourceID)
        if interval > 0, elapsed - lastSoundAt[key, default: -.infinity] < interval { return }
        lastSoundAt[key] = elapsed
        audioEvents.append(GameAudioEvent(id: allocateID(), cue: cue, position: position, volume: volume, variant: variant, sourceID: sourceID))
        if audioEvents.count > 96 { audioEvents.removeFirst(audioEvents.count - 96) }
    }

    private func removeCivilianVictims(_ victims: Set<Int>, at point: CGPoint) {
        guard !victims.isEmpty else { return }
        for civilian in civilians where victims.contains(civilian.id) { recordTacticalMarker(.casualty, at: civilian.position) }
        casualties += victims.count
        civilians.removeAll { victims.contains($0.id) }
        for id in victims { civilianMotion[id] = nil }
    }

    private func evacuateCivilians(dt: Double) {
        var rescuedIDs: Set<Int> = []
        for station in units where station.kind == .evacuation && station.health > 0 {
            let rate = 4 + Double(upgradeLevels[.evacuation, default: 0])
            evacuationProgress[station.id, default: 0] = min(2, evacuationProgress[station.id, default: 0] + dt * rate)
            var available = Int(evacuationProgress[station.id, default: 0])
            guard available > 0 else { continue }
            for civilian in civilians where !rescuedIDs.contains(civilian.id) && distance(civilian.position, station.position) < min(30, metersToWorld * 8) && hasLineOfSight(from: civilian.position, to: station.position) && !movementBlocked(from: civilian.position, to: station.position, forCivilians: true) {
                rescuedIDs.insert(civilian.id)
                saved += 1
                available -= 1
                evacuationProgress[station.id, default: 0] -= 1
                effects.append(CombatEffect(id: allocateID(), position: civilian.position, endPosition: nil, kind: .rescue, age: 0, duration: 0.65, radius: 14))
                emitAudio(.civilianRescue, at: station.position, volume: 0.6, interval: 1.1)
                if available <= 0 { break }
            }
        }
        if !rescuedIDs.isEmpty {
            civilians.removeAll { rescuedIDs.contains($0.id) }
            for id in rescuedIDs { civilianMotion[id] = nil }
        }
    }

    private func spreadInfection(dt: Double) {
        var infectedIDs: Set<Int> = []
        var newlyInfected: [Zombie] = []
        for index in civilians.indices {
            let contact = infectiousZombie(near: civilians[index].position, radius: metersToWorld * 1.6)
            if contact != nil {
                civilians[index].exposure += dt
            } else {
                civilians[index].exposure = max(0, civilians[index].exposure - dt * 0.8)
            }
            let civilian = civilians[index]
            if civilian.exposure >= GameBalance.infectionContactTime {
                infectedIDs.insert(civilian.id)
                let herdID = contact?.herdID ?? 0
                newlyInfected.append(Zombie(id: allocateID(), position: civilian.position, health: 55, infectiousAt: elapsed + GameBalance.infectionIncubation, herdID: herdID))
                emitAudio(.civilianScream, at: civilian.position, volume: 0.8, interval: 0.6)
                effects.append(CombatEffect(id: allocateID(), position: civilian.position, endPosition: nil, kind: .infection, age: 0, duration: 0.7, radius: 17))
                casualties += 1
                recordTacticalMarker(.casualty, at: civilian.position)
            }
        }
        if !infectedIDs.isEmpty {
            civilians.removeAll { infectedIDs.contains($0.id) }
            for infected in newlyInfected { appendInfected(infected) }
            for id in infectedIDs { civilianMotion[id] = nil }
        }
    }

    private func applyExplosion(at position: CGPoint, radius: Double, damage: Double, civilianRadius: Double) {
        effects.append(CombatEffect(id: allocateID(), position: position, endPosition: nil, kind: .explosion, age: 0, duration: 1.1, radius: radius))
        emitAudio(.explosion, at: position, volume: 0.95, interval: 0.12)
        for index in zombies.indices {
            let separation = distance(zombies[index].position, position)
            if separation <= radius {
                zombies[index].health -= damage * max(0.55, 1 - separation / (radius * 2))
            }
        }
        let victims = Set(civilians.filter { distance($0.position, position) < civilianRadius }.map(\.id))
        removeCivilianVictims(victims, at: position)
        for index in units.indices where units[index].health > 0 && distance(units[index].position, position) < civilianRadius {
            units[index].health -= damage * max(0.15, 1 - distance(units[index].position, position) / max(0.001, radius))
        }
        applyStructuralDamage(at: position, radius: radius, damage: damage)
        applyBlastToStagedMembers(at: position, radius: radius, damage: damage)
    }

    /// Visible exterior tails are real targets even while their AI is dormant.
    /// This keeps strategic strikes honest without simulating their pathfinding.
    private func applyBlastToStagedMembers(at position: CGPoint, radius: Double, damage: Double) {
        var defeatedIDs: Set<Int> = []
        for member in stagedHerdMembers {
            let separation = distance(member.position, position)
            guard separation <= radius else { continue }
            let value = stagedDamage[member.id, default: 0] + damage * max(0.55, 1 - separation / (radius * 2))
            if value >= (pendingInfections[member.id]?.health ?? 60) { defeatedIDs.insert(member.id); stagedDamage[member.id] = nil }
            else { stagedDamage[member.id] = value }
        }
        guard !defeatedIDs.isEmpty else { return }
        neutralizedStagedIDs.formUnion(defeatedIDs)
        for id in defeatedIDs { pendingInfections[id] = nil }
        stagedHerdMembers.removeAll { defeatedIDs.contains($0.id) }
        let income = defeatedIDs.count * GameBalance.killIncome
        kills += defeatedIDs.count
        budget += income
        earnedMoney += income
        stagingRevision += 1
    }

    /// Normalized accumulated structural damage survives subsequent camera LOD
    /// changes. A collapsed footprint no longer occludes direct fire or people.
    func hasLineOfSight(from start: CGPoint, to end: CGPoint) -> Bool {
        map.hasLineOfSight(from: start, to: end, excludingBuildings: destroyedBuildingIDs, excludingLandmarks: destroyedLandmarkIDs)
    }

    private func applyStructuralDamage(at position: CGPoint, radius: Double, damage: Double) {
        guard radius > 0, damage > 0 else { return }
        var changed = false
        for index in map.buildingIndices(near: position, radius: radius) where !destroyedBuildingIDs.contains(index) {
            let separation = map.distanceToBuilding(at: index, from: position)
            guard separation < radius else { continue }
            let building = map.buildings[index]
            let areaMeters = max(1, Double(building.rect.width * building.rect.height) / (metersToWorld * metersToWorld))
            let resistance = min(340, 80 + sqrt(areaMeters) * 1.4 + building.height / metersToWorld * 1.7)
            let amount = damage / resistance * max(0.12, 1 - separation / radius)
            let value = min(1, buildingDamage[index, default: 0] + amount)
            buildingDamage[index] = value
            if value >= 1 { destroyedBuildingIDs.insert(index) }
            changed = true
        }
        for index in map.landmarks.indices where !destroyedLandmarkIDs.contains(index) {
            let landmark = map.landmarks[index]
            // Squares and harbors have no inhabitable structure to collapse.
            guard landmark.kind != .mohammedSquare && landmark.kind != .port else { continue }
            let separation = map.distanceToLandmark(at: index, from: position)
            guard separation < radius else { continue }
            let resistance = min(450, 160 + landmark.height / metersToWorld * 1.6)
            let value = min(1, landmarkDamage[index, default: 0] + damage / resistance * max(0.12, 1 - separation / radius))
            landmarkDamage[index] = value
            if value >= 1 { destroyedLandmarkIDs.insert(index) }
            changed = true
        }
        if changed { destructionRevision += 1 }
    }

    private func removeDeadZombies() {
        let defeated = zombies.filter { $0.health <= 0 }
        kills += defeated.count
        let income = defeated.count * GameBalance.killIncome
        budget += income
        earnedMoney += income
        zombies.removeAll { $0.health <= 0 }
        for zombie in defeated {
            zombieMotion[zombie.id] = nil
            zombieRoutePositions[zombie.id] = nil
            zombieLanes[zombie.id] = nil
            zombieHeadings[zombie.id] = nil
        }
    }

    private func removeDestroyedUnits() {
        for index in units.indices {
            if let host = units[index].hostBuildingID, destroyedBuildingIDs.contains(host) { units[index].health = 0 }
        }
        let brokenGates = units.filter { $0.kind == .gate && $0.health <= 0 }.compactMap(\.linkedBarrierID)
        for index in units.indices where brokenGates.contains(units[index].id) { units[index].health = 0 }
        let destroyed = units.filter { $0.health <= 0 }
        units.removeAll { $0.health <= 0 }
        for unit in destroyed {
            if let recruited = recruitedCivilians.removeValue(forKey: unit.id) {
                casualties += recruited.count
                if !recruited.isEmpty { recordTacticalMarker(.casualty, at: unit.position, count: recruited.count) }
            }
            if unit.kind.isWall { recordTacticalMarker(.breach, at: unit.position) }
            supportAutoUnits.remove(unit.id)
            unitMotion[unit.id] = nil
            squadFireIndex[unit.id] = nil
            evacuationProgress[unit.id] = nil
            troopExposure[unit.id] = nil
            defenseTargetIDs[unit.id] = nil
            defenseSearchOffsets[unit.id] = nil
            if selectedUnitID == unit.id { selectedUnitID = nil }
            emitAudio(.unitLost, at: unit.position, volume: 0.75)
            setNotice("\(unit.kind.shortTitle) overrun. Adjust your perimeter.", duration: 4)
        }
        // The aperture hardware is part of its wall; a breached or withdrawn
        // wall cannot leave floating gates or continue charging passage slots.
        let wallIDs = Set(units.filter { $0.kind == .barricade }.map(\.id))
        units.removeAll { $0.kind == .gate && !wallIDs.contains($0.linkedBarrierID ?? -1) }
    }

    private func resolveOutcome() {
        guard phase == .running || phase == .paused else { return }
        if saved + civilians.count + mobilizedCivilianCount > 0 && zombies.isEmpty && stagedHerdMembers.isEmpty && pendingHerdCount == 0 && arrivals.allSatisfy({ $0.releasedCount == $0.size }) && projectiles.isEmpty && !supportAreas.contains(where: { $0.kind == .fireBomb }) {
            phase = .won
            saved += civilians.count + mobilizedCivilianCount
            emitAudio(.victory, at: map.initialFocus, volume: 0.8)
            if !rewardPaid {
                let result = CampaignRules.improvedBest(previous: bestMissionResult, survivors: saved, population: initialPopulation, score: resultScore, objective: survivalObjective)
                missionBests[currentMissionKey] = result.best
                lastProgressReward = result.reward
                upgradePoints += result.reward
                if outbreakMode == .siege || campaignDistrict == .citywide { completedCities.insert(city) }
                rewardPaid = true
                writeProgression()
                setNotice("\(resultGrade.title) · \(saved)/\(initialPopulation) survivors." + (result.reward > 0 ? " +\(result.reward) loadout points." : " Improve your survival best for the next reward tier."), duration: .infinity)
            }
        } else if civilians.isEmpty && mobilizedCivilianCount == 0 && (saved == 0 || (!units.contains(where: { $0.kind.isCombat && $0.health > 0 }) && budget < UnitKind.squad.cost)) {
            phase = .lost
            emitAudio(.defeat, at: map.initialFocus, volume: 0.8)
            setNotice("Containment failed. Retry the operation with a new defense plan.", duration: .infinity)
        }
    }

    private func ageEffects(dt: Double) {
        for index in effects.indices { effects[index].age += dt }
        effects.removeAll { $0.age >= $0.duration }
        if effects.count > 500 { effects.removeFirst(effects.count - 500) }
    }

    private func advance(from position: CGPoint, motion: inout Motion, amount: Double) -> CGPoint {
        var current = position
        var remaining = amount
        while motion.index < motion.waypoints.count && remaining > 0 {
            let target = motion.waypoints[motion.index]
            let separation = distance(current, target)
            if separation < 0.01 {
                motion.index += 1
            } else if separation <= remaining {
                current = target
                remaining -= separation
                motion.index += 1
            } else {
                let fraction = remaining / separation
                current = CGPoint(x: current.x + (target.x - current.x) * fraction, y: current.y + (target.y - current.y) * fraction)
                remaining = 0
            }
        }
        return current
    }

    private func wanderingDestination(from position: CGPoint) -> CGPoint {
        guard !map.navigationNodes.isEmpty else { return position }
        let node = map.nearestNode(to: position)
        if adjacency.indices.contains(node), !adjacency[node].isEmpty {
            return map.navigationNodes[adjacency[node][random.index(count: adjacency[node].count)]]
        }
        return map.navigationNodes[random.index(count: map.navigationNodes.count)]
    }

    private func escapeDestination(from position: CGPoint, threat: CGPoint) -> CGPoint {
        let node = map.nearestNode(to: position)
        guard adjacency.indices.contains(node), !adjacency[node].isEmpty else { return wanderingDestination(from: position) }
        // Compare adjacent intersections so fleeing stays on real streets.
        let choices = adjacency[node]
        let best = choices.max { distance(map.navigationNodes[$0], threat) < distance(map.navigationNodes[$1], threat) }!
        return map.navigationNodes[best]
    }

    private func cell(for point: CGPoint) -> GridCell {
        GridCell(x: Int(floor(Double(point.x) / gridSize)), y: Int(floor(Double(point.y) / gridSize)))
    }

    private func zombieCell(for point: CGPoint) -> GridCell {
        GridCell(x: Int(floor(Double(point.x) / zombieCellSize)), y: Int(floor(Double(point.y) / zombieCellSize)))
    }

    private func rebuildZombieGrid() {
        zombieGrid.removeAll(keepingCapacity: true)
        flockGrid.removeAll(keepingCapacity: true)
        for index in zombies.indices where zombies[index].health > 0 {
            zombieGrid[cell(for: zombies[index].position), default: []].append(index)
            flockGrid[zombieCell(for: zombies[index].position), default: []].append(index)
        }
    }

    private func rebuildCivilianGrid() {
        civilianGrid.removeAll(keepingCapacity: true)
        for index in civilians.indices { civilianGrid[cell(for: civilians[index].position), default: []].append(index) }
    }

    private func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return dx * dx + dy * dy
    }

    private func nearestZombie(to position: CGPoint, within radius: Double) -> Zombie? {
        var best: Zombie?
        var bestDistance = radius * radius
        let low = cell(for: CGPoint(x: position.x - radius, y: position.y - radius))
        let high = cell(for: CGPoint(x: position.x + radius, y: position.y + radius))
        for x in low.x...high.x {
            for y in low.y...high.y {
                for index in zombieGrid[GridCell(x: x, y: y)] ?? [] where zombies[index].health > 0 {
                    let candidate = squaredDistance(zombies[index].position, position)
                    if candidate < bestDistance { best = zombies[index]; bestDistance = candidate }
                }
            }
        }
        return best
    }

    private func infectiousZombie(near position: CGPoint, radius: Double) -> Zombie? {
        let low = zombieCell(for: CGPoint(x: position.x - radius, y: position.y - radius))
        let high = zombieCell(for: CGPoint(x: position.x + radius, y: position.y + radius))
        for x in low.x...high.x {
            for y in low.y...high.y {
                for index in flockGrid[GridCell(x: x, y: y)] ?? [] where zombies[index].health > 0 && zombies[index].infectiousAt <= elapsed && !stunnedZombieIDs.contains(zombies[index].id) {
                    if squaredDistance(zombies[index].position, position) < radius * radius,
                       hasLineOfSight(from: position, to: zombies[index].position),
                       !movementBlocked(from: position, to: zombies[index].position) { return zombies[index] }
                }
            }
        }
        return nil
    }

    private func nearestCivilian(to position: CGPoint) -> Civilian? {
        guard !civilians.isEmpty else { return nil }
        var best: Civilian?
        var bestDistance = Double.infinity
        let center = cell(for: position)
        // Visit each bucket only once, then stop as soon as the search boundary
        // is farther away than the closest survivor found. Dense hordes avoid
        // an all-pairs scan while keeping target selection exactly deterministic.
        for ring in 0...Int(ceil(map.worldSize / gridSize)) {
            for dx in -ring...ring {
                for dy in -ring...ring {
                    if ring > 0 && abs(dx) != ring && abs(dy) != ring { continue }
                    for index in civilianGrid[GridCell(x: center.x + dx, y: center.y + dy)] ?? [] {
                        let candidate = squaredDistance(civilians[index].position, position)
                        if candidate < bestDistance { best = civilians[index]; bestDistance = candidate }
                    }
                }
            }
            if best != nil {
                let lowX = Double(center.x - ring) * gridSize
                let highX = Double(center.x + ring + 1) * gridSize
                let lowY = Double(center.y - ring) * gridSize
                let highY = Double(center.y + ring + 1) * gridSize
                let boundary = min(Double(position.x) - lowX, highX - Double(position.x), Double(position.y) - lowY, highY - Double(position.y))
                if bestDistance <= boundary * boundary { return best }
            }
        }
        return best
    }

    private func randomStreetPoint() -> CGPoint {
        guard !map.navigationEdges.isEmpty else { return CGPoint(x: random.double(in: 50...950), y: random.double(in: 50...950)) }
        let districtOnly = outbreakMode == .cityOutbreak && missionBounds != nil
        let pool = !coreSpawnEdges.isEmpty && (districtOnly || random.double(in: 0...1) < 0.7) ? coreSpawnEdges : map.navigationEdges
        let edge = pool[random.index(count: pool.count)]
        let first = map.navigationNodes[edge.from]
        let second = map.navigationNodes[edge.to]
        let fraction = random.double(in: 0.05...0.95)
        return CGPoint(x: first.x + (second.x - first.x) * fraction, y: first.y + (second.y - first.y) * fraction)
    }

    private func upgradedRange(_ kind: UnitKind) -> Double { kind.range * (1 + Double(upgradeLevels[kind, default: 0]) * 0.06) }
    private func upgradedHealth(_ kind: UnitKind) -> Double { kind.maxHealth * (1 + Double(upgradeLevels[kind, default: 0]) * 0.22) }
    private func upgradedDamage(_ kind: UnitKind) -> Double { kind.damage * (1 + Double(upgradeLevels[kind, default: 0]) * 0.18) }
    private func allocateID() -> Int { defer { nextID += 1 }; return nextID }
    private func publish() { revision &+= 1 }
    private func setNotice(_ message: String, duration: Double) { notice = message; noticeUntil = elapsed + duration }
    private func clamped(_ point: CGPoint) -> CGPoint { CGPoint(x: min(map.worldSize - 10, max(10, point.x)), y: min(map.worldSize - 10, max(10, point.y))) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    private func readProgression() {
        guard let progress = defaults?.dictionary(forKey: progressionKey) else { return }
        upgradePoints = max(0, progress["points"] as? Int ?? 0)
        if let cities = progress["completedCities"] as? [String] {
            completedCities = Set(cities.compactMap(CityScenario.init(rawValue:)))
        }
        if let encoded = progress["missionBests"] as? Data,
           let bests = try? JSONDecoder().decode([String: MissionBest].self, from: encoded) {
            missionBests = bests.filter { key, value in
                CityScenario.allCases.contains { key.hasPrefix($0.rawValue + ".") } && value.population > 0 &&
                    value.survivors >= 0 && value.survivors <= value.population && (0...3).contains(value.awardedTier)
            }
        } else if (progress["campaignVersion"] as? Int ?? 0) < 1 {
            for completed in completedCities {
                let key = CampaignRules.missionKey(city: completed, mode: .siege, district: .citywide)
                // Legacy saves did not record survival. Keep the completion and
                // existing points, while permitting better results to claim tiers 2–3.
                missionBests[key] = MissionBest(survivors: 0, population: completed.population, score: 0, grade: .contained, awardedTier: 1)
            }
        }
        if let levels = progress["levels"] as? [String: Int] {
            let migrations: [String: UnitKind] = ["turret": .humvee, "airstrike": .b2, "helicopter": .ac130, "garrison": .sniper]
            let oldRoster = (progress["rosterVersion"] as? Int ?? 1) < 4
            var changed = false
            for (key, level) in levels {
                let kind = (key == "sniper" && oldRoster) ? nil : (UnitKind(rawValue: key) ?? migrations[key])
                if let kind { upgradeLevels[kind] = max(upgradeLevels[kind, default: 0], min(3, max(0, level))) }
                if migrations[key] != nil { changed = true }
            }
            if oldRoster, let removedLevel = levels["sniper"], removedLevel > 0 {
                upgradePoints += min(3, removedLevel)
                changed = true
            }
            if changed { writeProgression() }
        }
    }

    private func writeProgression() {
        let levels = Dictionary(uniqueKeysWithValues: upgradeLevels.map { ($0.key.rawValue, $0.value) })
        var payload: [String: Any] = ["rosterVersion": 4, "campaignVersion": 1, "points": upgradePoints, "levels": levels, "completedCities": completedCities.map(\.rawValue).sorted()]
        if let encoded = try? JSONEncoder().encode(missionBests) { payload["missionBests"] = encoded }
        defaults?.set(payload, forKey: progressionKey)
    }
}

#if CAMPAIGN_TESTS
extension GameEngine {
    func campaignTestDamageFirstDefense(fraction: Double) {
        guard !units.isEmpty else { return }
        units[0].health = units[0].maxHealth * fraction
    }
    /// Resolve a completed combat fixture through the production victory path.
    func campaignTestFinish(survivors: Int) {
        civilians = Array(civilians.prefix(survivors))
        casualties = initialPopulation - civilians.count
        saved = 0
        zombies.removeAll(); arrivals.removeAll(); stagedHerdMembers.removeAll()
        projectiles.removeAll(); supportAreas.removeAll()
        phase = .running
        resolveOutcome()
        publish()
    }
}
#endif

#if TACTICAL_TESTS
extension GameEngine {
    func tacticalTestConfigure(civilians residents: [Civilian] = [], zombies infected: [Zombie] = [],
                               units defenses: [DefenseUnit] = [], budget funds: Int = 5_000,
                               phase state: GamePhase = .planning) {
        reset(city: city)
        civilians = residents; zombies = infected; units = defenses; budget = funds; phase = state
        initialPopulation = residents.count
        nextID = max(10_000, (residents.map(\.id) + infected.map(\.id) + defenses.map(\.id)).max() ?? 0) + 1
        arrivals.removeAll(); stagedHerdMembers.removeAll(); stagedColumns.removeAll()
        for index in units.indices { updateFormation(at: index) }
        rebuildCivilianGrid(); rebuildZombieGrid()
    }
    func tacticalTestStep(dt: Double, moveResidents: Bool = false) {
        elapsed += dt; simulationStepCount += 1
        rebuildCivilianGrid(); rebuildZombieGrid()
        if moveResidents { updateCivilianKnowledge(dt: dt); moveCivilians(dt: dt) }
        updateInfantryInfection(dt: dt); updatePlantedExplosives(dt: dt)
        removeDestroyedUnits(); removeDeadZombies()
    }
    func tacticalTestSetPhase(_ state: GamePhase) { phase = state }
    func tacticalTestDamageUnit(_ id: Int) { if let index = units.firstIndex(where: { $0.id == id }) { units[index].health = 0 }; removeDestroyedUnits() }
    func tacticalTestExplosion(at point: CGPoint, radius: Double, damage: Double) {
        applyExplosion(at: point, radius: radius, damage: damage, civilianRadius: radius)
        removeDestroyedUnits(); removeDeadZombies()
    }
    func tacticalTestGateAllows(_ civilianID: Int, from start: CGPoint, to end: CGPoint) -> Bool {
        civilianGateAllows(civilianID, from: start, to: end)
    }
    func tacticalTestRouteCivilian(_ id: Int, to destination: CGPoint) {
        guard let resident = civilians.first(where: { $0.id == id }) else { return }
        let center = map.nearestRoadPoint(to: resident.position)
        civilianRoutePositions[id] = center
        civilianMotion[id] = Motion(waypoints: map.path(from: center, to: destination), reconsiderAt: 1_000, destination: destination)
    }
    func tacticalTestFire(dt: Double) { rebuildZombieGrid(); fireDefenses(dt: dt); removeDeadZombies() }
    func tacticalTestRecordMarker(at point: CGPoint) { recordTacticalMarker(.casualty, at: point) }
    func tacticalTestDuplicateSafeZone() {
        if let zone = safeZones.first { safeZones.append(SafeZone(id: allocateID(), points: zone.points, boundaryUnitIDs: zone.boundaryUnitIDs)) }
    }
}
#endif

#if MOVEMENT_TESTS
/// Controlled actor fixtures exist only in the standalone movement-check build.
/// Tests still call the production perception, contact and steering functions.
extension GameEngine {
    func movementTestConfigure(civilians residents: [Civilian], zombies infected: [Zombie],
                               destination: CGPoint, units defenses: [DefenseUnit] = []) {
        reset(city: city)
        civilians = residents; zombies = infected; units = defenses
        initialPopulation = residents.count
        arrivals.removeAll(); stagedHerdMembers.removeAll(); stagedColumns.removeAll()
        for civilian in residents {
            let center = map.nearestRoadPoint(to: civilian.position)
            civilianRoutePositions[civilian.id] = center
            civilianMotion[civilian.id] = Motion(waypoints: map.path(from: center, to: destination), reconsiderAt: 1_000, destination: destination)
        }
        for zombie in infected {
            let center = map.nearestRoadPoint(to: zombie.position)
            let route = map.path(from: center, to: destination)
            zombieRoutePositions[zombie.id] = center
            zombieHeadings[zombie.id] = zombie.heading
            zombieMotion[zombie.id] = Motion(waypoints: route, destination: destination)
            herds[zombie.herdID] = HerdState(center: center, destination: destination, reconsiderAt: 1_000, route: route)
        }
        phase = .running
        rebuildCivilianGrid(); rebuildZombieGrid()
    }
    /// Isolate delayed perception/conversation from moving actors leaving the fixture.
    /// Knowledge is acquired normally; no learned timestamps or IDs are injected.
    func movementTestKnowledge(dt: Double) {
        elapsed += dt
        rebuildCivilianGrid()
        updateCivilianKnowledge(dt: dt)
    }
    func movementTestCivilians(dt: Double) {
        elapsed += dt; simulationStepCount += 1
        rebuildCivilianGrid(); rebuildZombieGrid(); moveCivilians(dt: dt)
    }
    func movementTestZombies(dt: Double) {
        elapsed += dt; simulationStepCount += 1
        rebuildCivilianGrid(); rebuildZombieGrid(); moveZombies(dt: dt)
    }
    func movementTestContact(dt: Double) {
        elapsed += dt; rebuildZombieGrid(); spreadInfection(dt: dt)
    }
    func movementTestVisibleThreat(at position: CGPoint, radius: Double) -> Int? {
        rebuildZombieGrid(); return nearestVisibleZombie(to: position, within: radius)?.id
    }
    func movementTestPursuit(for zombieID: Int) -> Int? { zombiePursuits[zombieID]?.civilianID }
    func movementTestRemoveCivilian(_ id: Int) { civilians.removeAll { $0.id == id } }
}
#endif
