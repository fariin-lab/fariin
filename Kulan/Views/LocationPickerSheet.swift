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

    /// ⛔ THE FIX THE PHONE ALREADY HAS. `requestLocation()` goes and gets a NEW fix, and a new fix is
    /// seconds — GPS has to acquire, and indoors or on a weak signal it is many seconds. iOS is
    /// already holding the last one every other app asked for, and for "what is near me" a fix from a
    /// minute ago is the same answer.
    ///
    /// Nil when nothing is cached or the permission was never granted. Reading it starts nothing and
    /// costs nothing.
    var cached: CLLocationCoordinate2D? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return manager.location?.coordinate
        default: return nil
        }
    }

    /// `accuracy` exists for the same reason `cached` does: a map you drop a pin on wants metres, and
    /// a list of places near you does not. A coarser target is answered from wifi and cell towers
    /// instead of waiting on a GPS lock, which is most of the wait. The default is what the map
    /// picker has always used, so that screen is unchanged.
    func request(accuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters) {
        manager.desiredAccuracy = accuracy
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

/// The window's top inset — the status bar and, on a phone that has one, the island. Read from the
/// window rather than a `GeometryReader`, because this header sits over a view that deliberately
/// ignores the safe area and would therefore be handed the full screen by any reader inside it.
private func _locationTopInset() -> CGFloat {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let w = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
    return w?.safeAreaInsets.top ?? 44
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
    /// ⛔ MAP · SATELLITE · HYBRID — owner, 2026-08-24, as a thing he expected and did not find.
    /// Three cases rather than a free-form style so the control and the map cannot disagree.
    @State private var styleKind: MapStyleKind = .standard
    /// What the pin is standing on, resolved from the coordinate — see `resolveName`. This is what
    /// makes the sent bubble say a PLACE instead of "Location": without it the label was nil for
    /// every share except one picked out of search, which is his "the name is not appearing".
    @State private var resolvedName: String?
    @State private var resolvedAddress: String?
    @State private var geocodeTask: Task<Void, Never>?

    enum MapStyleKind: String, CaseIterable, Identifiable {
        case standard = "Map", satellite = "Satellite", hybrid = "Hybrid"
        var id: String { rawValue }
        var style: MapStyle {
            switch self {
            case .standard:  return .standard(elevation: .realistic)
            case .satellite: return .imagery(elevation: .realistic)
            case .hybrid:    return .hybrid(elevation: .realistic)
            }
        }
    }

    /// The name that travels with the share: what he picked out of search if he did, otherwise
    /// whatever the pin resolved to. Nil only while a fresh spot is still being looked up.
    private var sendName: String? { selectedName ?? resolvedName }

    /// One reverse-geocode for wherever the pin is now, debounced, because the camera reports
    /// continuously while a finger is moving and CLGeocoder rate-limits hard — a request per frame
    /// gets the whole app throttled, and the only answer that matters is the one after it settles.
    private func resolveName(for c: CLLocationCoordinate2D) {
        geocodeTask?.cancel()
        geocodeTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let placemarks = try? await CLGeocoder()
                .reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
            guard !Task.isCancelled, let p = placemarks?.first else { return }
            await MainActor.run {
                // `name` is the building or landmark; the thoroughfare is the fallback so a spot in
                // the middle of a street still says the street rather than a plus-code.
                resolvedName = p.name ?? p.thoroughfare ?? p.locality ?? p.country
                resolvedAddress = [p.thoroughfare, p.locality, p.country]
                    .compactMap { $0 }.joined(separator: ", ")
            }
        }
    }
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
            .mapStyle(styleKind.style)
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .continuous) { ctx in
                center = ctx.camera.centerCoordinate
                if searchFocused == false && !results.isEmpty { results = [] }
            }
            // The name is looked up when the map STOPS, not while it moves. `onEnded` is the settle,
            // which is the only camera value worth spending a geocode on.
            .onMapCameraChange(frequency: .onEnd) { ctx in
                let c = ctx.camera.centerCoordinate
                center = c
                // A spot chosen by hand is no longer the search result that was picked before it.
                if userMovedMap { selectedName = nil }
                resolveName(for: c)
            }
            // A finger drag on the map = the user deliberately choosing a spot (enables Send even with
            // no GPS / permission denied — they're pointing at a real place).
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in userMovedMap = true })
            // Fixed center pin — pan the map to choose the spot.
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.red)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(y: -17)   // tip of the pin sits ON the center point
                    .allowsHitTesting(false)
            }

            // Header: X on the LEADING edge, title centred.
            //
            // ⛔ THE ✕ MOVED OFF THE RIGHT BECAUSE MAPKIT OWNS THAT CORNER — owner, 2026-08-24, with
            // the ✕ and the compass circled together. `Map` draws its compass at the top-TRAILING
            // corner, and our close button was put in the same place, so the two sat on top of each
            // other. Nothing was going to separate them there: the compass appears and disappears on
            // its own as the map rotates, so on a north-up map the collision is invisible and the
            // moment the map turns it is not.
            //
            // Leading is also where this app already puts a sheet's close: the GIF picker and the
            // photo sheet both do, and both get it from a real toolbar's `.topBarLeading`. Same
            // position, reached the same way a bar item would be.
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Select Location").font(.headline)
                Spacer()
                // Balances the title against the button so it is centred on the SCREEN, not on the
                // space left over beside the ✕.
                Spacer().frame(width: 44)
            }
            .padding(.horizontal, 12)
            // ⛔ INSIDE THE SAFE AREA — owner, 2026-08-24: the ✕ sat under the status bar and the
            // island. The map below is deliberately full-bleed (`ignoresSafeArea`), and this header
            // is layered over it in the same ZStack, so it inherited the map's edge-to-edge frame
            // instead of the screen's usable one. Pushing the header down by the top inset leaves
            // the map full-bleed and puts only the controls where they can be reached.
            .padding(.top, _locationTopInset())

            // Map · Satellite · Hybrid, under the header and over the map. A plain segmented picker
            // rather than a custom control: it is the shape iOS uses for exactly this choice, and it
            // stays legible over both a street map and satellite imagery because the system draws it
            // on its own background.
            VStack(spacing: 8) {
                // ⛔ IT NEEDS A SURFACE OF ITS OWN — owner, 2026-08-24: "to bar aits hard to see".
                // A segmented picker draws its own background, but that background is translucent and
                // it was sitting straight on a street map, so the roads and labels read through both
                // the track and the selected segment. Backing it with an opaque material and lifting
                // it off the map with a shadow is what separates a control from the picture under it.
                Picker("", selection: $styleKind) {
                    ForEach(MapStyleKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .padding(3)
                .background(.thickMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                // What the pin is standing on. It appears as soon as the lookup answers, so the spot
                // is named BEFORE it is sent rather than only afterwards in the bubble.
                if let name = sendName, !name.isEmpty {
                    VStack(spacing: 1) {
                        Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if let addr = resolvedAddress, !addr.isEmpty, addr != name {
                            Text(addr).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    // Thick, not regular, and for the same reason as the picker above it: a regular
                    // material over pale map tiles let the street names underneath compete with the
                    // place name, which is the one piece of text on this screen that has to be read
                    // before Send is pressed.
                    .background(.thickMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .transition(.opacity)
                }
            }
            // Header height + the gap under it. 44 is the close button, which came down from 48 with
            // the bar-item sizing above, so this follows it rather than leaving 4pt of drift.
            .padding(.top, _locationTopInset() + 52)
            .animation(.easeOut(duration: 0.2), value: sendName)
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
                    // The resolved name travels with it, so the bubble can say the place rather
                    // than "Location" — see `sendName`.
                    onSend(c.latitude, c.longitude, sendName)
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
