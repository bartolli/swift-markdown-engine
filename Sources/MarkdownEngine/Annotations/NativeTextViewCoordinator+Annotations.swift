//
//  NativeTextViewCoordinator+Annotations.swift
//  MarkdownEngine
//
//  Host-triggered redraw of annotation marks when the provider's rows change
//  without a keystroke. Reached on the coordinator directly or through the
//  bus's `invalidateAnnotationsRequest`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Lay out and redraw the marks over `range`, a storage-coordinate range,
    /// or over the whole document when nil. Nothing in the text changed, so
    /// the text storage is told its attributes over the range were edited,
    /// with no attribute touched: the one notice the text view re-lays-out
    /// and re-renders a range for. Invalidating layout by hand and running a
    /// viewport pass rebuilds the fragments but never reaches the screen.
    public func invalidateAnnotations(in range: NSRange? = nil) {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
        let target = range.map { displayRange(forStorage: $0, length: storage.length) }
            ?? NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.edited(.editedAttributes, range: target, changeInLength: 0)
        storage.endEditing()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        textView.needsDisplay = true
    }

    /// The storage range on the display form, clamped to the text and widened
    /// to one unit when it collapses so the paragraph around an insertion
    /// point is still covered.
    private func displayRange(forStorage range: NSRange, length: Int) -> NSRange {
        let map = AnnotationDisplayMap(wikiLinkMetadata)
        var start = min(map.displayOffset(forStorage: range.location), length)
        var end = min(map.displayOffset(forStorage: NSMaxRange(range)), length)
        if end <= start {
            if start < length { end = start + 1 } else { start = end - 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Handler for `MarkdownEditorBus/invalidateAnnotationsRequest`.
    /// Optional `userInfo["range"] as? NSRange`, a storage range; absent means the document.
    @objc func handleInvalidateAnnotationsNotification(_ notification: Notification) {
        invalidateAnnotations(in: notification.userInfo?["range"] as? NSRange)
    }
}
