// 목적: 제공된 앱 SVG의 macOS ICNS 변환
// 이용처: 앱 아이콘 교체 및 패키징 전 자산 갱신
// 사용방법: swift scripts/generate_app_icon.swift SOURCE.svg OUTPUT.icns
import AppKit

/// 원본 SVG를 표준 아이콘 크기로 렌더링하고 ICNS 생성
func generateIcon(source: URL, output: URL) throws {
    guard let image = NSImage(contentsOf: source) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "원본 SVG 로드 실패"])
    }
    let manager = FileManager.default
    let work = manager.temporaryDirectory.appendingPathComponent("codex-app-icon-\(UUID().uuidString)")
    let iconset = work.appendingPathComponent("AppIcon.iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: work) }
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "AppIcon", code: 2)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                       from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "AppIcon", code: 3)
            }
            let suffix = scale == 2 ? "@2x" : ""
            try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", output.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "AppIcon", code: Int(process.terminationStatus))
    }
    print("Generated \(output.path)")
}

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/generate_app_icon.swift SOURCE.svg OUTPUT.icns")
}
try generateIcon(source: URL(fileURLWithPath: CommandLine.arguments[1]),
                 output: URL(fileURLWithPath: CommandLine.arguments[2]))
