import Foundation

/// Siege preserves the large exterior-column operations. The campaign starts
/// with a concealed outbreak among a genuinely smaller district population.
enum OutbreakMode: String, CaseIterable, Codable, Identifiable {
    case siege, cityOutbreak
    var id: String { rawValue }
    var title: String { self == .siege ? "EXTERIOR SIEGE" : "CITY OUTBREAK" }
    var detail: String {
        self == .siege ? "Visible exterior herds and randomized arrival times." : "An unknown street outbreak. Expand your response across three districts."
    }
}

enum CampaignDistrict: String, CaseIterable, Codable, Identifiable {
    case neighborhood, district, citywide
    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var title: String { ["NEIGHBORHOOD", "INNER DISTRICTS", "CITYWIDE"][index] }
    var next: CampaignDistrict? { index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil }
    var initialInfected: Int { [18, 26, 36][index] }
    var survivalObjective: Double { [0.50, 0.60, 0.70][index] }
    func population(in city: CityScenario) -> Int { city.population / [4, 2, 1][index] }
    func startingBudget(in city: CityScenario) -> Int { city.startingBudget - [800, 400, 0][index] }
    /// A briefing/population catchment, never a clipping or simulation boundary.
    func catchment(in map: CityMap) -> CGRect? {
        guard self != .citywide else { return nil }
        let factor = self == .neighborhood ? 0.42 : 1.0
        let width = map.coreBounds.width * factor
        return CGRect(x: map.initialFocus.x - width / 2, y: map.initialFocus.y - width / 2, width: width, height: width)
    }
}

enum SurvivalGrade: String, Codable {
    case unranked, contained, bronze, silver, gold, diamond
    var title: String { rawValue.uppercased() }
    static func grade(survival: Double, objective: Double, won: Bool) -> SurvivalGrade {
        guard won else { return .unranked }
        if survival >= 0.95 { return .diamond }
        if survival >= max(0.90, objective) { return .gold }
        if survival >= min(0.89, objective + 0.15) { return .silver }
        if survival >= objective { return .bronze }
        return .contained
    }
}

struct MissionBest: Codable, Equatable {
    var survivors: Int
    var population: Int
    var score: Int
    var grade: SurvivalGrade
    /// Tracks finite reward entitlement; improved attempts pay only the difference.
    var awardedTier: Int
    var survivalRate: Double { population > 0 ? Double(survivors) / Double(population) : 0 }
}

enum CampaignRules {
    static let upgradeableKinds: [UnitKind] = [.squad, .humvee, .mortar, .sniper, .barricade, .evacuation, .ac130, .b2, .a10]
    static func upgradeDescription(_ kind: UnitKind) -> String {
        switch kind {
        case .barricade: return "Per level: +22% wall durability"
        case .evacuation: return "Per level: +1 extraction/s, +6% reach, +22% health"
        case .ac130: return "Per level: +18% gun damage, +6% targeting reach"
        case .b2: return "Per level: +18% bomb damage, +6% blast radius"
        case .a10: return "Per level: +18% GAU-8 damage"
        default: return "Per level: +18% damage, +6% range, +22% health, faster fire"
        }
    }
    static func missionKey(city: CityScenario, mode: OutbreakMode, district: CampaignDistrict) -> String {
        "\(city.rawValue).\(mode.rawValue).\(mode == .siege ? CampaignDistrict.citywide.rawValue : district.rawValue)"
    }
    /// One additional survivor always outweighs every combat/time tie breaker.
    static func score(survivors: Int, kills: Int, elapsed: Double, won: Bool) -> Int {
        let tieBreaker = min(9_999, max(0, kills) + (won ? max(0, 180 - Int(elapsed)) : 0))
        return max(0, survivors) * 10_000 + tieBreaker
    }
    static func rewardTier(survival: Double, objective: Double) -> Int {
        survival <= 0 ? 0 : (survival >= 0.90 ? 3 : (survival >= objective ? 2 : 1))
    }
    static func improvedBest(previous: MissionBest?, survivors: Int, population: Int, score: Int, objective: Double) -> (best: MissionBest, reward: Int) {
        let rate = population > 0 ? Double(survivors) / Double(population) : 0
        let entitlement = rewardTier(survival: rate, objective: objective)
        let previousTier = previous?.awardedTier ?? 0
        let reward = max(0, entitlement - previousTier)
        let candidate = MissionBest(survivors: survivors, population: population, score: score,
                                   grade: SurvivalGrade.grade(survival: rate, objective: objective, won: true),
                                   awardedTier: max(entitlement, previousTier))
        if var previous, previous.survivalRate > rate || (previous.survivalRate == rate && previous.score > score) {
            previous.awardedTier = max(previousTier, entitlement)
            return (previous, reward)
        }
        return (candidate, reward)
    }
}
