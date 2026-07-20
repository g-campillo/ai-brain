// Renders the Brain.app icon layers (neural constellation) as transparent PNGs.
// Usage: swift render-layers.swift <assetsDir> [previewDir]
//   assetsDir:  receives edges.png and nodes.png (1024x1024, transparent)
//   previewDir: optional; receives composite.png (art over the navy background)
import Foundation
import CoreGraphics
import ImageIO

let size = 1024
// Geometry is authored y-down (screen-like); the context is flipped once below.
// Brain in left-facing profile: frontal lobe left, occipital right,
// cerebellum bump lower right, Sylvian-fissure arc through the interior.
struct Node { let x: CGFloat; let y: CGFloat; let r: CGFloat }
let L: CGFloat = 30, M: CGFloat = 20, S: CGFloat = 13
// Outline traced from brain-profile landmarks (facing left), as fractions of a
// bounding box mapped to x 250-780, y 265-715: forehead, dome, occipital pole,
// cerebellum bump, brainstem low point, temporal underside.
let frac: [(CGFloat, CGFloat, CGFloat)] = [
    (0.02, 0.44, L),  //  0 frontal pole
    (0.09, 0.17, S),  //  1 forehead
    (0.30, 0.01, M),  //  2 crown front
    (0.52, 0.00, L),  //  3 crown
    (0.74, 0.10, S),  //  4 parietal rear
    (0.93, 0.28, M),  //  5 occipital upper
    (1.00, 0.48, L),  //  6 occipital pole
    (0.93, 0.66, S),  //  7 occipital lower
    (0.86, 0.82, M),  //  8 cerebellum
    (0.68, 0.94, S),  //  9 cerebellum bottom
    (0.56, 0.99, S),  // 10 brainstem
    (0.44, 0.80, S),  // 11 underside notch
    (0.22, 0.74, M),  // 12 temporal pole
    (0.05, 0.58, S),  // 13 front lower
    (0.40, 0.36, M),  // 14 front hub
    (0.68, 0.40, L),  // 15 rear hub
    (0.30, 0.58, S),  // 16 fissure
]
let nodes: [Node] = frac.map { Node(x: 250 + $0.0 * 530, y: 265 + $0.1 * 450, r: $0.2) }
let edges: [(Int, Int)] = [
    // silhouette ring
    (0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7),
    (7, 8), (8, 9), (9, 10), (10, 11), (11, 12), (12, 13), (13, 0),
    // interior: two hubs + Sylvian-fissure sweep, no crossings
    (14, 15), (2, 14), (14, 0), (3, 15), (15, 6), (12, 16), (16, 15),
]

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}
let edgeColor = color(0.180, 0.490, 0.541, 0.60)          // #2E7D8A dim teal
let haloOuter = color(0.310, 0.839, 0.769, 0.0)           // #4FD6C4 -> transparent
let haloInner = color(0.310, 0.839, 0.769, 0.35)
let coreStops: [(CGFloat, CGColor)] = [
    (0.00, color(0.949, 0.992, 1.0, 1)),                  // near-white hot center
    (0.45, color(0.482, 0.910, 1.0, 1)),                  // #7BE8FF cyan
    (1.00, color(0.184, 0.722, 0.690, 1)),                // teal rim
]

func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)  // author coords are y-down
    return ctx
}

func writePNG(_ ctx: CGContext, to url: URL) {
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed: \(url.path)") }
}

func drawEdges(_ ctx: CGContext) {
    ctx.setStrokeColor(edgeColor)
    ctx.setLineWidth(12)
    ctx.setLineCap(.round)
    for (a, b) in edges {
        let na = nodes[a], nb = nodes[b]
        let dx = nb.x - na.x, dy = nb.y - na.y
        let len = (dx * dx + dy * dy).squareRoot()
        // trim so lines stop short of the glowing cores (constellation-chart gap)
        let ta = (na.r + 8) / len, tb = (nb.r + 8) / len
        ctx.move(to: CGPoint(x: na.x + dx * ta, y: na.y + dy * ta))
        ctx.addLine(to: CGPoint(x: nb.x - dx * tb, y: nb.y - dy * tb))
        ctx.strokePath()
    }
}

func drawNodes(_ ctx: CGContext) {
    for n in nodes {
        let c = CGPoint(x: n.x, y: n.y)
        // halo
        let halo = CGGradient(colorsSpace: srgb, colors: [haloInner, haloOuter] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(halo, startCenter: c, startRadius: n.r * 0.6,
                               endCenter: c, endRadius: n.r * 2.6, options: [])
        // core
        let core = CGGradient(colorsSpace: srgb,
                              colors: coreStops.map { $0.1 } as CFArray,
                              locations: coreStops.map { $0.0 })!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: n.x - n.r, y: n.y - n.r, width: n.r * 2, height: n.r * 2))
        ctx.clip()
        ctx.drawRadialGradient(core,
                               startCenter: CGPoint(x: n.x - n.r * 0.25, y: n.y - n.r * 0.25),
                               startRadius: 0, endCenter: c, endRadius: n.r * 1.15, options: [])
        ctx.restoreGState()
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: swift render-layers.swift <assetsDir> [previewDir]") }
let assetsDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

let edgesCtx = makeContext()
drawEdges(edgesCtx)
writePNG(edgesCtx, to: assetsDir.appendingPathComponent("edges.png"))

let nodesCtx = makeContext()
drawNodes(nodesCtx)
writePNG(nodesCtx, to: assetsDir.appendingPathComponent("nodes.png"))

if args.count >= 3 {
    let previewDir = URL(fileURLWithPath: args[2], isDirectory: true)
    try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
    let ctx = makeContext()
    let bg = CGGradient(colorsSpace: srgb,
                        colors: [color(0.039, 0.086, 0.157, 1), color(0.063, 0.165, 0.263, 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: size), options: [])
    drawEdges(ctx)
    drawNodes(ctx)
    writePNG(ctx, to: previewDir.appendingPathComponent("composite.png"))
}
print("rendered \(nodes.count) nodes, \(edges.count) edges -> \(assetsDir.path)")
