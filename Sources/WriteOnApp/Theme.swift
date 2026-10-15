import AppKit

enum WriteOnTheme: String, CaseIterable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"
}

enum Ink {
    static let teal = NSColor(calibratedRed: 71/255, green: 125/255, blue: 120/255, alpha: 1)
    static let amber = NSColor(calibratedRed: 201/255, green: 151/255, blue: 85/255, alpha: 1)
    static let darkCanvas = NSColor(calibratedRed: 17/255, green: 25/255, blue: 35/255, alpha: 1)
    static let darkPanel = NSColor(calibratedRed: 21/255, green: 31/255, blue: 42/255, alpha: 1)
    static let lightCanvas = NSColor(calibratedRed: 246/255, green: 243/255, blue: 236/255, alpha: 1)
    static let lightPanel = NSColor(calibratedRed: 238/255, green: 235/255, blue: 226/255, alpha: 1)
    static let darkText = NSColor(calibratedRed: 239/255, green: 232/255, blue: 220/255, alpha: 1)
    static let lightText = NSColor(calibratedRed: 36/255, green: 42/255, blue: 41/255, alpha: 1)
    static let darkMuted = NSColor(calibratedRed: 142/255, green: 153/255, blue: 163/255, alpha: 1)
    static let lightMuted = NSColor(calibratedRed: 103/255, green: 109/255, blue: 105/255, alpha: 1)
}

struct Palette {
    let canvas: NSColor
    let panel: NSColor
    let text: NSColor
    let muted: NSColor
    let line: NSColor
    let isDark: Bool

    static func current(_ appearance: NSAppearance? = NSApp.effectiveAppearance) -> Palette {
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? Palette(canvas: Ink.darkCanvas, panel: Ink.darkPanel, text: Ink.darkText, muted: Ink.darkMuted, line: NSColor.white.withAlphaComponent(0.09), isDark: true)
            : Palette(canvas: Ink.lightCanvas, panel: Ink.lightPanel, text: Ink.lightText, muted: Ink.lightMuted, line: NSColor.black.withAlphaComponent(0.09), isDark: false)
    }
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

enum UIStyle {
    static func label(_ title: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        return field
    }

    static func button(_ title: String, action: Selector, target: AnyObject? = nil, palette: Palette, prominent: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: prominent ? .semibold : .medium)
        button.contentTintColor = prominent ? .white : palette.text
        if prominent {
            button.bezelColor = Ink.teal
        }
        return button
    }

    static func iconButton(_ symbol: String, help: String, action: Selector, target: AnyObject? = nil, palette: Palette) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: target, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = palette.muted
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    static func hairline(_ palette: Palette) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = palette.line.cgColor
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }
}
