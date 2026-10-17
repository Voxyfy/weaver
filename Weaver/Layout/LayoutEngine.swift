import CoreGraphics

/// A gap between two siblings that the user can drag to resize both.
struct Seam {
    let split: LayoutNode
    let index: Int          // between children[index] and children[index + 1]
    let axis: Axis
    let rect: CGRect        // the gap itself, in Quartz coordinates
    let parentLength: CGFloat
}

struct TabStrip {
    let node: LayoutNode
    let rect: CGRect
}

struct Layout {
    var frames: [CGWindowID: CGRect] = [:]
    var seams: [Seam] = []
    var tabStrips: [TabStrip] = []
    /// Where the Desktop cell landed, if it is part of the visible tree and not hidden.
    var desktopRect: CGRect?
}

enum LayoutEngine {
    /// Set by the manager from Preferences before each layout pass.
    nonisolated(unsafe) static var gap: CGFloat = 8
    static let tabStripHeight: CGFloat = 34

    /// Lays `node` out inside `rect` (Quartz coordinates), gaps between siblings included.
    /// With `hideDesktop` the Desktop cell takes no space (nothing is floating on it).
    static func layout(_ node: LayoutNode, in rect: CGRect, hideDesktop: Bool = false) -> Layout {
        var result = Layout()
        place(node, in: rect.insetBy(dx: gap, dy: gap), hideDesktop: hideDesktop, into: &result)
        return result
    }

    /// A node that would render nothing: a hidden Desktop, or a split of only such nodes.
    private static func isEmpty(_ node: LayoutNode, hideDesktop: Bool) -> Bool {
        if node.isDesktop { return hideDesktop }
        if node.isLeaf { return false }
        return node.children.allSatisfy { isEmpty($0, hideDesktop: hideDesktop) }
    }

    private static func place(_ node: LayoutNode, in rect: CGRect, hideDesktop: Bool, into result: inout Layout) {
        if let id = node.windowID {
            result.frames[id] = rect
            return
        }
        if node.isTabs {
            // Every member gets the cell below the strip; the manager raises the active one.
            let strip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: tabStripHeight)
            let body = CGRect(x: rect.minX, y: rect.minY + tabStripHeight, width: rect.width, height: max(0, rect.height - tabStripHeight))
            for id in node.members { result.frames[id] = body }
            result.tabStrips.append(TabStrip(node: node, rect: strip))
            return
        }
        if node.isDesktop {
            if !hideDesktop { result.desktopRect = rect }
            return
        }
        guard let axis = node.axis else { return }
        // Skip empty children and spread their share over the rest, so a hidden Desktop
        // leaves no hole; the tree itself is untouched.
        let visible = node.children.enumerated().filter { !isEmpty($0.element, hideDesktop: hideDesktop) }
        guard !visible.isEmpty else { return }
        let total = visible.reduce(0) { $0 + node.ratios[$1.offset] }
        let count = CGFloat(visible.count)
        let length = (axis == .horizontal ? rect.width : rect.height) - gap * (count - 1)
        var cursor = axis == .horizontal ? rect.minX : rect.minY
        for (n, (i, child)) in visible.enumerated() {
            let share = max(0, length * node.ratios[i] / max(total, 0.0001))
            let childRect = axis == .horizontal
                ? CGRect(x: cursor, y: rect.minY, width: share, height: rect.height)
                : CGRect(x: rect.minX, y: cursor, width: rect.width, height: share)
            place(child, in: childRect, hideDesktop: hideDesktop, into: &result)
            cursor += share
            if n < visible.count - 1 {
                let seamRect = axis == .horizontal
                    ? CGRect(x: cursor, y: rect.minY, width: gap, height: rect.height)
                    : CGRect(x: rect.minX, y: cursor, width: rect.width, height: gap)
                result.seams.append(Seam(split: node, index: i, axis: axis, rect: seamRect, parentLength: length))
                cursor += gap
            }
        }
    }
}
