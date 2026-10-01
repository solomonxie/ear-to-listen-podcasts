import SwiftUI

/// The cover for something nobody gave a picture: a gradient and pattern derived from its
/// id, with its name and speaker set on it like a printed sleeve. Below `monogramBelow`
/// points the words wouldn't be legible, so it shows initials instead.
struct GeneratedCover: View {
    enum Kind { case album, playlist }

    let seed: String
    let title: String
    var subtitle: String?
    var kind: Kind = .album
    var symbol: String?
    var tint: Color?

    private static let monogramBelow: CGFloat = 72

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let style = CoverStyle(seed: seed)
            ZStack(alignment: .bottomLeading) {
                Color.black
                LinearGradient(
                    colors: tint.map { [$0, $0.opacity(0.45)] } ?? [style.top, style.bottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Canvas { context, size in
                    switch kind {
                    case .album: style.drawMotif(in: &context, size: size)
                    case .playlist: CoverStyle.drawPlaylistBars(in: &context, size: size)
                    }
                }
                if side < Self.monogramBelow {
                    monogram(side: side)
                } else {
                    label(side: side)
                }
            }
        }
    }

    private func monogram(side: CGFloat) -> some View {
        Text(Self.initials(of: title))
            .font(.system(size: side * 0.38, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: side * 0.03) {
            if kind == .playlist {
                HStack(spacing: 4) {
                    if let symbol { Image(systemName: symbol) }
                    Text("Playlist").textCase(.uppercase).tracking(1.2)
                }
                .font(.system(size: max(9, side * 0.075), weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: side * 0.14, weight: .bold, design: .serif))
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            if let subtitle = subtitle?.nilIfEmpty {
                Text(subtitle)
                    .font(.system(size: max(9, side * 0.08), weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .padding(side * 0.09)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "♪" : String(letters).uppercased()
    }
}

/// Colours and pattern picked from a seed's stable hash, so the same album always wears
/// the same cover and neighbours on a shelf rarely match.
struct CoverStyle {
    let top: Color
    let bottom: Color
    private let motif: Int
    private let variant: Double

    init(seed: String) {
        let hash = LibraryArt.stableHash(seed)
        let hue = Double(hash % 360) / 360
        let shift = Double((hash / 360) % 60 + 20) / 360
        top = Color(hue: hue, saturation: 0.55, brightness: 0.62)
        bottom = Color(hue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.28)
        motif = (hash / 21_600) % 4
        variant = Double((hash / 86_400) % 100) / 100
    }

    func drawMotif(in context: inout GraphicsContext, size: CGSize) {
        let ink = GraphicsContext.Shading.color(.white.opacity(0.12))
        let side = min(size.width, size.height)
        switch motif {
        case 0:
            let center = CGPoint(x: size.width * (0.7 + variant * 0.3), y: size.height * 0.15)
            for ring in 1...6 {
                let r = side * 0.16 * CGFloat(ring)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                               with: ink, lineWidth: side * 0.025)
            }
        case 1:
            var path = Path()
            let gap = side * (0.1 + variant * 0.06)
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += gap
            }
            context.stroke(path, with: ink, lineWidth: side * 0.03)
        case 2:
            let step = side * 0.12
            let dot = side * (0.025 + variant * 0.02)
            var y = step / 2
            while y < size.height * 0.6 {
                var x = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)), with: ink)
                    x += step
                }
                y += step
            }
        default:
            let bars = 14
            let width = size.width / CGFloat(bars)
            for i in 0..<bars {
                let wave = abs(sin(Double(i) * (0.7 + variant) + variant * 6))
                let height = size.height * (0.12 + 0.4 * wave)
                context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * width + width * 0.2, y: size.height * 0.05,
                                                      width: width * 0.6, height: height),
                                  cornerRadius: width * 0.3), with: ink)
            }
        }
    }

    /// A stack of track-like bars, so a playlist reads as a list rather than an album.
    static func drawPlaylistBars(in context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let barHeight = side * 0.07
        for i in 0..<4 {
            let inset = side * 0.09
            let width = (size.width - inset * 2) * (0.8 - CGFloat(i) * 0.12)
            let rect = CGRect(x: size.width - inset - width, y: side * 0.26 + CGFloat(i) * barHeight * 1.8,
                              width: width, height: barHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: barHeight / 2),
                         with: .color(.white.opacity(0.16 - Double(i) * 0.03)))
        }
    }
}
