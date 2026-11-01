# pdf-viewer for macOS

A small, native PDF and DjVu viewer written in Swift with AppKit, PDFKit, and DjVuLibre. This is the first macOS edition inspired by the Windows KillerPDF 1.9.1 source tree and the DjView4 4.12 sources. It has no .NET or Qt runtime dependency.

## Features in this edition

- Open PDF, DjVu, and DjV files from the File menu, Finder, command line, or drag and drop.
- Use a separate window for each document.
- Navigate by page number, thumbnails, or document outline, including DjVu bookmarks.
- Search PDF text with highlighted matches. Search a DjVu hidden text layer by page when one is present; image-only DjVu scans have no searchable text.
- Switch between continuous and two-page reading, zoom, and fit the page or width. PDF files also support text selection, links, and printing.
- Open password-protected PDFs.

The interface is English only. This edition is a viewer: it does not save changes to PDF files.

The dark workspace, compact controls, left page strip, and footer follow the screenshots in `../KillerPDF-1.9.1/docs/`. The [KillerPDF 1.9.0 overview on Habr](https://habr.com/ru/news/1101878/) informed the capability split: page thumbnails, search, text selection, printing, and password prompts belong in the viewer; page reordering, annotations, signing, and direct text edits belong to the editor milestone. The [Foxit PDF Reader page](https://www.foxit.com/pdf-reader/) was a secondary reference for the reading workflow. Features listed on either site are not automatically implemented here.

## Build

Requires macOS 13 or later, Xcode's Swift toolchain, and the standard C/C++ build tools. From this directory:

```sh
./build-app.sh
```

The script builds the vendored DjVuLibre 3.5.30 source as a static library on its first run. The optimized, locally signed app is written to `dist/pdf-viewer.app`; DjVuLibre is included in the executable, so users do not need Homebrew or Qt. Open it in Finder or run `open dist/pdf-viewer.app`. The bundle is signed ad hoc for local development; public distribution will need an Apple Developer signature and notarization.

The source archive in `Vendor/` is DjVuLibre 3.5.30, downloaded from the [official SourceForge release](https://sourceforge.net/projects/djvu/files/DjVuLibre/3.5.30/). `build-app.sh` checks its SHA-256 before compiling. DjVuLibre is GPL-2.0-or-later; its license is copied into the application bundle. The app itself is GPLv3. See the [DjVuLibre documentation](https://djvu.sourceforge.net/doc/index.html) and the [DjView4 overview](https://djvu.sourceforge.net/djview4.html).

## Windows source analysis and port plan

The Windows app is a large WPF shell targeting `net10.0-windows` (`KillerPDF-1.9.1/KillerPDF.csproj`, `Shell/MainWindow.xaml`). Its viewer is split across `Controls/Viewer/PdfViewer.*` and `Features/Viewer/*`. Windows-specific UI, printing, file dialogs, TWAIN scanning, and installer code cannot be compiled as a Swift macOS app.

The separate `engine/KillerPdf.Engine` library targets cross-platform .NET 10. It owns parsing, rendering, search, editing, OCR, signatures, redaction, and PDF writing. The engine is reusable in principle, but embedding it would add a .NET runtime and a Swift-to-.NET boundary. For a lightweight first edition, macOS PDFKit supplies PDF reading and rendering, while DjVuLibre decodes DjVu pages through its C API. This means rendering and PDF edge-case behavior may differ from KillerPDF's engine; the two apps are not yet feature-equivalent.

DjView4 4.12 is a Qt interface over DjVuLibre. Its source in `../djvu/djview4-4.12/` informed the supported DjVu workflows; the app does not copy or embed that Qt interface. DjVu pages are decoded on demand into native page views, with a bounded image cache. Bookmarks and page dimensions are read from the document. DjVu search uses its hidden text layer and navigates to matching pages without text highlighting or selection. The supplied 226-page test document, `Ponedelnik_nachinaetsya_v_subbotu.djvu`, contains an outline but its first page has no hidden text.

| Windows capability | macOS edition 1 | Planned edition 2 |
| --- | --- | --- |
| Tabs and split panes | One native window per PDF | Evaluate tabs and compare view |
| PDF rendering, navigation, outlines, search | PDFKit | Keep and validate against document corpus |
| DjVu rendering, thumbnails, bookmarks, hidden-text page search | DjVuLibre and native UI | Improve text selection and search highlighting |
| Annotations and forms | View only | Add markup, form filling, save as, undo |
| Page organization | View only | Rotate, reorder, insert, delete, merge, split |
| Source text editing, OCR, redaction, signatures | Not available | Separate engineering milestones; evaluate a bridge to `KillerPdf.Engine` where PDFKit is insufficient |

The first editor milestone should use a document model with explicit dirty state, undo/redo, permission checks, atomic Save As, and reopen verification. Real redaction must remove underlying content; a visible black rectangle is not sufficient. Digital signing and source text editing require dedicated PDF engine work and validation against the Windows test corpus.

This repository includes its own GPLv3 license. The macOS implementation is new Swift code and does not copy the WPF UI or C# engine.
