import SwiftUI

struct AddS3ProviderView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucket = ""
    @State private var keyPrefix = ""
    @State private var pastedBlock = ""
    @State private var isPasting = false
    @State private var isValidating = false
    @State private var validationError: String?

    private static let setupGuideURL = URL(string: "https://github.com/solomonxie/ear-to-listen-podcasts/blob/main/docs/guides/s3-bucket-setup.md")!

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
                Section {
                    if isPasting {
                        TextEditor(text: $pastedBlock)
                            .font(.footnote.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: 96)
                            .overlay(alignment: .topLeading) {
                                if pastedBlock.isEmpty {
                                    Text("bucket: my-bucket\nfolder: podcasts/\naccess_key_id: AKIA…\nsecret_access_key: …")
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                        Text("`:` or `=`, any spelling of the key names. Fills the fields as you paste. Region is still detected automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Bucket name", text: $bucket)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Folder path (e.g. podcasts/)", text: $keyPrefix)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Access Key ID", text: $accessKeyId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Secret Access Key", text: $secretAccessKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Only files under this folder in the bucket are used. Leave it empty for the whole bucket — a trailing / is added for you. Region is detected automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("S3 Bucket")
                        Button(isPasting ? "(back to fields)" : "(paste info to add)") {
                            pastedBlock = ""
                            isPasting.toggle()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .textCase(nil)
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
            .onChange(of: pastedBlock) { previous, text in
                let draft = S3ConnectionDraft.parse(text)
                guard !draft.isEmpty else { return }
                apply(draft)
                // Only a real paste snaps back to the filled fields; typing by hand keeps
                // the box open so the next line can still be entered.
                guard text.count - previous.count > 1 else { return }
                pastedBlock = ""
                isPasting = false
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

    /// Only overwrites what the block actually named, so a half-filled paste doesn't wipe
    /// a field that was typed in by hand.
    private func apply(_ draft: S3ConnectionDraft) {
        validationError = nil
        if let value = draft.bucket { bucket = value }
        if let value = draft.keyPrefix { keyPrefix = value }
        if let value = draft.accessKeyId { accessKeyId = value }
        if let value = draft.secretAccessKey { secretAccessKey = value }
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
        // Folders only, always slash-terminated — a bare `pod` would otherwise also match
        // `podcasts-old/`, quietly syncing a folder nobody picked.
        let keyPrefix = S3FolderPath.normalized(keyPrefix) ?? ""

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
