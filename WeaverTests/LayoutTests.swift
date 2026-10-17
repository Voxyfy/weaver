import CoreGraphics
import Testing
@testable import Weaver

struct LayoutTests {
    @Test func insertBesideCreatesSplit() {
        let a = LayoutNode(window: 1)
        let b = LayoutNode(window: 2)
        let root = a.insert(b, side: .right, of: a)
        #expect(root.axis == .horizontal)
        #expect(root.windowIDs == [1, 2])
    }

    @Test func insertSameAxisBecomesSibling() {
        let a = LayoutNode(window: 1), b = LayoutNode(window: 2), c = LayoutNode(window: 3)
        var root = a.insert(b, side: .right, of: a)
        root = root.insert(c, side: .right, of: b)
        #expect(root.children.count == 3)
        #expect(root.windowIDs == [1, 2, 3])
        #expect(abs(root.ratios.reduce(0, +) - 1) < 0.0001)
    }

    @Test func insertOtherAxisNests() {
        let a = LayoutNode(window: 1), b = LayoutNode(window: 2), c = LayoutNode(window: 3)
        var root = a.insert(b, side: .right, of: a)
        root = root.insert(c, side: .bottom, of: b)
        #expect(root.children.count == 2)
        #expect(root.children[1].axis == .vertical)
        #expect(root.windowIDs == [1, 2, 3])
    }

    @Test func removeCollapses() {
        let a = LayoutNode(window: 1), b = LayoutNode(window: 2)
        let root = a.insert(b, side: .left, of: a)
        let after = root.remove(b)
        #expect(after === a)
        #expect(a.parent == nil)
        #expect(root.remove(a) == nil || a.root === a)
    }

    @Test func layoutFramesAndSeams() {
        let a = LayoutNode(window: 1), b = LayoutNode(window: 2)
        let root = a.insert(b, side: .right, of: a)
        let layout = LayoutEngine.layout(root, in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let fa = layout.frames[1]!, fb = layout.frames[2]!
        #expect(fa.minX == LayoutEngine.gap)
        #expect(abs(fa.width - fb.width) < 0.001)
        #expect(fb.maxX == 1000 - LayoutEngine.gap)
        #expect(layout.seams.count == 1)
        #expect(layout.seams[0].rect.minX == fa.maxX)
    }

    @Test func seamMoveRespectsMinimum() {
        let a = LayoutNode(window: 1), b = LayoutNode(window: 2)
        let root = a.insert(b, side: .right, of: a)
        root.moveSeam(at: 0, by: 0.9)
        #expect(root.ratios[1] >= 0.08)
        #expect(abs(root.ratios.reduce(0, +) - 1) < 0.0001)
    }
}
