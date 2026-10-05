import SwiftUI

/// Original or spoken transcript, and the two ways to save space: drop the phone's copy of
/// the original, or delete the original from its bucket for good.
struct EpisodeAudioSection: View {
    let track: Track
    @ObservedObject private var renderer = VoiceRenderer.shared
    @State private var current: Track
    @State private var cachedBytes: Int64?
    @State private var voiceBytes: Int64?
    @State private var confirmingDeleteOriginal = false
    @State private var message: String?
    @State private var isWorking = false

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(track: Track) {
        self.track = track
        _current = State(initialValue: track)
    }

    private var hasOriginal: Bool { !current.isLost && current.originalDeletedAt == nil }
    private var hasVoice: Bool { voiceBytes != nil }
    private var language: String? { VoiceTrack.language(for: current) }

    var body: some View {
        Section {
            Picker("Listen to", selection: Binding(get: { current.prefersVoice || !hasOriginal }, set: setVoice)) {
                Text("Original").tag(false)
                Text("Voice").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!hasOriginal || !hasVoice)

            if let fraction = renderer.progress[current.id] {
                ProgressView(value: fraction) {
                    Text("Making voice track… \(Int(fraction * 100))%").font(.footnote)
                }
            } else if let bytes = voiceBytes {
                HStack {
                    Label("Voice track", systemImage: "waveform")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(.secondary)
                }
                Button("Make Again", systemImage: "arrow.clockwise") { renderer.render(current, language: language) }
                if hasOriginal {
                    Button("Delete Voice Track", systemImage: "trash", role: .destructive) {
                        VoiceTrack.remove(current.id)
                        setVoice(false)
                        reload()
                    }
                }
            } else {
                Button("Make Voice Track", systemImage: "waveform.badge.plus") { renderer.render(current, language: language) }
            }
            if let error = renderer.errors[current.id] {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            if VoiceTrack.onlyBasicVoice(language: language) {
                Text("Better voices are free: iPhone Settings → Accessibility → Spoken Content → Voices — download an Enhanced or Premium one for this language, then make the track again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if hasOriginal {
                if let cachedBytes {
                    Button("Remove Download from Phone (\(ByteCountFormatter.string(fromByteCount: cachedBytes, countStyle: .file)))", systemImage: "iphone.slash") {
                        Task {
                            await AudioCache.shared.invalidate(providerID: current.providerID, filePath: current.filePath)
                            reload()
                        }
                    }
                }
                Button("Delete Original from Bucket…", systemImage: "trash", role: .destructive) {
                    confirmingDeleteOriginal = true
                }
                .disabled(!hasVoice || isWorking)
                if !hasVoice {
                    Text("Make the voice track first — it's what you'll listen to once the original is gone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if current.originalDeletedAt != nil {
                Text("Original deleted from its bucket. This episode plays its voice track.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Voice speaks the transcript with the iPhone's own voices, on the transcript's timing, and works offline.")
        }
        .confirmationDialog("Delete the original from your bucket?", isPresented: $confirmingDeleteOriginal, titleVisibility: .visible) {
            Button("Delete Original", role: .destructive) { deleteOriginal() }
        } message: {
            Text("The audio file is deleted from your storage for good. The episode stays, with its marks and notes, and plays its voice track.")
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in reload() }
    }

    private func reload() {
        current = (try? trackStore.find(id: track.id)) ?? current
        voiceBytes = VoiceTrack.size(current.id)
        let providerID = current.providerID, path = current.filePath
        Task { cachedBytes = await AudioCache.shared.cachedSize(providerID: providerID, filePath: path) }
    }

    private func setVoice(_ voice: Bool) {
        renderer.setListening(voice: voice, track: current)
        current.prefersVoice = voice
    }

    private func deleteOriginal() {
        isWorking = true
        Task {
            let copies = ((try? TrackFileStore().all(forTrack: current.id)) ?? []).filter { !$0.isLost }
            let records = Dictionary(((try? ProviderStore(dbQueue: DatabaseManager.shared.dbQueue).all()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            do {
                for copy in copies {
                    guard let record = records[copy.providerID] else { continue }
                    try await ProviderManager.shared.provider(for: record).deleteFile(atPath: copy.filePath)
                    await AudioCache.shared.invalidate(providerID: copy.providerID, filePath: copy.filePath)
                }
                try trackStore.markOriginalDeleted(id: current.id)
                FixHistoryStore(dbQueue: DatabaseManager.shared.dbQueue)
                    .record(action: "Delete original", count: 1, detail: current.title)
                message = "Original deleted. Playing the voice track from now on."
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            } catch {
                message = "Couldn't delete the original: \(describeCloudError(error))"
            }
            isWorking = false
            reload()
            if let fresh = try? trackStore.find(id: track.id) { PlaybackEngine.shared.reloadCurrent(with: fresh) }
        }
    }
}
