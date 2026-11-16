// Run from the repository root: swift scripts/generate-brand.swift
// Native vector artwork; the PDF mark and PNG icon share the same geometry.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let forest = CGColor(red: 0.12, green: 0.34, blue: 0.25, alpha: 1)
let cream = CGColor(red: 0.98, green: 0.96, blue: 0.88, alpha: 1)
func draw(_ context: CGContext, background: Bool) {
    if background {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.20, green: 0.44, blue: 0.34, alpha: 1), forest
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
    }
    context.saveGState()
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    let bubble = CGMutablePath()
    bubble.move(to: CGPoint(x: 512, y: 232))
    bubble.addCurve(to: CGPoint(x: 812, y: 474), control1: CGPoint(x: 711, y: 232), control2: CGPoint(x: 812, y: 316))
    bubble.addCurve(to: CGPoint(x: 526, y: 724), control1: CGPoint(x: 812, y: 634), control2: CGPoint(x: 715, y: 724))
    bubble.addCurve(to: CGPoint(x: 354, y: 788), control1: CGPoint(x: 459, y: 724), control2: CGPoint(x: 416, y: 788))
    bubble.addCurve(to: CGPoint(x: 330, y: 754), control1: CGPoint(x: 328, y: 788), control2: CGPoint(x: 319, y: 774))
    bubble.addCurve(to: CGPoint(x: 344, y: 694), control1: CGPoint(x: 344, y: 730), control2: CGPoint(x: 358, y: 708))
    bubble.addCurve(to: CGPoint(x: 212, y: 474), control1: CGPoint(x: 255, y: 654), control2: CGPoint(x: 212, y: 581))
    bubble.addCurve(to: CGPoint(x: 512, y: 232), control1: CGPoint(x: 212, y: 316), control2: CGPoint(x: 313, y: 232))
    bubble.closeSubpath()
    context.setFillColor(background ? cream : forest)
    context.addPath(bubble)
    context.fillPath()
    context.setFillColor(background ? forest : cream)
    for (x, y, height) in [(364.0, 432.0, 112.0), (476.0, 376.0, 224.0), (588.0, 410.0, 156.0)] {
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 72, height: height), cornerWidth: 36, cornerHeight: 36, transform: nil))
        context.fillPath()
    }
    context.restoreGState()
}
let bitmap = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
draw(bitmap, background: true)
let png = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: root.appendingPathComponent("VoiceApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
var box = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let pdf = CGContext(root.appendingPathComponent("VoiceApp/Assets.xcassets/MurmurMark.imageset/MurmurMark.pdf") as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
draw(pdf, background: false)
pdf.endPDFPage()
pdf.closePDF()
