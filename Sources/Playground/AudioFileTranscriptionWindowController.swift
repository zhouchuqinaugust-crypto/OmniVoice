import AppCore
import AppKit
import Foundation

@MainActor
final class AudioFileTranscriptionWindowController: NSWindowController {
    typealias ExportHandler = @MainActor (URL, AudioFileTranscriptionExportOptions) async throws -> AudioFileTranscriptionExportResult

    private let exportHandler: ExportHandler
    private var inputFileURL: URL?
    private var outputFileURL: URL?
    private var activeTask: Task<Void, Never>?

    private let dropView = AudioFileDropView()
    private let inputPathField = NSTextField()
    private let outputPathField = NSTextField()
    private let diarizeButton = NSButton(checkboxWithTitle: "Try speaker labels", target: nil, action: nil)
    private let chunkSecondsField = NSTextField()
    private let exportButton = NSButton(title: "Export Transcript", target: nil, action: nil)
    private let chooseInputButton = NSButton(title: "Choose Audio…", target: nil, action: nil)
    private let chooseOutputButton = NSButton(title: "Choose Output…", target: nil, action: nil)
    private let openOutputButton = NSButton(title: "Open Output", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Drop a local audio file here, then export it to a text file.")
    private let progressIndicator = NSProgressIndicator()

    init(exportHandler: @escaping ExportHandler) {
        self.exportHandler = exportHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribe Audio File"
        window.center()

        super.init(window: window)
        buildInterface()
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        activeTask?.cancel()
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        dropView.onFileDropped = { [weak self] fileURL in
            self?.loadInput(fileURL)
        }

        inputPathField.isEditable = false
        inputPathField.placeholderString = "No file selected"
        inputPathField.lineBreakMode = .byTruncatingMiddle
        inputPathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        outputPathField.isEditable = false
        outputPathField.placeholderString = "Default: same folder, *.transcript.txt"
        outputPathField.lineBreakMode = .byTruncatingMiddle
        outputPathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        chunkSecondsField.stringValue = "900"
        chunkSecondsField.placeholderString = "900"
        chunkSecondsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        chooseInputButton.target = self
        chooseInputButton.action = #selector(chooseInputFile)

        chooseOutputButton.target = self
        chooseOutputButton.action = #selector(chooseOutputFile)

        exportButton.target = self
        exportButton.action = #selector(exportTranscript)
        exportButton.keyEquivalent = "\r"

        openOutputButton.target = self
        openOutputButton.action = #selector(openOutput)
        openOutputButton.isHidden = true

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let hint = helperLabel(
            "WAV works directly. m4a/mp3/mp4 use ffmpeg when available, otherwise macOS afconvert. Speaker labels are best-effort and need pyannote.audio plus a Hugging Face token."
        )

        let inputRow = viewRow(label: "Input", views: [inputPathField, chooseInputButton])
        let outputRow = viewRow(label: "Output", views: [outputPathField, chooseOutputButton])
        let chunkRow = viewRow(label: "Chunk seconds", views: [chunkSecondsField])
        let optionsRow = NSStackView(views: [diarizeButton, progressIndicator])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 12
        optionsRow.alignment = .centerY

        let actionRow = NSStackView(views: [exportButton, openOutputButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10

        let stack = NSStackView(views: [
            dropView,
            inputRow,
            outputRow,
            chunkRow,
            optionsRow,
            hint,
            statusLabel,
            actionRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dropView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropView.heightAnchor.constraint(equalToConstant: 150),
            inputPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            outputPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            chunkSecondsField.widthAnchor.constraint(equalToConstant: 90),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.contentView = container
    }

    private func viewRow(label: String, views: [NSView]) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.alignment = .right

        let valueStack = NSStackView(views: views)
        valueStack.orientation = .horizontal
        valueStack.spacing = 8
        valueStack.alignment = .centerY

        let grid = NSGridView(views: [[title, valueStack]])
        grid.rowSpacing = 8
        grid.columnSpacing = 14
        grid.xPlacement = .fill
        grid.column(at: 0).width = 120
        return grid
    }

    private func helperLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func loadInput(_ fileURL: URL) {
        inputFileURL = fileURL
        if outputFileURL == nil || outputPathField.stringValue.isEmpty {
            outputFileURL = defaultOutputFileURL(for: fileURL)
        }
        statusLabel.stringValue = "Ready to export: \(fileURL.lastPathComponent)"
        updateState()
    }

    private func defaultOutputFileURL(for inputFileURL: URL) -> URL {
        let fileName = inputFileURL.deletingPathExtension().lastPathComponent + ".transcript.txt"
        return inputFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    private func updateState() {
        inputPathField.stringValue = inputFileURL?.path ?? ""
        outputPathField.stringValue = outputFileURL?.path ?? ""
        let isExporting = activeTask != nil
        exportButton.isEnabled = inputFileURL != nil && !isExporting
        chooseInputButton.isEnabled = !isExporting
        chooseOutputButton.isEnabled = inputFileURL != nil && !isExporting
        diarizeButton.isEnabled = !isExporting
        chunkSecondsField.isEnabled = !isExporting

        if isExporting {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    @objc
    private func chooseInputFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a local audio file to transcribe."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        loadInput(url)
    }

    @objc
    private func chooseOutputFile() {
        guard let inputFileURL else {
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultOutputFileURL(for: inputFileURL).lastPathComponent
        panel.directoryURL = outputFileURL?.deletingLastPathComponent() ?? inputFileURL.deletingLastPathComponent()
        panel.prompt = "Use Output"
        panel.message = "Choose where to save the transcript text file."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        outputFileURL = url
        updateState()
    }

    @objc
    private func exportTranscript() {
        guard let inputFileURL else {
            return
        }

        let outputURL = outputFileURL ?? defaultOutputFileURL(for: inputFileURL)
        outputFileURL = outputURL

        guard let chunkSeconds = Int(chunkSecondsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              chunkSeconds > 0 else {
            statusLabel.stringValue = "Chunk seconds must be a positive integer."
            return
        }

        statusLabel.stringValue = "Exporting transcript. Large files can take a while."
        openOutputButton.isHidden = true

        let shouldDiarize = diarizeButton.state == .on
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await exportHandler(
                    inputFileURL,
                    AudioFileTranscriptionExportOptions(
                        outputFileURL: outputURL,
                        shouldDiarize: shouldDiarize,
                        chunkDurationSeconds: chunkSeconds,
                        progressHandler: { [weak self] message in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeTask != nil else {
                                    return
                                }
                                self.statusLabel.stringValue = message
                            }
                        }
                    )
                )

                await MainActor.run {
                    self.activeTask = nil
                    self.statusLabel.stringValue = self.successMessage(for: result)
                    self.openOutputButton.isHidden = false
                    self.updateState()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.activeTask = nil
                    self.statusLabel.stringValue = "Export cancelled."
                    self.updateState()
                }
            } catch {
                await MainActor.run {
                    self.activeTask = nil
                    self.statusLabel.stringValue = "Export failed: \(self.userFacingMessage(for: error))"
                    self.updateState()
                }
            }
        }

        activeTask = task
        updateState()
    }

    private func successMessage(for result: AudioFileTranscriptionExportResult) -> String {
        var message = "Exported \(result.segments.count) segments to \(result.outputFilePath)."
        if result.diarizationRequested && !result.diarizationPerformed {
            message += " Speaker labels were not available."
        }
        if !result.warnings.isEmpty {
            message += " Warning: \(result.warnings.joined(separator: " | "))"
        }
        return message
    }

    private func userFacingMessage(for error: Error) -> String {
        guard let sttError = error as? STTProviderError else {
            return error.localizedDescription
        }

        switch sttError {
        case .commandFailed(_, let output):
            if output.localizedCaseInsensitiveContains("afconvert") ||
                output.localizedCaseInsensitiveContains("ffmpeg") {
                return "This audio file could not be decoded locally. Try exporting it as WAV, or install ffmpeg and retry."
            }
            return "Local transcription failed. Try a smaller chunk size or a shorter file."
        case .missingMLXPythonPath, .missingMLXModel, .missingMLXRunnerScript:
            return "MLX file transcription is not fully configured. Check Settings and run Doctor."
        case .audioFileNotFound:
            return "The selected audio file no longer exists."
        default:
            return sttError.localizedDescription
        }
    }

    @objc
    private func openOutput() {
        guard let outputFileURL else {
            return
        }

        NSWorkspace.shared.open(outputFileURL)
    }
}

@MainActor
private final class AudioFileDropView: NSBox {
    var onFileDropped: ((URL) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Drop Audio File Here")
    private let subtitleLabel = NSTextField(labelWithString: "Supports WAV directly; m4a/mp3/mp4 via ffmpeg or afconvert")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 14
        borderWidth = 1
        borderColor = .separatorColor
        fillColor = .controlBackgroundColor
        contentViewMargins = NSSize(width: 20, height: 20)
        registerForDraggedTypes([.fileURL])

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView?.addSubview(stack)
        if let contentView {
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let fileURL = draggedFileURL(from: sender) else {
            return false
        }

        onFileDropped?(fileURL)
        return true
    }

    private func draggedFileURL(from sender: NSDraggingInfo) -> URL? {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]

        return objects?.first as URL?
    }
}
