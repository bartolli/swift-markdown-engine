//
//  AnnotationDisplayMap.swift
//  MarkdownEngine
//
//  Storage-to-display mapping for annotation ranges. A provider answers in
//  storage coordinates, the raw Markdown the binding holds, while the text
//  storage holds the display form, where `[[Name|id]]` reads `[[Name]]`.
//  The fragment maps through the coordinator's wiki-link table before a
//  range reaches layout geometry, so a host never sees display coordinates.
//

import Foundation

/// Monotone map between storage and display offsets, one entry per
/// wiki-link from the coordinator's `wikiLinkMetadata`.
///
/// The rule: outside a link the two forms are the same text, shifted by
/// the units the links before the offset lost on display. Inside a link,
/// `[[` and the name map one to one from the link's start, the closing
/// `]]` maps one to one from the link's end, and the hidden `|id` run
/// collapses onto the display offset where `]]` begins. A range that
/// collapses to nothing is not drawn. An empty table, which raw source
/// mode leaves, is the identity.
struct AnnotationDisplayMap {
    private struct Link {
        let display: NSRange
        let storage: NSRange
    }

    /// Ascending by storage location; display order is the same, both forms being monotone.
    private let links: [Link]

    init(_ metadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata]) {
        links = metadata
            .map { Link(display: NSRange(location: $0.key.location, length: $0.key.length), storage: $0.value.storageRange) }
            .sorted { $0.storage.location < $1.storage.location }
    }

    static let identity = AnnotationDisplayMap([:])

    /// The closing `]]`, present in both forms.
    private static let closerLength = 2

    func displayOffset(forStorage offset: Int) -> Int {
        var shift = 0
        for link in links {
            if offset < link.storage.location { break }
            if offset < NSMaxRange(link.storage) {
                return Self.offset(offset, from: link.storage, into: link.display)
            }
            shift += link.storage.length - link.display.length
        }
        return offset - shift
    }

    func storageOffset(forDisplay offset: Int) -> Int {
        var shift = 0
        for link in links {
            if offset < link.display.location { break }
            if offset < NSMaxRange(link.display) {
                return Self.offset(offset, from: link.display, into: link.storage)
            }
            shift += link.storage.length - link.display.length
        }
        return offset + shift
    }

    /// nil when the range has no display extent.
    func displayRange(forStorage range: NSRange) -> NSRange? {
        let start = displayOffset(forStorage: range.location)
        let end = displayOffset(forStorage: NSMaxRange(range))
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The storage span whose offsets land in `range`; the provider is queried over it.
    func storageRange(forDisplay range: NSRange) -> NSRange {
        let start = storageOffset(forDisplay: range.location)
        let end = storageOffset(forDisplay: NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// An offset inside one form of a link carried into the other form.
    private static func offset(_ offset: Int, from source: NSRange, into target: NSRange) -> Int {
        let trailing = NSMaxRange(source) - offset
        if trailing <= closerLength { return NSMaxRange(target) - trailing }
        return min(target.location + (offset - source.location), NSMaxRange(target) - closerLength)
    }
}
