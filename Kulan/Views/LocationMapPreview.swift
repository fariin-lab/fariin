import MapKit
import SwiftUI
import UIKit

// ⛔ A SHARED LOCATION SHOWS THE PLACE, NOT ITS NUMBERS — owner, 2026-08-24: "when I send a location,
// add a location preview". The bubble said `0.33746, 32.55977`, which is the one thing about a place
// nobody reads.
//
// A STILL IMAGE, NOT AN EMBEDDED MAP. `MKMapSnapshotter` renders once to a UIImage; a live `Map` in a
// chat row would be a running MapKit instance per bubble, each with its own tile fetches and gesture
// recognisers, inside a list that recycles cells while scrolling. The bubble only ever needs one
// frame of it, and a picture is also the only thing that survives the pre-measure rule this chat
// lives by — see the bloom notes in ThreadView: a row whose height resolves later than the
// measurement grows into its neighbour.

/// One rendered map, kept so scrolling past a location twice does not render it twice.
@MainActor enum MapSnapshotCache {
    private static var images: [String: UIImage] = [:]
    /// In flight, so a cell that is configured twice in the same frame — which recycling does —
    /// starts one render rather than two.
    private static var pending: Set<String> = []

    static func key(lat: Double, lon: Double, size: CGSize, dark: Bool) -> String {
        // Five decimals is about a metre, which is finer than any bubble can show, and it keeps two
        // shares of "the same place" on one cache entry.
        String(format: "%.5f,%.5f@%.0fx%.0f/%@", lat, lon, size.width, size.height, dark ? "d" : "l")
    }

    static func cached(_ key: String) -> UIImage? { images[key] }

    static func render(lat: Double, lon: Double, size: CGSize, dark: Bool,
                       key: String, done: @escaping (UIImage?) -> Void) {
        if let hit = images[key] { done(hit); return }
        guard !pending.contains(key) else { done(nil); return }
        pending.insert(key)

        let options = MKMapSnapshotter.Options()
        // ⚠️ A SPAN, NOT A DISTANCE. `MKCoordinateRegion(center:latitudinalMeters:)` is metres on the
        // ground, so the same share renders at a different zoom depending on latitude. A span is
        // degrees, so every location comes out at one zoom — which is what makes a column of them
        // read as one thing rather than as several maps at several scales.
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004),
        )
        options.size = size
        options.showsBuildings = true
        // The snapshot draws in whatever appearance it is handed, so it has to be told ours — a map
        // rendered light and shown in a dark chat is the brightest thing on the screen.
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

        MKMapSnapshotter(options: options).start(with: .global(qos: .userInitiated)) { snapshot, _ in
            let drawn: UIImage? = snapshot.map { snap in
                // The pin is drawn ON the snapshot rather than laid over the view, so what the
                // bubble holds is ONE image: nothing to keep aligned when the row is re-laid out,
                // and the lift that the long-press menu takes gets the pin with it.
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = snap.image.scale
                return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                    snap.image.draw(at: .zero)
                    let point = snap.point(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    let pin = UIImage(systemName: "mappin.circle.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 30,
                                                                                     weight: .semibold))?
                        .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
                    guard let pin else { return }
                    // A pin points AT something: its tip sits on the coordinate, so the glyph is
                    // drawn a full height above the point rather than centred on it.
                    let rect = CGRect(x: point.x - pin.size.width / 2,
                                      y: point.y - pin.size.height,
                                      width: pin.size.width, height: pin.size.height)
                    ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                                            color: UIColor.black.withAlphaComponent(0.35).cgColor)
                    pin.draw(in: rect)
                }
            }
            Task { @MainActor in
                pending.remove(key)
                if let drawn {
                    // A handful is all a chat needs; a long scroll through a location-heavy thread
                    // should not hold every map it passed.
                    if images.count >= 24 { images.removeAll() }
                    images[key] = drawn
                }
                done(drawn)
            }
        }
    }
}

/// The map a shared-location bubble wears. Sized by the caller and never by its own content, so the
/// row's height is known before the picture arrives.
struct LocationMapPreview: View {
    let lat: Double
    let lon: Double
    let width: CGFloat
    let height: CGFloat
    let dark: Bool

    @State private var image: UIImage?

    private var size: CGSize { CGSize(width: width, height: height) }
    private var key: String { MapSnapshotCache.key(lat: lat, lon: lon, size: size, dark: dark) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // The quiet ground the map will land on. Never a spinner: a map that fades in over a
                // flat colour reads as loading; a spinner in a chat row reads as something wrong.
                Rectangle().fill(Color.primary.opacity(dark ? 0.10 : 0.06))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        // Synchronous cache first, so a bubble that has been on screen before draws its map on the
        // very first frame instead of flashing the placeholder again on every recycle.
        .onAppear {
            if let hit = MapSnapshotCache.cached(key) { image = hit; return }
            MapSnapshotCache.render(lat: lat, lon: lon, size: size, dark: dark, key: key) { img in
                if let img { withAnimation(.easeOut(duration: 0.18)) { image = img } }
            }
        }
        // Cells are recycled: the same view can wake up holding a different place.
        .onChange(of: key) { _, _ in
            image = MapSnapshotCache.cached(key)
            guard image == nil else { return }
            MapSnapshotCache.render(lat: lat, lon: lon, size: size, dark: dark, key: key) { img in
                if let img { withAnimation(.easeOut(duration: 0.18)) { image = img } }
            }
        }
        .accessibilityLabel("Map preview")
    }
}
