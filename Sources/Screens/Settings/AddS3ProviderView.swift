import SwiftUI

struct AddS3ProviderView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucket = ""
    @State private var keyPrefix = S3Provider.defaultKeyPrefix
    @State private var isValidating = false
    @State private var validationError: String?

    private static let setupGuideURL = URL(string: "https://github.com/solomonxie/bring-your-own-podcasts/blob/main/docs/guides/s3-bucket-setup.md")!

    var body: some View {
        NavigationStack {
            Form {
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
                // Scans the bucket right away so the new source isn't empty until the
                // next scheduled/manual sync.
                _ = try? await SyncEngine().sync(providerRecord: record)
            }
            dismiss()
        } catch {
            validationError = describeAWSError(error)
        }
    }
}
