import SwiftUI

/// Half-height sheet, not a full page — a vendor picker and one text field don't need
/// more room. No separate "Test Connection" button: Save itself sends one real, cheap
/// request through the chosen vendor's client and only persists the key once that
/// succeeds, same flow as adding an S3 connection tests the bucket first.
struct AddAiKeyView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var vendor: AiVendor = .openAI
    @State private var model: String?
    @State private var openPicker: String?
    @State private var secret = ""
    @State private var isTesting = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    UnfoldingPicker(
                        title: "Vendor", id: "vendor", open: $openPicker, selection: $vendor,
                        options: AiVendor.allCases.map { UnfoldingPicker.Option($0, $0.displayName) }
                    )
                    AiModelPicker(vendor: vendor, model: $model, id: "model", open: $openPicker)
                    SecureField(vendor.keyHint, text: $secret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    // Linked rather than just named, so adding a key doesn't require
                    // already knowing where that vendor's console lives.
                    HStack(spacing: 4) {
                        Text("Don't have a \(vendor.displayName) key yet?")
                        Link("Get one →", destination: vendor.docsURL)
                    }
                    .font(.footnote)
                }

                if isTesting {
                    Label("Testing the key…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let validationError {
                    Label(validationError, systemImage: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Section {
                    Text("Stored only in this device's Keychain — we never see it or send it anywhere ourselves, it's used solely for direct requests from your device to \(vendor.displayName).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add AI Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isTesting || secret.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        isTesting = true
        validationError = nil
        defer { isTesting = false }
        do {
            try await viewModel.addAiKey(
                vendor: vendor, model: model, secret: secret.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            validationError = "Could not connect: \(error.localizedDescription)"
        }
    }
}
