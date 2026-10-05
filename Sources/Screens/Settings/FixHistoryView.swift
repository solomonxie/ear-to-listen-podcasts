import SwiftUI

struct FixHistoryView: View {
    @State private var entries: [FixHistoryEntry] = []
    private let store = FixHistoryStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        List {
            if entries.isEmpty { Text("No fixes yet.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.action).font(.headline)
                        Spacer()
                        Text("\(entry.count)").foregroundStyle(.secondary)
                    }
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle("Fix history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { try? store.clear(); load() }
                }
            }
        }
        .task { load() }
    }

    private func load() { entries = (try? store.all()) ?? [] }
}
