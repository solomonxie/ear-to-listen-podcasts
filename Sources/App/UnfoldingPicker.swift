import SwiftUI

/// A form field whose options unfold **in the field's own row**, pushing the rest of the
/// form down, instead of floating a menu or a sheet over it.
///
/// A popup covers exactly the context the choice is made from: the label of the row being
/// changed, the fields already filled in, the value it's replacing. Unfolding keeps all of
/// that on screen — the row itself doesn't move, only what's below it does, so there's no
/// backdrop, no transition and nothing to dismiss.
///
/// ```
///  Language        English  ›        Language        English  ⌄
///  Notes                        →    ┌───────────────────────────┐
///  Topics                            │   Inherit (automatic)     │
///                                    │ ✓ English                 │
///                                    │   中文                     │
///                                    └───────────────────────────┘
///                                    Notes
///                                    Topics        ← pushed down, not covered
/// ```
///
/// The rules it encodes, from the mobile UI/UX guideline:
/// - The row doesn't move; everything below it does.
/// - **One open at a time** — opening a row folds away whichever was open, which is what
///   `open` is for: every picker in a form shares one binding.
/// - The chevron turns `›` → `⌄`: the row says where its options went.
/// - Full width, options on the same left edge as the row's own label.
/// - **No Cancel / Done.** Picking folds it; tapping the row again folds it unchanged.
///
/// Still a sheet or a menu, not this: a list's filter, a toolbar menu, a destructive
/// confirm, or a picker that genuinely needs the screen.
struct UnfoldingPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        /// A second line under the label — what the option means, when the name can't
        /// carry it on its own.
        var detail: String?

        var id: String { label }

        init(_ value: Value, _ label: String, detail: String? = nil) {
            self.value = value
            self.label = label
            self.detail = detail
        }
    }

    let title: LocalizedStringKey
    /// Identifies this row within its form, for the shared `open` binding.
    let id: String
    @Binding var open: String?
    @Binding var selection: Value
    let options: [Option]
    /// `.trailing` in a form, where the label holds the left edge. `.leading` when the row
    /// *is* the value — a labelless row with its answer pushed to the far right reads as
    /// two unrelated things.
    var valueAlignment: HorizontalAlignment = .trailing

    private var isOpen: Bool { open == id }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "—"
    }

    var body: some View {
        Button(action: toggle) {
            HStack {
                if valueAlignment == .trailing {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                }
                Text(currentLabel)
                    .foregroundStyle(valueAlignment == .trailing ? .secondary : .primary)
                    .lineLimit(1)
                if valueAlignment == .leading { Spacer() }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            ForEach(options) { option in
                Button {
                    // Picking is the commit and the dismissal, both.
                    selection = option.value
                    withAnimation(.easeOut(duration: 0.18)) { open = nil }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(option.value == selection ? 1 : 0)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).foregroundStyle(.primary)
                            if let detail = option.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.18)) {
            open = isOpen ? nil : id
        }
    }
}

/// A text field that unfolds from a row, for the same reason a picker does — an alert
/// with a `TextField` in it covers the list you're naming something to go into, and costs
/// a Cancel and a Create to type one word.
///
/// ```
///  ⊕ New playlist          →   ⊕ New playlist
///                              [ Name…              ]  [ Create ]
/// ```
struct UnfoldingTextField: View {
    let prompt: LocalizedStringKey
    let actionLabel: LocalizedStringKey
    let id: String
    @Binding var open: String?
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var isOpen: Bool { open == id }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { open = isOpen ? nil : id }
        } label: {
            Label(prompt, systemImage: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            HStack {
                TextField(prompt, text: $text)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                Button(actionLabel, action: commit)
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // Typing is the whole reason the row opened.
            .onAppear { isFocused = true }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        text = ""
        withAnimation(.easeOut(duration: 0.18)) { open = nil }
    }
}

/// A number chosen from a wheel that unfolds in the row, instead of typed on a keypad.
///
/// A year and a track number are picked from a short, ordered, known range — the kind of
/// thing a keypad is a bad fit for: it covers half the screen, offers every number
/// including the wrong ones, and needs a Done to dismiss. A wheel in the row shows the
/// neighbours, can't produce a value outside the range, and needs no dismissal.
///
/// ```
///  Year            2026  ›        Year            2026  ⌄
///  Track no.        —    ›   →    ┌────────────────────────┐
///                                 │         2027           │
///                                 │      ▸  2026  ◂        │
///                                 │         2025           │
///                                 └────────────────────────┘
///                                 Track no.        —    ›
/// ```
///
/// Per the guideline, a continuous control **commits as it moves** — there is no Done,
/// and the row's value updates under your thumb as the wheel turns.
struct UnfoldingWheel: View {
    let title: LocalizedStringKey
    let id: String
    @Binding var open: String?
    @Binding var value: Int?
    /// In the order they should appear on the wheel.
    let choices: [Int]
    /// What the row shows when nothing is set — the inherited value, where there is one
    /// ("2026 · from album"), rather than the field's own name.
    var placeholder: String = "—"

    private var isOpen: Bool { open == id }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { open = isOpen ? nil : id }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value.map(String.init) ?? placeholder)
                    .foregroundStyle(value == nil ? .secondary : .primary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            Picker(title, selection: $value) {
                // Clearing has to be on the wheel itself — there's no keyboard to delete
                // from, and "unset" is a real answer for both of these.
                Text("—").tag(Int?.none)
                ForEach(choices, id: \.self) { choice in
                    Text(String(choice)).tag(Int?.some(choice))
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 130)
            .labelsHidden()
        }
    }
}

enum NumberChoices {
    /// Newest first: audio in a personal library is mostly recent, and the top of the
    /// wheel is where it opens.
    static var years: [Int] {
        let thisYear = Calendar.current.component(.year, from: Date())
        return Array((1950...(thisYear + 1)).reversed())
    }

    /// Long enough for a lecture series, short enough to scroll.
    static let trackNumbers = Array(1...300)
}

/// `UnfoldingPicker`'s list replaced by a wheel, for options there are too many of to
/// read as rows — a few dozen languages is a scroll either way, and a wheel turns under
/// one thumb without the list scrolling the page along with it.
///
/// Commits as it moves, like every continuous control: no Done.
struct UnfoldingOptionWheel<Value: Hashable>: View {
    let title: LocalizedStringKey
    let id: String
    @Binding var open: String?
    @Binding var selection: Value
    let options: [UnfoldingPicker<Value>.Option]

    private var isOpen: Bool { open == id }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "—"
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { open = isOpen ? nil : id }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(currentLabel).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 130)
            .labelsHidden()
        }
    }
}

/// A text field with its label above it rather than beside it, growing with what's typed.
///
/// A `LabeledContent` row puts the value in a narrow trailing column — fine for "2026",
/// wrong for a sentence, and actively broken for a comma list, which clipped mid-word
/// rather than wrapping. Anything that can run to a line or more gets the full width and
/// no ceiling on its height: the box follows the text.
struct StackedField: View {
    let label: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String

    init(_ label: LocalizedStringKey, placeholder: LocalizedStringKey, text: Binding<String>) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
