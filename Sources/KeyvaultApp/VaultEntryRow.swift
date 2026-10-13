import KeyvaultCore
import SwiftUI

struct VaultEntryRow: View {
    let entry: VaultEntry
    @ObservedObject var model: VaultModel
    let edit: () -> Void
    @State private var revealedValue: String?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.body.weight(.medium))
                if let revealedValue {
                    Text(revealedValue.isEmpty ? "(empty secret)" : revealedValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                } else {
                    Text(entry.address).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button {
                if revealedValue != nil {
                    revealedValue = nil
                } else {
                    Task { revealedValue = await model.reveal(entry) }
                }
            } label: {
                Image(systemName: revealedValue == nil ? "eye" : "eye.slash")
            }
            .help(revealedValue == nil ? "Reveal secret" : "Hide secret")
            .buttonStyle(.borderless)
            Button { Task { await model.copy(entry) } } label: { Image(systemName: "doc.on.doc") }
                .help("Copy secret")
                .buttonStyle(.borderless)
            Button(action: edit) { Image(systemName: "pencil") }
                .help("Edit secret")
                .buttonStyle(.borderless)
            Button { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Delete secret")
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .confirmationDialog("Delete \(entry.address)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Secret", role: .destructive) { model.delete(entry) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the secret from this Mac's Keychain.")
        }
    }
}
