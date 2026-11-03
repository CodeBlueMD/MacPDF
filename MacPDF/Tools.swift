import PDFKit
import SwiftUI

/// The tabs across the top of the window; each shows its own row of tools.
enum Mode: String, CaseIterable, Identifiable {
    case annotate, edit, export, fillSign, scan, measure

    var id: Self { self }

    var title: String {
        switch self {
        case .annotate: "Annotate"
        case .edit: "Edit"
        case .export: "Export"
        case .fillSign: "Fill & Sign"
        case .scan: "Scan & OCR"
        case .measure: "Measure"
        }
    }

    var symbol: String {
        switch self {
        case .annotate: "highlighter"
        case .edit: "character.cursor.ibeam"
        case .export: "square.and.arrow.up"
        case .fillSign: "signature"
        case .scan: "doc.viewfinder"
        case .measure: "ruler"
        }
    }
}

enum Tool: Hashable {
    case select
    // Annotate
    case highlight, underline, strikeOut, pen, eraser, textBox, shape, note, stamp, signature, snapshot
    // Edit
    case editText, image, link, redact
    // Fill & Sign
    case date, checkmark, cross
    // Scan
    case crop
    // Measure
    case distance, area

    var title: String {
        switch self {
        case .select: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .pen: "Pen"
        case .eraser: "Eraser"
        case .textBox: "Text"
        case .shape: "Shapes"
        case .note: "Comment"
        case .stamp: "Stamp"
        case .signature: "Signature"
        case .snapshot: "Copy Area as Image"
        case .editText: "Text"
        case .image: "Image"
        case .link: "Link"
        case .redact: "Redact"
        case .date: "Date"
        case .checkmark: "Checkmark"
        case .cross: "Cross"
        case .crop: "Crop Pages"
        case .distance: "Distance"
        case .area: "Area"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .textBox: "character.textbox"
        case .shape: "square.on.circle"
        case .note: "text.bubble"
        case .stamp: "seal"
        case .signature: "signature"
        case .snapshot: "rectangle.dashed"
        case .editText: "character.cursor.ibeam"
        case .image: "photo"
        case .link: "link"
        case .redact: "rectangle.inset.filled"
        case .date: "calendar"
        case .checkmark: "checkmark.square"
        case .cross: "xmark.square"
        case .crop: "crop"
        case .distance: "ruler"
        case .area: "square.dashed"
        }
    }

    /// Markup tools act on a text selection rather than a click.
    var markupSubtype: PDFAnnotationSubtype? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: nil
        }
    }

    var defaultColor: Color {
        switch self {
        case .highlight, .note: .yellow
        case .underline, .strikeOut, .shape, .distance, .area: .red
        case .pen: .blue
        default: .black
        }
    }

    /// Whether the tool has a color the user can change.
    var hasColor: Bool {
        switch self {
        case .highlight, .underline, .strikeOut, .pen, .textBox, .shape, .note,
             .redact, .date, .checkmark, .cross, .distance, .area: true
        default: false
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case rectangle, oval, line, arrow
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        }
    }
}

enum StampKind: String, CaseIterable, Identifiable {
    case approved = "Approved"
    case notApproved = "NotApproved"
    case draft = "Draft"
    case final = "Final"
    case confidential = "Confidential"
    case forComment = "ForComment"
    case asIs = "AsIs"
    case expired = "Expired"
    case topSecret = "TopSecret"

    var id: Self { self }

    var color: NSColor {
        switch self {
        case .approved, .final: NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 1)
        case .notApproved, .confidential, .expired, .topSecret: NSColor(red: 0.78, green: 0.12, blue: 0.12, alpha: 1)
        case .draft, .forComment: NSColor(red: 0.12, green: 0.32, blue: 0.75, alpha: 1)
        case .asIs: NSColor(white: 0.35, alpha: 1)
        }
    }

    var title: String {
        switch self {
        case .notApproved: "Not Approved"
        case .forComment: "For Comment"
        case .asIs: "As Is"
        case .topSecret: "Top Secret"
        default: rawValue
        }
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case thumbnails, outline, annotations, search
    var id: Self { self }
    var symbol: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        case .annotations: "highlighter"
        case .search: "magnifyingglass"
        }
    }
}

enum ExportKind: CaseIterable, Identifiable {
    case word, excel, text, image
    var id: Self { self }
    var title: String {
        switch self {
        case .word: "to Word"
        case .excel: "to Excel"
        case .text: "to Text"
        case .image: "to Image"
        }
    }
    var symbol: String {
        switch self {
        case .word: "w.square"
        case .excel: "x.square"
        case .text: "t.square"
        case .image: "photo"
        }
    }
}
