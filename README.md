<p align="center">
  <img src="docs/screenshots/icon.png" width="128" alt="MacPDF icon">
</p>

<h1 align="center">MacPDF</h1>

<p align="center">
  A fast, native PDF editor for macOS. Annotate, edit, redact, sign, scan and export — built entirely on Apple's PDFKit and Vision, with no third-party dependencies.
</p>

<p align="center">
  <img src="docs/screenshots/annotate.png" alt="MacPDF annotating a report: highlight, underline, strikethrough, comment, circled number and an Approved stamp">
</p>

## Features

MacPDF organizes its tools into six modes, switchable from the tabs at the top of the window (or <kbd>⌘</kbd><kbd>⌃</kbd><kbd>1</kbd>–<kbd>6</kbd>).

### Annotate
![Annotate tools](docs/screenshots/toolbar-annotate.png)

Highlight, underline and strikethrough (select text to apply) · pen · eraser · text boxes · shapes (rectangle, oval, line, arrow) · comments · stamps (Approved, Draft, Confidential, …) · your saved signature · copy any area as an image. Every tool remembers its own color.

### Edit
![Edit tools](docs/screenshots/toolbar-edit.png)

- **Text** — click a line of text and retype it.
- **Image** — place a picture anywhere on the page.
- **Link** — drag a box and attach a web address.
- **Redact** — select text or drag a box; it turns into a solid block in the color you pick, and the content underneath is **permanently removed** from the file.

<p align="center">
  <img src="docs/screenshots/redaction.png" alt="An account number redacted with a solid black box">
</p>

### Export
![Export tools](docs/screenshots/toolbar-export.png)

Word (.docx, text with fonts and styles) · Excel (.csv, split into columns where the PDF has gaps) · plain text · one PNG image per page.

### Fill & Sign
![Fill & Sign tools](docs/screenshots/toolbar-fillsign.png)

Text · signature (draw once, reuse) · today's date · checkmark · cross · stamps · images. Fillable PDF form fields work too — click and type.

### Scan & OCR
![Scan & OCR tools](docs/screenshots/toolbar-scanocr.png)

- **Enhance Scan** — cleans up the background and sharpens text.
- **Split Pages** — cuts two-page book scans into separate pages.
- **Crop Pages** — drag a box around what to keep, on one page or all.
- **Clear Margins** — whites out dark scan edges.
- **Recognize Text** — on-device OCR adds an invisible text layer so scans become searchable and selectable. The page looks exactly the same.

### Measure
![Measure tools](docs/screenshots/toolbar-measure.png)

Distance and area, labeled in inches and centimeters.

### Also
- Tabs: each PDF opens as a tab in the same window.
- Sidebar: page thumbnails, table of contents, a list of every annotation, and search results.
- Search runs in the background with every match highlighted.
- Pages: insert from other PDFs (merge), insert blank pages, rotate, delete.
- Password-protected PDFs, printing, and full undo/redo (<kbd>⌘</kbd><kbd>Z</kbd>) for every change.

## How redaction works

Covering text with a black rectangle doesn't remove it — the words are still in the file and can be copied out. MacPDF removes them for real:

1. The box appears immediately.
2. In the background, the page is re-rendered at 300 dpi with the redacted areas painted in, so the original text and images under the box no longer exist anywhere in the file.
3. On-device OCR restores an invisible text layer for the **rest** of the page, so it stays searchable and selectable.
4. Annotations outside the redacted areas are carried over.

Undo brings back the original page. Pages you don't redact are never touched.

## Requirements

- macOS 14 Sonoma or later
- To build: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

```bash
git clone https://github.com/CodeBlueMD/MacPDF.git
cd MacPDF
xcodegen generate
xcodebuild -scheme MacPDF -configuration Release -derivedDataPath build build
open build/Build/Products/Release/MacPDF.app
```

Or open `MacPDF.xcodeproj` in Xcode and press <kbd>⌘</kbd><kbd>R</kbd>. To install, copy `MacPDF.app` into `/Applications`.

The app is ad-hoc signed for local use. To share it with other Macs, sign it with a Developer ID and notarize it.

## Project layout

| File | What it does |
|---|---|
| `MacPDFApp.swift` | App entry, document windows, menu commands |
| `PDFFile.swift` | Reading and saving PDF documents |
| `DocumentModel.swift` | Per-document state, annotations, text editing, pages, search, undo |
| `Tools.swift` | Modes, tools, shapes, stamps and export kinds |
| `MacPDFView.swift` | PDFView subclass: mouse handling for every tool, drag previews, inline text editing |
| `PageTools.swift` | Redaction, image/link placement, scan tools, measuring |
| `OCR.swift` | Page rendering, Vision text recognition, searchable page rebuilding |
| `Export.swift` | Word, Excel, text and image export |
| `ContentView.swift`, `ModeBar.swift`, `SidebarView.swift` | The interface |

## Limitations

- **Edit → Text** draws your new text over the original line rather than rewriting the PDF's own text, which PDFKit doesn't support. The old text remains underneath; redact the line first if it must be gone.
- Redacted, enhanced or margin-cleared pages become high-resolution images with an OCR text layer; selecting text on them is slightly less precise than on the original.
- Export to Excel produces CSV; Word export keeps text and styling but not exact page layout. There is no PowerPoint export.
- OCR works best on upright pages — rotate sideways scans first.

## Privacy

Everything runs on your Mac. OCR uses Apple's on-device Vision framework; no documents are uploaded anywhere. The app is sandboxed and only reads the files you open.
