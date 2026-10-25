import Foundation

/// Runtime snapshots shared by the tactical renderer and the sound mixer.
enum ProjectileKind { case mortar, bomb, cannon105 }
enum AirWeaponMode: String, CaseIterable {
    case cannon30 = "30 mm", cannon105 = "105 mm"
    var title: String { rawValue }
}

struct CombatProjectile: Identifiable {
    let id: Int
    let kind: ProjectileKind
    let launch: CGPoint
    let target: CGPoint
    var age: Double = 0
    let duration: Double
    let arcHeight: Double
    let radius: Double
    let damage: Double
    let civilianRadius: Double
    var progress: Double { min(1, max(0, age / duration)) }
    var position: CGPoint {
        CGPoint(x: launch.x + (target.x - launch.x) * progress,
                y: launch.y + (target.y - launch.y) * progress)
    }
    var altitude: Double {
        switch kind {
        case .mortar: return sin(progress * .pi) * arcHeight
        case .cannon105: return arcHeight * (1 - progress) + sin(progress * .pi) * arcHeight * 0.3
        case .bomb: return arcHeight * (1 - progress * progress)
        }
    }
}

struct AircraftFlight: Identifiable {
    let id: Int
    let kind: UnitKind
    var position: CGPoint
    var altitude: Double
    var heading: Double
    var age: Double = 0
    let duration: Double
    var target: CGPoint
    let start: CGPoint
    let end: CGPoint
    var ammo: Int
    var weaponMode: AirWeaponMode = .cannon30
    var progress: Double { min(1, max(0, age / duration)) }
}

struct HerdArrival: Identifiable {
    let id: Int
    let position: CGPoint
    let arrivesAt: Double
    let size: Int
    let direction: String
    var spawned: Bool = false
    var sourcePosition: CGPoint = .zero
    var departureAt: Double = 0
    var travelDistance: Double = 0
    var releasedCount: Int = 0
    var releaseDuration: Double = 0
    var stagingLength: Double = 0
}

/// A pre-existing member of an exterior column. Dormant members have no AI,
/// collision or pathfinding cost; they turn into live zombies at this exact point.
struct StagedHerdMember: Identifiable {
    let id: Int
    let herdID: Int
    let position: CGPoint
    let heading: Double
    let routePosition: CGPoint
    let lateralOffset: Double
}

enum AudioCue: String, CaseIterable {
    case rifle, sniper, heavyGun, mortarLaunch, explosion, civilianScream, civilianRescue
    case zombieGroan, zombieAttack, barrierHit, warningAlarm, herdArrival
    case aircraftApproach, ac130Engine, ac130Cannon30, ac130Cannon105, b2Engine, bombRelease
    case a10Engine, a10Burst, humveeEngine, unitLost, victory, defeat
}

struct GameAudioEvent: Identifiable {
    let id: Int
    let cue: AudioCue
    let position: CGPoint
    let volume: Double
    var variant: Int = 0
    var sourceID: Int? = nil
}
