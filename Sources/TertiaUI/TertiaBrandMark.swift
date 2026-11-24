import AppKit
import SwiftUI

/// Native SwiftUI vector shape matching Tertia Club's trefoil knot (`viewBox="-330 -300 660 600"`).
public struct TertiaKnotShape: Shape {
    private static let svgPath = "M-1 -295.5 L34 -267.5 L63 -237.5 L85 -209.5 L112 -165.5 L128 -129.5 L140 -91.5 L147 -55.5 L150 -20.5 L186 4.5 L225 39.5 L257 78.5 L275 106.5 L294 144.5 L307 179.5 L318 222.5 L323 253.5 L322 255.5 L281 273.5 L241 285.5 L195 293.5 L146 295.5 L105 291.5 L67 282.5 L32 269.5 L0 252.5 L-33 270.5 L-72 284.5 L-116 293.5 L-141 295.5 L-169 295.5 L-211 291.5 L-249 283.5 L-284 272.5 L-323 254.5 L-320 229.5 L-309 183.5 L-297 149.5 L-277 108.5 L-252 70.5 L-234 48.5 L-197 12.5 L-172 -6.5 L-151 -19.5 L-147 -61.5 L-139 -98.5 L-124 -141.5 L-108 -174.5 L-86 -209.5 L-63 -238.5 L-36 -266.5 Z M-1 -225.5 L29 -195.5 L49 -169.5 L62 -148.5 L73 -126.5 L83 -101.5 L91 -72.5 L96 -40.5 L97 -5.5 L95 17.5 L91 39.5 L81 73.5 L69 100.5 L50 131.5 L29 157.5 L10 175.5 L30 190.5 L48 200.5 L64 184.5 L86 156.5 L101 132.5 L114 106.5 L125 76.5 L132 49.5 L136 24.5 L138 -2.5 L137 -38.5 L135 -55.5 L130 -82.5 L120 -116.5 L112 -137.5 L95 -171.5 L76 -201.5 L63 -218.5 L30 -254.5 L0 -280.5 L-34 -251.5 L-53 -231.5 L-71 -209.5 L-90 -181.5 L-106 -152.5 L-118 -124.5 L-128 -93.5 L-136 -54.5 L-138 -27.5 L-137 -26.5 L-122 -34.5 L-96 -44.5 L-93 -66.5 L-87 -91.5 L-77 -119.5 L-65 -144.5 L-39 -184.5 L-21 -205.5 Z M-17 -59.5 L29 -58.5 L51 -55.5 L79 -48.5 L83 -49.5 L79 -71.5 L70 -102.5 L51 -143.5 L28 -177.5 L0 -208.5 L-9 -200.5 L-29 -177.5 L-54 -139.5 L-70 -104.5 L-76 -86.5 L-83 -54.5 L-83 -49.5 L-80 -48.5 L-58 -54.5 Z M-14 -6.5 L13 -6.5 L40 -3.5 L66 2.5 L83 8.5 L85 -4.5 L85 -24.5 L83 -35.5 L50 -43.5 L18 -47.5 L-18 -47.5 L-57 -42.5 L-100 -30.5 L-136 -14.5 L-167 4.5 L-196 27.5 L-226 57.5 L-236 69.5 L-255 95.5 L-271 122.5 L-284 149.5 L-298 188.5 L-305 215.5 L-310 247.5 L-279 261.5 L-244 272.5 L-210 279.5 L-169 283.5 L-127 282.5 L-89 276.5 L-50 264.5 L-14 247.5 L-12 245.5 L-14 243.5 L-34 229.5 L-50 215.5 L-59 220.5 L-85 229.5 L-112 235.5 L-140 238.5 L-170 238.5 L-198 235.5 L-232 228.5 L-259 219.5 L-246 172.5 L-230 136.5 L-205 97.5 L-190 79.5 L-171 60.5 L-136 33.5 L-121 24.5 L-94 11.5 L-56 -0.5 Z M81 24.5 L82 21.5 L80 19.5 L61 13.5 L39 8.5 L13 5.5 L-13 5.5 L-40 8.5 L-69 15.5 L-82 21.5 L-79 40.5 L-70 69.5 L-55 101.5 L-35 131.5 L-2 166.5 L1 167.5 L20 149.5 L38 127.5 L53 104.5 L69 71.5 L76 50.5 Z M-61 207.5 L-60 205.5 L-75 190.5 L-94 166.5 L-115 132.5 L-131 97.5 L-137 80.5 L-143 55.5 L-145 54.5 L-163 69.5 L-181 87.5 L-196 105.5 L-211 127.5 L-230 164.5 L-245 210.5 L-241 213.5 L-227 217.5 L-198 223.5 L-170 226.5 L-139 226.5 L-98 220.5 L-74 213.5 Z M241 212.5 L243 212.5 L244 209.5 L234 176.5 L225 154.5 L211 128.5 L199 110.5 L182 89.5 L161 68.5 L143 54.5 L129 101.5 L112 137.5 L83 180.5 L60 205.5 L74 212.5 L93 218.5 L116 223.5 L144 226.5 L169 226.5 L198 223.5 L230 216.5 Z M309 247.5 L310 245.5 L303 209.5 L290 166.5 L281 144.5 L260 104.5 L240 75.5 L214 45.5 L187 20.5 L152 -4.5 L149 -1.5 L149 14.5 L146 41.5 L169 59.5 L192 82.5 L208 102.5 L220 120.5 L243 166.5 L258 216.5 L258 219.5 L245 224.5 L205 234.5 L168 238.5 L145 238.5 L116 235.5 L78 226.5 L55 217.5 L37 208.5 L10 191.5 L-11 174.5 L-33 152.5 L-52 128.5 L-69 100.5 L-78 81.5 L-87 56.5 L-93 32.5 L-93 27.5 L-95 25.5 L-116 35.5 L-133 46.5 L-126 75.5 L-114 107.5 L-98 138.5 L-76 170.5 L-55 194.5 L-31 216.5 L-1 238.5 L30 255.5 L51 264.5 L91 276.5 L129 282.5 L168 283.5 L203 280.5 L247 271.5 L284 259.5 Z"
    private static let commands: [PathCommand] = parsePath(svgPath)
    private enum PathCommand: Sendable { case move(CGPoint), line(CGPoint), close }

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 660.0, rect.height / 600.0)
        return Self.commands.reduce(into: Path()) { p, cmd in
            switch cmd {
            case .move(let pt): p.move(to: CGPoint(x: rect.midX + pt.x * scale, y: rect.midY + pt.y * scale))
            case .line(let pt): p.addLine(to: CGPoint(x: rect.midX + pt.x * scale, y: rect.midY + pt.y * scale))
            case .close: p.closeSubpath()
            }
        }
    }

    private static func parsePath(_ raw: String) -> [PathCommand] {
        let tokens = raw.split(separator: " ")
        var out: [PathCommand] = []; var idx = 0
        while idx < tokens.count {
            let tok = tokens[idx]
            if tok == "Z" { out.append(.close); idx += 1 }
            else if (tok.hasPrefix("M") || tok.hasPrefix("L")), idx + 1 < tokens.count,
                    let x = Double(tok.dropFirst()), let y = Double(tokens[idx + 1]) {
                out.append(tok.hasPrefix("M") ? .move(CGPoint(x: x, y: y)) : .line(CGPoint(x: x, y: y))); idx += 2
            } else { idx += 1 }
        }
        return out
    }
}

public struct TertiaBrandMark: View {
    public let size: CGFloat
    public let color: Color

    public init(size: CGFloat = 18, color: Color) { self.size = size; self.color = color }

    public var body: some View {
        let strokeWidth = min(max(size * 0.032, 0.48), 0.62)
        ZStack {
            TertiaKnotShape().fill(color, style: FillStyle(eoFill: true))
            TertiaKnotShape().stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size * 1.1, height: size)
    }
}

public struct TertiaWordmarkView: View {
    public let palette: TertiaPalette
    public let compact: Bool

    public init(palette: TertiaPalette, compact: Bool = false) { self.palette = palette; self.compact = compact }

    public var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            TertiaBrandMark(size: compact ? 15 : 18, color: palette.ink)
            Text("TERTIA").font(.system(size: compact ? 12.5 : 15, weight: .regular, design: .serif)).tracking(0.5).foregroundStyle(palette.ink)
            Rectangle().fill(palette.border).frame(width: 1, height: compact ? 10 : 12)
            Text("LONDON").font(.system(size: compact ? 8.5 : 9.5, weight: .medium, design: .monospaced)).tracking(2.0).foregroundStyle(palette.muted)
        }
    }
}

@MainActor
public func makeTertiaMenuBarImage(pointSize: CGFloat = 17) -> NSImage {
    let renderer = ImageRenderer(content: TertiaBrandMark(size: pointSize, color: .black).frame(width: pointSize + 3, height: pointSize + 1))
    renderer.scale = 2.0
    let img = renderer.nsImage ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
    img.isTemplate = true
    return img
}
