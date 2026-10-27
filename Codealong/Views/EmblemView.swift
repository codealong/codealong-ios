import SwiftUI

/// A session's emblem beside its title, as its Mac gives it (the Mac's primitives.tsx
/// `SessionEmblem`): an emoji Jev picked for what it works on, or a small picture an account drew,
/// read from the session's Mac once and kept (`Store.image`), so sessions side by side read apart
/// and one is remembered as "the dinosaur". Its emoji, when it has one, shows while the picture is
/// on its way and when its Mac can't send it, and the picture is asked for again once that Mac
/// connects. It says nothing its row doesn't, so VoiceOver passes over it.
struct EmblemView: View {
    let emblem: Emblem
    /// The Mac the session is on, which keeps its picture.
    let mac: String
    let size: CGFloat
    /// Sized with the text beside it.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(Store.self) private var store
    @State private var picture: UIImage?
    /// Where `picture` is kept on its Mac: a new one for the session is read in its place.
    @State private var pictureOf: String?
    /// Its Mac couldn't send the picture the last time it was asked.
    @State private var failed = false

    private var online: Bool { store.devices.contains { $0.key == mac && $0.online } }

    var body: some View {
        let side = size * scale
        Group {
            if let picture, pictureOf == emblem.picture {
                Image(uiImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
            } else if let emoji = emblem.emoji {
                Text(emoji)
                    .font(.system(size: (side * 0.86).rounded()))
                    .frame(width: side, height: side)
            } else {
                // Its room while the picture comes, none once it hasn't: the view stays, so the
                // picture is asked for again when its Mac connects.
                Color.clear.frame(width: failed ? 0 : side, height: side)
            }
        }
        .accessibilityHidden(true)
        .task(id: "\(emblem.picture ?? "") \(online)") {
            guard let path = emblem.picture else {
                (picture, pictureOf) = (nil, nil)
                return
            }
            // One kept from before shows at once; one its Mac couldn't send is asked for again
            // only once that Mac is here.
            guard picture == nil || pictureOf != path else { return }
            let read = await store.image(mac: mac, path: path)
            // The cache reads on after this task is cancelled, as a row comes to show another
            // session: what it brings late isn't this one's any more.
            guard !Task.isCancelled else { return }
            (picture, pictureOf, failed) = (read, path, read == nil)
        }
    }
}

extension View {
    /// Lines an emblem up on the middle of the capitals of the text in a stack aligned on its
    /// first baseline, where it would otherwise stand on the baseline.
    func onCapitals(of style: UIFont.TextStyle) -> some View {
        alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + UIFont.preferredFont(forTextStyle: style).capHeight / 2 }
    }
}
