import AppKit
import WriteOnAI

@MainActor
final class UpdateController: NSObject {
    private let service: AppUpdateService
    private let privateReleasesURL: URL?
    private var checking = false

    init(repository: String?, installedVersion: String, privateChannel: Bool = false) {
        service = AppUpdateService(repository: repository, installedVersion: installedVersion)
        if privateChannel, let repository,
           repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
           repository.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) {
            privateReleasesURL = URL(string: "https://github.com/\(repository)/releases/latest")
        } else {
            privateReleasesURL = nil
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard !checking else { return }
        if let privateReleasesURL {
            let alert = NSAlert()
            alert.messageText = "Check for updates on GitHub"
            alert.informativeText = "DansWriter will open the private release page in your browser, where GitHub can use your existing sign-in. Download the update DMG there, then quit DansWriter and replace the app from the DMG. Your writing files are stored separately and will be preserved."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, !NSWorkspace.shared.open(privateReleasesURL) {
                showMessage("Could not open GitHub", "DansWriter could not open your browser. Open the GitHub release page for this repository in your browser to check for updates.")
            }
            return
        }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            defer { checking = false }
            do {
                switch try await service.check() {
                case .unavailable:
                    showMessage("Update checks are unavailable", "This build does not have an update repository configured.")
                case .current:
                    showMessage("DansWriter is up to date", "No newer stable version is available.")
                case .noPublishedReleases:
                    showMessage("No published releases", "This repository does not have a published release yet.")
                case .update(let release):
                    offerDownload(release)
                }
            } catch {
                showMessage("Could not check for updates", error.localizedDescription)
            }
        }
    }

    private func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func offerDownload(_ release: AppUpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "DansWriter \(release.version) is available"
        alert.informativeText = "Download the update DMG? After it downloads, quit DansWriter and replace the app from the DMG. Your writing files are stored separately and will be preserved."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard NSWorkspace.shared.open(release.downloadURL) else {
            showMessage("Could not open the download", "DansWriter could not open your browser. Visit the GitHub release page to download the update DMG.")
            return
        }
    }
}
