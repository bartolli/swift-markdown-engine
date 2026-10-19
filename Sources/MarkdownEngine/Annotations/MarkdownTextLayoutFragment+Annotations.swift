//
//  MarkdownTextLayoutFragment+Annotations.swift
//  MarkdownEngine
//
//  Draw step for `InlineAnnotationProvider`. After the text has drawn, the
//  fragment asks the provider for the annotations in its range, maps each to
//  one rect per line below the descender, and strokes a dotted line for an
//  entity or a wavy line for a finding. No storage or rendering attribute is
//  involved: a restyle never repaints a mark and a mark never moves the text.
//

import AppKit

extension MarkdownTextLayoutFragment {

    /// One stroked mark, in the fragment's draw space.
    struct AnnotationMark: Equatable {
        let rect: CGRect
        let kind: InlineAnnotationKind
    }

    static let annotationStrokeWidth: CGFloat = 1
    /// Peak-to-peak height of a finding's wave.
    static let annotationWaveHeight: CGFloat = 3
    /// Horizontal distance between a wave's peaks.
    static let annotationWaveHalfPeriod: CGFloat = 2

    private var nativeTextView: NativeTextView? {
        textLayoutManager?.textContainer?.textView as? NativeTextView
    }

    /// Marks for every annotation the provider reports in this fragment, one
    /// per line the annotation touches, relative to `point`. Headless:
    /// `renderingSurfaceBounds` calls it with `.zero` to widen the surface,
    /// `draw(at:in:)` with its draw origin.
    func annotationMarks(at point: CGPoint) -> [AnnotationMark] {
        guard let textView = nativeTextView,
              let provider = textView.configuration.services.annotations,
              let fragRange = fragmentNSRange, fragRange.length > 0 else { return [] }
        let font = textView.baseFont
        var marks: [AnnotationMark] = []
        for annotation in provider.annotations(in: fragRange) {
            let clipped = NSIntersectionRange(annotation.range, fragRange)
            guard clipped.length > 0 else { continue }
            let local = NSRange(location: clipped.location - fragRange.location, length: clipped.length)
            for lineFragment in textLineFragments {
                let lineRange = lineFragment.characterRange
                let hit = NSIntersectionRange(lineRange, local)
                guard hit.length > 0,
                      let start = drawPosition(forDocumentCharAt: fragRange.location + hit.location, point: point),
                      let line = lineBounds(forLocalIndex: hit.location, point: point) else { continue }
                // A hit reaching the line's end stops at the line's own width:
                // the index one past the line belongs to the next line.
                let hitEnd = hit.location + hit.length
                let endX = hitEnd >= lineRange.location + lineRange.length
                    ? line.maxX
                    : point.x + lineFragment.typographicBounds.origin.x + lineFragment.locationForCharacter(at: hitEnd).x
                guard endX > start.x else { continue }
                let band = Self.annotationBand(for: annotation.kind, baselineY: start.baselineY, font: font)
                marks.append(AnnotationMark(
                    rect: CGRect(x: start.x, y: band.minY, width: endX - start.x, height: band.height),
                    kind: annotation.kind
                ))
            }
        }
        return marks
    }

    /// Vertical band a mark occupies. Both kinds start at the bottom of the
    /// descender so a mark never crosses glyph ink, which puts them outside
    /// the glyph box: the surface has to be widened for them.
    static func annotationBand(
        for kind: InlineAnnotationKind, baselineY: CGFloat, font: NSFont
    ) -> (minY: CGFloat, height: CGFloat) {
        let top = baselineY + max(0, -font.descender)
        switch kind {
        case .entity:
            return (top, annotationStrokeWidth)
        case .finding:
            return (top, annotationWaveHeight + annotationStrokeWidth)
        }
    }

    static func annotationColor(for kind: InlineAnnotationKind, theme: MarkdownEditorTheme) -> NSColor {
        switch kind {
        case .entity:
            return theme.link
        case .finding(let severity):
            switch severity {
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }
    }

    func drawAnnotations(at point: CGPoint, in context: CGContext) {
        let marks = annotationMarks(at: point)
        guard !marks.isEmpty else { return }

        let theme = nativeTextView?.configuration.theme ?? .default

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        for mark in marks {
            let path = NSBezierPath()
            path.lineWidth = Self.annotationStrokeWidth
            path.lineCapStyle = .butt
            switch mark.kind {
            case .entity:
                let y = mark.rect.midY
                path.move(to: CGPoint(x: mark.rect.minX, y: y))
                path.line(to: CGPoint(x: mark.rect.maxX, y: y))
                var pattern: [CGFloat] = [Self.annotationStrokeWidth, Self.annotationStrokeWidth * 2]
                path.setLineDash(&pattern, count: pattern.count, phase: 0)
            case .finding:
                let inset = Self.annotationStrokeWidth / 2
                let top = mark.rect.minY + inset
                let bottom = mark.rect.maxY - inset
                var x = mark.rect.minX
                var toTop = true
                path.move(to: CGPoint(x: x, y: bottom))
                while x < mark.rect.maxX {
                    x = min(x + Self.annotationWaveHalfPeriod, mark.rect.maxX)
                    path.line(to: CGPoint(x: x, y: toTop ? top : bottom))
                    toTop.toggle()
                }
            }
            Self.annotationColor(for: mark.kind, theme: theme).setStroke()
            path.stroke()
        }
    }
}
