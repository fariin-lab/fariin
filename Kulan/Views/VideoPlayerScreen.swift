import SwiftUI
import AVKit
import FirebaseStorage

// Full-screen player for an E2EE video message — the delivery half of the mailman model:
// play from the device copy if we have one; otherwise download the ciphertext, decrypt,
// KEEP it on this device (VideoCache), and then delete the server object (1:1 chats) so
// our storage never holds delivered videos. Groups skip the delete (other members still
// need it) — the 30-day storage sweep collects those.
struct VideoPlayerScreen: View {
    let message: Message
    let cid: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else if unavailable {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.system(size: 34))
                    Text("Video no longer available")
                        .font(.system(size: 15, weight: .medium))
                    Text("It was delivered and removed from the server.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 6).padding(.leading, 14)
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        // 1) This device already has it (sender saved at send; recipient on first watch).
        if let local = VideoCache.url(for: message.id) {
            startPlayer(local); return
        }
        // 2) Collect from the server, keep locally, then clear the mailbox.
        guard let s = message.videoUrl, let url = URL(string: s), let meta = message.enc,
              let (cipher, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
            await MainActor.run { unavailable = true }
            return
        }
        VideoCache.store(data, for: message.id)
        if let local = VideoCache.url(for: message.id) { startPlayer(local) }
        // Delivered → delete the server object. 1:1 only: the cid encodes both uids, which
        // the storage rule checks; group members can't be verified there, so groups rely
        // on the 30-day lifecycle sweep instead. Best-effort — a failure just means the
        // sweep collects it later.
        if cid.contains("_"), message.authorId != AuthService.shared.uid {
            try? await Storage.storage().reference(forURL: s).delete()
        }
    }

    @MainActor private func startPlayer(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }
}
