import CoreGraphics
import Foundation

struct WindowEdge {
    let id: CGWindowID
    let bounds: CGRect
    let spans: [Range<CGFloat>]

    static func capture() -> [WindowEdge]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var occluders: [CGRect] = []
        var edges: [WindowEdge] = []

        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !rect.isEmpty else { continue }

            if rect.width >= 100, rect.height >= 80 {
                let spans = visibleSpans(for: rect, behind: occluders)
                if !spans.isEmpty {
                    edges.append(WindowEdge(id: id, bounds: rect, spans: spans))
                }
            }
            if edges.count == 24 { break }
            occluders.append(rect)
        }
        return edges.sorted { $0.bounds.minY < $1.bounds.minY }
    }

    static func visibleSpans(for rect: CGRect, behind occluders: [CGRect]) -> [Range<CGFloat>] {
        let inset = min(13, rect.width / 4)
        var spans = [(rect.minX + inset)..<(rect.maxX - inset)]
        for front in occluders where front.minY <= rect.minY && front.maxY > rect.minY {
            spans = spans.flatMap { span -> [Range<CGFloat>] in
                guard span.lowerBound < front.maxX, span.upperBound > front.minX else { return [span] }
                var visible: [Range<CGFloat>] = []
                if span.lowerBound < front.minX { visible.append(span.lowerBound..<front.minX) }
                if front.maxX < span.upperBound { visible.append(front.maxX..<span.upperBound) }
                return visible
            }
            if spans.isEmpty { break }
        }
        return spans
    }
}
