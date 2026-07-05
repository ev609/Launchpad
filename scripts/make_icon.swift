#!/usr/bin/env swift
// Рисует иконку приложения (сетка 3×3 в стиле Launchpad) и сохраняет PNG 1024×1024.
// Использование: swift make_icon.swift <выходной_путь.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_master.png"
let size = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Не удалось создать bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let S = CGFloat(size)

// Скруглённый «квадрат» (squircle) как основа иконки.
let pad = S * 0.06
let bgRect = CGRect(x: pad, y: pad, width: S - 2 * pad, height: S - 2 * pad)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: S * 0.22, cornerHeight: S * 0.22, transform: nil)

// Градиентный фон.
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.28, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0),
                       options: [])
ctx.restoreGState()

// Сетка 3×3 разноцветных плиток.
let tileColors: [NSColor] = [
    NSColor(calibratedRed: 0.98, green: 0.31, blue: 0.28, alpha: 1), // красный
    NSColor(calibratedRed: 0.99, green: 0.70, blue: 0.18, alpha: 1), // оранжевый
    NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.36, alpha: 1), // зелёный
    NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.98, alpha: 1), // синий
    NSColor(calibratedRed: 0.62, green: 0.44, blue: 0.98, alpha: 1), // фиолетовый
    NSColor(calibratedRed: 0.98, green: 0.44, blue: 0.72, alpha: 1), // розовый
    NSColor(calibratedRed: 0.28, green: 0.80, blue: 0.80, alpha: 1), // бирюзовый
    NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.30, alpha: 1), // жёлтый
    NSColor(calibratedRed: 0.60, green: 0.65, blue: 0.72, alpha: 1), // серый
]

let inner = bgRect.insetBy(dx: S * 0.14, dy: S * 0.14)
let gap = inner.width * 0.10
let tile = (inner.width - 2 * gap) / 3

for row in 0..<3 {
    for col in 0..<3 {
        let x = inner.minX + CGFloat(col) * (tile + gap)
        // Верхний ряд рисуем сверху: инвертируем y (CoreGraphics — снизу вверх).
        let y = inner.minY + CGFloat(2 - row) * (tile + gap)
        let rect = CGRect(x: x, y: y, width: tile, height: tile)
        let path = CGPath(roundedRect: rect, cornerWidth: tile * 0.26, cornerHeight: tile * 0.26, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(tileColors[row * 3 + col].cgColor)
        ctx.fillPath()
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("Не удалось получить PNG")
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("Иконка сохранена: \(outPath)")
