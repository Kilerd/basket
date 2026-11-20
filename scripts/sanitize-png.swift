// Re-encodes a PNG as plain sRGB with no metadata (no ICC display profile naming the monitor,
// no XMP), optionally scaled to a maximum width. Usage: swift sanitize-png.swift <in> <out> [maxWidth]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: sanitize-png.swift <in.png> <out.png> [maxWidth]\n".utf8)); exit(64)
}
let maxWidth = args.count > 3 ? Int(args[3]) ?? cg.width : cg.width
let scale = min(1, Double(maxWidth) / Double(cg.width))
let width = Int((Double(cg.width) * scale).rounded()), height = Int((Double(cg.height) * scale).rounded())
guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
