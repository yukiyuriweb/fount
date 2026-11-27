import AppKit

@MainActor
final class GitHubSyncController {
    private let store: Store
    private let github = GitHubSync()
    private var operation: Task<Void, Never>?

    init(store: Store) {
        self.store = store
    }

    func show(in window: NSWindow) {
        guard operation == nil else { return }
        do {
            guard let credential = try GitHubCredentialStore.load() else {
                connect(in: window)
                return
            }
            let gist = savedGist(for: credential.account)
            let alert = NSAlert()
            alert.messageText = String(localized: "GitHub Sync")
            alert.informativeText = String(localized: "Connected to GitHub as \(credential.account.login). Sync uploads your feeds, article list, read status, and reading activity summary to a secret Gist. Anyone with its URL can read it.")
            alert.addButton(withTitle: String(localized: "Sync Now"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Disconnect"))
            if gist != nil {
                alert.addButton(withTitle: String(localized: "Copy Gist URL"))
            }

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                sync(credential, gist: gist)
            case .alertThirdButtonReturn:
                try GitHubCredentialStore.remove()
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                if let gist { copy(gist.htmlUrl.absoluteString) }
            default: break
            }
        } catch {
            showError(error)
        }
    }

    private func connect(in window: NSWindow) {
        operation = Task { [self] in
            defer { operation = nil }
            do {
                let code = try await github.requestCode()
                let alert = NSAlert()
                alert.messageText = String(localized: "Connect to GitHub")
                alert.informativeText = String(localized: "Enter this code in your browser and authorize Fount to write to Gists.")
                let field = NSTextField(labelWithString: code.userCode)
                field.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
                field.isSelectable = true
                field.sizeToFit()
                alert.accessoryView = field
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.operation?.cancel() }
                }
                let credential: GitHubSync.Credential
                do {
                    NSWorkspace.shared.open(GitHubSync.verificationURL)
                    credential = try await github.authorize(code)
                    try Task.checkCancellation()
                    try GitHubCredentialStore.save(credential)
                } catch {
                    if alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
                    throw error
                }

                if alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
                NSApp.activate(ignoringOtherApps: true)
                let connected = NSAlert()
                connected.messageText = String(localized: "Connected to GitHub")
                connected.informativeText = String(localized: "Signed in as \(credential.account.login). Open GitHub Sync again to upload your data.")
                connected.runModal()
            } catch {
                if !Task.isCancelled { showError(error) }
            }
        }
    }

    private func sync(_ credential: GitHubSync.Credential, gist: GitHubSync.Gist?) {
        let feeds = store.feeds
        let articles = store.articles
        operation = Task {
            defer { operation = nil }
            do {
                let content = try await Task.detached(priority: .utility) {
                    try SyncSnapshot.encode(feeds: feeds, articles: articles)
                }.value
                let result = try await upload(content, credential: credential, gistID: gist?.id)
                UserDefaults.standard.set(try JSONEncoder().encode(result), forKey: gistKey(for: credential.account))

                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = String(localized: "Fount synced to GitHub")
                alert.informativeText = String(localized: "Copy the Gist URL to use on Android.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.addButton(withTitle: String(localized: "Copy Gist URL"))
                if alert.runModal() == .alertSecondButtonReturn { copy(result.htmlUrl.absoluteString) }
            } catch {
                showError(error)
            }
        }
    }

    private func upload(_ content: String, credential: GitHubSync.Credential, gistID: String?) async throws -> GitHubSync.Gist {
        let expiresSoon = credential.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false
        if !expiresSoon {
            do {
                return try await github.upload(content, gistID: gistID, credential: credential)
            } catch GitHubSync.SyncError.http(401) {
                // A rejected request has not written anything, so it is safe to retry after refreshing.
            }
        }
        let refreshed = try await github.refresh(credential)
        try GitHubCredentialStore.save(refreshed)
        do {
            return try await github.upload(content, gistID: gistID, credential: refreshed)
        } catch GitHubSync.SyncError.http(401) {
            throw GitHubSync.SyncError.reconnect
        }
    }

    private func gistKey(for account: GitHubSync.Account) -> String { "githubSyncGist.\(account.id)" }

    private func savedGist(for account: GitHubSync.Account) -> GitHubSync.Gist? {
        guard let data = UserDefaults.standard.data(forKey: gistKey(for: account)) else { return nil }
        return try? JSONDecoder().decode(GitHubSync.Gist.self, from: data)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
