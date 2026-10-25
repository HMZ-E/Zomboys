import AVFoundation
import SwiftUI

/// Spatial sound with independent weapon voices, bounded polyphony and aircraft pass envelopes.
@MainActor
final class GameAudioController: ObservableObject {
    @Published var muted: Bool { didSet { save(); if muted { stop() } } }
    @Published var effectsVolume: Double { didSet { save() } }
    @Published var aircraftVolume: Double { didSet { save() } }
    private struct Voice { let player: AVAudioPlayer; let priority: Int }
    private struct GateKey: Hashable { let cue: AudioCue; let source: Int }
    private struct LoopVoice {
        let player: AVAudioPlayer
        var position: CGPoint?
        var time: TimeInterval
        var volume: Float
        var rate: Float
    }
    private var voices: [Voice] = []
    private var retiring: [ObjectIdentifier: AVAudioPlayer] = [:]
    private var loops: [Int: LoopVoice] = [:]
    private var data: [String: Data] = [:]
    private var lastPlayed: [GateKey: TimeInterval] = [:]
    private var sessionReady = false
    private var interrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private var lastMission: UUID?
    private var lastPhase: GamePhase?
    private var duckUntil: TimeInterval = 0
    private let defaults: UserDefaults?

    init() {
        let defaults: UserDefaults? = ProcessInfo.processInfo.arguments.contains("--uitesting") ? nil : .standard
        self.defaults = defaults
        muted = defaults?.bool(forKey: "sound.muted") ?? false
        effectsVolume = defaults?.object(forKey: "sound.effects") as? Double ?? 0.72
        aircraftVolume = defaults?.object(forKey: "sound.aircraft") as? Double ?? 0.25
        for cue in AudioCue.allCases where !isCrowdCue(cue) {
            let count = cue == .rifle || cue == .sniper ? 4 : 1
            for variant in 0..<count { cache(asset(for: cue, variant: variant)) }
        }
        cache("bomb_fall")
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor [weak self] in
                self?.interrupted = began
                self?.sessionReady = false
                if began { self?.stop() }
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func update(game: GameEngine, focus: CGPoint) {
        let events = game.drainAudioEvents()
        if lastMission != game.missionID {
            if lastMission != nil { stop() }
            lastPlayed.removeAll(); lastMission = game.missionID
        }
        voices.removeAll { !$0.player.isPlaying }
        guard !muted, !interrupted else { return }
        if game.phase != .running && lastPhase != game.phase {
            // Shots already fired keep their natural decay, including the complete GAU-8 burst.
            // No new combat cue starts while paused; engines and whistles gently recede.
            stopLoops()
        }
        lastPhase = game.phase
        // Drained combat cues must not restart sound after the user has paused.
        guard game.phase == .running || game.phase.isFinished else { return }
        for event in events {
            play(event.cue, variant: event.variant, sourceID: event.sourceID,
                 at: event.position, focus: focus, gain: event.volume)
        }
        guard game.phase == .running else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let duck: Float = now < duckUntil ? 0.16 : 1
        var active = Set<Int>()
        for flight in game.flights {
            let cue: AudioCue = flight.kind == .ac130 ? .ac130Engine : (flight.kind == .b2 ? .b2Engine : .a10Engine)
            let distance = hypot(flight.position.x - focus.x, flight.position.y - focus.y)
            let ramp = flight.kind == .ac130 ? 0.055 : 0.16
            let approach = smoothStep(min(1, flight.progress / ramp))
            let departure = smoothStep(min(1, (1 - flight.progress) / ramp))
            let pass = approach * departure
            let gain = flight.kind == .ac130 ? 0.4 : (flight.kind == .b2 ? 0.75 : 0.6)
            let volume = Float(aircraftVolume * gain * pass / (1 + distance / 600)) * duck
            loop(id: flight.id, asset: asset(for: cue), volume: volume,
                 pan: pan(at: flight.position, focus: focus), position: flight.position, focus: focus, now: now)
            active.insert(flight.id)
        }
        // The whistle tracks the actual projectile and gently merges into the impact report.
        for bomb in game.projectiles where bomb.kind == .bomb {
            let distance = hypot(bomb.position.x - focus.x, bomb.position.y - focus.y)
            let intensity = smoothStep(min(1, bomb.progress / 0.12)) * (0.12 + bomb.progress * 0.5)
            loop(id: bomb.id, asset: "bomb_fall", volume: Float(effectsVolume * intensity / (1 + distance / 420)),
                 pan: pan(at: bomb.position, focus: focus), rate: Float(0.72 + bomb.progress * 0.68), now: now)
            active.insert(bomb.id)
        }
        let vehicles = game.units.filter { $0.kind == .humvee && (!$0.holding || $0.targetPosition != nil) }
            .sorted { hypot($0.position.x - focus.x, $0.position.y - focus.y) < hypot($1.position.x - focus.x, $1.position.y - focus.y) }
            .prefix(3)
        for vehicle in vehicles {
            let distance = hypot(vehicle.position.x - focus.x, vehicle.position.y - focus.y)
            loop(id: vehicle.id, asset: "humvee_engine", volume: Float(aircraftVolume * 0.3 / (1 + distance / 300)) * duck,
                 pan: pan(at: vehicle.position, focus: focus), now: now)
            active.insert(vehicle.id)
        }
        for id in Array(loops.keys) where !active.contains(id) {
            if let voice = loops.removeValue(forKey: id) { retire(voice.player, duration: 0.2) }
        }
        voices.removeAll { !$0.player.isPlaying }
        // Long missions cannot keep accumulating IDs of destroyed weapons.
        if lastPlayed.count > 256 { lastPlayed = lastPlayed.filter { now - $0.value < 8 } }
    }

    func previewBRRRT() {
        // A second tap must not restart or shorten the burst that is already playing.
        guard !voices.contains(where: { $0.priority == 4 && $0.player.isPlaying }) else { return }
        play(.a10Burst, at: .zero, focus: .zero, gain: 1, bypassGate: true)
    }
    func stop() {
        voices.forEach { retire($0.player, duration: $0.priority == 4 ? 0.3 : 0.1) }
        voices.removeAll(); stopLoops()
        lastPlayed.removeAll(keepingCapacity: true)
        duckUntil = 0
    }
    private func stopLoops() {
        loops.values.forEach { retire($0.player, duration: 0.2) }
        loops.removeAll()
    }
    private func retire(_ player: AVAudioPlayer, duration: TimeInterval) {
        guard player.isPlaying else { return }
        let id = ObjectIdentifier(player)
        guard retiring[id] == nil else { return }
        // AVAudioPlayer performs the ramp on its audio thread, even when simulation is paused.
        retiring[id] = player
        player.setVolume(0, fadeDuration: duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self, player] in
            player.stop()
            self?.retiring.removeValue(forKey: id)
        }
    }
    private func save() {
        defaults?.set(muted, forKey: "sound.muted")
        defaults?.set(effectsVolume, forKey: "sound.effects")
        defaults?.set(aircraftVolume, forKey: "sound.aircraft")
    }
    private func prepareSession() -> Bool {
        guard !interrupted else { return false }
        if sessionReady { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sessionReady = true
            return true
        } catch { return false }
    }
    private func play(_ cue: AudioCue, variant: Int = 0, sourceID: Int? = nil,
                      at position: CGPoint, focus: CGPoint, gain: Double, bypassGate: Bool = false) {
        guard !muted, !interrupted, !isCrowdCue(cue) else { return }
        if cue == .a10Burst, voices.contains(where: { $0.priority == 4 && $0.player.isPlaying }) { return }
        let now = Date.timeIntervalSinceReferenceDate
        let gate: Double
        let independent: Bool
        switch cue {
        case .a10Burst: gate = 0.1; independent = false // The live player, including its tail, is the gate.
        case .rifle: gate = 0.09; independent = true
        case .sniper: gate = 0.3; independent = true
        case .heavyGun: gate = 0.11; independent = true
        case .zombieGroan, .zombieAttack, .civilianScream: return
        case .ac130Cannon30: gate = 0.14; independent = true
        case .ac130Cannon105: gate = 0.3; independent = true
        case .aircraftApproach, .ac130Engine, .b2Engine, .a10Engine, .humveeEngine: return
        default: gate = 0.12; independent = false
        }
        let spatialSource = Int(position.x / 32) * 100003 + Int(position.y / 32)
        let key = GateKey(cue: cue, source: independent ? (sourceID ?? spatialSource) : 0)
        guard bypassGate || now - lastPlayed[key, default: 0] >= gate else { return }
        let local = cue == .rifle || cue == .sniper || cue == .heavyGun
            || cue == .mortarLaunch || cue == .barrierHit || cue == .civilianRescue
        let priority = cue == .a10Burst ? 4 : ((cue == .explosion || cue == .ac130Cannon105) ? 3 : (cue == .sniper ? 2 : 1))
        let distance = hypot(position.x - focus.x, position.y - focus.y)
        if local && distance > 1400 { return }
        let outcome = cue == .victory || cue == .defeat
        let distantFloor = priority == 4 ? 0.65 : ((cue == .warningAlarm || cue == .herdArrival) ? 0.35 : 0.045)
        let attenuation = outcome ? 1 : (local ? 1 / (1 + pow(distance / 260, 2))
            : max(distantFloor, 1 / (1 + distance / 450)))
        let duck = now < duckUntil && priority < 3 ? 0.7 : 1
        let volume = Float(min(1, effectsVolume * gain * attenuation * duck))
        // Reject inaudible or lower-value voices before constructing/decoding a player.
        guard volume >= 0.008 else { return }
        voices.removeAll { !$0.player.isPlaying }
        var eviction: Int?
        if voices.count >= 18 {
            guard let index = voices.indices.filter({ voices[$0].priority < 4 }).min(by: {
                voices[$0].priority == voices[$1].priority
                    ? voices[$0].player.volume < voices[$1].player.volume
                    : voices[$0].priority < voices[$1].priority
            }), voices[index].priority <= priority else { return }
            // Let equal-value reports finish instead of constantly replacing their tails.
            if voices[index].priority == priority && volume <= voices[index].player.volume * 1.35 { return }
            eviction = index
        }
        guard let bytes = data[asset(for: cue, variant: variant)],
              let player = try? AVAudioPlayer(data: bytes), prepareSession() else { return }
        player.volume = volume; player.pan = outcome ? 0 : pan(at: position, focus: focus)
        player.prepareToPlay()
        guard player.play() else { return }
        if let eviction { retire(voices.remove(at: eviction).player, duration: 0.06) }
        voices.append(Voice(player: player, priority: priority))
        lastPlayed[key] = now
        if cue == .a10Burst || cue == .explosion {
            duckUntil = max(duckUntil, now + (cue == .a10Burst ? player.duration : 0.55))
        }
    }
    private func loop(id: Int, asset name: String, volume: Float, pan: Float, rate: Float = 1,
                      position: CGPoint? = nil, focus: CGPoint? = nil, now: TimeInterval) {
        var targetRate = rate
        if var voice = loops[id] {
            let elapsed = max(0.001, min(0.25, now - voice.time))
            if let position, let previous = voice.position, let focus {
                let oldDistance = hypot(previous.x - focus.x, previous.y - focus.y)
                let distance = hypot(position.x - focus.x, position.y - focus.y)
                let radialSpeed = (oldDistance - distance) / elapsed
                targetRate = Float(min(1.08, max(0.92, 1 + radialSpeed / 14000)))
            }
            let blend = Float(1 - exp(-elapsed * 8))
            voice.volume += (volume - voice.volume) * blend
            voice.rate += (targetRate - voice.rate) * blend
            voice.player.volume = voice.volume
            voice.player.pan += (pan - voice.player.pan) * blend
            voice.player.rate = voice.rate
            voice.position = position; voice.time = now
            loops[id] = voice
            return
        }
        guard volume > 0.001, let bytes = data[name], let player = try? AVAudioPlayer(data: bytes) else { return }
        guard prepareSession() else { return }
        player.numberOfLoops = -1; player.enableRate = true
        player.rate = targetRate; player.volume = 0; player.pan = pan
        player.prepareToPlay()
        guard player.play() else { return }
        loops[id] = LoopVoice(player: player, position: position, time: now, volume: 0, rate: targetRate)
    }
    private func isCrowdCue(_ cue: AudioCue) -> Bool {
        cue == .civilianScream || cue == .zombieGroan || cue == .zombieAttack
    }
    private func smoothStep(_ value: Double) -> Double { value * value * (3 - 2 * value) }
    private func pan(at position: CGPoint, focus: CGPoint) -> Float { Float(min(0.9, max(-0.9, (position.x - focus.x) / 650))) }
    private func cache(_ name: String) {
        if data[name] == nil, let url = assetURL(name), let bytes = try? Data(contentsOf: url) { data[name] = bytes }
    }
    private func assetURL(_ name: String) -> URL? {
        for ext in ["wav", "mp3", "m4a"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/Audio") { return url }
        }
        return nil
    }
    private func asset(for cue: AudioCue, variant: Int = 0) -> String {
        let voice = ((variant % 4) + 4) % 4
        switch cue {
        case .rifle: return "rifle_\(voice)"
        case .sniper: return "sniper_\(voice)"
        case .heavyGun: return "heavy_gun"
        case .mortarLaunch: return "mortar_launch"
        case .explosion: return "explosion"
        case .civilianScream: return "civilian_scream"
        case .civilianRescue: return "rescue"
        case .zombieGroan: return "zombie_groan"
        case .zombieAttack: return "zombie_attack"
        case .barrierHit: return "barrier_hit"
        case .warningAlarm, .herdArrival: return "warning"
        case .aircraftApproach, .a10Engine: return "a10_engine"
        case .ac130Engine: return "ac130_engine"
        case .b2Engine: return "b2_engine"
        case .ac130Cannon30: return "cannon30"
        case .ac130Cannon105: return "cannon105"
        case .bombRelease: return "bomb_release"
        case .a10Burst: return "a10_brrrt"
        case .humveeEngine: return "humvee_engine"
        case .unitLost: return "unit_lost"
        case .victory: return "victory"
        case .defeat: return "defeat"
        }
    }
}

struct SoundSettingsView: View {
    @ObservedObject var audio: GameAudioController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SheetShell(eyebrow: "COMBAT AUDIO", title: "AUDIO", close: { dismiss() }) {
            VStack(alignment: .leading, spacing: 26) {
                Toggle("SOUND ENABLED", isOn: Binding(get: { !audio.muted }, set: { audio.muted = !$0 }))
                    .font(CommandTheme.mono(12, weight: .bold)).tint(CommandTheme.lime).accessibilityIdentifier("sound.enabled")
                volume("WEAPONS & EXPLOSIONS", value: $audio.effectsVolume)
                volume("AIRCRAFT & VEHICLES", value: $audio.aircraftVolume)
                Button { audio.previewBRRRT() } label: { Label("TEST THE A-10 BRRRT", systemImage: "speaker.wave.3.fill") }
                    .buttonStyle(TacticalButton(primary: true)).disabled(audio.muted).accessibilityIdentifier("sound.brrrt")
                Text("Spatial stereo follows your camera. Gun reports and the GAU-8 keep their full decay; repeated test taps let the current burst finish. Aircraft sounds accompany active flybys, and bombs whistle into their impact. Each squad and sniper deployment keeps its own gun sound. City ambience and crowd voices are off.")
                    .font(.system(size: 12)).foregroundStyle(CommandTheme.muted).lineSpacing(4)
                Text("A-10 cannon recording: 127th Wing / Rachel Barton, DVIDS ‘The Gun’ (public domain). Other sounds are original. U.S. Department of War visual information does not imply or constitute endorsement.")
                    .font(.system(size: 10)).foregroundStyle(CommandTheme.muted).lineSpacing(3)
            }
        }
    }
    private func volume(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Eyebrow(text: title); Spacer(); Text("\(Int(value.wrappedValue * 100))%").font(CommandTheme.mono(10)) }
            Slider(value: value, in: 0...1).tint(CommandTheme.lime)
        }
    }
}
