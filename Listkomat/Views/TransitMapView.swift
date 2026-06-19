import SwiftUI
import MapKit

/// A vehicle pin (mutable coordinate so MapKit can animate moves).
final class VehicleAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var line: String
    var kind: VehicleKind
    var title: String? { "Linka \(line)" }

    init(_ v: Vehicle) { id = v.id; coordinate = v.coordinate; line = v.line; kind = v.kind }
    func apply(_ v: Vehicle) { line = v.line; kind = v.kind }
}

/// A stop pin (static).
final class StopAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    init(_ s: Stop) { id = s.id; coordinate = s.coordinate; title = s.name }
}

/// MKMapView wrapped for SwiftUI: live vehicles (always) + stops (only when zoomed
/// in). Keeps the iOS 16.2 floor and gives full annotation control.
struct TransitMapView: UIViewRepresentable {
    var vehicles: [Vehicle]
    var stops: [Stop]
    var initialCenter: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator { Coordinator(stops: stops) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(center: initialCenter,
                                         span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)),
                      animated: false)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.stops = stops
        context.coordinator.syncVehicles(vehicles, on: map)
        context.coordinator.refreshStops(on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        var stops: [Stop]
        private var vehicleAnn: [String: VehicleAnnotation] = [:]
        private var stopAnn: [String: StopAnnotation] = [:]
        private let stopZoomThreshold = 0.035   // show stops once span is tighter than this
        private let cap = 300

        init(stops: [Stop]) { self.stops = stops }

        // MARK: Vehicles

        func syncVehicles(_ vehicles: [Vehicle], on map: MKMapView) {
            let region = map.region
            let visible = vehicles.filter { region.contains($0.coordinate) }.prefix(cap)
            var seen = Set<String>()
            for v in visible {
                seen.insert(v.id)
                if let a = vehicleAnn[v.id] {
                    a.apply(v)
                    UIView.animate(withDuration: 0.9) { a.coordinate = v.coordinate }
                    if let view = map.view(for: a) as? MKMarkerAnnotationView { style(view, v.kind, v.line) }
                } else {
                    let a = VehicleAnnotation(v); vehicleAnn[v.id] = a; map.addAnnotation(a)
                }
            }
            for (id, a) in vehicleAnn where !seen.contains(id) {
                map.removeAnnotation(a); vehicleAnn[id] = nil
            }
        }

        // MARK: Stops (zoom-gated)

        func refreshStops(on map: MKMapView) {
            let region = map.region
            guard region.span.latitudeDelta < stopZoomThreshold else {
                if !stopAnn.isEmpty { map.removeAnnotations(Array(stopAnn.values)); stopAnn.removeAll() }
                return
            }
            let visible = stops.filter { region.contains($0.coordinate) }.prefix(cap)
            var seen = Set<String>()
            for s in visible {
                seen.insert(s.id)
                if stopAnn[s.id] == nil { let a = StopAnnotation(s); stopAnn[s.id] = a; map.addAnnotation(a) }
            }
            for (id, a) in stopAnn where !seen.contains(id) {
                map.removeAnnotation(a); stopAnn[id] = nil
            }
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) { refreshStops(on: map) }

        // MARK: Views

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is MKUserLocation:
                return nil
            case let v as VehicleAnnotation:
                let id = "vehicle"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: v, reuseIdentifier: id)
                view.annotation = v
                style(view, v.kind, v.line)
                return view
            case let s as StopAnnotation:
                let id = "stop"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: s, reuseIdentifier: id)
                view.annotation = s
                view.image = Coordinator.stopDot
                view.canShowCallout = true
                view.displayPriority = .defaultLow
                return view
            default:
                return nil
            }
        }

        private func style(_ view: MKMarkerAnnotationView, _ kind: VehicleKind, _ line: String) {
            view.markerTintColor = UIColor(Self.color(kind))
            view.glyphText = line
            view.canShowCallout = true
            view.displayPriority = .required
        }

        static func color(_ kind: VehicleKind) -> Color {
            switch kind {
            case .tram: return .red
            case .trolleybus: return .purple
            case .bus: return .blue
            case .train: return .green
            }
        }

        static let stopDot: UIImage = {
            let s = CGSize(width: 12, height: 12)
            return UIGraphicsImageRenderer(size: s).image { ctx in
                UIColor.darkGray.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: s))
                UIColor.white.setStroke()
                ctx.cgContext.setLineWidth(1.5)
                ctx.cgContext.strokeEllipse(in: CGRect(x: 0.75, y: 0.75, width: 10.5, height: 10.5))
            }
        }()
    }
}

extension MKCoordinateRegion {
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude - center.latitude) <= span.latitudeDelta / 2 &&
        abs(c.longitude - center.longitude) <= span.longitudeDelta / 2
    }
}
