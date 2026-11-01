import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [ViewerWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        let fileArguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        for path in fileArguments {
            open(URL(fileURLWithPath: path))
        }
        if windows.isEmpty { showEmptyWindow() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEmptyWindow() }
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func openDocument(_ sender: Any?) {
        let target = NSApp.keyWindow?.windowController as? ViewerWindowController
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "djvu")!, UTType(filenameExtension: "djv")!]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open($0, in: target) }
        }
    }

    @objc func showEmptyWindow() {
        let controller = ViewerWindowController()
        retain(controller)
        controller.showWindow(nil)
    }

    func open(_ url: URL, in preferredWindow: ViewerWindowController? = nil) {
        guard url.isFileURL else { return }
        if let existing = windows.first(where: { $0.containsDocument(url) }) {
            existing.selectDocument(url)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller: ViewerWindowController
        if let preferredWindow, windows.contains(where: { $0 === preferredWindow }) {
            controller = preferredWindow
        } else if let focused = NSApp.keyWindow?.windowController as? ViewerWindowController {
            controller = focused
        } else if let visible = windows.last(where: { $0.window?.isVisible == true }) {
            controller = visible
        } else {
            controller = ViewerWindowController()
            retain(controller)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.loadDocument(url)
    }

    private func retain(_ controller: ViewerWindowController) {
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
    }

    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About pdf-viewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit pdf-viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(showEmptyWindow), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Print…", action: #selector(ViewerWindowController.printDocument(_:)), keyEquivalent: "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(ViewerWindowController.closeCurrentTab(_:)), keyEquivalent: "w")
        let closeWindow = file.addItem(withTitle: "Close Window", action: #selector(ViewerWindowController.closeCurrentWindow(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(ViewerWindowController.focusSearch(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "Find Next", action: #selector(ViewerWindowController.nextMatch(_:)), keyEquivalent: "g")
        let previous = edit.addItem(withTitle: "Find Previous", action: #selector(ViewerWindowController.previousMatch(_:)), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Next Page", action: #selector(ViewerWindowController.nextPage(_:)), keyEquivalent: "]")
        view.addItem(withTitle: "Previous Page", action: #selector(ViewerWindowController.previousPage(_:)), keyEquivalent: "[")
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In", action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Fit Width", action: #selector(ViewerWindowController.fitWidth(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "Fit Page", action: #selector(ViewerWindowController.fitPage(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        view.addItem(withTitle: "Pages", action: #selector(ViewerWindowController.showPages(_:)), keyEquivalent: "3")
        view.addItem(withTitle: "Outline", action: #selector(ViewerWindowController.showOutline(_:)), keyEquivalent: "4")
        view.addItem(.separator())
        view.addItem(withTitle: "Continuous", action: #selector(ViewerWindowController.showContinuous(_:)), keyEquivalent: "5")
        view.addItem(withTitle: "Two Page", action: #selector(ViewerWindowController.showTwoPage(_:)), keyEquivalent: "6")
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(ViewerWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: "Next Tab", action: #selector(ViewerWindowController.selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = windowMenu.addItem(withTitle: "Previous Tab", action: #selector(ViewerWindowController.selectPreviousTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
