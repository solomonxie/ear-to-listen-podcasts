import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showingAddS3 = false

    var body: some View {
        NavigationStack {
            List {
                Section("Storage providers") {
                    if viewModel.providers.isEmpty {
                        Text("No storage configured yet. Add your S3 bucket to start.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.providers) { record in
                        providerRow(record)
                    }
                }
                Section("Spotify playlist import") {
                    TextField("Spotify Client ID", text: $viewModel.spotifyClientID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { viewModel.saveSpotifyClientID() }
                    Button("Save Client ID") { viewModel.saveSpotifyClientID() }
                    Text("Create an app at developer.spotify.com, add byomusic://spotify-callback as a redirect URI, then paste its Client ID here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddS3 = true
                    } label: {
                        Label("Add S3 Bucket", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddS3) {
                AddS3ProviderView(viewModel: viewModel)
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onAppear { viewModel.load() }
        }
    }

    @ViewBuilder
    private func providerRow(_ record: ProviderRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.label)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { record.isActive },
                    set: { _ in viewModel.toggleActive(record) }
                ))
                .labelsHidden()
            }
            HStack {
                Text(record.type.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = viewModel.testResults[record.id] {
                    Label(
                        result.isSuccess ? "Connected" : (result.message ?? "Failed"),
                        systemImage: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(result.isSuccess ? .green : .red)
                }
            }
            Button("Test Connection") { viewModel.testConnection(record) }
                .font(.caption)
        }
        .swipeActions {
            Button("Delete", role: .destructive) { viewModel.delete(record) }
        }
    }
}
