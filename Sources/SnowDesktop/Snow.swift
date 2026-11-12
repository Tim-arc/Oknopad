import AppKit
import MetalKit
import QuartzCore

final class Snow: NSObject, MTKViewDelegate {
    private struct Particle {
        var x: Float
        var y: Float
        let depth: Float
        let speed: Float
        let radius: Float
        let opacity: Float
        let phase: Float
    }

    private struct Instance {
        let shape: SIMD4<Float>
        let detail: SIMD4<Float>
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let scanQueue = DispatchQueue(label: "dev.snowdesktop.windows", qos: .userInitiated)
    private let columns = 64
    private var particles: [Particle] = []
    private var instances: [Instance] = []
    private var edges: [WindowEdge] = []
    private var deposits: [CGWindowID: [Float]] = [:]
    private var fragments: [SnowPhysics.Fragment] = []
    private var previousPointer: CGPoint?
    private var previousSnapshot: CFTimeInterval?
    private var lastFrame: CFTimeInterval?
    private var lastScan: CFTimeInterval = -.infinity
    private var scanPending = false
    private var active = true
    private var elapsed: Float = 0
    private(set) var frames = 0
    private(set) var scans = 0
    private let measure = CommandLine.arguments.contains("--smoke-test")
    private(set) var cpuMilliseconds: [Double] = []
    private(set) var gpuMilliseconds: [Double] = []
    var count = 420

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        self.queue = queue
        let library = try device.makeLibrary(source: SnowArt.metalSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "snowVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "snowFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()

        particles = (0..<850).map { _ in
            let depth = powf(.random(in: 0...1), 2)
            return Particle(x: .random(in: 0...1), y: .random(in: 0...1), depth: depth,
                            speed: .random(in: 0.027...0.052) + 0.085 * depth,
                            radius: .random(in: 0.9...1.6) + 3.8 * depth,
                            opacity: .random(in: 0.32...0.60) + 0.29 * depth,
                            phase: .random(in: 0...(2 * .pi)))
        }
        instances.reserveCapacity(particles.count + 24 * columns + SnowPhysics.fragmentLimit)
        fragments.reserveCapacity(SnowPhysics.fragmentLimit)
    }

    func setActive(_ active: Bool) {
        self.active = active
        previousPointer = nil
        previousSnapshot = nil
        lastFrame = nil
        lastScan = -.infinity
    }

    func clearSnow() {
        deposits.removeAll(keepingCapacity: true)
        fragments.removeAll(keepingCapacity: true)
    }

    private func requestWindowScan(_ now: CFTimeInterval) {
        guard !scanPending, now - lastScan >= 1.0 / 15 else { return }
        lastScan = now
        scanPending = true
        scans += 1
        scanQueue.async { [weak self] in
            let snapshot = WindowEdge.capture()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanPending = false
                guard self.active, let snapshot else { return }
                self.applySnapshot(snapshot, at: now)
                // Keep hidden-window snow so covering or minimizing a window preserves it.
                // Trim the cache when old window IDs accumulate.
                if self.deposits.count > 96 {
                    let visible = Set(snapshot.map(\.id))
                    self.deposits = self.deposits.filter { visible.contains($0.key) }
                }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard active, let screen = view.window?.screen,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let now = CACurrentMediaTime()
        requestWindowScan(now)

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        frames += 1
        let dt = Float(min(now - (lastFrame ?? now), 0.05))
        lastFrame = now
        elapsed += dt
        let frame = CGDisplayBounds(CGMainDisplayID())
        let viewport = view.drawableSize
        let scale = Float(viewport.width / screen.frame.width)
        instances.removeAll(keepingCapacity: true)
        updateParticles(dt: dt, frame: frame, scale: scale)
        sweepSnow(dt: CGFloat(dt), screenTop: screen.frame.maxY)
        updateFragments(dt: CGFloat(dt), frame: frame, scale: scale)
        appendDrifts(frame: frame, scale: scale)

        encoder.setRenderPipelineState(pipeline)
        var size = SIMD2(Float(viewport.width), Float(viewport.height))
        encoder.setVertexBytes(&size, length: MemoryLayout.size(ofValue: size), index: 1)
        instances.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let strideBytes = MemoryLayout<Instance>.stride
            // Metal's inline buffer limit is 4 KiB per binding.
            let batch = 4096 / strideBytes
            for offset in stride(from: 0, to: buffer.count, by: batch) {
                let length = min(batch, buffer.count - offset)
                encoder.setVertexBytes(base.advanced(by: offset), length: length * strideBytes, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: length)
            }
        }
        encoder.endEncoding()
        command.present(drawable)
        if measure {
            cpuMilliseconds.append((CACurrentMediaTime() - now) * 1000)
            command.addCompletedHandler { [weak self] buffer in
                let duration = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                guard buffer.status == .completed, duration > 0 else { return }
                DispatchQueue.main.async { [weak self] in self?.gpuMilliseconds.append(duration) }
            }
        }
        command.commit()
    }

    private func updateParticles(dt: Float, frame: CGRect, scale: Float) {
        let wind = 0.016 + 0.012 * sinf(elapsed * 0.42)
        for index in 0..<count {
            var flake = particles[index]
            let previousY = flake.y
            let sway = sinf(elapsed * (0.7 + flake.depth) + flake.phase)
            flake.y += flake.speed * dt
            flake.x += (wind + sway * (0.009 + 0.020 * flake.depth)) * dt
            if flake.x < -0.02 { flake.x += 1.04 }
            if flake.x > 1.02 { flake.x -= 1.04 }

            let x = frame.minX + CGFloat(flake.x) * frame.width
            let oldY = frame.minY + CGFloat(previousY) * frame.height
            let y = frame.minY + CGFloat(flake.y) * frame.height

            if flake.y > 1.02 || land(x: x, previousY: oldY, y: y, frame: frame) {
                flake.y = -.random(in: 0.02...0.20)
                flake.x = .random(in: 0...1)
            }

            particles[index] = flake
            if flake.y >= -0.02 {
                let angle = flake.phase + 0.48 * sway
                instances.append(Instance(
                    shape: SIMD4(flake.x * 2 - 1, 1 - flake.y * 2, flake.radius * scale, flake.opacity),
                    detail: SIMD4(cosf(angle), sinf(angle), flake.depth, 0)
                ))
            }
        }
    }

    private func applySnapshot(_ snapshot: [WindowEdge], at now: CFTimeInterval) {
        defer {
            edges = snapshot
            previousSnapshot = now
        }
        guard !deposits.isEmpty, let previousSnapshot else { return }
        let dt = now - previousSnapshot
        guard dt > 0, dt < 0.24 else { return }
        for old in edges where deposits[old.id] != nil {
            guard let current = snapshot.first(where: { $0.id == old.id }),
                  current.bounds.size == old.bounds.size else { continue }
            let dx = current.bounds.minX - old.bounds.minX
            let dy = current.bounds.minY - old.bounds.minY
            let speed = hypot(dx, dy) / dt
            // Ignore discontinuous jumps between Spaces or display configurations.
            guard hypot(dx, dy) < 150 else { continue }
            let release = SnowPhysics.releaseFraction(speed: speed, threshold: 440)
            guard release > 0 else { continue }
            detach(from: old, fraction: release,
                   velocity: CGVector(dx: dx / dt * 0.24, dy: dy / dt * 0.15))
        }
    }

    private func sweepSnow(dt: CGFloat, screenTop: CGFloat) {
        guard !deposits.isEmpty else {
            previousPointer = nil
            return
        }
        let pointer = NSEvent.mouseLocation
        let current = CGPoint(x: pointer.x, y: screenTop - pointer.y)
        defer { previousPointer = current }
        guard let previousPointer, dt > 0 else { return }
        let dx = current.x - previousPointer.x
        let dy = current.y - previousPointer.y
        let distance = hypot(dx, dy)
        guard distance < 170 else { return }
        let fraction = SnowPhysics.releaseFraction(speed: distance / dt, threshold: 330)
        guard fraction > 0 else { return }
        for edge in edges where deposits[edge.id] != nil {
            let rect = edge.bounds
            guard rect.minY >= min(current.y, previousPointer.y) - 16,
                  rect.minY <= max(current.y, previousPointer.y) + 27,
                  rect.maxX >= min(current.x, previousPointer.x) - 16,
                  rect.minX <= max(current.x, previousPointer.x) + 16 else { continue }
            detach(from: edge, fraction: fraction, velocity: CGVector(dx: dx / dt * 0.26, dy: dy / dt * 0.16),
                   sweep: (previousPointer, current))
        }
    }

    private func detach(from edge: WindowEdge, fraction: Float, velocity: CGVector,
                        sweep: (CGPoint, CGPoint)? = nil) {
        guard fragments.count < SnowPhysics.fragmentLimit,
              var ridge = deposits[edge.id] else { return }
        let width = edge.bounds.width / CGFloat(columns)
        for index in ridge.indices where ridge[index] >= 0.25 {
            let x = edge.bounds.minX + (CGFloat(index) + 0.5) * width
            guard let span = edge.spans.first(where: { $0.contains(x) }) else { continue }
            let height = ridge[index] * SnowPhysics.edgeTaper(at: x, in: span)
            let origin = CGPoint(x: x, y: edge.bounds.minY - CGFloat(height) * 0.65)
            if let (start, end) = sweep, !SnowPhysics.intersectsSweep(origin, from: start, to: end) { continue }
            let removed = ridge[index] * fraction
            guard removed > 0.12 else { continue }
            ridge[index] -= removed
            fragments.append(SnowPhysics.Fragment(
                source: edge.id, position: origin,
                velocity: CGVector(dx: max(-360, min(360, velocity.dx)) + .random(in: -35...35),
                                   dy: max(-200, min(140, velocity.dy)) - .random(in: 25...90)),
                radius: min(4.5, 0.8 + removed * 0.50), mass: removed
            ))
            if fragments.count == SnowPhysics.fragmentLimit { break }
        }
        deposits[edge.id] = ridge
    }

    func verifySnowPhysics() -> Bool {
        let id = CGWindowID.max
        let rect = CGRect(x: 0, y: 80, width: 320, height: 150)
        let span: Range<CGFloat> = 13..<307
        let edge = WindowEdge(id: id, bounds: rect, spans: [span])
        deposits[id] = Array(repeating: 5, count: columns)
        defer { clearSnow() }
        let from = CGPoint(x: 100, y: 77)
        let to = CGPoint(x: 150, y: 77)
        detach(from: edge, fraction: 0.6, velocity: CGVector(dx: 140, dy: 0), sweep: (from, to))
        guard var fragment = fragments.first, let ridge = deposits[id],
              ridge[0] == 5, ridge[24] < 5, ridge[50] == 5,
              SnowPhysics.edgeTaper(at: 13, in: span) == 0,
              SnowPhysics.edgeTaper(at: 30, in: span) == 1,
              SnowPhysics.releaseFraction(speed: 100, threshold: 440) == 0 else { return false }
        let start = fragment.position
        fragment.advance(0.7)
        guard fragment.position.y > start.y, fragment.position.x > start.x else { return false }

        // Reuse the real window-motion path and ensure a fast move sheds more snow.
        let before = fragments.count
        edges = [edge]
        previousSnapshot = 1
        let moved = WindowEdge(id: id, bounds: rect.offsetBy(dx: 72, dy: 0), spans: [85..<379])
        applySnapshot([moved], at: 1.07)
        let released = fragments.count > before && fragments.count <= SnowPhysics.fragmentLimit
        edges.removeAll(keepingCapacity: true)
        previousSnapshot = nil
        return released
    }

    private func updateFragments(dt: CGFloat, frame: CGRect, scale: Float) {
        var surviving = 0
        for index in fragments.indices {
            var fragment = fragments[index]
            let previousY = fragment.position.y
            fragment.advance(dt)
            let point = fragment.position
            guard point.y <= frame.maxY + 12, point.x >= frame.minX - 16, point.x <= frame.maxX + 16,
                  !land(x: point.x, previousY: previousY, y: point.y, frame: frame,
                        mass: fragment.mass, excluding: fragment.source) else { continue }
            fragments[surviving] = fragment
            surviving += 1
            instances.append(Instance(
                shape: SIMD4(Float((point.x - frame.minX) / frame.width) * 2 - 1,
                             1 - Float((point.y - frame.minY) / frame.height) * 2,
                             fragment.radius * scale, 0.90),
                detail: SIMD4(1, 0, 0, 0)
            ))
        }
        fragments.removeLast(fragments.count - surviving)
    }

    private func land(x: CGFloat, previousY: CGFloat, y: CGFloat, frame: CGRect,
                      mass: Float = 0.85, excluding source: CGWindowID? = nil) -> Bool {
        guard y > previousY, frame.minX <= x, x < frame.maxX else { return false }
        for edge in edges {
            let top = edge.bounds.minY
            if top > y + 10 { break }
            guard edge.id != source, top >= frame.minY, top < frame.maxY,
                  previousY < top, let span = edge.spans.first(where: { $0.contains(x) }) else { continue }
            let position = (x - edge.bounds.minX) / edge.bounds.width
            let index = min(columns - 1, Int(position * CGFloat(columns)))
            let previousHeight = deposits[edge.id]?[index] ?? 0
            let surface = top - CGFloat(previousHeight * SnowPhysics.edgeTaper(at: x, in: span))
            guard previousY < surface, y >= surface else { continue }
            deposits[edge.id, default: Array(repeating: 0, count: columns)][index] = min(10, previousHeight + mass)
            return true
        }
        return false
    }

    private func appendDrifts(frame: CGRect, scale: Float) {
        for edge in edges {
            let rect = edge.bounds
            guard rect.minY >= frame.minY, rect.minY < frame.maxY,
                  let ridge = deposits[edge.id] else { continue }
            let width = rect.width / CGFloat(columns)
            let base = 1 - Float((rect.minY + 0.6 - frame.minY) / frame.height) * 2
            var leftHeight: Float = 0
            for index in 0..<columns {
                let next = index + 1
                let rightHeight = next == columns ? 0 : 0.5 * (ridge[index] + ridge[next])
                if max(leftHeight, rightHeight) > 0.1 {
                    let left = rect.minX + CGFloat(index) * width
                    let right = left + width
                    for span in edge.spans {
                        let start = max(left, span.lowerBound, frame.minX)
                        let end = min(right, span.upperBound, frame.maxX)
                        guard start < end else { continue }
                        let startHeight = (leftHeight + (rightHeight - leftHeight) * Float((start - left) / width))
                            * SnowPhysics.edgeTaper(at: start, in: span)
                        let endHeight = (leftHeight + (rightHeight - leftHeight) * Float((end - left) / width))
                            * SnowPhysics.edgeTaper(at: end, in: span)
                        guard max(startHeight, endHeight) > 0.1 else { continue }
                        let center = (start + end) / 2
                        instances.append(Instance(
                            shape: SIMD4(Float((center - frame.minX) / frame.width) * 2 - 1,
                                         base, -Float(end - start) * scale / 2, 0.95),
                            detail: SIMD4(startHeight * scale, endHeight * scale, 1.2 * scale, 0)
                        ))
                    }
                }
                leftHeight = rightHeight
            }
        }
    }
}
