import CoreLocation
import Foundation
import MapKit
import Network
import SwiftUI
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var joystickActive = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private var resendTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private var engineGeneration = 0
    private let locationKeeper = BackgroundKeepAlive()
    private let audioKeepAlive = SilentAudioKeepAlive()
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.chrismack.locus.network-path", qos: .utility)
    private var activePairing: PairingStore?

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkPathChanged(path)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        pin = coordinate
        apply(coordinate, pairing: pairing, markRecent: true)
    }

    func stop(pairing: PairingStore) {
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        stopHealth()
        engineGeneration &+= 1
        // Stop must not wait for the developer tunnel. If LocalDevVPN has
        // already dropped, the native clear call can wait indefinitely on a
        // dead RemoteXPC connection and leave the Stop button apparently
        // broken. Reset the app-owned state first; native cleanup is best
        // effort on a detached utility queue below.
        isBusy = false
        simulated = nil
        status = .idle
        lastError = nil
        endBackground()
        locationKeeper.start()
        NSLog("[Locus][Session] stop requested; UI state reset immediately")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LocationEngine.clear()
            switch result {
            case .success:
                NSLog("[Locus][Session] native stop cleanup succeeded")
            case .failure(let error):
                NSLog("[Locus][Session] native stop cleanup deferred/failed: %@", error.localizedDescription)
            }
        }
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    /// Reassert the background keep-alives whenever the scene changes state.
    /// Location mode is the primary mechanism so the resend and health timers
    /// can continue while the app is not visible.
    func handleScenePhase(_ phase: ScenePhase) {
        NSLog("[Locus][Session] scene phase=%@ spoofing=%d", String(describing: phase), isSpoofing ? 1 : 0)
        guard isSpoofing else { return }
        switch phase {
        case .active, .background:
            locationKeeper.start()
            beginBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func networkPathChanged(_ path: NWPath) {
        guard isSpoofing else { return }
        NSLog("[Locus][Session] network path changed status=%@ wifi=%d cellular=%d", String(describing: path.status), path.usesInterfaceType(.wifi) ? 1 : 0, path.usesInterfaceType(.cellular) ? 1 : 0)

        guard path.status == .satisfied else {
            status = .reconnecting
            lastError = "Network changed; waiting for the developer tunnel to reconnect."
            return
        }
        guard let simulated, let pairing = activePairing else { return }

        status = .reconnecting
        lastError = nil
        stopResend()
        stopHealth()
        engineGeneration &+= 1
        let generation = engineGeneration
        isBusy = true

        LocationEngine.resetAsync { [weak self] in
            guard let self,
                  self.engineGeneration == generation,
                  self.isSpoofing else { return }
            self.apply(simulated, pairing: pairing, markRecent: false)
        }
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        if simulated == nil {
            apply(start, pairing: pairing, markRecent: false)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self else { return }
            var previous = coordinates[0]
            await MainActor.run {
                self.apply(previous, pairing: pairing, markRecent: true)
            }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await MainActor.run {
                        self.apply(coord, pairing: pairing, markRecent: false)
                    }
                }
                previous = next
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        engineGeneration &+= 1
        let generation = engineGeneration
        let pairingPath = pairing.pairingPath
        isBusy = true
        NSLog("[Locus][Session] apply generation=%d markRecent=%d", generation, markRecent ? 1 : 0)
        // The FFI can wait on a tunnel response. Never run it on the main
        // actor: iOS kills the app after a 10-second scene watchdog timeout.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LocationEngine.set(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                pairingPath: pairingPath,
                deviceIP: TunnelConfig.targetIP
            )
            DispatchQueue.main.async {
                guard let self, self.engineGeneration == generation else { return }
                self.isBusy = false
                switch result {
                case .success:
                    NSLog("[Locus][Session] apply success generation=%d", generation)
                    self.simulated = coordinate
                    self.pin = coordinate
                    self.activePairing = pairing
                    self.status = .active
                    self.lastError = nil
                    self.beginBackground()
                    self.locationKeeper.start()
                    self.startResend(pairing: pairing)
                    self.startHealth(pairing: pairing)
                    if markRecent {
                        self.pushRecent(coordinate)
                    }
                case .failure(let error):
                    NSLog("[Locus][Session] apply failed generation=%d error=%@", generation, error.localizedDescription)
                    self.lastError = error.localizedDescription
                    if self.simulated != nil {
                        self.status = .dropped(error.localizedDescription)
                        self.postDropNotification(error.localizedDescription)
                    } else {
                        self.status = .idle
                    }
                }
            }
        }
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false)
    }

    private func startResend(pairing: PairingStore) {
        stopResend()
        guard let sim = simulated else { return }
        let pairingPath = pairing.pairingPath
        let deviceIP = TunnelConfig.targetIP
        let generation = engineGeneration
        NSLog("[Locus][Session] resend timer start interval=8")
        let timer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(label: "com.chrismack.locus.location-resend", qos: .utility)
        )
        // Foundation Timer is tied to the main run loop and can stop firing
        // when the app is backgrounded. A GCD timer remains schedulable while
        // the location/audio background modes keep the process alive.
        timer.schedule(deadline: .now() + .seconds(8), repeating: .seconds(8), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            NSLog("[Locus][Session] resend fired")
            // Do not hop to the main actor before making the tunnel call. The
            // main actor may not be scheduled while the app is backgrounded.
            // Run directly on this serial timer queue so a slow tunnel call
            // cannot create overlapping resend operations.
            let result = LocationEngine.set(
                latitude: sim.latitude,
                longitude: sim.longitude,
                pairingPath: pairingPath,
                deviceIP: deviceIP
            )
            DispatchQueue.main.async {
                guard let self,
                      self.engineGeneration == generation,
                      self.isSpoofing else { return }
                if case .failure(let error) = result {
                    NSLog("[Locus][Session] resend failed error=%@; reconnecting", error.localizedDescription)
                    self.lastError = error.localizedDescription
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                } else {
                    NSLog("[Locus][Session] resend succeeded")
                }
            }
        }
        resendTimer = timer
        timer.resume()
    }

    private func stopResend() {
        resendTimer?.setEventHandler {}
        resendTimer?.cancel()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        stopHealth()
        NSLog("[Locus][Session] health timer start interval=12")
        let timer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(label: "com.chrismack.locus.health", qos: .utility)
        )
        timer.schedule(deadline: .now() + .seconds(12), repeating: .seconds(12), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            NSLog("[Locus][Session] health fired")
            // Probe the native session directly from the timer queue. Only
            // the resulting UI transition needs the main actor.
            LocationEngine.sessionActive { [weak self] active in
                DispatchQueue.main.async {
                    guard let self, !active, self.isSpoofing,
                          let sim = self.simulated else { return }
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                }
            }
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealth() {
        healthTimer?.setEventHandler {}
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        NSLog("[Locus][Session] begin background keep-alive")
        locationKeeper.start()
        // A silent playback session is a practical iOS background execution
        // keep-alive for this developer-only tunnel. Its AVFoundation work is
        // serialized off the main actor so it cannot reintroduce the watchdog
        // freeze that was fixed in 1.0.6.
        audioKeepAlive.start()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.backgroundTaskExpired()
        }
    }

    private func backgroundTaskExpired() {
        NSLog("[Locus][Session] finite background task expired; reasserting keep-alives")
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        // This finite grace task expiring is expected. Keep the location and
        // tunnel/location modes running so iOS can continue scheduling the session.
        locationKeeper.start()
        audioKeepAlive.start()
    }

    private func endBackground() {
        NSLog("[Locus][Session] end background keep-alive")
        audioKeepAlive.stop()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}


