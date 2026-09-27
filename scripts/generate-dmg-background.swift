#!/usr/bin/env swift
// Renders Resources/dmg/background.png (+@2x) for the release DMG: a plain, tasteful
// gradient tinted with AppIcon.icns's own average color, at 600x400 points.
// Run with no arguments: swift scripts/generate-dmg-background.swift

import AppKit

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconURL = root.appendingPathComponent("Resources/AppIcon.icns")
let outDir = root.appendingPathComponent("Resources/dmg")

guard let icon = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write("Could not load \(iconURL.path)\n".data(using: .utf8)!)
    exit(1)
}

/// Average color of the icon's opaque pixels, used to tint the background.
func averageColor(of image: NSImage) -> NSColor {
    let size = 32
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return NSColor(red: 0.5, green: 0.55, blue: 0.9, alpha: 1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    var (r, g, b, weight): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    for x in 0..<size {
        for y in 0..<size {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let a = c.alphaComponent
            r += c.redComponent * a; g += c.greenComponent * a; b += c.blueComponent * a
            weight += a
        }
    }
    guard weight > 0 else { return NSColor(red: 0.5, green: 0.55, blue: 0.9, alpha: 1) }
    return NSColor(red: r / weight, green: g / weight, blue: b / weight, alpha: 1)
}

/// Blend towards white so the tint stays subtle on a mostly-white background.
func lighten(_ color: NSColor, by amount: CGFloat) -> NSColor {
    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    return NSColor(
        red: color.redComponent + (white.redComponent - color.redComponent) * amount,
        green: color.greenComponent + (white.greenComponent - color.greenComponent) * amount,
        blue: color.blueComponent + (white.blueComponent - color.blueComponent) * amount,
        alpha: 1
    )
}

let tint = averageColor(of: icon)
let top = lighten(tint, by: 0.72)
let bottom = NSColor(white: 0.99, alpha: 1)

/// Renders straight into a pixel-exact bitmap: lockFocus on an NSImage would instead
/// scale by the current screen's backing factor, which isn't what we want here.
func renderBackground(pointSize: NSSize, scale: CGFloat) -> NSBitmapImageRep {
    let width = Int(pointSize.width * scale)
    let height = Int(pointSize.height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let gradient = NSGradient(starting: top, ending: bottom)
    gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Could not encode \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
    try? data.write(to: url)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let pointSize = NSSize(width: 600, height: 400)
writePNG(renderBackground(pointSize: pointSize, scale: 1), to: outDir.appendingPathComponent("background.png"))
writePNG(renderBackground(pointSize: pointSize, scale: 2), to: outDir.appendingPathComponent("background@2x.png"))
print("Wrote \(outDir.path)/background.png and background@2x.png")
