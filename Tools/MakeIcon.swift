import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let icons = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
 let size = points * scale
 guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
       let context = NSGraphicsContext(bitmapImageRep:rep) else { fatalError() }
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = context
 let factor = CGFloat(size) / 1024
 let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
 NSColor(srgbRed: 0.06, green: 0.43, blue: 0.39, alpha: 1).setFill()
 NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 198, yRadius: 198).fill()
 NSColor(srgbRed: 0.81, green: 0.95, blue: 0.88, alpha: 1).setStroke()
 let wave = NSBezierPath(); wave.lineWidth = 39; wave.lineCapStyle = .round
 let heights: [CGFloat] = [90,160,235,122,196]
 for (i,h) in heights.enumerated() { let x = 265 + CGFloat(i)*77; wave.move(to: NSPoint(x: x,y: 550-h/2)); wave.line(to: NSPoint(x: x,y:550+h/2)) }
 wave.stroke()
 let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:118,weight:.semibold),.foregroundColor:NSColor.white]
 ("EN 译" as NSString).draw(at:NSPoint(x:275,y:240),withAttributes:attrs)
 NSGraphicsContext.restoreGraphicsState()
 guard let png=rep.representation(using:.png,properties:[:]) else { fatalError() }
 let name="icon_\(points)x\(points)\(scale==2 ? "@2x" : "").png"
 try png.write(to:icons.appendingPathComponent(name))
}
