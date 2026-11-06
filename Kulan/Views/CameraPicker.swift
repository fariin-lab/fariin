import SwiftUI
import UIKit
import AVFoundation

// Native in-app camera. Returns the captured photo as JPEG Data, which flows
// through the SAME encrypted-image pipeline as library photos (ChatService.sendImage).
//
// Camera permission is checked first (chat, new group, new channel, profile photo all come
// through here). Refused or restricted: the story camera's explain + Open Settings panel and a
// close button, instead of the picker's dead black screen. Not asked yet: ask, then open.
struct CameraPicker: View {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        // No camera (simulator): the controller falls back to the library, which needs no camera access.
        if !UIImagePickerController.isSourceTypeAvailable(.camera) || access == .authorized {
            CameraPickerController(onImage: onImage)
        } else if access == .notDetermined {
            Color.black
                .ignoresSafeArea()
                .task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    access = granted ? .authorized : .denied
                }
        } else {
            // Close sits under the panel, mid-screen: some callers ignore the safe area, so a corner
            // button could land under the notch.
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 18) {
                    CameraDeniedPanel()
                    Button("Close") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// Camera access denied/restricted: explain and route to Settings. Shared by the story camera and
/// every other camera (`CameraPicker`). Drawn for a dark background.
struct CameraDeniedPanel: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.6))
            Text("Camera access is off. Turn it on in Settings.")
                .font(.subheadline).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(.black)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(.white, in: Capsule())
        }
        .padding(.horizontal, 40)
    }
}

private struct CameraPickerController: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Fall back to the library on devices/simulators with no camera (was a hard crash).
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerController
        init(_ parent: CameraPickerController) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let data = img.jpegData(compressionQuality: 0.8) {
                parent.onImage(data)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
