import AppKit
import Foundation

public enum ContextSource: String, Sendable {
    case auto
    case selected
    case clipboard
    case screenshot
    case none
}

public enum ContextResolverError: LocalizedError, Sendable {
    case desktopDirectoryUnavailable
    case screenshotNotFound
    case clipboardEmpty
    case selectedTextUnavailable
    case automationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .desktopDirectoryUnavailable:
            return "Desktop directory is unavailable."
        case .screenshotNotFound:
            return "No recent screenshot was found."
        case .clipboardEmpty:
            return "Clipboard does not currently contain supported text or image content."
        case .selectedTextUnavailable:
            return "No selected text could be captured from the frontmost app."
        case .automationFailed(let output):
            return "Failed to capture selected text: \(output)"
        }
    }
}

public struct ContextResolver {
    private let fileManager: FileManager
    private let screenshotLookbackWindow: TimeInterval
    private let selectionCopyTimeout: TimeInterval

    public init(
        fileManager: FileManager = .default,
        screenshotLookbackWindow: TimeInterval = 120,
        selectionCopyTimeout: TimeInterval = 0.8
    ) {
        self.fileManager = fileManager
        self.screenshotLookbackWindow = screenshotLookbackWindow
        self.selectionCopyTimeout = selectionCopyTimeout
    }

    public func resolve(source: ContextSource) throws -> InputContext? {
        switch source {
        case .auto:
            return try resolveAutomaticContext()
        case .selected:
            return try resolveSelectedTextContext()
        case .clipboard:
            return try resolveClipboardContext()
        case .screenshot:
            return try resolveRecentScreenshotContext()
        case .none:
            return nil
        }
    }

    public func currentFrontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    public func resolveAutomaticContext() throws -> InputContext? {
        if let selectedText = try? resolveSelectedTextContext() {
            return selectedText
        }

        if let clipboard = try? resolveClipboardContext() {
            return clipboard
        }

        return buildEmptyContext()
    }

    public func resolveSelectedTextContext() throws -> InputContext {
        let sourceApp = currentFrontmostAppName()
        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot()
        let originalChangeCount = pasteboard.changeCount

        do {
            try triggerCopyShortcut()
            let copiedText = try waitForCopiedText(after: originalChangeCount)

            restorePasteboardSnapshot(snapshot)

            return InputContext(
                kind: .selectedText,
                sourceApp: sourceApp,
                payloadSummary: summarizeText(copiedText),
                textContent: copiedText
            )
        } catch {
            restorePasteboardSnapshot(snapshot)

            if let error = error as? ContextResolverError {
                throw error
            }

            throw ContextResolverError.selectedTextUnavailable
        }
    }

    public func resolveClipboardContext() throws -> InputContext {
        let pasteboard = NSPasteboard.general
        let sourceApp = currentFrontmostAppName()

        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return InputContext(
                kind: .clipboardText,
                sourceApp: sourceApp,
                payloadSummary: summarizeText(text),
                textContent: text
            )
        }

        if let imageDataURL = readClipboardImageDataURL() {
            return InputContext(
                kind: .clipboardImage,
                sourceApp: sourceApp,
                payloadSummary: "Clipboard image available for visual question answering.",
                imageDataURL: imageDataURL
            )
        }

        throw ContextResolverError.clipboardEmpty
    }

    public func resolveRecentScreenshotContext() throws -> InputContext {
        guard let desktopDirectory = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw ContextResolverError.desktopDirectoryUnavailable
        }

        let contents = try fileManager.contentsOfDirectory(
            at: desktopDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let screenshots = try contents
            .filter { isScreenshotURL($0) }
            .compactMap { url -> (URL, Date)? in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                    return nil
                }

                return (url, modifiedAt)
            }
            .sorted { $0.1 > $1.1 }

        guard let (latestURL, modifiedAt) = screenshots.first else {
            throw ContextResolverError.screenshotNotFound
        }

        guard Date().timeIntervalSince(modifiedAt) <= screenshotLookbackWindow else {
            throw ContextResolverError.screenshotNotFound
        }

        guard let imageDataURL = try makeImageDataURL(from: latestURL) else {
            throw ContextResolverError.screenshotNotFound
        }

        return InputContext(
            kind: .recentScreenshot,
            sourceApp: currentFrontmostAppName(),
            payloadSummary: "Recent screenshot: \(latestURL.lastPathComponent)",
            imageDataURL: imageDataURL
        )
    }

    private func buildEmptyContext() -> InputContext? {
        InputContext(
            kind: .plainText,
            sourceApp: currentFrontmostAppName(),
            payloadSummary: "No clipboard, selected text, or recent screenshot context detected."
        )
    }

    public func resolveInsertionTargetContext() -> InputContext {
        InputContext(
            kind: .plainText,
            sourceApp: currentFrontmostAppName(),
            payloadSummary: "Active insertion target."
        )
    }

    private func summarizeText(_ text: String, limit: Int = 160) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else {
            return flattened
        }

        let endIndex = flattened.index(flattened.startIndex, offsetBy: limit)
        return String(flattened[..<endIndex]) + "..."
    }

    private func readClipboardImageDataURL() -> String? {
        let pasteboard = NSPasteboard.general

        guard let availableType = pasteboard.types?.first(where: {
            $0 == .png || $0 == .tiff
        }),
        let data = pasteboard.data(forType: availableType) else {
            return nil
        }

        let mimeType = availableType == .png ? "image/png" : "image/tiff"
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func makeImageDataURL(from fileURL: URL) throws -> String? {
        let data = try Data(contentsOf: fileURL)
        let lowercasedExtension = fileURL.pathExtension.lowercased()
        let mimeType: String

        switch lowercasedExtension {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "heic":
            mimeType = "image/heic"
        default:
            mimeType = "application/octet-stream"
        }

        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func isScreenshotURL(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        let screenshotMarkers = [
            "screenshot",
            "screen shot",
            "屏幕快照",
        ]

        let supportedExtensions = ["png", "jpg", "jpeg", "heic"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }

        return screenshotMarkers.contains(where: { filename.contains($0) })
    }

    private func capturePasteboardSnapshot() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.map { item -> PasteboardItemSnapshot in
            let entries = item.types.compactMap { type -> (String, Data)? in
                guard let data = item.data(forType: type) else {
                    return nil
                }

                return (type.rawValue, data)
            }
            return PasteboardItemSnapshot(entries: entries)
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return
        }

        let items = snapshot.items.map { snapshot in
            let item = NSPasteboardItem()
            snapshot.entries.forEach { type, data in
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        pasteboard.writeObjects(items)
    }

    private func triggerCopyShortcut() throws {
        do {
            try SystemInputInjector.sendCommandC()
        } catch {
            throw ContextResolverError.automationFailed(error.localizedDescription)
        }
    }

    private func waitForCopiedText(after changeCount: Int) throws -> String {
        let deadline = Date().addingTimeInterval(selectionCopyTimeout)
        let pasteboard = NSPasteboard.general

        while Date() < deadline {
            if pasteboard.changeCount > changeCount,
               let text = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        throw ContextResolverError.selectedTextUnavailable
    }
}

private struct PasteboardSnapshot {
    let items: [PasteboardItemSnapshot]
}

private struct PasteboardItemSnapshot {
    let entries: [(String, Data)]
}
