import SwiftUI
import UniformTypeIdentifiers

struct AiKeysSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingAddAiKey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeading(
                        title: "AI KEYS",
                        info: "Used to guess better titles and show names during sync, and to transcribe an episode on playback. Sent straight from this device to the chosen vendor — never stored or seen by us, and never included in backups. Add more than one to fall back automatically if one hits a rate limit."
                    )
                    Spacer()
                    // The fallback order only matters with more than one key, but the
                    // control stays put either way so it doesn't appear out of nowhere.
                    Button {
                        viewModel.setAiKeyStrategy(viewModel.aiKeyStrategy == .sequential ? .roundRobin : .sequential)
                    } label: {
                        Text("\(viewModel.aiKeyStrategy.displayName) ▾").font(.caption.weight(.semibold))
                    }
                    .disabled(viewModel.aiKeys.count < 2)
                }
                Text("Better titles during sync, and transcription on playback.")
                    .sectionHint()
                ForEach(Array(viewModel.aiKeys.enumerated()), id: \.element.id) { index, key in
                    HStack {
                        // The key's own page: what it's been asked, what came back, and
                        // what that cost. A request count alone explains nothing.
                        NavigationLink {
                            AiKeyDetailView(key: key)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.displayName).font(.subheadline)
                                Text("\(key.requestCount) request\(key.requestCount == 1 ? "" : "s") sent")
                                    .sectionRowSecondary()
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if viewModel.aiKeys.count > 1 {
                            Button { viewModel.moveAiKey(key, direction: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { viewModel.moveAiKey(key, direction: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == viewModel.aiKeys.count - 1)
                        }
                        // An explicit menu rather than only a long-press context menu —
                        // deleting a key shouldn't be a hidden gesture.
                        Menu {
                            Button(role: .destructive) {
                                viewModel.removeAiKey(key)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showingAddAiKey = true
                } label: {
                    Label("Add AI Key", systemImage: "plus.circle")
                }
            }
            .settingsCard()
            .sheet(isPresented: $showingAddAiKey) {
                AddAiKeyView(viewModel: viewModel)
            }
            }
            .sectionRow()
            .padding(.vertical)
            .padding(.bottom, 72)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("AI Keys")
        .navigationBarTitleDisplayMode(.inline)
    }
}
