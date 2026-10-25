import SwiftUI
import QuartzCore

/// One display clock, fixed street-AI steps, and an independently paced HUD.
/// SceneKit interpolates each accepted snapshot on its render thread.
@MainActor
final class TacticalGameLoop: NSObject, ObservableObject {
    private var link: CADisplayLink?
    private var clock = FixedSimulationClock()
    private weak var game: GameEngine?
    private weak var audio: GameAudioController?
    private weak var interaction: TacticalSceneInteraction?
    private var nextHUD = 0.0
    private var missionID: UUID?
    private var currentSpeed = 1.0
    private var renderGroupInterval = 0.0
    private var renderGroupOpen = false

    func attach(game: GameEngine, audio: GameAudioController, interaction: TacticalSceneInteraction) {
        self.game = game; self.audio = audio; self.interaction = interaction
        synchronize()
    }

    func synchronize() {
        guard let game else { return }
        if renderGroupOpen { game.endRenderFrame() }
        missionID = game.missionID
        currentSpeed = game.speed
        clock = FixedSimulationClock(stepDuration:0.05/currentSpeed,maximumFrameInterval:0.1/currentSpeed)
        renderGroupInterval = 0; renderGroupOpen = false; nextHUD = 0
        audio?.update(game:game,focus:interaction?.focusPoint ?? game.map.initialFocus)
        interaction?.onSimulationFrame?(game)
        if game.phase == .running && TacticalPerformance.shared.active {
            UIApplication.shared.isIdleTimerDisabled = true
            if link == nil {
                let display = CADisplayLink(target:self,selector:#selector(frame(_:)))
                display.add(to:.main,forMode:.common); link = display
            }
            updateCadence()
        } else { stop() }
    }

    func updateCadence() {
        let fps = Float(TacticalPerformance.shared.framesPerSecond)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum:fps,maximum:fps,preferred:fps)
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        if renderGroupOpen { game?.endRenderFrame() }
        link?.invalidate(); link = nil; clock.reset(); renderGroupOpen = false; renderGroupInterval = 0
    }

    @objc private func frame(_ display: CADisplayLink) {
        guard let game, game.phase == .running, TacticalPerformance.shared.active else { stop(); return }
        if missionID != game.missionID { missionID = game.missionID; clock.reset(); nextHUD = 0 }
        if currentSpeed != game.speed {
            if renderGroupOpen { game.endRenderFrame(); interaction?.onSimulationFrame?(game) }
            currentSpeed = game.speed; clock = FixedSimulationClock(stepDuration:0.05/currentSpeed,maximumFrameInterval:0.1/currentSpeed)
            clock.reset(at:display.timestamp); renderGroupOpen = false; renderGroupInterval = 0
        }
        let plan = clock.advance(to:display.timestamp)
        guard plan.steps > 0 else { return }
        for _ in 0..<plan.steps {
            if !renderGroupOpen { game.beginRenderFrame(); renderGroupOpen = true }
            let began = CACurrentMediaTime()
            game.tick(dt:clock.stepDuration,publishSnapshot:false,captureRenderHistory:false)
            interaction?.recordWork?("AI",(CACurrentMediaTime()-began)*1_000)
            renderGroupInterval += clock.stepDuration
            if renderGroupInterval+0.000_000_01 >= 0.05 || game.phase != .running {
                game.endRenderFrame()
                interaction?.onSimulationFrame?(game)
                audio?.update(game:game,focus:interaction?.focusPoint ?? game.map.initialFocus)
                renderGroupInterval = max(0,renderGroupInterval-0.05); renderGroupOpen = false
            }
        }
        if display.timestamp >= nextHUD {
            nextHUD = display.timestamp + 0.2
            game.publishUI()
        }
    }
}
