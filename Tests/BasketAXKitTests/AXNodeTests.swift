import Foundation
import Testing
@testable import BasketAXKit

@Suite struct AXRectTests {
    @Test func intersectionAndContainment() {
        let a = r(0, 0, 100, 50)
        #expect(a.intersection(r(90, 40, 20, 20)) == r(90, 40, 10, 10))
        #expect(a.intersection(r(100, 0, 10, 10)) == nil, "touching edges don't intersect")
        #expect(a.contains(r(10, 10, 20, 20)))
        #expect(!a.contains(r(-1, 0, 10, 10)))
        #expect(a.contains(r(-1, 0, 10, 10), tolerance: 1))
        #expect(r(0, 0, 0, 10).isEmpty)
        #expect(r(1, 2, 3.5, 4).short == "1,2 3.5x4")
    }
}

@Suite struct AXNodeTests {
    @Test func jsonRoundTripAndCompactLeaves() throws {
        let tree = window([button("x.action.go", r(110, 110, 40, 24), title: "Go")])
        let data = try tree.jsonData()
        let decoded = try AXNode.decode(jsonData: data)
        #expect(decoded == tree)
        let json = String(decoding: data, as: UTF8.self)
        // The leaf button omits `children`; nil attributes are omitted too.
        #expect(json.components(separatedBy: "\"children\"").count == 2)
        #expect(!json.contains("placeholder"))
    }

    @Test func decodesHandWrittenSnapshotWithoutChildren() throws {
        let json = #"{"role":"AXWindow","identifier":"basket.main","children":[{"role":"AXButton","title":"OK"}]}"#
        let node = try AXNode.decode(jsonData: Data(json.utf8))
        #expect(node.children.first?.children == [])
        #expect(node.children.first?.title == "OK")
    }

    @Test func traversalHelpers() {
        let tree = window([group([button("a.b", nil), text("hi", nil)], id: "g.x")])
        #expect(tree.nodeCount == 4)
        #expect(tree.first(identifier: "a.b")?.role == "AXButton")
        #expect(tree.contains(identifier: "g.x"))
        #expect(!tree.contains(identifier: "nope"))
        #expect(tree.all { $0.role == "AXStaticText" }.count == 1)
        var depths: [Int] = []
        tree.walk { _, ancestors in depths.append(ancestors.count) }
        #expect(depths == [0, 1, 2, 2])
    }

    @Test func accessibleNameAndText() {
        #expect(AXNode(role: "AXButton", title: "  ", label: "Delete").accessibleName == "Delete")
        #expect(AXNode(role: "AXButton", help: "Removes it").accessibleName == "Removes it")
        #expect(AXNode(role: "AXButton").accessibleName == nil)
        #expect(AXNode(role: "AXStaticText", label: "l", value: "v").text == "v")
    }

    @Test func snapshotIORoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = basketWindow(section: "images")
        try AXSnapshotIO.write(tree, section: "images", to: dir)
        try AXSnapshotIO.write(basketWindow(section: "overview"), section: "overview", to: dir)
        try Data("x".utf8).write(to: dir.appendingPathComponent("images.png"))
        #expect(try AXSnapshotIO.sections(in: dir) == ["images", "overview"])
        #expect(try AXSnapshotIO.load(section: "images", from: dir) == tree)
    }
}

@Suite struct TextMeasureTests {
    @Test func widthGrowsWithTextAndSize() {
        let w13 = TextMeasure.width(of: "Containers", fontSize: 13)
        #expect(w13 > 50 && w13 < 90)
        #expect(TextMeasure.width(of: "Containers", fontSize: 11) < w13)
        #expect(TextMeasure.width(of: "Containers and images", fontSize: 13) > w13)
        #expect(TextMeasure.width(of: "", fontSize: 13) == 0)
    }

    @Test func fontEstimateFromFrameHeight() {
        #expect(TextMeasure.estimateFont(forFrameHeight: 16) == (13, 1))
        #expect(TextMeasure.estimateFont(forFrameHeight: 15) == (12, 1))
        #expect(TextMeasure.estimateFont(forFrameHeight: 14) == (11, 1))
        #expect(TextMeasure.estimateFont(forFrameHeight: 13) == (10, 1))
        #expect(TextMeasure.estimateFont(forFrameHeight: 12) == (10, 1))
        #expect(TextMeasure.estimateFont(forFrameHeight: 20) == (17, 1))
        let tall = TextMeasure.estimateFont(forFrameHeight: 48)
        #expect(tall.fontSize == 10 && tall.lines == 3)
    }
}
