import Foundation
import Darwin

/// Exercises the actual fixed-step clock and engine motion history used by the
/// native display driver. No display-link or SceneKit implementation is mocked.
@main
struct FrameInterpolationTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func near(_ first: Double, _ second: Double) -> Bool { abs(first - second) < 0.000_000_01 }
        func near(_ first: CGPoint, _ second: CGPoint) -> Bool { near(first.x, second.x) && near(first.y, second.y) }

        var clock = FixedSimulationClock()
        let initial = clock.advance(to: 10)
        expect(initial.steps == 0 && initial.acceptedInterval == 0, "the first display frame initializes the wall clock")
        var passes = 0, accepted = 0.0
        for frame in 1...60 {
            let plan = clock.advance(to: 10 + Double(frame) / 60)
            passes += plan.steps; accepted += plan.acceptedInterval
            expect(plan.interpolationFraction >= 0 && plan.interpolationFraction < 1,
                   "every display fraction stays between completed AI steps")
        }
        expect(passes == 20 && near(accepted, 1), "60 display frames produce exactly 20 fixed AI steps and preserve the accepted second")
        expect(near(clock.accumulatedInterval, 0), "one second has no timer-jitter remainder")

        clock.reset(at: 20)
        let jittered = clock.advance(to: 20.0501)
        expect(jittered.steps == 1 && near(jittered.interpolationFraction, 0.002), "a 50.1 ms frame performs one step and interpolates its 0.1 ms remainder")
        let next = clock.advance(to: 20.1)
        expect(next.steps == 1 && near(clock.accumulatedInterval, 0), "the next frame consumes the remainder without an extra microscopic AI step")
        let invalid = clock.advance(to: .nan)
        expect(invalid.steps == 0 && invalid.acceptedInterval == 0, "invalid system timestamps cannot reach the simulation")
        let backwards = clock.advance(to: 19)
        expect(backwards.steps == 0 && backwards.acceptedInterval == 0, "out-of-order timestamps do not rewind the accepted clock")
        let recovered = clock.advance(to: 20.15)
        expect(recovered.steps == 1, "recovering from an old timestamp cannot count the same time twice")
        let stall = clock.advance(to: 30)
        expect(stall.steps == 2 && near(stall.acceptedInterval, 0.1), "a long foreground stall has a bounded two-step catch-up")
        clock.reset()
        expect(clock.advance(to: 100).steps == 0 && clock.advance(to: 100.016).steps == 0,
               "reset after a pause discards paused wall time")

        let previous = RenderMotionState(position: .zero, heading: 179 * .pi / 180,
                                         stride: 6.2, speed: 3, altitude: 20, turretHeading: -.pi + 0.1, age: 2)
        let current = RenderMotionState(position: CGPoint(x: 9, y: 3), heading: -179 * .pi / 180,
                                        stride: 0.1, speed: 6, altitude: 14, turretHeading: .pi - 0.1, age: 2.05)
        let first = FrameInterpolation.sample(previous: previous, current: current, fraction: 1.0 / 3)
        let second = FrameInterpolation.sample(previous: previous, current: current, fraction: 2.0 / 3)
        expect(near(first.position, CGPoint(x: 3, y: 1)) && near(second.position, CGPoint(x: 6, y: 2)),
               "three display frames traverse a 20 Hz motion segment at equal distances")
        expect(first.heading > previous.heading && second.heading < .pi + 0.1,
               "a crossing of plus/minus pi rotates two degrees rather than taking the long turn")
        expect(first.stride > previous.stride && second.stride < 2 * .pi + 0.1,
               "wrapping a running stride cannot reverse or jump the limb animation")
        expect(near(FrameInterpolation.phase(from: 0.4, to: 5.2, fraction: 0.5), 2.8),
               "a three-times-speed surge advances a stride by more than pi instead of reversing its legs")
        expect(near(first.speed, 4) && near(first.altitude, 18) && near(first.age, 2 + 0.05 / 3),
               "speed, flying altitude and effect age interpolate at display cadence")
        expect(near(FrameInterpolation.sample(previous: previous, current: current, fraction: -1).position, previous.position)
               && near(FrameInterpolation.sample(previous: previous, current: current, fraction: 2).position, current.position),
               "fraction clamping cannot extrapolate through a building or before a spawn")
        expect(near(FrameInterpolation.sample(previous: nil, current: current, fraction: 0).position, current.position),
               "a newly spawned actor starts at its actual location rather than the origin")

        let game = GameEngine(city: .settat, defaults: nil)
        let initialCivilians = Dictionary(uniqueKeysWithValues: game.civilians.map { ($0.id, $0.position) })
        game.start()
        let initialPublication = game.revision
        game.tick(dt: 0.05, publishSnapshot: false)
        expect(game.revision == initialPublication && game.simulationRevision == 1,
               "a simulation frame updates render state without rebuilding the HUD")
        expect(near(game.previousRenderElapsed, 0) && near(game.renderSimulationInterval, 0.05),
               "the render history records its exact simulation interval")
        expect(game.civilians.allSatisfy { game.previousMotion(for: $0.id)?.position == initialCivilians[$0.id] },
               "the engine retains scalar prior poses without copying live actor arrays")
        let moving = game.civilians.first { $0.position != initialCivilians[$0.id] }
        expect(moving != nil, "real street AI supplies a moving civilian for the display interpolation check")
        if let moving {
            let currentPose = RenderMotionState(position: moving.position, heading: moving.heading,
                                                stride: moving.stride, speed: moving.speed)
            let rendered = (0...3).map { game.interpolatedMotion(for: moving.id, current: currentPose, fraction: Double($0) / 3).position }
            expect(near(rendered[0], initialCivilians[moving.id]!) && near(rendered[3], moving.position),
                   "display positions match both actual street-AI endpoints")
            expect(rendered[0] != rendered[1] && rendered[1] != rendered[2] && rendered[2] != rendered[3],
                   "the real civilian moves on every display frame instead of only at each AI tick")
            game.togglePause()
            let frozen = rendered[2], passes = game.simulationStepCount
            for _ in 0..<120 { game.tick(dt: 1.0 / 60, publishSnapshot: false) }
            expect(game.simulationStepCount == passes && near(game.interpolatedMotion(for: moving.id, current: currentPose, fraction: 2.0 / 3).position, frozen),
                   "a paused view keeps the rendered pose fixed across two seconds of display frames")
            game.togglePause()
        }
        let beforeFastTime = game.elapsed, beforeFastPasses = game.simulationStepCount
        game.setSpeed(3)
        game.tick(dt: 0.05, publishSnapshot: false)
        expect(near(game.elapsed - beforeFastTime, 0.15) && game.simulationStepCount - beforeFastPasses == 3,
               "accelerated play remains three bounded physics passes behind one display interval")
        expect(near(game.renderSimulationInterval, 0.15) && near(game.interpolatedElapsed(fraction: 0.5), beforeFastTime + 0.075),
               "aircraft and effect clocks interpolate the entire accelerated interval")
        let beforeHUD = game.revision
        game.publishUI()
        expect(game.revision == beforeHUD + 1, "the display driver can publish HUD metrics independently")
        game.reset(city: .settat)
        expect(game.simulationRevision == 0 && game.renderSimulationInterval == 0
               && game.previousMotion(for: game.civilians[0].id) == nil,
               "retry removes old motion history even when stable actor IDs are reused")
        let squadPoint = game.map.nearestRoadPoint(to: game.arrivals[0].sourcePosition)
        game.selectTool(.squad); game.tap(at: squadPoint)
        let squad = game.units[0], oldFormation = squad.formation
        game.selectTool(nil); game.tap(at: squad.position)
        game.start()
        let direction = game.map.roadDirection(at: squad.position)
        game.moveSelected(to: CGPoint(x: squad.position.x + direction.dx * game.map.metersToWorld * 20,
                                     y: squad.position.y + direction.dy * game.map.metersToWorld * 20))
        game.tick(dt: 0.05, publishSnapshot: false)
        let movedSquad = game.units[0]
        expect(game.previousCrewPosition(unitID: squad.id, index: 0) == oldFormation[0],
               "street-turn formation interpolation retains the actual previous soldier position")
        let crewMidpoint = game.interpolatedCrewPosition(unitID: squad.id, index: 0, current: movedSquad.formation[0], fraction: 0.5)
        expect(near(crewMidpoint, CGPoint(x: (oldFormation[0].x + movedSquad.formation[0].x) / 2,
                                         y: (oldFormation[0].y + movedSquad.formation[0].y) / 2)),
               "individual crew members interpolate their formation, as well as the unit centre")
        let herd = GameEngine(city: .settat, defaults: nil)
        let exteriorPositions = Dictionary(uniqueKeysWithValues: herd.stagedHerdMembers.map { ($0.id, $0.position) })
        herd.start()
        while herd.zombies.isEmpty && herd.phase == .running { herd.tick(dt: 0.05, publishSnapshot: false) }
        let activated = herd.zombies[0]
        expect(herd.previousMotion(for: activated.id)?.position == exteriorPositions[activated.id],
               "an existing exterior herd member retains its visible position when live AI activates")
        expect(herd.interpolatedMotion(for: activated.id, current: RenderMotionState(position: activated.position), fraction: 0).position == exteriorPositions[activated.id],
               "a staged-to-active zombie cannot skip the first smooth display-motion frame")
        for multiplier in 1...3 {
            let distributed = GameEngine(city: .settat, defaults: nil)
            distributed.start(); distributed.setSpeed(Double(multiplier))
            let initialUIRevision = distributed.revision
            let wallStep = 0.05 / Double(multiplier)
            var wallClock = FixedSimulationClock(stepDuration: wallStep,maximumFrameInterval:wallStep*2)
            wallClock.reset(at: 0)
            var stalled = FixedSimulationClock(stepDuration:wallStep,maximumFrameInterval:wallStep*2)
            stalled.reset(at:0)
            let stall = stalled.advance(to:0.2)
            expect(stall.steps == 2,"foreground stalls never enqueue more than two accelerated AI passes")
            expect(near(stall.acceptedInterval,wallStep*2),"catch-up clamping scales with the accelerated step duration")
            var groupOpen = false, groupWallInterval = 0.0, completedGroups = 0
            var groupStartElapsed = 0.0, groupStartPosition = CGPoint.zero, oldRenderInterval = 0.0
            let trackedID = distributed.civilians[0].id
            var singlePasses = true, preservedHistory = true, completeIntervals = true, smoothSamples = true
            for displayFrame in 1...60 {
                let plan = wallClock.advance(to: Double(displayFrame) / 60)
                for _ in 0..<plan.steps {
                    if !groupOpen {
                        groupOpen = true
                        groupStartElapsed = distributed.elapsed
                        groupStartPosition = distributed.civilians[0].position
                        oldRenderInterval = distributed.renderSimulationInterval
                        distributed.beginRenderFrame()
                    }
                    let beforeStep = distributed.simulationStepCount
                    distributed.tick(dt: wallStep, publishSnapshot: false, captureRenderHistory: false)
                    singlePasses = singlePasses && distributed.simulationStepCount == beforeStep + 1
                    preservedHistory = preservedHistory
                        && distributed.previousRenderElapsed == groupStartElapsed
                        && distributed.previousMotion(for: trackedID)?.position == groupStartPosition
                        && distributed.renderSimulationInterval == oldRenderInterval
                    groupWallInterval += wallStep
                    if groupWallInterval + 0.000_000_001 >= 0.05 {
                        distributed.endRenderFrame()
                        completeIntervals = completeIntervals
                            && near(distributed.renderSimulationInterval, 0.05 * Double(multiplier))
                            && near(distributed.elapsed - groupStartElapsed, distributed.renderSimulationInterval)
                        let current = RenderMotionState(position: distributed.civilians[0].position)
                        let beginning = distributed.interpolatedMotion(for: trackedID, current: current, fraction: 0)
                        let midpoint = distributed.interpolatedMotion(for: trackedID, current: current, fraction: 0.5)
                        let end = distributed.interpolatedMotion(for: trackedID, current: current, fraction: 1)
                        smoothSamples = smoothSamples
                            && near(beginning.position, groupStartPosition) && near(end.position, current.position)
                            && near(midpoint.position, CGPoint(x: (groupStartPosition.x + current.position.x) / 2,
                                                              y: (groupStartPosition.y + current.position.y) / 2))
                        completedGroups += 1; groupOpen = false
                        groupWallInterval = max(0, groupWallInterval - 0.05)
                    }
                }
            }
            expect(singlePasses && distributed.simulationStepCount == 20 * multiplier,
                   "\(multiplier)x display scheduling distributes exactly one 50 ms physics pass per wall update")
            expect(preservedHistory, "\(multiplier)x intermediate physics frames preserve the original render-group poses")
            expect(completeIntervals && completedGroups == 20 && !groupOpen && near(distributed.elapsed, Double(multiplier)),
                   "\(multiplier)x play conserves a complete second in twenty 50 ms render groups")
            expect(smoothSamples, "\(multiplier)x render interpolation spans the whole accelerated group, rather than its last physics step")
            expect(distributed.revision == initialUIRevision,
                   "\(multiplier)x distributed physics cannot force a SwiftUI refresh at display cadence")
            expect(distributed.renderRevision == completedGroups,
                   "\(multiplier)x presentation revisions advance only at completed motion groups")
        }
        print("PASS: \(checks) fixed-step and display-interpolation checks")
    }
}
