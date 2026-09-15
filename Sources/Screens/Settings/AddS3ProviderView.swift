import SwiftUI

struct AddS3ProviderView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucket = ""
    @State private var keyPrefix = ""
    @State private var isValidating = false
    @State private var validationError: String?

    private static let setupGuideURL = URL(string: "https://github.com/solomonxie/bring-your-own-podcasts/blob/main/docs/guides/s3-bucket-setup.md")!

    private var existingS3Providers: [ProviderRecord] {
        viewModel.providers.filter { $0.type == S3Provider.providerType }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !existingS3Providers.isEmpty {
                    Section("Fill from an existing connection") {
                        ForEach(existingS3Providers) { record in
                            Button {
                                fillDraft(from: record)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.label)
                                    if let path = ProviderManager.shared.s3DisplayPath(for: record) {
                                        Text(path).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section("S3 Bucket") {
                    TextField("Bucket name", text: $bucket)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Folder (key prefix)", text: $keyPrefix)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Access Key ID", text: $accessKeyId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Secret Access Key", text: $secretAccessKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Only files under this folder in the bucket are used. Region is detected automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                Section {
                    Link("How to create a bucket and set permissions", destination: Self.setupGuideURL)
                        .font(.footnote)
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
                            .disabled(accessKeyId.isEmpty || secretAccessKey.isEmpty || bucket.isEmpty)
                    }
                }
            }
        }
    }

    /// Copies another connection's fields in as a starting point — e.g. the same bucket
    /// and credentials with just the prefix tweaked, rather than retyping everything.
    private func fillDraft(from record: ProviderRecord) {
        guard let settings = ProviderManager.shared.s3Settings(for: record) else { return }
        validationError = nil
        accessKeyId = settings["accessKeyId"] ?? accessKeyId
        secretAccessKey = settings["secretAccessKey"] ?? secretAccessKey
        bucket = settings["bucket"] ?? bucket
        keyPrefix = settings["keyPrefix"] ?? keyPrefix
    }

    private func validateAndSave() async {
        isValidating = true
        validationError = nil
        defer { isValidating = false }

        let accessKeyId = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let region = try await S3Provider.detectRegion(bucket: bucket)

            let config = CloudProviderConfig(
                id: UUID().uuidString,
                type: S3Provider.providerType,
                label: bucket,
                settings: [
                    "accessKeyId": accessKeyId,
                    "secretAccessKey": secretAccessKey,
                    "region": region,
                    "bucket": bucket,
                    "keyPrefix": keyPrefix,
                ]
            )

            let provider = try S3Provider(config: config)
            let result = await provider.testConnection()
            guard result.isSuccess else {
                validationError = result.message ?? "Could not connect to this bucket."
                return
            }
            if let record = viewModel.addS3Provider(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                region: region,
                bucket: bucket,
                keyPrefix: keyPrefix
            ) {
                // Queues the whole bucket instead of a single opaque background sync, so
                // progress (and any per-file errors) show up in the sync queue right away
                // rather than only after everything finishes.
                Task { await SyncQueueManager.shared.enqueueConnection(providerID: record.id) }
            }
            dismiss()
        } catch {
            validationError = describeAWSError(error)
        }
    }
}
