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

    private func durationTile(_ m: Int, _ title: String) -> some View {
        let on = minutes == m
        let ink: Color = on ? .onFariinAction : .primary
        return Button { minutes = m } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(ink.opacity(0.22), lineWidth: 3)
                    Circle().trim(from: 0, to: m == 15 ? 0.25 : 1)
                        .stroke(ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if m == 480 { Circle().fill(ink).frame(width: 3, height: 3) }
                }
                .frame(width: 30, height: 30)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(on ? Color.fariinAction : Color(.secondarySystemBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }

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
                // Three tiles, each with a small clock ring (owner 2026-11-13: "something cool, not cheap").
                HStack(spacing: 10) {
                    durationTile(15, "15 min")
                    durationTile(60, "1 hour")
                    durationTile(480, "8 hours")
                }
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
                    Text(fetcher.location == nil ? "Finding your location..." : "Start Sharing")
                        .font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Capsule().fill(Color.fariinAction))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
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
            .alert("Stop sharing live location?", isPresented: $confirmStop) {
                Button("Cancel", role: .cancel) {}
                Button("Stop", role: .destructive) { LiveLocationSharer.shared.stop(cid: cid) }
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
