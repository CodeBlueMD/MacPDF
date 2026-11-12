import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A PDF on disk. Edits happen directly on `pdf`; saving writes its current state.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let pdf: PDFDocument
    /// Commits any edit still open in the window before the file is written.
    var willSave: (() -> Void)?

    /// Safety backup tracking: captures original bytes on file load and ensures a non-destructive
    /// backup is written to disk before the first save.
    private var originalData: Data?
    private var hasCreatedBackup = false

    /// File > New creates a single blank US Letter page.
    init() {
        pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        pdf.insert(page, at: 0)
    }

    init(pdf: PDFDocument) {
        self.pdf = pdf
    }

    convenience init(data: Data) throws {
        guard let doc = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.init(pdf: doc)
        self.originalData = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let pdf = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pdf = pdf
        self.originalData = data
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Saves and autosaves can run off the main thread, where touching the editor views or PDF
        // pages directly races with active user interaction.
        // Both the redaction check and serialization are performed atomically on the main thread
        // to prevent race conditions.
        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                try prepareAndSerializeSnapshot()
            }
        } else {
            var capturedData: Data?
            var capturedError: Error?
            let sema = DispatchSemaphore(value: 0)

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    sema.signal()
                    return
                }
                do {
                    capturedData = try MainActor.assumeIsolated {
                        try self.prepareAndSerializeSnapshot()
                    }
                } catch {
                    capturedError = error
                }
                sema.signal()
            }

            // Allow sufficient time for Vision OCR rasterization burns (typically 1.5–3s) while
            // guarding against complete deadlocks.
            let waitResult = sema.wait(timeout: .now() + .seconds(20))
            if waitResult == .timedOut {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot save document: timed out waiting for document to prepare."
                ])
            }
            if let error = capturedError {
                throw error
            }
            guard let data = capturedData else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }

    @MainActor
    private func prepareAndSerializeSnapshot() throws -> Data {
        // 1. Commit open editor views and burn pending redactions synchronously
        willSave?()

        // 2. Fail-closed security check: If any pending redaction annotations remain unburned
        // (e.g. burn was cancelled or failed), refuse to write to disk.
        if hasPendingRedactions {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Cannot save document: pending redactions have not finished burning."
            ])
        }

        // 3. Non-destructive safety backup on first save
        createSafetyBackupIfNeeded()

        // 4. Serialize data on the main thread for consistency
        guard let data = pdf.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Preserves a timestamped copy of the original document in Caches before first save.
    private func createSafetyBackupIfNeeded() {
        guard !hasCreatedBackup, let original = originalData else { return }
        hasCreatedBackup = true
        let fm = FileManager.default
        let backupsDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPDF/Backups", isDirectory: true)
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let filename = "original-backup-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).pdf"
        let backupURL = backupsDir.appendingPathComponent(filename)
        try? original.write(to: backupURL)
    }

    var hasPendingRedactions: Bool {
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), page.annotations.contains(where: { $0.tag == .redaction }) {
                return true
            }
        }
        return false
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
