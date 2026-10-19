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

    @Test("no provider by default: no marks and the surface is the text's own")
    func nilProviderIsTheDefault() throws {
        #expect(MarkdownEditorServices.default.annotations == nil)
        let fragment = try #require(firstFragment(in: makeTextView(configuration: configuration(provider: nil))))
        #expect(fragment.annotationMarks(at: .zero).isEmpty)
    }
}
