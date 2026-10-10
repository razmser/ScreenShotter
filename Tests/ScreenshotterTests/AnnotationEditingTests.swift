import AppKit
import XCTest
@testable import Screenshotter

@MainActor
final class AnnotationEditingTests: XCTestCase {
    private func canvas() throws -> CanvasView {
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 50, y: 70, width: 100, height: 3))
        return CanvasView(screenshot: Screenshot(image: try XCTUnwrap(context.makeImage()), scale: 1))
    }

    private func mouse(_ canvas: CanvasView, _ type: NSEvent.EventType, _ point: CGPoint,
                       clicks: Int = 1) throws {
        let location = canvas.convert(point, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        default: canvas.mouseUp(with: event)
        }
    }

    private func drag(_ canvas: CanvasView, _ start: CGPoint, _ end: CGPoint) throws {
        try mouse(canvas, .leftMouseDown, start)
        try mouse(canvas, .leftMouseDragged, end)
        try mouse(canvas, .leftMouseUp, end)
    }

    func testHighlightFollowsFreehandPathWithTranslucentMarkerNib() throws {
        let canvas = try canvas()
        canvas.tool = .highlight
        try mouse(canvas, .leftMouseDown, CGPoint(x: 30, y: 40))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 150, y: 40))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 150, y: 110))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 150, y: 110))
        let pixels = try XCTUnwrap(PixelBuffer(canvas.renderScreenshot().image))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(pixels.data[pixels.offset(x, y)..<pixels.offset(x, y) + 4])
        }
        let fill = pixel(80, 40)
        XCTAssertGreaterThan(fill[0], 240)
        XCTAssertGreaterThan(fill[1], 240, "Highlight defaults to yellow")
        XCTAssertTrue((100..<220).contains(Int(fill[2])), "Underlying image stays visible")
        XCTAssertEqual(pixel(80, 80), [255, 255, 255, 255], "A curved stroke must not fill its bounding rectangle")
        XCTAssertLessThan(pixel(150, 100)[2], 220, "The stroke follows the second leg of the gesture")
        XCTAssertLessThan(pixel(80, 30)[2], 220, "A marker has a broad vertical nib")
        XCTAssertEqual(pixel(20, 40), [255, 255, 255, 255], "The nib is narrower horizontally")
        XCTAssertEqual(pixel(24, 26), [255, 255, 255, 255], "Nib corners are rounded")
    }

    func testSelectMoveResizeRecolorDeleteAndUndo() throws {
        let canvas = try canvas()
        canvas.tool = .rectangle
        try drag(canvas, CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60))
        let original = canvas.annotations[0].bounds
        canvas.tool = .select
        let beforeSelection = canvas.changeCount
        try mouse(canvas, .leftMouseDown, CGPoint(x: 50, y: 20))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 50, y: 20))
        XCTAssertEqual(canvas.selectedIndex, 0)
        XCTAssertEqual(canvas.changeCount, beforeSelection, "Selection alone does not dirty the image")
        try drag(canvas, CGPoint(x: 50, y: 20), CGPoint(x: 80, y: 40))
        XCTAssertEqual(canvas.annotations.count, 1, "Dragging an existing mark must not draw another")
        XCTAssertEqual(canvas.annotations[0].bounds, original.offsetBy(dx: 30, dy: 20))
        canvas.undo(nil)
        XCTAssertEqual(canvas.annotations[0].bounds, original)
        canvas.redo(nil)
        let moved = canvas.annotations[0].bounds
        try mouse(canvas, .leftMouseDown, CGPoint(x: 80, y: 40))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 80, y: 40))
        try drag(canvas, CGPoint(x: moved.maxX, y: moved.maxY), CGPoint(x: 160, y: 120))
        XCTAssertEqual(canvas.annotations[0].bounds, CGRect(x: 50, y: 40, width: 110, height: 80))
        canvas.color = .blue
        XCTAssertEqual(canvas.annotations[0].color, .blue)
        canvas.lineWidth = 8
        XCTAssertEqual(canvas.annotations[0].lineWidth, 8)
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "", charactersIgnoringModifiers: "",
                                                   isARepeat: false, keyCode: 51))
        canvas.keyDown(with: delete)
        XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.undo(nil)
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations[0].lineWidth, 8)
    }

    func testTextCanBeReopenedEditedAndResizedWithoutDuplicatingIt() throws {
        let canvas = try canvas()
        canvas.tool = .text
        try mouse(canvas, .leftMouseDown, CGPoint(x: 30, y: 60))
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Original"
        canvas.commitText()
        let origin = canvas.annotations[0].bounds.origin
        canvas.tool = .select
        let point = CGPoint(x: origin.x + 20, y: origin.y + 10)
        try mouse(canvas, .leftMouseDown, point, clicks: 2)
        let reopened = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(reopened.stringValue, "Original")
        reopened.stringValue = "Edited"
        canvas.textFontSize = 42
        canvas.commitText()
        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .text(string, updatedOrigin, size) = canvas.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(string, "Edited")
        XCTAssertEqual(updatedOrigin, origin)
        XCTAssertEqual(size, 42)
        canvas.undo(nil)
        guard case let .text(oldString, _, oldSize) = canvas.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(oldString, "Original")
        XCTAssertEqual(oldSize, 26)
    }

    func testChangingToolCommitsPendingTextAndKeepsRequestedTool() throws {
        let canvas = try canvas()
        canvas.tool = .text
        try mouse(canvas, .leftMouseDown, CGPoint(x: 30, y: 60))
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Label"
        canvas.tool = .highlight
        XCTAssertEqual(canvas.tool, .highlight)
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.color, .yellow)
        XCTAssertNil(canvas.selectedIndex)
    }

    func testSelectionUsesDocumentCoordinatesAfterCropAndZoom() throws {
        let canvas = try canvas()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        scroll.documentView = canvas
        scroll.allowsMagnification = true
        scroll.magnification = 2
        canvas.tool = .highlight
        try drag(canvas, CGPoint(x: 60, y: 60), CGPoint(x: 120, y: 100))
        canvas.tool = .crop
        try drag(canvas, CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 140))
        XCTAssertEqual(canvas.crop.origin, CGPoint(x: 40, y: 40))
        canvas.tool = .select
        try drag(canvas, CGPoint(x: 50, y: 40), CGPoint(x: 60, y: 50))
        XCTAssertEqual(canvas.annotations.count, 1)
        guard case let .highlight(movedPoints) = canvas.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(movedPoints.first, CGPoint(x: 70, y: 70))
        canvas.undo(nil)
        guard case let .highlight(originalPoints) = canvas.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(originalPoints.first, CGPoint(x: 60, y: 60))
    }

    func testGeometryHitTestingAndArrowEndpointEditing() {
        let arrow = Annotation(shape: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100)),
                               color: .red, lineWidth: 4)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 50), tolerance: 5))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 90, y: 10), tolerance: 5))
        let edited = arrow.resized(handle: 1, to: CGPoint(x: 120, y: 30))
        XCTAssertEqual(edited.handles, [CGPoint(x: 10, y: 10), CGPoint(x: 120, y: 30)])
        let pen = Annotation(shape: .pen([CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 20)]), color: .red, lineWidth: 4)
        XCTAssertTrue(pen.hitTest(CGPoint(x: 50, y: 22), tolerance: 5))
        XCTAssertEqual(pen.translated(dx: 10, dy: 30).bounds, CGRect(x: 20, y: 50, width: 70, height: 0))
    }

    func testFlatEllipseHitTestStaysNearOutlineAndTextResizesFromAnyHandle() {
        let ellipse = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 400, height: 10)), color: .red, lineWidth: 4)
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 402, y: 5), tolerance: 5))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 450, y: 5), tolerance: 5))
        let text = Annotation(shape: .text("Label", origin: CGPoint(x: 100, y: 100), fontSize: 20), color: .red, lineWidth: 0)
        let wider = text.resized(handle: 2, to: CGPoint(x: text.bounds.maxX + text.bounds.width, y: text.bounds.maxY))
        guard case let .text(_, _, size) = wider.shape else { return XCTFail() }
        XCTAssertEqual(size, 40, accuracy: 0.5)
        let stroke = Annotation(shape: .pen([CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 80)]), color: .red, lineWidth: 4)
        XCTAssertEqual(stroke.resized(handle: 2, to: CGPoint(x: -10, y: 80)).bounds.origin, CGPoint(x: 10, y: 10))
        let flat = Annotation(shape: .pen([CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 20)]), color: .red, lineWidth: 4)
        XCTAssertEqual(flat.resized(handle: 2, to: CGPoint(x: 100, y: 0)).bounds, CGRect(x: 10, y: 20, width: 90, height: 0))
    }

    func testDeleteAndUndoAreIgnoredMidDragAndClickAwayFinishesText() throws {
        let canvas = try canvas()
        canvas.tool = .rectangle
        try drag(canvas, CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60))
        canvas.tool = .select
        try mouse(canvas, .leftMouseDown, CGPoint(x: 20, y: 40))
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "\u{7f}",
                                                    charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        canvas.keyDown(with: delete)
        canvas.undo(nil)
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 30, y: 40))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 30, y: 40))
        XCTAssertEqual(canvas.annotations.count, 1)

        canvas.tool = .text
        try mouse(canvas, .leftMouseDown, CGPoint(x: 100, y: 100))
        try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first).stringValue = "Hi"
        try mouse(canvas, .leftMouseDown, CGPoint(x: 150, y: 120))
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? NSTextField }.isEmpty)
    }

    func testTextSizeControlsFollowActiveTool() throws {
        let controller = EditorWindowController(screenshot: try canvas().renderScreenshot())
        defer { controller.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try XCTUnwrap(controller.window?.contentView))
        let canvas = try XCTUnwrap(views.compactMap { $0 as? CanvasView }.first)
        let sizes = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }
            .first { $0.toolTip == "Text size" })
        XCTAssertTrue(sizes.isHidden)
        canvas.tool = .text
        XCTAssertFalse(sizes.isHidden)
        canvas.tool = .highlight
        XCTAssertTrue(sizes.isHidden)
        XCTAssertFalse(Tool.allCases.contains { $0.title == "Erase" })
    }


    func testSelectionDecorationsAreNotExportedAndDragIsOneUndoStep() throws {
        let canvas = try canvas()
        canvas.tool = .highlight
        try drag(canvas, CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60))
        canvas.tool = .select
        try mouse(canvas, .leftMouseDown, CGPoint(x: 50, y: 40))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 50, y: 40))
        let selected = try XCTUnwrap(PixelBuffer(canvas.renderScreenshot().image))
        let changes = canvas.changeCount
        try mouse(canvas, .leftMouseDown, CGPoint(x: 50, y: 40))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 60, y: 45))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 70, y: 50))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 70, y: 50))
        XCTAssertEqual(canvas.changeCount, changes + 1)
        canvas.undo(nil)
        let unselected = try XCTUnwrap(PixelBuffer(canvas.renderScreenshot().image))
        XCTAssertEqual(selected.data, unselected.data, "Selection handles must never appear in exports")
        canvas.undo(nil)
        XCTAssertTrue(canvas.annotations.isEmpty, "One undo restores the whole drag, next undo removes the original mark")
    }

    func testExportDuringDragIncludesTheMove() throws {
        let canvas = try canvas()
        canvas.tool = .rectangle
        try drag(canvas, CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60))
        canvas.tool = .select
        try mouse(canvas, .leftMouseDown, CGPoint(x: 20, y: 40))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 50, y: 40))
        _ = canvas.renderScreenshot() // e.g. Return pressed before releasing the mouse
        XCTAssertEqual(canvas.annotations[0].bounds.minX, 50)
        let changes = canvas.changeCount
        try mouse(canvas, .leftMouseUp, CGPoint(x: 50, y: 40))
        XCTAssertEqual(canvas.changeCount, changes, "The move is recorded once")
    }

    func testPixelateResamplesDestinationWhenMoved() throws {
        let canvas = try canvas()
        canvas.tool = .pixelate
        try drag(canvas, CGPoint(x: 40, y: 78), CGPoint(x: 160, y: 100))
        XCTAssertEqual(canvas.annotations.count, 1)
        canvas.tool = .select
        try drag(canvas, CGPoint(x: 90, y: 88), CGPoint(x: 90, y: 38))
        guard case let .patch(rect, image) = canvas.annotations[0].shape else { return XCTFail() }
        XCTAssertEqual(rect.minY, 28)
        let pixels = try XCTUnwrap(PixelBuffer(try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        XCTAssertTrue(pixels.data.allSatisfy { $0 == 255 }, "Moving pixelation must sample its new location")
        canvas.undo(nil)
        XCTAssertEqual(canvas.annotations[0].bounds.minY, 78)
    }


    func testDrawingOverExistingMarksDoesNotSelectOrMoveThem() throws {
        let canvas = try canvas()
        canvas.tool = .highlight
        try drag(canvas, CGPoint(x: 30, y: 40), CGPoint(x: 150, y: 40))
        let original = canvas.annotations[0].bounds
        XCTAssertNil(canvas.selectedIndex)
        try drag(canvas, CGPoint(x: 80, y: 40), CGPoint(x: 80, y: 110))
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertEqual(canvas.annotations[0].bounds, original)
        XCTAssertNil(canvas.selectedIndex)
        canvas.tool = .arrow
        try drag(canvas, CGPoint(x: 80, y: 40), CGPoint(x: 200, y: 120))
        XCTAssertEqual(canvas.annotations.count, 3)
        XCTAssertNil(canvas.selectedIndex)
        canvas.tool = .select
        try drag(canvas, CGPoint(x: 50, y: 40), CGPoint(x: 50, y: 60))
        XCTAssertEqual(canvas.annotations.count, 3)
        XCTAssertEqual(canvas.tool, .select, "Selection mode stays active after selecting and dragging")
        XCTAssertEqual(canvas.propertiesTool, .highlight)
        XCTAssertEqual(canvas.annotations[0].bounds, original.offsetBy(dx: 0, dy: 20))
        canvas.markerWidth = 44
        XCTAssertEqual(canvas.annotations[0].lineWidth, 44)
        canvas.undo(nil)
        XCTAssertEqual(canvas.annotations[0].lineWidth, 28)
    }

    func testMarkerOpacityIsEvenWithinAStrokeAndUnderlyingTextStaysVisible() throws {
        let canvas = try canvas()
        canvas.tool = .highlight
        try mouse(canvas, .leftMouseDown, CGPoint(x: 30, y: 88))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 180, y: 88))
        try mouse(canvas, .leftMouseDragged, CGPoint(x: 30, y: 88))
        try mouse(canvas, .leftMouseUp, CGPoint(x: 30, y: 88))
        let pixels = try XCTUnwrap(PixelBuffer(canvas.renderScreenshot().image))
        XCTAssertLessThan(pixels.data[pixels.offset(80, 88)], 20)
        XCTAssertEqual(pixels.data[pixels.offset(80, 80) + 2], pixels.data[pixels.offset(170, 80) + 2])
        XCTAssertGreaterThan(pixels.data[pixels.offset(80, 80) + 2], 100, "Overlapping nib samples are composited once")
        let annotation = canvas.annotations[0]
        let resized = annotation.resized(handle: 2, to: CGPoint(x: annotation.bounds.maxX + 40,
                                                              y: annotation.bounds.maxY + 20))
        XCTAssertGreaterThan(resized.lineWidth, annotation.lineWidth)
        XCTAssertEqual(resized.bounds.minX, annotation.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(resized.bounds.minY, annotation.bounds.minY, accuracy: 0.01)
    }

}
