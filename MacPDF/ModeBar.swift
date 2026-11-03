import SwiftUI

/// The tab row in the window toolbar: Annotate, Edit, Export, …
struct ModePicker: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { mode in
                Button { model.mode = mode } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(model.mode == mode ? Color.primary.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The row of tools under the toolbar for the selected mode.
struct ModeBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            switch model.mode {
            case .annotate:
                tool(.highlight)
                tool(.underline)
                tool(.strikeOut)
                gap
                tool(.pen)
                tool(.eraser)
                tool(.textBox)
                shapeMenu
                gap
                tool(.note)
                stampMenu
                signatureButton(labeled: false)
                gap
                tool(.snapshot)
            case .edit:
                tool(.editText, labeled: true)
                if model.textStyle != nil {
                    TextStylePanel(model: model)
                }
                tool(.image, labeled: true)
                if model.tool == .image || model.selectedImage != nil {
                    if model.tool == .image { action("Add Image…", "plus") { model.chooseImage() } }
                    if model.selectedImage != nil {
                        action("Rotate Left", "rotate.left") { model.rotateSelectedImage(by: 90) }
                        action("Rotate Right", "rotate.right") { model.rotateSelectedImage(by: -90) }
                        action("Replace…", "photo.badge.arrow.down") { model.replaceSelectedImage() }
                        action("Export…", "square.and.arrow.up") { model.exportSelectedImage() }
                        action("Delete", "trash") { model.deleteSelectedImage() }
                    }
                }
                tool(.link, labeled: true)
                tool(.redact, labeled: true)
                if model.tool == .redact {
                    action("Find & Redact…", "magnifyingglass") { model.findAndRedact() }
                }
                action("Header & Footer", "rectangle.topthird.inset.filled") { model.showHeaderFooter = true }
            case .export:
                ForEach(ExportKind.allCases) { kind in
                    action(kind.title, kind.symbol) { model.export(kind) }
                }
            case .fillSign:
                tool(.textBox, labeled: true)
                signatureButton(labeled: true)
                tool(.date, labeled: true)
                tool(.checkmark, labeled: true)
                tool(.cross, labeled: true)
                stampMenu
                action("Image", "photo") { model.chooseImage() }
                    .background(selectedBackground(model.tool == .image))
            case .scan:
                action("Enhance Scan", "wand.and.stars") { model.enhanceScans() }
                action("Split Pages", "rectangle.split.2x1") { model.splitPages() }
                tool(.crop, labeled: true)
                action("Clear Margins", "rectangle.dashed") { model.showClearMargins = true }
                action("Recognize Text", "text.viewfinder") { model.recognizeText() }
            case .measure:
                tool(.distance, labeled: true)
                tool(.area, labeled: true)
            }

            if model.tool.hasColor {
                gap
                ColorPicker("Color", selection: $model.color, supportsOpacity: false)
                    .labelsHidden()
                    .help("\(model.tool.title) color")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .disabled(model.progress != nil)
    }

    private var gap: some View { Spacer().frame(width: 14) }

    private func selectedBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
    }

    private func tool(_ tool: Tool, labeled: Bool = false) -> some View {
        Button {
            model.tool = model.tool == tool ? .select : tool
        } label: {
            itemLabel(tool.title, tool.symbol, labeled: labeled)
        }
        .buttonStyle(.plain)
        .background(selectedBackground(model.tool == tool))
        .help(tool.title)
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { itemLabel(title, symbol, labeled: true) }
            .buttonStyle(.plain)
            .help(title)
    }

    private func itemLabel(_ title: String, _ symbol: String, labeled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: labeled ? 15 : 17))
            if labeled { Text(title) }
        }
        .padding(.horizontal, labeled ? 10 : 8)
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    /// A tool button with a small arrow beside it for its options. A borderless SwiftUI Menu would
    /// draw its label dimmed, making it look disabled next to the plain buttons.
    private func splitButton<Options: View>(_ title: String, _ symbol: String, labeled: Bool, selected: Bool,
                                            help: String, action: @escaping () -> Void,
                                            @ViewBuilder options: () -> Options) -> some View {
        HStack(spacing: 0) {
            Button(action: action) { itemLabel(title, symbol, labeled: labeled) }
                .buttonStyle(.plain)
            Menu(content: options) { EmptyView() }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(selectedBackground(selected))
        .help(help)
    }

    private var shapeMenu: some View {
        splitButton("Shapes", model.shapeKind.symbol, labeled: false, selected: model.tool == .shape,
                    help: "Shapes — \(model.shapeKind.title)") {
            model.tool = model.tool == .shape ? .select : .shape
        } options: {
            ForEach(ShapeKind.allCases) { kind in
                Button { model.shapeKind = kind; model.tool = .shape } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
        }
    }

    private var stampMenu: some View {
        splitButton("Stamp", "seal", labeled: model.mode == .fillSign, selected: model.tool == .stamp,
                    help: "Stamp: \(model.stampKind.title)") {
            model.tool = model.tool == .stamp ? .select : .stamp
        } options: {
            ForEach(StampKind.allCases) { kind in
                Button(kind.title) { model.stampKind = kind; model.tool = .stamp }
            }
        }
    }

    private func signatureButton(labeled: Bool) -> some View {
        splitButton("Signature", "signature", labeled: labeled, selected: model.tool == .signature,
                    help: "Signature — click the page to place it") {
            model.useSignatureTool()
        } options: {
            Button("Place Signature") { model.useSignatureTool() }
            Button("New Signature…") { model.showSignaturePad = true }
        }
    }
}

/// Font, size, bold/italic, alignment and color for the paragraph being edited.
struct TextStylePanel: View {
    @ObservedObject var model: DocumentModel

    private static let families = ["Helvetica", "Helvetica Neue", "Arial", "Arial Narrow", "Avenir", "Calibri",
                                   "Cambria", "Courier New", "Garamond", "Georgia", "Gill Sans", "Menlo",
                                   "Palatino", "Times New Roman", "Verdana"]
        .filter { NSFontManager.shared.availableFontFamilies.contains($0) }

    private var style: Binding<TextStyle> {
        Binding(get: { model.textStyle ?? TextStyle(font: .systemFont(ofSize: 12), color: .black, alignment: .left, lineHeight: 14) },
                set: { model.textStyle = $0 })
    }

    var body: some View {
        HStack(spacing: 6) {
            Divider().frame(height: 20)
            Menu(style.wrappedValue.font.familyName ?? "Font") {
                ForEach(Self.families, id: \.self) { family in
                    Button(family) { style.wrappedValue.setFamily(family) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Font")

            Stepper(value: Binding(get: { style.wrappedValue.size },
                                   set: { new in
                                       // Keep the line spacing in proportion to the size.
                                       let ratio = style.wrappedValue.lineHeight / max(style.wrappedValue.size, 1)
                                       style.wrappedValue.size = new
                                       style.wrappedValue.lineHeight = new * ratio
                                   }),
                    in: 4...200, step: 1) {
                Text("\(Int(style.wrappedValue.size.rounded())) pt").monospacedDigit()
            }
            .fixedSize()
            .help("Size")

            Toggle(isOn: Binding(get: { style.wrappedValue.isBold }, set: { _ in style.wrappedValue.toggle(.boldFontMask) })) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)
            .help("Bold")
            Toggle(isOn: Binding(get: { style.wrappedValue.isItalic }, set: { _ in style.wrappedValue.toggle(.italicFontMask) })) {
                Image(systemName: "italic")
            }
            .toggleStyle(.button)
            .help("Italic")

            Picker("Alignment", selection: Binding(get: { style.wrappedValue.alignment }, set: { style.wrappedValue.alignment = $0 })) {
                Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                Image(systemName: "text.alignright").tag(NSTextAlignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ColorPicker("Text color", selection: Binding(get: { Color(nsColor: style.wrappedValue.color) },
                                                         set: { style.wrappedValue.color = NSColor($0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .help("Text color")
        }
    }
}

/// Edit → Header & Footer.
struct HeaderFooterSheet: View {
    @ObservedObject var model: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DocumentModel.HeaderFooter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Header & Footer").font(.headline)
            TextField("Header (optional)", text: $settings.header)
            TextField("Footer", text: $settings.footer)
            Text("Use {page} and {pages} for page numbers, e.g. “Page {page} of {pages}”.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Position", selection: $settings.alignment) {
                Text("Left").tag(NSTextAlignment.left)
                Text("Center").tag(NSTextAlignment.center)
                Text("Right").tag(NSTextAlignment.right)
            }
            .pickerStyle(.segmented)
            Stepper("Size: \(Int(settings.size)) pt", value: $settings.size, in: 6...24)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add to All Pages") {
                    dismiss()
                    model.addHeaderFooter(settings)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.header.isEmpty && settings.footer.isEmpty)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// Settings for Scan & OCR → Clear Margins.
struct ClearMarginsSheet: View {
    @ObservedObject var model: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @State private var margin: Double = 18
    @State private var allPages = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear Margins").font(.headline)
            Text("Whites out a border around each page to remove dark scan edges.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Slider(value: $margin, in: 4...72)
                Text(String(format: "%.2f in", margin / 72)).monospacedDigit().frame(width: 60)
            }
            Picker("Pages", selection: $allPages) {
                Text("All pages").tag(true)
                Text("Current page").tag(false)
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Clear") {
                    dismiss()
                    model.clearMargins(margin, allPages: allPages)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
