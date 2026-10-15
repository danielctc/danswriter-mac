import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var updateController: UpdateController?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        Self.allowNativeSpellCheckingForThisApp()
        let controller = MainWindowController()
        windowController = controller
        let repository = Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String
        let channel = Bundle.main.object(forInfoDictionaryKey: "UpdateChannel") as? String
        let updates = UpdateController(repository: repository,
                                       installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                       privateChannel: channel == "private")
        updateController = updates
        installMainMenu(for: controller, updates: updates)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.reportRecoveryProblemIfNeeded()
        let pending = pendingOpenURLs
        pendingOpenURLs.removeAll()
        pending.forEach { _ = controller.openFile(at: $0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let url = filenames.first.map(URL.init(fileURLWithPath:)) else { sender.reply(toOpenOrPrint: .failure); return }
        guard let windowController else { pendingOpenURLs.append(url); sender.reply(toOpenOrPrint: .success); return }
        let opened = windowController.openFile(at: url)
        sender.reply(toOpenOrPrint: opened ? .success : .failure)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard let windowController else { pendingOpenURLs.append(url); return }
        _ = windowController.openFile(at: url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windowController?.canQuitWhileResearchStarts() != false else { return .terminateCancel }
        return windowController?.flushAutosave() == true ? .terminateNow : .terminateCancel
    }

    static func allowNativeSpellCheckingForThisApp() {
        // AppKit reads this allow gate before continuous checks are initialized. This writes only
        // DansWriter's defaults domain, leaving the user's global spelling preference untouched.
        UserDefaults.standard.set(true, forKey: "NSAllowContinuousSpellChecking")
    }

    func installMainMenu(for controller: MainWindowController, updates: UpdateController) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DansWriter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        settings.target = controller
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DansWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newItem = fileMenu.addItem(withTitle: "New", action: #selector(MainWindowController.newDocument(_:)), keyEquivalent: "n")
        newItem.target = controller
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(MainWindowController.openDocument(_:)), keyEquivalent: "o")
        openItem.target = controller
        fileMenu.addItem(.separator())
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = controller
        let saveAsItem = fileMenu.addItem(withTitle: "Save As…", action: #selector(MainWindowController.saveAs(_:)), keyEquivalent: "S")
        saveAsItem.target = controller
        let exportItem = fileMenu.addItem(withTitle: "Export Markdown…", action: #selector(MainWindowController.exportMarkdown(_:)), keyEquivalent: "e")
        exportItem.target = controller
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo", action: #selector(MainWindowController.undoEdit(_:)), keyEquivalent: "z")
        undo.target = controller
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(MainWindowController.redoEdit(_:)), keyEquivalent: "Z")
        redo.target = controller
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.target = nil
        let findNext = editMenu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        findNext.target = nil
        editMenu.addItem(.separator())
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = nil
        }
        editMenu.addItem(.separator())
        let pasteAs = NSMenuItem(title: "Paste As AI…", action: nil, keyEquivalent: "")
        pasteAs.submenu = controller.pasteColourMenu(operation: "paste-edit")
        editMenu.addItem(pasteAs)
        let markSelection = NSMenuItem(title: "Mark Selection as AI Paste…", action: nil, keyEquivalent: "")
        markSelection.submenu = controller.pasteColourMenu(operation: "mark-paste")
        editMenu.addItem(markSelection)
        let recolour = NSMenuItem(title: "Change AI Paste Colour…", action: nil, keyEquivalent: "")
        recolour.submenu = controller.pasteColourMenu(operation: "recolour-paste")
        editMenu.addItem(recolour)
        let clearPaste = editMenu.addItem(withTitle: "Remove AI Paste Mark", action: #selector(MainWindowController.clearPasteMark(_:)), keyEquivalent: "")
        clearPaste.target = controller
        editMenu.addItem(.separator())
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        let spellingPanel = spellingMenu.addItem(withTitle: "Show Spelling and Grammar", action: #selector(MainWindowController.showSpellingPanel(_:)), keyEquivalent: "")
        spellingPanel.target = controller
        let checkSpelling = spellingMenu.addItem(withTitle: "Check Document Now", action: #selector(MainWindowController.checkSpellingNow(_:)), keyEquivalent: "")
        checkSpelling.target = controller
        spellingMenu.addItem(.separator())
        let continuous = spellingMenu.addItem(withTitle: "Check Spelling While Typing", action: #selector(MainWindowController.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        continuous.target = controller
        let grammar = spellingMenu.addItem(withTitle: "Check Grammar With Spelling", action: #selector(MainWindowController.toggleGrammarChecking(_:)), keyEquivalent: "")
        grammar.target = controller
        let correction = spellingMenu.addItem(withTitle: "Correct Spelling Automatically", action: #selector(MainWindowController.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        correction.target = controller
        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (title, action, key) in [
            ("Toggle Alternatives", #selector(MainWindowController.toggleAlternatives(_:)), "1"),
            ("Toggle Overflow", #selector(MainWindowController.toggleOverflow(_:)), "2"),
            ("Clean Reading", #selector(MainWindowController.toggleCleanRead(_:)), "k"),
            ("Open Lab…", #selector(MainWindowController.showLab(_:)), "l"),
            ("Markdown Preview…", #selector(MainWindowController.showMarkdownPreview(_:)), "p"),
            ("Research with Valyu…", #selector(MainWindowController.showResearch(_:)), "r"),
        ] {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = controller
        }
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "DansWriter Keyboard Shortcuts", action: #selector(MainWindowController.showKeyboardShortcuts(_:)), keyEquivalent: "?").target = controller
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "").target = updates
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)
        NSApp.mainMenu = menu
    }

    @MainActor func installMainMenu(for controller: MainWindowController) {
        let updates = UpdateController(repository: nil, installedVersion: "")
        updateController = updates
        installMainMenu(for: controller, updates: updates)
    }
}

@main
enum WriteOnMain {
    private static let delegate = AppDelegate()

    static func main() {
#if DEBUG
        if CommandLine.arguments.contains("--self-check") {
            do {
                try MainWindowController.runDebugSelfCheck()
                fputs("WRITE_ON_SELF_CHECK_PASSED\n", stderr)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("WRITE_ON_SELF_CHECK_FAILED: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
#endif
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
