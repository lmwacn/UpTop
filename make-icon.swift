import AppKit

func makeIconPNG(size: Int) -> Data {
    let canvas = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 64
    canvas.scaleBy(x: scale, y: scale)

    let background = CGRect(x: 5, y: 5, width: 54, height: 54)
    canvas.setFillColor(red: 0.08, green: 0.17, blue: 0.23, alpha: 1)
    canvas.addPath(CGPath(roundedRect: background, cornerWidth: 13, cornerHeight: 13, transform: nil))
    canvas.fillPath()

    canvas.setStrokeColor(red: 0.44, green: 0.95, blue: 0.80, alpha: 1)
    canvas.setLineWidth(4)
    canvas.setLineCap(.round)
    canvas.setLineJoin(.round)
    let waveform = [
        CGPoint(x: 14, y: 30), CGPoint(x: 23, y: 30), CGPoint(x: 28, y: 40),
        CGPoint(x: 35, y: 23), CGPoint(x: 40, y: 33), CGPoint(x: 50, y: 33)
    ]
    canvas.addLines(between: waveform)
    canvas.strokePath()

    let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

// ICNS 文件及各尺寸条目的长度都包含各自的 8 字节头。
func iconChunk(_ type: String, contents: Data) -> Data {
    var chunk = Data(type.utf8)
    var length = UInt32(contents.count + 8).bigEndian
    withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
    chunk.append(contents)
    return chunk
}

var representations = Data()
for (type, size) in [("icp5", 32), ("ic07", 128), ("ic08", 256)] {
    representations.append(iconChunk(type, contents: makeIconPNG(size: size)))
}
let icon = iconChunk("icns", contents: representations)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
