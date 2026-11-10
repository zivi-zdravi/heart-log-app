// Draws the app icon (design 4d): green Z with a white pulse on dark.
// Usage: swift make-icon.swift Outfit.ttf AppIcon.png
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let s = CGFloat(size) / 100
let args = CommandLine.arguments
guard args.count == 3, let provider = CGDataProvider(url: URL(fileURLWithPath: args[1]) as CFURL),
      let cgFont = CGFont(provider) else { fatalError("Could not load font") }

let base = CTFontCreateWithGraphicsFont(cgFont, 64 * s, nil, nil)
let weightAxis = NSNumber(value: 0x7767_6874)
let variation = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [weightAxis: 600]] as CFDictionary)
let font = CTFontCreateCopyWithAttributes(base, 64 * s, nil, variation)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(color(0x11181A))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

let text = NSAttributedString(string: "Z", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x8FD0AE),
])
let line = CTLineCreateWithAttributedString(text)
let width = CTLineGetTypographicBounds(line, nil, nil, nil)
ctx.saveGState()
ctx.translateBy(x: 50 * s - CGFloat(width) / 2, y: 72 * s)
ctx.scaleBy(x: 1, y: -1)
ctx.textPosition = .zero
CTLineDraw(line, ctx)
ctx.restoreGState()

let points: [CGPoint] = [(14, 50), (34, 50), (40, 40), (47, 60), (53, 50), (86, 50)].map { CGPoint(x: $0.0 * s, y: $0.1 * s) }
func stroke(_ hex: UInt32, _ w: CGFloat) {
    ctx.beginPath()
    ctx.addLines(between: points)
    ctx.setStrokeColor(color(hex))
    ctx.setLineWidth(w * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}
stroke(0x11181A, 8)
stroke(0xF2F5F3, 4)

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write icon") }
