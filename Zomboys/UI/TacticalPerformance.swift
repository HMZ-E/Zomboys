import SwiftUI
import UIKit

/// Full-resolution presentation. Low Power Mode and heat reduce frame cadence
/// while keeping the map sharp; street AI has its own fixed-step clock.
@MainActor
final class TacticalPerformance: ObservableObject {
    static let shared = TacticalPerformance()
    @Published private(set) var framesPerSecond = 60
    @Published private(set) var renderScale: CGFloat = UIScreen.main.scale
    @Published private(set) var active = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        active = UIApplication.shared.applicationState != .background
        refresh()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.active = false }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.active = true; self?.refresh() }
        })
    }

    private func refresh() {
        let process = ProcessInfo.processInfo
        switch process.thermalState {
        case .serious, .critical: framesPerSecond = 30
        default:
            framesPerSecond = process.isLowPowerModeEnabled ? 30 : 60
        }
        renderScale = UIScreen.main.scale
    }
}
