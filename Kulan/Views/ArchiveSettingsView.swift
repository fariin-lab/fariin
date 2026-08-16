import SwiftUI

// The archive page's own two screens, both reached from the "..." menu it grew on 2026-08-13.
//
// Neither is new behaviour. The auto-archive switch already existed, three taps deep in
// Settings > Chats, where somebody standing in the archive was never going to find it; and nothing
// anywhere in the app said what archiving actually does. The owner asked for both, pointing at the
// reference app's Archive Settings / How Does It Work pair.

/// The switch, in the place it is about. Same `@AppStorage` key as Settings > Chats, so the two
/// screens are two windows onto one setting and cannot disagree.
struct ArchiveSettingsView: View {
    @AppStorage(UnknownChatArchiver.defaultsKey) private var autoArchiveUnknown = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Automatically Archive", isOn: $autoArchiveUnknown).tint(.green)
                } header: {
                    Text("New Chats from Unknown Users")
                } footer: {
                    // The same sentence as Settings > Chats, word for word and deliberately: one
                    // switch described twice is how two descriptions drift apart.
                    Text("When someone you have never replied to starts a chat, it goes straight to Archived and stays muted. You still get the message.")
                }
            }
            .navigationTitle("Archive Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// What archiving does, in THIS app's words.
///
/// REWRITTEN 2026-08-13 after he held it up against theirs and asked which one a person understands.
/// Theirs, and not by a small margin — for three reasons that are all shape rather than wording:
/// their lines are ONE line each, every line starts with the thing you DO rather than what the
/// feature IS, and the sheet ends in one big button with a shortcut to the setting sitting in the
/// text. Ours was more accurate and less understandable, on an app read in a second language.
///
/// So: one line per point, each one an action, a half sheet rather than a page, and Got it at the
/// bottom. ⚠️ HIS CONDITION, and it is the reason not one string here is theirs: "don't copy their
/// text, make our own". The SHAPE is what was learned; the words are this app's, and every one of
/// them is still checked against the code — the list filter that hides an archived chat, the badge
/// filter that skips it, a new message not pulling it back, and the fact that manual archiving does
/// not mute, which is the one thing the app it is modelled on does and we do not.
struct ArchiveHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    /// Straight to the switch, from the line that mentions it — the shortcut theirs puts in its
    /// opening sentence. Nobody reads an explainer and then goes hunting through Settings.
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 18) {
                        // `Color.accentColor` is the app's `.primary` tint, so it is WHITE at night.
                        // Both this glyph and the Got it label below were hardcoded white on it.
                        MenuIcon("ic_archive", size: 34)
                            .foregroundStyle(Theme.onAccent(dark))
                            .frame(width: 76, height: 76)
                            .background(Circle().fill(Color.accentColor))
                            .padding(.top, 8)
                        Text("Archived Chats")
                            .font(.title3.weight(.semibold))
                        VStack(alignment: .leading, spacing: 18) {
                            point("hand.draw", "Swipe a chat to put it here")
                            point("tray.and.arrow.up", "Swipe it again to take it back")
                            point("bell.slash", "It stops counting on the Chats tab")
                            point("bell.badge", "It still notifies you, unless you mute it")
                        }
                        Button { showSettings = true } label: {
                            HStack(spacing: 4) {
                                Text("New chats from people you don't know can come straight here.")
                                    .foregroundStyle(.secondary)
                                Text("Change").foregroundStyle(Color.accentColor)
                            }
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                Button { dismiss() } label: {
                    Text("Got it").font(.headline).foregroundStyle(Theme.onAccent(dark))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // one exit, and it is the button
            .sheet(isPresented: $showSettings) { ArchiveSettingsView() }
        }
        // A half sheet, not a page: it is four lines, and a full screen for four lines reads as
        // something you have to get through.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// One line, one action, one icon. No second paragraph — the paragraph is what made the old one
    /// something to read rather than something to glance at.
    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, alignment: .center)
            Text(text).font(.system(size: 15))
            Spacer(minLength: 0)
        }
    }
}
