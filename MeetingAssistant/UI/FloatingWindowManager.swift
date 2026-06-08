import Cocoa
import Carbon.HIToolbox

// MARK: - Floating Window Manager

final class FloatingWindowManager {
    static let shared = FloatingWindowManager()

    private var floatingWindow: FloatingWidgetWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // Settings
    var isEnabled = true
    var defaultOpacity: CGFloat = 0.95
    var defaultFontSize: CGFloat = 11

    private init() {
        setupGlobalHotKey()
    }

    deinit {
        removeHotKey()
    }

    // MARK: - Window Management

    func showFloatingWindow() {
        if floatingWindow == nil {
            createWindow()
        }
        floatingWindow?.show()
    }

    func hideFloatingWindow() {
        floatingWindow?.hide()
    }

    func toggleFloatingWindow() {
        if floatingWindow?.isVisible == true {
            hideFloatingWindow()
        } else {
            showFloatingWindow()
        }
    }

    func destroyWindow() {
        floatingWindow?.close()
        floatingWindow = nil
    }

    private func createWindow() {
        floatingWindow = FloatingWidgetWindow()
        floatingWindow?.updateSettings(
            opacity: defaultOpacity,
            fontSize: defaultFontSize
        )
        floatingWindow?.restorePosition()
    }

    // MARK: - Global Hot Key (Cmd+Shift+M)

    private func setupGlobalHotKey() {
        // Register for Cmd+Shift+M
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D544E47), id: 1)  // "MTNG"

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            FloatingWindowManager.shared.toggleFloatingWindow()
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        // Cmd+Shift+M
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_M)

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func removeHotKey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Settings

    func updateOpacity(_ opacity: CGFloat) {
        defaultOpacity = opacity
        floatingWindow?.updateSettings(opacity: opacity)
        UserDefaults.standard.set(Double(opacity), forKey: "floatingWindowOpacity")
    }

    func updateFontSize(_ size: CGFloat) {
        defaultFontSize = size
        floatingWindow?.updateSettings(fontSize: size)
        UserDefaults.standard.set(Double(size), forKey: "floatingWindowFontSize")
    }

    func loadSettings() {
        if let opacity = UserDefaults.standard.object(forKey: "floatingWindowOpacity") as? Double {
            defaultOpacity = CGFloat(opacity)
        }
        if let fontSize = UserDefaults.standard.object(forKey: "floatingWindowFontSize") as? Double {
            defaultFontSize = CGFloat(fontSize)
        }
    }
}

// MARK: - Floating Window Controller (Alternative Approach)

final class FloatingWidgetController: NSWindowController {
    convenience init() {
        let window = FloatingWidgetWindow()
        self.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        (window as? FloatingWidgetWindow)?.show()
    }

    func toggle() {
        (window as? FloatingWidgetWindow)?.toggle()
    }
}

// MARK: - Mini Floating View (Compact Alternative)

final class MiniFloatingWindow: NSPanel {
    private let viewModel = MiniFloatingViewModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContent()
    }

    private func setupWindow() {
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        alphaValue = 0.9
        hasShadow = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8

        contentView = visualEffect
    }

    private func setupContent() {
        let content = MiniFloatingContent(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        if let visualEffect = contentView as? NSVisualEffectView {
            visualEffect.addSubview(hostingView)

            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
            ])
        }
    }

    func show() {
        viewModel.startUpdating()

        // Position at bottom right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - frame.width - 20
            let y = screenFrame.minY + 20
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        orderFront(nil)
    }

    func hide() {
        viewModel.stopUpdating()
        orderOut(nil)
    }
}

// MARK: - Mini Floating View Model

import SwiftUI

@MainActor
final class MiniFloatingViewModel: ObservableObject {
    @Published var topPrediction: String = "Listening..."
    @Published var isCapturing = false

    private var timer: Timer?

    func startUpdating() {
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        isCapturing = MeetingCaptureManager.shared.isCapturing

        if let prediction = PredictionEngine.shared.getTopPredictions(count: 1).first {
            topPrediction = prediction.question
        } else {
            topPrediction = isCapturing ? "Analyzing..." : "Click to start"
        }
    }

    func toggleCapture() {
        Task {
            if isCapturing {
                await MeetingCaptureManager.shared.stopCapture()
                PredictionEngine.shared.stop()
            } else {
                try? await MeetingCaptureManager.shared.startCapture()
                PredictionEngine.shared.start()
            }
            refresh()
        }
    }
}

// MARK: - Mini Floating SwiftUI Content

struct MiniFloatingContent: View {
    @ObservedObject var viewModel: MiniFloatingViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(viewModel.isCapturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            // Prediction text
            Text(viewModel.topPrediction)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()

            // Toggle button
            Button(action: viewModel.toggleCapture) {
                Image(systemName: viewModel.isCapturing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
    }
}

// MARK: - Window Position Presets

enum FloatingWindowPosition: String, CaseIterable {
    case topRight = "Top Right"
    case topLeft = "Top Left"
    case bottomRight = "Bottom Right"
    case bottomLeft = "Bottom Left"
    case center = "Center"

    func point(for windowSize: NSSize, in screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let margin: CGFloat = 20

        switch self {
        case .topRight:
            return NSPoint(x: frame.maxX - windowSize.width - margin, y: frame.maxY - windowSize.height - margin)
        case .topLeft:
            return NSPoint(x: frame.minX + margin, y: frame.maxY - windowSize.height - margin)
        case .bottomRight:
            return NSPoint(x: frame.maxX - windowSize.width - margin, y: frame.minY + margin)
        case .bottomLeft:
            return NSPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .center:
            return NSPoint(
                x: frame.midX - windowSize.width / 2,
                y: frame.midY - windowSize.height / 2
            )
        }
    }
}

extension FloatingWidgetWindow {
    func moveToPosition(_ position: FloatingWindowPosition) {
        guard let screen = NSScreen.main else { return }
        let point = position.point(for: frame.size, in: screen)
        setFrameOrigin(point)
    }
}
