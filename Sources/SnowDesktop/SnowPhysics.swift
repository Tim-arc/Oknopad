import CoreGraphics

enum SnowPhysics {
    static let gravity: CGFloat = 540
    static let fragmentLimit = 160

    static func edgeTaper(at x: CGFloat, in span: Range<CGFloat>) -> Float {
        let distance = min(x - span.lowerBound, span.upperBound - x)
        let width = min(17, (span.upperBound - span.lowerBound) / 2)
        guard width > 0 else { return 0 }
        let t = Float(max(0, min(1, distance / width)))
        return t * t * (3 - 2 * t)
    }

    static func releaseFraction(speed: CGFloat, threshold: CGFloat) -> Float {
        Float(max(0, min(0.8, (speed - threshold) / 1000)))
    }

    static func intersectsSweep(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared > 0 else { return false }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / distanceSquared))
        let x = point.x - (start.x + t * dx)
        let y = point.y - (start.y + t * dy)
        return x * x + y * y <= 15 * 15
    }

    struct Fragment {
        let source: CGWindowID
        var position: CGPoint
        var velocity: CGVector
        let radius: Float
        let mass: Float

        mutating func advance(_ dt: CGFloat) {
            position.x += velocity.dx * dt
            position.y += (velocity.dy + 0.5 * SnowPhysics.gravity * dt) * dt
            velocity.dy += SnowPhysics.gravity * dt
        }
    }
}
