import AppKit
import PDFKit

@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Palette {
        static let chrome = NSColor(srgbRed: 0.092, green: 0.095, blue: 0.102, alpha: 1)
        static let sidebar = NSColor(srgbRed: 0.105, green: 0.112, blue: 0.118, alpha: 1)
        static let canvas = NSColor(srgbRed: 0.17, green: 0.18, blue: 0.19, alpha: 1)
        static let accent = NSColor(srgbRed: 0.67, green: 0.74, blue: 0.64, alpha: 1)
        static let secondary = NSColor(srgbRed: 0.68, green: 0.70, blue: 0.70, alpha: 1)
    }

    var onClose: (() -> Void)?
    private(set) var documentURL: URL?
    private var pdfDocument: PDFDocument?
    private var djvuDocument: DjVuDocument?
    private var djvuOutlineRoot: PDFOutline?
    private let pdfView = PDFView()
    private let thumbnailView = PDFThumbnailView()
    private let djvuThumbnailView = NSTableView()
    private let djvuThumbnailScroll = NSScrollView()
    private let outlineView = NSOutlineView()
    private let sidebar = NSView()
    private let splitView = NSSplitView()
    private let sidebarMode = NSSegmentedControl(labels: ["Pages", "Outline"], trackingMode: .selectOne, target: nil, action: nil)
    private let pageField = NSTextField(string: "")
    private let pageCountLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let searchCountLabel = NSTextField(labelWithString: "")
    private let documentTabLabel = NSTextField(labelWithString: "No document")
    private let statusLabel = NSTextField(labelWithString: "No document")
    private let pageSizeLabel = NSTextField(labelWithString: "")
    private let displayModeControl = NSSegmentedControl(labels: ["Continuous", "Two Page"], trackingMode: .selectOne, target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "Open a PDF or DjVu (⌘O), or drop one here")
    private let searchPopover = NSPopover()
    private var searchButton: NSButton?
    private var continuousToolButton: ChromeIconButton?
    private var twoPageToolButton: ChromeIconButton?
    private var pagesToolButton: ChromeIconButton?
    private var outlineToolButton: ChromeIconButton?
    private var matches: [PDFSelection] = []
    private var djvuMatches: [Int] = []
    private var matchIndex = 0
    private var lastQuery = ""
    private var observations: [NSObjectProtocol] = []
    private var scrollObservation: NSObjectProtocol?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "pdf-viewer"
        window.minSize = NSSize(width: 680, height: 460)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.chrome
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("PDFViewerWindow")
        super.init(window: window)
        window.delegate = self
        window.nextResponder = self
        buildInterface()
        observePDFView()
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func windowWillClose(_ notification: Notification) {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        onClose?()
    }

    func loadDocument(_ url: URL) {
        let isDjVu = ["djvu", "djv"].contains(url.pathExtension.lowercased())
        let djvu = isDjVu ? DjVuDocument(url: url) : nil
        guard let pdf = isDjVu ? djvu?.makePDFDocument() : PDFDocument(url: url) else {
            showError("Could not open document: \(url.lastPathComponent)")
            return
        }
        if !isDjVu && pdf.isLocked {
            guard let password = askPassword(for: url), pdf.unlock(withPassword: password) else {
                showError("Could not unlock PDF: \(url.lastPathComponent)")
                return
            }
        }
        guard pdf.pageCount > 0 else {
            showError("Document has no pages: \(url.lastPathComponent)")
            return
        }
        documentURL = url
        djvuDocument = djvu
        djvuOutlineRoot = djvu?.makeOutline(for: pdf)
        pdfDocument = pdf
        pdfView.document = pdf
        pdfView.autoScales = false
        observeScroll()
        thumbnailView.pdfView = djvu == nil ? pdfView : nil
        djvuThumbnailView.reloadData()
        outlineView.reloadData()
        sidebarMode.setEnabled(activeOutlineRoot?.numberOfChildren ?? 0 > 0, forSegment: 1)
        if sidebarMode.selectedSegment == 1 && !sidebarMode.isEnabled(forSegment: 1) {
            sidebarMode.selectedSegment = 0
        }
        changeSidebarMode(nil)
        emptyLabel.isHidden = true
        window?.title = url.lastPathComponent
        window?.representedURL = url
        documentTabLabel.stringValue = url.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        clearSearch()
        refreshStatus()
        DispatchQueue.main.async { [weak self] in self?.fitPage(nil) }
    }

    private func buildInterface() {
        guard let window else { return }
        let root = PDFDropView()
        root.onDrop = { [weak self] url in self?.loadDocument(url) }
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.chrome.cgColor
        window.contentView = root

        let titleBar = ChromeBarView(draggable: true)
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleBar)

        let titleContent = NSStackView()
        titleContent.orientation = .horizontal
        titleContent.alignment = .centerY
        titleContent.spacing = 7
        titleContent.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleContent)
        let appIcon = NSImageView(image: NSImage(contentsOfFile: Bundle.main.path(forResource: "pdf-viewer", ofType: "png") ?? "") ?? NSImage())
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        titleContent.addArrangedSubview(appIcon)
        let brand = NSTextField(labelWithString: "pdf-viewer")
        brand.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        brand.textColor = NSColor(white: 0.88, alpha: 1)
        titleContent.addArrangedSubview(brand)
        let titleGap = NSView()
        titleGap.widthAnchor.constraint(equalToConstant: 9).isActive = true
        titleContent.addArrangedSubview(titleGap)
        documentTabLabel.textColor = Palette.secondary
        documentTabLabel.font = .systemFont(ofSize: 11)
        documentTabLabel.lineBreakMode = .byTruncatingMiddle
        documentTabLabel.maximumNumberOfLines = 1
        documentTabLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        titleContent.addArrangedSubview(documentTabLabel)
        NSLayoutConstraint.activate([
            titleContent.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 86),
            titleContent.trailingAnchor.constraint(lessThanOrEqualTo: titleBar.trailingAnchor, constant: -12),
            titleContent.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor)
        ])

        let toolbar = ChromeBarView(draggable: false)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        let leftTools = NSStackView()
        leftTools.orientation = .horizontal
        leftTools.alignment = .centerY
        leftTools.spacing = 1
        leftTools.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(leftTools)
        let rightTools = NSStackView()
        rightTools.orientation = .horizontal
        rightTools.alignment = .centerY
        rightTools.spacing = 1
        rightTools.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(rightTools)
        NSLayoutConstraint.activate([
            leftTools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 7),
            leftTools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            leftTools.trailingAnchor.constraint(lessThanOrEqualTo: rightTools.leadingAnchor, constant: -12),
            rightTools.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            rightTools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        leftTools.addArrangedSubview(toolButton("New Window", symbol: "doc", action: #selector(newWindow(_:))))
        leftTools.addArrangedSubview(toolButton("Close Window", symbol: "xmark", action: #selector(closeCurrentWindow(_:))))
        leftTools.addArrangedSubview(toolButton("Open PDF or DjVu", symbol: "folder", action: #selector(openFile(_:))))
        leftTools.addArrangedSubview(toolButton("Recent Files", symbol: "chevron.down", action: #selector(showRecentFiles(_:)), width: 18))
        leftTools.addArrangedSubview(toolButton("Print PDF", symbol: "printer", action: #selector(printDocument(_:))))
        leftTools.addArrangedSubview(toolbarSeparator())
        leftTools.addArrangedSubview(toolButton("Previous Page", symbol: "arrow.up", action: #selector(previousPage(_:))))
        leftTools.addArrangedSubview(toolButton("Next Page", symbol: "arrow.down", action: #selector(nextPage(_:))))
        leftTools.addArrangedSubview(toolbarSeparator())
        leftTools.addArrangedSubview(toolButton("Zoom Out", symbol: "minus", action: #selector(zoomOut(_:))))
        leftTools.addArrangedSubview(toolButton("Zoom In", symbol: "plus", action: #selector(zoomIn(_:))))
        leftTools.addArrangedSubview(toolButton("Fit Width", symbol: "arrow.left.and.right", action: #selector(fitWidth(_:))))
        leftTools.addArrangedSubview(toolButton("Fit Page", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(fitPage(_:))))

        let selectButton = toolButton("Select Text", symbol: "cursorarrow", action: #selector(focusDocument(_:)))
        selectButton.isSelected = true
        rightTools.addArrangedSubview(selectButton)
        pagesToolButton = toolButton("Pages", symbol: "square.grid.2x2", action: #selector(showPages(_:)))
        rightTools.addArrangedSubview(pagesToolButton!)
        outlineToolButton = toolButton("Outline", symbol: "list.bullet.rectangle", action: #selector(showOutline(_:)))
        rightTools.addArrangedSubview(outlineToolButton!)
        rightTools.addArrangedSubview(toolbarSeparator())
        continuousToolButton = toolButton("Continuous", symbol: "rectangle.stack", action: #selector(showContinuous(_:)))
        rightTools.addArrangedSubview(continuousToolButton!)
        twoPageToolButton = toolButton("Two Page", symbol: "rectangle.split.2x1", action: #selector(showTwoPage(_:)))
        rightTools.addArrangedSubview(twoPageToolButton!)
        rightTools.addArrangedSubview(toolButton("Toggle Sidebar", symbol: "sidebar.left", action: #selector(toggleSidebar(_:))))
        searchButton = toolButton("Find in Document", symbol: "magnifyingglass", action: #selector(focusSearch(_:)))
        rightTools.addArrangedSubview(searchButton!)
        continuousToolButton?.isSelected = true
        pagesToolButton?.isSelected = true

        buildSearchPopover()

        let statusBar = NSStackView()
        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 12
        statusBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        styleBar(statusBar, color: Palette.chrome)
        root.addSubview(statusBar)

        pageField.placeholderString = "Page"
        pageField.alignment = .right
        pageField.target = self
        pageField.action = #selector(goToPage(_:))
        pageField.delegate = self
        statusLabel.textColor = Palette.secondary
        statusLabel.font = .systemFont(ofSize: 11)
        pageSizeLabel.textColor = Palette.secondary
        pageSizeLabel.font = .systemFont(ofSize: 11)
        statusBar.addArrangedSubview(statusLabel)
        statusBar.addArrangedSubview(pageSizeLabel)
        statusBar.addArrangedSubview(NSView())
        pageField.widthAnchor.constraint(equalToConstant: 45).isActive = true
        statusBar.addArrangedSubview(pageField)
        statusBar.addArrangedSubview(pageCountLabel)
        zoomLabel.textColor = Palette.secondary
        zoomLabel.font = .systemFont(ofSize: 11)
        statusBar.addArrangedSubview(zoomLabel)
        displayModeControl.selectedSegment = 0
        displayModeControl.target = self
        displayModeControl.action = #selector(changeDisplayMode(_:))
        displayModeControl.controlSize = .small
        statusBar.addArrangedSubview(displayModeControl)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 31),
            toolbar.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 33),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 30)
        ])

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = Palette.sidebar.cgColor
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        splitView.addArrangedSubview(sidebar)

        sidebarMode.selectedSegment = 0
        sidebarMode.target = self
        sidebarMode.action = #selector(changeSidebarMode(_:))
        sidebarMode.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarMode)

        thumbnailView.backgroundColor = Palette.sidebar
        thumbnailView.thumbnailSize = NSSize(width: 128, height: 166)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(thumbnailView)

        djvuThumbnailScroll.hasVerticalScroller = true
        djvuThumbnailScroll.drawsBackground = true
        djvuThumbnailScroll.backgroundColor = Palette.sidebar
        djvuThumbnailScroll.translatesAutoresizingMaskIntoConstraints = false
        djvuThumbnailScroll.isHidden = true
        djvuThumbnailView.headerView = nil
        djvuThumbnailView.backgroundColor = Palette.sidebar
        djvuThumbnailView.rowHeight = 190
        djvuThumbnailView.intercellSpacing = NSSize(width: 0, height: 0)
        djvuThumbnailView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        djvuThumbnailView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DjVuPage")))
        djvuThumbnailView.dataSource = self
        djvuThumbnailView.delegate = self
        djvuThumbnailView.target = self
        djvuThumbnailView.action = #selector(openDjVuThumbnail(_:))
        djvuThumbnailScroll.documentView = djvuThumbnailView
        sidebar.addSubview(djvuThumbnailScroll)

        let outlineScroll = NSScrollView()
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = true
        outlineScroll.backgroundColor = Palette.sidebar
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineView.headerView = nil
        outlineView.backgroundColor = Palette.sidebar
        outlineView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")))
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(openOutlineItem(_:))
        outlineScroll.documentView = outlineView
        outlineScroll.isHidden = true
        sidebar.addSubview(outlineScroll)
        NSLayoutConstraint.activate([
            sidebarMode.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            sidebarMode.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sidebarMode.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            thumbnailView.topAnchor.constraint(equalTo: sidebarMode.bottomAnchor, constant: 10),
            thumbnailView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            djvuThumbnailScroll.topAnchor.constraint(equalTo: sidebarMode.bottomAnchor, constant: 10),
            djvuThumbnailScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            djvuThumbnailScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            djvuThumbnailScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            outlineScroll.topAnchor.constraint(equalTo: sidebarMode.bottomAnchor, constant: 10),
            outlineScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])

        pdfView.backgroundColor = Palette.canvas
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        splitView.addArrangedSubview(pdfView)
        splitView.setPosition(220, ofDividerAt: 0)

        emptyLabel.alignment = .center
        emptyLabel.textColor = Palette.secondary
        emptyLabel.font = .systemFont(ofSize: 17)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor)
        ])
    }

    private func button(_ title: String, symbol: String?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = Palette.button.cgColor
        button.layer?.cornerRadius = 5
        button.contentTintColor = .white
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        button.heightAnchor.constraint(equalToConstant: 27).isActive = true
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = title.count > 1 ? .imageLeading : .imageOnly
            button.toolTip = title
        }
        return button
    }

    private func styleBar(_ bar: NSStackView, color: NSColor) {
        bar.wantsLayer = true
        bar.layer?.backgroundColor = color.cgColor
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return box
    }

    private func observePDFView() {
        observations.append(NotificationCenter.default.addObserver(forName: Notification.Name("PDFViewPageChanged"), object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: Notification.Name("PDFViewScaleChanged"), object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
    }

    private func observeScroll() {
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        guard let contentView = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        contentView.postsBoundsChangedNotifications = true
        scrollObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private var visiblePage: PDFPage? {
        let center = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        return pdfView.page(for: center, nearest: true) ?? pdfView.currentPage
    }

    private func refreshStatus() {
        guard let pdfDocument else {
            pageField.stringValue = ""
            pageCountLabel.stringValue = "/ 0"
            zoomLabel.stringValue = "—"
            statusLabel.stringValue = "No document"
            pageSizeLabel.stringValue = ""
            return
        }
        if let page = visiblePage {
            let number = pdfDocument.index(for: page) + 1
            pageField.stringValue = String(number)
            statusLabel.stringValue = "\(djvuDocument == nil ? "PDF" : "DjVu") · Page \(number) of \(pdfDocument.pageCount)"
            let size = page.bounds(for: .cropBox).size
            pageSizeLabel.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"
            if djvuDocument != nil && djvuThumbnailView.selectedRow != number - 1 {
                djvuThumbnailView.selectRowIndexes(IndexSet(integer: number - 1), byExtendingSelection: false)
            }
        }
        pageCountLabel.stringValue = "/ \(pdfDocument.pageCount)"
        zoomLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded()))%"
    }

    private func askPassword(for url: URL) -> String? {
        let alert = NSAlert()
        alert.messageText = "Password protected PDF"
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open Error"
        alert.informativeText = message
        alert.runModal()
    }

    @objc func openFile(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.openDocument(sender) }

    @objc func goToPage(_ sender: Any?) {
        guard let pdfDocument, let number = Int(pageField.stringValue),
              number >= 1, number <= pdfDocument.pageCount,
              let page = pdfDocument.page(at: number - 1) else {
            refreshStatus()
            return
        }
        pdfView.go(to: page)
        refreshStatus()
    }

    @objc func nextPage(_ sender: Any?) {
        guard let pdfDocument, let page = visiblePage,
              let next = pdfDocument.page(at: pdfDocument.index(for: page) + (displayModeControl.selectedSegment == 1 ? 2 : 1)) else { return }
        pdfView.go(to: next)
        refreshStatus()
    }

    @objc func previousPage(_ sender: Any?) {
        guard let pdfDocument, let page = visiblePage,
              let previous = pdfDocument.page(at: pdfDocument.index(for: page) - (displayModeControl.selectedSegment == 1 ? 2 : 1)) else { return }
        pdfView.go(to: previous)
        refreshStatus()
    }
    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender); refreshStatus() }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender); refreshStatus() }

    @objc func fitWidth(_ sender: Any?) {
        guard let page = visiblePage else { return }
        pdfView.autoScales = false
        let columns: CGFloat = displayModeControl.selectedSegment == 1 ? 2 : 1
        let pageWidth = page.bounds(for: .cropBox).width * columns + (columns - 1) * 12
        let availableWidth = max(1, pdfView.bounds.width - 40)
        pdfView.scaleFactor = availableWidth / max(1, pageWidth)
        refreshStatus()
    }

    @objc func fitPage(_ sender: Any?) {
        guard let page = visiblePage else { return }
        pdfView.autoScales = false
        let size = page.bounds(for: .cropBox).size
        let columns: CGFloat = displayModeControl.selectedSegment == 1 ? 2 : 1
        let availableWidth = max(1, pdfView.bounds.width - 40)
        let availableHeight = max(1, pdfView.bounds.height - 40)
        let pageWidth = max(1, size.width * columns + (columns - 1) * 12)
        let pageHeight = max(1, size.height)
        pdfView.scaleFactor = min(availableWidth / pageWidth, availableHeight / pageHeight)
        refreshStatus()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebar.isHidden.toggle()
    }

    @objc func changeSidebarMode(_ sender: Any?) {
        let outlines = sidebarMode.selectedSegment == 1
        sidebar.subviews.compactMap { $0 as? NSScrollView }.forEach { $0.isHidden = !outlines }
        thumbnailView.isHidden = outlines || djvuDocument != nil
        djvuThumbnailScroll.isHidden = outlines || djvuDocument == nil
    }

    @objc func changeDisplayMode(_ sender: Any?) {
        pdfView.displayMode = displayModeControl.selectedSegment == 1 ? .twoUpContinuous : .singlePageContinuous
        fitPage(sender)
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func runSearch(_ sender: Any?) {
        guard let pdfDocument else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        lastQuery = query
        if let djvuDocument {
            djvuMatches = (0..<djvuDocument.pageCount).filter {
                djvuDocument.pageText(at: $0).localizedCaseInsensitiveContains(query)
            }
            matchIndex = 0
            if !djvuMatches.isEmpty { showMatch() }
            else { searchCountLabel.stringValue = "0 pages" }
            return
        }
        matches = pdfDocument.findString(query, withOptions: .caseInsensitive)
        matchIndex = 0
        pdfView.highlightedSelections = matches
        if !matches.isEmpty { showMatch() }
        else { searchCountLabel.stringValue = "0 results" }
    }

    private func showMatch() {
        if !djvuMatches.isEmpty {
            guard djvuMatches.indices.contains(matchIndex),
                  let page = pdfDocument?.page(at: djvuMatches[matchIndex]) else { return }
            pdfView.go(to: page)
            searchCountLabel.stringValue = "\(matchIndex + 1)/\(djvuMatches.count) pages"
            return
        }
        guard matches.indices.contains(matchIndex) else { return }
        let selection = matches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        searchCountLabel.stringValue = "\(matchIndex + 1)/\(matches.count)"
    }

    private func clearSearch() {
        matches.removeAll()
        djvuMatches.removeAll()
        lastQuery = ""
        pdfView.highlightedSelections = nil
        searchCountLabel.stringValue = ""
    }

    @objc func nextMatch(_ sender: Any?) {
        let count = djvuDocument == nil ? matches.count : djvuMatches.count
        if count == 0 || searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != lastQuery {
            runSearch(sender)
            return
        }
        matchIndex = (matchIndex + 1) % count
        showMatch()
    }

    @objc func previousMatch(_ sender: Any?) {
        let count = djvuDocument == nil ? matches.count : djvuMatches.count
        if count == 0 || searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != lastQuery {
            runSearch(sender)
            return
        }
        matchIndex = (matchIndex - 1 + count) % count
        showMatch()
    }

    @objc func printDocument(_ sender: Any?) {
        guard pdfDocument != nil else { return }
        if djvuDocument != nil {
            let alert = NSAlert()
            alert.messageText = "DjVu printing is unavailable"
            alert.informativeText = "Printing DjVu pages is not supported in this edition."
            alert.runModal()
            return
        }
        pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? PDFOutline ?? activeOutlineRoot)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? PDFOutline ?? activeOutlineRoot)!.child(at: index)!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PDFOutline)?.numberOfChildren ?? 0 > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
        }
        cell.identifier = identifier
        cell.textField?.stringValue = (item as? PDFOutline)?.label ?? "Untitled"
        return cell
    }

    @objc func openOutlineItem(_ sender: Any?) {
        guard outlineView.selectedRow >= 0,
              let outline = outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline,
              let destination = outline.destination else { return }
        pdfView.go(to: destination)
        refreshStatus()
    }

    private var activeOutlineRoot: PDFOutline? { djvuOutlineRoot ?? pdfDocument?.outlineRoot }

    func numberOfRows(in tableView: NSTableView) -> Int { djvuDocument?.pageCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DjVuThumbnailCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.imageView == nil {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.textColor = Palette.secondary
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                imageView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
                imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
                imageView.heightAnchor.constraint(equalToConstant: 152),
                label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
                label.centerXAnchor.constraint(equalTo: cell.centerXAnchor)
            ])
        }
        if let image = djvuDocument?.image(at: row, requestedWidth: 300) {
            cell.imageView?.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } else {
            cell.imageView?.image = nil
        }
        cell.textField?.stringValue = String(row + 1)
        cell.identifier = identifier
        return cell
    }

    @objc private func openDjVuThumbnail(_ sender: Any?) {
        guard let page = pdfDocument?.page(at: djvuThumbnailView.selectedRow) else { return }
        pdfView.go(to: page)
        refreshStatus()
    }
}

@MainActor
private final class PDFDropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURL(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first,
              ["pdf", "djvu", "djv"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}
