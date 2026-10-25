import SwiftUI

@main
struct ZomboysApp: App {
    @StateObject private var game: GameEngine
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let testing = arguments.contains("--uitesting")
        let cityArgument = arguments.first { $0.hasPrefix("--uitesting-city=") }?.split(separator: "=").last.map(String.init)
        let city = testing ? cityArgument.flatMap(CityScenario.init(rawValue:)) ?? .settat : .settat
        let engine = GameEngine(city: city, defaults: testing ? nil : .standard, missionSeed: testing ? city.seed : UInt64.random(in: 1...UInt64.max))
        // A reproducible, unsaved test workload on device or simulator.
        if testing && arguments.contains("--uitesting-run") {
            engine.selectTool(nil); engine.start()
            let speed = arguments.first { $0.hasPrefix("--uitesting-speed=") }?.split(separator:"=").last.flatMap { Double($0) } ?? 3
            engine.setSpeed(speed)
        }
        _game = StateObject(wrappedValue: engine)
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CommandView(game: game)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active && game.phase == .running {
                        game.togglePause()
                    }
                }
        }
    }
}
