import SwiftUI

/// The tab row in the window toolbar: Annotate, Edit, Export, …
struct ModePicker: View {
    @ObservedObject var model: DocumentModel
    @Namespace private var selection
    @State private var hovered: Mode?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { mode in
                let isSelected = model.mode == mode
                Button { model.mode = mode } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .labelStyle(.titleAndIcon)
                        .fontWeight(isSelected ? .medium : .regular)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                // One pill shared by all modes, so it slides to the chosen one.
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "pill", in: selection)
                            } else if hovered == mode {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = mode } else if hovered == mode { hovered = nil }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.mode)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Toolbar-row buttons: a soft plate on hover and a firmer one while pressed, so every tool
/// answers the pointer the way the window toolbar's own buttons do.
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }

    private struct Plate: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.14 : hovering ? 0.07 : 0)))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
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
                if let annotation = model.selectedAnnotation {
                    action("Delete \(annotation.displayName)", "trash") { model.deleteSelectedAnnotation() }
                    action("Duplicate", "plus.rectangle.on.rectangle") { model.duplicateSelectedAnnotation() }
                }
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
                action("Patient Info…", "person.text.rectangle") { model.scanForPatientInfo() }
                action("Header & Footer", "rectangle.topthird.inset.filled") { model.showHeaderFooter = true }
            case .export:
                ForEach(ExportKind.allCases) { kind in
                    action(kind.title, kind.symbol) { model.export(kind) }
                }
                gap
                action("Clean Copy…", "checkmark.shield") { model.showCleanCopy = true }
                action("Compare…", "arrow.left.arrow.right") { model.compareWithOlderVersion() }
            case .fillSign:
                Menu {
                    Button("This Page") { model.autofillForm(allPages: false) }
                    Button("All Pages") { model.autofillForm(allPages: true) }
                    Divider()
                    Button("Edit My Profile…") { model.showProfile = true }
                } label: {
                    Label("Auto-Fill", systemImage: "wand.and.stars")
                } primaryAction: {
                    model.autofillForm(allPages: false)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Fill this page's form from your profile (NPI, DEA, license, address…)")
                gap
                tool(.textBox, labeled: true)
                signatureButton(labeled: true)
                tool(.date, labeled: true)
                tool(.checkmark, labeled: true)
                tool(.cross, labeled: true)
                stampMenu
                if let annotation = model.selectedAnnotation {
                    action("Delete \(annotation.displayName)", "trash") { model.deleteSelectedAnnotation() }
                    action("Duplicate", "plus.rectangle.on.rectangle") { model.duplicateSelectedAnnotation() }
                }
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
        // The text and image options slide in beside their tool instead of making the row jump.
        .animation(.easeOut(duration: 0.16), value: model.textStyle != nil)
        .animation(.easeOut(duration: 0.16), value: model.selectedImage != nil)
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
        .buttonStyle(BarButtonStyle())
        .background(selectedBackground(model.tool == tool))
        .help(tool.title)
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { itemLabel(title, symbol, labeled: true) }
            .buttonStyle(BarButtonStyle())
            .help(title)
    }

    private func itemLabel(_ title: String, _ symbol: String, labeled: Bool) -> some View {
        HStack(spacing: 6) {
            if symbol == "rubber.stamp" || symbol == "seal" {
                RubberStampIcon(size: labeled ? 15 : 17, color: .primary)
            } else {
                Image(systemName: symbol).font(.system(size: labeled ? 15 : 17))
            }
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
                .buttonStyle(BarButtonStyle())
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
        Button {
            model.showStampSidebar.toggle()
            if model.showStampSidebar {
                model.tool = .stamp
            } else if model.tool == .stamp {
                model.tool = .select
            }
        } label: {
            itemLabel("Stamp", "rubber.stamp", labeled: model.mode == .fillSign)
        }
        .buttonStyle(BarButtonStyle())
        .frame(height: 30)
        .background(selectedBackground(model.tool == .stamp || model.showStampSidebar))
        .help("Stamps — customize and choose standard stamps")
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
                if !model.pageTextStyles.isEmpty {
                    Section("Match text on this page") {
                        ForEach(model.pageTextStyles.indices, id: \.self) { i in
                            let choice = model.pageTextStyles[i]
                            Button(choice.label) {
                                var matched = choice.style
                                matched.alignment = style.wrappedValue.alignment
                                style.wrappedValue = matched
                            }
                        }
                    }
                    Divider()
                }
                Section("Fonts") {
                    ForEach(Self.families, id: \.self) { family in
                        Button(family) { style.wrappedValue.setFamily(family) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Font")

            Stepper(value: Binding(get: { style.wrappedValue.size },
                                   set: { new in
                                       // With words selected, only they change size.
                                       let delta = new - style.wrappedValue.size
                                       if model.pdfView.resizeSelection(by: delta) { return }
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

            Toggle(isOn: Binding(get: { style.wrappedValue.isBold }, set: { _ in toggle(.boldFontMask) })) {
                Image(systemName: "bold")
            }
            .toggleStyle(.button)
            .help("Bold — selected words, or the whole paragraph")
            Toggle(isOn: Binding(get: { style.wrappedValue.isItalic }, set: { _ in toggle(.italicFontMask) })) {
                Image(systemName: "italic")
            }
            .toggleStyle(.button)
            .help("Italic — selected words, or the whole paragraph")

            Picker("Alignment", selection: Binding(get: { style.wrappedValue.alignment }, set: { style.wrappedValue.alignment = $0 })) {
                Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                Image(systemName: "text.alignright").tag(NSTextAlignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle(isOn: $model.pushTextBelow) {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .toggleStyle(.button)
            .help("Push text below down when this paragraph gets longer (and up when shorter)")

            ColorPicker("Text color", selection: Binding(get: { Color(nsColor: style.wrappedValue.color) },
                                                         set: { color in
                                                             if !model.pdfView.styleSelection(color: NSColor(color)) {
                                                                 style.wrappedValue.color = NSColor(color)
                                                             }
                                                         }),
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

extension TextStylePanel {
    /// Bold/italic for the selected words, or the whole paragraph when nothing is selected.
    fileprivate func toggle(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let handled = model.pdfView.styleSelection(font: { font in
            manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        })
        if !handled { model.textStyle?.toggle(trait) }
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
