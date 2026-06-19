import SwiftUI
import MapKit

/// A vehicle pin (mutable coordinate so MapKit can animate moves).
final class VehicleAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var line: String
    var kind: VehicleKind
    var brno = false
    var destination: String?
    var title: String? { "\(kind.displayName(brno: brno)) \(line)" }  // callout, e.g. "Šalina 7" in Brno
    var subtitle: String? { destination.map { "→ \($0)" } }           // e.g. "→ Královo Pole, nádraží"

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
    var brno: Bool = false      // tram → "Šalina" in callouts
    var stopNames: [Int: String] = [:]   // FinalStopID → destination name

    func makeCoordinator() -> Coordinator { Coordinator(stops: stops, brno: brno, stopNames: stopNames) }

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
        let brno: Bool
        let stopNames: [Int: String]
        private var vehicleAnn: [String: VehicleAnnotation] = [:]
        private var stopAnn: [String: StopAnnotation] = [:]
        private let stopZoomThreshold = 0.035   // show stops once span is tighter than this
        private let cap = 300

        init(stops: [Stop], brno: Bool, stopNames: [Int: String]) {
            self.stops = stops; self.brno = brno; self.stopNames = stopNames
        }

        private func destination(_ v: Vehicle) -> String? { v.destinationId.flatMap { stopNames[$0] } }

        // MARK: Vehicles

        func syncVehicles(_ vehicles: [Vehicle], on map: MKMapView) {
            let region = map.region
            let visible = vehicles.filter { region.contains($0.coordinate) }.prefix(cap)
            var seen = Set<String>()
            for v in visible {
                seen.insert(v.id)
                if let a = vehicleAnn[v.id] {
                    a.apply(v); a.destination = destination(v)
                    UIView.animate(withDuration: 0.9) { a.coordinate = v.coordinate }
                    if let view = map.view(for: a) as? MKMarkerAnnotationView { style(view, v.kind, v.line) }
                } else {
                    let a = VehicleAnnotation(v); a.brno = brno; a.destination = destination(v)
                    vehicleAnn[v.id] = a; map.addAnnotation(a)
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
                let view = (map.dequeueReusableAnnotationView(withIdentifier: StopMarkerView.reuse) as? StopMarkerView)
                    ?? StopMarkerView(annotation: s, reuseIdentifier: StopMarkerView.reuse)
                view.annotation = s
                view.configure(name: s.title ?? "")
                return view
            default:
                return nil
            }
        }

        private func style(_ view: MKMarkerAnnotationView, _ kind: VehicleKind, _ line: String) {
            view.markerTintColor = UIColor(kind.color)
            view.glyphText = line
            view.titleVisibility = .hidden        // no floating "Linka X" label; number stays in the bubble
            view.subtitleVisibility = .hidden
            view.canShowCallout = true            // tap → "Tramvaj 7"
            view.displayPriority = .required
        }
    }
}

/// A stop: a bright teal dot (the app's identity color) with the stop name beneath,
/// so stops pop and are labeled. Distinct from the colored vehicle bubbles.
final class StopMarkerView: MKAnnotationView {
    static let reuse = "stop"
    private let dot = UIView()
    private let label = PaddedLabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 15, height: 15)
        centerOffset = .zero
        clipsToBounds = false
        displayPriority = .defaultLow            // vehicles win collisions
        collisionMode = .circle

        dot.frame = bounds
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 7.5
        dot.layer.borderWidth = 3.5
        dot.layer.borderColor = UIColor(Color.brandTeal).cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.35
        dot.layer.shadowRadius = 2
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(dot)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .label
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String) {
        label.text = name
        label.sizeToFit()
        label.frame = CGRect(x: bounds.midX - label.bounds.width / 2,
                             y: bounds.maxY + 2,
                             width: label.bounds.width, height: label.bounds.height)
    }
}

/// UILabel with a little horizontal padding (for the stop-name pill).
private final class PaddedLabel: UILabel {
    private let inset = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        var s = super.intrinsicContentSize
        s.width += inset.left + inset.right; s.height += inset.top + inset.bottom; return s
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var s = super.sizeThatFits(size)
        s.width += inset.left + inset.right; s.height += inset.top + inset.bottom; return s
    }
}

extension MKCoordinateRegion {
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude - center.latitude) <= span.latitudeDelta / 2 &&
        abs(c.longitude - center.longitude) <= span.longitudeDelta / 2
    }
}
