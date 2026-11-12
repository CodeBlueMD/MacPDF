import AppKit
import PDFKit
import XCTest
@testable import MacPDF

final class RedactionProofTests: XCTestCase {
    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    @MainActor
    func testRedactSelectionPermanentlyRemovesTextFromExtractionAndRawStream() async throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let model = DocumentModel(pdf: doc)

        let targetText = "000-12-3456"

        // Negative controls: verify the sensitive string exists before redaction
        let initialMatches = doc.findString(targetText, withOptions: [])
        XCTAssertFalse(initialMatches.isEmpty, "Precondition: Sensitive text must exist initially")

        let initialPageString = try XCTUnwrap(doc.page(at: 0)?.string)
        XCTAssertTrue(initialPageString.contains(targetText), "Precondition: Sensitive text in page string")

        let initialData = try XCTUnwrap(doc.dataRepresentation())
        let targetUTF8 = Data(targetText.utf8)
        XCTAssertNotNil(initialData.range(of: targetUTF8),
                        "Negative control: Target text must exist in raw PDF bytes prior to redaction")

        let initialStreams = ContentSurgery.allDecodedContentStreams(from: initialData)
        XCTAssertTrue(initialStreams.contains(where: { $0.contains(targetText) }),
                      "Negative control: Target text must exist in decoded content stream prior to redaction")

        // Perform redaction
        model.redact(initialMatches[0])

        // Burn all redactions
        await model.burnAllPendingRedactions()

        // Capture serialized PDF data
        let savedData = try XCTUnwrap(doc.dataRepresentation())

        // 1. Reopen document from serialized data
        let reopenedDoc = try XCTUnwrap(PDFDocument(data: savedData))
        let reopenedPage = try XCTUnwrap(reopenedDoc.page(at: 0))

        // 2. Assert text is gone from extraction
        let extractedString = reopenedPage.string ?? ""
        XCTAssertFalse(extractedString.contains(targetText),
                       "CRITICAL: Redacted text '\(targetText)' must NOT be present in extracted string")
        XCTAssertTrue(reopenedDoc.findString(targetText, withOptions: []).isEmpty,
                      "CRITICAL: findString must return no matches for redacted text")

        // 3. Assert text is completely gone from raw PDF bytes
        XCTAssertNil(savedData.range(of: targetUTF8),
                     "CRITICAL: Redacted text ASCII/UTF8 bytes found in raw PDF data")

        let targetUTF16 = Data(targetText.utf16.flatMap { [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF)] })
        XCTAssertNil(savedData.range(of: targetUTF16),
                     "CRITICAL: Redacted text UTF16 bytes found in raw PDF data")

        // 4. Assert text is gone from all decoded content streams (inflated streams)
        let streams = ContentSurgery.allDecodedContentStreams(from: savedData)
        for (idx, stream) in streams.enumerated() {
            XCTAssertFalse(stream.contains(targetText),
                           "CRITICAL: Redacted text found inside decoded content stream #\(idx)")
        }

        // 5. Assert unredacted content is still present and selectable
        XCTAssertTrue(extractedString.contains("CONFIDENTIAL MEDICAL REPORT") ||
                      extractedString.contains("CONFIDENTIAL") ||
                      extractedString.contains("MEDICAL"),
                      "Non-redacted content should survive rasterization/OCR")
    }

    @MainActor
    func testRedactBoxPermanentlyRemovesSecretCode() async throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let model = DocumentModel(pdf: doc)

        let secretCode = "ALPHA-OMEGA-99"

        // Negative controls: verify the secret code exists before redaction
        let matches = doc.findString(secretCode, withOptions: [])
        XCTAssertFalse(matches.isEmpty, "Precondition: Secret code must exist initially")

        let page = try XCTUnwrap(doc.page(at: 0))
        let initialPageText = page.string ?? ""
        XCTAssertTrue(initialPageText.contains(secretCode), "Precondition: Secret code must be in initial page text")

        let initialData = try XCTUnwrap(doc.dataRepresentation())
        XCTAssertNotNil(initialData.range(of: Data(secretCode.utf8)),
                        "Negative control: Secret code must exist in raw PDF bytes prior to redaction")

        let initialStreams = ContentSurgery.allDecodedContentStreams(from: initialData)
        XCTAssertTrue(initialStreams.contains(where: { $0.contains(secretCode) }),
                      "Negative control: Secret code must exist in decoded stream prior to redaction")

        let selectionBounds = matches[0].bounds(for: page)
        let redactBox = selectionBounds.insetBy(dx: -4, dy: -3)

        // Add rectangular redaction
        model.addRedaction(redactBox, on: page)
        await model.burnAllPendingRedactions()

        let savedData = try XCTUnwrap(doc.dataRepresentation())
        let reopenedDoc = try XCTUnwrap(PDFDocument(data: savedData))

        // Verify extraction has no trace
        let text = reopenedDoc.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.contains(secretCode), "Secret code must be purged from extraction")
        XCTAssertTrue(reopenedDoc.findString(secretCode, withOptions: []).isEmpty)

        // Verify raw bytes and content streams
        XCTAssertNil(savedData.range(of: Data(secretCode.utf8)), "Secret code found in raw PDF bytes")

        let streams = ContentSurgery.allDecodedContentStreams(from: savedData)
        for stream in streams {
            XCTAssertFalse(stream.contains(secretCode), "Secret code found in decoded stream")
        }
    }

    @MainActor
    func testImmediateSaveBurnsPendingRedactionsThroughWillSaveHook() throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let data = try Data(contentsOf: url)
        let file = try PDFFile(data: data)

        let model = DocumentModel(pdf: file.pdf)

        // Connect the real willSave hook exactly as ContentView does
        file.willSave = { [weak model] in
            model?.pdfView.endInlineEdit()
            model?.burnAllPendingRedactionsSync()
        }

        let patientID = "PT-98234-X"

        // Negative controls: verify target text exists in search, text, raw bytes, and streams
        let matches = file.pdf.findString(patientID, withOptions: [])
        XCTAssertFalse(matches.isEmpty, "Precondition: Target text must exist in document")

        let initialText = try XCTUnwrap(file.pdf.page(at: 0)?.string)
        XCTAssertTrue(initialText.contains(patientID), "Precondition: Target text in initial string")

        let initialData = try XCTUnwrap(file.pdf.dataRepresentation())
        XCTAssertNotNil(initialData.range(of: Data(patientID.utf8)),
                        "Negative control: Target text must exist in raw PDF bytes prior to redaction")

        let initialStreams = ContentSurgery.allDecodedContentStreams(from: initialData)
        XCTAssertTrue(initialStreams.contains(where: { $0.contains(patientID) }),
                      "Negative control: Target text must exist in decoded stream prior to redaction")

        // Apply redaction mark (which schedules async burn with 350ms delay)
        model.redact(matches[0])

        // Immediately take snapshot via file.snapshot WITHOUT manually calling burnAllPendingRedactions.
        // The snapshot triggers the real willSave hook, which must synchronously burn all pending redactions.
        let snapshotData = try file.snapshot(contentType: .pdf)

        // Verify that snapshot data has the redaction completely burned in
        let reopened = try XCTUnwrap(PDFDocument(data: snapshotData))
        let reopenedText = reopened.page(at: 0)?.string ?? ""
        XCTAssertFalse(reopenedText.contains(patientID),
                       "Immediate snapshot via willSave must burn pending redactions")
        XCTAssertTrue(reopened.findString(patientID, withOptions: []).isEmpty,
                      "findString must return no matches for redacted text")
        XCTAssertNil(snapshotData.range(of: Data(patientID.utf8)),
                     "Target text must not exist in raw bytes of snapshot")

        let streams = ContentSurgery.allDecodedContentStreams(from: snapshotData)
        for (idx, stream) in streams.enumerated() {
            XCTAssertFalse(stream.contains(patientID),
                           "Redacted text found in decoded stream #\(idx)")
        }

        XCTAssertTrue(reopenedText.contains("CONFIDENTIAL") || reopenedText.contains("MEDICAL"),
                      "Non-redacted content should survive rasterization/OCR")
    }

    @MainActor
    func testRotatedPageRedactionBurnsAccurately() async throws {
        let url = fixturesURL.appendingPathComponent("rotated-page.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let model = DocumentModel(pdf: doc)

        let secret = "ROT-998811"

        // Negative controls: verify rotated secret exists before redaction
        let matches = doc.findString(secret, withOptions: [])
        XCTAssertFalse(matches.isEmpty, "Precondition: Rotated secret must exist initially")

        let initialText = try XCTUnwrap(doc.page(at: 0)?.string)
        XCTAssertTrue(initialText.contains(secret), "Precondition: Rotated secret in page text")

        let initialData = try XCTUnwrap(doc.dataRepresentation())
        XCTAssertNotNil(initialData.range(of: Data(secret.utf8)),
                        "Negative control: Rotated secret must exist in raw PDF bytes prior to redaction")

        let initialStreams = ContentSurgery.allDecodedContentStreams(from: initialData)
        XCTAssertTrue(initialStreams.contains(where: { $0.contains(secret) }),
                      "Negative control: Rotated secret must exist in decoded stream prior to redaction")

        model.redact(matches[0])
        await model.burnAllPendingRedactions()

        let savedData = try XCTUnwrap(doc.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: savedData))

        XCTAssertEqual(reopened.page(at: 0)?.rotation, 90, "Rotation should be preserved")
        let text = reopened.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.contains(secret), "Redacted text on rotated page must be purged")
        XCTAssertNil(savedData.range(of: Data(secret.utf8)), "Secret text found in raw bytes of rotated page")

        let streams = ContentSurgery.allDecodedContentStreams(from: savedData)
        for (idx, stream) in streams.enumerated() {
            XCTAssertFalse(stream.contains(secret), "Rotated secret found in decoded stream #\(idx)")
        }
    }

    @MainActor
    func testDirectRasterizedDestroysRedactedText() async throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))

        let target = "ALPHA-OMEGA-99"

        // Negative controls
        let matches = doc.findString(target, withOptions: [])
        XCTAssertFalse(matches.isEmpty, "Precondition: Target must exist initially")

        let initialData = try XCTUnwrap(doc.dataRepresentation())
        XCTAssertNotNil(initialData.range(of: Data(target.utf8)),
                        "Negative control: Target must exist in raw PDF bytes prior to rasterization")

        let rect = matches[0].bounds(for: page)

        // Call OCR.rasterized directly
        let fills: [OCR.Fill] = [(rect: rect.insetBy(dx: -5, dy: -5), color: .black)]
        let pageResult = await OCR.rasterized(page, fills: fills, keep: { _ in true })
        let flattened = try XCTUnwrap(pageResult)

        let single = PDFDocument()
        single.insert(flattened, at: 0)
        let data = try XCTUnwrap(single.dataRepresentation())

        XCTAssertNil(data.range(of: Data(target.utf8)), "Target must not be present in raw PDF data")
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertFalse((reopened.page(at: 0)?.string ?? "").contains(target))
    }

    func testBackgroundSnapshotDoesNotDeadlock() throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let data = try Data(contentsOf: url)
        let file = try PDFFile(data: data)

        var willSaveCalled = false
        file.willSave = {
            willSaveCalled = true
        }

        let exp = expectation(description: "Background snapshot")
        var bgData: Data?
        DispatchQueue.global(qos: .userInitiated).async {
            bgData = try? file.snapshot(contentType: .pdf)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertNotNil(bgData)
        XCTAssertTrue(willSaveCalled, "willSave must be executed without deadlocking")
    }

    @MainActor
    func testBackgroundSaveFailsClosedWhenRedactionsPending() throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let data = try Data(contentsOf: url)
        let file = try PDFFile(data: data)
        let model = DocumentModel(pdf: file.pdf)

        let patientID = "PT-98234-X"
        let matches = file.pdf.findString(patientID, withOptions: [])
        XCTAssertFalse(matches.isEmpty)

        // Mark a redaction (creates an unburned redaction annotation on page)
        model.redact(matches[0])
        XCTAssertTrue(file.hasPendingRedactions, "Precondition: Redaction annotation must be present")

        // Simulate a save where willSave does NOT burn redactions (e.g. main thread busy or burn timed out)
        file.willSave = {
            // Intentionally omit burning to simulate failure/timeout
        }

        // 1. Assert that snapshot from a background queue throws CocoaError(.fileWriteUnknown) rather than writing unredacted text
        let exp = expectation(description: "Background save fails closed")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try file.snapshot(contentType: .pdf)
                XCTFail("Snapshot should have thrown CocoaError(.fileWriteUnknown) due to pending redactions")
            } catch let error as CocoaError {
                XCTAssertEqual(error.code, .fileWriteUnknown)
                XCTAssertTrue(error.localizedDescription.contains("pending redactions"))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        // 2. Assert that direct snapshot also throws rather than saving unburned redactions
        do {
            _ = try file.snapshot(contentType: .pdf)
            XCTFail("Direct snapshot should have thrown CocoaError(.fileWriteUnknown)")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteUnknown)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSubsetFontsExtractionOnlyRedaction() async throws {
        let url = fixturesURL.appendingPathComponent("subset-fonts.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let model = DocumentModel(pdf: doc)

        let target = "SUBSET-7701"

        // Negative control: verify target exists in extraction and search
        let matches = doc.findString(target, withOptions: [])
        XCTAssertFalse(matches.isEmpty, "Precondition: Diagnostic code must exist initially")
        let initialPageString = try XCTUnwrap(doc.page(at: 0)?.string)
        XCTAssertTrue(initialPageString.contains(target), "Precondition: Target must exist in page string")

        // Redact target selection
        model.redact(matches[0])
        await model.burnAllPendingRedactions()

        // Capture serialized PDF
        let savedData = try XCTUnwrap(doc.dataRepresentation())
        let reopenedDoc = try XCTUnwrap(PDFDocument(data: savedData))
        let reopenedPage = try XCTUnwrap(reopenedDoc.page(at: 0))

        // Assert target is purged from extraction
        let extracted = reopenedPage.string ?? ""
        XCTAssertFalse(extracted.contains(target), "Redacted text '\(target)' must not be present in extracted text")
        XCTAssertTrue(reopenedDoc.findString(target, withOptions: []).isEmpty, "findString must return no matches for '\(target)'")

        // Assert unredacted text remains intact
        XCTAssertTrue(extracted.contains("SUBSET FONT SPECIMEN") || extracted.contains("SPECIMEN"),
                      "Unredacted text should survive rasterization/OCR")
        XCTAssertTrue(extracted.contains("REC-88329-Z") || extracted.contains("88329"),
                      "Other text lines should survive rasterization/OCR")
    }

    @MainActor
    func testFirstSaveCreatesSafetyBackupInCaches() throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let data = try Data(contentsOf: url)
        let file = try PDFFile(data: data)

        // Snapshotting should generate a non-destructive backup in ~/Library/Caches/MacPDF/Backups/
        _ = try file.snapshot(contentType: .pdf)

        let fm = FileManager.default
        let backupsDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPDF/Backups", isDirectory: true)
        XCTAssertTrue(fm.fileExists(atPath: backupsDir.path), "Backup directory must exist")

        let backups = try fm.contentsOfDirectory(atPath: backupsDir.path)
            .filter { $0.hasPrefix("original-backup-") && $0.hasSuffix(".pdf") }
        XCTAssertFalse(backups.isEmpty, "A safety backup file must have been created before first save")
    }

    func testGlyphValidationRejectsUnsupportedCharacters() {
        let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)

        // Standard ASCII characters must have valid glyphs
        XCTAssertTrue(font.hasGlyphs(for: "Hello World 12345!"), "Standard ASCII must have valid glyphs")

        // Private use or non-font characters should fail validation
        let unsupportedString = "\u{E000}\u{E001}" // Private Use Area characters
        XCTAssertFalse(font.hasGlyphs(for: unsupportedString), "Missing glyphs must return false")
    }

    @MainActor
    func testRoundTripTextEditingReplacesTextSafely() throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        let model = DocumentModel(pdf: doc)

        // Find existing text block
        let originalText = "CONFIDENTIAL MEDICAL REPORT"
        guard let selection = doc.findString(originalText, withOptions: []).first else {
            XCTFail("Target text '\(originalText)' not found in plain-text.pdf")
            return
        }

        let selectionBounds = selection.bounds(for: page)
        let block = try XCTUnwrap(TextBlock.at(CGPoint(x: selectionBounds.midX, y: selectionBounds.midY), on: page))
        XCTAssertTrue(block.text.contains("CONFIDENTIAL"), "Hit-tested block must contain CONFIDENTIAL")

        // Replace with new text
        let newText = "VERIFIED PATIENT DOSSIER"
        model.writeBlock(block, text: newText, style: block.style, on: page)

        // Verify replacement
        let updatedPage = try XCTUnwrap(doc.page(at: 0))
        let updatedString = try XCTUnwrap(updatedPage.string)
        XCTAssertTrue(updatedString.contains("VERIFIED PATIENT DOSSIER"), "Page string must contain replacement text")

        // Verify surrounding text still intact
        XCTAssertTrue(updatedString.contains("Patient ID:"), "Surrounding labels must remain intact")
        XCTAssertTrue(updatedString.contains("000-12-3456"), "Surrounding data must remain intact")
    }
}
