import AppCore
import AppKit
import Foundation

@MainActor
final class HistoryWindowController: NSWindowController {
    private let refreshHandler: () -> [HistoryEvent]
    private let copyHandler: (String) -> Void
    private let insertHandler: (String) -> Void

    private let rowsStack = NSStackView()

    init(
        events: [HistoryEvent],
        refreshHandler: @escaping () -> [HistoryEvent],
        copyHandler: @escaping (String) -> Void,
        insertHandler: @escaping (String) -> Void
    ) {
        self.refreshHandler = refreshHandler
        self.copyHandler = copyHandler
        self.insertHandler = insertHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.center()
        super.init(window: window)
        buildInterface()
        load(events: events)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(events: [HistoryEvent]) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if events.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No transcript or Ask history has been recorded yet.")
            empty.textColor = .secondaryLabelColor
            rowsStack.addArrangedSubview(empty)
            return
        }

        for event in events.reversed() {
            rowsStack.addArrangedSubview(historyCard(for: event))
        }
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        rowsStack.orientation = .vertical
        rowsStack.spacing = 12
        rowsStack.alignment = .leading

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = rowsStack

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let header = NSStackView(views: [refreshButton])
        header.orientation = .horizontal

        let root = NSStackView(views: [header, scrollView])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])

        window.contentView = container
    }

    @objc
    private func refresh() {
        load(events: refreshHandler())
    }

    private func historyCard(for event: HistoryEvent) -> NSView {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        let title = NSTextField(labelWithString: event.kind == .ask ? "Ask Anything" : "Dictation")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let meta = NSTextField(labelWithString: formatter.string(from: event.createdAt))
        meta.textColor = .secondaryLabelColor
        meta.font = .systemFont(ofSize: 11)

        let bodyText: String
        switch event.kind {
        case .ask:
            let prompt = event.prompt ?? "(no prompt)"
            let answer = event.answer ?? "(no answer)"
            bodyText = "Prompt: \(prompt)\nAnswer: \(answer)"
        case .transcript:
            bodyText = event.transcript ?? "(no transcript)"
        }

        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.maximumNumberOfLines = 0

        let buttons = buttonsRow(for: event)

        let stack = NSStackView(views: [title, meta, body, buttons])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading

        let container = NSBox()
        container.titlePosition = .noTitle
        container.boxType = .custom
        container.cornerRadius = 10
        container.borderColor = .separatorColor
        container.fillColor = .controlBackgroundColor
        container.contentViewMargins = NSSize(width: 14, height: 14)
        container.contentView = stack
        return container
    }

    private func buttonsRow(for event: HistoryEvent) -> NSView {
        let copyButton = NSButton(title: "Copy", target: nil, action: nil)
        copyButton.action = #selector(copyContent(_:))
        copyButton.target = self
        copyButton.identifier = NSUserInterfaceItemIdentifier(event.id.uuidString)

        let insertButton = NSButton(title: "Insert", target: nil, action: nil)
        insertButton.action = #selector(insertContent(_:))
        insertButton.target = self
        insertButton.identifier = NSUserInterfaceItemIdentifier(event.id.uuidString)

        let hasContent = content(for: event) != nil
        copyButton.isEnabled = hasContent
        insertButton.isEnabled = hasContent

        let row = NSStackView(views: [copyButton, insertButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    @objc
    private func copyContent(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let event = refreshHandler().first(where: { $0.id.uuidString == identifier }),
              let content = content(for: event) else {
            return
        }

        copyHandler(content)
    }

    @objc
    private func insertContent(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let event = refreshHandler().first(where: { $0.id.uuidString == identifier }),
              let content = content(for: event) else {
            return
        }

        insertHandler(content)
    }

    private func content(for event: HistoryEvent) -> String? {
        switch event.kind {
        case .ask:
            return event.answer
        case .transcript:
            return event.transcript
        }
    }
}
