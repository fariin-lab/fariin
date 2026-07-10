import SwiftUI

// Custom bubble-colour editor (our own recreation of Signal's "Custom Color" page): Solid/Gradient
// segmented control, a live message preview, a Hue slider and a Saturation slider, Set to apply.
struct CustomColorView: View {
    let cid: String
    var onSet: (ChatColorSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    @State private var isGradient = false
    @State private var hue1 = 0.62
    @State private var sat1 = 0.72
    @State private var hue2 = 0.78
    @State private var sat2 = 0.72
    @State private var editingStop = 0   // gradient: which end the sliders control

    private var spec: ChatColorSpec {
        isGradient ? .gradient((hue1, sat1), (hue2, sat2)) : .solid(hue: hue1, saturation: sat1)
    }
    private var hueBinding: Binding<Double> { editingStop == 0 || !isGradient ? $hue1 : $hue2 }
    private var satBinding: Binding<Double> { editingStop == 0 || !isGradient ? $sat1 : $sat2 }
    private var activeHue: Double { hueBinding.wrappedValue }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Picker("", selection: $isGradient) {
                    Text("Solid").tag(false)
                    Text("Gradient").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                preview

                if isGradient { stopSelector }

                VStack(alignment: .leading, spacing: 22) {
                    sliderBlock("Hue", GradientSlider(value: hueBinding, track: hueTrack))
                    sliderBlock("Saturation", GradientSlider(value: satBinding, track: satTrack))
                }
                .padding(.horizontal, 16)

                Spacer()
            }
            .padding(.top, 8)
            .navigationTitle("Custom Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set") { onSet(spec); dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    // Live preview: incoming (real received colour) + outgoing (the chosen colour) bubbles on the
    // ACTUAL chat background. Only the outgoing bubble recolours as the sliders move — the background
    // and incoming bubbles stay exactly as they are in the real chat.
    private var preview: some View {
        VStack(spacing: 10) {
            Text("Today").font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
            previewBubble("Here's a preview of the chat color.", mine: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            previewBubble("The color is visible to only you.", mine: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            previewBubble("Another bubble", mine: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background { ChatWallpaperBackground(cid: cid) }   // the user's real chat background, unchanged
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func previewBubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(mine ? .white : (dark ? .white : .black))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(mine ? spec.fill : AnyShapeStyle(Theme.received(dark)))
            }
    }

    // Gradient: two dots to choose which end the sliders edit.
    private var stopSelector: some View {
        HStack(spacing: 14) {
            ForEach(0..<2, id: \.self) { i in
                let c = i == 0 ? Color(hue: hue1, saturation: sat1, brightness: 0.86)
                               : Color(hue: hue2, saturation: sat2, brightness: 0.86)
                Circle().fill(c).frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(editingStop == i ? Color.primary : .clear, lineWidth: 3))
                    .onTapGesture { editingStop = i }
            }
        }
    }

    private func sliderBlock<S: View>(_ title: String, _ slider: S) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            slider
        }
    }

    private var hueTrack: LinearGradient {
        LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
            Color(hue: $0, saturation: 0.9, brightness: 0.95)
        }, startPoint: .leading, endPoint: .trailing)
    }
    private var satTrack: LinearGradient {
        LinearGradient(colors: [Color(hue: activeHue, saturation: 0, brightness: 0.7),
                                Color(hue: activeHue, saturation: 1, brightness: 0.86)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

// A rounded gradient track with a draggable white thumb (0…1).
struct GradientSlider: View {
    @Binding var value: Double
    let track: LinearGradient

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumb: CGFloat = 28
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: 14)
                Circle().fill(.white).frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: min(max(0, CGFloat(value) * (w - thumb)), w - thumb))
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = min(max(0, Double((g.location.x - thumb / 2) / (w - thumb))), 1)
            })
        }
        .frame(height: 28)
    }
}
