import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func bitmap(_ size: Int, height: Int? = nil) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size, height: height ?? size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "UtterArtwork", code: 1)
    }
    return context
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icons = root.appending(path: "build/Utter.iconset")
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let context = try bitmap(size)
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        context.setFillColor(CGColor(red: 0.36, green: 0.34, blue: 0.91, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840), cornerWidth: 190, cornerHeight: 190, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for (index, height) in [170, 300, 440, 300, 170].enumerated() {
            let rect = CGRect(x: 294 + index * 94, y: 512 - height / 2, width: 60, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil))
            context.fillPath()
        }
        let suffix = scale == 2 ? "@2x" : ""
        let url = icons.appending(path: "icon_\(points)x\(points)\(suffix).png")
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "UtterArtwork", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "UtterArtwork", code: 3) }
    }
}
// ICNS uses PNG-backed image elements for modern macOS, including Retina sizes.
var elements = Data()
for (kind, name) in [("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
                     ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
                     ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
                     ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
                     ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: icons.appending(path: name))
    elements.append(Data(kind.utf8))
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { elements.append(contentsOf: $0) }
    elements.append(png)
}
var icns = Data("icns".utf8)
var length = UInt32(elements.count + 8).bigEndian
withUnsafeBytes(of: &length) { icns.append(contentsOf: $0) }
icns.append(elements)
try icns.write(to: root.appending(path: "Config/Utter.icns"))
let docs = root.appending(path: "docs")
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
let gif = docs.appending(path: "dictation-flow.gif")
guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil) else {
    throw NSError(domain: "UtterArtwork", code: 4)
}
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for label in ["Hold Fn · Speak naturally", "Release · Processing on device", "Your words appear at the cursor"] {
    let context = try bitmap(760, height: 160)
    context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 760, height: 160))
    context.setFillColor(CGColor(red: 0.36, green: 0.34, blue: 0.91, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 20, y: 20, width: 720, height: 120), cornerWidth: 30, cornerHeight: 30, transform: nil))
    context.fillPath()
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 30, nil)
    let text = NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                             NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
    context.textPosition = CGPoint(x: 50, y: 70)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    if let image = context.makeImage() {
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.1]] as CFDictionary)
    }
}
guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "UtterArtwork", code: 5) }
