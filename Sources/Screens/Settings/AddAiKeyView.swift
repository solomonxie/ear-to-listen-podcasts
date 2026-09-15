import SwiftUI

/// No separate "Test Connection" button — Save itself sends one real, cheap request
/// through the chosen vendor's client and only persists the key once that succeeds,
/// same flow as adding an S3 connection tests the bucket first.
struct AddAiKeyView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var vendor: AiVendor = .openAI
    @State private var secret = ""
    @State private var isTesting = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Vendor") {
                    Picker("Vendor", selection: $vendor) {
                        ForEach(AiVendor.allCases, id: \.self) { vendor in
                            Text(vendor.displayName).tag(vendor)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("API Key") {
                    SecureField(vendor == .openAI ? "sk-…" : "sk-ant-…", text: $secret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if let validationError {
                    Section {
                        Label(validationError, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
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
                    if isTesting {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(secret.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        isTesting = true
        validationError = nil
        defer { isTesting = false }
        do {
            try await viewModel.addAiKey(vendor: vendor, secret: secret.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
