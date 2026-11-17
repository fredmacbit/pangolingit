import Cocoa
import PangolinGitCore

/// Draws the Revision Graph: one box per node listing its refs, coloured by ref type like
/// TortoiseGit's `RevisionGraphWnd` (local branch, remote branch, tag, HEAD, stash), with edges to
/// the nearest shown ancestors. Zoom comes from the enclosing scroll view's magnification.
@MainActor
final class RevisionGraphCanvasView: NSView, NSViewToolTipOwner {

    struct Placed {
        let node: RevisionGraphNode
        let frame: NSRect
    }

    private(set) var placed: [Placed] = []
    private var frameByHash: [String: NSRect] = [:]
    /// Selected node hashes, in click order (two selected nodes can be compared).
    private(set) var selection: [String] = [] {
        didSet { needsDisplay = true; onSelectionChange?() }
    }
    /// Hashes matching the Find field.
    var highlighted: Set<String> = [] {
        didSet { needsDisplay = true }
    }
    var onSelectionChange: (() -> Void)?
    var onDoubleClick: ((RevisionGraphNode) -> Void)?
    /// Context menu for the selected nodes.
    var menuProvider: (([RevisionGraphNode]) -> NSMenu?)?
    /// TortoiseGit's *Arrows point upwards* toggle: draw newest at the bottom instead of the top.
    var newestAtBottom = false {
        didSet { relayout() }
    }

    private var nodes: [RevisionGraphNode] = []
    private let boxWidth: CGFloat = 200
    private let laneGap: CGFloat = 48
    private let rowGap: CGFloat = 26
    private let lineHeight: CGFloat = 15
    private let margin: CGFloat = 24

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setNodes(_ nodes: [RevisionGraphNode]) {
        let previous = Set(selection)
        self.nodes = nodes
        selection = nodes.map(\.commit.hash).filter { previous.contains($0) }
        relayout()
    }

    var selectedNodes: [RevisionGraphNode] {
        selection.compactMap { hash in nodes.first { $0.commit.hash == hash } }
    }

    func select(_ hash: String) {
        selection = [hash]
        if let frame = frameByHash[hash] {
            scrollToVisible(frame.insetBy(dx: -40, dy: -40))
        }
    }

    private func height(for node: RevisionGraphNode) -> CGFloat {
        let refLines = max(node.commit.refs.count, node.commit.refs.isEmpty ? 0 : 1)
        return CGFloat(refLines + 1) * lineHeight + 10
    }

    private func relayout() {
        var rowHeights: [Int: CGFloat] = [:]
        for node in nodes {
            rowHeights[node.row] = max(rowHeights[node.row] ?? 0, height(for: node))
        }
        let rows = nodes.map(\.row).max().map { $0 + 1 } ?? 0
        let order = newestAtBottom ? Array((0..<rows).reversed()) : Array(0..<rows)
        var rowTop: [Int: CGFloat] = [:]
        var y = margin
        for row in order {
            rowTop[row] = y
            y += (rowHeights[row] ?? 0) + rowGap
        }
        placed = nodes.map { node in
            let x = margin + CGFloat(node.lane) * (boxWidth + laneGap)
            return Placed(node: node, frame: NSRect(x: x, y: rowTop[node.row] ?? 0, width: boxWidth, height: height(for: node)))
        }
        frameByHash = Dictionary(placed.map { ($0.node.commit.hash, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let width = (placed.map(\.frame.maxX).max() ?? 0) + margin
        setFrameSize(NSSize(width: max(width, 400), height: max(y + margin, 300)))
        removeAllToolTips()
        for item in placed {
            addToolTip(item.frame, owner: self, userData: nil)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        // Edges first so the boxes sit on top.
        NSColor.secondaryLabelColor.setStroke()
        for item in placed {
            for parent in item.node.commit.parents {
                guard let target = frameByHash[parent] else { continue }
                drawEdge(from: item.frame, to: target)
            }
        }
        for item in placed where item.frame.intersects(dirtyRect.insetBy(dx: -20, dy: -20)) {
            drawNode(item)
        }
    }

    private func drawEdge(from child: NSRect, to parent: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        let childBelow = child.midY > parent.midY
        let start = NSPoint(x: child.midX, y: childBelow ? child.minY : child.maxY)
        let end = NSPoint(x: parent.midX, y: childBelow ? parent.maxY : parent.minY)
        path.move(to: start)
        if abs(start.x - end.x) < 1 {
            path.line(to: end)
        } else {
            let middle = (start.y + end.y) / 2
            path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: middle), controlPoint2: NSPoint(x: end.x, y: middle))
        }
        path.stroke()
        // Arrow head pointing at the parent, as in TortoiseGit.
        let direction: CGFloat = childBelow ? -1 : 1
        let arrow = NSBezierPath()
        arrow.move(to: end)
        arrow.line(to: NSPoint(x: end.x - 4, y: end.y - 7 * direction))
        arrow.line(to: NSPoint(x: end.x + 4, y: end.y - 7 * direction))
        arrow.close()
        NSColor.secondaryLabelColor.setFill()
        arrow.fill()
    }

    static func colour(for kind: RevisionGraphRef.Kind?) -> NSColor {
        switch kind {
        case .head: return .systemRed
        case .localBranch: return .systemGreen
        case .remoteBranch: return .systemOrange
        case .tag: return .systemYellow
        case .stash: return .systemGray
        case .notes: return .systemPurple
        case .other: return .systemTeal
        case nil: return .tertiaryLabelColor
        }
    }

    private func drawNode(_ item: Placed) {
        let commit = item.node.commit
        let isSelected = selection.contains(commit.hash)
        let isCurrent = commit.refs.contains { $0.isCurrent }
        let colour = Self.colour(for: commit.refs.first?.kind)

        let box = NSBezierPath(roundedRect: item.frame, xRadius: 6, yRadius: 6)
        colour.withAlphaComponent(commit.refs.isEmpty ? 0.08 : 0.22).setFill()
        box.fill()
        box.lineWidth = isSelected ? 3 : (isCurrent ? 2.5 : 1)
        (isSelected ? NSColor.controlAccentColor : (isCurrent ? NSColor.systemRed : colour)).setStroke()
        box.stroke()
        if highlighted.contains(commit.hash) {
            let ring = NSBezierPath(roundedRect: item.frame.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.systemPink.setStroke()
            ring.stroke()
        }

        var y = item.frame.minY + 5
        let x = item.frame.minX + 8
        let width = item.frame.width - 16
        for ref in commit.refs {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: ref.isCurrent ? .bold : .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            let prefix = ref.kind == .tag ? "🏷 " : (ref.isCurrent ? "➤ " : "")
            (prefix + ref.shortName as NSString).draw(with: NSRect(x: x, y: y, width: width, height: lineHeight),
                                                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes)
            y += lineHeight
        }
        let detail = "\(String(commit.hash.prefix(8)))  \(commit.subject)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (detail as NSString).draw(with: NSRect(x: x, y: y, width: width, height: lineHeight),
                                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes)
    }

    // MARK: - Interaction

    private func node(at point: NSPoint) -> RevisionGraphNode? {
        placed.first { $0.frame.contains(point) }?.node
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = node(at: point) else {
            selection = []
            return
        }
        if event.clickCount == 2 {
            onDoubleClick?(hit)
            return
        }
        let hash = hit.commit.hash
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            // TortoiseGit compares two selected nodes; keep at most the last two.
            if let index = selection.firstIndex(of: hash) {
                selection.remove(at: index)
            } else {
                selection = Array((selection + [hash]).suffix(2))
            }
        } else {
            selection = [hash]
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = node(at: point) else { return nil }
        if !selection.contains(hit.commit.hash) {
            selection = [hit.commit.hash]
        }
        return menuProvider?(selectedNodes)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let node = node(at: point) else { return "" }
        let commit = node.commit
        let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: commit.timestamp), dateStyle: .medium, timeStyle: .short)
        var lines = [commit.hash, "\(commit.author) — \(date)", commit.subject]
        if !commit.refs.isEmpty {
            lines.append(commit.refs.map(\.fullName).joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Export

    func pngData() -> Data? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func pdfData() -> Data {
        dataWithPDF(inside: bounds)
    }
}
