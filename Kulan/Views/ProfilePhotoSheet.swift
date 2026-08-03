import SwiftUI

// The Edit Photo sheet: your picture, large, with the three things you can do to it.
//
// It replaces a list of words (Choose Photo / Remove Photo / Cancel) with the photo itself and two
// buttons, to the owner's drawing (2026-08-03): X at the top left, the circle in the middle wearing
// a small X of its own for remove, and Take photo / Choose photo along the bottom. Everything the
// finger can reach is real Liquid Glass, which on this screen means the sheet is the only place in
// Edit Profile where glass appears at all — there is a photograph behind it to refract.
//
// The sheet DECIDES, it does not DO. Every action is recorded here and run by the presenter in the
// sheet's `onDismiss`: presenting a camera, a photo picker or an alert from inside a sheet that is
// still dismissing is the "nothing happens" bug this app has already been bitten by twice, and the
// note at the top of BottomActionSheet.swift says so in as many words.

enum ProfilePhotoAction {
    case camera     // Apple's camera, to take a new one
    case library    // Apple's photo picker, to choose one
    case remove     // no picture, back to the letter
}

struct ProfilePhotoSheet: View {
    let name: String
    /// The saved picture. Nil while a removal is pending, so the sheet shows what you are about to
    /// have rather than what you just asked to get rid of.
    let photoUrl: String?
    /// A picked-but-not-yet-saved photo wins over the saved one, for the same reason.
    let pendingImage: UIImage?
    let canRemove: Bool
    @Binding var action: ProfilePhotoAction?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private let circle: CGFloat = 190

    /// Fitted, so there is no dead space under the buttons. Kept next to the layout that produces
    /// it: 16 top + 48 X + 22 + circle + 30 + 54 buttons + 30 bottom.
    static let height: CGFloat = 390

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CloseXButton { dismiss() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer(minLength: 0)

            photo
                .overlay(alignment: .topTrailing) {
                    if canRemove {
                        Button { choose(.remove) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .liquidGlass(Circle(), interactive: true)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        // Sitting ON the edge, at about one o'clock, is what makes it read as
                        // belonging to the picture instead of floating beside it.
                        .offset(x: 6, y: 14)
                        .accessibilityLabel("Remove photo")
                    }
                }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                actionButton("Take photo", icon: "camera") { choose(.camera) }
                actionButton("Choose photo", icon: "photo") { choose(.library) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .presentationDetents([.height(Self.height)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.regularMaterial)
    }

    /// The picture, with a soft halo so a dark photo does not sit on the sheet like a hole. White at
    /// low strength in light, barely there in dark — a white glow that reads as light in the day
    /// reads as a lamp at night.
    private var photo: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: circle + 24, height: circle + 24)
                .blur(radius: 16)
                .opacity(scheme == .dark ? 0.10 : 0.55)

            if let pendingImage {
                Image(uiImage: pendingImage).resizable().scaledToFill()
                    .frame(width: circle, height: circle)
                    .clipShape(Circle())
            } else {
                AvatarView(name: name, photoUrl: photoUrl, size: circle)
            }
        }
        .frame(width: circle, height: circle)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 16, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity).frame(height: 54)
            .liquidGlass(Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ a: ProfilePhotoAction) {
        action = a
        dismiss()
    }
}
