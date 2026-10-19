//
//  InlineAnnotation.swift
//  MarkdownEngine
//
//  Host-supplied marks the fragment draws over the text: an entity underline
//  or a finding squiggle for a document range. The provider is the sixth
//  entry in `MarkdownEditorServices`, nil by default. The engine sets no
//  storage or rendering attribute for a mark; it is paint only.
//

import Foundation

public enum FindingSeverity: Sendable, Hashable {
    case error
    case warning
}

public enum InlineAnnotationKind: Sendable, Hashable {
    /// Dotted underline. `slug` names the entity the span mentions.
    case entity(slug: String)
    /// Wavy underline, amber for a warning and red for an error.
    case finding(severity: FindingSeverity)
}

public struct InlineAnnotation: Sendable, Hashable {
    /// Document range in UTF-16 code units, storage coordinates.
    public var range: NSRange
    public var kind: InlineAnnotationKind

    public init(range: NSRange, kind: InlineAnnotationKind) {
        self.range = range
        self.kind = kind
    }
}

/// Answers the fragment at layout and draw time. Called on the main thread
/// for every fragment that lays out or draws, so an implementation should be
/// an in-memory lookup over rows the host already holds.
public protocol InlineAnnotationProvider: Sendable {
    /// Annotations intersecting `range`, a storage-coordinate range. Returned
    /// ranges may extend past it; the fragment clips them.
    func annotations(in range: NSRange) -> [InlineAnnotation]
}
