import AppCore
import AppKit
import Foundation

private enum DictionaryEditorError: LocalizedError {
    case targetMissing
    case spokenFormsMissing(String)

    var errorDescription: String? {
        switch self {
        case .targetMissing:
            return "Each dictionary entry must have a target term."
        case .spokenFormsMissing(let target):
            return "Dictionary entry '\(target)' must include at least one spoken form."
        }
    }
}

@MainActor
final class DictionaryEditorWindowController: NSWindowController {
    private let saveHandler: ([DictionaryEntry]) -> Void
    private let rowsStack = NSStackView()
    private var rowViews: [DictionaryEntryRowView] = []

    init(
        entries: [DictionaryEntry],
        saveHandler: @escaping ([DictionaryEntry]) -> Void
    ) {
        self.saveHandler = saveHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictionary"
        window.center()
        super.init(window: window)
        buildInterface()
        load(entries: entries)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(entries: [DictionaryEntry]) {
        clearRows()
        if entries.isEmpty {
            addRow()
            return
        }

        entries.forEach { addRow(entry: $0) }
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let helper = NSTextField(
            wrappingLabelWithString: "Use comma-separated spoken forms. These rules run after STT to normalize product names, mixed Chinese-English terminology, and brand casing."
        )
        helper.textColor = .secondaryLabelColor

        rowsStack.orientation = .vertical
        rowsStack.spacing = 10
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rowsStack

        let addButton = NSButton(title: "Add Entry", target: self, action: #selector(addEntry))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveEntries))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))

        let buttonRow = NSStackView(views: [addButton, saveButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        root.addArrangedSubview(helper)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(buttonRow)

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        window.contentView = container
    }

    @objc
    private func addEntry() {
        addRow()
    }

    @objc
    private func saveEntries() {
        do {
            let entries = try currentEntries()
            saveHandler(entries)
            close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Dictionary Error"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc
    private func cancelEditing() {
        close()
    }

    private func currentEntries() throws -> [DictionaryEntry] {
        let entries = try rowViews.compactMap { row -> DictionaryEntry? in
            let target = row.targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let spokenForms = row.spokenFormsField.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if target.isEmpty && spokenForms.isEmpty {
                return nil
            }

            guard !target.isEmpty else {
                throw DictionaryEditorError.targetMissing
            }

            guard !spokenForms.isEmpty else {
                throw DictionaryEditorError.spokenFormsMissing(target)
            }

            return DictionaryEntry(spokenForms: spokenForms, target: target)
        }

        return entries
    }

    private func addRow(entry: DictionaryEntry? = nil) {
        let row = DictionaryEntryRowView(entry: entry) { [weak self] row in
            self?.removeRow(row)
        }
        rowViews.append(row)
        rowsStack.addArrangedSubview(row)
    }

    private func removeRow(_ row: DictionaryEntryRowView) {
        rowViews.removeAll { $0 === row }
        rowsStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        if rowViews.isEmpty {
            addRow()
        }
    }

    private func clearRows() {
        rowViews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowViews.removeAll()
    }
}

@MainActor
private final class DictionaryEntryRowView: NSStackView {
    let targetField = NSTextField()
    let spokenFormsField = NSTextField()

    private let removeHandler: (DictionaryEntryRowView) -> Void

    init(entry: DictionaryEntry?, removeHandler: @escaping (DictionaryEntryRowView) -> Void) {
        self.removeHandler = removeHandler
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 10
        alignment = .centerY
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false

        targetField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        targetField.placeholderString = "Target term"
        targetField.stringValue = entry?.target ?? ""

        spokenFormsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        spokenFormsField.placeholderString = "spoken form 1, spoken form 2"
        spokenFormsField.stringValue = entry?.spokenForms.joined(separator: ", ") ?? ""

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelf))

        let targetColumn = labeledColumn(title: "Target", field: targetField, width: 220)
        let spokenFormsColumn = labeledColumn(title: "Spoken Forms", field: spokenFormsField, width: 420)

        addArrangedSubview(targetColumn)
        addArrangedSubview(spokenFormsColumn)
        addArrangedSubview(removeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func removeSelf() {
        removeHandler(self)
    }

    private func labeledColumn(title: String, field: NSTextField, width: CGFloat) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)

        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        return stack
    }
}
