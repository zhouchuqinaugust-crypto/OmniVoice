import AppKit
import Foundation

public struct ClipboardStore {
    public init() {}

    public func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
