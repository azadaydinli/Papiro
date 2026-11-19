import AppKit
import PDFKit

/// "iPhone’dan İçe Aktar" (Continuity Camera, as in Preview): macOS fills the menu item and talks to the iPhone;
/// what comes back — a scanned document (PDF), a photo or a sketch — arrives on a pasteboard.
/// - pages: added after the current page (photos and sketches become pages the size of A4);
/// - signature: the picture's light background is made transparent and it joins the signatures panel.
enum DeviceImport {
    case pages, signature

    /// What Papiro accepts from the iPhone.
    static let types: [NSPasteboard.PasteboardType] = [
        .pdf, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// The menu item macOS turns into "iPhone’dan İçe Aktar ›" (with the nearby devices and their cameras).
    /// macOS fills it only in the main menu, not in a menu opened by a button: so the main menu holds one, hidden,
    /// and the "+" menus borrow it while they are open (`popUp`).
    static func holder() -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        item.isHidden = true
        return item
    }

    /// Open a menu under a button with "iPhone’dan İçe Aktar ›" at its end; the item goes back afterwards.
    static func popUp(_ menu: NSMenu, under button: NSView) {
        let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.identifier == NSMenuItem.importFromDeviceIdentifier }
        guard let item, let home = item.menu else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return
        }
        let at = home.index(of: item)
        home.removeItem(item)
        item.isHidden = false
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)   // returns when closed
        menu.removeItem(item)
        item.isHidden = true
        home.insertItem(item, at: at)
    }

    // MARK: pages

    /// The pages in the pasteboard: a PDF's pages, or one page made from a picture.
    /// The iPhone's document scan puts each scanned sheet in the middle of an A4 (or Letter) page, with white
    /// around it: such a page is cut to its picture, so it keeps the scan's own size and shape.
    static func pages(from pb: NSPasteboard) -> [PDFPage] {
        if let data = pb.data(forType: .pdf), let src = PDFDocument(data: data), src.pageCount > 0 {
            return (0..<src.pageCount).compactMap { i -> PDFPage? in
                guard let original = src.page(at: i), let page = original.copy() as? PDFPage else { return nil }
                let box = original.bounds(for: .mediaBox)
                if let pic = Scan.pictureFrame(original)?.intersection(box), !pic.isNull,
                   pic.width * pic.height < box.width * box.height * 0.98, pic.width > 36, pic.height > 36 {
                    page.setBounds(pic, for: .mediaBox)
                    page.setBounds(pic, for: .cropBox)
                }
                return page
            }
        }
        guard let img = picture(from: pb) else { return [] }
        return [page(from: img)].compactMap { $0 }
    }

    /// A picture as a page: fitted into A4 (on its side for a wide picture), compressed like a scan.
    static func page(from img: CGImage) -> PDFPage? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        guard w > 0, h > 0 else { return nil }
        let box = w > h ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
        let k = min(box.width / w, box.height / h)
        let media = CGRect(x: 0, y: 0, width: (w * k).rounded(), height: (h * k).rounded())
        let image = NSImage(cgImage: img, size: media.size)
        return PDFPage(image: image, options: [.mediaBox: NSValue(rect: media), .compressionQuality: 0.85])
    }

    /// The picture in the pasteboard, turned the right way up (photos carry their orientation separately).
    static func picture(from pb: NSPasteboard) -> CGImage? {
        for t in types where t != .pdf {
            if let data = pb.data(forType: t), let img = upright(data) { return img }
        }
        if let data = pb.data(forType: .pdf), let doc = PDFDocument(data: data), let p = doc.page(at: 0) {
            let b = p.bounds(for: .mediaBox)
            return p.thumbnail(of: NSSize(width: b.width * 3, height: b.height * 3), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    private static func upright(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: signature

    /// A signature from a picture: the paper (light pixels) becomes transparent, the ink stays; trimmed to the ink.
    static func signature(from img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))        // a transparent sketch counts as ink on white
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // paper → 0, ink → 1, with a soft edge between (luminance 0.82 … 0.55)
        let light: Double = 0.82, dark: Double = 0.55
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(buf[i]), g = Double(buf[i + 1]), b = Double(buf[i + 2])
                let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                let a = max(0, min(1, (light - lum) / (light - dark)))
                // keep the ink's colour, made a little darker so it reads like a pen
                buf[i] = UInt8(r * 0.8 * a); buf[i + 1] = UInt8(g * 0.8 * a); buf[i + 2] = UInt8(b * 0.8 * a)
                buf[i + 3] = UInt8(255 * a)
                if a > 0.3 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY, let full = ctx.makeImage() else { return nil }
        let pad = max(4, (maxX - minX) / 40)
        let crop = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(w, maxX + pad + 1) - max(0, minX - pad), height: min(h, maxY + pad + 1) - max(0, minY - pad))
        // the bitmap's rows in memory run from the top, as CGImage coordinates do
        return full.cropping(to: crop)
    }

    /// Save a signature picture as a PNG in the signatures folder.
    @discardableResult
    static func storeSignature(_ img: CGImage) -> URL? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]),
              (try? png.write(to: tmp)) != nil else { return nil }
        return SignatureStore.add(tmp)
    }
}
