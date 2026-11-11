import AppKit
import PDFKit
import XCTest
@testable import MacPDF

final class FixtureTests: XCTestCase {
    private var fixturesURL: URL {
        // Path to fixtures directory in workspace
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return projectDir
    }

    func testPlainTextFixture() throws {
        let url = fixturesURL.appendingPathComponent("plain-text.pdf")
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load plain-text.pdf from \(url.path)")
            return
        }
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let text = try XCTUnwrap(page.string)
        XCTAssertTrue(text.contains("CONFIDENTIAL MEDICAL REPORT"))
        XCTAssertTrue(text.contains("SSN: 000-12-3456"))
        XCTAssertTrue(text.contains("Secret Code: ALPHA-OMEGA-99"))
        XCTAssertFalse(OCR.needsText(page))
    }

    func testSubsetFontsFixture() throws {
        let url = fixturesURL.appendingPathComponent("subset-fonts.pdf")
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load subset-fonts.pdf")
            return
        }
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let text = try XCTUnwrap(page.string)
        XCTAssertTrue(text.contains("SUBSET FONT SPECIMEN"))

        // Verify standard 6-character subset prefix [A-Z]{6}+ in font naming (e.g. AAAAAB+)
        let data = try Data(contentsOf: url)
        let raw = String(decoding: data, as: UTF8.self)
        let hasSubset = raw.range(of: #"/BaseFont\s*/[A-Z]{6}\+"#, options: .regularExpression) != nil
        XCTAssertTrue(hasSubset,
                      "Expected 6-letter subset font tag (e.g. AAAAAB+) in font naming")
    }

    func testTwoColumnFixture() throws {
        let url = fixturesURL.appendingPathComponent("two-column.pdf")
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load two-column.pdf")
            return
        }
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let lines = (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? [])
        let leftLines = lines.filter { $0.bounds(for: page).minX < 200 }
        let rightLines = lines.filter { $0.bounds(for: page).minX > 300 }

        XCTAssertFalse(leftLines.isEmpty, "Should have left column lines")
        XCTAssertFalse(rightLines.isEmpty, "Should have right column lines")
    }

    func testRotatedPageFixture() throws {
        let url = fixturesURL.appendingPathComponent("rotated-page.pdf")
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load rotated-page.pdf")
            return
        }
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertEqual(page.rotation, 90, "Page should have 90 degree rotation")
        let text = try XCTUnwrap(page.string)
        XCTAssertTrue(text.contains("ROTATED DOCUMENT"))
    }

    func testFormFixture() throws {
        let url = fixturesURL.appendingPathComponent("form.pdf")
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load form.pdf")
            return
        }
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let widgets = page.annotations.filter { $0.type == "Widget" }
        XCTAssertGreaterThanOrEqual(widgets.count, 3, "Expected at least 3 form field widgets")

        let names = widgets.compactMap(\.fieldName)
        XCTAssertTrue(names.contains("FullName"), "Expected FullName field")
        XCTAssertTrue(names.contains("DOB"), "Expected DOB field")
        XCTAssertTrue(names.contains("Consent"), "Expected Consent field")
    }

    func testScannedFixture() throws {
        let url = fixturesURL.appendingPathComponent("scanned.pdf")
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Failed to load scanned.pdf")
            return
        }
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertTrue(OCR.needsText(page), "Scanned document without text layer should require OCR")
        let text = page.string ?? ""
        XCTAssertLessThan(text.trimmingCharacters(in: .whitespacesAndNewlines).count, 20)
    }
}
