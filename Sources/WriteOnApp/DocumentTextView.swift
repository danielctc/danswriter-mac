import AppKit
import WriteOnCore

final class DocumentTextView: NSTextView {
    var groupAtCharacter: ((Int) -> AlternativeGroup?)?
    var onGroupClick: ((AlternativeGroup, NSPoint) -> Void)?
    var onHoverGroup: ((AlternativeGroup?) -> Void)?
    var onCycleGroup: ((AlternativeGroup, Int) -> Void)?
    var menuAtCharacter: ((Int) -> NSMenu?)?
    var onDeleteAlternative: (() -> Bool)?
    var alternativesProvider: (() -> [AlternativeGroup])?
    var drawsAlternativeMarks = true
    private var tracking: NSTrackingArea?
    private var hoveredID: UUID?
    private var hoveredGroup: AlternativeGroup?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsAlternativeMarks, let layoutManager else { return }
        for group in alternativesProvider?() ?? [] {
            guard group.range.location >= 0, group.range.length > 0,
                  group.range.location + group.range.length <= (string as NSString).length,
                  group.options.indices.contains(group.selectedIndex) else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: group.range.nsRange, actualCharacterRange: nil)
            let selected = group.options[group.selectedIndex]
            let markColor = selected.source == .ai ? Ink.amber : Ink.teal
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, container, lineGlyphRange, _ in
                let overlap = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard overlap.length > 0 else { return }
                let bounds = layoutManager.boundingRect(forGlyphRange: overlap, in: container)
                let origin = self.textContainerOrigin
                let left = origin.x + bounds.minX
                let right = origin.x + bounds.maxX
                guard right > left else { return }
                let baseline = origin.y + bounds.maxY - 1.5
                let path = NSBezierPath()
                path.lineWidth = 0.9
                path.move(to: NSPoint(x: left, y: baseline))
                var x = left
                var step = 0
                while x < right {
                    let next = min(right, x + 2.2)
                    path.line(to: NSPoint(x: next, y: baseline + (step.isMultiple(of: 2) ? 1.1 : -1.1)))
                    x = next; step += 1
                }
                markColor.setStroke(); path.stroke()
                if overlap.location == glyphRange.location {
                    let dotRect = NSRect(x: max(1, left - 6), y: baseline - 1.3, width: 3, height: 3)
                    if group.selectedIndex == 0 { markColor.setFill(); NSBezierPath(ovalIn: dotRect).fill() }
                    else { markColor.setStroke(); let dot = NSBezierPath(ovalIn: dotRect); dot.lineWidth = 0.8; dot.stroke() }
                }
            }
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), let group = groupAtCharacter?(index) {
            if group.id != hoveredID { hoveredID = group.id; hoveredGroup = group; onHoverGroup?(group) }
        } else if hoveredID != nil {
            hoveredID = nil
            hoveredGroup = nil
            onHoverGroup?(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard let index = characterIndex(at: point), let group = groupAtCharacter?(index) else { return }
        hoveredID = group.id
        onGroupClick?(group, point)
    }

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        let hasModifiers = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if !hasModifiers, (key == 51 || key == 117), onDeleteAlternative?() == true { return }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              [123, 124, 125, 126].contains(key), let group = hoveredGroup else {
            super.keyDown(with: event)
            return
        }
        let direction = (key == 123 || key == 126) ? -1 : 1
        if let current = groupAtCharacter?(characterIndex(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) ?? -1) {
            onCycleGroup?(current, direction)
        } else {
            onCycleGroup?(group, direction)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Ask NSTextView first: AppKit uses this opportunity to establish the
        // word under the pointer and populate its native spelling/Writing Tools menu.
        let nativeMenu = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), let applicationMenu = menuAtCharacter?(index) {
            let proposed = selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
            let selection = selectedRange()
            let source = proposed.length > 0 ? proposed : (NSLocationInRange(index, selection) ? selection : NSRange(location: index, length: 0))
            let term = source.length > 0 && NSMaxRange(source) <= (string as NSString).length
                ? (string as NSString).substring(with: source).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return combinedContextMenu(nativeMenu: nativeMenu, applicationMenu: applicationMenu, dictionaryTerm: term)
        }
        return nativeMenu
    }

    func combinedContextMenu(nativeMenu: NSMenu?, applicationMenu: NSMenu, dictionaryTerm: String) -> NSMenu {
        let menu = nativeMenu ?? NSMenu()
        let hasApplicationItems = !applicationMenu.items.isEmpty || !dictionaryTerm.isEmpty
        guard hasApplicationItems else { return menu }
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        if !dictionaryTerm.isEmpty {
            let lookup = NSMenuItem(title: "Dictionary and Thesaurus", action: #selector(openInDictionary(_:)), keyEquivalent: "")
            lookup.target = self
            lookup.representedObject = dictionaryTerm
            menu.addItem(lookup)
        }
        for item in Array(applicationMenu.items) {
            applicationMenu.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openInDictionary(_ sender: NSMenuItem) {
        guard let term = sender.representedObject as? String,
              let url = Self.dictionaryURL(for: term) else { return }
        guard NSWorkspace.shared.open(url) else {
            let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: "macOS could not open Dictionary for “\(term)”."])
            presentError(error)
            return
        }
    }

    static func dictionaryURL(for term: String) -> URL? {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "dict://\(encoded)")
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < (string as NSString).length ? index : nil
    }
}

final class AlternativesPopoverController: NSViewController {
    var group: AlternativeGroup
    var onChoose: ((Int) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    private let palette: Palette

    init(group: AlternativeGroup, palette: Palette) {
        self.group = group
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = palette.panel.cgColor
        let title = UIStyle.label("ALTERNATIVES", size: 10, color: palette.muted, weight: .bold)
        title.setAccessibilityLabel("Alternatives")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 5
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, option) in group.options.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let symbol = option.source == .ai ? "sparkle" : (index == 0 ? "circle" : "pencil.line")
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: option.source == .ai ? "AI suggestion" : "Human alternative") ?? NSImage())
            icon.contentTintColor = option.source == .ai ? Ink.amber : Ink.teal
            icon.translatesAutoresizingMaskIntoConstraints = false
            let button = NSButton(title: option.text, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.alignment = .left
            button.isBordered = false
            button.font = .monospacedSystemFont(ofSize: 13, weight: index == group.selectedIndex ? .semibold : .regular)
            button.contentTintColor = palette.text
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = option.text
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(icon); row.addSubview(button)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor), icon.centerYAnchor.constraint(equalTo: row.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                button.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), button.trailingAnchor.constraint(equalTo: row.trailingAnchor), button.topAnchor.constraint(equalTo: row.topAnchor), button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                row.widthAnchor.constraint(equalToConstant: 295), row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
            ])
            list.addArrangedSubview(row)
        }
        let add = NSButton(title: "＋  Add an alternative", target: self, action: #selector(addAlternative))
        add.bezelStyle = .rounded
        add.font = .systemFont(ofSize: 12)
        add.contentTintColor = palette.text
        let footer = UIStyle.label("Original is kept with every group", size: 10, color: palette.muted)
        let stack = NSStackView(views: [title, list, add, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 15), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        self.view = root
        preferredContentSize = NSSize(width: 330, height: min(350, 95 + CGFloat(group.options.count) * 39))
    }

    @objc private func choose(_ sender: NSButton) { onChoose?(sender.tag) }
    @objc private func addAlternative() { onAdd?() }
}
