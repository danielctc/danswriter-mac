import AppKit
import UniformTypeIdentifiers
import WriteOnCore
import WriteOnAI

/// Native research panel. Results remain staged until the user explicitly inserts them.
final class ResearchWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    typealias Insert = (String, ResearchDestination) -> Bool
    typealias CreateTask = (String, ValyuResearchMode) async throws -> ValyuResearchTask
    typealias ReadTask = (String) async throws -> ValyuResearchTask
    typealias CancelTask = (String) async throws -> ValyuResearchTask
    typealias CopyText = (String) -> Bool

    private let onInsert: Insert
    private let createTask: CreateTask
    private let readTask: ReadTask
    private let cancelTask: CancelTask
    private let copyText: CopyText
    private var journal: ResearchJournal?
    private var entries: [ResearchJournalEntry] = []
    private var selectedEntryID: UUID?
    private var pollTask: Task<Void, Never>?
    private var pendingReportSave: DispatchWorkItem?
    private var reportNeedsSave = false
    private var reportRecoverySaved = false
    private var isPolling = false
    private var isCancelling = false
    private(set) var hasPendingCreation = false
    private var lifecycleGeneration = UUID()
    private var pendingCreationTask: ValyuResearchTask?
    private var pendingCreationEntryID: UUID?
    private var pendingCreationTimer: Timer?
    private var pendingCreationRetryCount = 0
    private var pendingCreationRetryExhausted = false
    private var panelClosed = false
    private var palette: Palette
    private weak var mainStack: NSStackView?
    private weak var controlsRow: NSStackView?
    private weak var stageRow: NSStackView?
    private var reportHeightConstraint: NSLayoutConstraint?
    private let query = NSTextView()
    private let queryScroll = NSScrollView()
    private let mode = NSPopUpButton()
    private let startButton = NSButton(title: "Start paid research", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume selected task", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel remote request", target: nil, action: nil)
    private let copyTaskIDButton = NSButton(title: "Copy task ID", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Research results are saved here until you choose what to do with them.")
    private let progress = NSProgressIndicator()
    private let history = NSPopUpButton()
    private let resumeIDButton = NSButton(title: "Resume task ID…", target: nil, action: nil)
    private let report = NSTextView()
    private let reportScroll = NSScrollView()
    private let sources = NSTextView()
    private let key = NSSecureTextField(string: "")
    private let keyStatus = NSTextField(labelWithString: "")
    private let saveKeyButton = NSButton(title: "Save key", target: nil, action: nil)
    private let deleteKeyButton = NSButton(title: "Delete saved key", target: nil, action: nil)

    convenience init(initialTheme: WriteOnTheme, service: ValyuResearchService = ValyuResearchService(), journalDirectory: URL? = nil, onInsert: @escaping Insert) {
        self.init(initialTheme: initialTheme, journalDirectory: journalDirectory,
                  createTask: { try await service.create(query: $0, mode: $1) },
                  readTask: { try await service.status(taskID: $0) },
                  cancelTask: { try await service.cancel(taskID: $0) }, onInsert: onInsert)
    }

    init(initialTheme: WriteOnTheme, journalDirectory: URL? = nil, createTask: @escaping CreateTask, readTask: @escaping ReadTask, cancelTask: @escaping CancelTask, copyText: @escaping CopyText = { value in NSPasteboard.general.clearContents(); return NSPasteboard.general.setString(value, forType: .string) }, onInsert: @escaping Insert) {
        self.onInsert = onInsert
        self.createTask = createTask; self.readTask = readTask; self.cancelTask = cancelTask; self.copyText = copyText
        switch initialTheme {
        case .system: palette = Palette.current()
        case .dark: palette = Palette.current(NSAppearance(named: .darkAqua))
        case .light: palette = Palette.current(NSAppearance(named: .aqua))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DansWriter Research"; window.center(); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 650, height: 680)
        super.init(window: window)
        applyTheme(initialTheme)
        window.delegate = self
        do { journal = try ResearchJournal(directory: journalDirectory); entries = try journal?.load() ?? [] }
        catch { journal = nil; status.stringValue = "The local research journal could not be opened. Existing files were left untouched; research requests are disabled." }
        build()
        refreshHistory()
        selectEntry(entries.first?.id)
        updateKeyStatus()
        if let active = entries.first(where: { $0.status == "queued" || $0.status == "running" }), active.taskID != nil {
            status.stringValue = "A research task is saved. Select it and choose Resume to check its current status."
        }
    }
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) { panelClosed = false; super.showWindow(sender) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { flushReportChanges() }

    func windowWillClose(_ notification: Notification) {
        _ = flushReportChanges()
        panelClosed = true
        guard !hasPendingCreation, !isCancelling else { return }
        pollTask?.cancel(); pollTask = nil
        lifecycleGeneration = UUID()
        setBusy(false)
        if selectedEntry?.taskID != nil { status.stringValue = "Status checks paused while this window is closed. Reopen Research and choose Resume to continue." }
    }
    func windowDidResize(_ notification: Notification) { updateReportHeight() }
    private func updateReportHeight() {
        guard let content = window?.contentView else { return }
        reportHeightConstraint?.constant = min(300, max(150, content.bounds.height - 490))
    }

    func update(theme: WriteOnTheme) {
        applyTheme(theme)
        palette = Palette.current(window?.effectiveAppearance)
        window?.contentView?.layer?.backgroundColor = palette.canvas.cgColor
        [query, report, sources].forEach { $0.backgroundColor = palette.panel; $0.textColor = palette.text }
        [status, keyStatus].forEach { $0.textColor = palette.muted }
    }

    private func applyTheme(_ theme: WriteOnTheme) {
        switch theme { case .system: window?.appearance = nil; case .dark: window?.appearance = NSAppearance(named: .darkAqua); case .light: window?.appearance = NSAppearance(named: .aqua) }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true; content.layer?.backgroundColor = palette.canvas.cgColor
        let title = UIStyle.label("Research", size: 23, color: palette.text, weight: .semibold)
        let queryLabel = UIStyle.label("RESEARCH QUESTION · Start sends this query to your Valyu paid account.", size: 10, color: palette.muted, weight: .bold)
        query.isRichText = false; query.font = .systemFont(ofSize: 13); query.textContainerInset = NSSize(width: 9, height: 8)
        query.backgroundColor = palette.panel; query.textColor = palette.text; query.minSize = NSSize(width: 0, height: 56); query.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        query.isVerticallyResizable = true; query.isHorizontallyResizable = false; query.textContainer?.widthTracksTextView = true
        queryScroll.documentView = query; queryScroll.hasVerticalScroller = true; queryScroll.borderType = .bezelBorder; queryScroll.translatesAutoresizingMaskIntoConstraints = false
        queryScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        mode.addItems(withTitles: ValyuResearchMode.allCases.map { $0.rawValue.capitalized }); mode.selectItem(at: ValyuResearchMode.allCases.firstIndex(of: .standard) ?? 0)
        let modeRow = NSStackView(views: [UIStyle.label("Depth", size: 11, color: palette.muted), mode, startButton])
        modeRow.orientation = .horizontal; modeRow.alignment = .centerY; modeRow.spacing = 10
        mode.target = self; mode.action = #selector(modeChanged)
        startButton.target = self; startButton.action = #selector(startResearch); startButton.bezelStyle = .rounded; startButton.bezelColor = Ink.teal; startButton.contentTintColor = .white
        resumeButton.target = self; resumeButton.action = #selector(resumeSelected); cancelButton.target = self; cancelButton.action = #selector(cancelSelected)
        copyTaskIDButton.target = self; copyTaskIDButton.action = #selector(copyPendingTaskID)
        let taskRow = NSStackView(views: [resumeButton, cancelButton]); taskRow.orientation = .horizontal; taskRow.alignment = .centerY; taskRow.spacing = 9
        let controls = NSStackView(views: [modeRow, taskRow]); controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 4
        controlsRow = controls
        progress.style = .bar; progress.isIndeterminate = true; progress.isHidden = true; progress.controlSize = .small
        status.font = .systemFont(ofSize: 11); status.textColor = palette.muted; status.maximumNumberOfLines = 2; status.usesSingleLineMode = false; status.lineBreakMode = .byWordWrapping
        history.target = self; history.action = #selector(historyChanged)
        resumeIDButton.target = self; resumeIDButton.action = #selector(resumeTaskIDPrompt)
        let stageRow = NSStackView(views: [UIStyle.label("Saved research", size: 11, color: palette.muted, weight: .semibold), history, resumeIDButton])
        stageRow.orientation = .horizontal; stageRow.alignment = .centerY; stageRow.spacing = 8; self.stageRow = stageRow
        report.isRichText = false; report.allowsUndo = true; report.font = .monospacedSystemFont(ofSize: 12, weight: .regular); report.textContainerInset = NSSize(width: 12, height: 11)
        report.backgroundColor = palette.panel; report.textColor = palette.text; report.delegate = self
        reportScroll.documentView = report; reportScroll.hasVerticalScroller = true; reportScroll.borderType = .bezelBorder
        sources.isEditable = false; sources.isSelectable = true; sources.isRichText = false; sources.font = .systemFont(ofSize: 11); sources.textContainerInset = NSSize(width: 8, height: 6)
        sources.backgroundColor = palette.panel; sources.textColor = palette.text; sources.isVerticallyResizable = true; sources.isHorizontallyResizable = false; sources.textContainer?.widthTracksTextView = true
        let sourcesScroll = NSScrollView(); sourcesScroll.documentView = sources; sourcesScroll.hasVerticalScroller = true; sourcesScroll.borderType = .bezelBorder; sourcesScroll.heightAnchor.constraint(equalToConstant: 58).isActive = true
        let reportLabel = UIStyle.label("REPORT · EDITABLE STAGED COPY", size: 10, color: palette.muted, weight: .bold)
        let insertButtons = NSStackView(views: [UIStyle.button("Copy report", action: #selector(copyReport), target: self, palette: palette), UIStyle.button("Append to draft", action: #selector(appendToDraft), target: self, palette: palette, prominent: true), UIStyle.button("Send to Overflow", action: #selector(sendToOverflow), target: self, palette: palette), UIStyle.button("Export…", action: #selector(exportReport), target: self, palette: palette), UIStyle.button("Import…", action: #selector(importReport), target: self, palette: palette)])
        insertButtons.orientation = .horizontal; insertButtons.alignment = .centerY; insertButtons.spacing = 8
        let keyHeader = UIStyle.label("VALYU KEY · STORED IN KEYCHAIN", size: 10, color: palette.muted, weight: .bold)
        let keyRow = NSStackView(views: [key, saveKeyButton, deleteKeyButton]); keyRow.orientation = .horizontal; keyRow.spacing = 7
        key.placeholderString = "Paste key to save; saved value is never displayed"; key.target = self; key.action = #selector(saveKey)
        saveKeyButton.target = self; saveKeyButton.action = #selector(saveKey); deleteKeyButton.target = self; deleteKeyButton.action = #selector(deleteKey)
        keyStatus.font = .systemFont(ofSize: 10); keyStatus.textColor = palette.muted
        let stack = NSStackView(views: [title, queryLabel, queryScroll, controls, stageRow, progress, status, copyTaskIDButton, reportLabel, reportScroll, sourcesScroll, insertButtons, keyHeader, keyRow, keyStatus])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false
        mainStack = stack
        content.addSubview(stack)
        let reportHeight = reportScroll.heightAnchor.constraint(equalToConstant: 160); reportHeight.isActive = true; reportHeightConstraint = reportHeight
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10), queryScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), stageRow.widthAnchor.constraint(equalTo: stack.widthAnchor), history.widthAnchor.constraint(greaterThanOrEqualToConstant: 250), reportLabel.widthAnchor.constraint(equalTo: stack.widthAnchor), reportScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), sourcesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor), keyRow.widthAnchor.constraint(equalTo: stack.widthAnchor), keyStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        content.layoutSubtreeIfNeeded(); updateReportHeight()
        for textView in [query, report, sources] {
            textView.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        }
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        updateButtons()
    }

    private var selectedEntry: ResearchJournalEntry? { entries.first { $0.id == selectedEntryID } }
    private func refreshHistory() {
        history.removeAllItems()
        for item in entries { history.addItem(withTitle: String((item.query.isEmpty ? "Imported report" : item.query).prefix(56)) + " · " + item.status) ; history.lastItem?.representedObject = item.id }
        if let id = selectedEntryID, let index = entries.firstIndex(where: { $0.id == id }) { history.selectItem(at: index) }
    }
    private func selectEntry(_ id: UUID?) {
        selectedEntryID = id
        guard let item = selectedEntry else { report.string = ""; sources.string = ""; updateButtons(); return }
        report.string = item.reportMarkdown; sources.string = item.sources.enumerated().map { index, source in
            let excerpt = source.snippet.map { "\n   \($0)" } ?? ""
            return "\(index + 1). \(source.title)\n   \(source.url)\(excerpt)"
        }.joined(separator: "\n\n")
        query.string = item.query
        status.stringValue = statusText(item)
        refreshHistory(); updateButtons()
    }
    @objc private func historyChanged() {
        guard history.indexOfSelectedItem >= 0, let id = history.selectedItem?.representedObject as? UUID else { return }
        guard flushReportChanges() else { refreshHistory(); return }
        reportNeedsSave = false; reportRecoverySaved = false
        selectEntry(id)
    }
    @objc private func modeChanged() {}
    private var selectedMode: ValyuResearchMode { ValyuResearchMode.allCases[min(ValyuResearchMode.allCases.count - 1, max(0, mode.indexOfSelectedItem))] }
    @objc private func startResearch() {
        let text = query.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard journal != nil else { status.stringValue = "Research cannot start because its local journal is unavailable."; return }
        guard !text.isEmpty, text.count <= 8_000, !isPolling, !hasPendingCreation else { status.stringValue = "Enter a research question under 8,000 characters."; return }
        let requestMode = selectedMode
        let entry = ResearchJournalEntry(query: text, mode: requestMode.rawValue, status: "queued")
        entries.insert(entry, at: 0); selectedEntryID = entry.id
        guard persist() else { entries.removeAll { $0.id == entry.id }; selectedEntryID = nil; refreshHistory(); updateButtons(); return }
        refreshHistory(); selectEntry(entry.id)
        status.stringValue = "Starting a paid Valyu research request…"; setBusy(true)
        hasPendingCreation = true
        updateButtons()
        let generation = UUID(); lifecycleGeneration = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let task = try await createTask(text, requestMode)
                await MainActor.run {
                    guard self.lifecycleGeneration == generation else { return }
                    self.pendingCreationTask = task; self.pendingCreationEntryID = entry.id
                    self.persistCreatedTask(task, entryID: entry.id, generation: generation)
                }
            } catch {
                await MainActor.run {
                    guard self.lifecycleGeneration == generation else { return }
                    self.hasPendingCreation = false
                    self.setFailure(for: entry.id, message: "Valyu could not start the research request. Check the saved key and connection, then try again.")
                }
            }
        }
    }
    private func persistCreatedTask(_ task: ValyuResearchTask, entryID: UUID, generation: UUID) {
        guard lifecycleGeneration == generation else { return }
        if apply(task, to: entryID) {
            clearPendingCreation()
            updateButtons()
            if panelClosed { setBusy(false); status.stringValue = "The task ID is saved. Reopen Research and choose Resume to check its status." }
            else { poll(taskID: task.id, entryID: entryID, generation: generation) }
        } else if pendingCreationRetryCount >= 3 {
            pendingCreationRetryExhausted = true
            pendingCreationTimer?.invalidate(); pendingCreationTimer = nil
            status.stringValue = "The task ID could not be saved after three retries. Copy it now, save it somewhere safe, then choose Resume to check the task."
            setBusy(false)
        } else {
            status.stringValue = "Valyu started the task, but its ID could not be saved. DansWriter is retrying the local save."
            if pendingCreationTimer == nil {
                pendingCreationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    self.retryPendingCreationPersistence(generation: generation)
                }
            }
        }
    }
    private func retryPendingCreationPersistence(generation: UUID) {
        guard lifecycleGeneration == generation, let task = pendingCreationTask, let entryID = pendingCreationEntryID else {
            pendingCreationTimer?.invalidate(); pendingCreationTimer = nil; return
        }
        pendingCreationTimer?.invalidate(); pendingCreationTimer = nil
        pendingCreationRetryCount += 1
        persistCreatedTask(task, entryID: entryID, generation: generation)
    }
    private func clearPendingCreation() {
        hasPendingCreation = false; pendingCreationTask = nil; pendingCreationEntryID = nil
        pendingCreationRetryCount = 0; pendingCreationRetryExhausted = false
        pendingCreationTimer?.invalidate(); pendingCreationTimer = nil
    }
    @objc private func copyPendingTaskID() {
        guard pendingCreationRetryExhausted, let task = pendingCreationTask else { return }
        guard copyText(task.id) else { status.stringValue = "The task ID could not be copied. It is still retained here; try Copy task ID again."; return }
        hasPendingCreation = false
        pendingCreationRetryExhausted = false
        pendingCreationTimer?.invalidate(); pendingCreationTimer = nil
        status.stringValue = "Task ID copied. Save it somewhere safe, then choose Resume to check the remote task."
        setBusy(false)
    }
    @objc private func resumeSelected() {
        guard let item = selectedEntry, let taskID = item.taskID, !isPolling else { return }
        status.stringValue = "Checking the saved task with Valyu…"; setBusy(true)
        let generation = UUID(); lifecycleGeneration = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            do { let task = try await readTask(taskID); await MainActor.run { guard self.lifecycleGeneration == generation else { return }; _ = self.apply(task, to: item.id); self.poll(taskID: taskID, entryID: item.id, generation: generation) } }
            catch { await MainActor.run { guard self.lifecycleGeneration == generation else { return }; self.setFailure(for: item.id, message: "The saved research task could not be checked. You can retry Resume later.") } }
        }
    }
    @objc private func resumeTaskIDPrompt() {
        let field = NSTextField(string: "")
        field.placeholderString = "Valyu task ID"
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let alert = NSAlert(); alert.messageText = "Resume a research task"; alert.informativeText = "Paste a task ID you saved. DansWriter will check its status without starting new research."; alert.accessoryView = field
        alert.addButton(withTitle: "Resume"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restoreTaskID(field.stringValue)
    }
    private func restoreTaskID(_ rawID: String) {
        let taskID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTaskID(taskID) else { status.stringValue = "That task ID is not valid."; return }
        if let existing = entries.first(where: { $0.taskID == taskID }) { selectEntry(existing.id); resumeSelected(); return }
        let recovered = ResearchJournalEntry(taskID: taskID, query: "Recovered research task", mode: "recovered", status: "unknown")
        entries.insert(recovered, at: 0); selectedEntryID = recovered.id
        guard persist() else { entries.removeAll { $0.id == recovered.id }; selectedEntryID = nil; refreshHistory(); status.stringValue = "The task ID could not be saved locally, so its status was not requested."; return }
        refreshHistory(); selectEntry(recovered.id)
        resumeSelected()
    }
    private static func isValidTaskID(_ value: String) -> Bool {
        value.count <= 128 && value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }
    private func poll(taskID: String, entryID: UUID, generation: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }), entry.status == "queued" || entry.status == "running" else { setBusy(false); return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<720 where !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    let task = try await readTask(taskID)
                    let finished = task.status == .completed || task.status == .failed || task.status == .cancelled || task.status == .awaiting_input || task.status == .paused
                    let current = await MainActor.run { () -> Bool in
                        guard self.lifecycleGeneration == generation else { return false }
                        _ = self.apply(task, to: entryID); if finished { self.setBusy(false) }; return true
                    }
                    guard current else { return }
                    if finished { return }
                } catch is CancellationError { return }
                catch { await MainActor.run { guard self.lifecycleGeneration == generation else { return }; self.setFailure(for: entryID, message: "Research status could not be refreshed. Resume the task to check again.") }; return }
                if attempt == 719 {
                    await MainActor.run { guard self.lifecycleGeneration == generation else { return }; self.status.stringValue = "Automatic status checks paused after two hours. The task ID is saved; choose Resume to continue checking."; self.setBusy(false) }
                }
            }
        }
    }
    @objc private func cancelSelected() {
        guard let item = selectedEntry, let taskID = item.taskID, !isCancelling,
              item.status == "running" || item.status == "queued" || item.status == "unknown" || item.status == "paused" || item.status == "awaiting_input" else { return }
        pollTask?.cancel(); pendingCreationTimer?.invalidate(); pendingCreationTimer = nil
        let generation = UUID(); lifecycleGeneration = generation
        isCancelling = true; setBusy(true); status.stringValue = "Sending cancellation to Valyu…"
        pollTask = Task { [weak self] in
            guard let self else { return }
            do { let task = try await cancelTask(taskID); await MainActor.run { guard self.lifecycleGeneration == generation else { return }; let saved = self.apply(task, to: item.id); if task.status == .cancelled && self.pendingCreationTask?.id == task.id { self.clearPendingCreation() }; self.isCancelling = false; self.setBusy(false); if !saved { self.status.stringValue = "Valyu cancelled the task, but its latest status could not be saved locally." }; self.updateButtons() } }
            catch { await MainActor.run {
                guard self.lifecycleGeneration == generation else { return }
                self.isCancelling = false
                self.setFailure(for: item.id, message: "Valyu could not confirm cancellation. Resume to check task status.")
                if self.hasPendingCreation, let pending = self.pendingCreationTask, let pendingID = self.pendingCreationEntryID {
                    self.persistCreatedTask(pending, entryID: pendingID, generation: generation)
                }
            } }
        }
    }
    @discardableResult private func apply(_ task: ValyuResearchTask, to id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var item = entries[index]; item.taskID = task.id; item.status = task.status.rawValue
        if let result = task.result {
            item.reportMarkdown = result.markdown
            item.sources = result.sources.map { ResearchSourceRecord(title: $0.title, url: $0.url.absoluteString, snippet: $0.snippet) }
        }
        item.updatedAt = Date(); entries[index] = item
        let saved = persist()
        if selectedEntryID == id {
            selectEntry(id)
            if !saved { status.stringValue = "The local research journal could not save the full task result. The report remains staged in this window." }
            else if task.status == .running { status.stringValue = "Research is running. Progress: \(task.progressCurrent ?? 0) / \(task.progressTotal ?? 0)." }
        }
        return saved
    }
    private func statusText(_ item: ResearchJournalEntry) -> String {
        switch item.status { case "completed": return "Report saved locally. Review and edit it before using it."; case "running", "queued": return "Task \(item.taskID ?? "pending") · \(item.status). Choose Resume to check again."; case "awaiting_input": return "Valyu is waiting for more input. The task ID and staged report are saved."; case "paused": return "Valyu paused this task. Choose Resume to check its status."; case "failed": return "The provider reported a failure. The staged data is preserved."; case "cancelled": return "The remote task is cancelled. Any returned report remains staged."; default: return "Imported or staged report. It will not alter a draft automatically." }
    }
    private func setFailure(for id: UUID, message: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].updatedAt = Date(); persist() }
        status.stringValue = message; setBusy(false)
    }
    @discardableResult private func persist() -> Bool {
        guard let journal else { status.stringValue = "The local research journal is unavailable. Existing files were left untouched."; return false }
        do { try journal.save(entries); return true }
        catch { status.stringValue = "The local research journal could not save this full result. The report remains staged in this window."; return false }
    }
    private func setBusy(_ busy: Bool) { isPolling = busy; progress.isHidden = !busy; if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }; updateButtons() }
    private func updateButtons() {
        let resumable = ["running", "queued", "unknown", "paused", "awaiting_input"].contains(selectedEntry?.status ?? "")
        startButton.isEnabled = !isPolling && !hasPendingCreation && journal != nil; resumeButton.isEnabled = !isPolling && !hasPendingCreation && selectedEntry?.taskID != nil && resumable; cancelButton.isEnabled = !isCancelling && selectedEntry?.taskID != nil && resumable
        copyTaskIDButton.isHidden = !pendingCreationRetryExhausted || pendingCreationTask == nil
        copyTaskIDButton.isEnabled = !copyTaskIDButton.isHidden
        let hasReport = !(selectedEntry?.reportMarkdown.isEmpty ?? true); report.isEditable = hasReport
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === report, let index = entries.firstIndex(where: { $0.id == selectedEntryID }) else { return }
        entries[index].reportMarkdown = report.string; entries[index].updatedAt = Date()
        reportNeedsSave = true; reportRecoverySaved = false
        pendingReportSave?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flushReportChanges() }
        pendingReportSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    @discardableResult func flushReportChanges() -> Bool {
        pendingReportSave?.cancel(); pendingReportSave = nil
        guard reportNeedsSave else { return true }
        let saved = persist()
        if saved { reportNeedsSave = false }
        return saved || reportRecoverySaved
    }
    @objc private func copyReport() { guard let text = composedReport(), !text.isEmpty else { return }; NSPasteboard.general.clearContents(); reportRecoverySaved = NSPasteboard.general.setString(text, forType: .string); status.stringValue = reportRecoverySaved ? "Report and references copied." : "The report could not be copied." }
    @objc private func appendToDraft() { insert(.draft) }
    @objc private func sendToOverflow() { insert(.overflow) }
    private func insert(_ destination: ResearchDestination) {
        guard let text = composedReport(), !text.isEmpty else { status.stringValue = "There is no report to add yet."; return }
        status.stringValue = onInsert(text, destination) ? "Report and references added." : "The report could not be added. The staged copy is still here."
    }
    private func composedReport() -> String? {
        guard var body = selectedEntry.map({ _ in report.string.trimmingCharacters(in: .whitespacesAndNewlines) }), !body.isEmpty else { return nil }
        let refs = selectedEntry?.sources ?? []
        guard !refs.isEmpty else { return body }
        let existing = Set(body.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let range = line.range(of: "https?://[^)\\s]+", options: .regularExpression) else { return nil }; return String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        })
        var seen = existing
        let missing = refs.filter { seen.insert($0.url).inserted }
        let lines = missing.compactMap { source -> String? in
            guard let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let title = source.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").components(separatedBy: .newlines).joined(separator: " ")
            let safeURL = url.absoluteString.replacingOccurrences(of: ">", with: "%3E")
            return "- [\(title)](<\(safeURL)>)"
        }
        if !lines.isEmpty { body += "\n\n## References\n\n" + lines.joined(separator: "\n") }
        return body
    }
    @objc private func exportReport() {
        guard let text = composedReport() else { status.stringValue = "There is no report to export yet."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = "Research.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic); reportRecoverySaved = true; status.stringValue = "Research report exported." }
        catch { status.stringValue = "The report could not be exported to that file." }
    }
    @objc private func importReport() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else { throw ResearchImportError.invalid }
            let imported = try Self.parseImport(Data(contentsOf: url), fileExtension: url.pathExtension)
            let item = ResearchJournalEntry(query: "Imported: \(url.lastPathComponent)", mode: "import", status: "imported", reportMarkdown: imported.markdown, sources: imported.sources)
            entries.insert(item, at: 0); selectedEntryID = item.id
            let saved = persist(); refreshHistory(); selectEntry(item.id)
            if !saved { status.stringValue = "The imported report is available in this window, but its full report and source list could not be saved to the local journal." }
        } catch { status.stringValue = "That file could not be imported. Use Markdown or JSON with a report string and optional valid HTTP or HTTPS sources." }
    }
    private static func parseImport(_ data: Data, fileExtension: String) throws -> (markdown: String, sources: [ResearchSourceRecord]) {
        guard data.count <= 2_000_000 else { throw ResearchImportError.invalid }
        let markdown: String
        var importedSources: [ResearchSourceRecord] = []
        if fileExtension.lowercased() == "json" {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ResearchImportError.invalid }
            markdown = (object["output"] as? String) ?? (object["markdown"] as? String) ?? (object["report"] as? String) ?? (object["content"] as? String) ?? ""
            let rows = object["sources"] as? [[String: Any]] ?? []
            guard rows.count <= 500 else { throw ResearchImportError.invalid }
            for row in rows {
                guard let sourceURL = row["url"] as? String, let parsedURL = URL(string: sourceURL),
                      ["https", "http"].contains(parsedURL.scheme?.lowercased() ?? ""), parsedURL.host != nil else { throw ResearchImportError.invalid }
                let title = row["title"] as? String ?? sourceURL
                let snippet = row["snippet"] as? String
                guard title.count <= 500, sourceURL.count <= 2_000, (snippet?.count ?? 0) <= 4_000 else { throw ResearchImportError.invalid }
                importedSources.append(ResearchSourceRecord(title: title, url: sourceURL, snippet: snippet))
            }
        } else { markdown = String(decoding: data, as: UTF8.self) }
        guard !markdown.isEmpty, markdown.utf8.count <= 3_000_000 else { throw ResearchImportError.invalid }
        return (markdown, importedSources)
    }
    @objc private func saveKey() {
        guard !key.stringValue.isEmpty else { return }
        do { try ValyuKeychainStore.set(key.stringValue); key.stringValue = ""; updateKeyStatus() }
        catch { key.stringValue = ""; keyStatus.stringValue = "Keychain could not save the key." }
    }
    @objc private func deleteKey() {
        do { try ValyuKeychainStore.delete(); key.stringValue = ""; updateKeyStatus() }
        catch { keyStatus.stringValue = "Keychain could not delete the key." }
    }
    private func updateKeyStatus() {
        do { keyStatus.stringValue = try ValyuKeychainStore.hasKey() ? "A Valyu key is saved in Keychain." : "No key saved. Add one to start paid research." }
        catch { keyStatus.stringValue = "Keychain status is unavailable." }
    }
#if DEBUG
    func debugStageFixture() throws {
        let entry = ResearchJournalEntry(query: "Fixture query", mode: "standard", status: "completed", reportMarkdown: "# Staged fixture\n\nThis report remains reviewable and does not alter a draft.", sources: [ResearchSourceRecord(title: "Example source", url: "https://example.com")])
        entries.insert(entry, at: 0); selectedEntryID = entry.id; try journal?.save(entries); refreshHistory(); selectEntry(entry.id)
    }

    func debugSetCreationPending(_ pending: Bool) { hasPendingCreation = pending }

    static func runDebugResearchCheck() throws {
        let valyuFixture = Data(##"{"output":"# Valyu JSON report","sources":[{"title":"Official source","url":"https://example.com/report","snippet":"A short excerpt."}]}"##.utf8)
        let parsedFixture = try parseImport(valyuFixture, fileExtension: "json")
        guard parsedFixture.markdown == "# Valyu JSON report", parsedFixture.sources.count == 1,
              parsedFixture.sources[0].url == "https://example.com/report",
              isValidTaskID("dr_123-test"), !isValidTaskID("https://example.com") else { throw ResearchDebugFailure.valyuJSONImportWasNotParsed }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DansWriterResearchCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var inserts: [(String, ResearchDestination)] = []
        let unusedCreate: CreateTask = { _, _ in throw ValyuResearchError.transport }
        let unusedRead: ReadTask = { _ in throw ValyuResearchError.transport }
        let unusedCancel: CancelTask = { _ in throw ValyuResearchError.transport }
        let first = ResearchWindowController(initialTheme: .system, journalDirectory: folder, createTask: unusedCreate, readTask: unusedRead, cancelTask: unusedCancel) { text, destination in
            inserts.append((text, destination)); return true
        }
        try first.debugStageFixture()
        guard inserts.isEmpty else { throw ResearchDebugFailure.stagedReportChangedDraft }
        let unedited = try first.journal!.load()
        first.report.string += "\nEdited report fixture."
        first.textDidChange(Notification(name: NSText.didChangeNotification, object: first.report))
        guard try first.journal!.load() == unedited, first.flushReportChanges(),
              try first.journal!.load().first?.reportMarkdown.hasSuffix("Edited report fixture.") == true else { throw ResearchDebugFailure.debouncedEditLost }
        guard let store = first.journal else { throw ResearchDebugFailure.journalUnavailable }
        let savedFixture = try store.load()
        do {
            try store.save([ResearchJournalEntry(query: "Oversized fixture", mode: "standard", reportMarkdown: String(repeating: "x", count: 3_000_001))])
            throw ResearchDebugFailure.oversizedReportWasAccepted
        } catch ResearchJournalError.invalidEntry { }
        guard try store.load() == savedFixture else { throw ResearchDebugFailure.failedSaveReplacedJournal }
        let savedMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        guard savedMode?.intValue == 0o600 else { throw ResearchDebugFailure.journalPermissions }
        let active = ResearchJournalEntry(taskID: "fixture-task", query: "Resumable fixture", mode: "standard", status: "running")
        try store.save([active] + first.entries)
        let reopened = ResearchWindowController(initialTheme: .system, journalDirectory: folder, createTask: unusedCreate, readTask: unusedRead, cancelTask: unusedCancel) { text, destination in
            inserts.append((text, destination)); return true
        }
        guard reopened.entries.count == 2, reopened.resumeButton.isEnabled, reopened.cancelButton.isEnabled else {
            throw ResearchDebugFailure.resumeStateNotRestored
        }
        guard inserts.isEmpty else { throw ResearchDebugFailure.stagedReportChangedDraft }
        reopened.selectEntry(reopened.entries.first(where: { $0.reportMarkdown.contains("Staged fixture") })?.id)
        guard reopened.report.string.contains("Staged fixture") else { throw ResearchDebugFailure.stagedReportNotRestored }
        let artifactFolder = URL(fileURLWithPath: "/private/tmp/danswriter-self-check-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactFolder, withIntermediateDirectories: true)
        try reopened.renderDebugSnapshot(theme: .light, size: NSSize(width: 650, height: 680), to: artifactFolder.appendingPathComponent("research-light.png"))
        try reopened.renderDebugSnapshot(theme: .dark, size: NSSize(width: 790, height: 850), to: artifactFolder.appendingPathComponent("research-dark.png"))
        reopened.appendToDraft()
        guard inserts.count == 1, inserts[0].1 == .draft, inserts[0].0.contains("https://example.com") else {
            throw ResearchDebugFailure.explicitInsertNotDelivered
        }
        reopened.sendToOverflow()
        guard inserts.count == 2, inserts[1].1 == .overflow else { throw ResearchDebugFailure.explicitInsertNotDelivered }

        let retryFolder = folder.appendingPathComponent("retry", isDirectory: true)
        var copiedID: String?
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        let retryID = UUID()
        let retryController = ResearchWindowController(initialTheme: .system, journalDirectory: retryFolder,
            createTask: unusedCreate, readTask: unusedRead, cancelTask: unusedCancel,
            copyText: { copiedID = $0; return true }, onInsert: { _, _ in false })
        let retryEntry = ResearchJournalEntry(id: retryID, query: "Retry fixture", mode: "standard", status: "queued")
        retryController.entries = [retryEntry]; retryController.selectedEntryID = retryID
        try retryController.journal?.save([retryEntry]); retryController.refreshHistory(); retryController.selectEntry(retryID)
        let unsupportedSource = ValyuResearchSource(title: "Invalid fixture source", url: URL(string: "file:///private/tmp/research")!)
        let failedSaveTask = ValyuResearchTask(id: "fixture-unsaved-task", status: .running, result: ValyuResearchResult(markdown: "Staged without a durable task ID.", sources: [unsupportedSource]))
        retryController.pendingCreationTask = failedSaveTask; retryController.pendingCreationEntryID = retryID
        retryController.hasPendingCreation = true; retryController.isPolling = true
        let retryGeneration = UUID(); retryController.lifecycleGeneration = retryGeneration
        retryController.persistCreatedTask(failedSaveTask, entryID: retryID, generation: retryGeneration)
        for _ in 0..<3 { retryController.retryPendingCreationPersistence(generation: retryGeneration) }
        guard retryController.pendingCreationRetryCount == 3, retryController.pendingCreationRetryExhausted,
              retryController.hasPendingCreation, retryController.copyTaskIDButton.isEnabled,
              retryController.pollTask == nil else { throw ResearchDebugFailure.persistenceRetryWasNotBounded }
        retryController.copyPendingTaskID()
        guard copiedID == "fixture-unsaved-task", !retryController.hasPendingCreation,
              retryController.pollTask == nil, NSPasteboard.general.string(forType: .string) == clipboardBefore else {
            throw ResearchDebugFailure.copyDidNotReleasePendingTask
        }

        let corruptFolder = folder.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corruptURL = corruptFolder.appendingPathComponent("research-journal.json")
        let malformed = Data("[invalid".utf8); try malformed.write(to: corruptURL)
        let corruptController = ResearchWindowController(initialTheme: .system, journalDirectory: corruptFolder,
            createTask: { _, _ in throw ResearchDebugFailure.corruptJournalWasOverwritten },
            readTask: unusedRead, cancelTask: unusedCancel, onInsert: { _, _ in false })
        corruptController.query.string = "Should not start"
        corruptController.startResearch()
        guard !corruptController.isPolling, try Data(contentsOf: corruptURL) == malformed else { throw ResearchDebugFailure.corruptJournalWasOverwritten }
    }

    private func renderDebugSnapshot(theme: WriteOnTheme, size: NSSize, to url: URL) throws {
        guard let window, let content = window.contentView else { throw ResearchDebugFailure.layoutUnavailable }
        update(theme: theme)
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.displayIfNeeded(); content.layoutSubtreeIfNeeded()
        guard let stack = mainStack, let controls = controlsRow, let stage = stageRow,
              content.bounds.width >= 600,
              queryScroll.frame.width >= 550, reportScroll.frame.width >= 550, reportScroll.frame.height >= 145,
              controls.frame.minX >= 0, controls.frame.maxX <= stack.bounds.width + 1,
              stage.frame.minX >= 0, stage.frame.maxX <= stack.bounds.width + 1 else { throw ResearchDebugFailure.layoutOutOfBounds }
        for textView in [query, report, sources] {
            guard textView.frame.width > 100, textView.frame.height > 0,
                  let container = textView.textContainer, container.containerSize.width > 100 else { throw ResearchDebugFailure.layoutOutOfBounds }
            if !textView.string.isEmpty {
                textView.layoutManager?.ensureLayout(for: container)
                guard (textView.layoutManager?.glyphRange(for: container).length ?? 0) > 0 else { throw ResearchDebugFailure.layoutOutOfBounds }
            }
        }
        guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw ResearchDebugFailure.snapshotFailed }
        content.cacheDisplay(in: content.bounds, to: image)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw ResearchDebugFailure.snapshotFailed }
        try png.write(to: url, options: .atomic)
    }
#endif
}

private enum ResearchImportError: Error { case invalid }

#if DEBUG
private enum ResearchDebugFailure: Error { case debouncedEditLost, stagedReportChangedDraft, journalUnavailable, resumeStateNotRestored, stagedReportNotRestored, explicitInsertNotDelivered, oversizedReportWasAccepted, failedSaveReplacedJournal, journalPermissions, persistenceRetryWasNotBounded, copyDidNotReleasePendingTask, corruptJournalWasOverwritten, valyuJSONImportWasNotParsed, layoutUnavailable, layoutOutOfBounds, snapshotFailed }
#endif
