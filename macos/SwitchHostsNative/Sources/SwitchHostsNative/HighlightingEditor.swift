import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the Edit menu. The focused editor comments or uncomments its lines.
    static let toggleComment = Notification.Name("net.oldj.switchhosts.native.toggleComment")
}

/// Monospaced hosts editor backed by NSTextView. Comments are dimmed and the
/// address at the start of each entry is coloured. Pass `readOnly` for the
/// system hosts view. A new `reveal` selects its range and scrolls to it.
struct HighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    var readOnly = false
    var reveal: EditorReveal? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.defaultParagraphStyle = Self.paragraph
        textView.typingAttributes = [.font: Self.font, .paragraphStyle: Self.paragraph, .foregroundColor: NSColor.labelColor]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isEditable = !readOnly
        textView.string = text
        Self.highlight(textView)
        context.coordinator.attach(textView)
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = !readOnly
        // Replace the text only when the model changed it, so typing keeps the caret.
        if textView.string != text {
            textView.string = text
            Self.highlight(textView)
            // Setting the string does not post a change notification, so the gutter is redrawn here.
            (scroll.verticalRulerView as? LineNumberRuler)?.needsDisplay = true
        }
        if let reveal, reveal.token != context.coordinator.revealToken {
            context.coordinator.revealToken = reveal.token
            Self.select(reveal.range, in: textView)
        }
    }

    /// Selects `range` (UTF-16 offsets, as the core reports them), scrolls to it,
    /// and moves focus to the editor so the selection is visible.
    private static func select(_ range: NSRange, in textView: NSTextView) {
        let length = (textView.string as NSString).length
        let start = min(max(range.location, 0), length)
        let selection = NSRange(location: start, length: min(max(range.length, 0), length - start))
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Re-applies the colours for the whole document.
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ], range: whole)

        let source = storage.string as NSString
        // Whole-line comments.
        commentPattern.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
            guard let range = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        // The address at the start of an entry.
        addressPattern.enumerateMatches(in: storage.string, range: whole) { match, _, _ in
            guard let range = match?.range(at: 1), range.location != NSNotFound else { return }
            if source.substring(with: range).isEmpty == false {
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
            }
        }
        storage.endEditing()
    }

    /// The editor's text: 13 pt monospaced with a little extra line height.
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        return style
    }()

    private static let commentPattern = try! NSRegularExpression(pattern: "^[ \\t]*#.*$", options: [.anchorsMatchLines])
    private static let addressPattern = try! NSRegularExpression(pattern: "^[ \\t]*([0-9A-Fa-f.:]+)", options: [.anchorsMatchLines])
    /// The comment marker at the start of a line, with the indent before it.
    private static let commentMarker = try! NSRegularExpression(pattern: "^([ \\t]*)#[ \\t]*")

    /// Comments or uncomments every line the selection touches. A commented
    /// line loses its `#` and the spaces after it; any other non-blank line gets
    /// `# ` in front of its text. Each line is decided on its own, as in 5.0.2.
    static func toggleComment(in textView: NSTextView) {
        guard textView.isEditable else { return }
        let source = textView.string as NSString
        let selected = textView.selectedRange()
        let first = source.lineRange(for: NSRange(location: selected.location, length: 0))
        let lastPosition = selected.length > 0 ? selected.location + selected.length - 1 : selected.location
        let block = NSUnionRange(first, source.lineRange(for: NSRange(location: lastPosition, length: 0)))
        guard block.length > 0 else { return }

        let original = source.substring(with: block)
        let toggled = original
            .components(separatedBy: "\n")
            .map(toggledLine)
            .joined(separator: "\n")
        guard toggled != original, textView.shouldChangeText(in: block, replacementString: toggled) else { return }
        textView.replaceCharacters(in: block, with: toggled)
        textView.setSelectedRange(NSRange(location: block.location, length: (toggled as NSString).length))
        textView.didChangeText()
    }

    private static func toggledLine(_ line: String) -> String {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return line }
        let text = line as NSString
        if let match = commentMarker.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
            let indent = text.substring(with: match.range(at: 1))
            return indent + text.substring(from: match.range.location + match.range.length)
        }
        return "# " + line
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingEditor
        var revealToken: UUID?
        private weak var textView: NSTextView?
        private var commentObserver: NSObjectProtocol?

        init(_ parent: HighlightingEditor) {
            self.parent = parent
        }

        deinit {
            if let commentObserver {
                NotificationCenter.default.removeObserver(commentObserver)
            }
        }

        /// Listens for the Edit menu's comment command. Only the editor that has
        /// focus reacts, so several editors never all toggle at once.
        func attach(_ textView: NSTextView) {
            self.textView = textView
            guard commentObserver == nil else { return }
            commentObserver = NotificationCenter.default.addObserver(
                forName: .toggleComment, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let textView = self.textView, textView.window?.firstResponder === textView else { return }
                HighlightingEditor.toggleComment(in: textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            HighlightingEditor.highlight(textView)
        }
    }
}

/// The line-number gutter beside a hosts editor, as the 5.0.2 editor shows it.
/// Only the first line of each logical line is numbered, so wrapped lines do not
/// get numbers of their own.
final class LineNumberRuler: NSRulerView {
    private weak var editor: NSTextView?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView) {
        editor = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // The first layout of the text view does not always redraw the ruler, so
        // redraw when the text view changes size and once after it is set up.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView
        )
        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
        }
    }

    required init(coder: NSCoder) {
        fatalError("LineNumberRuler is created in code")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        // A hairline between the numbers and the text.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let editor, let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
        let text = editor.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        // Line fragments are in text-container space, which starts at the inset.
        var origin = convert(NSPoint.zero, from: editor)
        origin.y += editor.textContainerOrigin.y
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { fragment, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let start = characters.location
            let isLineStart = start == 0 || (start <= text.length && text.character(at: start - 1) == 10)
            guard isLineStart else { return }
            let number = 1 + Self.newlineCount(in: text.substring(to: start))
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = origin.y + fragment.minY + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
        // The empty line after a final newline has no fragment of its own; number
        // it too, so the gutter counts the same lines as the info panel.
        let extra = layoutManager.extraLineFragmentRect
        if text.length > 0, text.character(at: text.length - 1) == 10, extra.height > 0,
           extra.intersects(editor.visibleRect) {
            let label = "\(1 + Self.newlineCount(in: editor.string))" as NSString
            let size = label.size(withAttributes: attributes)
            let y = origin.y + extra.minY + (extra.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
    }

    private static func newlineCount(in text: String) -> Int {
        text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

