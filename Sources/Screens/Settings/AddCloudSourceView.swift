import SwiftUI

/// Connecting a bucket, in whichever cloud it lives in.
///
/// One screen for all five, because the differences are small and named in
/// `CloudSourceKind`: what the credential's two halves are called, whether the region is
/// detected or picked, and — for Google — that the credential is a pasted JSON key rather
/// than a pair of strings. Save is the test: nothing is stored until a real listing comes
/// back from the bucket.
struct AddCloudSourceView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var kind: CloudSourceKind = .amazonS3
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var serviceAccountJson = ""
    @State private var bucket = ""
    @State private var keyPrefix = ""
    @State private var region = ""
    @State private var openPicker: String?
    @State private var pastedBlock = ""
    @State private var isPasting = false
    @State private var isValidating = false
    @State private var validationError: String?

    private static let setupGuideURL = URL(string: "https://github.com/solomonxie/ear-to-listen-podcasts/blob/main/docs/guides/s3-bucket-setup.md")!

    /// Only connections to the same cloud — a COS SecretId doesn't prefill an Azure form.
    private var sameKindProviders: [ProviderRecord] {
        viewModel.providers.filter { $0.cloudKind == kind }
    }

    private var canSave: Bool {
        guard !bucket.isEmpty else { return false }
        switch kind.credential {
        case .keyPair:
            // A region is only ever required where one is picked: AWS detects it, and
            // Azure doesn't have one to give.
            return !accessKeyId.isEmpty && !secretAccessKey.isEmpty
                && (kind.regions.isEmpty || !region.isEmpty)
        case .serviceAccountJSON:
            return !serviceAccountJson.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    UnfoldingPicker(
                        title: "Cloud", id: "cloud", open: $openPicker, selection: $kind,
                        options: CloudSourceKind.allCases.map { UnfoldingPicker.Option($0, $0.name) }
                    )
                }
                if !sameKindProviders.isEmpty {
                    Section("Fill from an existing connection") {
                        ForEach(sameKindProviders) { record in
                            Button {
                                fillDraft(from: record)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.label)
                                    if let path = ProviderManager.shared.displayPath(for: record) {
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
                        pasteBox
                    } else {
                        fields
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(kind.name)
                        if case .keyPair = kind.credential {
                            Button(isPasting ? "(back to fields)" : "(paste info to add)") {
                                pastedBlock = ""
                                isPasting.toggle()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
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
                    Text(credentialTip)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if kind == .amazonS3 {
                    Section {
                        Link("How to create a bucket and set permissions", destination: Self.setupGuideURL)
                            .font(.footnote)
                    }
                }
            }
            .onChange(of: kind) { _, _ in
                validationError = nil
                isPasting = false
                // A region from the cloud that was selected a moment ago isn't one this
                // cloud has ever heard of.
                if !kind.regions.contains(region) { region = kind.regions.first ?? "" }
            }
            .onChange(of: pastedBlock) { previous, text in
                guard applyPaste(text) else { return }
                // Only a real paste snaps back to the filled fields; typing by hand keeps
                // the box open so the next line can still be entered.
                guard text.count - previous.count > 1 else { return }
                pastedBlock = ""
                isPasting = false
            }
            .navigationTitle("Add Cloud Storage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isValidating {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await validateAndSave() } }
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        TextField("\(kind.containerLabel) name", text: $bucket)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        TextField("Folder path (e.g. podcasts/)", text: $keyPrefix)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        if !kind.regions.isEmpty {
            UnfoldingPicker(
                title: "Region", id: "region", open: $openPicker, selection: $region,
                options: kind.regions.map { UnfoldingPicker.Option($0, $0) }
            )
        }
        switch kind.credential {
        case .keyPair(let idLabel, let secretLabel):
            TextField(idLabel, text: $accessKeyId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField(secretLabel, text: $secretAccessKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .serviceAccountJSON:
            editor(text: $serviceAccountJson, placeholder: "{\n  \"type\": \"service_account\",\n  \"client_email\": \"…\",\n  \"private_key\": \"-----BEGIN PRIVATE KEY-----…\"\n}")
        }
        Text(folderHint)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pasteBox: some View {
        editor(text: $pastedBlock, placeholder: pastePlaceholder)
        Text(pasteHint)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func editor(text: Binding<String>, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(.footnote.monospaced())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minHeight: 96)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Copy

    private var folderHint: String {
        let base = "Only files under this folder in the \(kind.containerLabel.lowercased()) are used. Leave it empty for the whole \(kind.containerLabel.lowercased()) — a trailing / is added for you."
        return kind.detectsRegion ? base + " Region is detected automatically." : base
    }

    private var pastePlaceholder: String {
        switch kind {
        case .azureBlob:
            "DefaultEndpointsProtocol=https;AccountName=…;AccountKey=…"
        default:
            "\(kind.containerLabel.lowercased()): my-\(kind.containerLabel.lowercased())\nfolder: podcasts/\naccess_key_id: …\nsecret_access_key: …"
        }
    }

    private var pasteHint: String {
        switch kind {
        case .azureBlob:
            "The connection string from the portal, as it is — or `key: value` lines. Fills the fields as you paste."
        default:
            "`:` or `=`, any spelling of the key names. Fills the fields as you paste."
        }
    }

    /// Whichever narrower credential this cloud can issue — the app only ever reads
    /// episodes and writes its own two files, so nothing here needs an account-wide key.
    private var credentialTip: String {
        switch kind {
        case .amazonS3:
            "Tip: create an IAM user scoped to read-only access on this bucket rather than reusing your main AWS credentials."
        case .tencentCos:
            "Tip: create a CAM sub-account scoped to this bucket rather than reusing your root account's SecretId."
        case .aliyunOss:
            "Tip: create a RAM user scoped to this bucket rather than reusing your main AccessKey."
        case .azureBlob:
            "Tip: an account key opens the whole storage account, so keep podcasts in a storage account of their own."
        case .googleCloudStorage:
            "Tip: give the service account Storage Object Viewer on this bucket alone rather than a project-wide role."
        }
    }

    // MARK: Filling in

    /// Only overwrites what the pasted text actually named, so a half-filled paste doesn't
    /// wipe a field that was typed in by hand. `false` when there was nothing to take.
    @discardableResult
    private func applyPaste(_ text: String) -> Bool {
        // Azure hands out one `;`-joined string rather than lines; it's what's on the
        // clipboard, so it's what the box accepts.
        if kind == .azureBlob, let account = AzureConnectionString.parse(text) {
            validationError = nil
            accessKeyId = account.accountName
            secretAccessKey = account.accountKey
            return true
        }
        let draft = BucketConnectionDraft.parse(text)
        guard !draft.isEmpty else { return false }
        validationError = nil
        if let value = draft.bucket { bucket = value }
        if let value = draft.keyPrefix { keyPrefix = value }
        if let value = draft.accessKeyId { accessKeyId = value }
        if let value = draft.secretAccessKey { secretAccessKey = value }
        if let value = draft.region, kind.regions.contains(value) { region = value }
        return true
    }

    /// Copies another connection's fields in as a starting point — e.g. the same bucket
    /// and credentials with just the folder tweaked, rather than retyping everything.
    private func fillDraft(from record: ProviderRecord) {
        guard let settings = ProviderManager.shared.bucketSettings(for: record) else { return }
        validationError = nil
        accessKeyId = settings["accessKeyId"] ?? accessKeyId
        secretAccessKey = settings["secretAccessKey"] ?? secretAccessKey
        serviceAccountJson = settings["serviceAccountJson"] ?? serviceAccountJson
        bucket = settings["bucket"] ?? bucket
        keyPrefix = settings["keyPrefix"] ?? keyPrefix
        region = settings["region"] ?? region
    }

    // MARK: Saving

    private func validateAndSave() async {
        isValidating = true
        validationError = nil
        defer { isValidating = false }

        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        // Folders only, always slash-terminated — a bare `pod` would otherwise also match
        // `podcasts-old/`, quietly syncing a folder nobody picked.
        let keyPrefix = CloudFolderPath.normalized(keyPrefix) ?? ""

        do {
            var settings = ["bucket": bucket, "keyPrefix": keyPrefix]
            switch kind.credential {
            case .keyPair:
                settings["accessKeyId"] = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
                settings["secretAccessKey"] = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if kind.speaksS3 {
                    settings["region"] = kind.detectsRegion
                        ? try await S3Provider.detectRegion(bucket: bucket)
                        : region
                }
            case .serviceAccountJSON:
                settings["serviceAccountJson"] = serviceAccountJson.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let config = CloudProviderConfig(
                id: UUID().uuidString, type: kind.providerType, label: bucket, settings: settings
            )
            guard let provider = try CloudProviderRegistry.shared.makeProvider(for: config) else {
                validationError = "This app doesn't know how to talk to \(kind.name)."
                return
            }
            let result = await provider.testConnection()
            guard result.isSuccess else {
                validationError = result.message ?? "Could not connect to this \(kind.containerLabel.lowercased())."
                return
            }
            if let record = viewModel.addCloudProvider(kind: kind, label: bucket, settings: settings) {
                // Queues the whole bucket instead of a single opaque background sync, so
                // progress (and any per-file errors) show up in the sync queue right away
                // rather than only after everything finishes.
                Task { await SyncQueueManager.shared.enqueueConnection(providerID: record.id) }
            }
            dismiss()
        } catch {
            validationError = describeCloudError(error)
        }
    }
}
