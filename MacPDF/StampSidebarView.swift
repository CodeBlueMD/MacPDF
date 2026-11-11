import SwiftUI

struct StampSidebarView: View {
    @ObservedObject var model: DocumentModel
    @State private var selectedTab = 0
    @State private var showingAddCustom = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Stamps")
                    .font(.headline.weight(.bold))
                Spacer()
                Button {
                    showingAddCustom = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Create Custom Stamp")

                Button {
                    model.showStampSidebar = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .help("Close Stamps")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Segmented Picker (Standard / Custom)
            Picker("Stamp Type", selection: $selectedTab) {
                Text("Standard").tag(0)
                Text("Custom").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider()

            // Content
            ScrollView {
                if selectedTab == 0 {
                    standardStampsGrid
                        .padding(12)
                } else {
                    customStampsList
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingAddCustom) {
            AddCustomStampSheet(model: model)
        }
    }

    // MARK: - Standard Stamps Grid (Image 5)
    private var standardStampsGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(StampCatalog.standardStamps) { stamp in
                Button {
                    model.selectStamp(stamp)
                } label: {
                    StampPreviewCell(stamp: stamp, isSelected: model.activeStamp.id == stamp.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Custom Stamps List (Image 4)
    private var customStampsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TEXT STAMPS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(model.customStamps) { stamp in
                HStack {
                    Button {
                        model.selectStamp(stamp)
                    } label: {
                        HStack {
                            Text(stamp.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(model.activeStamp.id == stamp.id ? Color.accentColor : Color.gray.opacity(0.2),
                                        lineWidth: model.activeStamp.id == stamp.id ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.deleteCustomStamp(stamp)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete Stamp")
                    .padding(.leading, 4)
                }
            }
        }
    }
}

// MARK: - Stamp Preview Cell
private struct StampPreviewCell: View {
    let stamp: StampItem
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))

            switch stamp.style {
            case .boxed:
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(stamp.swiftBgColor)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(stamp.swiftPrimaryColor, lineWidth: 2)

                    Text(stamp.title)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(stamp.swiftPrimaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                }
                .padding(6)

            case .tagArrow:
                TagArrowShape()
                    .fill(stamp.swiftBgColor)
                    .overlay(
                        TagArrowShape()
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                    )
                    .overlay(
                        Text(stamp.title)
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(stamp.swiftPrimaryColor)
                            .lineLimit(1)
                            .padding(.trailing, 8)
                    )
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)

            case .mark:
                Text(stamp.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(stamp.swiftPrimaryColor)

            case .dateTime:
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(stamp.swiftBgColor)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(stamp.swiftPrimaryColor, lineWidth: 1.8)

                    VStack(spacing: 2) {
                        Text(stamp.title)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(stamp.swiftPrimaryColor)
                        if let sub = stamp.subtitle {
                            Text(sub)
                                .font(.system(size: 6.5, weight: .bold))
                                .foregroundStyle(stamp.swiftPrimaryColor)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(6)

            case .plainText:
                Text(stamp.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(stamp.swiftPrimaryColor)
                    .padding(6)
            }
        }
        .frame(height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
    }
}

// MARK: - Tag Arrow Shape
struct TagArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arrowWidth: CGFloat = 12
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - arrowWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - arrowWidth, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Add Custom Stamp Sheet
private struct AddCustomStampSheet: View {
    @ObservedObject var model: DocumentModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var selectedColorHex = "#2E7D32"
    @State private var selectedStyle: StampStyle = .boxed

    private let colorPresets: [String] = [
        "#2E7D32", // Green
        "#C62828", // Red
        "#1565C0", // Blue
        "#6A1B9A", // Purple
        "#EF6C00", // Orange
        "#212121"  // Black
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Custom Stamp")
                .font(.headline)

            TextField("Stamp text (e.g. APPROVED, REVISED, NAME)", text: $text)
                .textFieldStyle(.roundedBorder)

            // Quick Insert Buttons
            HStack(spacing: 8) {
                Button("Insert Today's Date") {
                    text = Date().formatted(date: .abbreviated, time: .omitted)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Insert My Name") {
                    let name = NSFullUserName()
                    text = name.isEmpty ? "OFFICIAL" : name.uppercased()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Style Picker
            Picker("Style", selection: $selectedStyle) {
                Text("Boxed").tag(StampStyle.boxed)
                Text("Arrow Tag").tag(StampStyle.tagArrow)
                Text("Plain Text").tag(StampStyle.plainText)
            }
            .pickerStyle(.segmented)

            // Color Presets
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(colorPresets, id: \.self) { hex in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .black))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary, lineWidth: selectedColorHex == hex ? 2.5 : 0)
                            )
                            .onTapGesture { selectedColorHex = hex }
                    }
                }
            }

            // Preview
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview").font(.subheadline).foregroundStyle(.secondary)
                StampPreviewCell(
                    stamp: StampItem(
                        title: text.isEmpty ? "STAMP PREVIEW" : text,
                        style: selectedStyle,
                        colorHex: selectedColorHex,
                        bgHex: selectedColorHex,
                        isCustom: true
                    ),
                    isSelected: false
                )
                .frame(width: 140, height: 48)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            Spacer()

            // Actions
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add Stamp") {
                    let stamp = StampItem(
                        title: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        style: selectedStyle,
                        colorHex: selectedColorHex,
                        bgHex: selectedColorHex,
                        isCustom: true
                    )
                    model.addCustomStamp(stamp)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 420)
    }
}
