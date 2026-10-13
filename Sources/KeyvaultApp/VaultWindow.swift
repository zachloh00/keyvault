import KeyvaultCore
import SwiftUI

private struct EditorRequest: Identifiable {
    let id = UUID()
    let entry: VaultEntry?
}

struct VaultWindow: View {
    @ObservedObject var model: VaultModel
    @State private var searchText = ""
    @State private var editorRequest: EditorRequest?

    private var groupedEntries: [(vault: String, entries: [VaultEntry])] {
        let filtered = model.entries.filter {
            searchText.isEmpty || $0.address.localizedCaseInsensitiveContains(searchText)
        }
        return Dictionary(grouping: filtered, by: \.vault)
            .map { (vault: $0.key, entries: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.vault.localizedStandardCompare($1.vault) == .orderedAscending }
    }

    var body: some View {
        Group {
            if model.isUnlocked {
                mainContent
            } else {
                lockedContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if !model.isUnlocked { await model.unlock() } }
        .sheet(item: $editorRequest) { request in
            SecretEditorSheet(model: model, entry: request.entry)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search secrets", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            if groupedEntries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groupedEntries, id: \.vault) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                VaultEntryRow(entry: entry, model: model) {
                                    editorRequest = EditorRequest(entry: entry)
                                }
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            HStack {
                                Image(systemName: "folder")
                                Text(group.vault)
                            }
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editorRequest = EditorRequest(entry: nil) } label: {
                    Label("Add Secret", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Keyvault").font(.title2.weight(.semibold))
                Text("Local secrets for this Mac").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Lock") { model.lock() }
                .help("Lock the Keyvault window")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "key.horizontal" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "Your vault is ready" : "No matching secrets")
                .font(.title3.weight(.medium))
            Text(searchText.isEmpty ? "Add a secret to get started." : "Try a different name or vault.")
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Button("Add your first secret") { editorRequest = EditorRequest(entry: nil) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Keyvault is locked").font(.title2.weight(.semibold))
            Text("Authenticate to manage secrets on this Mac.")
                .foregroundStyle(.secondary)
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button("Unlock") { Task { await model.unlock() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
