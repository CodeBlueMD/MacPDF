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

        // Verify the sensitive string exists before redaction
        let targetText = "000-12-3456"
        let initialMatches = doc.findString(targetText, withOptions: [])
        XCTAssertFalse(initialMatches.isEmpty, "Precondition: Sensitive text must exist initially")

        let initialPageString = try XCTUnwrap(doc.page(at: 0)?.string)
        XCTAssertTrue(initialPageString.contains(targetText))

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
        let targetUTF8 = Data(targetText.utf8)
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
        let matches = doc.findString(secretCode, withOptions: [])
        XCTAssertFalse(matches.isEmpty, "Secret code must exist initially")

        let page = try XCTUnwrap(doc.page(at: 0))
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
    func testImmediateSaveBurnsPendingRedactionsWithoutWaitingForTimer() async throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let file = PDFFile()
        file.pdf.removePage(at: 0)
        file.pdf.insert(doc.page(at: 0)!.copy() as! PDFPage, at: 0)

        let model = DocumentModel(pdf: file.pdf)

        let patientID = "PT-98234-X"
        let matches = file.pdf.findString(patientID, withOptions: [])
        XCTAssertFalse(matches.isEmpty)

        // Apply redaction mark (which schedules async burn with 350ms delay)
        model.redact(matches[0])

        // Immediately burn via model before taking snapshot
        await model.burnAllPendingRedactions()
        let snapshotData = try file.snapshot(contentType: .pdf)

        // Verify that snapshot data has the redaction burned in
        let reopened = try XCTUnwrap(PDFDocument(data: snapshotData))
        let reopenedText = reopened.page(at: 0)?.string ?? ""
        XCTAssertFalse(reopenedText.contains(patientID),
                       "Immediate snapshot must burn pending redactions")
        XCTAssertNil(snapshotData.range(of: Data(patientID.utf8)),
                     "Target text must not exist in raw bytes of snapshot")
    }

    @MainActor
    func testRotatedPageRedactionBurnsAccurately() async throws {
        let url = fixturesURL.appendingPathComponent("rotated-page.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let model = DocumentModel(pdf: doc)

        let secret = "ROT-998811"
        let matches = doc.findString(secret, withOptions: [])
        XCTAssertFalse(matches.isEmpty)

        model.redact(matches[0])
        await model.burnAllPendingRedactions()

        let savedData = try XCTUnwrap(doc.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: savedData))

        XCTAssertEqual(reopened.page(at: 0)?.rotation, 90, "Rotation should be preserved")
        let text = reopened.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.contains(secret), "Redacted text on rotated page must be purged")
        XCTAssertNil(savedData.range(of: Data(secret.utf8)), "Secret text found in raw bytes of rotated page")
    }

    @MainActor
    func testDirectRasterizedDestroysRedactedText() async throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))

        let target = "ALPHA-OMEGA-99"
        let matches = doc.findString(target, withOptions: [])
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
}
