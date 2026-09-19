import SwiftUI

/// What one key has actually been doing: every call made with it, newest first, with the
/// prompt and the reply behind a tap.
///
/// A request count on its own can't answer the questions people actually have about an AI
/// key — what is this spending money on, why did the bill jump, is this key failing? The
/// cost is an estimate from published list prices (`AiPricing`) and says so, because the
/// vendor's own invoice is the only real number.
struct AiKeyDetailView: View {
    let key: AiKey

    @State private var queries: [AiQuery] = []
    @State private var expanded: Set<String> = []
    @State private var showingClearConfirmation = false
    @State private var model: String?
    @State private var openPicker: String?

    private let store = AiQueryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let keyStore = AiKeyStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// Saves as it changes — there's no Done button on this screen, and a model picked
    /// and then navigated away from should be the model that gets called.
    private var modelBinding: Binding<String?> {
        Binding(
            get: { model },
            set: { newValue in
                model = newValue
                try? keyStore.setModel(id: key.id, model: newValue)
            }
        )
    }

    private var totalTokens: Int {
        queries.compactMap(\.totalTokens).reduce(0, +)
    }

    private var totalCost: Double? {
        let costs = queries.compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var body: some View {
        List {
            Section {
                AiModelPicker(vendor: key.vendor, model: modelBinding, id: "model", open: $openPicker)
            } header: {
                Text("Model")
            } footer: {
                Text("Used for every call made with this key. Leave it on Default unless you want a bigger model for better titles, or a cheaper one to spend less per sync.")
            }

            Section {
                LabeledContent("Requests", value: "\(key.requestCount)")
                LabeledContent("Tokens (last \(AiQueryStore.historyLimit))", value: totalTokens.formatted())
                LabeledContent("Estimated cost", value: totalCost.map(Self.money) ?? "—")
            } footer: {
                Text("Estimated from published per-token prices — your vendor's bill is the real number. The last \(AiQueryStore.historyLimit) calls are kept; older ones are dropped.")
            }

            Section("Recent calls") {
                if queries.isEmpty {
                    Text("Nothing sent with this key yet. It's used to guess episode titles during sync, and to transcribe on playback.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(queries) { query in
                        queryRow(query)
                    }
                }
            }
        }
        .navigationTitle(key.vendor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !queries.isEmpty {
                Button("Clear", role: .destructive) { showingClearConfirmation = true }
            }
        }
        .confirmationDialog("Clear this key's history?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                try? store.removeAll(keyID: key.id)
                queries = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the record of what was sent — the key itself stays.")
        }
        .onAppear {
            queries = (try? store.recent(keyID: key.id)) ?? []
            model = key.model
        }
    }

    /// Tap to open rather than push: the point of a row is comparing calls, and the
    /// prompt that explains one is two lines away, not a screen away.
    @ViewBuilder
    private func queryRow(_ query: AiQuery) -> some View {
        let isExpanded = expanded.contains(query.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(query.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Spacer()
                Text(query.estimatedCostUSD.map(Self.money) ?? "—")
                    .sectionRowSecondary()
            }
            Text(summary(query))
                .sectionRowSecondary()
            Text(query.errorMessage ?? query.prompt)
                .font(.caption)
                .foregroundStyle(query.errorMessage == nil ? .secondary : Color.red)
                .lineLimit(isExpanded ? nil : 2)

            if isExpanded, let response = query.response {
                Text("Reply").sectionHeading()
                Text(response)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expanded.remove(query.id) } else { expanded.insert(query.id) }
        }
    }

    private func summary(_ query: AiQuery) -> String {
        var parts = [query.model]
        if let prompt = query.promptTokens, let completion = query.completionTokens {
            parts.append("\(prompt) in → \(completion) out")
        } else if let total = query.totalTokens {
            parts.append("\(total) tokens")
        }
        return parts.joined(separator: " · ")
    }

    /// Single calls are fractions of a cent, so the usual two decimal places would render
    /// every row as "$0.00".
    private static func money(_ amount: Double) -> String {
        amount < 0.01 ? String(format: "~$%.4f", amount) : String(format: "~$%.2f", amount)
    }
}
