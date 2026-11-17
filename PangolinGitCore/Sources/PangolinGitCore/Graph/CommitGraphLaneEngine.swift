import Foundation

/// Represents a single visual node and connecting lines in a Git commit DAG.
/// Equivalent to TortoiseGit's `lanes.cpp` lane allocation and graph rendering logic.
public struct CommitGraphLane: Sendable, Hashable {
    public enum LaneSegmentType: Sendable, Hashable {
        case vertical       // Continuing straight down |
        case fork           // Forking to the right \
        case merge          // Merging from the right /
        case cross          // Passing behind or through
    }
    
    public struct Segment: Sendable, Hashable {
        public let fromLane: Int
        public let toLane: Int
        public let type: LaneSegmentType
        
        public init(fromLane: Int, toLane: Int, type: LaneSegmentType) {
            self.fromLane = fromLane
            self.toLane = toLane
            self.type = type
        }
    }
    
    public let commitIndex: Int
    public let hash: GitHash
    public let nodeLane: Int
    public let activeLanesCount: Int
    public let segments: [Segment]
    
    public init(
        commitIndex: Int,
        hash: GitHash,
        nodeLane: Int,
        activeLanesCount: Int,
        segments: [Segment]
    ) {
        self.commitIndex = commitIndex
        self.hash = hash
        self.nodeLane = nodeLane
        self.activeLanesCount = activeLanesCount
        self.segments = segments
    }
}

/// Lane allocation engine for calculating topological graph tracks in Git commit history.
/// Directly ports and optimizes the lane routing algorithm from TortoiseGit's `src/TortoiseProc/lanes.cpp`.
public final class CommitGraphLaneEngine: Sendable {
    
    public init() {}
    
    /// Computes the graph tracks and lane segments for a topologically sorted list of revisions.
    public func computeLanes(revisions: [GitRevision]) -> [CommitGraphLane] {
        var result: [CommitGraphLane] = []
        var activeLanes: [GitHash?] = [] // index = lane number, value = next expected commit hash
        
        for (index, rev) in revisions.enumerated() {
            var segments: [CommitGraphLane.Segment] = []
            
            // 1. Find or assign node lane for this commit
            var nodeLane = -1
            if let existingLane = activeLanes.firstIndex(where: { $0 == rev.hash }) {
                nodeLane = existingLane
            } else {
                // Find first free slot or append
                if let freeSlot = activeLanes.firstIndex(where: { $0 == nil }) {
                    nodeLane = freeSlot
                    activeLanes[freeSlot] = rev.hash
                } else {
                    nodeLane = activeLanes.count
                    activeLanes.append(rev.hash)
                }
            }
            
            // 2. Clear this commit from its lane. Any other lanes that were also waiting for it
            //    (branches converging on a shared parent) merge into the node lane and end here.
            activeLanes[nodeLane] = nil
            for (laneIdx, pendingHash) in activeLanes.enumerated() where pendingHash == rev.hash {
                activeLanes[laneIdx] = nil
                segments.append(CommitGraphLane.Segment(fromLane: laneIdx, toLane: nodeLane, type: .merge))
            }
            
            // 3. Connect parents to lanes
            let parents = rev.parentHashes
            if let firstParent = parents.first {
                // First parent continues along the primary node lane
                activeLanes[nodeLane] = firstParent
                segments.append(CommitGraphLane.Segment(fromLane: nodeLane, toLane: nodeLane, type: .vertical))
                
                // Secondary parents (merge commits) fork into additional lanes
                for secondaryParent in parents.dropFirst() {
                    var targetLane = -1
                    if let existing = activeLanes.firstIndex(where: { $0 == secondaryParent }) {
                        targetLane = existing
                        segments.append(CommitGraphLane.Segment(fromLane: nodeLane, toLane: targetLane, type: .merge))
                    } else if let free = activeLanes.firstIndex(where: { $0 == nil }) {
                        targetLane = free
                        activeLanes[free] = secondaryParent
                        segments.append(CommitGraphLane.Segment(fromLane: nodeLane, toLane: targetLane, type: .fork))
                    } else {
                        targetLane = activeLanes.count
                        activeLanes.append(secondaryParent)
                        segments.append(CommitGraphLane.Segment(fromLane: nodeLane, toLane: targetLane, type: .fork))
                    }
                }
            }
            
            // 4. Record passing vertical lanes that are active across this row
            for (laneIdx, pendingHash) in activeLanes.enumerated() {
                if pendingHash != nil && laneIdx != nodeLane {
                    // Only add vertical segment if not already part of a fork/merge
                    if !segments.contains(where: { $0.toLane == laneIdx && $0.fromLane == nodeLane }) {
                        segments.append(CommitGraphLane.Segment(fromLane: laneIdx, toLane: laneIdx, type: .vertical))
                    }
                }
            }
            
            // Trim trailing empty lanes
            while activeLanes.last == nil && !activeLanes.isEmpty {
                activeLanes.removeLast()
            }
            
            result.append(CommitGraphLane(
                commitIndex: index,
                hash: rev.hash,
                nodeLane: nodeLane,
                activeLanesCount: max(activeLanes.count, nodeLane + 1),
                segments: segments
            ))
        }
        
        return result
    }
}
