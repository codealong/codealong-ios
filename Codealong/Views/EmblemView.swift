import SwiftUI

/// A session's emblem beside its title, as the Mac draws one (its primitives.tsx
/// `SessionEmblem`): the icon Jev picked for what it works on, on a radial gradient of its two
/// colors, the accent where its light falls and its main color over the rest, so sessions side by
/// side read apart and one is remembered as "the teal bug". Its icons and colors are the Mac's
/// own (scripts/build-emblems.sh). It says nothing its row doesn't, so VoiceOver passes over it.
/// Nothing for an icon this build doesn't have.
struct EmblemView: View {
    let emblem: Emblem
    let size: CGFloat
    /// Sized with the text beside it.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        if UIImage(named: icon) != nil {
            let side = size * scale
            let color = Color("emblem-\(emblem.color)")
            let accent = Color("emblem-\(emblem.accent)")
            let light = UnitPoint(x: CGFloat(emblem.lightX), y: CGFloat(emblem.lightY))
            // To the corner farthest from the light, as the Mac's `circle at` gradient goes.
            let reach = side * hypot(max(light.x, 1 - light.x), max(light.y, 1 - light.y))
            Image(icon)
                .resizable()
                .frame(width: (side * 0.7).rounded(), height: (side * 0.7).rounded())
                .foregroundStyle(color.mix(with: Color("emblem-ink"), by: 0.5, in: .device))
                .frame(width: side, height: side)
                .background(
                    RadialGradient(
                        stops: [
                            .init(color: accent.opacity(0.66), location: 0),
                            .init(color: accent.opacity(0.4), location: 0.36),
                            .init(color: color.opacity(0.42), location: 0.7),
                            .init(color: color.opacity(0.58), location: 1),
                        ],
                        center: light, startRadius: 0, endRadius: reach),
                    in: .rect(cornerRadius: side * 0.32)
                )
                .accessibilityHidden(true)
        }
    }

    private var icon: String { "emblem-icon-\(emblem.icon)" }
}

extension View {
    /// Lines an emblem up on the middle of the capitals of the text in a stack aligned on its
    /// first baseline, where it would otherwise stand on the baseline.
    func onCapitals(of style: UIFont.TextStyle) -> some View {
        alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + UIFont.preferredFont(forTextStyle: style).capHeight / 2 }
    }
}
