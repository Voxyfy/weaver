import CoreGraphics

enum Axis { case horizontal, vertical }

enum Side {
    case left, right, top, bottom

    var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    /// Whether the inserted node goes before (left/top) or after (right/bottom) its sibling.
    var before: Bool { self == .left || self == .top }
}

/// A space is a tree: leaves are windows, inner nodes split their area along one axis.
/// Nesting a split inside a split is what makes the layout "fractal".
final class LayoutNode {
    enum Kind {
        case window(CGWindowID)
        case split(Axis)
        /// The Desktop: every floating window lives in this cell and scales with it.
        case desktop
        /// Several windows sharing one cell under a tab strip; one is in front.
        case tabs
    }

    private(set) var kind: Kind
    /// Members of a tab group, in strip order (empty unless `kind == .tabs`).
    private(set) var members: [CGWindowID] = []
    /// The member shown in front of the others.
    var activeMember: CGWindowID?
    private(set) var children: [LayoutNode] = []
    /// One ratio per child, summing to 1.
    private(set) var ratios: [CGFloat] = []
    private(set) weak var parent: LayoutNode?

    init(window id: CGWindowID) { kind = .window(id) }

    init(desktop: Void = ()) { kind = .desktop }

    var isTabs: Bool {
        if case .tabs = kind { return true }
        return false
    }

    /// Turn a window leaf into a tab group holding itself and `id`, with `id` in front.
    func makeTabs(adding id: CGWindowID) {
        guard let own = windowID else { return }
        kind = .tabs
        members = [own, id]
        activeMember = id
    }

    /// Whatever this leaf is, end up as a tab group that also holds `id`.
    func makeTabsOrAdd(_ id: CGWindowID) {
        if isTabs { addMember(id) } else { makeTabs(adding: id) }
    }

    func addMember(_ id: CGWindowID) {
        guard isTabs, !members.contains(id) else { return }
        members.append(id)
        activeMember = id
    }

    /// Removes a member. With one member left the node turns back into a plain window leaf.
    func removeMember(_ id: CGWindowID) {
        guard isTabs, let i = members.firstIndex(of: id) else { return }
        members.remove(at: i)
        if activeMember == id { activeMember = members[min(i, members.count - 1)] }
        if members.count == 1 {
            kind = .window(members[0])
            members = []
            activeMember = nil
        }
    }

    var isDesktop: Bool {
        if case .desktop = kind { return true }
        return false
    }

    init(axis: Axis, children: [LayoutNode], ratios: [CGFloat]? = nil) {
        kind = .split(axis)
        self.children = children
        self.ratios = ratios ?? Array(repeating: 1 / CGFloat(max(children.count, 1)), count: children.count)
        children.forEach { $0.parent = self }
    }

    var windowID: CGWindowID? {
        if case .window(let id) = kind { return id }
        return nil
    }

    var axis: Axis? {
        if case .split(let a) = kind { return a }
        return nil
    }

    var isLeaf: Bool { windowID != nil || isDesktop || isTabs }

    /// Every window in this subtree, tab-group members included.
    var allWindowIDs: [CGWindowID] {
        if let id = windowID { return [id] }
        if isTabs { return members }
        return children.flatMap(\.allWindowIDs)
    }

    var leaves: [LayoutNode] {
        isLeaf ? [self] : children.flatMap(\.leaves)
    }

    var windowIDs: [CGWindowID] { allWindowIDs }

    /// The leaf holding the window: the window node itself, or the tab group it belongs to.
    func find(window id: CGWindowID) -> LayoutNode? {
        if windowID == id || (isTabs && members.contains(id)) { return self }
        for c in children { if let n = c.find(window: id) { return n } }
        return nil
    }

    var desktopNode: LayoutNode? {
        if isDesktop { return self }
        for c in children { if let n = c.desktopNode { return n } }
        return nil
    }

    func contains(_ node: LayoutNode) -> Bool {
        var n: LayoutNode? = node
        while let current = n {
            if current === self { return true }
            n = current.parent
        }
        return false
    }

    var root: LayoutNode {
        var n = self
        while let p = n.parent { n = p }
        return n
    }

    /// Puts `node` beside `target` on the given side. When the target's parent already splits
    /// along that axis the node becomes a sibling; otherwise the target is wrapped in a new split.
    /// Returns the (possibly new) root.
    @discardableResult
    func insert(_ node: LayoutNode, side: Side, of target: LayoutNode) -> LayoutNode {
        node.detachFromParent()
        if let parent = target.parent, parent.axis == side.axis {
            let index = parent.children.firstIndex { $0 === target }!
            let share = parent.ratios[index] / 2
            parent.ratios[index] = share
            let at = side.before ? index : index + 1
            parent.children.insert(node, at: at)
            parent.ratios.insert(share, at: at)
            node.parent = parent
            return parent.root
        }
        // Wrap: the new split takes the target's place in its parent (or becomes the root).
        let oldParent = target.parent
        let oldIndex = oldParent?.children.firstIndex { $0 === target }
        let split = LayoutNode(axis: side.axis, children: side.before ? [node, target] : [target, node])
        if let oldParent, let oldIndex {
            oldParent.children[oldIndex] = split
            split.parent = oldParent
        }
        return split.root
    }

    /// Removes a leaf and collapses any split left with one child. Returns the new root,
    /// or nil when the tree is now empty.
    func remove(_ node: LayoutNode) -> LayoutNode? {
        let root = self.root
        guard let parent = node.parent else {
            return node === root ? nil : root
        }
        let index = parent.children.firstIndex { $0 === node }!
        parent.children.remove(at: index)
        let freed = parent.ratios.remove(at: index)
        if !parent.ratios.isEmpty {
            // Give the freed share to the neighbour that was next to it.
            let receiver = min(index, parent.ratios.count - 1)
            parent.ratios[receiver] += freed
        }
        node.parent = nil
        if parent.children.count == 1 {
            let only = parent.children[0]
            if let grand = parent.parent {
                let i = grand.children.firstIndex { $0 === parent }!
                grand.children[i] = only
                only.parent = grand
                return grand.root
            }
            only.parent = nil
            return only
        }
        return parent.root
    }

    /// Hands one child's whole share to another (used when a window takes the Desktop's place).
    func transferShare(from: Int, to: Int) {
        guard ratios.indices.contains(from), ratios.indices.contains(to), from != to else { return }
        ratios[to] += ratios[from]
        ratios[from] = 0
    }

    /// Gives a child with no share an equal share again (the Desktop coming back).
    func reviveShare(at index: Int) {
        guard ratios.indices.contains(index), ratios[index] < 0.01 else { return }
        let share = 1 / CGFloat(ratios.count)
        for i in ratios.indices where i != index { ratios[i] *= (1 - share) }
        ratios[index] = share
    }

    /// Moves the seam between child `index` and `index + 1` by `fraction` of the parent's length.
    func moveSeam(at index: Int, by fraction: CGFloat) {
        guard index >= 0, index + 1 < ratios.count else { return }
        let minShare: CGFloat = 0.08
        let delta = max(-(ratios[index] - minShare), min(ratios[index + 1] - minShare, fraction))
        ratios[index] += delta
        ratios[index + 1] -= delta
    }

    private func detachFromParent() {
        if let parent {
            _ = parent.remove(self)
        }
        parent = nil
    }
}
