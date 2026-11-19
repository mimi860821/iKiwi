import Foundation
import CoreLocation
import Combine

/// Safety net: a simulated position is cleared by itself after a while, so a lost
/// phone does not keep reporting a fake place.
enum AutoRestoreSettings {
    static let enabledKey = "wayfarer.autoRestoreEnabled"
    static let teleportMinutesKey = "wayfarer.autoRestoreTeleportMinutes"
    static let routeMinutesKey = "wayfarer.autoRestoreRouteMinutes"
    static let defaultTeleportMinutes: Double = 60
    static let defaultRouteMinutes: Double = 120

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func seconds(forRoute: Bool) -> TimeInterval {
        let key = forRoute ? routeMinutesKey : teleportMinutesKey
        let fallback = forRoute ? defaultRouteMinutes : defaultTeleportMinutes
        let stored = UserDefaults.standard.double(forKey: key)
        return (stored > 0 ? stored : fallback) * 60
    }
}

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    /// When the simulated position will be cleared automatically; nil if never.
    @Published private(set) var autoRestoreAt: Date?
    private var resendTimer: Timer?
    private var routeID: UUID?
    private var autoRestoreTimer: Timer?

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Void) {
        start(at: coordinate)
        resendTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in operation() }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    func pauseResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    // MARK: Auto restore

    /// Starts (or restarts) the countdown after a teleport or when a route starts.
    /// Counted from that moment, whatever happens afterwards.
    func armAutoRestore(forRoute: Bool) {
        cancelAutoRestore()
        guard AutoRestoreSettings.isEnabled else { return }

        autoRestoreAt = Date().addingTimeInterval(AutoRestoreSettings.seconds(forRoute: forRoute))
        // Checked against the clock every few seconds instead of one long timer.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkAutoRestore()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRestoreTimer = timer
    }

    func cancelAutoRestore() {
        autoRestoreTimer?.invalidate()
        autoRestoreTimer = nil
        if autoRestoreAt != nil {
            autoRestoreAt = nil
        }
    }

    private func checkAutoRestore() {
        guard let deadline = autoRestoreAt, Date() >= deadline else { return }
        cancelAutoRestore()
        // Stops route playback too: it quits once the route is no longer current.
        stop()
        LocationSimulationCommandQueue.shared.async {
            _ = clear_simulated_location()
        }
    }

    func stop() {
        cancelAutoRestore()
        pauseResending()
        clearRoute()
        guard isActive else { return }
        isActive = false
        coordinate = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }
}
