import AppKit
import SwiftUI

enum StampStyle: String, Codable, CaseIterable {
    case boxed
    case tagArrow
    case mark
    case dateTime
    case plainText
}

struct StampItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var style: StampStyle
    var colorHex: String
    var bgHex: String
    var isCustom: Bool

    init(id: String = UUID().uuidString,
         title: String,
         subtitle: String? = nil,
         style: StampStyle = .boxed,
         colorHex: String,
         bgHex: String? = nil,
         isCustom: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.colorHex = colorHex
        self.bgHex = bgHex ?? colorHex
        self.isCustom = isCustom
    }

    var primaryColor: NSColor {
        NSColor(hex: colorHex) ?? .labelColor
    }

    var backgroundColor: NSColor {
        switch style {
        case .boxed, .dateTime:
            return NSColor(hex: bgHex) ?? primaryColor.withAlphaComponent(0.12)
        case .tagArrow:
            return NSColor(hex: bgHex) ?? primaryColor
        case .mark, .plainText:
            return .clear
        }
    }

    var swiftPrimaryColor: Color {
        Color(nsColor: primaryColor)
    }

    var swiftBgColor: Color {
        Color(nsColor: backgroundColor)
    }
}

// MARK: - Color Hex Conversion
extension NSColor {
    convenience init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanHex.hasPrefix("#") { cleanHex.removeFirst() }
        guard cleanHex.count == 6, let rgb = UInt64(cleanHex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Standard Stamp Catalog
enum StampCatalog {
    static let standardStamps: [StampItem] = [
        // Boxed Text Stamps (matching PDF Expert aesthetic)
        StampItem(id: "approved", title: "APPROVED", style: .boxed, colorHex: "#1B6A32", bgHex: "#EAF5ED"),
        StampItem(id: "not_approved", title: "NOT APPROVED", style: .boxed, colorHex: "#A91E1E", bgHex: "#FAECEC"),
        StampItem(id: "draft", title: "DRAFT", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),
        StampItem(id: "final", title: "FINAL", style: .boxed, colorHex: "#1B6A32", bgHex: "#EAF5ED"),
        StampItem(id: "void", title: "VOID", style: .boxed, colorHex: "#A91E1E", bgHex: "#FAECEC"),
        StampItem(id: "for_comment", title: "FOR COMMENT", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),
        StampItem(id: "completed", title: "COMPLETED", style: .boxed, colorHex: "#1B6A32", bgHex: "#EAF5ED"),
        StampItem(id: "confidential", title: "CONFIDENTIAL", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),
        StampItem(id: "for_public_release", title: "FOR PUBLIC RELEASE", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),
        StampItem(id: "not_for_public_release", title: "NOT FOR PUBLIC RELEASE", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),
        StampItem(id: "preliminary_results", title: "PRELIMINARY RESULTS", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),
        StampItem(id: "information_only", title: "INFORMATION ONLY", style: .boxed, colorHex: "#143870", bgHex: "#EAF1FB"),

        // Mark / Symbol Stamps
        StampItem(id: "check_green", title: "✓", style: .mark, colorHex: "#1B6A32"),
        StampItem(id: "cross_red", title: "✗", style: .mark, colorHex: "#A91E1E"),
        StampItem(id: "check_black", title: "✓", style: .mark, colorHex: "#111111"),
        StampItem(id: "cross_black", title: "✗", style: .mark, colorHex: "#111111"),

        // Tag Arrow Stamps
        StampItem(id: "witness", title: "WITNESS", style: .tagArrow, colorHex: "#111111", bgHex: "#FFF176"),
        StampItem(id: "initial_here", title: "INITIAL HERE", style: .tagArrow, colorHex: "#111111", bgHex: "#CE93D8"),
        StampItem(id: "sign_here", title: "SIGN HERE", style: .tagArrow, colorHex: "#111111", bgHex: "#EF5350"),

        // Dynamic DateTime Stamp
        StampItem(id: "revised", title: "REVISED", subtitle: dynamicDateString(), style: .dateTime, colorHex: "#143870", bgHex: "#EAF1FB")
    ]

    static func dynamicDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a, MMM d, yyyy"
        return formatter.string(from: Date())
    }

    private static let customStampsKey = "MacPDF.CustomStamps"

    static func loadCustomStamps() -> [StampItem] {
        if let data = UserDefaults.standard.data(forKey: customStampsKey),
           let list = try? JSONDecoder().decode([StampItem].self, from: data),
           !list.isEmpty {
            return list
        }
        // Defaults if none created yet
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        let name = NSFullUserName().isEmpty ? "MY SIGNATURE STAMP" : NSFullUserName().uppercased()
        let defaults = [
            StampItem(id: "custom_date", title: today, style: .plainText, colorHex: "#000000", isCustom: true),
            StampItem(id: "custom_name", title: name, style: .plainText, colorHex: "#000000", isCustom: true)
        ]
        saveCustomStamps(defaults)
        return defaults
    }

    static func saveCustomStamps(_ stamps: [StampItem]) {
        if let data = try? JSONEncoder().encode(stamps) {
            UserDefaults.standard.set(data, forKey: customStampsKey)
        }
    }
}
