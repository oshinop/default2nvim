import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let glyph = NSImage(contentsOfFile: arguments[2]) else {
    exit(1)
}

guard let baseData = try? Data(contentsOf: URL(fileURLWithPath: arguments[1])),
      let baseRepresentation = NSBitmapImageRep(data: baseData) else {
    exit(1)
}
let canvasSize = NSSize(width: baseRepresentation.pixelsWide, height: baseRepresentation.pixelsHigh)
guard canvasSize.width > 0, canvasSize.height > 0 else {
    exit(1)
}

let canvas = NSImage(size: canvasSize)
canvas.addRepresentation(baseRepresentation)
canvas.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let glyphSide = (min(canvasSize.width, canvasSize.height) * 0.45).rounded()
glyph.draw(
    in: NSRect(
        x: (canvasSize.width - glyphSide) / 2,
        y: (canvasSize.height - glyphSide) / 2 - canvasSize.height * 0.0732421875,
        width: glyphSide,
        height: glyphSide
    ),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: arguments[3]))
