import SwiftUI
import LiveKit

// Group call screen — voice = avatar grid, video = live tile grid. Frosted-capsule controls to
// match the 1:1 call UI. Observes the LiveKit Room directly for live participant updates.
struct GroupCallView: View {
    @ObservedObject private var service = GroupCallService.shared
    @ObservedObject private var room = GroupCallService.shared.room
    @Environment(\.dismiss) private var dismiss

    private var participants: [Participant] {
        [room.localParticipant as Participant] + room.remoteParticipants.values.map { $0 as Participant }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                header
                if service.isVideo {
                    ScrollView { videoGrid }
                } else {
                    Spacer(); voiceGrid; Spacer()
                }
                controls
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        // Always dark, for the same reason the 1:1 call is — see `CallView`. A call is drawn for a
        // dark ground whatever the phone is set to.
        .environment(\.colorScheme, .dark)
        .onChange(of: service.activeCid) { _, cid in if cid == nil { dismiss() } }
    }

    private var header: some View {
        HStack {
            Button {
                service.minimized = true   // NOT ending the call: the green return bar takes over
                dismiss()
            } label: {
                Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(.white.opacity(0.15), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(service.callTitle).font(.headline).foregroundStyle(.white)
                Text("\(participants.count) in call").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
    }

    private var voiceGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 22) {
            ForEach(participants, id: \.sid) { p in   // stable id: index-keyed tiles reused the wrong track on join/leave
                VStack(spacing: 6) {
                    AvatarView(name: p.name ?? "Member", photoUrl: nil, size: 76)
                        .overlay(Circle().stroke(Color.green, lineWidth: p.isSpeaking ? 3 : 0))
                    Text(p.name ?? "Member").font(.caption).foregroundStyle(.white).lineLimit(1)
                }
            }
        }
    }

    private var videoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(participants, id: \.sid) { p in   // stable id (see voiceGrid)
                ZStack(alignment: .bottomLeading) {
                    if let track = p.firstCameraVideoTrack {
                        SwiftUIVideoView(track, layoutMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.12)
                            AvatarView(name: p.name ?? "Member", photoUrl: nil, size: 56)
                        }
                    }
                    HStack(spacing: 4) {
                        if !p.isMicrophoneEnabled() { Image(systemName: "mic.slash.fill").font(.caption2) }
                        Text(p.name ?? "Member").font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(.white).padding(6)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            ctrl(service.cameraOn ? "video.fill" : "video.slash.fill") { service.toggleCamera() }
            ctrl(service.micOn ? "mic.fill" : "mic.slash.fill") { service.toggleMic() }
            routeCtrl
            ctrl("phone.down.fill", tint: Color(.systemRed)) { service.end() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // Native audio-route button (the system route picker): group calls run on speaker by default;
    // this lets you move the call to AirPods/Bluetooth/earpiece through the system sheet.
    private var routeCtrl: some View {
        ZStack {
            Image(systemName: "speaker.wave.2.fill").font(.title3).foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .liquidGlass(Circle(), interactive: true)
            AudioRoutePicker().frame(width: 54, height: 54).clipShape(Circle())
        }
    }

    private func ctrl(_ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                // Real Liquid Glass circles (was a flat white-20% fill); end button = red glass.
                .liquidGlass(Circle(), interactive: true, tint: tint)
        }
    }
}
