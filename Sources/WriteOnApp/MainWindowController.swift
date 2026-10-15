import AppKit
import UniformTypeIdentifiers
import WriteOnCore
import WriteOnAI

private final class TopAlignedInspectorStack: NSStackView {
    override var isFlipped: Bool { true }
}

private struct AcceptedReviewMark: Equatable {
    let action: AIAction
    let quote: String
    let reason: String
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSTextViewDelegate, NSControlTextEditingDelegate, NSTextFieldDelegate {
    private let documentUndoManager = UndoManager()
    private var draft: WritingDocument
    private var store: DocumentStore?
    private var recoveryDisabled = true
    private var recoveryProblem: String?
    private var hasUnsavedChanges = false
    private let recoveryFileURL: URL
    private var fileURL: URL?
    private let editor = DocumentTextView(frame: .zero)
    private let overflowEditor = NSTextView(frame: .zero)
    private let root = NSView()
    private let header = NSView()
    private let leftPane = NSView()
    private let leftScroll = NSScrollView()
    private let rightPane = NSView()
    private let editorScroll = NSScrollView()
    private let leftContent = NSView()
    private let rightContent = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let companyLinkButton = NSButton(title: "Compare the Cloud", target: nil, action: nil)
    private let cancelAIButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let wordCountButton = NSButton(title: "0 words", target: nil, action: nil)
    private let cleanButton = NSButton(title: "Clean read", target: nil, action: nil)
    private var cleanRead = false
    private var showAlternatives = true
    private var showOverflow = true
    private var theme = WriteOnTheme(rawValue: UserDefaults.standard.string(forKey: "WriteOn.theme") ?? "System") ?? .system
    private var palette = Palette.current()
    private var inspectedGroupID: UUID?
    private var contextRange: DraftRange?
    private var pendingSave: DispatchWorkItem?
    private var editorToLeftConstraint: NSLayoutConstraint?
    private var editorToRootConstraint: NSLayoutConstraint?
    private var editorToRightConstraint: NSLayoutConstraint?
    private var editorToRootTrailingConstraint: NSLayoutConstraint?
    private var documentRevision: UInt64 = 0
    private var reviewMarks: [AcceptedReviewMark] = []
    private var trimPreviewRanges: [DraftRange] = []
    private var popover: NSPopover?
    private var optionsController: AlternativesPopoverController?
    private weak var alternativesButton: NSButton?
    private var labController: LabWindowController?
    private var settingsController: SettingsWindowController?
    private var markdownPreviewController: MarkdownPreviewWindowController?
    private var researchController: ResearchWindowController?
    private var sharePicker: NSSharingServicePicker?
    private var aiTask: Task<Void, Never>?
    private var aiLifecycle = AIRequestLifecycle()
    private var aiRequestID: UUID?
    private var aiStartedAt: Date?
    private var aiProgressTimer: Timer?
    private let aiService = AIService()
    private var applyingUI = false
    private var nativeSpellDefaultsApplied = false
#if DEBUG
    var selfCheckSuppressAlerts = false
#endif

    init(recoveryDirectory: URL? = nil) {
        let recoveryDirectory = recoveryDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("DansWriter", isDirectory: true)
        recoveryFileURL = recoveryDirectory.appendingPathComponent("recovery.writeon")
        do {
            let loadedStore = try DocumentStore(directory: recoveryDirectory)
            store = loadedStore
            do {
                let recovered = try loadedStore.load()
                draft = recovered ?? WritingDocument.welcome
                hasUnsavedChanges = recovered != nil
                recoveryDisabled = false
            } catch {
                draft = WritingDocument.welcome
                recoveryProblem = "DansWriter could not read its recovery draft. It has been left untouched, and recovery saving is disabled until you choose Start Fresh. Details: \(error.localizedDescription)"
            }
        } catch {
            store = nil
            draft = WritingDocument.welcome
            recoveryProblem = "DansWriter could not open its recovery folder. Recovery saving is disabled. Details: \(error.localizedDescription)"
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 830), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DansWriter — \(draft.title)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 640)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildWindow()
        refreshAll()
    }

    required init?(coder: NSCoder) { nil }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        root.pinEdges(to: content)

        header.translatesAutoresizingMaskIntoConstraints = false
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        leftContent.translatesAutoresizingMaskIntoConstraints = false
        rightContent.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        companyLinkButton.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header); root.addSubview(leftPane); root.addSubview(rightPane); root.addSubview(editorScroll); root.addSubview(companyLinkButton); root.addSubview(statusLabel); root.addSubview(cancelAIButton)
        let leftWidth = leftPane.widthAnchor.constraint(equalToConstant: 218)
        let rightWidth = rightPane.widthAnchor.constraint(equalToConstant: 240)
        editorToLeftConstraint = editorScroll.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor)
        editorToRootConstraint = editorScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        editorToRightConstraint = editorScroll.trailingAnchor.constraint(equalTo: rightPane.leadingAnchor)
        editorToRootTrailingConstraint = editorScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 64),
            leftPane.leadingAnchor.constraint(equalTo: root.leadingAnchor), leftPane.topAnchor.constraint(equalTo: header.bottomAnchor), leftPane.bottomAnchor.constraint(equalTo: statusLabel.topAnchor), leftWidth,
            rightPane.trailingAnchor.constraint(equalTo: root.trailingAnchor), rightPane.topAnchor.constraint(equalTo: header.bottomAnchor), rightPane.bottomAnchor.constraint(equalTo: statusLabel.topAnchor), rightWidth,
            editorScroll.topAnchor.constraint(equalTo: header.bottomAnchor), editorScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),
            companyLinkButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), companyLinkButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor), companyLinkButton.widthAnchor.constraint(equalToConstant: 136),
            statusLabel.leadingAnchor.constraint(equalTo: companyLinkButton.trailingAnchor, constant: 12), statusLabel.trailingAnchor.constraint(equalTo: cancelAIButton.leadingAnchor, constant: -16), statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), statusLabel.heightAnchor.constraint(equalToConstant: 24),
            cancelAIButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), cancelAIButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor), cancelAIButton.widthAnchor.constraint(equalToConstant: 72)
        ])
        cancelAIButton.translatesAutoresizingMaskIntoConstraints = false
        cancelAIButton.bezelStyle = .rounded
        cancelAIButton.font = .systemFont(ofSize: 10, weight: .medium)
        cancelAIButton.target = self; cancelAIButton.action = #selector(cancelAIRequest(_:)); cancelAIButton.isHidden = true
        companyLinkButton.bezelStyle = .regularSquare
        companyLinkButton.isBordered = false
        companyLinkButton.font = .systemFont(ofSize: 10, weight: .medium)
        companyLinkButton.alignment = .left
        companyLinkButton.target = self
        companyLinkButton.action = #selector(openCompareTheCloud(_:))
        companyLinkButton.toolTip = "Open Compare the Cloud in your browser"
        companyLinkButton.setAccessibilityLabel("Compare the Cloud")
        companyLinkButton.setAccessibilityHelp("Opens the Compare the Cloud website in your browser")
        NSLayoutConstraint.activate([editorToLeftConstraint!, editorToRightConstraint!])

        buildHeader()
        buildSidebars()
        buildEditor()
        [header, leftPane, rightPane].forEach { $0.wantsLayer = true }
        editor.delegate = self
        overflowEditor.delegate = self
        editor.isRichText = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        overflowEditor.isAutomaticSpellingCorrectionEnabled = false
        overflowEditor.isContinuousSpellCheckingEnabled = true
        overflowEditor.isGrammarCheckingEnabled = true
        if NSSpellChecker.shared.availableLanguages.contains("en_GB") {
            NSSpellChecker.shared.automaticallyIdentifiesLanguages = false
            _ = NSSpellChecker.shared.setLanguage("en_GB")
        }
        editor.usesFindPanel = true
        editor.isIncrementalSearchingEnabled = true
        editor.textContainerInset = NSSize(width: 52, height: 70)
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.groupAtCharacter = { [weak self] index in self?.group(at: index) }
        editor.alternativesProvider = { [weak self] in self?.draft.alternatives ?? [] }
        editor.onHoverGroup = { [weak self] group in self?.inspect(group) }
        editor.onGroupClick = { [weak self] group, point in self?.showOptions(for: group, point: point) }
        editor.onCycleGroup = { [weak self] group, direction in self?.cycle(group, direction: direction) }
        editor.onDeleteAlternative = { [weak self] in self?.deleteSelectedAlternative() ?? false }
        editor.menuAtCharacter = { [weak self] index in self?.contextMenu(at: index) }
        wordCountButton.target = self; wordCountButton.action = #selector(toggleCleanRead(_:)); wordCountButton.bezelStyle = .regularSquare; wordCountButton.isBordered = false; wordCountButton.font = .monospacedSystemFont(ofSize: 10, weight: .medium); wordCountButton.contentTintColor = palette.muted; wordCountButton.toolTip = "Click to toggle clean reading view"
        overflowEditor.isRichText = false
        overflowEditor.allowsUndo = false
        overflowEditor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        overflowEditor.textContainerInset = NSSize(width: 0, height: 8)
    }

    private func buildHeader() {
        let p = palette
        let mark = UIStyle.label("D", size: 18, color: Ink.teal, weight: .bold, monospaced: true)
        let brand = UIStyle.label("DANSWRITER", size: 11, color: p.muted, weight: .bold)
        let dot = UIStyle.label("·", size: 16, color: p.muted)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = p.text
        let brandStack = NSStackView(views: [mark, brand, dot, titleLabel])
        brandStack.orientation = .horizontal; brandStack.alignment = .centerY; brandStack.spacing = 9
        brandStack.translatesAutoresizingMaskIntoConstraints = false
        brandStack.identifier = NSUserInterfaceItemIdentifier("brand-stack")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let alternatives = UIStyle.iconButton("text.quote", help: "Toggle alternatives", action: #selector(toggleAlternatives(_:)), target: self, palette: p)
        let overflow = UIStyle.iconButton("tray", help: "Toggle overflow", action: #selector(toggleOverflow(_:)), target: self, palette: p)
        cleanButton.bezelStyle = .rounded; cleanButton.font = .systemFont(ofSize: 11, weight: .medium); cleanButton.target = self; cleanButton.action = #selector(toggleCleanRead(_:))
        cleanButton.setButtonType(.toggle)
        let lab = UIStyle.button("Lab", action: #selector(showLab(_:)), target: self, palette: p)
        let research = UIStyle.button("Research", action: #selector(showResearch(_:)), target: self, palette: p)
        let preview = UIStyle.button("Preview", action: #selector(showMarkdownPreview(_:)), target: self, palette: p)
        let settings = UIStyle.iconButton("slider.horizontal.3", help: "Settings", action: #selector(showSettings(_:)), target: self, palette: p)
        let share = UIStyle.iconButton("square.and.arrow.up", help: "Share with a Mac app", action: #selector(openSystemShare(_:)), target: self, palette: p)
        let xDraft = NSButton(title: "X", target: self, action: #selector(openXDraft(_:)))
        xDraft.bezelStyle = .regularSquare; xDraft.isBordered = false; xDraft.font = .systemFont(ofSize: 11, weight: .bold); xDraft.contentTintColor = p.muted; xDraft.toolTip = "Open an X compose draft"
        let linkedin = NSButton(title: "in", target: self, action: #selector(openLinkedInDraft(_:)))
        linkedin.bezelStyle = .regularSquare; linkedin.isBordered = false; linkedin.font = .systemFont(ofSize: 11, weight: .bold); linkedin.contentTintColor = p.muted
        linkedin.toolTip = "Open LinkedIn with your text ready to review"
        let topButtons = NSStackView(views: [wordCountButton, alternatives, overflow, cleanButton, lab, preview, research, share, xDraft, linkedin, settings])
        topButtons.orientation = .horizontal; topButtons.alignment = .centerY; topButtons.spacing = 11
        topButtons.translatesAutoresizingMaskIntoConstraints = false
        topButtons.identifier = NSUserInterfaceItemIdentifier("header-buttons")
        header.addSubview(brandStack); header.addSubview(topButtons)
        NSLayoutConstraint.activate([
            brandStack.trailingAnchor.constraint(lessThanOrEqualTo: topButtons.leadingAnchor, constant: -12),
            brandStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 23), brandStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            topButtons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22), topButtons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            alternatives.widthAnchor.constraint(equalToConstant: 30), overflow.widthAnchor.constraint(equalToConstant: 30), settings.widthAnchor.constraint(equalToConstant: 30), share.widthAnchor.constraint(equalToConstant: 30), xDraft.widthAnchor.constraint(equalToConstant: 22), linkedin.widthAnchor.constraint(equalToConstant: 20)
        ])
    }

    private func buildSidebars() {
        let leftStack = TopAlignedInspectorStack()
        leftStack.orientation = .vertical; leftStack.alignment = .leading; leftStack.spacing = 0
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 14, right: 17)
        leftScroll.translatesAutoresizingMaskIntoConstraints = false; leftScroll.drawsBackground = false; leftScroll.hasVerticalScroller = true; leftScroll.hasHorizontalScroller = false; leftScroll.borderType = .noBorder
        leftPane.addSubview(leftScroll)
        leftScroll.pinEdges(to: leftPane)
        leftScroll.documentView = leftStack
        leftStack.widthAnchor.constraint(equalTo: leftScroll.contentView.widthAnchor).isActive = true
        leftStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        leftStack.identifier = NSUserInterfaceItemIdentifier("left-stack")

        let rightStack = NSStackView()
        rightStack.orientation = .vertical; rightStack.alignment = .leading; rightStack.spacing = 0
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(rightStack)
        rightStack.pinEdges(to: rightPane, insets: NSEdgeInsets(top: 20, left: 17, bottom: 14, right: 17))
        rightStack.identifier = NSUserInterfaceItemIdentifier("right-stack")

        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.borderType = .noBorder
        editorScroll.documentView = editor
    }

    private func buildEditor() {
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.documentView = editor
        editor.frame = NSRect(origin: .zero, size: editorScroll.contentView.bounds.size)
        editor.autoresizingMask = [.width]
        editorScroll.contentView.postsBoundsChangedNotifications = true
    }

    private func leftStack() -> NSStackView? { leftScroll.documentView as? NSStackView }
    private func rightStack() -> NSStackView? { rightPane.subviews.first(where: { $0.identifier?.rawValue == "right-stack" }) as? NSStackView }

    private func refreshAll(selection: NSRange? = nil) {
        applyingUI = true
        editor.string = draft.body
        let wanted = selection ?? NSRange(location: min(editor.selectedRange().location, (draft.body as NSString).length), length: 0)
        let bounded = NSRange(location: min(wanted.location, (draft.body as NSString).length), length: min(wanted.length, max(0, (draft.body as NSString).length - wanted.location)))
        editor.setSelectedRange(bounded)
        if overflowEditor.string != draft.overflow { overflowEditor.string = draft.overflow }
        applyingUI = false
        applyTheme()
        renderAnnotations()
        titleLabel.stringValue = draft.title
        window?.title = "DansWriter — \(draft.title)"
        cleanButton.state = cleanRead ? .on : .off
        cleanButton.title = cleanRead ? "Editing view" : "Clean read"
        updateStatusLabel()
        wordCountButton.title = "\(draft.wordCount) words"
        wordCountButton.contentTintColor = palette.muted
        companyLinkButton.attributedTitle = NSAttributedString(string: "Compare the Cloud", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: palette.muted,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = palette.muted
        statusLabel.alignment = .right
        buildLeftInspector()
        buildOverflowPane()
        markdownPreviewController?.update(body: draft.body, theme: theme)
        leftPane.isHidden = !showAlternatives
        rightPane.isHidden = !showOverflow
        if showAlternatives {
            editorToRootConstraint?.isActive = false; editorToLeftConstraint?.isActive = true
        } else {
            editorToLeftConstraint?.isActive = false; editorToRootConstraint?.isActive = true
        }
        if showOverflow {
            editorToRootTrailingConstraint?.isActive = false; editorToRightConstraint?.isActive = true
        } else {
            editorToRightConstraint?.isActive = false; editorToRootTrailingConstraint?.isActive = true
        }
    }

    private func applyTheme() {
        switch theme {
        case .system: window?.appearance = nil; NSApp.appearance = nil
        case .dark: window?.appearance = NSAppearance(named: .darkAqua); NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: window?.appearance = NSAppearance(named: .aqua); NSApp.appearance = NSAppearance(named: .aqua)
        }
        palette = Palette.current(window?.effectiveAppearance)
        root.layer?.backgroundColor = palette.canvas.cgColor
        header.layer?.backgroundColor = palette.canvas.cgColor
        leftPane.layer?.backgroundColor = palette.panel.cgColor
        rightPane.layer?.backgroundColor = palette.panel.cgColor
        editor.backgroundColor = palette.canvas
        editor.textColor = palette.text
        editor.insertionPointColor = Ink.teal
        titleLabel.textColor = palette.text
        wordCountButton.contentTintColor = palette.muted
        cleanButton.contentTintColor = palette.text
        if let topButtons = header.subviews.first(where: { $0.identifier?.rawValue == "header-buttons" }) {
            func refreshHeaderControls(_ view: NSView) {
                if let button = view as? NSButton, button !== cleanButton { button.contentTintColor = palette.muted }
                view.subviews.forEach(refreshHeaderControls)
            }
            refreshHeaderControls(topButtons)
        }
        editor.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        overflowEditor.backgroundColor = palette.panel
        overflowEditor.textColor = palette.text
    }

    private func renderAnnotations() {
        guard let storage = editor.textStorage else { return }
        let full = NSRange(location: 0, length: (draft.body as NSString).length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 17
        storage.beginEditing()
        if full.length > 0 { storage.setAttributes([.font: editor.font ?? .monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: palette.text, .paragraphStyle: paragraph], range: full) }
        applyMarkdownStyles(to: storage)
        editor.drawsAlternativeMarks = !cleanRead
        for ghost in draft.ghosts where isValid(ghost.range, in: draft.body) {
            storage.addAttribute(.foregroundColor, value: palette.text.withAlphaComponent(cleanRead ? 0.15 : 0.20), range: ghost.range.nsRange)
        }
        for range in trimPreviewRanges where isValid(range, in: draft.body) {
            storage.addAttribute(.foregroundColor, value: palette.text.withAlphaComponent(0.16), range: range.nsRange)
        }
        for mark in reviewMarks {
            guard let range = uniqueRange(of: mark.quote, in: draft.body), isValid(range, in: draft.body) else { continue }
            let tint = mark.action == .smoothness ? Ink.teal : Ink.amber
            storage.addAttribute(.backgroundColor, value: tint.withAlphaComponent(palette.isDark ? 0.22 : 0.15), range: range.nsRange)
        }
        if !cleanRead {
            for span in draft.pasteSpans where isValid(span.range, in: draft.body) {
                let tint = pasteTint(span.colour)
                storage.addAttribute(.backgroundColor, value: tint.withAlphaComponent(palette.isDark ? 0.25 : 0.16), range: span.range.nsRange)
                storage.addAttribute(.foregroundColor, value: pasteForeground(span.colour), range: span.range.nsRange)
            }
        }
        storage.endEditing()
        editor.typingAttributes = [.font: editor.font ?? .monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: palette.text, .paragraphStyle: paragraph]
    }

    private func applyMarkdownStyles(to storage: NSTextStorage) {
        let source = draft.body as NSString
        guard source.length > 0 else { return }
        let heading = try? NSRegularExpression(pattern: "(?m)^#{1,3} [^\\n]+")
        for match in heading?.matches(in: draft.body, range: NSRange(location: 0, length: source.length)) ?? [] {
            let line = source.substring(with: match.range)
            let level = line.prefix(while: { $0 == "#" }).count
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: CGFloat(max(18, 24 - level * 2)), weight: .semibold), range: match.range)
        }
        let bold = try? NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*")
        for match in bold?.matches(in: draft.body, range: NSRange(location: 0, length: source.length)) ?? [] {
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold), range: match.range)
        }
        let italic = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)[^*\\n]+\\*(?!\\*)")
        for match in italic?.matches(in: draft.body, range: NSRange(location: 0, length: source.length)) ?? [] {
            let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: match.range)
        }
    }

    private func buildLeftInspector() {
        guard let stack = leftStack() else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let eyebrow = UIStyle.label("THE ALTS SIDEBAR", size: 10, color: palette.muted, weight: .bold)
        let title = UIStyle.label("Working alternatives", size: 17, color: palette.text, weight: .semibold)
        let hint = UIStyle.label("Choose a phrase in your draft, then keep a few ways to say it close by.", size: 11, color: palette.muted)
        hint.maximumNumberOfLines = 3; hint.lineBreakMode = .byWordWrapping; hint.usesSingleLineMode = false
        stack.addArrangedSubview(eyebrow); stack.addArrangedSubview(spacer(8)); stack.addArrangedSubview(title); stack.addArrangedSubview(spacer(8)); stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35).isActive = true
        stack.addArrangedSubview(spacer(21)); stack.addArrangedSubview(UIStyle.hairline(palette)); stack.addArrangedSubview(spacer(15))
        let selection = editor.selectedRange()
        let exactGroup = draft.alternatives.first(where: { $0.range.nsRange == selection })
        let group = exactGroup ?? (selection.length > 0 ? group(covering: selection) : inspectedGroupID.flatMap(group(id:)))
        if let group {
            inspectedGroupID = group.id
            let current = UIStyle.label("CURRENT GROUP", size: 10, color: palette.muted, weight: .bold)
            let rangeText = (try? draft.text(in: group.range)) ?? "Selected phrase"
            let selection = UIStyle.label("“\(rangeText)”", size: 12, color: palette.text, weight: .medium, monospaced: true)
            selection.maximumNumberOfLines = 3; selection.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(current); stack.addArrangedSubview(spacer(6)); stack.addArrangedSubview(selection); stack.addArrangedSubview(spacer(12))
            selection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35).isActive = true
            for (index, option) in group.options.enumerated() {
                let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
                let marker = UIStyle.label(index == 0 ? "●" : "○", size: 9, color: option.source == .ai ? Ink.amber : Ink.teal, weight: .bold, monospaced: true)
                marker.translatesAutoresizingMaskIntoConstraints = false
                let icon = NSImageView(image: NSImage(systemSymbolName: option.source == .ai ? "sparkle" : "text.alignleft", accessibilityDescription: option.source.rawValue) ?? NSImage())
                icon.translatesAutoresizingMaskIntoConstraints = false; icon.contentTintColor = option.source == .ai ? Ink.amber : Ink.teal
                let text = NSButton(title: option.text, target: self, action: #selector(editInspectorOption(_:)))
                text.translatesAutoresizingMaskIntoConstraints = false
                text.bezelStyle = .regularSquare; text.isBordered = false; text.alignment = .left; text.font = .monospacedSystemFont(ofSize: 12, weight: index == group.selectedIndex ? .semibold : .regular); text.contentTintColor = palette.text; text.lineBreakMode = .byWordWrapping; text.cell?.wraps = true; text.cell?.isScrollable = false; text.identifier = NSUserInterfaceItemIdentifier(option.id.uuidString); text.toolTip = "Click to edit this choice"
                let use = NSButton(title: index == group.selectedIndex ? "✓" : "", target: self, action: #selector(chooseInspectorOption(_:)))
                use.translatesAutoresizingMaskIntoConstraints = false
                use.tag = index; use.bezelStyle = .regularSquare; use.isBordered = false; use.contentTintColor = Ink.teal
                use.setAccessibilityLabel("Use alternative \(index + 1)")
                let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove choice") ?? NSImage(), target: self, action: #selector(removeInspectorOption(_:)))
                remove.translatesAutoresizingMaskIntoConstraints = false
                remove.identifier = NSUserInterfaceItemIdentifier(option.id.uuidString)
                remove.bezelStyle = .regularSquare; remove.isBordered = false; remove.contentTintColor = palette.muted; remove.toolTip = "Remove this choice"
                row.addSubview(marker); row.addSubview(icon); row.addSubview(text); row.addSubview(use); if index > 0 { row.addSubview(remove) }
                stack.addArrangedSubview(row)
                let measuredStackWidth = stack.bounds.width > 0 ? stack.bounds.width : 218
                let textWidth = max(80, measuredStackWidth - 35 - 9 - 16 - 7 - 25 - (index > 0 ? 21 : 0) - 5)
                let measured = (option.text as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!]).height.rounded(.up)
                let rowHeight = max(27, measured + 4)
                NSLayoutConstraint.activate([
                    marker.leadingAnchor.constraint(equalTo: row.leadingAnchor), marker.centerYAnchor.constraint(equalTo: row.centerYAnchor), marker.widthAnchor.constraint(equalToConstant: 9),
                    icon.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 2), icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 4), icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), text.topAnchor.constraint(equalTo: row.topAnchor), text.bottomAnchor.constraint(equalTo: row.bottomAnchor), text.trailingAnchor.constraint(lessThanOrEqualTo: use.leadingAnchor, constant: -3),
                    use.trailingAnchor.constraint(equalTo: row.trailingAnchor), use.centerYAnchor.constraint(equalTo: row.centerYAnchor), use.widthAnchor.constraint(equalToConstant: 25),
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35), row.heightAnchor.constraint(equalToConstant: rowHeight)
                ])
                if index > 0 {
                    NSLayoutConstraint.activate([remove.trailingAnchor.constraint(equalTo: use.leadingAnchor, constant: -3), remove.centerYAnchor.constraint(equalTo: row.centerYAnchor), remove.widthAnchor.constraint(equalToConstant: 18), text.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -3)])
                }
                stack.addArrangedSubview(spacer(4))
            }
        } else {
            let noGroup = UIStyle.label("NO GROUP SELECTED", size: 10, color: palette.muted, weight: .bold)
            stack.addArrangedSubview(noGroup)
            stack.addArrangedSubview(spacer(7))
            let noGroupHint = UIStyle.label("Select a word, sentence, or paragraph to explore alternatives.", size: 11, color: palette.muted)
            noGroupHint.maximumNumberOfLines = 3; noGroupHint.usesSingleLineMode = false; noGroupHint.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(noGroupHint)
            noGroupHint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35).isActive = true
        }
        stack.addArrangedSubview(spacer(12))
        let field = NSTextField(string: "")
        field.placeholderString = "Add a choice · or type ??"
        field.font = .systemFont(ofSize: 11)
        field.textColor = palette.text
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier("alternative-entry")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(field)
        let add = UIStyle.button("Add choice", action: #selector(addInspectorAlternative(_:)), target: self, palette: palette)
        add.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer(6)); stack.addArrangedSubview(add)
        add.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35).isActive = true
        let ai = UIStyle.button("✦  Generate with AI", action: #selector(generateAlternatives(_:)), target: self, palette: palette, prominent: true)
        alternativesButton = ai
        ai.isEnabled = !aiLifecycle.isBusy
        ai.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(spacer(7)); stack.addArrangedSubview(ai); ai.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35).isActive = true
        stack.addArrangedSubview(spacer(16)); stack.addArrangedSubview(UIStyle.hairline(palette)); stack.addArrangedSubview(spacer(12))
        let lab = UIStyle.button("Open the Lab  ↗", action: #selector(showLab(_:)), target: self, palette: palette)
        lab.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(lab); lab.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35).isActive = true
    }

    private func buildOverflowPane() {
        guard let stack = rightStack() else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        stack.addArrangedSubview(UIStyle.label("OVERFLOW", size: 10, color: palette.muted, weight: .bold))
        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(UIStyle.label("Keep nearby", size: 17, color: palette.text, weight: .semibold))
        stack.addArrangedSubview(spacer(8))
        let hint = UIStyle.label("Useful lines that don’t belong in the draft yet.", size: 11, color: palette.muted)
        hint.maximumNumberOfLines = 2; hint.usesSingleLineMode = false; hint.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(hint); stack.addArrangedSubview(spacer(18)); stack.addArrangedSubview(UIStyle.hairline(palette)); stack.addArrangedSubview(spacer(12))
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.documentView = overflowEditor
        overflowEditor.frame = NSRect(origin: .zero, size: scroll.contentView.bounds.size)
        overflowEditor.autoresizingMask = [.width]
        overflowEditor.minSize = NSSize(width: 0, height: 400); overflowEditor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        overflowEditor.isVerticallyResizable = true; overflowEditor.isHorizontallyResizable = false; overflowEditor.textContainer?.widthTracksTextView = true
        stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(spacer(10))
        let stash = UIStyle.button("←  Stash selection", action: #selector(stashSelection(_:)), target: self, palette: palette)
        stash.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(stash)
        stash.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView(); view.translatesAutoresizingMaskIntoConstraints = false; view.heightAnchor.constraint(equalToConstant: height).isActive = true; return view
    }

    private func isValid(_ range: DraftRange, in text: String) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= (text as NSString).length && range.length <= (text as NSString).length - range.location
    }
    private func group(id: UUID) -> AlternativeGroup? { draft.alternatives.first(where: { $0.id == id }) }
    private func group(at index: Int) -> AlternativeGroup? { draft.alternatives.first(where: { index >= $0.range.location && index < $0.range.location + $0.range.length }) }
    private func group(covering selection: NSRange) -> AlternativeGroup? { draft.alternatives.first(where: { $0.range.nsRange == selection || NSLocationInRange(selection.location, $0.range.nsRange) }) }
    private func inspect(_ group: AlternativeGroup?) {
        guard let group else { return }
        inspectedGroupID = group.id
        buildLeftInspector()
    }

    private func showOptions(for group: AlternativeGroup, point: NSPoint) {
        inspectedGroupID = group.id
        buildLeftInspector()
        let controller = AlternativesPopoverController(group: group, palette: palette)
        controller.onChoose = { [weak self] index in self?.selectAlternative(group, index: index); self?.popover?.close() }
        controller.onAdd = { [weak self] in self?.popover?.close(); self?.promptForAlternative(group: group) }
        let pop = NSPopover()
        pop.behavior = .transient; pop.animates = true; pop.contentViewController = controller
        optionsController = controller; popover = pop
        pop.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: editor, preferredEdge: .maxX)
    }

    private func cycle(_ group: AlternativeGroup, direction: Int) {
        guard let group = self.group(id: group.id) else { return }
        let count = group.options.count
        guard count > 1 else { NSSound.beep(); return }
        let index = (group.selectedIndex + direction + count) % count
        selectAlternative(group, index: index)
        if UserDefaults.standard.bool(forKey: "WriteOn.sound") { NSSound(named: direction > 0 ? "Tink" : "Pop")?.play() }
    }

    private func selectAlternative(_ group: AlternativeGroup, index: Int) {
        mutateDocument("Choose alternative") { try $0.selectAlternative(groupID: group.id, index: index) }
        inspectedGroupID = group.id
        if let selected = self.group(id: group.id) { refreshAll(selection: selected.range.nsRange) }
    }

    private func deleteSelectedAlternative() -> Bool {
        let selection = editor.selectedRange()
        guard selection.length > 0,
              let group = draft.alternatives.first(where: { $0.range.nsRange == selection }),
              group.selectedIndex > 0, group.options.indices.contains(group.selectedIndex) else { return false }
        let option = group.options[group.selectedIndex]
        mutateDocument("Remove alternative") { try $0.removeAlternative(groupID: group.id, optionID: option.id) }
        playDeleteAccent()
        return true
    }

    private func contextMenu(at index: Int) -> NSMenu? {
        let clickedGroup = group(at: index)
        let currentSelection = editor.selectedRange()
        let clickedGhost = draft.ghosts.first(where: { index >= $0.range.location && index < $0.range.location + $0.range.length })
        let range = clickedGhost?.range ?? clickedGroup?.range ?? (currentSelection.length > 0 && NSLocationInRange(index, currentSelection) ? DraftRange(location: currentSelection.location, length: currentSelection.length) : wordRange(at: index))
        contextRange = range
        let menu = NSMenu()
        menu.addItem(menuItem("Select word", #selector(contextSelectWord(_:))))
        menu.addItem(menuItem("Select sentence", #selector(contextSelectSentence(_:))))
        menu.addItem(menuItem("Select paragraph", #selector(contextSelectParagraph(_:))))
        menu.addItem(.separator())
        menu.addItem(submenuItem("Paste as AI paste…", pasteColourMenu(operation: "paste-context")))
        if currentSelection.length > 0 {
            menu.addItem(submenuItem("Mark selection as AI paste…", pasteColourMenu(operation: "mark-paste")))
            menu.addItem(submenuItem("Change AI paste colour…", pasteColourMenu(operation: "recolour-paste")))
            menu.addItem(menuItem("Remove AI paste mark", #selector(clearPasteMark(_:))))
            menu.addItem(.separator())
        }
        if let clickedGroup {
            for (i, option) in clickedGroup.options.enumerated() {
                let item = NSMenuItem(title: "\(i == clickedGroup.selectedIndex ? "✓ " : "")\(option.text)", action: #selector(contextChoose(_:)), keyEquivalent: "")
                item.target = self; item.tag = i; item.representedObject = clickedGroup.id as NSUUID
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Make alternatives…", #selector(contextAddAlternatives(_:))))
        menu.addItem(menuItem("✦  Ask AI for alternatives", #selector(contextAIAlternatives(_:))))
        let existingGhost = clickedGhost != nil || draft.ghosts.contains(where: { $0.range == range })
        menu.addItem(menuItem(existingGhost ? "Revive this passage" : "Dim this passage", #selector(contextGhost(_:))))
        menu.addItem(menuItem("Move to overflow", #selector(contextStash(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("Proofread selection in Lab…", #selector(contextProofread(_:))))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; return item }
    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = submenu; return item }
    func pasteColourMenu(operation: String) -> NSMenu {
        let menu = NSMenu(title: "Paste colour")
        for colour in PasteColour.allCases {
            let item = NSMenuItem(title: "\(operation.hasPrefix("paste") ? "Paste as AI · " : operation == "mark-paste" ? "Mark as AI · " : "Set AI colour · ")\(colour.rawValue.capitalized)", action: #selector(pasteColourAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = colour.rawValue
            item.identifier = NSUserInterfaceItemIdentifier(operation)
            item.image = colourSwatch(for: colour)
            menu.addItem(item)
        }
        return menu
    }
    private func colourSwatch(for colour: PasteColour) -> NSImage {
        let tint = pasteTint(colour)
        let image = NSImage(size: NSSize(width: 13, height: 13))
        image.lockFocus(); tint.setFill(); NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 11, height: 11)).fill(); image.unlockFocus()
        return image
    }
    private func pasteTint(_ colour: PasteColour) -> NSColor {
        switch colour {
        case .teal: return NSColor(calibratedRed: 0.18, green: 0.55, blue: 0.49, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.30, green: 0.49, blue: 0.75, alpha: 1)
        case .amber: return NSColor(calibratedRed: 0.76, green: 0.49, blue: 0.18, alpha: 1)
        case .coral: return NSColor(calibratedRed: 0.79, green: 0.36, blue: 0.32, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.31, green: 0.55, blue: 0.34, alpha: 1)
        }
    }
    private func pasteForeground(_ colour: PasteColour) -> NSColor {
        if palette.isDark {
            switch colour {
            case .teal: return NSColor(calibratedRed: 0.63, green: 0.87, blue: 0.82, alpha: 1)
            case .blue: return NSColor(calibratedRed: 0.66, green: 0.79, blue: 0.98, alpha: 1)
            case .amber: return NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.55, alpha: 1)
            case .coral: return NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.66, alpha: 1)
            case .green: return NSColor(calibratedRed: 0.68, green: 0.85, blue: 0.66, alpha: 1)
            }
        } else {
            switch colour {
            case .teal: return NSColor(calibratedRed: 0.07, green: 0.34, blue: 0.31, alpha: 1)
            case .blue: return NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.57, alpha: 1)
            case .amber: return NSColor(calibratedRed: 0.48, green: 0.29, blue: 0.07, alpha: 1)
            case .coral: return NSColor(calibratedRed: 0.52, green: 0.20, blue: 0.17, alpha: 1)
            case .green: return NSColor(calibratedRed: 0.22, green: 0.39, blue: 0.21, alpha: 1)
            }
        }
    }
    private func wordRange(at index: Int) -> DraftRange {
        let ns = draft.body as NSString
        guard ns.length > 0 else { return DraftRange(location: 0, length: 0) }
        let safe = min(max(0, index), ns.length - 1)
        var found = NSRange(location: safe, length: 1)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, stop in
            if NSLocationInRange(safe, range) { found = range; stop.pointee = true }
        }
        return DraftRange(location: found.location, length: found.length)
    }

    private func selectedRangeOr(_ fallback: DraftRange? = nil) -> DraftRange? {
        let selection = editor.selectedRange()
        if selection.length > 0 { return DraftRange(location: selection.location, length: selection.length) }
        return fallback
    }

    @objc private func contextSelectWord(_ sender: Any?) { expandSelection(level: .word) }
    @objc private func contextSelectSentence(_ sender: Any?) { expandSelection(level: .sentence) }
    @objc private func contextSelectParagraph(_ sender: Any?) { expandSelection(level: .paragraph) }

    @objc private func pasteColourAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let colour = PasteColour(rawValue: raw) else { return }
        let operation = sender.identifier?.rawValue ?? "paste-edit"
        if operation.hasPrefix("paste") {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                showError("No plain text to paste", detail: "Copy text first, then choose a colour under Paste As."); return
            }
            let range = operation == "paste-context" ? (selectedRangeOr(contextRange) ?? DraftRange(location: editor.selectedRange().location, length: 0)) : DraftRange(location: editor.selectedRange().location, length: editor.selectedRange().length)
            _ = applyPasteAs(text, range: range, colour: colour)
        } else {
            let range = selectedRangeOr(contextRange)
            guard let range, range.length > 0 else { showError("Select text first", detail: "Choose the passage you want to track as an AI paste."); return }
            _ = setPasteColour(range, colour: colour)
        }
    }

    @discardableResult private func applyPasteAs(_ text: String, range: DraftRange, colour: PasteColour) -> Bool {
        guard range.location >= 0, range.location + range.length <= (draft.body as NSString).length else { return false }
        let insertedLength = (text as NSString).length
        let success = mutateDocument("Paste as AI · \(colour.rawValue.capitalized)") { try $0.paste(range: range, with: text, colour: colour) }
        if success { editor.setSelectedRange(NSRange(location: range.location + insertedLength, length: 0)); editor.window?.makeFirstResponder(editor) }
        return success
    }

    @discardableResult private func setPasteColour(_ range: DraftRange, colour: PasteColour?) -> Bool {
        let updated = mutateDocument(colour == nil ? "Remove AI paste mark" : "Change AI paste colour") { try $0.setPasteColour(range: range, colour: colour) }
        return updated
    }

    @objc func clearPasteMark(_ sender: Any?) {
        guard let range = selectedRangeOr(contextRange), range.length > 0 else { showError("Select marked text first", detail: "Choose the passage whose AI paste mark you want to remove."); return }
        _ = setPasteColour(range, colour: nil)
    }

    private enum SelectionLevel { case word, sentence, paragraph }
    private func expandSelection(level: SelectionLevel) {
        let current = editor.selectedRange()
        let index = current.length > 0 ? current.location : contextRange?.location ?? current.location
        let ns = draft.body as NSString
        guard ns.length > 0 else { return }
        switch level {
        case .word:
            let range = wordRange(at: index); editor.setSelectedRange(range.nsRange)
        case .sentence:
            let safe = min(max(0, index), ns.length - 1)
            let separators = CharacterSet(charactersIn: ".!?\n")
            var start = safe, end = safe
            while start > 0 && !isSentenceSeparator(ns.character(at: start - 1), set: separators) { start -= 1 }
            while end < ns.length && !isSentenceSeparator(ns.character(at: end), set: separators) { end += 1 }
            if end < ns.length && ns.character(at: end) != 10 { end += 1 }
            while start < end && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: start)) ?? " ") { start += 1 }
            editor.setSelectedRange(NSRange(location: start, length: end - start))
        case .paragraph:
            let safe = min(max(0, index), ns.length - 1)
            let start = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: safe)).location
            let lineStart = start == NSNotFound ? 0 : start + 1
            let tail = ns.range(of: "\n", options: [], range: NSRange(location: safe, length: ns.length - safe)).location
        let endPosition = tail == NSNotFound ? ns.length : tail
            let paragraphLength: Int = Swift.max(0, endPosition - lineStart)
            editor.setSelectedRange(NSRange(location: lineStart, length: paragraphLength))
        }
        editor.window?.makeFirstResponder(editor)
    }
    private func isSentenceSeparator(_ codeUnit: unichar, set: CharacterSet) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return set.contains(scalar)
    }

    @discardableResult private func mutateDocument(_ name: String, _ mutation: (inout WritingDocument) throws -> Void) -> Bool {
        let before = draft
        let beforeMarks = reviewMarks
        do { try mutation(&draft); try draft.validate() }
        catch { draft = before; showError("The change could not be applied", detail: "Check the selected passage and try again."); return false }
        registerUndo(before, name: name, reviewSnapshot: beforeMarks)
        documentRevision &+= 1
        hasUnsavedChanges = true
        trimPreviewRanges = []
        refreshAll(selection: editor.selectedRange())
        scheduleAutosave()
        return true
    }

    private func registerUndo(_ snapshot: WritingDocument, name: String, reviewSnapshot: [AcceptedReviewMark]? = nil) {
        guard let undoManager = window?.undoManager else { return }
        let marks = reviewSnapshot ?? reviewMarks
        undoManager.registerUndo(withTarget: self) { controller in controller.restore(snapshot, reviewMarks: marks) }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: WritingDocument, reviewMarks snapshotMarks: [AcceptedReviewMark]) {
        let current = draft
        let currentMarks = reviewMarks
        draft = snapshot
        reviewMarks = snapshotMarks
        documentRevision &+= 1
        hasUnsavedChanges = true
        guard let undoManager = window?.undoManager else { refreshAll(); scheduleAutosave(); return }
        undoManager.registerUndo(withTarget: self) { controller in controller.restore(current, reviewMarks: currentMarks) }
        undoManager.setActionName("Change")
        refreshAll(); scheduleAutosave()
    }

    func textDidChange(_ notification: Notification) {
        guard !applyingUI, let textView = notification.object as? NSTextView else { return }
        if textView === overflowEditor {
            let before = draft
            let beforeMarks = reviewMarks
            draft.overflow = overflowEditor.string
            do { try draft.validate() }
            catch {
                draft = before; applyingUI = true; overflowEditor.string = before.overflow; applyingUI = false
                showError("The note is too large", detail: "The previous note was restored."); return
            }
            registerUndo(before, name: "Edit overflow", reviewSnapshot: beforeMarks)
            documentRevision &+= 1
            hasUnsavedChanges = true
            scheduleAutosave(); return
        }
        guard textView === editor else { return }
        let old = draft.body
        let new = editor.string
        guard old != new else { return }
        let (range, replacement) = textDiff(old, new)
        let before = draft
        let beforeMarks = reviewMarks
        do { try draft.replace(range: range, with: replacement); try draft.validate() }
        catch {
            draft = before
            applyingUI = true; editor.string = old; applyingUI = false
            showError("The edit could not be applied", detail: "The draft was restored to its last consistent state.")
            return
        }
        documentRevision &+= 1
        hasUnsavedChanges = true
        trimPreviewRanges = []
        reviewMarks.removeAll { uniqueRange(of: $0.quote, in: draft.body) == nil }
        registerUndo(before, name: "Edit text", reviewSnapshot: beforeMarks)
        renderAnnotations(); titleLabel.stringValue = draft.title
        updateStatusLabel()
        wordCountButton.title = "\(draft.wordCount) words"
        scheduleAutosave()
        markdownPreviewController?.update(body: draft.body)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard textView === editor || textView === overflowEditor,
              let event = NSApp.currentEvent,
              TypewriterSoundPolicy.shouldPlay(eventType: event.type, modifiers: event.modifierFlags) else { return true }
        TypewriterSoundPlayer.shared.playIfEnabled()
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard (notification.object as? NSTextView) === editor, !applyingUI else { return }
        if let group = group(covering: editor.selectedRange()) { inspectedGroupID = group.id; buildLeftInspector() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.identifier?.rawValue == "alternative-entry" else { return }
        addTextFieldAlternative(field)
    }

    private func textDiff(_ old: String, _ new: String) -> (DraftRange, String) {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let location = String(a.prefix(prefix)).utf16.count
        let oldLength = String(a[prefix..<(a.count - suffix)]).utf16.count
        let replacement = String(b[prefix..<(b.count - suffix)])
        return (DraftRange(location: location, length: oldLength), replacement)
    }

    private func effectiveAlternativeRange() -> DraftRange? {
        let selection = editor.selectedRange()
        if selection.length > 0 { return DraftRange(location: selection.location, length: selection.length) }
        return inspectedGroupID.flatMap(group(id:))?.range
    }

    private func selectedEditorRange() -> DraftRange? {
        let selection = editor.selectedRange()
        guard selection.length > 0, selection.location >= 0,
              NSMaxRange(selection) <= (draft.body as NSString).length else { return nil }
        return DraftRange(location: selection.location, length: selection.length)
    }

    private func addTextFieldAlternative(_ field: NSTextField) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text == "??" { field.stringValue = ""; generateAlternatives(nil); return }
        guard let range = effectiveAlternativeRange() else { showError("Select a phrase first", detail: "Choose text in the draft before adding an alternative."); return }
        mutateDocument("Add alternative") { _ = try $0.addAlternatives(range: range, texts: [text], source: .human) }
        field.stringValue = ""
    }

    @objc private func addInspectorAlternative(_ sender: Any?) {
        guard let field = leftStack()?.views.first(where: { $0.identifier?.rawValue == "alternative-entry" }) as? NSTextField else { return }
        addTextFieldAlternative(field)
    }

    @objc private func chooseInspectorOption(_ sender: NSButton) {
        guard let group = inspectedGroupID.flatMap(group(id:)) else { return }
        selectAlternative(group, index: sender.tag)
    }

    @objc private func removeInspectorOption(_ sender: NSButton) {
        guard let group = inspectedGroupID.flatMap(group(id:)), let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        mutateDocument("Remove alternative") { try $0.removeAlternative(groupID: group.id, optionID: id) }
        playDeleteAccent()
    }

    @objc private func editInspectorOption(_ sender: NSButton) {
        guard let group = inspectedGroupID.flatMap(group(id:)), let raw = sender.identifier?.rawValue, let optionID = UUID(uuidString: raw),
              let groupIndex = draft.alternatives.firstIndex(where: { $0.id == group.id }),
              let optionIndex = draft.alternatives[groupIndex].options.firstIndex(where: { $0.id == optionID }) else { return }
        guard optionIndex > 0 else { showError("The original choice stays available", detail: "Add another alternative to create an editable choice."); return }
        let alert = NSAlert(); alert.messageText = "Edit this choice"; alert.informativeText = "The original choice remains available."; alert.addButton(withTitle: "Save Choice"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 310, height: 26)); field.stringValue = draft.alternatives[groupIndex].options[optionIndex].text; alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); guard !updated.isEmpty else { return }
        _ = setAlternativeText(groupID: group.id, optionID: optionID, text: updated)
    }

    @discardableResult private func setAlternativeText(groupID: UUID, optionID: UUID, text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let gi = draft.alternatives.firstIndex(where: { $0.id == groupID }),
              let oi = draft.alternatives[gi].options.firstIndex(where: { $0.id == optionID }), oi > 0 else { return false }
        return mutateDocument("Edit alternative") { value in
            guard let index = value.alternatives.firstIndex(where: { $0.id == groupID }),
                  let optionIndex = value.alternatives[index].options.firstIndex(where: { $0.id == optionID }), optionIndex > 0 else { throw WritingDocumentError.invalidAlternativeIndex }
            if value.alternatives[index].selectedIndex == optionIndex {
                var old = value.alternatives[index]
                try value.replace(range: old.range, with: text)
                old.options[optionIndex].text = text
                old.range.length = (text as NSString).length
                value.alternatives.append(old); value.alternatives.sort { $0.range.location < $1.range.location }
            } else { value.alternatives[index].options[optionIndex].text = text }
        }
    }

    @objc private func contextChoose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? UUID, let group = group(id: raw) else { return }
        selectAlternative(group, index: sender.tag)
    }
    @objc private func contextAddAlternatives(_ sender: Any?) {
        guard let contextRange else { return }
        let alert = NSAlert(); alert.messageText = "Add an alternative"; alert.informativeText = "Keep the original and add another way to say this passage."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24)); alert.accessoryView = field; alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        mutateDocument("Add alternative") { _ = try $0.addAlternatives(range: contextRange, texts: [value], source: .human) }
    }
    @objc private func contextAIAlternatives(_ sender: Any?) { if let contextRange { inspectedGroupID = group(covering: contextRange.nsRange)?.id; requestAlternatives(range: contextRange) } }
    @objc private func contextGhost(_ sender: Any?) {
        guard let range = contextRange else { return }
        if draft.ghosts.contains(where: { $0.range == range }) { mutateDocument("Revive passage") { $0.revive(range: range) } }
        else { mutateDocument("Dim passage") { try $0.ghost(range: range) }; playDeleteAccent() }
    }
    @objc private func contextStash(_ sender: Any?) { guard let range = contextRange else { return }; mutateDocument("Move to overflow") { try $0.stash(range: range) } }
    @objc private func contextProofread(_ sender: Any?) {
        guard selectContextForProofread() else { return }
        showLab(nil, initialAction: .proofread)
    }

    private func selectContextForProofread() -> Bool {
        guard let range = contextRange, range.location >= 0, range.length > 0,
              NSMaxRange(range.nsRange) <= (editor.string as NSString).length else { return false }
        editor.setSelectedRange(range.nsRange)
        inspectedGroupID = group(covering: range.nsRange)?.id
        return true
    }

    @objc func toggleAlternatives(_ sender: Any?) { showAlternatives.toggle(); refreshAll() }
    @objc func toggleOverflow(_ sender: Any?) { showOverflow.toggle(); refreshAll() }
    @objc func toggleCleanRead(_ sender: Any?) { cleanRead.toggle(); refreshAll(selection: editor.selectedRange()) }
    @objc func undoEdit(_ sender: Any?) { window?.undoManager?.undo() }
    @objc func redoEdit(_ sender: Any?) { window?.undoManager?.redo() }
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "Keyboard shortcuts"; alert.informativeText = "⌘N New draft     ⌘O Open     ⌘S Save\n⌘Z Undo     ⇧⌘Z Redo     ⌘F Find\n⌘1 Alternatives     ⌘2 Overflow     ⌘K Clean read     ⌘L Lab\n⌘P Markdown Preview     ⌘R Research with Valyu\nArrow keys cycle alternatives while the pointer is over an underlined phrase. Delete removes the selected non-original choice."
        alert.addButton(withTitle: "Done"); alert.runModal()
    }
    @objc func showSettings(_ sender: Any?) {
        settingsController = SettingsWindowController(initialTheme: theme) { [weak self] newTheme in
            self?.theme = newTheme; UserDefaults.standard.set(newTheme.rawValue, forKey: "WriteOn.theme"); self?.refreshAll()
        } onTypewriterSound: { enabled in if !enabled { TypewriterSoundPlayer.shared.stop() } }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    func canQuitWhileResearchStarts() -> Bool {
        if researchController?.hasPendingCreation == true {
            showError("Research is still starting", detail: "Wait for Valyu to return its task ID. If the local save fails, use Copy task ID in Research before quitting.")
            return false
        }
        guard researchController?.flushReportChanges() != false else {
            showError("Research edits could not be saved", detail: "Export or copy the staged report before quitting, or make the local research journal writable and try again.")
            return false
        }
        return true
    }

    @objc func showResearch(_ sender: Any?) {
        if researchController == nil {
            researchController = ResearchWindowController(initialTheme: theme) { [weak self] text, destination in
                self?.insertResearch(text, destination: destination) ?? false
            }
        }
        researchController?.update(theme: theme)
        researchController?.showWindow(nil)
        researchController?.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult private func insertResearch(_ text: String, destination: ResearchDestination) -> Bool {
        guard window?.isVisible == true, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return mutateDocument(destination == .draft ? "Append research" : "Research to overflow") { document in
            switch destination {
            case .draft:
                let addition = (document.body.isEmpty ? "" : "\n\n") + text
                try document.paste(range: DraftRange(location: (document.body as NSString).length, length: 0), with: addition, colour: .teal)
            case .overflow:
                document.overflow += (document.overflow.isEmpty ? "" : "\n\n") + text
                document.modifiedAt = Date()
            }
        }
    }

    @objc func showMarkdownPreview(_ sender: Any?) {
        if markdownPreviewController == nil {
            let controller = MarkdownPreviewWindowController(theme: theme)
            markdownPreviewController = controller
            controller.window?.delegate = controller
        }
        markdownPreviewController?.update(body: draft.body, theme: theme)
        markdownPreviewController?.showWindow(nil)
        markdownPreviewController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSpellingPanel(_ sender: Any?) {
        window?.makeFirstResponder(editor)
        editor.showGuessPanel(sender)
    }

    @objc func checkSpellingNow(_ sender: Any?) {
        window?.makeFirstResponder(editor)
        editor.checkSpelling(sender)
    }

    @objc func toggleContinuousSpellChecking(_ sender: Any?) {
        let enabled = !editor.isContinuousSpellCheckingEnabled
        editor.isContinuousSpellCheckingEnabled = enabled
        overflowEditor.isContinuousSpellCheckingEnabled = enabled
    }

    @objc func toggleGrammarChecking(_ sender: Any?) {
        let enabled = !editor.isGrammarCheckingEnabled
        editor.isGrammarCheckingEnabled = enabled
        overflowEditor.isGrammarCheckingEnabled = enabled
    }

    @objc func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        let enabled = !editor.isAutomaticSpellingCorrectionEnabled
        editor.isAutomaticSpellingCorrectionEnabled = enabled
        overflowEditor.isAutomaticSpellingCorrectionEnabled = enabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if aiLifecycle.isBusy && (menuItem.action == #selector(generateAlternatives(_:)) || menuItem.action == #selector(contextAIAlternatives(_:))) { return false }
        switch menuItem.action {
        case #selector(toggleContinuousSpellChecking(_:)): menuItem.state = editor.isContinuousSpellCheckingEnabled ? .on : .off
        case #selector(toggleGrammarChecking(_:)): menuItem.state = editor.isGrammarCheckingEnabled ? .on : .off
        case #selector(toggleAutomaticSpellingCorrection(_:)): menuItem.state = editor.isAutomaticSpellingCorrectionEnabled ? .on : .off
        default: break
        }
        return true
    }

    private func configureNativeSpellDefaultsOnce() {
        guard !nativeSpellDefaultsApplied else { return }
        let spellingAndGrammar = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        editor.enabledTextCheckingTypes |= spellingAndGrammar
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        overflowEditor.enabledTextCheckingTypes |= spellingAndGrammar
        overflowEditor.isContinuousSpellCheckingEnabled = true
        overflowEditor.isGrammarCheckingEnabled = true
        overflowEditor.isAutomaticSpellingCorrectionEnabled = false
        nativeSpellDefaultsApplied = true
    }

    @objc func showLab(_ sender: Any?) { showLab(sender, initialAction: nil) }
    private func showLab(_ sender: Any?, initialAction: AIAction?) {
        if labController == nil { labController = LabWindowController(initialTheme: theme, service: aiService, documentProvider: { [weak self] in self?.draft ?? WritingDocument() }, revisionProvider: { [weak self] in self?.documentRevision ?? 0 }, selectedRangeProvider: { [weak self] in self?.selectedEditorRange() }, acceptance: { [weak self] suggestion in self?.acceptSuggestion(suggestion) ?? false }, markAcceptance: { [weak self] suggestion, action in self?.acceptReviewMark(suggestion, action: action) ?? false }, trimAcceptance: { [weak self] suggestions in self?.acceptCuts(suggestions) ?? false }, trimPreview: { [weak self] suggestions in self?.setTrimPreview(suggestions) }) }
        labController?.showWindow(nil)
        labController?.window?.makeKeyAndOrderFront(nil)
        if let initialAction { labController?.start(initialAction) }
    }

    @objc private func generateAlternatives(_ sender: Any?) {
        guard let range = effectiveAlternativeRange() else { showError("Select a phrase first", detail: "Select text in your draft, then generate alternatives."); return }
        requestAlternatives(range: range)
    }

    private func requestAlternatives(range: DraftRange) {
        guard !aiLifecycle.isBusy, let selected = try? draft.text(in: range), let thisRequest = beginAlternativesRequest() else { return }
        let beforeID = draft.id
        let beforeBody = draft.body
        let beforeRevision = documentRevision
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.aiService.generate(AIRequest(action: .alternatives, document: beforeBody, selection: selected), configuration: AIConfiguration.load())
                await MainActor.run {
                    guard self.finishAlternativesRequest(thisRequest) else { return }
                    guard self.draft.id == beforeID, self.draft.body == beforeBody, self.documentRevision == beforeRevision, let current = try? self.draft.text(in: range), current == selected else {
                        self.showError("The draft changed while suggestions were being prepared", detail: "Nothing was applied. Select the passage and try again."); return
                    }
                    guard !result.alternatives.isEmpty else { self.showError("No alternatives returned", detail: "Try a shorter passage or another provider setting."); return }
                    self.mutateDocument("Add AI alternatives") { _ = try $0.addAlternatives(range: range, texts: result.alternatives, source: .ai) }
                }
            } catch {
                await MainActor.run {
                    guard self.finishAlternativesRequest(thisRequest), !Task.isCancelled else { return }
                    self.showError("AI suggestions weren’t available", detail: error.localizedDescription)
                }
            }
        }
        aiTask = task
    }

    private func beginAlternativesRequest() -> UUID? {
        guard let requestID = aiLifecycle.begin() else { return nil }
        aiRequestID = requestID
        aiStartedAt = Date()
        cancelAIButton.isHidden = false
        alternativesButton?.isEnabled = false
        updateAlternativesProgress()
        aiProgressTimer?.invalidate()
        aiProgressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateAlternativesProgress()
        }
        return requestID
    }

    @discardableResult private func finishAlternativesRequest(_ requestID: UUID) -> Bool {
        guard aiLifecycle.finish(requestID) else { return false }
        aiRequestID = nil
        aiTask = nil
        aiStartedAt = nil
        aiProgressTimer?.invalidate(); aiProgressTimer = nil
        cancelAIButton.isHidden = true
        alternativesButton?.isEnabled = true
        updateStatusLabel()
        return true
    }

    private func updateAlternativesProgress() {
        guard aiLifecycle.isBusy, let started = aiStartedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(started)))
        statusLabel.stringValue = "Generating alternatives · \(elapsed)s"
    }

    private func updateStatusLabel() {
        if aiLifecycle.isBusy { updateAlternativesProgress(); return }
        statusLabel.stringValue = "\(draft.wordCount) words     \(draft.alternatives.count) alternatives     \(draft.ghosts.count) dimmed"
    }

    private func cancelAlternativesRequest(_ requestID: UUID) {
        guard aiLifecycle.isCurrent(requestID) else { return }
        aiLifecycle.cancel(requestID)
        aiRequestID = nil
        aiStartedAt = nil
        aiProgressTimer?.invalidate(); aiProgressTimer = nil
        cancelAIButton.isHidden = true
        alternativesButton?.isEnabled = true
        let task = aiTask
        aiTask = nil
        task?.cancel()
        updateStatusLabel()
    }

    private func cancelActiveAlternativesRequest() {
        if let aiRequestID { cancelAlternativesRequest(aiRequestID) }
        else { aiTask?.cancel(); aiTask = nil; aiProgressTimer?.invalidate(); aiProgressTimer = nil; cancelAIButton.isHidden = true; alternativesButton?.isEnabled = true }
    }

    @objc private func cancelAIRequest(_ sender: Any?) {
        guard let aiRequestID else { return }
        cancelAlternativesRequest(aiRequestID)
    }

    private func acceptSuggestion(_ suggestion: AISuggestion) -> Bool {
        guard let range = uniqueRange(of: suggestion.quote, in: draft.body) else { showError("The quoted text has changed", detail: "Nothing was changed. Run the Lab again on the current draft."); return false }
        guard let replacement = suggestion.replacement else { return false }
        return mutateDocument("Accept Lab suggestion") { try $0.replace(range: range, with: replacement) }
    }

    private func acceptCuts(_ suggestions: [AISuggestion]) -> Bool {
        let ranges = suggestions.compactMap { uniqueRange(of: $0.quote, in: draft.body) }
        guard ranges.count == suggestions.count else { showError("Some suggested cuts no longer match", detail: "Nothing was cut. Run the Lab again on the current draft."); return false }
        let applied = mutateDocument("Accept trim suggestions") { try $0.applyCuts(ranges) }
        guard applied else { return false }
        playDeleteAccent()
        return true
    }

    private func setTrimPreview(_ suggestions: [AISuggestion]?) {
        trimPreviewRanges = (suggestions ?? []).compactMap { uniqueRange(of: $0.quote, in: draft.body) }
        renderAnnotations()
    }

    private func acceptReviewMark(_ suggestion: AISuggestion, action: AIAction) -> Bool {
        guard uniqueRange(of: suggestion.quote, in: draft.body) != nil else { showError("The quoted text has changed", detail: "Nothing was marked. Run the Lab again on the current draft."); return false }
        let previous = reviewMarks
        reviewMarks.removeAll { $0.quote == suggestion.quote }
        reviewMarks.append(AcceptedReviewMark(action: action, quote: suggestion.quote, reason: suggestion.reason))
        documentRevision &+= 1
        registerUndo(draft, name: "Mark passage", reviewSnapshot: previous)
        renderAnnotations(); scheduleAutosave()
        return true
    }

    private func uniqueRange(of quote: String, in text: String) -> DraftRange? {
        guard let range = text.range(of: quote), text.range(of: quote, range: range.upperBound..<text.endIndex) == nil else { return nil }
        let location = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound.samePosition(in: text.utf16)!)
        return DraftRange(location: location, length: quote.utf16.count)
    }

    private func playDeleteAccent() {
        if UserDefaults.standard.bool(forKey: "WriteOn.sound") {
            NSSound(named: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "Tink" : "Pop")?.play()
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        root.wantsLayer = true
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = NSPoint(x: root.bounds.midX, y: root.bounds.midY)
        if let range = selectedRangeOr(), let layout = editor.layoutManager, let container = editor.textContainer {
            let glyphRange = layout.glyphRange(forCharacterRange: range.nsRange, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            emitter.emitterPosition = editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: root)
        }
        emitter.emitterShape = .point; emitter.emitterMode = .outline
        let colors = [Ink.teal.cgColor, Ink.amber.cgColor, palette.text.withAlphaComponent(0.85).cgColor]
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell(); cell.birthRate = 0; cell.lifetime = 0.85; cell.velocity = 75; cell.velocityRange = 42; cell.yAcceleration = -95; cell.emissionRange = .pi * 2; cell.scale = 0.055; cell.scaleRange = 0.035; cell.alphaSpeed = -1.1; cell.color = color; cell.contents = particleImage()?.cgImage; cell.name = "burst"; return cell
        }
        root.layer?.addSublayer(emitter)
        emitter.setValue(16, forKeyPath: "emitterCells.burst.birthRate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { emitter.setValue(0, forKeyPath: "emitterCells.burst.birthRate") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { emitter.removeFromSuperlayer() }
    }

    private func particleImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 6, height: 6)); image.lockFocus(); NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 6, height: 6)).fill(); image.unlockFocus(); return image
    }

    @objc private func openXDraft(_ sender: Any?) {
        guard let text = selectedOrFullDraftText() else { showError("There is no text to share", detail: "Write something first, or select the passage you want to share."); return }
        guard let url = xDraftURL(text: text), NSWorkspace.shared.open(url) else { showError("Couldn’t open a share draft", detail: "Check that a browser is available and try again."); return }
    }

    @objc func openSystemShare(_ sender: NSButton) {
        guard let text = selectedOrFullDraftText() else { showError("There is no text to share", detail: "Write something first, or select the passage you want to share."); return }
        let picker = NSSharingServicePicker(items: [text])
        sharePicker = picker
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func selectedOrFullDraftText() -> String? {
        let selection = editor.selectedRange()
        if selection.length > 0 {
            guard selection.location >= 0, NSMaxRange(selection) <= (draft.body as NSString).length else { return nil }
            return (draft.body as NSString).substring(with: selection)
        }
        return draft.body.isEmpty ? nil : draft.body
    }

    private func xDraftURL(text: String) -> URL? {
        var components = URLComponents(string: "https://twitter.com/intent/tweet")
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        return components?.url
    }

    private func linkedInComposeURL(text: String) -> URL? {
        var components = URLComponents(string: "https://www.linkedin.com/feed/")
        components?.queryItems = [URLQueryItem(name: "shareActive", value: "true"), URLQueryItem(name: "text", value: text)]
        // Encode literal plus signs as well, for query decoders using form semantics.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    private func copyShareText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @objc private func openLinkedInDraft(_ sender: Any?) {
        guard let text = selectedOrFullDraftText() else { showError("There is no text to share", detail: "Write something first, or select the passage you want to share."); return }
        guard copyShareText(text, to: .general) else { showError("Couldn’t copy the draft", detail: "Check clipboard access and try again."); return }
        guard let url = linkedInComposeURL(text: text), NSWorkspace.shared.open(url) else { showError("Couldn’t open LinkedIn", detail: "The draft is copied. Open LinkedIn in your browser and paste it into a post."); return }
        statusLabel.stringValue = "Opened LinkedIn with your text. Review before posting; clipboard backup also copied."
    }

    @objc private func stashSelection(_ sender: Any?) {
        guard let range = selectedRangeOr() else { showError("Select a passage first", detail: "Choose the words you want to keep nearby."); return }
        mutateDocument("Move to overflow") { try $0.stash(range: range) }
        playDeleteAccent()
    }

    private func scheduleAutosave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.saveRecovery() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.milliseconds(650), execute: work)
    }

    private func saveRecovery() -> Bool {
        guard !recoveryDisabled else { return !hasUnsavedChanges }
        guard let store else { return false }
        do { try store.save(draft); return true }
        catch { recoveryDisabled = true; showError("Recovery save failed", detail: "Your open draft is still available. Recovery saving is now disabled. Use File → Save As to keep a named copy."); return false }
    }

    func flushAutosave() -> Bool {
        pendingSave?.cancel(); pendingSave = nil
        guard !recoveryDisabled || !hasUnsavedChanges else {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "This draft is not saved"; alert.informativeText = "Recovery saving is disabled because the previous recovery file could not be read. Save a copy before quitting, or discard the changes."; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Quit Without Saving")
            let discard = alert.runModal() == .alertSecondButtonReturn
            if discard { hasUnsavedChanges = false }
            return discard
        }
        guard saveRecovery() else {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Recovery save failed"; alert.informativeText = "DansWriter could not save the current draft. Choose Save As before quitting, or discard the changes."; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Quit Without Saving")
            let discard = alert.runModal() == .alertSecondButtonReturn
            if discard { hasUnsavedChanges = false }
            return discard
        }
        return true
    }

    func reportRecoveryProblemIfNeeded() {
        guard let message = recoveryProblem else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Recovery draft needs attention"; alert.informativeText = message
        alert.addButton(withTitle: "Keep Recovery"); alert.addButton(withTitle: "Start Fresh"); alert.addButton(withTitle: "Open a Draft…")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            do {
                let preservedAt = try startFreshFromRecovery()
                if let preservedAt {
                    showError("Previous recovery preserved", detail: "The unreadable recovery file and its backup were copied to:\n\(preservedAt.path)")
                }
            } catch {
                showError("Couldn’t start a fresh draft", detail: "Recovery saving remains disabled and the original files were kept. Details: \(error.localizedDescription)")
            }
        case .alertThirdButtonReturn: openDocument(nil)
        default: break
        }
    }

    @discardableResult
    private func startFreshFromRecovery() throws -> URL? {
        let directory = recoveryFileURL.deletingLastPathComponent()
        if store == nil { store = try DocumentStore(directory: directory) }
        let fileManager = FileManager.default
        let sources = [recoveryFileURL, directory.appendingPathComponent("recovery.writeon.bak")]
        let existing = sources.filter { fileManager.fileExists(atPath: $0.path) }
        var preservedAt: URL?
        if !existing.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = directory.appendingPathComponent("recovery-quarantine-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                for source in existing {
                    let destination = quarantine.appendingPathComponent(source.lastPathComponent)
                    try fileManager.copyItem(at: source, to: destination)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
            } catch {
                try? fileManager.removeItem(at: quarantine)
                throw error
            }
            for source in existing { try fileManager.removeItem(at: source) }
            preservedAt = quarantine
        }
        draft = WritingDocument(title: "Untitled", body: "")
        reviewMarks = []
        trimPreviewRanges = []
        inspectedGroupID = nil
        contextRange = nil
        cancelActiveAlternativesRequest()
        documentRevision &+= 1
        labController?.cancelForDocumentChange()
        fileURL = nil
        window?.undoManager?.removeAllActions()
        recoveryDisabled = false
        recoveryProblem = nil
        hasUnsavedChanges = false
        refreshAll()
        scheduleAutosave()
        return preservedAt
    }

    @objc func newDocument(_ sender: Any?) {
        guard confirmReplacement() else { return }
        let old = draft
        draft = WritingDocument(title: "Untitled", body: "")
        fileURL = nil
        window?.undoManager?.removeAllActions()
        registerUndo(old, name: "New draft")
        hasUnsavedChanges = true
        documentRevision &+= 1; cancelActiveAlternativesRequest(); trimPreviewRanges = []; labController?.cancelForDocumentChange()
        refreshAll(selection: NSRange(location: 0, length: 0)); editor.window?.makeFirstResponder(editor); scheduleAutosave()
    }

    @objc func openDocument(_ sender: Any?) {
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "writeon") ?? .data, markdownType, .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = openFile(at: url)
    }

    @discardableResult
    func openFile(at url: URL) -> Bool {
        guard confirmReplacement() else { return false }
        do {
            draft = try DocumentStore.read(from: url); fileURL = url.pathExtension.lowercased() == "writeon" ? url : nil; window?.undoManager?.removeAllActions(); hasUnsavedChanges = false; reviewMarks = []; trimPreviewRanges = []; documentRevision &+= 1; cancelActiveAlternativesRequest(); labController?.cancelForDocumentChange(); refreshAll(selection: NSRange(location: 0, length: 0)); scheduleAutosave(); return true
        } catch { showError("Couldn’t open this draft", detail: "The file may be malformed or use an unsupported encoding."); return false }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let fileURL else { saveAs(sender); return }
        writeDocument(to: fileURL)
    }

    @objc func saveAs(_ sender: Any?) {
        _ = saveAsAndReturn()
    }

    private func saveAsAndReturn() -> Bool {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "writeon") ?? .data]; panel.nameFieldStringValue = "\(safeFileStem(draft.title)).writeon"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        writeDocument(to: url)
        return !hasUnsavedChanges
    }

    @objc func exportMarkdown(_ sender: Any?) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = "\(safeFileStem(draft.title)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DocumentStore.write(draft, to: url) }
        catch { showError("Markdown export failed", detail: "Choose another destination and try again.") }
    }

    private func writeDocument(to url: URL) {
        do { try DocumentStore.write(draft, to: url); fileURL = url; hasUnsavedChanges = false; window?.title = "DansWriter — \(draft.title)" }
        catch { showError("Couldn’t save the draft", detail: "Choose another destination or check that the folder is writable.") }
    }

    private func confirmReplacement() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Save changes before replacing this draft?"; alert.informativeText = "Your changes are still available in this window. Save them, discard them, or cancel."; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard Changes"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let fileURL { writeDocument(to: fileURL); return !hasUnsavedChanges }
            return saveAsAndReturn()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func safeFileStem(_ title: String) -> String { title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }

    private func promptForAlternative(group: AlternativeGroup) {
        let alert = NSAlert(); alert.messageText = "Add an alternative"; alert.informativeText = "The original stays available as the first choice."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24)); alert.accessoryView = field; alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        mutateDocument("Add alternative") { _ = try $0.addAlternatives(range: group.range, texts: [value], source: .human) }
    }

    private func showError(_ message: String, detail: String) {
#if DEBUG
        if selfCheckSuppressAlerts { statusLabel.stringValue = message; return }
#endif
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = message; alert.informativeText = detail; alert.addButton(withTitle: "OK"); alert.runModal()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { documentUndoManager }

    @objc private func openCompareTheCloud(_ sender: Any?) {
        let url = URL(string: "https://www.comparethecloud.net/")!
        guard NSWorkspace.shared.open(url) else {
            showError("Couldn’t open Compare the Cloud", detail: "Check that a browser is available and try again.")
            return
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canQuitWhileResearchStarts() && flushAutosave() }
    func windowDidBecomeKey(_ notification: Notification) {
        if let window, window.firstResponder !== editor { window.makeFirstResponder(editor) }
        configureNativeSpellDefaultsOnce()
    }
    func windowWillClose(_ notification: Notification) {
        cancelActiveAlternativesRequest()
        if notification.object as? NSWindow === window {
            markdownPreviewController?.close(); markdownPreviewController = nil
            researchController?.close(); researchController = nil
        }
    }
}

#if DEBUG
extension MainWindowController {
    static func runDebugSelfCheck() throws {
        func checkpoint(_ message: String) { fputs("SELF-CHECK \(message)\n", stderr); fflush(stderr) }
        let typewriterKey = "WriteOn.typewriterSound"
        let previousTypewriterSetting = UserDefaults.standard.object(forKey: typewriterKey)
        defer { if let previousTypewriterSetting { UserDefaults.standard.set(previousTypewriterSetting, forKey: typewriterKey) } else { UserDefaults.standard.removeObject(forKey: typewriterKey) }; TypewriterSoundPlayer.shared.stop() }
        guard TypewriterSoundPolicy.shouldPlay(eventType: .keyDown, modifiers: []),
              TypewriterSoundPolicy.shouldPlay(eventType: .keyDown, modifiers: [.shift]),
              !TypewriterSoundPolicy.shouldPlay(eventType: .keyDown, modifiers: [.command]),
              !TypewriterSoundPolicy.shouldPlay(eventType: .keyDown, modifiers: [.control]),
              !TypewriterSoundPolicy.shouldPlay(eventType: .leftMouseDown, modifiers: []),
              !TypewriterSoundPolicy.shouldPlay(eventType: .keyDown, modifiers: [.function]) else {
            throw SelfCheckFailure("Typewriter sound routing included a shortcut, navigation-like function key, or non-key event")
        }
        guard let wave = TypewriterSoundPlayer.validWaveData(), wave.count > 44,
              String(data: wave.prefix(4), encoding: .ascii) == "RIFF",
              String(data: wave[8..<12], encoding: .ascii) == "WAVE" else { throw SelfCheckFailure("Typewriter sound WAV was empty or invalid") }
        UserDefaults.standard.set(false, forKey: typewriterKey)
        TypewriterSoundPlayer.shared.playIfEnabled()
        guard UserDefaults.standard.object(forKey: typewriterKey) as? Bool == false else { throw SelfCheckFailure("Typewriter sounds off setting did not persist") }
        checkpoint("typewriter sound routing, WAV and off preference")
        let spellGateKey = "NSAllowContinuousSpellChecking"
        let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let globalSpellGateBefore = globalDomain?[spellGateKey]
        AppDelegate.allowNativeSpellCheckingForThisApp()
        let globalSpellGateAfter = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[spellGateKey]
        guard UserDefaults.standard.object(forKey: spellGateKey) as? Bool == true,
              (globalSpellGateBefore as? Bool) == (globalSpellGateAfter as? Bool) else {
            throw SelfCheckFailure("Native spelling allow override was not app-scoped")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("danswriter-self-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = URL(fileURLWithPath: "/private/tmp/danswriter-self-check-artifacts", isDirectory: true)
        try? FileManager.default.removeItem(at: artifacts)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let application = NSApplication.shared
        application.finishLaunching()
        _ = application.setActivationPolicy(.regular)
        checkpoint("construct main window")
        let controller = MainWindowController(recoveryDirectory: directory)
        controller.selfCheckSuppressAlerts = true
        AppDelegate().installMainMenu(for: controller)
        guard let window = controller.window, let content = window.contentView else { throw SelfCheckFailure("Main window was not created") }
        controller.showWindow(nil)
        try controller.runDebugAlternativesRequestCheck()
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.editor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            application.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                application.postEvent(wake, atStart: true)
            }
        }
        application.run()
        window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        try MarkdownPreviewWindowController.runDebugSelfCheck()
        try ResearchWindowController.runDebugResearchCheck()
        let closeCheck = MainWindowController(recoveryDirectory: directory.appendingPathComponent("close-check"))
        closeCheck.selfCheckSuppressAlerts = true
        let researchCloseCheck = ResearchWindowController(initialTheme: .light, journalDirectory: directory.appendingPathComponent("research-close-check"), onInsert: { _, _ in false })
        closeCheck.researchController = researchCloseCheck
        researchCloseCheck.debugSetCreationPending(true)
        guard closeCheck.windowShouldClose(closeCheck.window!) == false else { throw SelfCheckFailure("Closing the main window could orphan a pending research task") }
        researchCloseCheck.debugSetCreationPending(false)
        researchCloseCheck.showWindow(nil)
        closeCheck.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: closeCheck.window!))
        guard researchCloseCheck.window?.isVisible == false else { throw SelfCheckFailure("Research remained open against a closed draft") }
        let beforeResearch = controller.draft
        let separateResearch = ResearchWindowController(initialTheme: .light, journalDirectory: directory.appendingPathComponent("research-undo"), onInsert: { _, _ in false })
        separateResearch.showWindow(nil); separateResearch.window?.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let researchFixture = "## Research fixture\n\nCited finding. [Source](https://example.com/research)"
        guard controller.insertResearch(researchFixture, destination: .draft),
              controller.draft.body.hasPrefix(beforeResearch.body),
              controller.draft.body.hasSuffix(researchFixture),
              !controller.draft.pasteSpans.isEmpty else { throw SelfCheckFailure("Research insertion did not append with provenance") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        separateResearch.close(); window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.undoManager?.undo()
        guard controller.draft == beforeResearch else { throw SelfCheckFailure("Research insertion undo did not restore the whole document") }
        guard controller.insertResearch(researchFixture, destination: .overflow),
              controller.draft.body == beforeResearch.body,
              controller.draft.overflow.hasSuffix(researchFixture) else { throw SelfCheckFailure("Research Overflow insertion changed the draft") }
        window.undoManager?.undo()
        guard controller.draft == beforeResearch else { throw SelfCheckFailure("Research Overflow undo lost document state") }
        checkpoint("research staging, explicit insertion, provenance and undo")
        if NSSpellChecker.shared.availableLanguages.contains("en_GB") {
            let misspelling = NSSpellChecker.shared.checkSpelling(of: "teh", startingAt: 0, language: "en_GB", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard misspelling.location == 0 && misspelling.length == 3 else { throw SelfCheckFailure("Apple’s en_GB spell checker did not flag the typo fixture") }
        }
        let editMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "Edit" })
        let spellingMenu = editMenu?.items.first(where: { $0.title == "Spelling and Grammar" })?.submenu
        let nativeContextMenu = NSMenu()
        let lookupItem = NSMenuItem(title: "Look Up ‘teh’", action: NSSelectorFromString("lookUp:"), keyEquivalent: "")
        lookupItem.target = controller.editor
        let writingToolsItem = NSMenuItem(title: "Writing Tools", action: nil, keyEquivalent: "")
        let writingToolsSubmenu = NSMenu(title: "Writing Tools")
        writingToolsSubmenu.addItem(NSMenuItem(title: "Rewrite", action: NSSelectorFromString("rewrite:"), keyEquivalent: ""))
        writingToolsItem.submenu = writingToolsSubmenu
        let nativeCorrectionItem = NSMenuItem(title: "Replace with ‘the’", action: NSSelectorFromString("changeSpelling:"), keyEquivalent: "")
        nativeCorrectionItem.target = controller.editor
        nativeContextMenu.addItem(lookupItem)
        nativeContextMenu.addItem(writingToolsItem)
        nativeContextMenu.addItem(nativeCorrectionItem)
        let nativeContextMenuCount = nativeContextMenu.items.count
        let applicationContextMenu = controller.contextMenu(at: 0) ?? NSMenu()
        let combinedContextMenu = controller.editor.combinedContextMenu(nativeMenu: nativeContextMenu, applicationMenu: applicationContextMenu, dictionaryTerm: "teh")
        guard combinedContextMenu.items.count > nativeContextMenuCount,
              combinedContextMenu.items[0] === lookupItem,
              combinedContextMenu.items[1] === writingToolsItem,
              combinedContextMenu.items[1].submenu?.items.first?.title == "Rewrite",
              combinedContextMenu.items[2] === nativeCorrectionItem,
              combinedContextMenu.items[3].isSeparatorItem,
              combinedContextMenu.items[4].title == "Dictionary and Thesaurus",
              combinedContextMenu.items[4].action == NSSelectorFromString("openInDictionary:"),
              combinedContextMenu.items[4].target === controller.editor,
              combinedContextMenu.items[4].representedObject as? String == "teh",
              DocumentTextView.dictionaryURL(for: "teh")?.absoluteString == "dict://teh",
              DocumentTextView.dictionaryURL(for: " ") == nil else {
            throw SelfCheckFailure("Editor context menu dropped native Lookup, Writing Tools or correction items, or lost the offline Dictionary action")
        }
        let spellActions = Set(spellingMenu?.items.compactMap { item in item.action.map { NSStringFromSelector($0) } } ?? [])
        guard spellActions.contains(NSStringFromSelector(#selector(MainWindowController.checkSpellingNow(_:)))),
              spellActions.contains(NSStringFromSelector(#selector(MainWindowController.showSpellingPanel(_:)))),
              spellActions.contains(NSStringFromSelector(#selector(MainWindowController.toggleContinuousSpellChecking(_:)))),
              spellActions.contains(NSStringFromSelector(#selector(MainWindowController.toggleGrammarChecking(_:)))),
              spellActions.contains(NSStringFromSelector(#selector(MainWindowController.toggleAutomaticSpellingCorrection(_:)))),
              spellingMenu?.items.first(where: { $0.action == #selector(MainWindowController.checkSpellingNow(_:)) })?.target === controller else {
            throw SelfCheckFailure("Native spelling controls are missing from Edit > Spelling and Grammar")
        }
        guard controller.responds(to: NSSelectorFromString("validateMenuItem:")) else { throw SelfCheckFailure("Main controller does not expose native menu validation") }
        controller.configureNativeSpellDefaultsOnce()
        guard let continuousItem = spellingMenu?.items.first(where: { $0.action == #selector(MainWindowController.toggleContinuousSpellChecking(_:)) }),
              let grammarItem = spellingMenu?.items.first(where: { $0.action == #selector(MainWindowController.toggleGrammarChecking(_:)) }),
              let correctionItem = spellingMenu?.items.first(where: { $0.action == #selector(MainWindowController.toggleAutomaticSpellingCorrection(_:)) }) else { throw SelfCheckFailure("Native spelling toggles are missing") }
        _ = controller.validateMenuItem(continuousItem); _ = controller.validateMenuItem(grammarItem); _ = controller.validateMenuItem(correctionItem)
        guard continuousItem.state == .on && grammarItem.state == .on && correctionItem.state == .off else {
            throw SelfCheckFailure("Native spell menu states did not reflect defaults: spelling=\(continuousItem.state.rawValue)/\(controller.editor.isContinuousSpellCheckingEnabled), grammar=\(grammarItem.state.rawValue)/\(controller.editor.isGrammarCheckingEnabled), autocorrect=\(correctionItem.state.rawValue)/\(controller.editor.isAutomaticSpellingCorrectionEnabled)")
        }
        let spellingBefore = controller.draft
        controller.draft = WritingDocument(title: "Spell QA", body: "teh")
        controller.editor.string = "teh"; controller.refreshAll(selection: NSRange(location: 0, length: 0))
        controller.checkSpellingNow(nil)
        guard controller.editor.selectedRange().length == 3 else { throw SelfCheckFailure("Explicit Check Document Now action did not select the misspelling") }
        let spellUndo = controller.window?.undoManager
        spellUndo?.removeAllActions()
        spellUndo?.beginUndoGrouping()
        let correctionSender = NSTextField(string: "the")
        guard NSApp.sendAction(NSSelectorFromString("changeSpelling:"), to: controller.editor, from: correctionSender) else { throw SelfCheckFailure("Native spelling correction action did not reach NSTextView") }
        spellUndo?.endUndoGrouping()
        guard controller.draft.body == "the" else { throw SelfCheckFailure("Native spelling correction did not reach the draft model") }
        spellUndo?.undo()
        guard controller.draft.body == "teh" else { throw SelfCheckFailure("Native spelling correction was not undoable as one edit") }
        controller.draft = spellingBefore; controller.refreshAll(); spellUndo?.removeAllActions()
        checkpoint("window hierarchy laid out")

        let original = controller.draft.body
        controller.applyingUI = true; controller.editor.string = original + " A check."; controller.applyingUI = false
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.editor))
        guard controller.draft.body == original + " A check." else { throw SelfCheckFailure("Text edit did not reach the writing model") }
        let undoItem = NSMenuItem(title: "Undo", action: #selector(undoEdit(_:)), keyEquivalent: "z")
        undoItem.target = controller
        guard NSApp.sendAction(undoItem.action!, to: undoItem.target, from: undoItem) else { throw SelfCheckFailure("Undo menu action was not dispatched") }
        guard controller.draft.body == original else { throw SelfCheckFailure("Undo did not restore the document snapshot") }
        checkpoint("edit and undo")

        let initialAlternatives = controller.showAlternatives
        controller.toggleAlternatives(nil); content.layoutSubtreeIfNeeded()
        guard controller.showAlternatives != initialAlternatives else { throw SelfCheckFailure("Alternatives control did not toggle") }
        controller.toggleAlternatives(nil)
        let initialOverflow = controller.showOverflow
        controller.toggleOverflow(nil); content.layoutSubtreeIfNeeded()
        guard controller.showOverflow != initialOverflow else { throw SelfCheckFailure("Overflow control did not toggle") }
        controller.toggleOverflow(nil)
        let initialClean = controller.cleanRead
        controller.toggleCleanRead(nil)
        guard controller.cleanRead != initialClean else { throw SelfCheckFailure("Clean view control did not toggle") }
        controller.toggleCleanRead(nil)
        controller.draft = WritingDocument.welcome
        controller.editor.string = controller.draft.body
        controller.theme = .light
        if let marked = controller.draft.alternatives.first {
            try controller.draft.selectAlternative(groupID: marked.id, index: 1)
            controller.inspect(marked)
        }
        controller.refreshAll(selection: controller.draft.alternatives.first?.range.nsRange)
        if let selectedGroup = controller.draft.alternatives.first {
            let editedBody = controller.draft.body
            controller.editor.setSelectedRange(NSRange(location: selectedGroup.range.location + 1, length: 0))
            guard !controller.deleteSelectedAlternative(), controller.draft.body == editedBody else { throw SelfCheckFailure("Delete at a caret inside an alternative should remain ordinary text deletion") }
            controller.refreshAll(selection: selectedGroup.range.nsRange)
        }
        try controller.runDebugFunctionalMatrix(directory: directory, artifacts: artifacts)
        try runDebugRecoveryQuarantineCheck(directory: directory)
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 640), display: false)
        window.setContentSize(NSSize(width: 900, height: 640)); window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        checkpoint("900-point frame \(window.frame.width), content \(content.bounds.width), min \(window.minSize.width)")
        try controller.assertSelfCheckGeometry(width: 900, content: content)
        try controller.writeSelfCheckSnapshot(to: artifacts.appendingPathComponent("danswriter-900-light.png"))
        if !controller.draft.alternatives.isEmpty {
            let originalOption = controller.draft.alternatives[0].options[2].text
            let longParagraph = String(repeating: "A complete paragraph option should stay readable while people compare how each sentence flows through an idea and lands at a clear ending. ", count: 14)
            controller.draft.alternatives[0].options[2].text = longParagraph
            controller.refreshAll(selection: controller.draft.alternatives[0].range.nsRange)
            window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
            guard let optionScroll = controller.leftScroll.documentView, optionScroll.frame.height > controller.leftScroll.contentView.bounds.height + 40 else { throw SelfCheckFailure("Long alternative did not expand the scrollable inspector") }
            try SelfCheckSnapshot.write(controller.leftPane, to: artifacts.appendingPathComponent("danswriter-900-long-alternative.png"))
            controller.draft.alternatives[0].options[2].text = originalOption
            controller.refreshAll(selection: controller.draft.alternatives[0].range.nsRange)
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1260, height: 830), display: false)
        window.setContentSize(NSSize(width: 1260, height: 830)); window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        checkpoint("1260-point frame \(window.frame.width), content \(content.bounds.width), min \(window.minSize.width)")
        try controller.assertSelfCheckGeometry(width: 1260, content: content)
        try controller.writeSelfCheckSnapshot(to: artifacts.appendingPathComponent("danswriter-1260-light.png"))
        controller.theme = .dark; controller.refreshAll()
        try controller.writeSelfCheckSnapshot(to: artifacts.appendingPathComponent("danswriter-1260-dark.png"))
        checkpoint("900 and 1260 light/dark snapshots: /private/tmp/danswriter-self-check-artifacts")

        controller.draft.overflow = "A note kept nearby."
        try controller.store?.save(controller.draft)
        guard try controller.store?.load() == controller.draft else { throw SelfCheckFailure("Recovery round-trip lost document annotations") }
        let recoveryBaseline = controller.draft
        let recoveryStart = CFAbsoluteTimeGetCurrent()
        let recoveredController = MainWindowController(recoveryDirectory: directory)
        let recoveryElapsed = CFAbsoluteTimeGetCurrent() - recoveryStart
        guard recoveredController.draft == recoveryBaseline else { throw SelfCheckFailure("Re-instantiated recovery did not preserve document ID, body, alternatives, ghosts, and overflow") }
        recoveredController.hasUnsavedChanges = false
        recoveredController.window?.orderOut(nil)
        fputs(String(format: "SELF-CHECK recovery re-instantiation %.3f seconds; document fields preserved\n", recoveryElapsed), stderr)
        let markdown = directory.appendingPathComponent("round-trip.md")
        try DocumentStore.write(controller.draft, to: markdown)
        guard try DocumentStore.read(from: markdown).body == controller.draft.body else { throw SelfCheckFailure("Markdown round-trip failed") }
        checkpoint("isolated recovery and Markdown round-trips")

        controller.showLab(nil); controller.labController?.window?.layoutIfNeeded()
        guard controller.labController?.window?.contentView != nil else { throw SelfCheckFailure("Lab window was not created") }
        if let inspected = controller.draft.alternatives.first {
            controller.inspect(inspected)
            controller.editor.setSelectedRange(NSRange(location: 0, length: 0))
            try controller.labController?.runDebugSelectionScopeCheck()
        }
        let beforeLabFixture = controller.draft
        controller.draft = WritingDocument(title: "Lab QA", body: "cat dog")
        controller.refreshAll()
        try controller.labController?.runDebugAcceptanceRetentionCheck()
        controller.draft = beforeLabFixture; controller.refreshAll()
        try controller.labController?.runDebugStaleAcceptanceCheck()
        if let labContent = controller.labController?.window?.contentView { try SelfCheckSnapshot.write(labContent, to: artifacts.appendingPathComponent("danswriter-lab.png")) }
        controller.labController?.close()
        controller.showSettings(nil); controller.settingsController?.window?.layoutIfNeeded()
        guard controller.settingsController?.window?.contentView != nil else { throw SelfCheckFailure("Settings window was not created") }
        try controller.settingsController?.runDebugProviderIsolationCheck()
        if let settingsContent = controller.settingsController?.window?.contentView { try SelfCheckSnapshot.write(settingsContent, to: artifacts.appendingPathComponent("danswriter-settings.png")) }
        controller.settingsController?.close()
        controller.close()
        checkpoint("Lab and settings windows constructed")
    }

    private func runDebugAlternativesRequestCheck() throws {
        guard let first = beginAlternativesRequest(), !cancelAIButton.isHidden, alternativesButton?.isEnabled == false,
              statusLabel.stringValue.contains("Generating alternatives") else {
            throw SelfCheckFailure("Alternatives request did not show immediate progress and Cancel")
        }
        guard beginAlternativesRequest() == nil else { throw SelfCheckFailure("Repeated alternatives action replaced an in-flight request") }
        cancelAlternativesRequest(first)
        guard !aiLifecycle.isBusy, cancelAIButton.isHidden else { throw SelfCheckFailure("Cancel did not clear alternatives busy state") }

        guard let next = beginAlternativesRequest() else { throw SelfCheckFailure("A new alternatives request was blocked after cancellation") }
        guard !finishAlternativesRequest(first), aiLifecycle.isCurrent(next), !cancelAIButton.isHidden else {
            throw SelfCheckFailure("A late completion from a cancelled request altered newer request UI")
        }
        cancelAlternativesRequest(next)
    }

    private func runDebugFunctionalMatrix(directory: URL, artifacts: URL) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw SelfCheckFailure(message) } }
        let savedDraft = draft
        let savedURL = fileURL
        let savedDirty = hasUnsavedChanges
        defer {
            draft = savedDraft; fileURL = savedURL; hasUnsavedChanges = savedDirty
            editor.string = savedDraft.body; overflowEditor.string = savedDraft.overflow
            reviewMarks = []; trimPreviewRanges = []; inspectedGroupID = nil
            window?.undoManager?.removeAllActions(); refreshAll(); scheduleAutosave()
        }
        window?.undoManager?.removeAllActions()
        draft = WritingDocument(title: "Share QA", body: "Full draft to share")
        editor.string = draft.body
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        try require(selectedOrFullDraftText() == "Full", "Share selection did not choose only selected text")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try require(selectedOrFullDraftText() == "Full draft to share", "Share did not fall back to the complete draft")
        let localPasteboard = NSPasteboard.withUniqueName()
        defer { localPasteboard.releaseGlobally() }
        try require(copyShareText("LinkedIn draft", to: localPasteboard) && localPasteboard.string(forType: .string) == "LinkedIn draft", "LinkedIn share did not copy the draft text")
        guard let linkedinURL = linkedInComposeURL(text: "Full draft to share"), let xURL = xDraftURL(text: "X QA text"),
              let linkedinParts = URLComponents(url: linkedinURL, resolvingAgainstBaseURL: false),
              let xParts = URLComponents(url: xURL, resolvingAgainstBaseURL: false) else { throw SelfCheckFailure("A share compose URL could not be built") }
        try require(linkedinParts.queryItems?.contains(URLQueryItem(name: "text", value: "Full draft to share")) == true, "LinkedIn compose URL lost its text payload")
        try require(linkedinParts.host == "www.linkedin.com" && linkedinParts.path == "/feed/" && linkedinParts.queryItems?.contains(URLQueryItem(name: "shareActive", value: "true")) == true, "LinkedIn share did not use the native compose destination")
        try require(xParts.host == "twitter.com" && xParts.path == "/intent/tweet" && xParts.queryItems?.contains(URLQueryItem(name: "text", value: "X QA text")) == true, "X compose URL lost its text payload")
        for payload in ["Line one\n\nLine two £ & + # ? = 😀 café", String(repeating: "Draft + & # 😀\n", count: 150)] {
            guard let url = linkedInComposeURL(text: payload),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw SelfCheckFailure("LinkedIn payload URL failed") }
            try require(parts.queryItems?.first(where: { $0.name == "text" })?.value == payload, "LinkedIn draft lost newlines, punctuation or Unicode")
            try require(!url.absoluteString.contains("+"), "LinkedIn query left literal plus signs unescaped")
        }
        let sharePicker = NSSharingServicePicker(items: ["Native share test"])
        try require(sharePicker.delegate == nil, "Native share picker unexpectedly requires an external service")
        draft = savedDraft; editor.string = savedDraft.body
        let fullBody = draft.body as NSString
        guard fullBody.length > 8 else { throw SelfCheckFailure("Proofread selection fixture too short") }
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        contextRange = DraftRange(location: 6, length: 3)
        try require(selectContextForProofread() && editor.selectedRange() == NSRange(location: 6, length: 3), "Context proofreading used a stale editor selection")
        contextRange = nil
        guard let group = draft.alternatives.first, group.options.count > 1 else { throw SelfCheckFailure("No alternative fixture exists") }
        let option = group.options[1]
        selectAlternative(group, index: 1)
        try require(draft.alternatives.first(where: { $0.id == group.id })?.selectedIndex == 1, "Alternative selection did not update the model")
        try require(setAlternativeText(groupID: group.id, optionID: option.id, text: option.text + " edited"), "Editing an alternate choice failed")
        try require(draft.alternatives.first(where: { $0.id == group.id })?.options.contains(where: { $0.text == option.text + " edited" }) == true, "Edited choice was not retained")
        let originalText = draft.alternatives.first(where: { $0.id == group.id })!.options[0].text
        try require(!setAlternativeText(groupID: group.id, optionID: group.options[0].id, text: "replace original"), "Original choice was editable")
        window?.undoManager?.removeAllActions()
        let selected = draft.alternatives.first(where: { $0.id == group.id })!
        editor.setSelectedRange(selected.range.nsRange)
        try require(deleteSelectedAlternative(), "Whole selected alternate choice did not delete")
        try require(draft.alternatives.first(where: { $0.id == group.id })?.options.first?.text == originalText, "Deleting an alternate did not preserve original text")
        window?.undoManager?.undo()
        try require(draft.alternatives.first(where: { $0.id == group.id })?.options.contains(where: { $0.text == option.text + " edited" }) == true, "Undo did not restore removed alternative")
        window?.undoManager?.redo()
        try require(draft.alternatives.first(where: { $0.id == group.id })?.options.first?.text == originalText, "Redo did not restore original choice")

        let phrase = "quiet draft"
        guard let swiftRange = draft.body.range(of: phrase) else { throw SelfCheckFailure("Fixture phrase missing") }
        let start = draft.body.utf16.distance(from: draft.body.utf16.startIndex, to: swiftRange.lowerBound.samePosition(in: draft.body.utf16)!)
        let phraseRange = DraftRange(location: start, length: phrase.utf16.count)
        _ = mutateDocument("Debug add choice") { _ = try $0.addAlternatives(range: phraseRange, texts: ["calm draft"], source: .human) }
        try require(draft.alternatives.contains(where: { $0.options.contains(where: { $0.text == "calm draft" }) }), "Adding an alternative did not update the model")
        _ = mutateDocument("Debug ghost") { try $0.ghost(range: phraseRange) }
        try require(draft.ghosts.contains(where: { $0.range == phraseRange }), "Ghost action did not dim the selected phrase")
        _ = mutateDocument("Debug revive") { $0.revive(range: phraseRange) }
        try require(!draft.ghosts.contains(where: { $0.range == phraseRange }), "Revive did not remove the ghost mark")
        _ = mutateDocument("Debug stash") { try $0.stash(range: phraseRange) }
        try require(draft.overflow.contains(phrase), "Stash did not preserve selected text in overflow")

        let beforeOverflow = draft.overflow
        window?.undoManager?.removeAllActions()
        overflowEditor.string = beforeOverflow + " note"
        textDidChange(Notification(name: NSText.didChangeNotification, object: overflowEditor))
        try require(draft.overflow == beforeOverflow + " note", "Overflow typing did not update the draft")
        window?.undoManager?.undo(); try require(draft.overflow == beforeOverflow, "Overflow undo failed")
        window?.undoManager?.redo(); try require(draft.overflow == beforeOverflow + " note", "Overflow redo failed")
        let validBody = draft.body
        editor.string = String(repeating: "x", count: 5_000_001)
        textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        try require(draft.body == validBody && editor.string == validBody, "Oversized body edit rollback failed (model \(draft.body.utf8.count), view \(editor.string.utf8.count), expected \(validBody.utf8.count), status \(statusLabel.stringValue))")
        let validOverflow = draft.overflow
        overflowEditor.string = String(repeating: "x", count: 5_000_001)
        textDidChange(Notification(name: NSText.didChangeNotification, object: overflowEditor))
        try require(draft.overflow == validOverflow && overflowEditor.string == validOverflow, "Oversized overflow edit was accepted or not rolled back")

        let plain = directory.appendingPathComponent("import.md")
        try Data("Imported body only.".utf8).write(to: plain)
        hasUnsavedChanges = false
        try require(openFile(at: plain), "Markdown import failed")
        try require(draft.body == "Imported body only." && draft.alternatives.isEmpty && fileURL == nil, "Markdown import did not remain a plain-text unsaved draft")
        let native = directory.appendingPathComponent("round-trip.writeon")
        writeDocument(to: native)
        let reread = try DocumentStore.read(from: native)
        try require(reread == draft, "Native save/reopen round-trip lost draft metadata")
        hasUnsavedChanges = false
        try require(openFile(at: native) && draft == reread, "Opening a native draft did not restore its annotations")
        hasUnsavedChanges = false
        newDocument(nil)
        try require(draft.body.isEmpty && fileURL == nil, "New draft action did not create a clean untitled draft")

        draft = WritingDocument(title: "Paste QA", body: "alpha beta")
        editor.string = draft.body; window?.undoManager?.removeAllActions(); refreshAll()
        let paletteMenu = pasteColourMenu(operation: "paste-edit")
        try require(paletteMenu.items.count == PasteColour.allCases.count, "Paste As palette did not expose every colour")
        try require(applyPasteAs("AI phrase", range: DraftRange(location: 6, length: 4), colour: .coral), "Paste As action failed")
        try require(draft.body == "alpha AI phrase" && draft.pasteSpans.count == 1 && draft.pasteSpans[0].colour == .coral, "Paste As did not replace selection and track its colour")
        window?.undoManager?.undo()
        try require(draft.body == "alpha beta" && draft.pasteSpans.isEmpty, "Undo did not remove Paste As text and metadata together")
        window?.undoManager?.redo()
        try require(draft.body == "alpha AI phrase" && draft.pasteSpans.count == 1, "Redo did not restore Paste As text and metadata")
        window?.undoManager?.removeAllActions()
        let selectedPaste = DraftRange(location: 7, length: 5)
        try require(setPasteColour(selectedPaste, colour: .blue), "Changing a paste colour failed")
        try require(draft.pasteSpans.contains(where: { $0.range == selectedPaste && $0.colour == .blue }), "Partial recolouring did not target the selection")
        try writeSelfCheckSnapshot(to: artifacts.appendingPathComponent("danswriter-paste-colours-light.png"))
        theme = .dark; refreshAll()
        try writeSelfCheckSnapshot(to: artifacts.appendingPathComponent("danswriter-paste-colours-dark.png"))
        theme = .light; refreshAll()
        window?.undoManager?.removeAllActions()
        editor.setSelectedRange(selectedPaste.nsRange)
        let clearItem = NSMenuItem(title: "Remove AI Paste Mark", action: #selector(clearPasteMark(_:)), keyEquivalent: "")
        clearItem.target = self
        try require(NSApp.sendAction(clearItem.action!, to: clearItem.target, from: clearItem), "Remove AI paste mark menu action did not dispatch")
        try require(!draft.pasteSpans.contains(where: { $0.range.location < selectedPaste.location + selectedPaste.length && selectedPaste.location < $0.range.location + $0.range.length && $0.colour == .blue }), "Clearing a paste mark left selected text coloured")
        window?.undoManager?.undo()
        try require(draft.pasteSpans.contains(where: { $0.range == selectedPaste && $0.colour == .blue }), "Undo did not restore the previous paste colour")
        window?.undoManager?.redo()
        draft = WritingDocument(title: "Plain paste QA", body: "ordinary")
        editor.string = "ordinary paste"; textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        try require(draft.body == "ordinary paste" && draft.pasteSpans.isEmpty, "Ordinary typing/paste acquired AI attribution")
        fputs("SELF-CHECK editing, undo/redo, ghost/stash, size guards, New/Open and native file round-trips\n", stderr)
    }

    private func writeSelfCheckSnapshot(to url: URL) throws {
        guard let content = window?.contentView else { throw SelfCheckFailure("Snapshot window is missing") }
        try SelfCheckSnapshot.write(content, to: url)
    }

    private func assertSelfCheckGeometry(width: CGFloat, content: NSView) throws {
        content.layoutSubtreeIfNeeded()
        guard abs(content.bounds.width - width) < 1, abs(root.bounds.width - width) < 1 else { throw SelfCheckFailure("Window content/root width does not match the requested \(width)-point layout") }
        guard companyLinkButton.frame.width >= 130,
              companyLinkButton.frame.maxX <= statusLabel.frame.minX,
              statusLabel.frame.maxX <= cancelAIButton.frame.minX else {
            throw SelfCheckFailure("Compare the Cloud footer link overlaps at \(width): link=\(companyLinkButton.frame) status=\(statusLabel.frame) cancel=\(cancelAIButton.frame)")
        }
        guard editorScroll.frame.width > 400, abs(editor.frame.width - editorScroll.contentView.bounds.width) < 2,
              (editor.textContainer?.containerSize.width ?? 0) > 0 else { throw SelfCheckFailure("The writing canvas did not receive usable text layout width") }
        if let brand = header.subviews.first(where: { $0.identifier?.rawValue == "brand-stack" }),
           let buttons = header.subviews.first(where: { $0.identifier?.rawValue == "header-buttons" }) {
            let brandRight = brand.frame.maxX
            let buttonsLeft = buttons.frame.minX
            guard brandRight + 12 <= buttonsLeft else { throw SelfCheckFailure("Header title overlaps toolbar at \(width) points") }
        } else { throw SelfCheckFailure("Header layout anchors were not found") }
    }

    private static func runDebugRecoveryQuarantineCheck(directory: URL) throws {
        let recoveryDirectory = directory.appendingPathComponent("damaged-recovery", isDirectory: true)
        let writer = try DocumentStore(directory: recoveryDirectory)
        try writer.save(WritingDocument(title: "Previous recovery", body: "First known good."))
        try writer.save(WritingDocument(title: "Previous recovery", body: "Second known good."))
        let damagedMain = recoveryDirectory.appendingPathComponent("recovery.writeon")
        let backup = recoveryDirectory.appendingPathComponent("recovery.writeon.bak")
        let damagedBytes = Data("unreadable main recovery".utf8)
        try damagedBytes.write(to: damagedMain, options: .atomic)
        let backupBytes = try Data(contentsOf: backup)
        let controller = MainWindowController(recoveryDirectory: recoveryDirectory)
        controller.selfCheckSuppressAlerts = true
        guard controller.recoveryProblem != nil else { throw SelfCheckFailure("Corrupt recovery fixture was accepted as readable") }
        let staleDocumentID = controller.draft.id
        let oldRevision = controller.documentRevision
        controller.reviewMarks = [AcceptedReviewMark(action: .longSentences, quote: "old", reason: "self-check")]
        controller.trimPreviewRanges = [DraftRange(location: 0, length: 1)]
        guard let quarantine = try controller.startFreshFromRecovery() else { throw SelfCheckFailure("Starting fresh did not preserve unreadable recovery files") }
        guard controller.draft.id != staleDocumentID && controller.documentRevision == oldRevision + 1,
              controller.reviewMarks.isEmpty && controller.trimPreviewRanges.isEmpty,
              controller.window?.undoManager?.canUndo == false else { throw SelfCheckFailure("Starting fresh retained stale marks, undo history, or document identity") }
        let preservedMain = quarantine.appendingPathComponent("recovery.writeon")
        let preservedBackup = quarantine.appendingPathComponent("recovery.writeon.bak")
        guard try Data(contentsOf: preservedMain) == damagedBytes,
              try Data(contentsOf: preservedBackup) == backupBytes else { throw SelfCheckFailure("Recovery quarantine did not retain exact damaged and backup bytes") }
        controller.pendingSave?.cancel(); controller.pendingSave = nil
        guard controller.saveRecovery() else { throw SelfCheckFailure("Fresh recovery could not be saved after quarantining old files") }
        guard try Data(contentsOf: preservedMain) == damagedBytes,
              try Data(contentsOf: preservedBackup) == backupBytes else { throw SelfCheckFailure("Fresh autosave overwrote the quarantined recovery evidence") }
        controller.hasUnsavedChanges = false; controller.window?.orderOut(nil)
    }
}

private struct SelfCheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum SelfCheckSnapshot {
    static func write(_ content: NSView, to url: URL) throws {
        content.layoutSubtreeIfNeeded()
        let width = max(1, Int(content.bounds.width.rounded(.up)))
        let height = max(1, Int(content.bounds.height.rounded(.up)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw SelfCheckFailure("Could not allocate a window snapshot") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SelfCheckFailure("Could not encode a window snapshot") }
        try data.write(to: url, options: .atomic)
    }
}
#endif
