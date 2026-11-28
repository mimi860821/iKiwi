//
//  WayfarerSupport.swift
//  Wayfarer
//
//  Travel modes, multi-stop route building and the mode/speed control bar.
//

import SwiftUI
import MapKit
import CoreLocation

/// How the simulated traveller moves. Cycling reuses pedestrian routing because
/// MapKit has no dedicated bicycle transport type.
enum TravelMode: String, CaseIterable, Identifiable {
    case walking
    case cycling
    case driving
    /// Very fast travel along roads, with fewer route points.
    case detect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: return "走路"
        case .cycling: return "騎車"
        case .driving: return "開車"
        case .detect: return "偵測"
        }
    }

    var defaultSpeedKmh: Double {
        switch self {
        case .walking: return 5
        case .cycling: return 19.5
        case .driving: return 40
        case .detect: return 600
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving, .detect: return .automobile
        default: return .walking
        }
    }
}

enum WayfarerTab: String, CaseIterable, Identifiable {
    case teleport
    case multi
    case spiral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teleport: return "瞬移"
        case .multi: return "多點路徑"
        case .spiral: return "繞圈"
        }
    }
}

/// A spiral walked outwards from a centre point. Each lap lies `2 × radius` further
/// out than the one before, so the circles of `radius` around the walker on two
/// neighbouring laps just touch and never overlap.
enum SpiralPath {
    static let maxLaps = 30
    static let radiusRange: ClosedRange<Double> = 50...5000

    /// Distance between one lap and the next.
    static func pitch(radius: Double) -> Double {
        radius * 2
    }

    /// Radius of the outermost lap.
    static func outerRadius(radius: Double, laps: Int) -> Double {
        pitch(radius: radius) * Double(laps)
    }

    /// Length of the whole walk, in metres.
    static func length(radius: Double, laps: Int) -> Double {
        let b = pitch(radius: radius) / (2 * .pi)
        let t = 2 * .pi * Double(laps)
        return b / 2 * (t * (1 + t * t).squareRoot() + asinh(t))
    }

    /// The point `distance` metres from `center` on the given bearing (radians from north).
    private static func destination(
        from center: CLLocationCoordinate2D,
        bearing: Double,
        distance: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let delta = distance / earthRadius
        let lat1 = center.latitude * .pi / 180
        let lon1 = center.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(delta) + cos(lat1) * sin(delta) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(delta) * cos(lat1),
            cos(delta) - sin(lat1) * sin(lat2)
        )
        var longitude = lon2 * 180 / .pi
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: longitude)
    }

    /// A stretch of the walk: points about `step` metres apart (further apart far from
    /// the centre, where the curve is gentle) after `fromTheta` up to `toTheta`
    /// (radians turned from the start; one lap is 2π). The start itself is not included.
    static func coordinates(
        center: CLLocationCoordinate2D,
        radius: Double,
        clockwise: Bool,
        step: Double,
        fromTheta: Double,
        toTheta: Double
    ) -> [CLLocationCoordinate2D] {
        let b = pitch(radius: radius) / (2 * .pi)
        var theta = fromTheta
        var result: [CLLocationCoordinate2D] = []
        while theta < toTheta {
            let r = b * theta
            let chord = max(step, min(r * 0.02, 100))
            theta = min(theta + chord / (r * r + b * b).squareRoot(), toTheta)
            result.append(destination(
                from: center,
                bearing: clockwise ? theta : -theta,
                distance: b * theta
            ))
        }
        return result
    }

    /// A light outline for the map while the settings are being chosen.
    static func previewCoordinates(
        center: CLLocationCoordinate2D,
        radius: Double,
        laps: Int,
        clockwise: Bool
    ) -> [CLLocationCoordinate2D] {
        let b = pitch(radius: radius) / (2 * .pi)
        let thetaMax = 2 * .pi * Double(laps)
        let count = 72 * laps
        return (0...count).map { index in
            let theta = thetaMax * Double(index) / Double(count)
            return destination(
                from: center,
                bearing: clockwise ? theta : -theta,
                distance: b * theta
            )
        }
    }
}

/// How a multi-stop route is travelled.
enum RouteShape: String, CaseIterable, Identifiable {
    case oneWay
    case roundTrip
    case circuit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneWay: return "單程"
        case .roundTrip: return "來回"
        case .circuit: return "繞圈"
        }
    }
}

/// Copies coordinates as "lat,lng" (one per line for a list), the same format the
/// search bar and the coordinate list accept when pasted back.
enum CoordinateClipboard {
    static func text(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }

    static func text(for coordinates: [CLLocationCoordinate2D]) -> String {
        coordinates.map { text(for: $0) }.joined(separator: "\n")
    }

    static func copy(_ string: String) {
        UIPasteboard.general.string = string
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

enum WayfarerSpeed {
    static let maxKmh: Double = 3000

    static func metersPerSecond(fromKmh kmh: Double) -> CLLocationSpeed {
        max(kmh, 0.5) / 3.6
    }

    static let updateIntervalKey = "wayfarer.updateInterval"
    static let defaultUpdateInterval: Double = 0.5

    /// Seconds between location updates while a route plays (user adjustable).
    static var updateInterval: Double {
        let stored = UserDefaults.standard.double(forKey: updateIntervalKey)
        return stored > 0 ? min(max(stored, 0.1), 5) : defaultUpdateInterval
    }

    /// Spacing between route points: never denser than 10 m, wider at high speed.
    static func pathSpacing(forSpeed metersPerSecond: CLLocationSpeed) -> CLLocationDistance {
        max(10, metersPerSecond * updateInterval)
    }
}

struct RouteStop: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct WayfarerBuiltRoute {
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    /// Number of legs where MapKit found no route and a straight line was used.
    let straightLegCount: Int
    /// The path vertex at each waypoint (start, every stop, end), in travel order.
    let waypointCoordinates: [CLLocationCoordinate2D]
}

/// The stops still to visit, as indices into the user's stop list, so a route can be
/// re-planned from the middle (for example, when paused and the walk style changes).
struct LogicalPlan {
    /// Stop indices still to visit, in order, after the starting position.
    var sequence: [Int]
    /// Positions at or after this are the way back.
    var returnStart: Int

    static let empty = LogicalPlan(sequence: [], returnStart: 0)

    static func initial(shape: RouteShape, count: Int) -> LogicalPlan {
        make(shape: shape, count: count, nextOutbound: 1) ?? .empty
    }

    /// Heading outbound to stop `k`.
    static func make(shape: RouteShape, count n: Int, nextOutbound k: Int) -> LogicalPlan? {
        guard n >= 2, k >= 1, k <= n - 1 else { return nil }
        let outbound = Array(k...(n - 1))
        switch shape {
        case .oneWay:
            return LogicalPlan(sequence: outbound, returnStart: outbound.count)
        case .roundTrip:
            let back = Array(stride(from: n - 2, through: 0, by: -1))
            return LogicalPlan(sequence: outbound + back, returnStart: outbound.count)
        case .circuit:
            return LogicalPlan(sequence: outbound + [0], returnStart: outbound.count)
        }
    }

    /// Already on the way back, next heading to stop `m`. Not possible for a one-way trip.
    static func makeReturning(shape: RouteShape, next m: Int) -> LogicalPlan? {
        guard m >= 0 else { return nil }
        switch shape {
        case .oneWay:
            return nil
        case .roundTrip:
            return LogicalPlan(sequence: Array(stride(from: m, through: 0, by: -1)), returnStart: 0)
        case .circuit:
            return LogicalPlan(sequence: [0], returnStart: 0)
        }
    }

    func remaining(after passed: Int) -> (isReturning: Bool, next: Int)? {
        guard passed >= 0, passed < sequence.count else { return nil }
        return (passed >= returnStart, sequence[passed])
    }
}

enum WayfarerRouteBuilder {
    static func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    static func straightDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Builds one continuous path through all stops with the chosen shape.
    static func build(
        stops: [CLLocationCoordinate2D],
        shape: RouteShape,
        mode: TravelMode,
        followRoads: Bool
    ) async throws -> WayfarerBuiltRoute {
        var points = stops
        if shape == .circuit, let first = stops.first, stops.count > 1 {
            points.append(first)
        }

        var route = try await buildSequence(points: points, mode: mode, followRoads: followRoads)
        if shape == .roundTrip {
            var coordinates = route.coordinates
            coordinates.append(contentsOf: route.coordinates.reversed().dropFirst())
            var waypoints = route.waypointCoordinates
            waypoints.append(contentsOf: route.waypointCoordinates.reversed().dropFirst())
            route = WayfarerBuiltRoute(
                coordinates: coordinates,
                distance: route.distance * 2,
                straightLegCount: route.straightLegCount,
                waypointCoordinates: waypoints
            )
        }
        return route
    }

    /// Builds the path that visits `points` in order, using MapKit directions per leg
    /// when `followRoads` is on, and records the path vertex of every waypoint.
    static func buildSequence(
        points: [CLLocationCoordinate2D],
        mode: TravelMode,
        followRoads: Bool
    ) async throws -> WayfarerBuiltRoute {
        guard points.count >= 2 else {
            throw NSError(
                domain: "Wayfarer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "請至少加入兩個站點。"]
            )
        }

        if !followRoads {
            var total: CLLocationDistance = 0
            for (a, b) in zip(points, points.dropFirst()) {
                total += straightDistance(a, b)
            }
            return WayfarerBuiltRoute(
                coordinates: points,
                distance: total,
                straightLegCount: 0,
                waypointCoordinates: points
            )
        }

        var allCoordinates: [CLLocationCoordinate2D] = []
        var boundaries: [CLLocationCoordinate2D] = []
        var totalDistance: CLLocationDistance = 0
        var straightLegs = 0

        for (index, pair) in zip(points, points.dropFirst()).enumerated() {
            try Task.checkCancellation()
            let (start, end) = pair

            if index > 0 {
                // Stay well below MapKit's directions rate limit.
                try await Task.sleep(for: .milliseconds(400))
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = mode.transportType
            request.requestsAlternateRoutes = false

            var legCoordinates: [CLLocationCoordinate2D]
            var legDistance: CLLocationDistance
            do {
                let response = try await MKDirections(request: request).calculate()
                if let route = response.routes.first {
                    legCoordinates = polylineCoordinates(route.polyline)
                    legDistance = route.distance
                } else {
                    legCoordinates = [start, end]
                    legDistance = straightDistance(start, end)
                    straightLegs += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                legCoordinates = [start, end]
                legDistance = straightDistance(start, end)
                straightLegs += 1
            }

            if index == 0, let first = legCoordinates.first {
                boundaries.append(first)
            }
            if let last = legCoordinates.last {
                boundaries.append(last)
            }

            if allCoordinates.isEmpty {
                allCoordinates.append(contentsOf: legCoordinates)
            } else {
                allCoordinates.append(contentsOf: legCoordinates.dropFirst())
            }
            totalDistance += legDistance
        }

        return WayfarerBuiltRoute(
            coordinates: allCoordinates,
            distance: totalDistance,
            straightLegCount: straightLegs,
            waypointCoordinates: boundaries
        )
    }
}

/// Mode picker plus a speed field (type a value or use the stepper).
struct TravelModeSpeedBar: View {
    @Binding var modeRaw: String
    @Binding var speedKmh: Double
    @Binding var updateInterval: Double
    var modeLocked: Bool
    @FocusState private var speedFieldFocused: Bool
    @FocusState private var intervalFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Picker("移動模式", selection: $modeRaw) {
                ForEach(TravelMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(modeLocked)

            HStack(spacing: 8) {
                Text("速度")
                    .font(.subheadline)
                TextField("速度", value: $speedKmh, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($speedFieldFocused)
                Text("公里/小時")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $speedKmh, in: 1...3000, step: 1)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text("更新間隔")
                    .font(.subheadline)
                TextField("秒", value: $updateInterval, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($intervalFieldFocused)
                Text("秒/次")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $updateInterval, in: 0.1...5, step: 0.1)
                    .labelsHidden()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        speedFieldFocused = false
                        intervalFieldFocused = false
                    }
                }
            }
        }
    }
}

/// Seconds to stay at each stop in point-to-point (hop) mode.
struct DwellField: View {
    @Binding var seconds: Double
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("到點停留")
                .font(.subheadline)
            TextField("秒", value: $seconds, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .focused($focused)
            Text("秒")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Stepper("", value: $seconds, in: 0...3600, step: 1)
                .labelsHidden()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = false }
            }
        }
    }
}
