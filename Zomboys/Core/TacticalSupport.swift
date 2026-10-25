import Foundation

/// Single-use tactical reserves complement the reusable ground roster and the
/// three named aircraft without changing their deployment or upgrade identity.
enum TacticalSupportKind: String, CaseIterable, Identifiable {
    case paratroopers, gasBomb, fireBomb, callToArms
    var id: String { rawValue }
    var title: String {
        switch self {
        case .paratroopers: return "PARATROOPERS"
        case .gasBomb: return "GAS BOMB"
        case .fireBomb: return "FIRE BOMB"
        case .callToArms: return "CALL TO ARMS"
        }
    }
    var shortTitle: String {
        switch self {
        case .paratroopers: return "Paratroopers"
        case .gasBomb: return "Gas"
        case .fireBomb: return "Fire bomb"
        case .callToArms: return "Call to arms"
        }
    }
    var subtitle: String {
        switch self {
        case .paratroopers: return "3-second drop · two squads seek the horde"
        case .gasBomb: return "8-second stun cloud · civilians remain safe"
        case .fireBomb: return "Three impacts · 10-second fires · civilian risk"
        case .callToArms: return "Arm up to 12 nearby civilians · defend their streets"
        }
    }
    var symbol: String {
        switch self {
        case .paratroopers: return "arrow.down.to.line"
        case .gasBomb: return "cloud.fill"
        case .fireBomb: return "flame.fill"
        case .callToArms: return "person.3.fill"
        }
    }
    var cost: Int {
        switch self {
        case .paratroopers: return 350
        case .gasBomb: return 250
        case .fireBomb: return 450
        case .callToArms: return 200
        }
    }
    var radiusMeters: Double {
        switch self {
        case .paratroopers: return 12
        case .gasBomb: return 32
        case .fireBomb: return 22
        case .callToArms: return 150
        }
    }
    var duration: Double {
        switch self {
        case .paratroopers: return 3
        case .gasBomb: return 8
        case .fireBomb: return 10
        case .callToArms: return 1.8
        }
    }
}

struct SupportAreaState: Identifiable {
    let id: Int
    let kind: TacticalSupportKind
    let position: CGPoint
    let radius: Double
    var age: Double = 0
    let lifetime: Double
    var nextPulseAt: Double = 0
    var progress: Double { min(1, max(0, age / lifetime)) }
}
