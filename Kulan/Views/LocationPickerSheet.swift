import SwiftUI
import MapKit
import CoreLocation

// Requests When-In-Use permission and delivers one-shot GPS fixes. Clean CLLocationManager wrapper:
// request() is safe to call any time — it asks for permission first if needed, then fetches.
final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocationCoordinate2D?
    @Published var denied = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:        manager.requestWhenInUseAuthorization()   // → callback below fetches
        case .denied, .restricted:  denied = true
        default:                    manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted:                    denied = true
        default: break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        location = locs.last?.coordinate
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { /* one-shot; ignore */ }
}

// "Select Location" (user design): full-screen map with a fixed CENTER PIN (pan the map to choose),
// a locate-me button, a bottom search field (MKLocalSearch), and a Send Location button that outputs
// the chosen coordinates (falls back to the live GPS fix when the map hasn't been moved).
struct LocationPickerSheet: View {
    var onSend: (_ lat: Double, _ lon: Double, _ label: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fetcher = LocationFetcher()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var selectedName: String?
    @State private var userMovedMap = false   // the user actually panned the map to a spot
    @FocusState private var searchFocused: Bool

    // Only a location the user actually CHOSE counts: a spot they panned to, a search result they
    // picked, or a real GPS fix. Without this, `center` was set on the first automatic camera settle
    // (even the default region when permission is denied), so Send shipped a bogus default location.
    private var sendCoordinate: CLLocationCoordinate2D? {
        if userMovedMap || selectedName != nil { return center }
        return fetcher.location
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
            }
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .continuous) { ctx in
                center = ctx.camera.centerCoordinate
                if searchFocused == false && !results.isEmpty { results = [] }
            }
            // A finger drag on the map = the user deliberately choosing a spot (enables Send even with
            // no GPS / permission denied — they're pointing at a real place).
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in userMovedMap = true })
            // Fixed center pin — pan the map to choose the spot (Telegram-style).
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.red)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(y: -17)   // tip of the pin sits ON the center point
                    .allowsHitTesting(false)
            }

            // Header: title + X (matches the design).
            HStack {
                Spacer().frame(width: 48)
                Spacer()
                Text("Select Location").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
        }
        // Locate-me + send + search pinned at the bottom.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Button {
                        fetcher.request()
                        withAnimation { camera = .userLocation(fallback: .automatic) }
                    } label: {
                        Image(systemName: "location.fill").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                            .liquidGlass(Circle(), interactive: true)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                // Search results (top 4) above the field.
                if !results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(results.prefix(4).enumerated()), id: \.offset) { _, item in
                            Button { pick(item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name ?? "Location").font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary).lineLimit(1)
                                        if let addr = item.placemark.title {
                                            Text(addr).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                // Send Location — outputs the chosen (or current GPS) coordinates.
                Button {
                    guard let c = sendCoordinate else { fetcher.request(); return }
                    onSend(c.latitude, c.longitude, selectedName)
                    dismiss()
                } label: {
                    Label("Send Location", systemImage: "location.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .liquidGlass(Capsule(), interactive: true, tint: Theme.defaultBubble(false))
                }
                .buttonStyle(.plain)
                .disabled(sendCoordinate == nil)
                .opacity(sendCoordinate == nil ? 0.5 : 1)
                // Search by name or address (design's bottom bar).
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name or address", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                }
                .padding(.horizontal, 14).frame(height: 48)
                .liquidGlass(Capsule(), interactive: true)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .alert("Location access is off", isPresented: $fetcher.denied) {
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Allow location access in Settings to share where you are.") }
        .onAppear { fetcher.request() }
    }

    private func pick(_ item: MKMapItem) {
        selectedName = item.name
        results = []
        query = item.name ?? query
        searchFocused = false
        let coord = item.placemark.coordinate
        center = coord
        withAnimation {
            camera = .region(MKCoordinateRegion(center: coord,
                                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let c = sendCoordinate {
            req.region = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        }
        MKLocalSearch(request: req).start { resp, _ in
            results = resp?.mapItems ?? []
        }
    }
}
