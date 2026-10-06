import SwiftUI
import UniformTypeIdentifiers

struct AboutSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingRemoveAllConfirmation = false
    private let isDemo = AppMode.isDemo

    /// Version and build as shipped, so a bug report can name the build it came from.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(
                    title: "ABOUT",
                    info: "No accounts, no sign-in, no analytics, no ads, no tracking, and no server of ours to send anything to — there isn't one. Episodes play from the storage you picked, and backups go to storage you picked; both stay yours. The app reaches the network for two things only: the buckets and folders you added, and — if you add a key — the AI vendor that key belongs to, straight from this device. Transcription runs on the phone."
                )
                Text("Ear to Listen \(appVersion)").sectionHint()
                Text("An offline audio player. It collects no data about you, has no backend server, plays audio from storage you choose, and backs up to storage you choose.")
                    .sectionHint()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsCard()

            if !isDemo {
                Button("Remove All App Data", role: .destructive) {
                    showingRemoveAllConfirmation = true
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .confirmationDialog("Remove all app data?", isPresented: $showingRemoveAllConfirmation) {
                    Button("Remove Everything", role: .destructive) {
                        Task { await viewModel.removeAllAppData() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes everything stored by the app on this device. A copy is saved first, by itself: into Files, and into iCloud Drive and your bucket wherever they're connected.")
                }
            }
            }
            .sectionRow()
            .padding(.vertical)
            .padding(.bottom, 72)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
