import SwiftUI

struct AddS3ProviderView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var region = "us-east-1"
    @State private var bucket = ""
    @State private var isValidating = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("S3 Bucket") {
                    TextField("Label (e.g. My Music)", text: $label)
                    TextField("Access Key ID", text: $accessKeyId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Secret Access Key", text: $secretAccessKey)
                    TextField("Region (e.g. us-east-1)", text: $region)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Bucket name", text: $bucket)
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
                    Text("Tip: create an IAM user scoped to read-only access on this bucket rather than reusing your main AWS credentials.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add S3 Bucket")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isValidating {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await validateAndSave() } }
                            .disabled(accessKeyId.isEmpty || secretAccessKey.isEmpty || region.isEmpty || bucket.isEmpty)
                    }
                }
            }
        }
    }

    private func validateAndSave() async {
        isValidating = true
        validationError = nil
        defer { isValidating = false }

        let config = CloudProviderConfig(
            id: UUID().uuidString,
            type: S3Provider.providerType,
            label: label.isEmpty ? bucket : label,
            settings: [
                "accessKeyId": accessKeyId,
                "secretAccessKey": secretAccessKey,
                "region": region,
                "bucket": bucket,
            ]
        )

        do {
            let provider = try S3Provider(config: config)
            let result = await provider.testConnection()
            guard result.isSuccess else {
                validationError = result.message ?? "Could not connect to this bucket."
                return
            }
            viewModel.addS3Provider(
                label: label,
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                region: region,
                bucket: bucket
            )
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
