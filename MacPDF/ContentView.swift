import PDFKit
import SwiftUI

struct ContentView: View {
    let file: PDFFile
    @StateObject private var model: DocumentModel
    @Environment(\.undoManager) private var undoManager
    @State private var needsPassword: Bool

    init(file: PDFFile, fileURL: URL?) {
        self.file = file
        let model = DocumentModel(pdf: file.pdf)
        if let name = fileURL?.deletingPathExtension().lastPathComponent { model.fileName = name }
        _model = StateObject(wrappedValue: model)
        _needsPassword = State(initialValue: file.pdf.isLocked)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } detail: {
            VStack(spacing: 0) {
                ModeBar(model: model)
                Divider()
                PDFKitView(pdfView: model.pdfView)
                    .overlay(alignment: .bottom) { statusOverlay }
            }
        }
        .alert(model.message ?? "", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {}
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .onSubmit(of: .search) { model.showResult(model.resultIndex + 1) }
        .focusedSceneObject(model)
        .background(WindowTabbing())
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .onChange(of: model.tool) { _, tool in
            model.pdfView.endInlineEdit()
            model.pdfView.window?.invalidateCursorRects(for: model.pdfView)
            if tool != .image { model.pendingImage = nil }
        }
        .sheet(item: $model.noteEdit) { edit in
            NoteEditor(edit: edit, model: model)
        }
        .sheet(isPresented: $model.showSignaturePad) {
            SignaturePad { model.tool = .signature }
        }
        .sheet(isPresented: $model.showClearMargins) {
            ClearMarginsSheet(model: model)
        }
        .sheet(isPresented: $needsPassword) {
            PasswordSheet(pdf: file.pdf) {
                needsPassword = false
                model.pdfView.document = nil
                model.pdfView.document = file.pdf
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let progress = model.progress {
            ProgressView(value: progress.fraction) {
                Text("\(progress.title)… \(Int(progress.fraction * 100))%")
            }
            .frame(width: 260)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 20)
        } else if let toast = model.toast {
            Text(toast)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
                .transition(.opacity)
        } else if let hint = toolHint {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
        }
    }

    private var toolHint: String? {
        switch model.tool {
        case .redact: "Select text or drag a box to redact it. The content underneath is permanently removed."
        case .editText: "Click a line of text to change it."
        case .image: "Click or drag on the page to place the image."
        case .link: "Drag a box over the area to link."
        case .crop: "Drag a box around the part to keep."
        case .snapshot: "Drag a box to copy that area as an image."
        case .distance: "Drag to measure a distance."
        case .area: "Drag a box to measure its area."
        case .signature: "Click where your signature goes."
        default: nil
        }
    }

    private var zoomLabel: String {
        "\(Int((model.scale * 100).rounded()))%"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu(zoomLabel) {
                Button("Fit to Window") { model.setZoom(nil) }
                Divider()
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { factor in
                    Button("\(Int(factor * 100))%") { model.setZoom(factor) }
                }
            }
            .fixedSize()
            .help("Zoom")

            ControlGroup {
                Button { model.pdfView.zoomOut(nil) } label: { Image(systemName: "minus") }
                    .help("Zoom out")
                Button { model.pdfView.zoomIn(nil) } label: { Image(systemName: "plus") }
                    .help("Zoom in")
            }
        }

        ToolbarItem(placement: .principal) {
            ModePicker(model: model)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Text("\(model.currentPageIndex + 1) / \(model.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Menu {
                Section("Layout") {
                    Button("Single Page") { setDisplay(.singlePage) }
                    Button("Continuous Scroll") { setDisplay(.singlePageContinuous) }
                    Button("Two Pages") { setDisplay(.twoUp) }
                    Button("Two Pages, Continuous") { setDisplay(.twoUpContinuous) }
                }
                Section("Pages") {
                    Button("Insert Pages from File…") { model.insertPages() }
                    Button("Insert Blank Page") { model.insertBlankPage() }
                    Button("Rotate Left") { model.rotateCurrentPage(by: -90) }
                    Button("Rotate Right") { model.rotateCurrentPage(by: 90) }
                    Button("Delete Page", role: .destructive) { model.deleteCurrentPage() }
                        .disabled(model.pageCount < 2)
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Layout and pages")
        }
    }

    private func setDisplay(_ mode: PDFDisplayMode) {
        model.pdfView.displayMode = mode
        model.pdfView.autoScales = true
    }
}


struct PDFKitView: NSViewRepresentable {
    let pdfView: MacPDFView
    func makeNSView(context: Context) -> MacPDFView { pdfView }
    func updateNSView(_ nsView: MacPDFView, context: Context) {}
}

/// Opens new documents as tabs in the existing window, like Safari.
private struct WindowTabbing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.tabbingMode = .preferred }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct NoteEditor: View {
    let edit: NoteEdit
    @ObservedObject var model: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 340, height: 160)
                .border(.separator)
            HStack {
                Button("Delete", role: .destructive) {
                    model.remove(edit.annotation)
                    dismiss()
                }
                Spacer()
                Button("Done") {
                    model.setContents(text, of: edit.annotation)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear { text = edit.annotation.contents ?? "" }
    }
}

private struct SignaturePad: View {
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    private let size = CGSize(width: 420, height: 160)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draw your signature").font(.headline)
            Canvas { context, _ in
                for stroke in strokes where stroke.count > 1 {
                    var path = Path()
                    path.addLines(stroke)
                    context.stroke(path, with: .color(.primary),
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width, height: size.height)
            .background(.background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 36)
            }
            .border(.separator)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let point = value.location
                if value.translation == .zero || strokes.isEmpty || value.startLocation == point {
                    strokes.append([point])
                } else {
                    strokes[strokes.count - 1].append(point)
                }
            })
            HStack {
                Button("Clear") { strokes = [] }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save & Place") {
                    Signature.saved = Signature(strokes: strokes, size: size)
                    dismiss()
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
            }
            Text("Then click where it goes on the page.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct PasswordSheet: View {
    let pdf: PDFDocument
    let onUnlock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This PDF is password protected").font(.headline)
            SecureField("Password", text: $password)
                .frame(width: 280)
                .onSubmit(unlock)
            if failed {
                Text("Incorrect password").foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func unlock() {
        if pdf.unlock(withPassword: password) {
            onUnlock()
        } else {
            failed = true
        }
    }
}
