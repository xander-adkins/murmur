import AppKit
import Foundation

/// Puts a transcript into the focused app and optionally presses Return to send it.
/// Reads no settings: the effect it executes carries the whole decision.
final class TextInserter {
    /// Bumped per insertion so a previous take's delayed clipboard restore cannot clobber this one.
    private var generation = 0

    func insert(_ text: String, via method: InsertionMethod, then submission: Submission, completion: @escaping () -> Void) {
        generation += 1
        let current = generation

        switch method {
        case .type:
            KeyEvents.type(text)
            log(.insert, "typed \(text.count) characters")
        case .paste(let restoreClipboard):
            let pasteboard = NSPasteboard.general
            let snapshot = restoreClipboard ? PasteboardSnapshot.capture(from: pasteboard) : nil
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            KeyEvents.press(.v, modifiers: .maskCommand)
            log(.insert, "pasted \(text.count) characters")

            if let snapshot {
                // Give the target app time to read the pasteboard before putting the old contents back.
                let delay = max(submission.delay, 0.3) + 0.2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard self?.generation == current else { return }
                    snapshot.restore(to: pasteboard)
                }
            }
        }

        switch submission {
        case .none:
            completion()
        case .pressReturn(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                KeyEvents.press(.return)
                log(.insert, "pressed Return")
                completion()
            }
        }
    }
}

private extension Submission {
    var delay: TimeInterval {
        switch self {
        case .none:
            return 0
        case .pressReturn(let delay):
            return delay
        }
    }
}

/// A deep copy of every item and type on a pasteboard, so the user's clipboard survives the paste.
struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    /// Nil when the pasteboard is empty (there is nothing to put back).
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let existing = pasteboard.pasteboardItems, !existing.isEmpty else {
            return nil
        }

        let copies = existing.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return PasteboardSnapshot(items: copies)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
