import SwiftUI

/// Which model a key calls: the vendor's default, one of a handful of presets, or
/// anything you care to type.
///
/// The custom field is the point, not an escape hatch. Vendors ship and retire models far
/// faster than this app ships builds, so a closed list would be wrong within months — and
/// there's no way to validate a name from here anyway. What catches a typo is the test
/// call that "Add key" already makes, which now goes through the chosen model.
struct AiModelPicker: View {
    let vendor: AiVendor
    /// Nil means the vendor default.
    @Binding var model: String?
    let id: String
    @Binding var open: String?

    @State private var isCustom = false
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    private static let defaultTag = "\u{1}default"
    private static let customTag = "\u{1}custom"

    var body: some View {
        // Grouped so both rows share the lifecycle modifiers below — in a Form a `Group`
        // of two views is still two rows.
        Group {
            UnfoldingPicker(
            title: "Model", id: id, open: $open, selection: selection,
            options: [UnfoldingPicker.Option(Self.defaultTag, "Default", detail: vendor.defaultModel)]
                + vendor.presetModels.map { UnfoldingPicker.Option($0, $0) }
                    + [UnfoldingPicker.Option(Self.customTag, "Custom…", detail: "Type any model name")]
            )
            if isCustom {
                TextField("model-name", text: $customText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($customFocused)
                    .onChange(of: customText) { _, new in model = new.nilIfEmpty }
            }
        }
        // A model set on a previous visit that isn't in the preset list is a custom one —
        // reopening the screen has to show it as such rather than snapping to Default.
        .onAppear {
            guard let model, !vendor.presetModels.contains(model) else { return }
            isCustom = true
            customText = model
        }
        .onChange(of: vendor) { _, _ in
            // Presets are per-vendor, so a model chosen for the last one is meaningless.
            isCustom = false
            customText = ""
            model = nil
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if isCustom { return Self.customTag }
                return model.flatMap { vendor.presetModels.contains($0) ? $0 : nil } ?? Self.defaultTag
            },
            set: { choice in
                switch choice {
                case Self.defaultTag:
                    isCustom = false
                    model = nil
                case Self.customTag:
                    isCustom = true
                    model = customText.nilIfEmpty
                    customFocused = true
                default:
                    isCustom = false
                    model = choice
                }
            }
        )
    }
}
