import Foundation
import Darwin

@main
struct SupportTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func game() -> GameEngine { GameEngine(city: .settat, defaults: nil) }
        func run(_ game: GameEngine, until time: Double) {
            while game.elapsed + 0.000_000_1 < time && game.phase == .running {
                game.tick(dt: min(0.25, time - game.elapsed))
            }
        }
        func population(_ game: GameEngine) -> Int {
            game.civilians.count + game.mobilizedCivilianCount + game.saved + game.casualties
        }
        let planning = game()
        for kind in TacticalSupportKind.allCases {
            let budget = planning.budget
            expect(!planning.performSupport(kind, at: planning.map.initialFocus)
                   && planning.budget == budget && planning.supportUsesRemaining(kind) == 1,
                   "planning rejects \(kind) without charging or consuming its reserve")
        }
        planning.chooseSupport(.gasBomb)
        expect(planning.selectedTool == nil && planning.selectedSupport == .gasBomb && planning.selectedUnit == nil,
               "tactical targeting replaces ground deployment selection")
        planning.selectTool(.squad)
        expect(planning.selectedSupport == nil, "ground tools cancel tactical targeting")

        let airborne = game(); airborne.start()
        let landing = airborne.map.nearestRoadPoint(to: airborne.arrivals[0].sourcePosition)
        let airborneFunds = airborne.budget
        expect(airborne.performSupport(.paratroopers, at: landing), "a paid airborne reserve accepts a land target")
        expect(airborne.budget == airborneFunds - TacticalSupportKind.paratroopers.cost
               && airborne.units.isEmpty && airborne.supportAreas.first?.kind == .paratroopers,
               "airborne troops have a visible descent before they become ground units")
        run(airborne, until: 2.9)
        expect(airborne.units.isEmpty, "troops cannot shoot before landing")
        run(airborne, until: 3.1)
        expect(airborne.units.count == 2 && airborne.units.allSatisfy { $0.kind == .squad && airborne.crewCount(for: $0.id) == 5 },
               "the completed drop creates two real five-person rifle squads")
        expect(airborne.units.allSatisfy { airborne.map.isRoad($0.position) && !airborne.map.containsBuilding($0.position) },
               "the landing squads occupy actual public streets")
        expect(airborne.supportAreas.isEmpty && airborne.supportUsesRemaining(.paratroopers) == 0,
               "the descent disappears and the reserve stays consumed")
        let afterDropBudget = airborne.budget
        expect(!airborne.performSupport(.paratroopers, at: landing) && airborne.budget == afterDropBudget,
               "a used airborne reserve cannot charge the player twice")
        run(airborne, until: airborne.arrivals[0].departureAt + 8)
        expect(airborne.kills > 0, "the dropped squads use ordinary live combat and eliminate actual incoming zombies")

        let gas = game(); gas.start()
        run(gas, until: gas.arrivals[0].departureAt + 4)
        expect(!gas.zombies.isEmpty, "the gas check waits for an actual exterior column")
        let zombie = gas.zombies[0], target = zombie.position
        let gasBudget = gas.budget, gasCasualties = gas.casualties
        expect(gas.performSupport(.gasBomb, at: target) && gas.budget == gasBudget - TacticalSupportKind.gasBomb.cost,
               "a stun cloud charges its single paid reserve")
        let gasStart = gas.elapsed
        run(gas, until: gasStart + 1)
        expect(gas.zombies.first(where: { $0.id == zombie.id })?.position == target
               && gas.zombies.first(where: { $0.id == zombie.id })?.speed == 0,
               "actual zombies stop moving inside the persistent stun cloud")
        expect(gas.casualties == gasCasualties && gas.supportAreas.contains(where: { $0.kind == .gasBomb }),
               "the cloud remains visible and does not kill civilians")
        run(gas, until: gasStart + 8.5)
        expect(!gas.supportAreas.contains(where: { $0.kind == .gasBomb })
               && gas.zombies.first(where: { $0.id == zombie.id })?.position != target,
               "zombies resume their existing street route after the gas dissipates")

        let arms = game(); arms.start()
        let armsTarget = arms.civilians[0].position
        let originalCivilianIDs = Set(arms.civilians.map(\.id)), armsBudget = arms.budget
        expect(arms.performSupport(.callToArms, at: armsTarget), "a populated street accepts call to arms")
        let mobilized = arms.mobilizedCivilianCount
        expect(mobilized > 0 && mobilized <= 12 && arms.units.count == mobilized,
               "call to arms recruits actual nearby residents into individual armed defenders")
        expect(arms.budget == armsBudget - TacticalSupportKind.callToArms.cost && arms.saved == 0
               && arms.civilians.count + mobilized == arms.initialPopulation && population(arms) == arms.initialPopulation,
               "armed residents remain in population accounting and are not reported as evacuated")
        expect(arms.activeCivilianCount == arms.initialPopulation && arms.survivalRate == 1,
               "arming a resident cannot lower the survivor HUD or inflate the score")
        expect(arms.units.allSatisfy { arms.crewCount(for: $0.id) == 1 && $0.formation.count == 1 && originalCivilianIDs.isDisjoint(with: [$0.id]) },
               "each armed resident has one actual body rather than five invented squad members")
        expect(arms.units.reduce(0) { $0 + $1.purchaseCost } <= TacticalSupportKind.callToArms.cost,
               "resident weapon refunds cannot manufacture money by withdrawing newly armed defenders")
        let convertedUnit = arms.units[0]
        expect(convertedUnit.position == armsTarget, "the first resident arms where they stood instead of teleporting to a formation")
        arms.selectTool(nil); arms.tap(at: convertedUnit.position)
        let beforeWithdrawal = arms.mobilizedCivilianCount
        arms.removeSelected()
        expect(arms.mobilizedCivilianCount == beforeWithdrawal - 1 && population(arms) == arms.initialPopulation
               && arms.saved == 0 && Set(arms.civilians.map(\.id)).isSubset(of: originalCivilianIDs),
               "withdrawing an armed resident returns the original civilian and preserves the survival objective")
        if let remaining = arms.units.first {
            expect(arms.performSupport(.fireBomb, at: remaining.position), "incendiary support can threaten armed residents too")
            run(arms, until: 1.2)
            expect(arms.mobilizedCivilianCount < beforeWithdrawal - 1 && arms.casualties > 0
                   && population(arms) == arms.initialPopulation,
                   "resident combat deaths become civilian casualties rather than disappearing from the population")
        }

        let fire = game(); fire.start()
        let victim = fire.civilians.first { civilian in
            fire.map.buildingIndices(near: civilian.position, radius: fire.map.metersToWorld * 12).contains {
                fire.map.distanceToBuilding(at: $0, from: civilian.position) < fire.map.metersToWorld * 12
            }
        }!
        let fireBudget = fire.budget
        expect(fire.performSupport(.fireBomb, at: victim.position), "a paid fire bomb strikes the aimed city street")
        expect(fire.budget == fireBudget - TacticalSupportKind.fireBomb.cost
               && fire.supportAreas.filter { $0.kind == .fireBomb }.count == 3,
               "the strike creates three real lasting fire areas")
        expect(fire.casualties > 0 && !fire.civilians.contains(where: { $0.id == victim.id })
               && fire.destructionRevision > 1 && !fire.buildingDamage.isEmpty,
               "incendiary impacts damage actual buildings and kill nearby civilians")
        let structuralAfterImpact = fire.buildingDamage.values.reduce(0, +)
        run(fire, until: 2)
        expect(fire.buildingDamage.values.reduce(0, +) > structuralAfterImpact
               && fire.supportAreas.filter { $0.kind == .fireBomb }.count == 3,
               "continuing flames cause additional structural damage after the impact animation")
        run(fire, until: 10.2)
        expect(fire.supportAreas.isEmpty && population(fire) == fire.initialPopulation,
               "burning streets expire after ten seconds without losing civilian accounting")
        fire.reset(city: .settat)
        expect(fire.supportAreas.isEmpty && fire.mobilizedCivilianCount == 0
               && TacticalSupportKind.allCases.allSatisfy { fire.supportUsesRemaining($0) == 1 },
               "retry clears hazards and restores each limited reserve")
        print("PASS: \(checks) paid tactical-support gameplay checks")
    }
}
