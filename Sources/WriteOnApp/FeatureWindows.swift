import AppKit
import WriteOnCore
import WriteOnAI

typealias DraftRange = WriteOnCore.TextRange

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private var configuration = AIConfiguration.load()
    private var displayedProvider: AIProvider = .codex
    private var providerProfiles: [String: [String: String]] = UserDefaults.standard.dictionary(forKey: "WriteOn.ai.providerProfiles") as? [String: [String: String]] ?? [:]
    private var theme: WriteOnTheme
    private let provider = NSPopUpButton()
    private let connection = NSPopUpButton()
    private let model = NSTextField(string: "")
    private let modelHint = NSTextField(labelWithString: "")
    private let executable = NSTextField(string: "")
    private let key = NSSecureTextField(string: "")
    private let keyStatus = NSTextField(labelWithString: "")
    private let sound = NSButton(checkboxWithTitle: "Play subtle tones when moving between alternatives", target: nil, action: nil)
    private let typewriterSound = NSButton(checkboxWithTitle: "Typewriter sounds", target: nil, action: nil)
    private let appearance = NSPopUpButton()
    private let onTheme: (WriteOnTheme) -> Void
    private let onTypewriterSound: (Bool) -> Void

    init(initialTheme: WriteOnTheme, onTheme: @escaping (WriteOnTheme) -> Void, onTypewriterSound: @escaping (Bool) -> Void) {
        theme = initialTheme; self.onTheme = onTheme; self.onTypewriterSound = onTypewriterSound
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        switch theme { case .system: window.appearance = nil; case .dark: window.appearance = NSAppearance(named: .darkAqua); case .light: window.appearance = NSAppearance(named: .aqua) }
        window.title = "DansWriter Settings"; window.center(); window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }
    required init?(coder: NSCoder) { nil }

    private func build() {
        guard let content = window?.contentView else { return }
        let palette = Palette.current(window?.effectiveAppearance)
        content.wantsLayer = true; content.layer?.backgroundColor = palette.canvas.cgColor
        provider.addItems(withTitles: AIProvider.allCases.map { $0 == .codex ? "Codex" : "Claude" })
        provider.target = self; provider.action = #selector(providerChanged)
        connection.addItems(withTitles: AIConnection.allCases.map { $0 == .subscription ? "Subscription" : "API key" })
        connection.target = self; connection.action = #selector(connectionChanged)
        appearance.addItems(withTitles: WriteOnTheme.allCases.map(\.rawValue))
        provider.selectItem(at: AIProvider.allCases.firstIndex(of: configuration.provider) ?? 0)
        displayedProvider = configuration.provider
        if providerProfiles[configuration.provider.rawValue] == nil {
            providerProfiles[configuration.provider.rawValue] = ["model": configuration.model, "executable": configuration.executablePath, "connection": configuration.connection.rawValue]
        }
        connection.selectItem(at: AIConnection.allCases.firstIndex(of: configuration.connection) ?? 0)
        appearance.selectItem(at: WriteOnTheme.allCases.firstIndex(of: theme) ?? 0)
        model.stringValue = configuration.model; executable.stringValue = configuration.executablePath
        model.delegate = self
        executable.placeholderString = "Optional command-line executable path"
        sound.state = UserDefaults.standard.bool(forKey: "WriteOn.sound") ? .on : .off
        typewriterSound.state = UserDefaults.standard.bool(forKey: "WriteOn.typewriterSound") ? .on : .off
        typewriterSound.target = self; typewriterSound.action = #selector(typewriterSoundChanged)

        let title = UIStyle.label("Settings", size: 22, color: palette.text, weight: .semibold)
        let subtitle = UIStyle.label("Choose how DansWriter reaches your writing assistant.", size: 12, color: palette.muted)
        let providerRow = fieldRow("Provider", control: provider, palette: palette)
        let connectionRow = fieldRow("Connection", control: connection, palette: palette)
        let modelRow = fieldRow("Model", control: model, palette: palette)
        modelHint.font = .systemFont(ofSize: 10)
        modelHint.textColor = palette.muted
        modelHint.maximumNumberOfLines = 2
        modelHint.usesSingleLineMode = false
        modelHint.lineBreakMode = .byWordWrapping
        modelHint.widthAnchor.constraint(equalToConstant: 450).isActive = true
        let pathRow = NSStackView(views: [executable, UIStyle.button("Choose…", action: #selector(chooseExecutable), target: self, palette: palette)])
        pathRow.orientation = .horizontal; pathRow.spacing = 7
        let cliRow = fieldRow("CLI path override", control: pathRow, palette: palette)
        let apiTitle = UIStyle.label("API KEY", size: 10, color: palette.muted, weight: .bold)
        let keyEntry = NSStackView(views: [key, UIStyle.button("Save key", action: #selector(saveKey), target: self, palette: palette)])
        keyEntry.orientation = .horizontal; keyEntry.spacing = 7
        keyStatus.font = .systemFont(ofSize: 11); keyStatus.textColor = palette.muted
        let deleteKey = UIStyle.button("Delete saved key", action: #selector(deleteKey), target: self, palette: palette)
        let keyGroup = NSStackView(views: [apiTitle, keyEntry, keyStatus, deleteKey])
        keyGroup.orientation = .vertical; keyGroup.alignment = .leading; keyGroup.spacing = 8
        let themeRow = fieldRow("Appearance", control: appearance, palette: palette)
        let stack = NSStackView(views: [title, subtitle, spacer(8), providerRow, connectionRow, modelRow, modelHint, cliRow, spacer(8), apiTitle, keyEntry, keyStatus, deleteKey, spacer(8), themeRow, sound, typewriterSound, spacer(8), UIStyle.button("Save settings", action: #selector(saveSettings), target: self, palette: palette, prominent: true)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 25)])
        [provider, connection, model, executable, appearance].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        updateKeyStatus()
        updateModelHint()
    }
    @objc private func connectionChanged() { updateModelHint() }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === model { updateModelHint() }
    }

    private func fieldRow(_ title: String, control: NSView, palette: Palette) -> NSView {
        let label = UIStyle.label(title, size: 11, color: palette.muted, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false; label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12; row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 450).isActive = true
        return row
    }

    private func spacer(_ height: CGFloat) -> NSView { let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false; v.heightAnchor.constraint(equalToConstant: height).isActive = true; return v }

    @objc private func typewriterSoundChanged() {
        let enabled = typewriterSound.state == .on
        UserDefaults.standard.set(enabled, forKey: "WriteOn.typewriterSound")
        onTypewriterSound(enabled)
    }

    private var selectedProvider: AIProvider { AIProvider.allCases[max(0, provider.indexOfSelectedItem)] }
    @objc private func providerChanged() {
        providerProfiles[displayedProvider.rawValue] = ["model": model.stringValue, "executable": executable.stringValue, "connection": AIConnection.allCases[max(0, connection.indexOfSelectedItem)].rawValue]
        key.stringValue = ""
        let next = selectedProvider
        let profile = providerProfiles[next.rawValue]
        model.stringValue = profile?["model"] ?? (next == configuration.provider ? configuration.model : "")
        executable.stringValue = profile?["executable"] ?? (next == configuration.provider ? configuration.executablePath : "")
        if let raw = profile?["connection"], let saved = AIConnection(rawValue: raw) { connection.selectItem(at: AIConnection.allCases.firstIndex(of: saved) ?? 0) }
        else if next == configuration.provider { connection.selectItem(at: AIConnection.allCases.firstIndex(of: configuration.connection) ?? 0) }
        else { connection.selectItem(at: AIConnection.allCases.firstIndex(of: .subscription) ?? 0) }
        displayedProvider = next
        updateModelHint()
        updateKeyStatus()
    }
    private func updateModelHint() {
        let selectedConnection = AIConnection.allCases[max(0, connection.indexOfSelectedItem)]
        let blankModel = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selectedProvider == .codex && selectedConnection == .subscription && blankModel {
            model.placeholderString = "Default: gpt-6-luna"
            modelHint.stringValue = "Blank model uses gpt-6-luna with low reasoning and standard service for each request."
        } else if selectedConnection == .api && blankModel {
            model.placeholderString = "Model required for API"
            modelHint.stringValue = "Enter the API model identifier above. Subscription defaults are not used in API mode."
        } else if selectedConnection == .subscription && blankModel {
            model.placeholderString = "Provider default"
            modelHint.stringValue = "Blank model keeps the provider CLI default."
        } else {
            model.placeholderString = "Model identifier from your account"
            modelHint.stringValue = "The model entered above is used for this connection."
        }
    }
    @objc private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; executable.stringValue = url.path
    }
    @objc private func saveKey() {
        guard !key.stringValue.isEmpty else { return }
        do { try KeychainStore.set(key.stringValue, for: selectedProvider); key.stringValue = ""; updateKeyStatus() }
        catch { showError("The key could not be saved", detail: "Check Keychain access and try again.") }
    }
    @objc private func deleteKey() {
        do { try KeychainStore.delete(for: selectedProvider); key.stringValue = ""; updateKeyStatus() }
        catch { showError("The key could not be deleted", detail: "Check Keychain access and try again.") }
    }
    private func updateKeyStatus() {
        do { keyStatus.stringValue = try KeychainStore.hasKey(for: selectedProvider) ? "A key is saved in Keychain." : "No saved key for this provider." }
        catch { keyStatus.stringValue = "Keychain status is unavailable." }
    }
    @objc private func saveSettings() {
        configuration.provider = selectedProvider
        configuration.connection = AIConnection.allCases[max(0, connection.indexOfSelectedItem)]
        configuration.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.executablePath = executable.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        providerProfiles[selectedProvider.rawValue] = ["model": configuration.model, "executable": configuration.executablePath, "connection": configuration.connection.rawValue]
        UserDefaults.standard.set(providerProfiles, forKey: "WriteOn.ai.providerProfiles")
        configuration.save()
        UserDefaults.standard.set(sound.state == .on, forKey: "WriteOn.sound")
        let typewriterEnabled = typewriterSound.state == .on
        UserDefaults.standard.set(typewriterEnabled, forKey: "WriteOn.typewriterSound")
        onTypewriterSound(typewriterEnabled)
        theme = WriteOnTheme.allCases[max(0, appearance.indexOfSelectedItem)]
        onTheme(theme)
        window?.close()
    }
    private func showError(_ message: String, detail: String) { let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail; alert.runModal() }

#if DEBUG
    func runDebugProviderIsolationCheck() throws {
        let oldProvider = provider.indexOfSelectedItem
        let oldConnection = connection.indexOfSelectedItem
        let oldModel = model.stringValue
        let oldExecutable = executable.stringValue
        let oldKey = key.stringValue
        let oldProfiles = providerProfiles
        defer {
            providerProfiles = oldProfiles; provider.selectItem(at: oldProvider); connection.selectItem(at: oldConnection)
            model.stringValue = oldModel; executable.stringValue = oldExecutable; key.stringValue = oldKey
            displayedProvider = selectedProvider
        }
        providerProfiles[AIProvider.claude.rawValue] = nil
        displayedProvider = .codex
        provider.selectItem(at: AIProvider.allCases.firstIndex(of: .codex) ?? 0)
        model.stringValue = "codex-self-check-model"; executable.stringValue = "/codex/self-check"; key.stringValue = "temporary-codex-key"
        provider.selectItem(at: AIProvider.allCases.firstIndex(of: .claude) ?? 1); providerChanged()
        guard model.stringValue.isEmpty, executable.stringValue.isEmpty, key.stringValue.isEmpty else {
            throw NSError(domain: "WriteOnSelfCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Provider switch leaked model, executable or unsaved key into the next provider"])
        }
        model.stringValue = "claude-self-check-model"; executable.stringValue = "/claude/self-check"
        provider.selectItem(at: AIProvider.allCases.firstIndex(of: .codex) ?? 0); providerChanged()
        guard model.stringValue == "codex-self-check-model", executable.stringValue == "/codex/self-check" else {
            throw NSError(domain: "WriteOnSelfCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Switching providers did not restore the provider-specific model and executable"])
        }
    }
#endif
}

final class LabWindowController: NSWindowController, NSWindowDelegate {
    private let service: AIService
    private let documentProvider: () -> WritingDocument
    private let revisionProvider: () -> UInt64
    private let selectedRangeProvider: () -> DraftRange?
    private let acceptance: (AISuggestion) -> Bool
    private let markAcceptance: (AISuggestion, AIAction) -> Bool
    private let trimAcceptance: ([AISuggestion]) -> Bool
    private let trimPreview: ([AISuggestion]?) -> Void
    private var task: Task<Void, Never>?
    private var pending: [AISuggestion] = []
    private var currentAction: AIAction?
    private var expectedDocumentID: UUID?
    private var expectedRevision: UInt64 = 0
    private var requestID = UUID()
    private let resultStack = NSStackView()
    private let status = NSTextField(labelWithString: "Choose a check to review suggestions.")
    private let cancelButton = NSButton(title: "Cancel request", target: nil, action: nil)
    private let acceptAllButton = NSButton(title: "Accept all", target: nil, action: nil)
    private var resultScroll: NSScrollView!

    init(initialTheme: WriteOnTheme, service: AIService, documentProvider: @escaping () -> WritingDocument, revisionProvider: @escaping () -> UInt64, selectedRangeProvider: @escaping () -> DraftRange?, acceptance: @escaping (AISuggestion) -> Bool, markAcceptance: @escaping (AISuggestion, AIAction) -> Bool, trimAcceptance: @escaping ([AISuggestion]) -> Bool, trimPreview: @escaping ([AISuggestion]?) -> Void) {
        self.service = service; self.documentProvider = documentProvider; self.revisionProvider = revisionProvider; self.selectedRangeProvider = selectedRangeProvider; self.acceptance = acceptance; self.markAcceptance = markAcceptance; self.trimAcceptance = trimAcceptance; self.trimPreview = trimPreview
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        switch initialTheme { case .system: window.appearance = nil; case .dark: window.appearance = NSAppearance(named: .darkAqua); case .light: window.appearance = NSAppearance(named: .aqua) }
        window.title = "DansWriter Lab"; window.center(); window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 520, height: 600)
        super.init(window: window)
        window.delegate = self
        build()
    }
    required init?(coder: NSCoder) { nil }

    private func build() {
        guard let content = window?.contentView else { return }
        let p = Palette.current(window?.effectiveAppearance)
        content.wantsLayer = true; content.layer?.backgroundColor = p.canvas.cgColor
        let heading = UIStyle.label("The Lab", size: 22, color: p.text, weight: .semibold)
        let intro = UIStyle.label("Review every suggestion before it changes the draft.", size: 12, color: p.muted)
        let actions: [(String, String, AIAction)] = [
            ("Fix punctuation and typos", "Small corrections, shown against their exact source lines.", .proofread),
            ("Mark smooth sentences", "Find passages that already read cleanly.", .smoothness),
            ("Mark sentences too long", "Surface sentences that may need a breath.", .longSentences),
            ("Mark convoluted sentences", "Find passages that may be hard to follow.", .convoluted),
            ("Mark words that don’t fit tone", "Review wording that shifts the voice.", .tone),
            ("Mark hedges and filler", "Find softeners that may be unnecessary.", .hedges)
        ]
        let grid = NSGridView()
        grid.rowSpacing = 6; grid.columnSpacing = 8
        for pair in stride(from: 0, to: actions.count, by: 2) {
            let a = actionCard(actions[pair], palette: p)
            let b = pair + 1 < actions.count ? actionCard(actions[pair + 1], palette: p) : NSView()
            grid.addRow(with: [a, b])
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).width = 267; grid.column(at: 1).width = 267
        let trimLabel = UIStyle.label("TRIM WITH CONTROL", size: 10, color: p.muted, weight: .bold)
        let trimActions: [(String, AIAction)] = [("Light", .trimLight), ("Medium", .trimMedium), ("Strong", .trimStrong), ("By half", .trimHalf)]
        let trimStack = NSStackView(views: trimActions.map { title, action in
            let button = NSButton(title: title, target: self, action: #selector(trimAction(_:))); button.tag = AIAction.allCases.firstIndex(of: action) ?? 0; button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11); button.contentTintColor = p.text; return button
        })
        trimStack.orientation = .horizontal; trimStack.distribution = .fillEqually; trimStack.spacing = 7
        let resultTitle = UIStyle.label("SUGGESTIONS", size: 10, color: p.muted, weight: .bold)
        status.font = .systemFont(ofSize: 11); status.textColor = p.muted
        cancelButton.target = self; cancelButton.action = #selector(cancelRequest); cancelButton.isHidden = true; cancelButton.bezelStyle = .rounded
        acceptAllButton.target = self; acceptAllButton.action = #selector(acceptAll); acceptAllButton.isHidden = true; acceptAllButton.bezelStyle = .rounded; acceptAllButton.contentTintColor = Ink.teal
        let reviewButtons = NSStackView(views: [status, cancelButton, acceptAllButton]); reviewButtons.orientation = .horizontal; reviewButtons.distribution = .fill; reviewButtons.alignment = .centerY; reviewButtons.spacing = 8
        resultStack.orientation = .vertical; resultStack.alignment = .leading; resultStack.spacing = 10; resultStack.translatesAutoresizingMaskIntoConstraints = false
        resultScroll = NSScrollView(); resultScroll.translatesAutoresizingMaskIntoConstraints = false; resultScroll.borderType = .noBorder; resultScroll.drawsBackground = false; resultScroll.hasVerticalScroller = true; resultScroll.documentView = resultStack
        resultStack.widthAnchor.constraint(equalTo: resultScroll.contentView.widthAnchor).isActive = true

        let top = NSStackView(views: [heading, intro, spacer(4), grid, spacer(10), trimLabel, trimStack, spacer(13), UIStyle.hairline(p), resultTitle, reviewButtons, resultScroll])
        top.orientation = .vertical; top.alignment = .leading; top.spacing = 8; top.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), top.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: top.widthAnchor), trimStack.widthAnchor.constraint(equalTo: top.widthAnchor), resultScroll.widthAnchor.constraint(equalTo: top.widthAnchor), resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            reviewButtons.widthAnchor.constraint(equalTo: top.widthAnchor)
        ])
    }

    private func actionCard(_ item: (String, String, AIAction), palette: Palette) -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(checkAction(_:)))
        button.tag = AIAction.allCases.firstIndex(of: item.2) ?? 0; button.bezelStyle = .regularSquare; button.isBordered = false; button.contentTintColor = palette.text; button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true; button.layer?.backgroundColor = palette.panel.cgColor; button.layer?.cornerRadius = 8; button.layer?.borderWidth = 1; button.layer?.borderColor = palette.line.cgColor
        let title = UIStyle.label(item.0, size: 12, color: palette.text, weight: .semibold)
        let detail = UIStyle.label(item.1, size: 10, color: palette.muted)
        detail.maximumNumberOfLines = 2; detail.usesSingleLineMode = false; detail.lineBreakMode = .byWordWrapping
        title.translatesAutoresizingMaskIntoConstraints = false; detail.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        button.addSubview(stack)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 267), button.heightAnchor.constraint(equalToConstant: 61), stack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10), stack.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        return button
    }

    private func spacer(_ height: CGFloat) -> NSView { let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false; v.heightAnchor.constraint(equalToConstant: height).isActive = true; return v }

    @objc private func checkAction(_ sender: NSButton) { let index = max(0, min(sender.tag, AIAction.allCases.count - 1)); start(AIAction.allCases[index]) }
    @objc private func trimAction(_ sender: NSButton) { let index = max(0, min(sender.tag, AIAction.allCases.count - 1)); start(AIAction.allCases[index]) }

    func start(_ action: AIAction) {
        requestID = UUID(); let thisRequest = requestID
        trimPreview(nil)
        let draft = documentProvider()
        let documentID = draft.id
        let range = selectedRangeProvider()
        let selection = range.flatMap { try? draft.text(in: $0) } ?? ""
        let revision = revisionProvider()
        expectedDocumentID = documentID; expectedRevision = revision
        task?.cancel(); task = nil; currentAction = action; pending = []; rebuildResults()
        status.stringValue = "Preparing \(action.title.lowercased())…"
        cancelButton.isHidden = false; acceptAllButton.isHidden = true
        let request = AIRequest(action: action, document: draft.body, selection: selection)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.generate(request, configuration: AIConfiguration.load())
                await MainActor.run {
                    guard !Task.isCancelled, self.requestID == thisRequest else { return }
                    guard self.revisionProvider() == revision, self.documentProvider().id == documentID else { self.status.stringValue = "The draft changed while the check was running. Run it again."; self.cancelButton.isHidden = true; self.trimPreview(nil); return }
                    self.pending = result.suggestions
                    self.trimPreview(action.rawValue.hasPrefix("trim") ? result.suggestions : nil)
                    self.status.stringValue = result.suggestions.isEmpty ? "No suggestions found." : "\(result.suggestions.count) reviewable suggestion\(result.suggestions.count == 1 ? "" : "s")"
                    self.cancelButton.isHidden = true
                    self.acceptAllButton.isHidden = result.suggestions.isEmpty
                    self.rebuildResults()
                }
            } catch {
                await MainActor.run { guard self.requestID == thisRequest, !Task.isCancelled else { return }; self.status.stringValue = error.localizedDescription; self.cancelButton.isHidden = true; self.trimPreview(nil) }
            }
        }
    }

    @objc private func cancelRequest() {
        requestID = UUID(); task?.cancel(); task = nil; pending = []; currentAction = nil
        trimPreview(nil)
        status.stringValue = "Request cancelled. Nothing was changed."; cancelButton.isHidden = true; acceptAllButton.isHidden = true; rebuildResults()
    }

    @objc private func acceptAll() {
        guard let action = currentAction else { return }
        guard pendingIsCurrent() else { discardStaleSuggestions(); return }
        let all = pending
        if action.rawValue.hasPrefix("trim") {
            guard trimAcceptance(all) else { status.stringValue = "Some cuts no longer match. Review the remaining suggestions."; return }
            pending = []
        } else {
            var rejected: [AISuggestion] = []
            for suggestion in all {
                let accepted: Bool
                if action == .proofread, suggestion.replacement != nil { accepted = acceptance(suggestion) }
                else { accepted = markAcceptance(suggestion, action) }
                if !accepted { rejected.append(suggestion) }
                expectedRevision = revisionProvider()
            }
            pending = rejected
        }
        expectedRevision = revisionProvider()
        acceptAllButton.isHidden = pending.isEmpty
        status.stringValue = pending.isEmpty ? "Reviewed all suggestions." : "Some suggestions no longer match. Review the remaining items."
        rebuildResults()
        trimPreview(action.rawValue.hasPrefix("trim") && !pending.isEmpty ? pending : nil)
    }

    private func rebuildResults() {
        resultStack.arrangedSubviews.forEach { resultStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let p = Palette.current(window?.effectiveAppearance)
        for suggestion in pending {
            let quote = UIStyle.label("“\(suggestion.quote)”", size: 12, color: p.text, weight: .medium, monospaced: true)
            quote.maximumNumberOfLines = 3; quote.usesSingleLineMode = false; quote.lineBreakMode = .byTruncatingTail
            let replacement = suggestion.replacement.map { UIStyle.label("→  \($0)", size: 12, color: p.isDark ? NSColor(calibratedRed: 0.69, green: 0.82, blue: 0.77, alpha: 1) : Ink.teal, weight: .medium, monospaced: true) }
            replacement?.maximumNumberOfLines = 3; replacement?.usesSingleLineMode = false; replacement?.lineBreakMode = .byTruncatingTail
            let reason = UIStyle.label(suggestion.reason, size: 11, color: p.muted)
            reason.maximumNumberOfLines = 2; reason.usesSingleLineMode = false; reason.lineBreakMode = .byWordWrapping
            let accept = NSButton(title: currentAction?.rawValue.hasPrefix("trim") == true ? "Cut" : (suggestion.replacement == nil ? "Mark" : "Accept"), target: self, action: #selector(acceptOne(_:)))
            accept.identifier = NSUserInterfaceItemIdentifier(suggestion.id.uuidString); accept.bezelStyle = .rounded; accept.contentTintColor = Ink.teal
            let reject = NSButton(title: "Reject", target: self, action: #selector(rejectOne(_:))); reject.identifier = NSUserInterfaceItemIdentifier(suggestion.id.uuidString); reject.bezelStyle = .rounded
            let buttons = NSStackView(views: [accept, reject]); buttons.orientation = .horizontal; buttons.spacing = 7
            var views: [NSView] = [quote]
            if let replacement { views.append(replacement) }
            views += [reason, buttons, UIStyle.hairline(p)]
            let card = NSStackView(views: views); card.orientation = .vertical; card.alignment = .leading; card.spacing = 7; card.translatesAutoresizingMaskIntoConstraints = false
            resultStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
        }
    }

#if DEBUG
    func runDebugSelectionScopeCheck() throws {
        guard selectedRangeProvider() == nil else {
            throw NSError(domain: "WriteOnSelfCheck", code: 8, userInfo: [NSLocalizedDescriptionKey: "Lab used a previously inspected phrase when the editor had no selection"])
        }
    }

    func runDebugAcceptanceRetentionCheck() throws {
        let before = documentProvider()
        let first = AISuggestion(quote: "cat", replacement: "dog", reason: "test first")
        let second = AISuggestion(quote: "dog", replacement: "wolf", reason: "test becomes ambiguous")
        currentAction = .proofread; expectedDocumentID = before.id; expectedRevision = revisionProvider(); pending = [first, second]
        rebuildResults(); acceptAll()
        let current = documentProvider()
        guard current.body == "dog dog", pending.count == 1, pending[0].quote == "dog" else {
            throw NSError(domain: "WriteOnSelfCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Lab accept-all did not retain an ambiguous failed suggestion after applying a valid one"])
        }
        let reject = NSButton(); reject.identifier = NSUserInterfaceItemIdentifier(pending[0].id.uuidString)
        rejectOne(reject)
        guard pending.isEmpty, documentProvider().body == current.body else {
            throw NSError(domain: "WriteOnSelfCheck", code: 5, userInfo: [NSLocalizedDescriptionKey: "Rejecting a Lab item changed the document or failed to clear the item"])
        }
        let invalid = AISuggestion(quote: "missing quote", replacement: "anything", reason: "test stale quote")
        pending = [invalid]; expectedDocumentID = documentProvider().id; expectedRevision = revisionProvider(); currentAction = .proofread
        rebuildResults()
        let accept = NSButton(); accept.identifier = NSUserInterfaceItemIdentifier(invalid.id.uuidString)
        acceptOne(accept)
        guard pending.count == 1, documentProvider().body == current.body else {
            throw NSError(domain: "WriteOnSelfCheck", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed Lab suggestion was discarded or mutated the document"])
        }
        currentAction = nil; expectedDocumentID = nil; pending = []; rebuildResults()
        guard before.body == "cat dog" else { throw NSError(domain: "WriteOnSelfCheck", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid Lab fixture was not prepared correctly"]) }
    }

    func runDebugStaleAcceptanceCheck() throws {
        let before = documentProvider()
        let suggestion = AISuggestion(quote: "stale trim test", reason: "self-check only")
        currentAction = .trimLight
        expectedDocumentID = UUID()
        expectedRevision = revisionProvider()
        pending = [suggestion]
        trimPreview(pending)
        rebuildResults()
        acceptAll()
        guard documentProvider() == before, pending.isEmpty, status.stringValue.contains("Run the check again") else {
            throw NSError(domain: "WriteOnSelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stale Lab suggestions were not rejected and cleared"])
        }
        trimPreview(nil)
        currentAction = nil; expectedDocumentID = nil; pending = []
        acceptAllButton.isHidden = true; cancelButton.isHidden = true
        status.stringValue = "Choose a check to review suggestions."
    }
#endif

    @objc private func acceptOne(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let index = pending.firstIndex(where: { $0.id.uuidString == id }) else { return }
        guard pendingIsCurrent() else { discardStaleSuggestions(); return }
        let suggestion = pending[index]
        let accepted: Bool
        if currentAction?.rawValue.hasPrefix("trim") == true { accepted = trimAcceptance([suggestion]) }
        else if let action = currentAction {
            if action == .proofread, suggestion.replacement != nil { accepted = acceptance(suggestion) }
            else { accepted = markAcceptance(suggestion, action) }
        } else { accepted = false }
        guard accepted else { status.stringValue = "This suggestion no longer matches the draft. It remains here for review."; return }
        expectedRevision = revisionProvider()
        pending.remove(at: index); rebuildResults()
        if currentAction?.rawValue.hasPrefix("trim") == true { trimPreview(pending) }
        if pending.isEmpty { status.stringValue = "Reviewed all suggestions."; acceptAllButton.isHidden = true }
    }
    @objc private func rejectOne(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        pending.removeAll { $0.id.uuidString == id }; rebuildResults()
        if currentAction?.rawValue.hasPrefix("trim") == true { trimPreview(pending) }
        if pending.isEmpty { status.stringValue = "Reviewed all suggestions."; acceptAllButton.isHidden = true }
    }

    func windowWillClose(_ notification: Notification) { task?.cancel(); task = nil; pending = []; trimPreview(nil) }
    private func pendingIsCurrent() -> Bool { expectedDocumentID == documentProvider().id && expectedRevision == revisionProvider() }
    private func discardStaleSuggestions() { pending = []; trimPreview(nil); acceptAllButton.isHidden = true; status.stringValue = "The draft changed. Run the check again before accepting suggestions."; rebuildResults() }
    func cancelForDocumentChange() { cancelRequest(); status.stringValue = "Draft changed. Run a new check to review its text." }
}
