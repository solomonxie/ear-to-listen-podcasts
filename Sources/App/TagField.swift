import SwiftUI

/// Subject tags, as chips you can add to and take away.
///
/// Topics belong to a **collection** — a topic is what a series is about, and tagging
/// forty episodes of one album one at a time isn't a thing anyone would do. An episode
/// page shows its album's, and says whose they are via `ownerName`, because editing there
/// changes what the other episodes show too.
struct TagField: View {
    let names: [String]
    /// Named when the tags belong to something other than the page you're on — an
    /// episode showing its collection's tags has to say whose they are.
    var ownerName: String?
    var labelWidth: CGFloat?
    @Binding var open: String?
    let onChange: ([String]) -> Void

    @State private var newTag = ""
    @FocusState private var isAdding: Bool

    private var isOpen: Bool { open == "topics" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Topics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)

                // Wraps rather than running off the edge: tags are short but there can be
                // several, and a row that scrolls sideways hides the ones past the fold.
                FlowLayout(spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        Button {
                            onChange(names.filter { $0 != name })
                        } label: {
                            HStack(spacing: 4) {
                                Text(name)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { open = isOpen ? nil : "topics" }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)

            if isOpen {
                HStack {
                    TextField("New topic", text: $newTag)
                        .font(.footnote)
                        .focused($isAdding)
                        .submitLabel(.done)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.leading, labelWidth ?? 0)
                .onAppear { isAdding = true }

                if let ownerName {
                    Text("Tags the whole collection — \(ownerName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, labelWidth ?? 0)
                }
            }
        }
    }

    private func commit() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !names.contains(trimmed) else { return }
        onChange(names + [trimmed])
        newTag = ""
    }
}
