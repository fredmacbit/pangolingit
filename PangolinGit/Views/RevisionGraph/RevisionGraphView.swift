import Foundation
import Cocoa
import PangolinGitCore

/// Draws the commit-graph column for one or more log rows using `CommitGraphLaneEngine` output.
/// Equivalent to the graph painting in TortoiseGit's `GitLogListBase.cpp` (`DrawGraph`).
public final class RevisionGraphView: NSView {

    public struct GraphRow {
        public let revision: GitRevision
        public let lane: CommitGraphLane
        /// True when the node's lane continues from the row above (i.e. a child commit is drawn above).
        public let hasIncomingEdge: Bool

        /// Builds graph rows for a topologically ordered history (newest first).
        public static func build(for revisions: [GitRevision]) -> [GraphRow] {
            let lanes = CommitGraphLaneEngine().computeLanes(revisions: revisions)
            var rows: [GraphRow] = []
            var lanesActiveBelowPrevious = Set<Int>()
            for (revision, lane) in zip(revisions, lanes) {
                rows.append(GraphRow(revision: revision, lane: lane,
                                     hasIncomingEdge: lanesActiveBelowPrevious.contains(lane.nodeLane)))
                lanesActiveBelowPrevious = lane.lanesActiveBelow
            }
            return rows
        }
    }

    public var rows: [GraphRow] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Height of one row; when the view hosts a single row it uses its own height instead.
    public var rowHeight: CGFloat = 26.0
    public var laneWidth: CGFloat = 14.0
    public var nodeRadius: CGFloat = 4.0

    private let laneColors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemPink, .systemTeal, .systemYellow, .systemIndigo
    ]

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        let maxLane = rows.map { $0.lane.activeLanesCount }.max() ?? 1
        return NSSize(width: max(CGFloat(maxLane) * laneWidth + 8, 40), height: CGFloat(rows.count) * rowHeight)
    }

    private func color(_ lane: Int) -> NSColor {
        laneColors[lane % laneColors.count]
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneWidth + laneWidth / 2 + 4
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, !rows.isEmpty else { return }
        let height = rows.count == 1 ? bounds.height : rowHeight
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)

        for (index, row) in rows.enumerated() {
            let top = CGFloat(index) * height
            let bottom = top + height
            let midY = top + height / 2
            let node = row.lane.nodeLane
            let nodePoint = CGPoint(x: x(node), y: midY)

            func stroke(_ lane: Int, _ build: (CGMutablePath) -> Void) {
                let path = CGMutablePath()
                build(path)
                ctx.addPath(path)
                ctx.setStrokeColor(color(lane).cgColor)
                ctx.strokePath()
            }

            if row.hasIncomingEdge {
                stroke(node) { $0.move(to: CGPoint(x: x(node), y: top)); $0.addLine(to: nodePoint) }
            }

            for segment in row.lane.segments {
                switch segment.type {
                case .vertical where segment.fromLane == node:
                    // First parent continues straight down.
                    stroke(node) { $0.move(to: nodePoint); $0.addLine(to: CGPoint(x: x(node), y: bottom)) }
                case .vertical, .cross:
                    // A lane passing through this row.
                    let lx = x(segment.fromLane)
                    stroke(segment.fromLane) { $0.move(to: CGPoint(x: lx, y: top)); $0.addLine(to: CGPoint(x: lx, y: bottom)) }
                case .fork, .merge:
                    if segment.fromLane == node {
                        // Edge from this commit down to another parent's lane.
                        let target = CGPoint(x: x(segment.toLane), y: bottom)
                        stroke(segment.toLane) {
                            $0.move(to: nodePoint)
                            $0.addCurve(to: target, control1: CGPoint(x: nodePoint.x, y: bottom),
                                        control2: CGPoint(x: target.x, y: midY))
                        }
                    } else {
                        // Another lane converging onto this commit from above.
                        let source = CGPoint(x: x(segment.fromLane), y: top)
                        stroke(segment.fromLane) {
                            $0.move(to: source)
                            $0.addCurve(to: nodePoint, control1: CGPoint(x: source.x, y: midY),
                                        control2: CGPoint(x: nodePoint.x, y: top))
                        }
                    }
                }
            }

            let circle = CGRect(x: nodePoint.x - nodeRadius, y: midY - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)
            ctx.setFillColor(row.revision.isMergeCommit ? NSColor.controlBackgroundColor.cgColor : color(node).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(color(node).cgColor)
            ctx.strokeEllipse(in: circle)
        }
    }
}

private extension CommitGraphLane {
    /// Lanes that carry an edge out of the bottom of this row.
    var lanesActiveBelow: Set<Int> {
        var lanes = Set<Int>()
        for segment in segments {
            switch segment.type {
            case .vertical, .cross:
                lanes.insert(segment.toLane)
            case .fork, .merge:
                if segment.fromLane == nodeLane { lanes.insert(segment.toLane) }
            }
        }
        return lanes
    }
}
