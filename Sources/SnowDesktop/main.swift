import AppKit
import MetalKit

final class App: NSObject, NSApplicationDelegate {
    private static let intensities = [("Flurries", 200), ("Snowfall", 420), ("Blizzard", 850)]
    private var window: NSWindow?
    private var renderer: Snow?
    private var view: MTKView?
    private var status: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var paused = false
    private let smokeTest = CommandLine.arguments.contains("--smoke-test")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let screen = NSScreen.screens.first else {
                throw CocoaError(.featureUnsupported)
            }
            let snow = try Snow(device: device)
            let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColorMake(0, 0, 0, 0)
            view.delegate = snow
            view.layer?.isOpaque = false
            view.isPaused = true

            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false, screen: nil)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.contentView = view
            self.window = window
            self.renderer = snow
            self.view = view
            installMenu()
            updateFrameRate()
            setPaused(false)

            let notifications = NotificationCenter.default
            notifications.addObserver(
                self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            notifications.addObserver(
                self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil
            )
            if smokeTest { runSmokeTest(snow, window: window) }
        } catch {
            if smokeTest {
                fputs("SnowDesktop startup failed: \(error)\n", stderr)
                exit(1)
            }
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let pause = menu.addItem(withTitle: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pauseItem = pause
        menu.addItem(.separator())

        let saved = UserDefaults.standard.integer(forKey: "snowIntensity")
        let count = Self.intensities.contains { $0.1 == saved } ? saved : 420
        renderer?.count = count
        for (index, preset) in Self.intensities.enumerated() {
            let option = menu.addItem(withTitle: preset.0, action: #selector(setIntensity(_:)),
                                      keyEquivalent: String(index + 1))
            option.target = self
            option.tag = preset.1
            option.state = preset.1 == count ? .on : .off
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Snowdrifts", action: #selector(clearSnow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SnowDesktop", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q").target = NSApp
        item.menu = menu
        status = item
    }

    @objc private func displayChanged() {
        guard let screen = NSScreen.screens.first else { return }
        window?.setFrame(screen.frame, display: !paused)
    }

    @objc private func powerChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateFrameRate() }
    }

    private func updateFrameRate() {
        view?.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
    }

    @objc private func setIntensity(_ sender: NSMenuItem) {
        renderer?.count = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: "snowIntensity")
        sender.menu?.items.filter { $0.action == #selector(setIntensity(_:)) }.forEach {
            $0.state = $0 === sender ? .on : .off
        }
    }

    @objc private func clearSnow() {
        renderer?.clearSnow()
    }

    @objc private func togglePause() {
        setPaused(!paused)
    }

    private func setPaused(_ paused: Bool) {
        guard let view, let window else { return }
        self.paused = paused
        renderer?.setActive(!paused)
        if paused {
            view.isPaused = true
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
            view.isPaused = false
        }
        pauseItem?.title = paused ? "Resume Snow" : "Pause Snow"
        let icon = paused ? "pause.circle" : "snowflake"
        status?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "SnowDesktop")
        status?.button?.toolTip = paused ? "SnowDesktop — Paused" : "SnowDesktop"
    }

    private static func p99(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.99)) - 1)
        return String(format: "%.2f", sorted[index])
    }

    private func runSmokeTest(_ snow: Snow, window: NSWindow) {
        let rear = CGRect(x: 10, y: 20, width: 100, height: 80)
        let front = CGRect(x: 40, y: 0, width: 30, height: 60)
        guard WindowEdge.visibleSpans(for: rear, behind: [front]) == [23..<40, 70..<97],
              window.ignoresMouseEvents, snow.verifySnowPhysics() else {
            fputs("Window geometry, click-through configuration, or snow physics failed\n", stderr)
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard snow.frames > 0, snow.scans > 0, window.isVisible else {
                fputs("Overlay did not render or scan\n", stderr)
                exit(1)
            }
            self.togglePause()
            let frames = snow.frames
            let scans = snow.scans
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard snow.frames == frames, snow.scans == scans, !window.isVisible else {
                    fputs("Overlay remained active on pause\n", stderr)
                    exit(1)
                }
                self.togglePause()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard snow.frames > frames, snow.scans > scans, window.isVisible, !snow.gpuMilliseconds.isEmpty else {
                        fputs("Overlay did not resume\n", stderr)
                        exit(1)
                    }
                    print("PASS: Metal rendered \(snow.frames) frames, window scans \(snow.scans), pause/resume, window spans, click-through configuration, cursor sweep and window shake")
                    print("Smoke p99, CPU frame preparation: \(Self.p99(snow.cpuMilliseconds)) ms, GPU command: \(Self.p99(snow.gpuMilliseconds)) ms")
                    exit(0)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
