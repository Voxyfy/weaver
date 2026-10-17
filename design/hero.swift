import AppKit
// README hero: black ground, one headline, a stylised Weaver layout (nested cells, Desktop cell, tab strip).
let W = 1800.0, H = 1000.0
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

let para = NSMutableParagraphStyle(); para.alignment = .center
NSAttributedString(string: "Windows that nest.", attributes: [
    .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para, .kern: -1.5
]).draw(in: NSRect(x: 0, y: H - 150, width: W, height: 90))
NSAttributedString(string: "Dock, nest, tab, resize, zoom. Your real windows, in a tree.", attributes: [
    .font: NSFont.systemFont(ofSize: 26, weight: .regular), .foregroundColor: NSColor(white: 0.62, alpha: 1), .paragraphStyle: para
]).draw(in: NSRect(x: 0, y: H - 200, width: W, height: 40))

// Screen
let screen = NSRect(x: 150, y: 70, width: 1500, height: 640)
let gap = 14.0
func cell(_ r: NSRect, fill: NSColor, title: String?, tabs: [String]? = nil, active: Int = 0) {
    let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
    NSGraphicsContext.current!.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.55); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6); sh.set()
    fill.setFill(); path.fill()
    NSGraphicsContext.current!.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.09).setStroke(); path.lineWidth = 1; path.stroke()
    // title bar
    var y = r.maxY - 36
    if let tabs {
        let strip = NSRect(x: r.minX, y: r.maxY - 40, width: r.width, height: 40)
        NSColor(white: 1, alpha: 0.06).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 14, yRadius: 14).fill()
        let w = min(180.0, (r.width - 40) / Double(tabs.count) - 8)
        var x = r.midX - (w * Double(tabs.count) + 8 * Double(tabs.count - 1)) / 2
        for (i, t) in tabs.enumerated() {
            let chip = NSRect(x: x, y: r.maxY - 33, width: w, height: 26)
            if i == active { NSColor(white: 1, alpha: 0.16).setFill(); NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill() }
            NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: i == active ? .semibold : .regular),
                .foregroundColor: NSColor(white: 1, alpha: i == active ? 0.95 : 0.55), .paragraphStyle: para]).draw(in: chip.insetBy(dx: 6, dy: 5))
            x += w + 8
        }
        y = r.maxY - 76
    }
    for (i, c) in [NSColor(calibratedRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(calibratedRed: 1, green: 0.74, blue: 0.2, alpha: 1), NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.36, alpha: 1)].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 16 + Double(i) * 18, y: y + 10, width: 11, height: 11)).fill()
    }
    if let title {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.7)])
            .draw(at: NSPoint(x: r.minX + 80, y: y + 7))
    }
    // content lines
    var ly = y - 26
    var seed = Int(r.width) % 7
    while ly > r.minY + 24 {
        let len = [0.55, 0.8, 0.4, 0.7, 0.3, 0.9, 0.6][seed % 7] * (r.width - 48)
        NSColor(white: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 24, y: ly, width: len, height: 8), xRadius: 4, yRadius: 4).fill()
        ly -= 22; seed += 1
    }
}
let dark = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
let darker = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)

// Layout: [ editor | Desktop | V(browser / tabs) ]
let left = NSRect(x: screen.minX, y: screen.minY, width: 520, height: screen.height)
let deskW = 300.0
let desk = NSRect(x: left.maxX + gap, y: screen.minY, width: deskW, height: screen.height)
let rightX = desk.maxX + gap
let rightW = screen.maxX - rightX
let topH = (screen.height - gap) * 0.55
let rtop = NSRect(x: rightX, y: screen.maxY - topH, width: rightW, height: topH)
let rbot = NSRect(x: rightX, y: screen.minY, width: rightW, height: screen.height - topH - gap)

cell(left, fill: dark, title: "web.php — editor")
// Desktop cell: wallpaper gradient + two small floating windows scaled down
let deskPath = NSBezierPath(roundedRect: desk, xRadius: 14, yRadius: 14)
NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.14, alpha: 1)])!.draw(in: deskPath, angle: -70)
cell(NSRect(x: desk.minX + 24, y: desk.maxY - 220, width: 200, height: 150), fill: darker, title: "Notes")
cell(NSRect(x: desk.minX + 70, y: desk.minY + 60, width: 190, height: 140), fill: darker, title: "Music")
cell(rtop, fill: dark, title: nil, tabs: ["Browser", "Docs", "Terminal"], active: 0)
cell(rbot, fill: dark, title: "Changes — git")

// seam handles
NSColor(white: 1, alpha: 0.85).setFill()
for x in [left.maxX + gap / 2, desk.maxX + gap / 2] {
    NSBezierPath(roundedRect: NSRect(x: x - 2, y: screen.midY - 18, width: 4, height: 36), xRadius: 2, yRadius: 2).fill()
}
NSBezierPath(roundedRect: NSRect(x: rtop.midX - 18, y: rtop.minY - gap / 2 - 2, width: 36, height: 4), xRadius: 2, yRadius: 2).fill()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("hero written")
