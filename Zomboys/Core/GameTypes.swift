import Foundation

/// A mission starts in planning so every placement is a strategic choice.
enum GamePhase: String, Codable {
    case planning, running, paused, won, lost

    var isFinished: Bool { self == .won || self == .lost }
}

enum CityScenario: String, CaseIterable, Codable, Identifiable {
    case settat, casablanca

    var id: String { rawValue }
    var title: String { self == .settat ? "SETTAT" : "CASABLANCA" }
    var district: String { self == .settat ? "CHAOUIA · COMPACT CITY" : "CITYWIDE COMMAND" }
    var coordinateText: String { self == .settat ? "33.0038° N  ·  7.6209° W" : "33.5731° N  ·  7.5898° W" }
    var operationName: String { self == .settat ? "OPERATION CHAOUIA SHIELD" : "OPERATION WHITE CITY" }
    var difficulty: String { "STANDARD" }
    var seed: UInt64 { self == .settat ? 0x53455454 : 0x43415341 }
    var population: Int { self == .settat ? 360 : 720 }
    var startingBudget: Int { self == .settat ? 2_000 : 2_400 }
}

enum UnitKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case squad, humvee, mortar, sniper, barricade, safeZone, gate, mine, c4, evacuation, ac130, b2, a10
    var id: String { rawValue }
    var title: String {
        switch self {
        case .squad: return "RIFLE SQUAD"
        case .humvee: return "ARMED HUMVEE"
        case .mortar: return "MORTAR TEAM"
        case .sniper: return "SNIPER TEAM"
        case .barricade: return "BARRICADE"
        case .safeZone: return "SAFE ZONE"
        case .gate: return "CIVILIAN GATE"
        case .mine: return "PROXIMITY MINE"
        case .c4: return "REMOTE C4"
        case .evacuation: return "EVAC STATION"
        case .ac130: return "AC-130 GHOSTRIDER"
        case .b2: return "B-2 SPIRIT"
        case .a10: return "A-10 THUNDERBOLT II"
        }
    }
    var shortTitle: String {
        switch self {
        case .squad: return "Squad"
        case .humvee: return "Humvee"
        case .mortar: return "Mortar"
        case .sniper: return "Snipers"
        case .barricade: return "Barrier"
        case .safeZone: return "Safe zone"
        case .gate: return "Gate"
        case .mine: return "Mine"
        case .c4: return "C4"
        case .evacuation: return "Evac"
        case .ac130: return "AC-130"
        case .b2: return "B-2"
        case .a10: return "A-10"
        }
    }
    var subtitle: String {
        switch self {
        case .squad: return "Five soldiers · spread formation · light fire"
        case .humvee: return "Mobile gun truck · patrol or hold"
        case .mortar: return "Arcing shells · delayed area damage"
        case .sniper: return "Precise long-range shots · clear sightlines"
        case .barricade: return "Draw along streets · repairable durability"
        case .safeZone: return "Draw a district · pay for every street closure"
        case .gate: return "Tap a wall · civilians pass in single file"
        case .mine: return "Triggers on zombies · collateral blast risk"
        case .c4: return "Place, then select and detonate · collateral risk"
        case .evacuation: return "Extracts nearby survivors"
        case .ac130: return "Orbit · 30 mm / 105 mm · finite ammunition"
        case .b2: return "Low flyby · four bombs · civilian risk"
        case .a10: return "Directed strafing run · GAU-8 BRRRT"
        }
    }
    var symbol: String {
        switch self {
        case .squad: return "person.3.fill"
        case .humvee: return "car.side.fill"
        case .mortar: return "burst.fill"
        case .sniper: return "scope"
        case .barricade: return "rectangle.split.3x1.fill"
        case .safeZone: return "shield.lefthalf.filled"
        case .gate: return "door.left.hand.open"
        case .mine: return "circle.hexagongrid.fill"
        case .c4: return "bolt.square.fill"
        case .evacuation: return "figure.walk.departure"
        case .ac130: return "scope"
        case .b2: return "airplane"
        case .a10: return "airplane.circle.fill"
        }
    }
    var cost: Int {
        switch self {
        case .squad: return 90
        case .humvee: return 220
        case .mortar: return 240
        case .sniper: return 280
        case .barricade: return 40
        case .safeZone: return 40
        case .gate: return 60
        case .mine: return 75
        case .c4: return 95
        case .evacuation: return 180
        case .ac130: return 650
        case .b2: return 600
        case .a10: return 400
        }
    }
    var range: Double {
        switch self {
        case .squad: return 105
        case .humvee: return 160
        case .mortar: return 240
        case .sniper: return 330
        case .barricade: return 27
        case .safeZone: return 0
        case .gate: return 0
        case .mine: return 30
        case .c4: return 48
        case .evacuation: return 120
        case .ac130: return 280
        case .b2: return 120
        case .a10: return 150
        }
    }
    var isAirSupport: Bool { self == .ac130 || self == .b2 || self == .a10 }
    var isMobile: Bool { self == .squad || self == .humvee || self == .mortar }
    var isCombat: Bool { self == .squad || self == .humvee || self == .mortar || self == .sniper }
    var isWall: Bool { self == .barricade || self == .gate }
    var isExplosive: Bool { self == .mine || self == .c4 }
    var hasHumanCrew: Bool { self == .squad || self == .sniper || self == .mortar }
    var maxHealth: Double {
        switch self {
        case .squad: return 125
        case .humvee: return 240
        case .mortar: return 95
        case .sniper: return 85
        case .barricade: return 320
        case .safeZone: return 1
        case .gate: return 240
        case .mine, .c4: return 30
        case .evacuation: return 160
        case .ac130, .b2, .a10: return 1
        }
    }
    var reloadTime: Double {
        switch self {
        case .squad: return 0.65
        case .humvee: return 0.24
        case .mortar: return 3.6
        case .sniper: return 1.8
        case .barricade, .safeZone, .gate, .mine, .c4, .evacuation, .ac130, .b2, .a10: return 1
        }
    }
    var damage: Double {
        switch self {
        case .squad: return 12
        case .humvee: return 20
        case .mortar: return 100
        case .sniper: return 90
        case .barricade, .safeZone, .gate, .evacuation: return 0
        case .mine: return 145
        case .c4: return 240
        case .ac130: return 80
        case .b2: return 250
        case .a10: return 70
        }
    }
    var upgradeCost: Int { 1 }
}

struct DefenseUnit: Identifiable {
    let id: Int
    let kind: UnitKind
    var position: CGPoint
    var targetPosition: CGPoint?
    var health: Double
    var maxHealth: Double
    var range: Double
    var cooldown: Double
    var barrierPath: [CGPoint] = []
    var purchaseCost: Int = 0
    var formation: [CGPoint] = []
    var heading: Double = 0
    var turretHeading: Double = 0
    var patrolWaypoints: [CGPoint] = []
    var patrolIndex: Int = 0
    var holding: Bool = true
    var soundVariant: Int = 0
    /// Gates occupy an aperture in one paid wall, never an unrelated wall nearby.
    var linkedBarrierID: Int? = nil
    /// Surviving infantry bodies, independent of health lost to explosions.
    var crewRemaining: Int? = nil
    var hostBuildingID: Int? = nil
    var elevation: Double = 0
}

struct Civilian: Identifiable {
    let id: Int
    var position: CGPoint
    var exposure: Double = 0
    var heading: Double = 0
    var speed: Double = 0
    var stride: Double = 0
    var evacuationID: Int? = nil
    var evacuationAwareness: Double = 0
    var evacuationLearnedFrom: Int? = nil
    var followingID: Int? = nil
    var panic: Double = 0
}

struct Zombie: Identifiable {
    let id: Int
    var position: CGPoint
    var health: Double
    var infectiousAt: Double = 0
    var herdID: Int = 0
    var lateralOffset: Double = 0
    var heading: Double = 0
    var speed: Double = 0
    var stride: Double = 0
}

struct BarricadePlan {
    let points: [CGPoint]
    let length: Double
    let cost: Int
    let modules: Int
}

enum GameBalance {
    static let killIncome = 12
    static let emergencyFunds = 350
    static let infectionContactTime = 1.4
    static let infectionIncubation = 2.5
    static let barricadeModuleLength = 60.0
    static let maxBarricadeLength = 300.0
}

enum EffectKind { case shot, explosion, rescue, infection }

struct CombatEffect: Identifiable {
    let id: Int
    var position: CGPoint
    var endPosition: CGPoint?
    var kind: EffectKind
    var age: Double
    var duration: Double
    var radius: Double
    var altitude: Double = 4
}

/// Stable pseudo-random numbers keep retries identical, so planning can improve.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let fraction = Double(next() & 0x1F_FFFF_FFFF_FFFF) / Double(0x1F_FFFF_FFFF_FFFF)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
    mutating func index(count: Int) -> Int { Int(next() % UInt64(max(1, count))) }
}
