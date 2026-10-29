import SwiftUI
import AppKit

/// High-performance native AppKit `NSTextField` tailored for Spotlight/Alfred-style launchers:
/// 1. Emits live text updates on every keystroke (`controlTextDidChange`), including active Vietnamese Telex/VNI IME marked text.
/// 2. Preserves active IME composition (`hasMarkedText()`) so Vietnamese diacritics (`ô`, `ơ`, `ư`, `đ`, tones) never break.
/// 3. Intercepts `↑`, `↓`, `↩`, `⇥`, `⎋`, and `⌫` directly via `NSTextFieldDelegate.control(_:textView:doCommandBy:)`
///    so arrow navigation and Enter/Tab work 100% reliably on the first keystroke.
struct NativeSearchInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    var focusTrigger: Int = 0
    var selectAllOnFocus: Bool = false
    var interceptHorizontalArrows: Bool = false
    var onMoveSelection: @MainActor (Int) -> Void
    var onSubmit: @MainActor (NSEvent.ModifierFlags) -> Void
    var onTab: @MainActor () -> Void
    var onEscape: @MainActor () -> Void
    var onBackspaceAtBoundary: (@MainActor () -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(frame: .zero)
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        tf.textColor = .labelColor
        tf.placeholderString = placeholder
        tf.maximumNumberOfLines = 1
        tf.lineBreakMode = .byTruncatingHead
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.stringValue = text

        DispatchQueue.main.async {
            Self.focusTextField(tf, selectAll: selectAllOnFocus)
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }

        let editor = nsView.currentEditor() as? NSTextView
        let hasMarked = editor?.hasMarkedText() ?? false

        // Do NOT clobber active Vietnamese Telex IME marked text unless text was externally cleared or changed to a browse path
        if !context.coordinator.isUpdatingFromUserTyping {
            let currentLive = editor?.string ?? nsView.stringValue
            if currentLive != text {
                let isExternalJump = text.isEmpty || text.hasSuffix("/") || !hasMarked
                if isExternalJump {
                    editor?.unmarkText()
                    nsView.stringValue = text
                    if let editor {
                        let endPos = (text as NSString).length
                        editor.selectedRange = NSRange(location: endPos, length: 0)
                    }
                }
            }
        }

        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            let shouldSelectAll = selectAllOnFocus
            DispatchQueue.main.async {
                Self.focusTextField(nsView, selectAll: shouldSelectAll)
            }
        }
    }

    static func focusTextField(_ tf: NSTextField, selectAll: Bool) {
        guard let win = tf.window else { return }
        if win.firstResponder !== tf && win.firstResponder !== tf.currentEditor() {
            win.makeFirstResponder(tf)
        }
        if let editor = tf.currentEditor() as? NSTextView {
            if selectAll && !tf.stringValue.isEmpty {
                editor.selectAll(nil)
            } else if !selectAll {
                let end = (tf.stringValue as NSString).length
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchInputField
        var isUpdatingFromUserTyping = false
        var lastFocusTrigger: Int = 0

        init(parent: NativeSearchInputField) {
            self.parent = parent
            self.lastFocusTrigger = parent.focusTrigger
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let liveString = (tf.currentEditor() as? NSTextView)?.string ?? tf.stringValue
            isUpdatingFromUserTyping = true
            if parent.text != liveString {
                parent.text = liveString
            }
            isUpdatingFromUserTyping = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if parent.interceptHorizontalArrows {
                if commandSelector == #selector(NSResponder.moveLeft(_:)) {
                    if textView.hasMarkedText() { textView.unmarkText() }
                    parent.onMoveSelection(-1)
                    return true
                }
                if commandSelector == #selector(NSResponder.moveRight(_:)) {
                    if textView.hasMarkedText() { textView.unmarkText() }
                    parent.onMoveSelection(1)
                    return true
                }
            }

            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if textView.hasMarkedText() { textView.unmarkText() }
                parent.onMoveSelection(-1)
                return true
            }

            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if textView.hasMarkedText() { textView.unmarkText() }
                parent.onMoveSelection(1)
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                if textView.hasMarkedText() { textView.unmarkText() }
                let liveString = textView.string
                if parent.text != liveString {
                    isUpdatingFromUserTyping = true
                    parent.text = liveString
                    isUpdatingFromUserTyping = false
                }
                let mods = (NSApp.currentEvent?.modifierFlags ?? []).cleanShortcutModifiers
                parent.onSubmit(mods)
                return true
            }

            if commandSelector == #selector(NSResponder.insertTab(_:)) ||
               commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if textView.hasMarkedText() { textView.unmarkText() }
                parent.onTab()
                return true
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if textView.hasMarkedText() { textView.unmarkText() }
                parent.onEscape()
                return true
            }

            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if !textView.hasMarkedText(),
                   let handler = parent.onBackspaceAtBoundary,
                   handler() {
                    return true
                }
            }

            return false
        }
    }
}
