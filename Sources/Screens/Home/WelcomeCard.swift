import SwiftUI

/// What an empty library shows instead of nothing: what the app does, and the two ways in.
struct WelcomeCard: View {
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your audio, searchable by what was said")
                .font(.title3.weight(.bold))
            VStack(alignment: .leading, spacing: 10) {
                point("externaldrive.connected.to.line.below", "Plays straight from your own storage — S3, COS, OSS, Azure, Google Cloud, or a folder in Files.")
                point("text.bubble", "Transcribes on the phone, and lets you fix any line in place.")
                point("magnifyingglass", "Search finds the moment something was said, and plays from that second.")
            }
            Button(action: trySample) {
                Label("Try the sample library", systemImage: "theatermasks.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            NavigationLink(value: HomeRoute.settings) {
                Label("Connect your storage", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Text("The sample library is kept apart from yours. Turn it off any time in Settings → Demo mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { _ in errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text).font(.subheadline)
        }
    }

    private func trySample() {
        do {
            try DemoMode.enter()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
