#!/usr/bin/env swift
//
// make-icon.swift — renders Resources/AppIcon.icns from the sparkle glyph in
// Resources/AppIcon.icon (the macOS 26 Icon Composer format, which older
// macOS versions can't use). Run:  swift scripts/make-icon.swift
//

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let glyphURL = root.appendingPathComponent("Resources/AppIcon.icon/Assets/Path.png")
let outputURL = root.appendingPathComponent("Resources/AppIcon.icns")

guard let glyph = NSImage(contentsOf: glyphURL) else {
    fatalError("Could not load \(glyphURL.path)")
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 rounded square, centered, with a soft shadow.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset + s * 6 / 1024, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 8 / 1024), blur: s * 20 / 1024,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle white → light-gray tile gradient
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let tileGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [NSColor(white: 1.0, alpha: 1).cgColor,
                                           NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 1])!
    ctx.drawLinearGradient(tileGradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // Sparkle glyph filled with a Gemini-style gradient.
    let glyphSize = tile.width * 0.62
    let glyphRect = CGRect(x: tile.midX - glyphSize / 2, y: tile.midY - glyphSize / 2, width: glyphSize, height: glyphSize)

    guard let layerRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layerRep)
    let lctx = NSGraphicsContext.current!.cgContext
    let colors = [
        NSColor(calibratedRed: 0.106, green: 0.443, blue: 0.996, alpha: 1).cgColor, // blue
        NSColor(calibratedRed: 0.427, green: 0.408, blue: 0.937, alpha: 1).cgColor, // indigo
        NSColor(calibratedRed: 0.851, green: 0.396, blue: 0.439, alpha: 1).cgColor, // rose
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    // Draw the glyph's shape, then paint the gradient only where the glyph is opaque.
    // (The source glyph is slightly translucent; stacking it makes the fill solid.)
    for _ in 0..<3 { glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0) }
    lctx.setBlendMode(.sourceIn)
    lctx.clip(to: glyphRect)
    lctx.drawLinearGradient(gradient,
                            start: CGPoint(x: glyphRect.minX, y: glyphRect.minY),
                            end: CGPoint(x: glyphRect.maxX, y: glyphRect.maxY),
                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    layerRep.draw(in: CGRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: nil)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

if task.terminationStatus == 0 {
    print("Wrote \(outputURL.path)")
} else {
    fatalError("iconutil failed")
}
