import SwiftUI

struct AddS3ProviderView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucket = ""
    @State private var endpoint = ""
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
                    TextField("Access Key ID", text: $accessKeyId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Secret Access Key", text: $secretAccessKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Endpoint") {
                    TextField("Endpoint (leave blank for AWS S3)", text: $endpoint)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Only needed for S3-compatible services, e.g. https://minio.example.com.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Key Prefix") {
                    TextField("Key prefix", text: $keyPrefix)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Only files under this path in the bucket are used. Region is detected automatically for AWS S3.")
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
                    Text("Works with AWS S3 and S3-compatible services: MinIO, Cloudflare R2, Backblaze B2, Wasabi, DigitalOcean Spaces, and others.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // Region auto-detection relies on AWS's virtual-hosted endpoint, so it only
            // works for real AWS S3; S3-compatible services sign with a fallback region instead.
            let region = endpoint.isEmpty
                ? try await S3Provider.detectRegion(bucket: bucket)
                : S3Provider.fallbackRegion

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
                    "endpoint": endpoint,
                ]
            )

            let provider = try S3Provider(config: config)
            let result = await provider.testConnection()
            guard result.isSuccess else {
                validationError = result.message ?? "Could not connect to this bucket."
                return
            }
            viewModel.addS3Provider(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                region: region,
                bucket: bucket,
                keyPrefix: keyPrefix,
                endpoint: endpoint
            )
            dismiss()
        } catch {
            validationError = describeAWSError(error)
        }
    }
}
