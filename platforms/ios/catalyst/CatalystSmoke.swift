import UIKit
import CoreText
import RaTeX

#if !targetEnvironment(macCatalyst)
#error("The integration smoke must compile for Mac Catalyst.")
#endif

private enum SmokeFailure: Error {
    case invalidDisplayList
    case missingFormulaGeometry
    case invalidViewSize
    case missingRenderedImage
    case blankRenderedImage
    case missingBundledFont
}

@main
@MainActor
final class CatalystSmoke: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            try runSmoke()
            print("Catalyst UIKit / Swift / C ABI formula smoke passed.")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Catalyst formula smoke failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private func runSmoke() throws {
        let latex = #"\frac{-b + \sqrt{b^2-4ac}}{2a}"#
        let displayList = try RaTeXEngine.shared.parse(latex, displayMode: true, color: .black)
        guard displayList.width.isFinite, displayList.width > 0,
              displayList.height.isFinite, displayList.height > 0,
              displayList.depth.isFinite, displayList.depth >= 0 else {
            throw SmokeFailure.invalidDisplayList
        }
        let hasGlyph = displayList.items.contains { if case .glyphPath = $0 { return true }; return false }
        let hasFractionBar = displayList.items.contains { if case .line = $0 { return true }; return false }
        guard hasGlyph, hasFractionBar else { throw SmokeFailure.missingFormulaGeometry }

        RaTeXFontLoader.ensureLoaded()
        let fontName = "KaTeX_Main-Regular"
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        let actualFontName = CTFontCopyPostScriptName(font) as String
        guard actualFontName == fontName else {
            throw SmokeFailure.missingBundledFont
        }
        let view = RaTeXView(frame: .zero)
        let _: UIView = view
        var renderingError: Error?
        view.onError = { renderingError = $0 }
        view.latex = latex
        if let renderingError { throw renderingError }
        let size = view.intrinsicContentSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw SmokeFailure.invalidViewSize
        }
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in view.draw(view.bounds) }
        guard let cgImage = image.cgImage else { throw SmokeFailure.missingRenderedImage }
        try assertVisiblePixels(in: cgImage)
    }

    private func assertVisiblePixels(in image: CGImage) throws {
        var alpha = [UInt8](repeating: 0, count: image.width * image.height)
        try alpha.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: nil,
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { throw SmokeFailure.missingRenderedImage }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        guard alpha.contains(where: { $0 > 0 }) else { throw SmokeFailure.blankRenderedImage }
    }
}
