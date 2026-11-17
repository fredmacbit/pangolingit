#!/usr/bin/env swift
// Generates every PangolinGit icon asset from the master artwork (images/icon.jpg):
//   • PangolinGit/Assets.xcassets/AppIcon.appiconset   app icon (Dock, Finder, About box, Settings)
//   • PangolinGitFinder/Assets.xcassets/MenuIcon.imageset   icon on Finder's "PangolinGit" submenu
//   • installer/resources/background*.png                 Installer window artwork
//
// The artwork is a rendered tile on a grey backdrop, so the tile is cropped just inside its frame,
// masked with a continuous rounded rectangle and placed on Apple's 824-on-1024 icon grid.
//
// Usage (from the repository root):  swift tools/generate_icons.swift [path/to/artwork]
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "images/icon.jpg", relativeTo: root)

/// Tile bounds in the 1024×1024 artwork (measured just inside the outer frame).
let tileRect = CGRect(x: 151, y: 151, width: 722, height: 722)

guard let source = NSImage(contentsOf: sourceURL),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read \(sourceURL.path)")
}
let scale = CGFloat(sourceCG.width) / 1024
let cropped = sourceCG.cropping(to: CGRect(x: tileRect.minX * scale, y: tileRect.minY * scale,
                                           width: tileRect.width * scale, height: tileRect.height * scale))!

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

/// Continuous-corner ("squircle") rounded rectangle like macOS app icons.
func iconShape(in rect: CGRect) -> CGPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    return path.cgPath
}

/// Masked tile on a transparent canvas of `pixels`², following the 824/1024 icon grid.
func renderIcon(pixels: Int) -> CGImage {
    let ctx = makeContext(pixels, pixels)
    let size = CGFloat(pixels)
    let inset = size * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    // Soft drop shadow, as in Apple's icon template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 10 / 1024), blur: size * 20 / 1024,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(iconShape(in: tile))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(iconShape(in: tile))
    ctx.clip()
    ctx.draw(cropped, in: tile)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

// MARK: App icon set

let appIconSet = root.appendingPathComponent("PangolinGit/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let file = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        writePNG(renderIcon(pixels: points * factor), to: appIconSet.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(factor)x", "filename": file])
    }
}
writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: appIconSet.appendingPathComponent("Contents.json"))

// MARK: Finder submenu icon (16 pt)

let menuIconSet = root.appendingPathComponent("PangolinGitFinder/Assets.xcassets/MenuIcon.imageset")
writePNG(renderIcon(pixels: 16), to: menuIconSet.appendingPathComponent("menu_icon.png"))
writePNG(renderIcon(pixels: 32), to: menuIconSet.appendingPathComponent("menu_icon@2x.png"))
writeJSON([
    "images": [
        ["idiom": "mac", "scale": "1x", "filename": "menu_icon.png"],
        ["idiom": "mac", "scale": "2x", "filename": "menu_icon@2x.png"]
    ],
    "info": ["author": "xcode", "version": 1]
], to: menuIconSet.appendingPathComponent("Contents.json"))

// MARK: Installer background (icon in the lower-left of the sidebar)

for (name, factor) in [("background.png", 1), ("background@2x.png", 2)] {
    // Installer's window is 620×418 pt; the background is drawn unscaled from the bottom-left.
    let width = 620 * factor, height = 418 * factor
    let ctx = makeContext(width, height)
    let iconSide = CGFloat(150 * factor)
    let icon = renderIcon(pixels: Int(iconSide))
    ctx.setAlpha(0.9)
    ctx.draw(icon, in: CGRect(x: CGFloat(18 * factor), y: CGFloat(16 * factor), width: iconSide, height: iconSide))
    writePNG(ctx.makeImage()!, to: root.appendingPathComponent("installer/resources/\(name)"))
}
