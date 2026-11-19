import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Scanned pages: a page whose content is one picture the size of the page. "Clean Margins" and "White Out" work
/// only on such pages, and they really remove what they paint over: the page is redrawn as a new picture with
/// those parts white, so nothing of the old picture is left in the file.
enum Scan {
    struct Picture { let width: Int, height: Int, gray: Bool }

    /// The largest picture the page draws (looking into forms too), or nil when it draws none.
    static func mainPicture(_ page: PDFPage) -> Picture? {
        guard let ref = page.pageRef, let pageDict = ref.dictionary else { return nil }
        var best: Picture?

        func look(in resources: CGPDFDictionaryRef, depth: Int) {
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let d = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(d, "Subtype", &subtype), let subtype else { return true }
                switch String(cString: subtype) {
                case "Image":
                    var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                    guard CGPDFDictionaryGetInteger(d, "Width", &w), CGPDFDictionaryGetInteger(d, "Height", &h) else { return true }
                    var bits: CGPDFInteger = 8
                    _ = CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bits)
                    var space: UnsafePointer<CChar>?
                    let gray = bits == 1 || (CGPDFDictionaryGetName(d, "ColorSpace", &space) && space.map { String(cString: $0) } == "DeviceGray")
                    if w * h > (best.map { $0.width * $0.height } ?? 0) { best = Picture(width: w, height: h, gray: gray) }
                case "Form" where depth < 3:
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(d, "Resources", &inner), let inner { look(in: inner, depth: depth + 1) }
                default: break
                }
                return true
            }, nil)
        }

        // resources may be inherited from the page tree
        var dict: CGPDFDictionaryRef? = pageDict
        while let d = dict {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(d, "Resources", &resources), let resources { look(in: resources, depth: 0); break }
            var parent: CGPDFDictionaryRef?
            dict = CGPDFDictionaryGetDictionary(d, "Parent", &parent) ? parent : nil
        }
        return best
    }

    /// A scanned page: its largest picture has the page's shape (either way round) and at least 50 dpi.
    static func isScanned(_ page: PDFPage) -> Bool {
        guard let pic = mainPicture(page) else { return false }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, pic.width > 0, pic.height > 0 else { return false }
        let pageAspect = box.width / box.height
        let picAspect = CGFloat(pic.width) / CGFloat(pic.height)
        let sameShape = abs(picAspect / pageAspect - 1) < 0.2 || abs(picAspect * pageAspect - 1) < 0.2
        let dpi = CGFloat(max(pic.width, pic.height)) / (max(box.width, box.height) / 72)
        return sameShape && dpi >= 50
    }

    /// The page redrawn as one picture at the resolution of its scan, with `paint` applied on top (page space,
    /// unrotated crop box). The old content is not kept. Annotations are carried over as they are.
    /// The new page lives in its own PDF, which must be kept alive with it.
    static func redrawn(_ page: PDFPage, paint: (CGContext, CGRect) -> Void) -> (page: PDFPage, owner: PDFDocument)? {
        guard let ref = page.pageRef, let pic = mainPicture(page) else { return nil }
        let box = page.bounds(for: .cropBox)
        // pixels per point of the scan (whichever way round the picture lies on the page), within 72–400 dpi
        let along = CGFloat(pic.width) / box.width, across = CGFloat(pic.width) / box.height
        let fit = abs(CGFloat(pic.height) / box.height - along) <= abs(CGFloat(pic.height) / box.width - across) ? along : across
        let scale = min(max(fit, 1), 400 / 72)
        let pw = Int((box.width * scale).rounded()), ph = Int((box.height * scale).rounded())
        guard pw > 0, ph > 0 else { return nil }

        let space = pic.gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = pic.gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(ref)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        paint(ctx, box)
        guard let bitmap = ctx.makeImage(), let jpeg = jpegImage(bitmap) else { return nil }

        // a PDF page that holds just this picture (JPEG data is embedded as it is)
        var media = CGRect(origin: .zero, size: box.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        pdf.beginPDFPage(nil)
        pdf.draw(jpeg, in: media)
        pdf.endPDFPage()
        pdf.closePDF()
        guard let doc = PDFDocument(data: data as Data), let out = doc.page(at: 0) else { return nil }
        out.rotation = page.rotation
        for a in page.annotations {
            guard let copy = a.copy() as? PDFAnnotation else { continue }
            copy.bounds = a.bounds.offsetBy(dx: -box.minX, dy: -box.minY)
            out.addAnnotation(copy)
        }
        return (out, doc)
    }

    /// The picture as JPEG (quality 0.9), so a page does not grow to an uncompressed bitmap.
    private static func jpegImage(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
