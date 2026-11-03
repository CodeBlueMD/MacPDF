import SwiftUI

/// Review list for Edit → Patient Info: everything found, grouped, with checkboxes.
struct PatientInfoSheet: View {
    @ObservedObject var model: DocumentModel
    @State var matches: [PatientInfoMatch]
    @Environment(\.dismiss) private var dismiss

    private var kinds: [PatientInfoMatch.Kind] {
        PatientInfoMatch.Kind.allCases.filter { kind in matches.contains { $0.kind == kind } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Patient information found").font(.headline)
            Text("Uncheck anything that should stay. Checked items are permanently removed from the file.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(kinds) { kind in
                    let indices = matches.indices.filter { matches[$0].kind == kind }
                    Section {
                        ForEach(indices, id: \.self) { i in
                            Toggle(isOn: $matches[i].include) {
                                HStack {
                                    Text(matches[i].text).lineLimit(1)
                                    Spacer()
                                    Text("p. \(matches[i].pageIndex + 1)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .contextMenu {
                                Button("Show on Page") { model.go(toPage: matches[i].pageIndex) }
                            }
                        }
                    } header: {
                        Toggle(isOn: Binding(
                            get: { indices.allSatisfy { matches[$0].include } },
                            set: { on in indices.forEach { matches[$0].include = on } }
                        )) {
                            Text("\(kind.rawValue) (\(indices.count))").font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Text("\(matches.filter(\.include).count) of \(matches.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.patientInfoMatches = nil
                    dismiss()
                }
                Button("Redact Selected") {
                    dismiss()
                    model.redactPatientInfo(matches)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!matches.contains(where: \.include))
            }
        }
        .padding()
        .frame(width: 520, height: 520)
    }
}
