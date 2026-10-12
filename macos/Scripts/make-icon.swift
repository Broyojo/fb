#!/usr/bin/env swift
import AppKit
import Foundation

// Resize the generated master without altering its artwork or transparency.
let macDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = macDirectory.appendingPathComponent("Artwork/fb-icon.png")
let assets = macDirectory.appendingPathComponent("App/Assets.xcassets", isDirectory: true)
let destination = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
guard let image = NSImage(contentsOf: source) else {
    fatalError("Missing icon master: \(source.path)")
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Cannot allocate icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode icon bitmap")
        }
        try data.write(to: destination.appendingPathComponent(filename), options: .atomic)
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": entries, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"), options: .atomic)
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: assets.appendingPathComponent("Contents.json"), options: .atomic)
print("Generated \(entries.count) macOS icon sizes from \(source.lastPathComponent)")
