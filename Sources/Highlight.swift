import AppKit
import PDFKit

/// "Highlight" (as in Preview): text selected with the tool on is marked — with a colour, underlined or struck
/// through. Each line of the selection becomes one PDF markup annotation, so any PDF reader shows it.
enum HighlightStyle: Int, CaseIterable {
    case yellow, green, blue, pink, purple, underline, strikethrough

    /// The last style chosen (kept between launches).
    static var saved: HighlightStyle {
        get { HighlightStyle(rawValue: UserDefaults.standard.integer(forKey: "highlightStyle")) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "highlightStyle") }
    }

    var title: String {
        switch self {
        case .yellow: L("Yellow")
        case .green: L("Green")
        case .blue: L("Blue")
        case .pink: L("Pink")
        case .purple: L("Purple")
        case .underline: L("Underline")
        case .strikethrough: L("Strikethrough")
        }
    }

    var isColour: Bool { self != .underline && self != .strikethrough }

    /// The colour in the menu (and of underline / strikethrough).
    var color: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.25, alpha: 1)
        case .green: NSColor(srgbRed: 0.45, green: 0.85, blue: 0.40, alpha: 1)
        case .blue: NSColor(srgbRed: 0.40, green: 0.68, blue: 1.00, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.62, alpha: 1)
        case .purple: NSColor(srgbRed: 0.75, green: 0.50, blue: 0.95, alpha: 1)
        case .underline, .strikethrough: .systemRed
        }
    }

    /// The colour stored in the annotation: highlights are see-through, so the text stays readable.
    var annotationColor: NSColor { isColour ? color.withAlphaComponent(0.5) : color }

    var subtype: PDFAnnotationSubtype {
        switch self {
        case .underline: .underline
        case .strikethrough: .strikeOut
        default: .highlight
        }
    }

    /// The tool button's picture: a highlighter, or the underline / strikethrough sign.
    var symbol: String {
        switch self {
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        default: "highlighter"
        }
    }

    /// A round swatch for the menu.
    var swatch: NSImage? {
        guard isColour else { return nil }
        let c = color
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

/// Annotation types the tool makes (and right-click can remove).
let markupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut"]

extension PDFDoc {
    /// Mark the selected text: one annotation per line (and page), all one undoable step.
    @discardableResult
    func mark(_ selection: PDFSelection, _ style: HighlightStyle) -> Int {
        var made = 0
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping(); undoManager?.setActionName(L("Highlight")) }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 1, b.height > 1 else { continue }
                let a = PDFAnnotation(bounds: b, forType: style.subtype, withProperties: nil)
                a.color = style.annotationColor
                // the marked area, from the annotation's corner: top left, top right, bottom left, bottom right
                a.quadrilateralPoints = [NSPoint(x: 0, y: b.height), NSPoint(x: b.width, y: b.height),
                                         NSPoint(x: 0, y: 0), NSPoint(x: b.width, y: 0)].map { NSValue(point: $0) }
                swapAnnotation(nil, a, on: page, name: L("Highlight"))
                made += 1
            }
        }
        return made
    }
}
