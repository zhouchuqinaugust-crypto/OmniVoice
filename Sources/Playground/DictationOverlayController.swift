import AppKit
import Foundation

@MainActor
final class DictationOverlayController {
    private enum OverlayMode {
        case recording
        case message

        var panelSize: NSSize {
            switch self {
            case .recording:
                return NSSize(width: 228, height: 76)
            case .message:
                return NSSize(width: 276, height: 92)
            }
        }
    }

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let waveformView = RecordingScopeView(frame: .zero)
    private let messageStack: NSStackView
    private var mode: OverlayMode = .message
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var onCancel: (() -> Void)?
    private var autoHideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayMode.message.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let visualEffectView = NSVisualEffectView()
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.alignment = .center
        hintLabel.textColor = .tertiaryLabelColor

        messageStack = NSStackView(views: [titleLabel, detailLabel, hintLabel])
        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 10
        messageStack.translatesAutoresizingMaskIntoConstraints = false

        waveformView.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(messageStack)
        visualEffectView.addSubview(waveformView)

        let contentView = NSView()
        contentView.addSubview(visualEffectView)

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            messageStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 16),
            messageStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -16),
            messageStack.centerYAnchor.constraint(equalTo: visualEffectView.centerYAnchor),

            waveformView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 18),
            waveformView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -18),
            waveformView.centerYAnchor.constraint(equalTo: visualEffectView.centerYAnchor),
            waveformView.heightAnchor.constraint(equalToConstant: 38),
        ])

        panel.contentView = contentView
        apply(mode: .message)
    }

    func showRecording(cancelHandler: @escaping () -> Void) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        waveformView.reset()
        show(mode: .recording, cancelHandler: cancelHandler)
    }

    func updateRecordingLevel(_ level: Float) {
        guard mode == .recording else {
            return
        }
        waveformView.push(level: CGFloat(level))
    }

    func showTranscribing(cancelHandler: @escaping () -> Void) {
        show(
            title: "Transcribing…",
            detail: "Processing locally…",
            hint: "Esc to cancel",
            cancelHandler: cancelHandler
        )
    }

    func showCancelled(_ detail: String = "Cancelled") {
        show(title: "Cancelled", detail: detail, hint: "", cancelHandler: nil)
        autoHide(after: 1.2)
    }

    func showError(_ detail: String) {
        show(title: "Dictation Failed", detail: detail, hint: "", cancelHandler: nil)
        autoHide(after: 2.5)
    }

    func hide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        uninstallEscapeMonitor()
        onCancel = nil
        waveformView.reset()
        panel.orderOut(nil)
    }

    private func show(
        title: String,
        detail: String,
        hint: String,
        cancelHandler: (() -> Void)?
    ) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        hintLabel.stringValue = hint
        show(mode: .message, cancelHandler: cancelHandler)
    }

    private func show(mode: OverlayMode, cancelHandler: (() -> Void)?) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        onCancel = cancelHandler
        apply(mode: mode)
        layoutPanel(for: mode)
        if cancelHandler != nil {
            installEscapeMonitor()
        } else {
            uninstallEscapeMonitor()
        }
        panel.orderFrontRegardless()
    }

    private func apply(mode: OverlayMode) {
        self.mode = mode
        waveformView.isHidden = mode != .recording
        messageStack.isHidden = mode != .message
        panel.setContentSize(mode.panelSize)
    }

    private func autoHide(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hide()
            }
        }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func layoutPanel(for mode: OverlayMode) {
        let size = mode.panelSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + max(110, visibleFrame.height * 0.14)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installEscapeMonitor() {
        guard localMonitor == nil, globalMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else {
                return event
            }
            self.handleEscape()
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else {
                return
            }
            Task { @MainActor in
                self.handleEscape()
            }
        }
    }

    private func uninstallEscapeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handleEscape() {
        guard let onCancel else {
            return
        }
        self.onCancel = nil
        onCancel()
    }
}

private final class RecordingScopeView: NSView {
    private let sampleCount = 40
    private let baselineLevel: CGFloat = 0.0
    private let minimumVisibleOffset: CGFloat = 0.7

    private var samples: [CGFloat]

    override init(frame frameRect: NSRect) {
        self.samples = Array(repeating: baselineLevel, count: sampleCount)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        samples = Array(repeating: baselineLevel, count: sampleCount)
        needsDisplay = true
    }

    func push(level: CGFloat) {
        let clamped = max(0, min(1, level))
        let previous = samples.last ?? baselineLevel
        let smoothed = max(baselineLevel, previous * 0.22 + clamped * 0.78)
        samples.append(smoothed)
        if samples.count > sampleCount {
            samples.removeFirst(samples.count - sampleCount)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        let midY = bounds.midY
        let amplitude = bounds.height * 0.38
        let step = bounds.width / CGFloat(max(samples.count - 1, 1))

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: bounds.minX, y: midY))
        baseline.line(to: NSPoint(x: bounds.maxX, y: midY))
        baseline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.08).setStroke()
        baseline.stroke()

        let path = NSBezierPath()
        path.lineWidth = 2.1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var lowerPoints: [NSPoint] = []

        for (index, sample) in samples.enumerated() {
            let x = bounds.minX + CGFloat(index) * step
            let shapedLevel = pow(max(0, sample), 0.82)
            let offset = max(minimumVisibleOffset, shapedLevel * amplitude)
            let upperPoint = NSPoint(x: x, y: midY + offset)
            let lowerPoint = NSPoint(x: x, y: midY - offset)
            if index == 0 {
                path.move(to: upperPoint)
            } else {
                path.line(to: upperPoint)
            }
            lowerPoints.append(lowerPoint)
        }

        for point in lowerPoints.reversed() {
            path.line(to: point)
        }
        path.close()

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setShadow(offset: .zero, blur: 10, color: NSColor.systemMint.withAlphaComponent(0.22).cgColor)
        }
        NSColor.systemMint.withAlphaComponent(0.22).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let outline = NSBezierPath()
        outline.lineWidth = 1.8
        outline.lineCapStyle = .round
        outline.lineJoinStyle = .round

        for (index, sample) in samples.enumerated() {
            let x = bounds.minX + CGFloat(index) * step
            let shapedLevel = pow(max(0, sample), 0.82)
            let offset = max(minimumVisibleOffset, shapedLevel * amplitude)
            let point = NSPoint(x: x, y: midY + offset)
            if index == 0 {
                outline.move(to: point)
            } else {
                outline.line(to: point)
            }
        }

        NSColor.systemMint.withAlphaComponent(0.92).setStroke()
        outline.stroke()

        let lowerOutline = NSBezierPath()
        lowerOutline.lineWidth = 1.8
        lowerOutline.lineCapStyle = .round
        lowerOutline.lineJoinStyle = .round

        for (index, sample) in samples.enumerated() {
            let x = bounds.minX + CGFloat(index) * step
            let shapedLevel = pow(max(0, sample), 0.82)
            let offset = max(minimumVisibleOffset, shapedLevel * amplitude)
            let point = NSPoint(x: x, y: midY - offset)
            if index == 0 {
                lowerOutline.move(to: point)
            } else {
                lowerOutline.line(to: point)
            }
        }

        NSColor.systemMint.withAlphaComponent(0.78).setStroke()
        lowerOutline.stroke()
    }
}
