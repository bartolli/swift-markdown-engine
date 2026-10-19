//
//  InlineAnnotationTests.swift
//  MarkdownEngineTests
//
//  `InlineAnnotationProvider` is the sixth service: a host hands the engine
//  document ranges and kinds, and the fragment paints marks for them after
//  the text, with no attribute set on the storage. The marks hang below the
//  descender, so the fragment has to union them into its rendering surface
//  or TextKit clips them.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

/// Records every range the fragment asks for and answers from a fixed list.
private final class RecordingProvider: InlineAnnotationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let rows: [InlineAnnotation]
    private var recorded: [NSRange] = []

    init(_ rows: [InlineAnnotation]) {
        self.rows = rows
    }

    var queries: [NSRange] { lock.withLock { recorded } }

    func reset() { lock.withLock { recorded.removeAll() } }

    func annotations(in range: NSRange) -> [InlineAnnotation] {
        lock.withLock { recorded.append(range) }
        return rows.filter { NSIntersectionRange($0.range, range).length > 0 }
    }
}

/// RGBA bitmap the fragment drew into, addressed in the fragment's own space.
private struct FragmentBitmap {
    let context: CGContext
    let origin: CGPoint

    /// Pixels inside `rect` whose colour is within `tolerance` (0...1 per
    /// channel) of `color`.
    func count(in rect: CGRect, matching color: NSColor, tolerance: CGFloat = 0.25) -> Int {
        guard let data = context.data,
              let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let want = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        let minX = max(0, Int(floor(rect.minX - origin.x)))
        let maxX = min(context.width - 1, Int(ceil(rect.maxX - origin.x)))
        let minY = max(0, Int(floor(rect.minY - origin.y)))
        let maxY = min(context.height - 1, Int(ceil(rect.maxY - origin.y)))
        guard minX <= maxX, minY <= maxY else { return 0 }
        var hits = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let i = y * bytesPerRow + x * 4
                let r = CGFloat(bytes[i]) / 255
                let g = CGFloat(bytes[i + 1]) / 255
                let b = CGFloat(bytes[i + 2]) / 255
                if abs(r - want.0) < tolerance, abs(g - want.1) < tolerance, abs(b - want.2) < tolerance {
                    hits += 1
                }
            }
        }
        return hits
    }
}

@MainActor
@Suite("Inline annotations")
struct InlineAnnotationTests {

    private let fontSize: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    private static let paragraph = "Ada walked the mill road with Tomas."
    private static let text = paragraph + "\n\nThe second paragraph stays plain."

    private static func range(of needle: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    /// A tight line box: no extra line spacing and no paragraph spacing, so
    /// a mark below the descender has nothing to hide in.
    private func configuration(provider: (any InlineAnnotationProvider)?) -> MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.paragraph.spacingFactor = 0
        config.paragraph.lineHeightExtraSpacing = 0
        config.services.annotations = provider
        return config
    }

    /// A laid-out editor whose storage carries the styler's own attributes.
    private func makeTextView(configuration: MarkdownEditorConfiguration, width: CGFloat = 400) -> NativeTextView {
        _ = NSApplication.shared
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        tv.configuration = configuration
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: tv.layoutBridge,
            configuration: configuration
        )
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        let storage = NSMutableAttributedString(
            string: Self.text,
            attributes: [.font: font, .paragraphStyle: style]
        )
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: Self.text, fontName: fontName, fontSize: fontSize,
            caretLocation: -1, configuration: configuration
        ) {
            storage.addAttributes(attributes, range: range)
        }
        tv.textStorage?.setAttributedString(storage)
        return tv
    }

    /// A laid-out editor whose storage the coordinator built from the storage
    /// form through the display state, as `updateNSView` does, so the text
    /// view holds `[[Name]]` and the coordinator the wiki-link table.
    private func makeDisplayEditor(
        storage: String, configuration: MarkdownEditorConfiguration, width: CGFloat = 400
    ) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(storage), fontName: fontName, fontSize: fontSize,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration = configuration
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        tv.configuration = configuration
        tv.baseFont = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        tv.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.delegate = coordinator
        coordinator.textView = tv
        // Set before the rebuild's own layout pass, as the wrapper does, so the fragments are the engine's.
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        coordinator.layoutDelegate = layoutDelegate
        tv.textLayoutManager?.delegate = layoutDelegate
        coordinator.rebuildTextStorageAndStyle(tv, from: storage)
        return (coordinator, tv)
    }

    /// Glyph rect of a display range in the fragment's own space, read from
    /// the layout manager's text segments rather than the fragment's helpers.
    private func glyphRect(
        of range: NSRange, in tv: NativeTextView, fragment: MarkdownTextLayoutFragment
    ) throws -> CGRect {
        let tlm = try #require(tv.textLayoutManager)
        let container = try #require(tv.textContainer)
        let rect = LayoutBridge(tlm).boundingRect(forCharacterRange: range, in: container)
        return rect.offsetBy(dx: -fragment.layoutFragmentFrame.minX, dy: -fragment.layoutFragmentFrame.minY)
    }

    /// Each mark's horizontal extent equals the glyph extent of its word, in order.
    private func expectMarks(
        _ marks: [MarkdownTextLayoutFragment.AnnotationMark], cover words: [String],
        in tv: NativeTextView, fragment: MarkdownTextLayoutFragment
    ) throws {
        let display = tv.string as NSString
        #expect(marks.count == words.count)
        for (mark, word) in zip(marks, words) {
            let glyphs = try glyphRect(of: display.range(of: word), in: tv, fragment: fragment)
            #expect(abs(mark.rect.minX - glyphs.minX) < 0.5, "\(word) starts at \(glyphs.minX), mark at \(mark.rect.minX)")
            #expect(abs(mark.rect.maxX - glyphs.maxX) < 0.5, "\(word) ends at \(glyphs.maxX), mark at \(mark.rect.maxX)")
        }
    }

    private func firstFragment(in tv: NativeTextView) -> MarkdownTextLayoutFragment? {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        tlm.invalidateLayout(for: tlm.documentRange)
        tlm.ensureLayout(for: tlm.documentRange)

        var found: MarkdownTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            found = fragment as? MarkdownTextLayoutFragment
            return false
        }
        return found
    }

    /// Draw the fragment at its own origin into an RGBA bitmap covering its
    /// rendering surface, white behind, antialiasing off so a 1pt mark lands
    /// as pure colour on one pixel row.
    private func render(_ fragment: MarkdownTextLayoutFragment) throws -> FragmentBitmap {
        let bounds = fragment.renderingSurfaceBounds.insetBy(dx: -2, dy: -2)
        let width = Int(ceil(bounds.width))
        let height = Int(ceil(bounds.height))
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to the text view's coordinate system: y grows downward.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setShouldAntialias(false)
        fragment.draw(at: .zero, in: context)
        return FragmentBitmap(context: context, origin: bounds.origin)
    }

    @Test("a provider on services is asked over the fragment's range and its marks are painted after the text")
    func sixthServiceDrawsMarks() throws {
        let rows = [
            InlineAnnotation(range: Self.range(of: "Ada"), kind: .entity(slug: "ada")),
            InlineAnnotation(range: Self.range(of: "Tomas"), kind: .entity(slug: "tomas")),
            InlineAnnotation(range: Self.range(of: "mill road"), kind: .finding(severity: .warning)),
        ]
        let provider = RecordingProvider(rows)
        let tv = makeTextView(configuration: configuration(provider: provider))
        let fragment = try #require(firstFragment(in: tv))
        let storage = try #require(tv.textStorage)
        let paragraphRange = (Self.text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))

        // Geometry: three marks, one per row, in text order.
        let marks = fragment.annotationMarks(at: .zero).sorted { $0.rect.minX < $1.rect.minX }
        #expect(marks.count == 3, "two entities and one finding should yield three marks, got \(marks.count)")
        let kinds = marks.map(\.kind)
        #expect(kinds == [.entity(slug: "ada"), .finding(severity: .warning), .entity(slug: "tomas")])

        // Every mark is unioned into the rendering surface, which is wider
        // than the same paragraph laid out without a provider.
        let bare = try #require(firstFragment(in: makeTextView(configuration: configuration(provider: nil))))
        let annotated = fragment.renderingSurfaceBounds
        #expect(annotated.contains(bare.renderingSurfaceBounds),
                "annotated surface \(annotated) should contain the bare surface \(bare.renderingSurfaceBounds)")
        #expect(annotated.maxY > bare.renderingSurfaceBounds.maxY + 0.5,
                "marks below the descender should widen the surface: \(annotated.maxY) vs \(bare.renderingSurfaceBounds.maxY)")
        for mark in marks {
            #expect(annotated.contains(mark.rect), "surface \(annotated) clips mark \(mark.rect)")
        }

        // Drawing asks the provider over the fragment's range and paints the
        // marks in their colours, without touching the storage.
        let before = NSAttributedString(attributedString: storage)
        provider.reset()
        let bitmap = try render(fragment)
        let queries = provider.queries
        #expect(!queries.isEmpty, "draw should ask the provider")
        #expect(queries.allSatisfy { $0 == paragraphRange },
                "draw should ask over the fragment's range \(paragraphRange), asked \(queries)")

        let theme = tv.configuration.theme
        let entityColor = theme.link
        let warningColor = NSColor.systemOrange
        let (ada, millRoad, tomas) = (marks[0], marks[1], marks[2])
        #expect(bitmap.count(in: ada.rect, matching: entityColor) > 0, "no entity ink under Ada")
        #expect(bitmap.count(in: tomas.rect, matching: entityColor) > 0, "no entity ink under Tomas")
        #expect(bitmap.count(in: millRoad.rect, matching: warningColor) > 0, "no warning ink under mill road")
        #expect(bitmap.count(in: millRoad.rect, matching: entityColor) == 0, "finding painted in the entity colour")
        #expect(bitmap.count(in: ada.rect, matching: warningColor) == 0, "entity painted in the warning colour")

        #expect(storage.isEqual(to: before), "draw must not touch the storage's attributes")
        #expect(Array(storage.string.utf16) == Array(before.string.utf16), "draw must not touch the storage's text")
    }

    private static let linkStorage = "Ada walked with [[mara-voss|Mara]] to the mill."
    private static let linkDisplay = "Ada walked with [[mara-voss]] to the mill."

    /// Storage-coordinate rows over `linkStorage`: a word before the link, the
    /// whole link, the hidden `Mara` run alone, and a word after the link.
    private static var linkRows: [InlineAnnotation] {
        let storage = linkStorage as NSString
        let hidden = storage.range(of: "|Mara")
        return [
            InlineAnnotation(range: storage.range(of: "Ada"), kind: .entity(slug: "ada")),
            InlineAnnotation(range: storage.range(of: "[[mara-voss|Mara]]"), kind: .entity(slug: "mara-voss")),
            InlineAnnotation(range: NSRange(location: hidden.location + 1, length: hidden.length - 1), kind: .finding(severity: .error)),
            InlineAnnotation(range: storage.range(of: "the mill"), kind: .entity(slug: "the-mill")),
        ]
    }

    @Test("storage-coordinate ranges are asked for and mapped through the wiki-link table onto the display form")
    func marksMapStorageRangesToTheDisplayForm() throws {
        let provider = RecordingProvider(Self.linkRows)
        let (coordinator, tv) = makeDisplayEditor(storage: Self.linkStorage, configuration: configuration(provider: provider))
        #expect(tv.string == Self.linkDisplay)
        #expect(coordinator.wikiLinkMetadata.count == 1)
        let fragment = try #require(firstFragment(in: tv))

        provider.reset()
        let marks = fragment.annotationMarks(at: .zero).sorted { $0.rect.minX < $1.rect.minX }
        #expect(provider.queries == [NSRange(location: 0, length: (Self.linkStorage as NSString).length)],
                "the provider is asked over the fragment's storage span, asked \(provider.queries)")
        // The hidden-run row collapses to nothing on display and is not drawn.
        #expect(marks.map(\.kind) == [.entity(slug: "ada"), .entity(slug: "mara-voss"), .entity(slug: "the-mill")])
        try expectMarks(marks, cover: ["Ada", "[[mara-voss]]", "the mill"], in: tv, fragment: fragment)
    }

    @Test("raw source mode leaves no table and the mapping is the identity")
    func rawSourceModeIsTheIdentity() throws {
        var config = configuration(provider: RecordingProvider(Self.linkRows))
        config.rawSourceMode = true
        let (coordinator, tv) = makeDisplayEditor(storage: Self.linkStorage, configuration: config)
        #expect(tv.string == Self.linkStorage)
        #expect(coordinator.wikiLinkMetadata.isEmpty)
        let fragment = try #require(firstFragment(in: tv))

        let marks = fragment.annotationMarks(at: .zero).sorted { $0.rect.minX < $1.rect.minX }
        #expect(marks.map(\.kind) == [
            .entity(slug: "ada"), .entity(slug: "mara-voss"), .finding(severity: .error), .entity(slug: "the-mill"),
        ])
        try expectMarks(marks, cover: ["Ada", "[[mara-voss|Mara]]", "Mara", "the mill"], in: tv, fragment: fragment)
    }

    @Test("a finding over an entity range stacks below the dotted mark; one alone starts at the descender")
    func findingOverAnEntityStacks() throws {
        let rows = [
            InlineAnnotation(range: Self.range(of: "Ada"), kind: .entity(slug: "ada")),
            InlineAnnotation(range: Self.range(of: "Ada walked"), kind: .finding(severity: .error)),
            InlineAnnotation(range: Self.range(of: "mill road"), kind: .finding(severity: .warning)),
        ]
        let tv = makeTextView(configuration: configuration(provider: RecordingProvider(rows)))
        let fragment = try #require(firstFragment(in: tv))
        let marks = fragment.annotationMarks(at: .zero)
        #expect(marks.map(\.kind) == [.entity(slug: "ada"), .finding(severity: .error), .finding(severity: .warning)])
        let (ada, stacked, alone) = (marks[0], marks[1], marks[2])
        #expect(alone.rect.minY == ada.rect.minY, "an unstacked finding starts where the entity mark does")
        #expect(stacked.rect.minY == ada.rect.minY + MarkdownTextLayoutFragment.annotationStackOffset,
                "the finding over Ada should drop by the stack offset: \(stacked.rect.minY) vs \(ada.rect.minY)")
        #expect(stacked.rect.minY >= ada.rect.maxY, "the wave must start below the dotted mark")
        #expect(fragment.renderingSurfaceBounds.contains(stacked.rect), "the surface follows the lowered wave")

        // Both marks have ink in their own colour inside their own rect, and
        // the dotted mark is not painted over: no error ink in its band.
        let bitmap = try render(fragment)
        let theme = tv.configuration.theme
        #expect(bitmap.count(in: ada.rect, matching: theme.link) > 0, "no entity ink under Ada")
        #expect(bitmap.count(in: stacked.rect, matching: .systemRed) > 0, "no error ink in the stacked band")
        #expect(bitmap.count(in: ada.rect, matching: .systemRed) == 0, "the wave covers the dotted mark")
    }

    @Test("no provider by default: no marks and the surface is the text's own")
    func nilProviderIsTheDefault() throws {
        #expect(MarkdownEditorServices.default.annotations == nil)
        let fragment = try #require(firstFragment(in: makeTextView(configuration: configuration(provider: nil))))
        #expect(fragment.annotationMarks(at: .zero).isEmpty)
    }
}
