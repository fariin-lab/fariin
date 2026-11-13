import SwiftUI
import MapKit
import CoreLocation
import FirebaseFirestore

// Live location screens (owner 2026-11-13, plan 2026-11-13-live-location-plan.md).

/// "Share Live Location": the map on my spot, 15 minutes / 1 hour / 8 hours (1 hour chosen), an
/// optional comment, Share. The first time, a short line says what sharing means.
struct LiveShareSheet: View {
    var onShare: (_ minutes: Int, _ note: String?, _ here: CLLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fetcher = LocationFetcher()
    @State private var minutes = 60
    @State private var note = ""
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @AppStorage("liveLocation.explained") private var explained = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Map(position: $camera) {
                    if let c = fetcher.location {
                        Annotation("", coordinate: c) { LivePhotoPin(url: ProfileStore.shared.me?.photoUrl, live: true) }
                    } else {
                        UserAnnotation()
                    }
                }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                if !explained {
                    Text("Your spot will keep updating in this chat as you move, for as long as you choose, even when Fariin is closed. Stop it any time.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("For how long?").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // iOS-native (owner 2026-11-13: the iPhone gets iPhone design, not Android's tiles):
                // the system segmented control, Liquid Glass on iOS 26.
                Picker("For how long?", selection: $minutes) {
                    Text("15 min").tag(15)
                    Text("1 hour").tag(60)
                    Text("8 hours").tag(480)
                }
                .pickerStyle(.segmented)
                Text("Until \(Date().addingTimeInterval(TimeInterval(minutes * 60)).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                TextField("Add a note", text: $note)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                Spacer(minLength: 0)
                Button {
                    guard let c = fetcher.location else { fetcher.request(); return }
                    let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    explained = true
                    let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onShare(minutes, n.isEmpty ? nil : String(n.prefix(200)), here)
                    dismiss()
                } label: {
                    Label(fetcher.location == nil ? "Finding your location..." : "Start Sharing",
                          systemImage: "location.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.fariinAction)
                .disabled(fetcher.location == nil)
                .opacity(fetcher.location == nil ? 0.5 : 1)
            }
            .padding(16)
            .navigationTitle("Share your location live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { fetcher.request() }
        }
    }
}

/// The live map: everyone sharing in this chat, moving; a row per person with "Updated …"; my own
/// Stop Sharing, or Share My Live Location. Listens to the chat's live docs only while open.
struct LiveMapPage: View {
    let cid: String
    let me: String
    let title: String
    var name: (String) -> String
    var photo: (String) -> String? = { _ in nil }
    var onShareMine: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var spots: [LiveSpot] = []
    @State private var listener: ListenerRegistration?
    @State private var camera: MapCameraPosition = .automatic
    @State private var satellite = false
    @State private var confirmStop = false
    @State private var tick = Date()

    private var mine: LiveSpot? { spots.first { $0.uid == me } }
    private var sharingHere: Bool { LiveLocationSharer.shared.isSharing(cid: cid) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    ForEach(spots) { s in
                        Annotation(s.uid == me ? "You" : name(s.uid),
                                   coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)) {
                            LivePhotoPin(url: photo(s.uid), live: true)
                        }
                    }
                }
                .mapStyle(satellite ? .hybrid : .standard)
                .overlay(alignment: .topTrailing) {
                    Button { recentre() } label: {
                        Image(systemName: "location.fill").font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .liquidGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain).padding(12)
                }

                VStack(spacing: 0) {
                    if spots.isEmpty {
                        Text("No one is sharing right now.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    ForEach(spots) { s in
                        HStack(spacing: 12) {
                            Circle().fill(Color.fariinAction.opacity(0.15)).frame(width: 36, height: 36)
                                .overlay(Text(initial(s.uid)).font(.subheadline.weight(.semibold)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.uid == me ? "You" : name(s.uid)).font(.body.weight(.semibold))
                                Text("\(updatedWords(s.updatedAt)) · \(LiveDocState.left(until: s.until, now: tick))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { focus(s) }
                    }
                    Button {
                        if sharingHere || mine != nil { confirmStop = true } else { onShareMine() }
                    } label: {
                        Text(sharingHere || mine != nil ? "Stop sharing mine" : "Share mine live too")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(sharingHere || mine != nil ? Color.red : Color.onFariinAction)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Capsule().fill(sharingHere || mine != nil ? Color(.tertiarySystemFill) : Color.fariinAction))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Map", selection: $satellite) {
                            Text("Map").tag(false)
                            Text("Satellite").tag(true)
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .confirmationDialog("Stop sharing your live location?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Sharing", role: .destructive) { LiveLocationSharer.shared.stop(cid: cid) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { listen() }
        .onDisappear { listener?.remove(); listener = nil }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    private func listen() {
        guard listener == nil else { return }
        listener = Firestore.firestore().collection("conversations").document(cid).collection("live")
            .addSnapshotListener { snap, _ in
                let now = (snap?.documents ?? []).compactMap { LiveDocs.spot($0, cid: cid) }
                let first = spots.isEmpty
                spots = now.sorted { $0.uid == me ? false : ($1.uid == me ? true : $0.uid < $1.uid) }
                if first { recentre() }
            }
    }

    private func recentre() {
        guard !spots.isEmpty else { return }
        if spots.count == 1, let s = spots.first { focus(s); return }
        let lats = spots.map(\.lat), lons = spots.map(\.lon)
        let c = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.6),
                                    longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.6))
        withAnimation { camera = .region(MKCoordinateRegion(center: c, span: span)) }
    }

    private func focus(_ s: LiveSpot) {
        withAnimation {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                                                latitudinalMeters: 800, longitudinalMeters: 800))
        }
    }

    private func initial(_ uid: String) -> String {
        String((uid == me ? "You" : name(uid)).prefix(1)).uppercased()
    }

    private func updatedWords(_ at: Date) -> String {
        let s = tick.timeIntervalSince(at)
        if s < 60 { return "Updated just now" }
        let m = Int(s / 60)
        return m == 1 ? "Updated 1 min ago" : "Updated \(m) min ago"
    }
}

/// A person on a live map: their photo in a white ring, a green ring breathing out of it while live.
struct LivePhotoPin: View {
    let url: String?
    var live: Bool = true
    @State private var image: UIImage?
    @State private var breathe = false

    var body: some View {
        ZStack {
            if live {
                Circle().fill(Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255))
                    .frame(width: 44, height: 44)
                    .scaleEffect(breathe ? 1.6 : 1)
                    .opacity(breathe ? 0 : 0.5)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true }
                    }
            }
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(.systemGray4) }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 3)
        }
        .task(id: url) {
            guard let url, !url.isEmpty else { return }
            image = ProfilePhotoLoader.shared.cachedAvatar(url)
            if image == nil { image = await ProfilePhotoLoader.shared.avatar(url) }
        }
    }
}
