import CoreGraphics

/// Pure geometry for display arrangement. No CoreGraphics display calls, so it can be
/// tested in isolation. Rects are in the global display space (points, y grows downward).
enum ArrangementLayout {
    /// Default distance (points) within which a dragged display aligns to another display's
    /// edge or center. Callers drawing a scaled-down canvas should pass a larger value.
    static let defaultAlignThreshold: CGFloat = 24
    /// Minimum shared edge length between neighbours (capped by the shorter edge).
    static let minContact: CGFloat = 32
    private static let epsilon: CGFloat = 0.5

    /// Where a display dropped at `proposed` should go: flush against an edge of one of
    /// `others`, overlapping none of them, with the whole arrangement still connected.
    /// Returns the valid spot closest to `proposed`, or nil if there is none.
    static func snap(_ proposed: CGRect, others: [CGRect],
                     alignThreshold: CGFloat = defaultAlignThreshold) -> CGRect? {
        guard !others.isEmpty else { return rounded(proposed) }
        var best: CGRect?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for other in others {
            for candidate in candidates(for: proposed, against: other, alignThreshold: alignThreshold) {
                guard !others.contains(where: { overlaps($0, candidate) }),
                      isConnected(others + [candidate]) else { continue }
                let distance = hypot(candidate.minX - proposed.minX, candidate.minY - proposed.minY)
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
        }
        return best
    }

    /// Shifts every frame so the frame for `mainID` sits at (0, 0).
    static func translated<Key: Hashable>(_ frames: [Key: CGRect], mainID: Key) -> [Key: CGRect] {
        guard let main = frames[mainID] else { return frames }
        let dx = -main.minX, dy = -main.minY
        return frames.mapValues { $0.offsetBy(dx: dx, dy: dy) }
    }

    /// Frames for `sizes` placed side by side (in the given order) directly above `anchor`,
    /// bottom edges on the anchor's top edge, centered on it as a group.
    static func rowAbove(_ anchor: CGRect, sizes: [CGSize]) -> [CGRect] {
        let totalWidth = sizes.reduce(0) { $0 + $1.width }
        var x = (anchor.midX - totalWidth / 2).rounded()
        return sizes.map { size in
            defer { x += size.width }
            return CGRect(x: x, y: anchor.minY - size.height, width: size.width, height: size.height)
        }
    }

    // MARK: - Helpers

    /// True when the two rects share interior area (touching edges don't count).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - epsilon && b.minX < a.maxX - epsilon &&
        a.minY < b.maxY - epsilon && b.minY < a.maxY - epsilon
    }

    /// True when the two rects touch along an edge segment of positive length.
    static func sharesEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        let verticalTouch = abs(a.maxX - b.minX) < epsilon || abs(b.maxX - a.minX) < epsilon
        let horizontalTouch = abs(a.maxY - b.minY) < epsilon || abs(b.maxY - a.minY) < epsilon
        let yOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let xOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return (verticalTouch && yOverlap > epsilon) || (horizontalTouch && xOverlap > epsilon)
    }

    /// True when every rect can be reached from the first through shared edges.
    static func isConnected(_ rects: [CGRect]) -> Bool {
        guard rects.count > 1 else { return true }
        var visited: Set<Int> = [0]
        var queue = [0]
        while let current = queue.popLast() {
            for i in rects.indices where !visited.contains(i) && sharesEdge(rects[current], rects[i]) {
                visited.insert(i)
                queue.append(i)
            }
        }
        return visited.count == rects.count
    }

    /// The four flush positions of `proposed` around `other`, keeping the free axis as close
    /// to the proposed value as the contact rule allows.
    private static func candidates(for proposed: CGRect, against other: CGRect,
                                   alignThreshold: CGFloat) -> [CGRect] {
        let w = proposed.width, h = proposed.height
        let y = freeAxis(proposed.minY, length: h, otherMin: other.minY, otherLength: other.height,
                         alignThreshold: alignThreshold)
        let x = freeAxis(proposed.minX, length: w, otherMin: other.minX, otherLength: other.width,
                         alignThreshold: alignThreshold)
        return [
            CGRect(x: other.maxX, y: y, width: w, height: h),      // right of other
            CGRect(x: other.minX - w, y: y, width: w, height: h),  // left of other
            CGRect(x: x, y: other.maxY, width: w, height: h),      // below other
            CGRect(x: x, y: other.minY - h, width: w, height: h),  // above other
        ].map(rounded)
    }

    /// Position along the shared edge: aligned to the other display's start, end or center
    /// when close, then clamped so the edges overlap by at least `minContact`.
    private static func freeAxis(_ value: CGFloat, length: CGFloat,
                                 otherMin: CGFloat, otherLength: CGFloat,
                                 alignThreshold: CGFloat) -> CGFloat {
        let alignments = [otherMin, otherMin + otherLength - length, otherMin + (otherLength - length) / 2]
        var result = value
        if let nearest = alignments.min(by: { abs($0 - value) < abs($1 - value) }),
           abs(nearest - value) <= alignThreshold {
            result = nearest
        }
        let contact = min(minContact, length, otherLength)
        let lower = otherMin - length + contact
        let upper = otherMin + otherLength - contact
        return min(max(result, lower), upper)
    }

    private static func rounded(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width, height: rect.height)
    }
}
