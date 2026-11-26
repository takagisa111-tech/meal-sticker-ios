import UIKit
import Vision
import CoreImage

enum StickerShape: String, CaseIterable, Identifiable {
    case lift, circle, rounded, original
    var id: String { rawValue }
    var name: String {
        switch self {
        case .lift: return "智能抠图"
        case .circle: return "圆形"
        case .rounded: return "圆角"
        case .original: return "原图"
        }
    }
}

enum StickerMaker {
    /// 统一方向、缩小尺寸、scale=1
    static func normalized(_ img: UIImage, maxSide: CGFloat = 1400) -> UIImage {
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 图片是否已经带透明背景（比如相册长按“拷贝”出来的主体）
    static func hasTransparency(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage else { return false }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = 64, h = 64
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 3, to: buf.count, by: 4) where buf[i] < 200 { n += 1 }
        return Double(n) / Double(w * h) > 0.03
    }

    /// iOS 17 系统级主体抠图（和相册长按抠图同一套技术）
    static func liftSubject(_ img: UIImage) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let cg = img.cgImage else { return nil }
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([req])
                guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
                let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
                let ci = CIImage(cvPixelBuffer: buffer)
                guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
                return UIImage(cgImage: out)
            } catch {
                return nil
            }
        }.value
    }

    static func crop(_ img: UIImage, circle: Bool) -> UIImage {
        let side = min(img.size.width, img.size.height) * (circle ? 0.92 : 0.96)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size, format: fmt).image { _ in
            let path = circle ? UIBezierPath(ovalIn: rect) : UIBezierPath(roundedRect: rect, cornerRadius: side * 0.14)
            path.addClip()
            img.draw(at: CGPoint(x: (side - img.size.width) / 2, y: (side - img.size.height) / 2))
        }
    }

    /// 加一圈白边，变成贴纸
    static func outlined(_ src: UIImage, maxSide: CGFloat = 640) -> UIImage {
        let img = normalized(src, maxSide: maxSide)
        let size = img.size
        let b = max(6, max(size.width, size.height) * 0.035)
        let pad = b + 2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let silhouette = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            img.draw(in: CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size), blendMode: .sourceIn)
        }
        let total = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        return UIGraphicsImageRenderer(size: total, format: fmt).image { _ in
            for a in stride(from: 0.0, to: 360.0, by: 15.0) {
                let r = a * .pi / 180
                silhouette.draw(at: CGPoint(x: pad + cos(r) * b, y: pad + sin(r) * b))
            }
            silhouette.draw(at: CGPoint(x: pad, y: pad))
            img.draw(in: CGRect(x: pad, y: pad, width: size.width, height: size.height))
        }
    }

    static func make(_ base: UIImage, shape: StickerShape, lifted: UIImage?) -> UIImage {
        switch shape {
        case .lift: return outlined(lifted ?? crop(base, circle: true))
        case .circle: return outlined(crop(base, circle: true))
        case .rounded: return outlined(crop(base, circle: false))
        case .original: return outlined(base)
        }
    }

    static func emojiSticker(_ emoji: String) -> UIImage {
        let size = CGSize(width: 260, height: 260)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let s = NSAttributedString(string: emoji.isEmpty ? "🍽️" : emoji, attributes: [.font: UIFont.systemFont(ofSize: 190)])
            let bounds = s.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
            s.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
        return outlined(img)
    }
}
