import SwiftUI
import UniformTypeIdentifiers

/// Export/import of passphrase-encrypted backups. Everything is explicit and
/// user-held: the app never writes a backup anywhere on its own.
struct BackupView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var settings: AppSettings

    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var exportedFileURL: URL?
    @State private var showImporter = false
    @State private var pendingImportData: Data?
    @State private var feedback: Feedback?

    private struct Feedback: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase", text: $passphrase)
                SecureField("Confirm passphrase", text: $passphraseConfirm)
            } header: {
                Text("Passphrase")
            } footer: {
                Text("Used to encrypt exports and decrypt imports. It is never stored — forget it and the backup file is unreadable, permanently.")
            }

            Section {
                Button {
                    exportBackup()
                } label: {
                    Label("Export encrypted backup", systemImage: "square.and.arrow.up")
                }
                .disabled(!passphraseUsable)
                if let url = exportedFileURL {
                    ShareLink(item: url) {
                        Label("Share \(url.lastPathComponent)", systemImage: "doc.badge.arrow.up")
                    }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Contains your rooms, room keys, members, messages and identity. Treat the file like a house key: anyone holding it plus the passphrase can join your rooms as you.")
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import backup file", systemImage: "square.and.arrow.down")
                }
                .disabled(passphrase.isEmpty)
            } header: {
                Text("Restore")
            } footer: {
                Text("Rooms you don't already have are added; messages merge in. On a fresh install your identity is restored too. Nothing existing is deleted.")
            }
        }
        .navigationTitle("Back up & restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert(item: $feedback) { feedback in
            Alert(title: Text(feedback.title),
                  message: Text(feedback.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var passphraseUsable: Bool {
        !passphrase.isEmpty && passphrase == passphraseConfirm
    }

    private func exportBackup() {
        do {
            let payload = BackupService.gather(engine: engine, settings: settings)
            let data = try BackupService.encrypt(payload, passphrase: passphrase)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(BackupService.suggestedFileName())
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportedFileURL = url
            feedback = Feedback(title: "Backup ready",
                                message: "\(payload.rooms.count) rooms and \(payload.messages.count) messages encrypted. Use the share button to save it to Files, AirDrop it, or store it anywhere you trust.")
        } catch {
            feedback = Feedback(title: "Export failed",
                                message: error.localizedDescription)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        // Security-scoped access is required for files picked from
        // outside our sandbox (Files app, iCloud Drive).
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let payload = try BackupService.decrypt(data, passphrase: passphrase)
            let summary = BackupService.restore(payload, engine: engine, settings: settings)
            feedback = Feedback(title: "Backup restored", message: summary)
        } catch {
            feedback = Feedback(title: "Import failed",
                                message: (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
        }
    }
}
