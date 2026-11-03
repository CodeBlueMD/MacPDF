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
                action("Image", "photo") { model.chooseImage() }
                    .background(selectedBackground(model.tool == .image))
                tool(.link, labeled: true)
                tool(.redact, labeled: true)
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

    private var shapeMenu: some View {
        Menu {
            ForEach(ShapeKind.allCases) { kind in
                Button { model.shapeKind = kind; model.tool = .shape } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
        } label: {
            Image(systemName: model.shapeKind.symbol)
        } primaryAction: {
            model.tool = model.tool == .shape ? .select : .shape
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(selectedBackground(model.tool == .shape))
        .help("Shapes — click to draw, hold for more shapes")
    }

    private var stampMenu: some View {
        Menu {
            ForEach(StampKind.allCases) { kind in
                Button(kind.title) { model.stampKind = kind; model.tool = .stamp }
            }
        } label: {
            Label(model.mode == .fillSign ? "Stamp" : "", systemImage: "seal")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            model.tool = model.tool == .stamp ? .select : .stamp
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(selectedBackground(model.tool == .stamp))
        .help("Stamp: \(model.stampKind.title) — hold to pick another")
    }

    private func signatureButton(labeled: Bool) -> some View {
        Menu {
            Button("Place Signature") { model.useSignatureTool() }
            Button("New Signature…") { model.showSignaturePad = true }
        } label: {
            Label(labeled ? "Signature" : "", systemImage: "signature")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            model.useSignatureTool()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(selectedBackground(model.tool == .signature))
        .help("Signature — click the page to place it")
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
