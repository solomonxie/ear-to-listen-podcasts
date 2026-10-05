import SwiftUI

/// Every episode the library can't say enough about, each with what's wrong and a fix.
struct FlaggedItemsView: View {
    @State private var items: [FlaggedEpisodes.Item] = []
    @State private var filter: FlaggedEpisodes.Reason?
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var renaming: [FlaggedEpisodes.Item]?
    @State private var placing: [FlaggedEpisodes.Item]?
    @State private var confirming: (FlaggedFix, [FlaggedEpisodes.Item])?
    @State private var message: String?
    @State private var isWorking = false

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var shown: [FlaggedEpisodes.Item] {
        guard let filter else { return items }
        return items.filter { $0.reasons.contains(filter) }
    }

    private var selectedItems: [FlaggedEpisodes.Item] { items.filter { selection.contains($0.id) } }

    var body: some View {
        List {
            Section {
                NavigationLink { NeglectedItemsView() } label: {
                    Label("Neglected items", systemImage: "eye.slash")
                }
                NavigationLink { FixHistoryView() } label: {
                    Label("Fix history", systemImage: "clock.arrow.circlepath")
                }
            }

            Section {
                if shown.isEmpty {
                    Text(items.isEmpty ? "Nothing flagged." : "Nothing flagged for this tag.").foregroundStyle(.secondary)
                }
                ForEach(shown) { item in row(item) }
            } header: {
                Text("\(shown.count) flagged")
            }
        }
        .navigationTitle("Flagged items")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(FlaggedEpisodes.Reason?.none)
                        ForEach(FlaggedEpisodes.Reason.allCases) { reason in
                            Text("\(FlaggedEpisodes.label(reason)) (\(count(reason)))").tag(Optional(reason))
                        }
                    }
                } label: {
                    Image(systemName: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    selection = []
                }
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(selection.count == shown.count ? "Select None" : "Select All") {
                        selection = selection.count == shown.count ? [] : Set(shown.map(\.id))
                    }
                    Spacer()
                    Menu("Fix \(selection.count) selected") {
                        ForEach(FlaggedFix.allCases.filter { !$0.isSingleOnly }) { fix in
                            Button(fix.title, systemImage: fix.symbol, role: fix.isDestructive ? .destructive : nil) {
                                start(fix, on: selectedItems)
                            }
                        }
                    }
                    .disabled(selection.isEmpty || isWorking)
                }
            }
        }
        .sheet(item: Binding(get: { renaming.map { Wrapper(items: $0) } }, set: { if $0 == nil { renaming = nil } })) { wrapper in
            RenameSheet(title: wrapper.items.first?.track.title ?? "") { newTitle in
                run(.rename, wrapper.items, title: newTitle)
            }
        }
        .sheet(item: Binding(get: { placing.map { Wrapper(items: $0) } }, set: { if $0 == nil { placing = nil } })) { wrapper in
            PlaceSheet(count: wrapper.items.count) { speaker, collection in
                run(.assignPlace, wrapper.items, speaker: speaker, collection: collection)
            }
        }
        .confirmationDialog(
            confirming.map { "\($0.0.title) — \($0.1.count) episode\($0.1.count == 1 ? "" : "s")?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let (fix, targets) = confirming {
                Button(fix.title, role: .destructive) { run(fix, targets) }
            }
        } message: {
            Text(confirming?.0 == .deleteWithFile
                 ? "Deletes the entry and the audio file in your storage. This can't be undone."
                 : "Deletes the entry, with its marks and notes.")
        }
        .alert("Fix", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in load() }
    }

    private struct Wrapper: Identifiable { let id = UUID(); let items: [FlaggedEpisodes.Item] }

    private func count(_ reason: FlaggedEpisodes.Reason) -> Int {
        items.filter { $0.reasons.contains(reason) }.count
    }

    private func row(_ item: FlaggedEpisodes.Item) -> some View {
        let fixes = suggestedFixes(for: item)
        return HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.track.title).lineLimit(2)
                Text((item.track.filePath as NSString).lastPathComponent)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                tags(item)
            }
            Spacer(minLength: 0)
            if !isSelecting {
                Menu("Fix") {
                    ForEach(fixes) { fix in
                        Button(fix.title, systemImage: fix.symbol, role: fix.isDestructive ? .destructive : nil) {
                            start(fix, on: [item])
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        }
    }

    private func tags(_ item: FlaggedEpisodes.Item) -> some View {
        HStack(spacing: 6) {
            ForEach(FlaggedEpisodes.Reason.allCases.filter { item.reasons.contains($0) }) { reason in
                Text(FlaggedEpisodes.label(reason))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((reason == .noAudio ? Color.red : .orange).opacity(0.18), in: Capsule())
            }
        }
    }

    private func suggestedFixes(for item: FlaggedEpisodes.Item) -> [FlaggedFix] {
        var fixes: [FlaggedFix] = []
        for reason in FlaggedEpisodes.Reason.allCases where item.reasons.contains(reason) {
            for fix in FlaggedFix.suggested(for: reason) where !fixes.contains(fix) && fix.applies(to: item) {
                fixes.append(fix)
            }
        }
        if !fixes.contains(.deleteWithFile), FlaggedFix.deleteWithFile.applies(to: item) { fixes.append(.deleteWithFile) }
        return fixes
    }

    private func start(_ fix: FlaggedFix, on targets: [FlaggedEpisodes.Item]) {
        switch fix {
        case .rename: renaming = targets
        case .assignPlace: placing = targets
        case .deleteRecord, .deleteWithFile: confirming = (fix, targets.filter { fix.applies(to: $0) })
        default: run(fix, targets)
        }
    }

    private func run(
        _ fix: FlaggedFix, _ targets: [FlaggedEpisodes.Item], title: String? = nil, speaker: String? = nil,
        collection: String? = nil
    ) {
        isWorking = true
        Task {
            let outcome = await FlaggedFixer().apply(fix, to: targets, title: title, speaker: speaker, collection: collection)
            isWorking = false
            selection = []
            load()
            var lines = ["\(outcome.fixed) fixed" + (outcome.skipped > 0 ? ", \(outcome.skipped) didn't fit" : "")]
            lines += outcome.failures.prefix(4)
            if !outcome.failures.isEmpty || outcome.fixed == 0 { message = lines.joined(separator: "\n") }
        }
    }

    private func load() {
        let store = trackStore
        Task {
            let loaded = await Task.detached(priority: .utility) { (try? store.flaggedItems()) ?? [] }.value
            items = loaded
            selection = selection.intersection(Set(loaded.map(\.id)))
        }
    }
}

private struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var title: String
    let onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form { TextField("Title", text: $title) }
                .navigationTitle("Rename")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(title); dismiss() }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

private struct PlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onSave: (String, String) -> Void
    @State private var speaker = ""
    @State private var collection = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Speaker", text: $speaker); TextField("Collection", text: $collection) }
                footer: { Text("Applied to \(count) episode\(count == 1 ? "" : "s"). Leave one blank to keep what's there.") }
            }
            .navigationTitle("Set speaker & collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onSave(speaker, collection); dismiss() }
                        .disabled(speaker.trimmingCharacters(in: .whitespaces).isEmpty
                                  && collection.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
