import AppKit
let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220).fill()
let circleRect = NSRect(x: 112, y: 112, width: 800, height: 800)
NSColor(calibratedRed: 0.18, green: 0.70, blue: 0.43, alpha: 1).setFill()
NSBezierPath(ovalIn: circleRect).fill()
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .black)
if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolRect = NSRect(x: 260, y: 260, width: 504, height: 504)
    symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
}
NSColor.systemRed.setFill()
NSBezierPath(ovalIn: NSRect(x: 714, y: 714, width: 170, height: 170)).fill()
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
try png.write(to: URL(fileURLWithPath: outputPath))
