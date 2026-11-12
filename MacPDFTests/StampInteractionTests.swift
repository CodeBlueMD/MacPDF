import AppKit
import PDFKit
import XCTest
@testable import MacPDF

final class StampInteractionTests: XCTestCase {
    private func makeTestDocument() -> (PDFDocument, PDFPage) {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            fatalError("Failed to create PDF context")
        }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        let doc = PDFDocument(data: data as Data)!
        return (doc, doc.page(at: 0)!)
    }

    func testPlacingStampSelectsIt() throws {
        let (doc, page) = makeTestDocument()
        let model = DocumentModel(pdf: doc)

        let placePoint = CGPoint(x: 200, y: 300)
        let stamp = model.addStamp(at: placePoint, on: page)

        XCTAssertTrue(page.annotations.contains(stamp))
        XCTAssertTrue(model.selectedAnnotation === stamp)
        XCTAssertTrue(stamp.isStamp)
        XCTAssertEqual(stamp.bounds.midX, placePoint.x, accuracy: 2.0)
        XCTAssertEqual(stamp.bounds.midY, placePoint.y, accuracy: 2.0)
    }

    func testMovingStampUpdatesBoundsAndUndo() throws {
        let (doc, page) = makeTestDocument()
        let model = DocumentModel(pdf: doc)
        let undoManager = UndoManager()
        model.undoManager = undoManager

        let stamp = model.addStamp(at: CGPoint(x: 200, y: 300), on: page)
        let originalBounds = stamp.bounds

        let newBounds = originalBounds.offsetBy(dx: 60, dy: -40)
        model.moveAnnotation(stamp, to: newBounds)

        XCTAssertEqual(stamp.bounds.origin.x, newBounds.origin.x, accuracy: 0.001)
        XCTAssertEqual(stamp.bounds.origin.y, newBounds.origin.y, accuracy: 0.001)
        XCTAssertEqual(stamp.bounds.width, newBounds.width, accuracy: 0.001)
        XCTAssertEqual(stamp.bounds.height, newBounds.height, accuracy: 0.001)

        undoManager.undo()
        XCTAssertEqual(stamp.bounds.origin.x, originalBounds.origin.x, accuracy: 0.001)
        XCTAssertEqual(stamp.bounds.origin.y, originalBounds.origin.y, accuracy: 0.001)

        undoManager.redo()
        XCTAssertEqual(stamp.bounds.origin.x, newBounds.origin.x, accuracy: 0.001)
        XCTAssertEqual(stamp.bounds.origin.y, newBounds.origin.y, accuracy: 0.001)
    }

    func testDeletingSelectedAnnotationRemovesFromPageAndUndo() throws {
        let (doc, page) = makeTestDocument()
        let model = DocumentModel(pdf: doc)
        let undoManager = UndoManager()
        model.undoManager = undoManager

        let stamp = model.addStamp(at: CGPoint(x: 250, y: 350), on: page)
        XCTAssertTrue(model.selectedAnnotation === stamp)
        XCTAssertTrue(page.annotations.contains(stamp))

        // End the current undo group so the deletion is a distinct undo step
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()

        model.deleteSelectedAnnotation()
        XCTAssertNil(model.selectedAnnotation)
        XCTAssertFalse(page.annotations.contains(stamp))

        undoManager.endUndoGrouping()

        undoManager.undo()
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertTrue(page.annotations.contains(where: { $0.bounds == stamp.bounds }))
    }

    func testDuplicatingStampCreatesOffsetCopy() throws {
        let (doc, page) = makeTestDocument()
        let model = DocumentModel(pdf: doc)

        let stamp = model.addStamp(at: CGPoint(x: 200, y: 300), on: page)
        XCTAssertEqual(page.annotations.count, 1)

        model.duplicateSelectedAnnotation()
        XCTAssertEqual(page.annotations.count, 2)
        guard let duplicate = model.selectedAnnotation as? StampAnnotation else {
            XCTFail("Expected duplicate to be StampAnnotation and selected")
            return
        }
        XCTAssertTrue(duplicate !== stamp)
        XCTAssertEqual(duplicate.bounds.midX, stamp.bounds.midX + 20, accuracy: 0.5)
        XCTAssertEqual(duplicate.bounds.midY, stamp.bounds.midY - 20, accuracy: 0.5)
    }

    func testStampHitTestingInMacPDFView() throws {
        let (doc, page) = makeTestDocument()
        let model = DocumentModel(pdf: doc)
        let pdfView = model.pdfView

        let center = CGPoint(x: 300, y: 400)
        let stamp = model.addStamp(at: center, on: page)

        // Inside the stamp bounds
        let hitInside = pdfView.stampAnnotation(at: center, on: page)
        XCTAssertTrue(hitInside === stamp)

        // Within tolerance margin (e.g. 4 points outside the bounds)
        let nearPoint = CGPoint(x: stamp.bounds.maxX + 4, y: stamp.bounds.midY)
        let hitNear = pdfView.stampAnnotation(at: nearPoint, on: page)
        XCTAssertTrue(hitNear === stamp)

        // Far outside the stamp bounds
        let farPoint = CGPoint(x: 50, y: 50)
        let hitFar = pdfView.stampAnnotation(at: farPoint, on: page)
        XCTAssertNil(hitFar)
    }

    func testVectorFillAnnotationSelectionAndMove() throws {
        let (doc, page) = makeTestDocument()
        let model = DocumentModel(pdf: doc)
        let undoManager = UndoManager()
        model.undoManager = undoManager

        let fill = model.addFillText(.checkmark, at: CGPoint(x: 150, y: 250), on: page)
        XCTAssertTrue(model.selectedAnnotation === fill)
        XCTAssertTrue(fill.isStamp)

        let originalBounds = fill.bounds
        let movedBounds = originalBounds.offsetBy(dx: 30, dy: 30)
        model.moveAnnotation(fill, to: movedBounds)
        XCTAssertEqual(fill.bounds.origin.x, movedBounds.origin.x, accuracy: 0.001)

        model.deleteSelectedAnnotation()
        XCTAssertNil(model.selectedAnnotation)
        XCTAssertFalse(page.annotations.contains(fill))
    }
}
