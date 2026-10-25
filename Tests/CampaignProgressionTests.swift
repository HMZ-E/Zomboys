import Foundation
import Darwin

@main
struct CampaignProgressionTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAILED: " + description) }
            checks += 1
        }
        let lower = CampaignRules.score(survivors: 89, kills: 1_000_000, elapsed: 0, won: true)
        let higher = CampaignRules.score(survivors: 90, kills: 0, elapsed: 900, won: true)
        expect(higher > lower, "One survivor outweighs unlimited kills and speed")
        expect(CampaignRules.rewardTier(survival: 0, objective: 0.5) == 0, "No survivors cannot earn a power reward")
        let first = CampaignRules.improvedBest(previous: nil, survivors: 30, population: 100, score: 300_000, objective: 0.5)
        expect(first.reward == 1 && first.best.grade == .contained, "Low survival earns the first finite tier only")
        let improved = CampaignRules.improvedBest(previous: first.best, survivors: 70, population: 100, score: 700_000, objective: 0.5)
        expect(improved.reward == 1 && improved.best.awardedTier == 2, "Better survival pays only the newly earned tier")
        let excellent = CampaignRules.improvedBest(previous: improved.best, survivors: 99, population: 100, score: 990_000, objective: 0.5)
        expect(excellent.reward == 1 && excellent.best.grade == .diamond, "Excellent survival reaches the final tier")
        let replay = CampaignRules.improvedBest(previous: excellent.best, survivors: 50, population: 100, score: 500_000, objective: 0.5)
        expect(replay.reward == 0 && replay.best.survivors == 99, "A worse replay preserves best and cannot farm rewards")
        expect(CampaignDistrict.neighborhood.next == .district && CampaignDistrict.district.next == .citywide && CampaignDistrict.citywide.next == nil, "Campaign has exactly three expanding operations")

        for city in CityScenario.allCases {
            let suite = "CampaignChecks." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let game = GameEngine(city: city, defaults: defaults, missionSeed: city.seed)
            expect(game.outbreakMode == .siege && game.initialPopulation == city.population && !game.arrivals.isEmpty, "Default operation preserves exterior siege")
            expect(game.purchaseUpgrade(.squad), "Planning can specialize an existing roster unit")
            let spent = game.upgradePoints
            expect(game.respecLoadout() && game.upgradePoints == spent + 1 && game.upgradeLevels.isEmpty, "Free respec returns exactly invested points")
            expect(!game.respecLoadout(), "An empty respec cannot create more points")
            game.beginOperation(city: city, mode: .cityOutbreak, district: .citywide)
            expect(game.outbreakMode == .siege, "Locked campaign stages cannot be started through the public API")
            game.beginOperation(city: city, mode: .cityOutbreak, district: .neighborhood, missionSeed: city.seed)
            expect(game.initialPopulation == city.population / 4 && game.arrivals.isEmpty && game.stagedHerdMembers.isEmpty, "Neighborhood uses actual smaller population without exterior columns")
            expect(game.zombies.isEmpty && game.infectionOrigins.isEmpty && game.missionBounds != nil, "Outbreak location is concealed throughout planning")
            expect(game.civilians.allSatisfy { game.missionBounds!.contains($0.position) }, "Every neighborhood civilian starts inside the displayed catchment")
            let populationIDs = Set(game.civilians.map(\.id))
            game.start()
            expect(game.zombies.count == 18 && game.infectionOrigins.count == 1, "Starting creates eighteen real initial infected")
            expect(Set(game.zombies.map(\.id)).isDisjoint(with: populationIDs), "Initial infected have unique identities")
            expect(!game.respecLoadout() && !game.purchaseUpgrade(.squad), "Combat cannot reallocate or buy specialization")
            game.reset(city: city)
            game.selectTool(.squad)
            game.tap(at: game.civilians[0].position)
            expect(game.units.count == 1, "A normal paid defense can be retained between districts")
            game.campaignTestDamageFirstDefense(fraction: 0.40)
            for _ in 0..<5 {
                expect(game.purchaseUpgrade(.squad) && game.respecLoadout(), "Planning allows reversible loadout experiments")
                expect(abs(game.units[0].health / game.units[0].maxHealth - 0.40) < 0.000_001, "Repeated purchase and free respec cannot repair damaged defenses")
            }
            let retained = game.units[0]
            let initialPoints = game.upgradePoints
            game.campaignTestFinish(survivors: game.initialPopulation)
            expect(game.phase == .won && game.lastProgressReward == 3 && game.upgradePoints == initialPoints + 3, "Production victory records survivor best and pays three finite points")
            expect(game.canContinueCampaign && game.isDistrictUnlocked(.district, in: city), "Meeting the survivor objective unlocks the next district")
            expect(game.continueCampaign(), "Continue expands to the next mission")
            expect(game.campaignDistrict == .district && game.initialPopulation == city.population / 2, "Expansion creates the true next population")
            expect(game.units.count == 1 && game.units[0].position == retained.position && game.units[0].health == retained.health, "Surviving paid unit retains placement and current health")
            expect(Set(game.units.map(\.id)).isDisjoint(with: Set(game.civilians.map(\.id))), "Retained unit ID is outside newly spawned civilian IDs")
            game.start()
            expect(game.zombies.count == 26, "District outbreak starts with twenty-six initial infected")
            game.campaignTestFinish(survivors: game.initialPopulation)
            expect(game.continueCampaign() && game.campaignDistrict == .citywide && game.missionBounds == nil, "Final stage expands the initial population throughout the city")
            expect(game.initialPopulation == city.population, "Citywide population matches the existing city scenario")
            game.start()
            expect(game.zombies.count == 36 && game.zombies.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite }, "Citywide has thirty-six finite-position initial infected")
            game.campaignTestFinish(survivors: game.initialPopulation)
            expect(!game.canContinueCampaign && game.completedCities.contains(city), "Citywide completion ends expansion and records the secured city")
            let restored = GameEngine(city: city, defaults: defaults)
            expect(restored.upgradePoints == game.upgradePoints && restored.missionBests == game.missionBests, "Best results, unlocks and finite points survive relaunch")
            expect(restored.isDistrictUnlocked(.citywide, in: city), "Saved district best restores campaign unlocks")
            let beforeReplay = restored.upgradePoints
            restored.beginOperation(city: city, mode: .cityOutbreak, district: .neighborhood)
            restored.campaignTestFinish(survivors: restored.initialPopulation)
            expect(restored.upgradePoints == beforeReplay && restored.lastProgressReward == 0, "A repeated completed campaign operation gives no additional power")
            restored.reset(city: city)
            let pointsBeforeLoss = restored.upgradePoints
            restored.campaignTestFinish(survivors: 0)
            expect(restored.phase == .lost && restored.lastProgressReward == 0 && restored.upgradePoints == pointsBeforeLoss, "Eliminating all infected after every civilian died is a defeat with no reward")
            defaults.removePersistentDomain(forName: suite)
        }
        print("PASS: \(checks) campaign and survivor-progression checks")
    }
}
