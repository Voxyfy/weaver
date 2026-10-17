import AppKit

/// Saves each screen's tree and brings it back after a relaunch. Windows are matched by app
/// bundle id and title; what cannot be found is dropped, so a stale layout never traps anything.
enum Persistence {
    struct NodeRecord: Codable {
        var kind: String                 // window, split, desktop, tabs
        var axis: String?                // horizontal, vertical
        var ratios: [Double]?
        var children: [NodeRecord]?
        var windows: [WindowRecord]?     // one for a window leaf, several for tabs
        var active: Int?
    }

    struct WindowRecord: Codable {
        var bundle: String
        var title: String
    }

    struct SpaceRecord: Codable {
        var screen: Int
        var root: NodeRecord
        var desktopHidden: Bool
        var savedViews: [Int: [Int]]     // slot → index path from the root
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Weaver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }

    static func save(_ records: [SpaceRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> [SpaceRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([SpaceRecord].self, from: data) else { return [] }
        return records
    }

    // MARK: - Tree <-> record

    static func record(_ node: LayoutNode, windows: [CGWindowID: AXWindow]) -> NodeRecord {
        func win(_ id: CGWindowID) -> WindowRecord {
            let w = windows[id]
            let bundle = w.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier } ?? ""
            return WindowRecord(bundle: bundle, title: w?.title ?? "")
        }
        if let id = node.windowID { return NodeRecord(kind: "window", windows: [win(id)]) }
        if node.isDesktop { return NodeRecord(kind: "desktop") }
        if node.isTabs {
            let active = node.members.firstIndex { $0 == node.activeMember } ?? 0
            return NodeRecord(kind: "tabs", windows: node.members.map(win), active: active)
        }
        return NodeRecord(kind: "split", axis: node.axis == .horizontal ? "horizontal" : "vertical",
                          ratios: node.ratios.map(Double.init), children: node.children.map { record($0, windows: windows) })
    }

    /// Rebuilds a tree, taking windows from `available` (matched by bundle and title, then bundle
    /// alone) and removing each one it uses. Returns nil for a subtree with nothing left in it.
    static func rebuild(_ r: NodeRecord, available: inout [AXWindow], used: inout [CGWindowID: AXWindow]) -> LayoutNode? {
        func take(_ w: WindowRecord) -> AXWindow? {
            // Same app and same title only: grabbing "any window of that app" would rearrange
            // windows the user never docked.
            guard let i = available.firstIndex(where: { bundle(of: $0) == w.bundle && $0.title == w.title }) else { return nil }
            let window = available.remove(at: i)
            used[window.id] = window
            return window
        }
        switch r.kind {
        case "desktop":
            return LayoutNode(desktop: ())
        case "window":
            guard let w = r.windows?.first, let window = take(w) else { return nil }
            return LayoutNode(window: window.id)
        case "tabs":
            let found = (r.windows ?? []).compactMap(take)
            guard let first = found.first else { return nil }
            let node = LayoutNode(window: first.id)
            for w in found.dropFirst() { node.makeTabsOrAdd(w.id) }
            if node.isTabs, let active = r.active, found.indices.contains(active) { node.activeMember = found[active].id }
            return node
        default:
            var children: [LayoutNode] = []
            var ratios: [CGFloat] = []
            for (i, c) in (r.children ?? []).enumerated() {
                if let built = rebuild(c, available: &available, used: &used) {
                    children.append(built)
                    ratios.append(CGFloat(r.ratios?[safe: i] ?? 1))
                }
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            let total = ratios.reduce(0, +)
            return LayoutNode(axis: r.axis == "vertical" ? .vertical : .horizontal, children: children,
                              ratios: ratios.map { $0 / max(total, 0.0001) })
        }
    }

    private static func bundle(of w: AXWindow) -> String {
        NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? ""
    }

    /// Index path from the root to the node, for saved views.
    static func path(to node: LayoutNode) -> [Int] {
        var path: [Int] = []
        var n = node
        while let p = n.parent, let i = p.children.firstIndex(where: { $0 === n }) {
            path.insert(i, at: 0)
            n = p
        }
        return path
    }

    static func node(at path: [Int], in root: LayoutNode) -> LayoutNode? {
        var n = root
        for i in path {
            guard n.children.indices.contains(i) else { return nil }
            n = n.children[i]
        }
        return n
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
