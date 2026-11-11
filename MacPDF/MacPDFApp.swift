import SwiftUI

@main
struct MacPDFApp: App {
    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
        UserDefaults.standard.register(defaults: ["AppleWindowTabbingMode": "always"])
    }

    var body: some Scene {
        DocumentGroup(newDocument: { PDFFile() }) { file in
            ContentView(file: file.document, fileURL: file.fileURL)
        }
        .commands { MacPDFCommands() }
    }
}

struct MacPDFCommands: Commands {
    @FocusedObject private var model: DocumentModel?

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.print() }
                .keyboardShortcut("p")
                .disabled(model == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { model?.pdfView.zoomIn(nil) }
                .keyboardShortcut("=")
            Button("Zoom Out") { model?.pdfView.zoomOut(nil) }
                .keyboardShortcut("-")
            Button("Fit to Window") { model?.pdfView.autoScales = true }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("Page") {
            Group {
                Button("Next Page") { model?.pdfView.goToNextPage(nil) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Page") { model?.pdfView.goToPreviousPage(nil) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Divider()
                Button("Rotate Left") { model?.rotateCurrentPage(by: -90) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Rotate Right") { model?.rotateCurrentPage(by: 90) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Delete Page") { model?.deleteCurrentPage() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            .disabled(model == nil)
        }

        CommandMenu("Tools") {
            ForEach(Array(Mode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .control])
                    .disabled(model == nil)
            }
            Divider()
            Button("Select Tool") { model?.tool = .select }
                .keyboardShortcut("0", modifiers: [.command, .control])
                .disabled(model == nil)
            Divider()
            Button("Recognize Text (OCR)") { model?.recognizeText() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Insert Pages from File…") { model?.insertPages() }
                .disabled(model == nil)
        }
    }
}
