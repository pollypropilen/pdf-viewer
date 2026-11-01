import AppKit
import PDFKit

private final class CachedImage: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

final class DjVuDocument: @unchecked Sendable {
    private let handle: OpaquePointer
    private let imageCache = NSCache<NSString, CachedImage>()
    let pageCount: Int
    let bookmarks: [(title: String, page: Int, level: Int)]

    init?(url: URL) {
        guard let opened = url.path.withCString({ pdv_djvu_open($0) }) else { return nil }
        handle = opened
        pageCount = Int(pdv_djvu_page_count(opened))
        var entries: [(String, Int, Int)] = []
        for index in 0..<Int(pdv_djvu_bookmark_count(opened)) {
            guard let title = pdv_djvu_bookmark_title(opened, Int32(index)) else { continue }
            entries.append((String(cString: title), Int(pdv_djvu_bookmark_page(opened, Int32(index))),
                            Int(pdv_djvu_bookmark_level(opened, Int32(index)))))
        }
        bookmarks = entries
        imageCache.totalCostLimit = 128 * 1024 * 1024
    }

    deinit { pdv_djvu_close(handle) }

    func pageSize(at index: Int) -> CGSize? {
        var width: Int32 = 0, height: Int32 = 0, dpi: Int32 = 0
        guard pdv_djvu_page_info(handle, Int32(index), &width, &height, &dpi) != 0 else { return nil }
        let resolution = CGFloat(max(1, dpi))
        return CGSize(width: CGFloat(width) * 72 / resolution,
                      height: CGFloat(height) * 72 / resolution)
    }

    func image(at index: Int, requestedWidth: Int) -> CGImage? {
        let bucket = [256, 512, 1024, 2048, 4096].first(where: { $0 >= requestedWidth }) ?? 4096
        let key = "\(index)-\(bucket)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached.image }
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        guard pdv_djvu_render(handle, Int32(index), Int32(bucket), &pixels, &width, &height) != 0,
              let pixels, width > 0, height > 0 else { return nil }
        let data = Data(bytes: pixels, count: Int(width) * Int(height) * 3)
        pdv_djvu_free(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8,
                                  bitsPerPixel: 24, bytesPerRow: Int(width) * 3,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        imageCache.setObject(CachedImage(image), forKey: key, cost: Int(width) * Int(height) * 3)
        return image
    }

    func pageText(at index: Int) -> String {
        guard let text = pdv_djvu_page_text(handle, Int32(index)) else { return "" }
        defer { pdv_djvu_free(text) }
        return String(cString: text)
    }

    func makePDFDocument() -> PDFDocument? {
        let proxy = PDFDocument()
        for index in 0..<pageCount {
            guard let size = pageSize(at: index) else { return nil }
            let page = DjVuPage(source: self, index: index, size: size)
            proxy.insert(page, at: index)
        }
        return proxy
    }

    func makeOutline(for document: PDFDocument) -> PDFOutline? {
        guard !bookmarks.isEmpty else { return nil }
        let root = PDFOutline()
        var parents: [PDFOutline] = [root]
        for bookmark in bookmarks {
            guard let page = document.page(at: bookmark.page) else { continue }
            let level = min(bookmark.level, parents.count - 1)
            parents = Array(parents.prefix(level + 1))
            let item = PDFOutline()
            item.label = bookmark.title
            item.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .cropBox).height))
            let parent = parents[level]
            parent.insertChild(item, at: parent.numberOfChildren)
            parents.append(item)
        }
        return root
    }
}

private final class DjVuPage: PDFPage {
    private let source: DjVuDocument
    private let index: Int

    init(source: DjVuDocument, index: Int, size: CGSize) {
        self.source = source
        self.index = index
        super.init()
        let bounds = CGRect(origin: .zero, size: size)
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            setBounds(bounds, for: box)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let bounds = bounds(for: box)
        let transform = context.ctm
        let scale = hypot(transform.a, transform.b)
        let requestedWidth = max(256, Int((bounds.width * scale * 2).rounded(.up)))
        guard let image = source.image(at: index, requestedWidth: requestedWidth) else { return }
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

}
