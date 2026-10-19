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
    /// Redraw the marks over `range`, or over the whole document when nil.
    /// Nothing in the text changed, so the layout bridge relayouts the
    /// viewport and the view is marked for display.
    public func invalidateAnnotations(in range: NSRange? = nil) {
        guard let textView else { return }
        let target = range ?? NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutBridge?.invalidateDisplay(forCharacterRange: target)
        textView.needsDisplay = true
    }

    /// Handler for `MarkdownEditorBus/invalidateAnnotationsRequest`.
    /// Optional `userInfo["range"] as? NSRange`; absent means the document.
    @objc func handleInvalidateAnnotationsNotification(_ notification: Notification) {
        invalidateAnnotations(in: notification.userInfo?["range"] as? NSRange)
    }
}
