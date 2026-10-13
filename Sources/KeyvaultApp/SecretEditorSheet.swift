import KeyvaultCore
import SwiftUI

struct SecretEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: VaultModel
    let entry: VaultEntry?
    @State private var vaultName: String
    @State private var secretName: String
    @State private var secretValue = ""
    @State private var saveFeedback = SecretEditorSaveFeedback()

    init(model: VaultModel, entry: VaultEntry?) {
        self.model = model
        self.entry = entry
        _vaultName = State(initialValue: entry?.vault ?? "")
        _secretName = State(initialValue: entry?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry == nil ? "Add secret" : "Edit secret")
                    .font(.title2.weight(.semibold))
                Text("Stored in this Mac's login Keychain")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                TextField("Vault", text: $vaultName)
                    .disabled(entry != nil)
                TextField("Name", text: $secretName)
                    .disabled(entry != nil)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Secret").font(.subheadline.weight(.medium))
                    TextEditor(text: $secretValue)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                }
            }
            if let inlineError = saveFeedback.inlineError {
                Label(inlineError, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("secret-save-error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Save Secret" : "Save Changes", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear(perform: loadExistingSecret)
    }

    private func loadExistingSecret() {
        guard let entry else { return }
        Task {
            if let value = await model.reveal(entry) { secretValue = value }
        }
    }

    private func save() {
        let outcome = model.save(Data(secretValue.utf8), vaultName: vaultName, secretName: secretName)
        if saveFeedback.apply(outcome) {
            dismiss()
        }
    }
}
