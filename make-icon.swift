#!/usr/bin/env swift
//
// Draws Diptych's app icon straight into the asset catalog at
// Diptych/Assets.xcassets/AppIcon.appiconset. Run with:  swift make-icon.swift
//
// The mark is a diptych: two hinged panels. It has to survive being shrunk to
// 16pt in the Dock and the menu bar, so the panels are large, high-contrast
// blocks and the only fine detail (the ruled lines) is allowed to disappear.

import AppKit
import Foundation

let navyTop    = NSColor(srgbRed: 0.16, green: 0.18, blue: 0.36, alpha: 1)
let navyBottom = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.22, alpha: 1)
let panelLeft  = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
let panelRight = NSColor(srgbRed: 0.88, green: 0.87, blue: 0.83, alpha: 1)
let accent     = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.28, alpha: 1)
let rule       = NSColor(srgbRed: 0.55, green: 0.57, blue: 0.66, alpha: 1)

func icon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons do not fill their canvas; they sit on a rounded square with
    // padding around it, which is what makes them line up in the Dock.
    let inset = s * 0.085
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = NSBezierPath(roundedRect: body,
                                xRadius: body.width * 0.2237,
                                yRadius: body.width * 0.2237)

    NSGradient(colors: [navyTop, navyBottom])?.draw(in: bodyPath, angle: -90)

    // Two panels, hinged at the centre.
    let pad = body.width * 0.155
    let gap = body.width * 0.055
    let panelW = (body.width - 2 * pad - gap) / 2
    let panelH = body.height - 2 * pad
    let radius = max(1, panelW * 0.10)

    for (index, colour) in [panelLeft, panelRight].enumerated() {
        let x = body.minX + pad + CGFloat(index) * (panelW + gap)
        let frame = NSRect(x: x, y: body.minY + pad, width: panelW, height: panelH)
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        colour.setFill()
        path.fill()

        // Ruled lines standing in for a file listing. Skipped at sizes where
        // they would turn into mud.
        guard size >= 64 else { continue }
        let lineH = max(1, panelH * 0.045)
        let step = panelH * 0.135
        rule.withAlphaComponent(0.55).setFill()
        for row in 0..<4 {
            let y = frame.maxY - panelH * 0.16 - CGFloat(row) * step
            let width = frame.width * (row == 3 ? 0.42 : 0.66)
            NSBezierPath(roundedRect: NSRect(x: frame.minX + frame.width * 0.14,
                                             y: y, width: width, height: lineH),
                         xRadius: lineH / 2, yRadius: lineH / 2).fill()
        }
    }

    // The hinge: a thin accent bar in the gutter, which is what stops the two
    // panels reading as an unrelated pair of rectangles.
    let hinge = NSRect(x: body.midX - gap * 0.16, y: body.minY + pad + panelH * 0.30,
                       width: gap * 0.32, height: panelH * 0.40)
    accent.setFill()
    NSBezierPath(roundedRect: hinge, xRadius: hinge.width / 2, yRadius: hinge.width / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let catalog = URL(fileURLWithPath: "Diptych/Assets.xcassets")
let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

try #"{"info":{"author":"xcode","version":1}}"#
    .write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16),    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),    ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var entries: [String] = []
for variant in variants {
    let rep = icon(size: variant.px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))

    // "icon_32x32@2x" -> point size 32, scale 2x.
    let scale = variant.name.hasSuffix("@2x") ? "2x" : "1x"
    let points = variant.px / (scale == "2x" ? 2 : 1)
    entries.append("""
        {"idiom":"mac","scale":"\(scale)","size":"\(points)x\(points)","filename":"\(variant.name).png"}
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {"author":"xcode","version":1}
}
"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)

print("wrote \(variants.count) images to \(iconset.path)")
