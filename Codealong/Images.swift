import ImageIO
import SwiftUI
import UIKit

/// An image you attached to a reply, kept on the session's Mac as soon as it's picked, so it's
/// ready when you send (`Store.attach`): the reply refers to it as a paste into the Mac's box
/// does (`![image](images/<hash>.jpg)`), and the Mac turns that into the agent's way to the file.
/// One for a new session's prompt is held here until it starts (`Store.keep`), since the Mac it
/// starts on can change until then.
struct AttachedImage: Identifiable, Equatable {
    let id = UUID()
    let thumb: UIImage
    var state: State

    enum State: Equatable {
        /// On the phone, as it's sent, until the session it goes with starts.
        case held(jpeg: Data)
        case keeping
        /// How the reply refers to it.
        case kept(reference: String)
    }

    var reference: String? {
        if case .kept(let reference) = state { reference } else { nil }
    }

    /// An image held for a new session's prompt; nil for bytes that aren't one.
    static func held(_ data: Data) -> AttachedImage? {
        guard let prepared = ImagePrep.jpeg(data) else { return nil }
        return AttachedImage(thumb: ImagePrep.thumb(prepared.image), state: .held(jpeg: prepared.data))
    }
}

enum ImagePrep {
    /// The longest side an image is sent at: what Claude reads images at, and plenty for a
    /// screenshot's text. Smaller ones go as they are.
    static let longest: CGFloat = 1568

    /// An image as it's sent: JPEG, no bigger than `longest` on its longer side, on white where it
    /// was clear. Nil for bytes that aren't an image.
    static func jpeg(_ data: Data) -> (data: Data, image: UIImage)? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, longest / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = drawn.jpegData(compressionQuality: 0.8) else { return nil }
        return (jpeg, drawn)
    }

    /// What shows an attached image over the box it goes with.
    static func thumb(_ image: UIImage) -> UIImage {
        image.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? image
    }

    /// A prompt with images: each on a line of its own before what's written, as the Mac's box
    /// writes them.
    static func prompt(images: [String], text: String) -> String {
        (images + [text]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }

    /// Where a reference says its Mac keeps the image: `images/<hash>.<ext>`.
    static func path(of reference: String) -> String? {
        guard let open = reference.range(of: "](images/"), reference.hasSuffix(")") else { return nil }
        return String(reference[reference.index(open.lowerBound, offsetBy: 2)..<reference.index(before: reference.endIndex)])
    }
}

/// The images Macs keep for prompts, as read from them: by path, which is named by the image's
/// bytes, so one never changes. Kept on disk in Caches, which iOS may clear, and in memory while
/// the app runs at no more than `ImageCache.shown` pixels on a side, however big the image: a
/// screenshot from a big screen is tens of megabytes decoded whole.
@MainActor
final class ImageCache {
    /// The longest side an image is kept at in memory: enough to read one whole on a phone.
    static let shown = 1400
    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("images", isDirectory: true)
    /// Reads under way, so two views of one image ask its Mac once.
    private var reading: [String: Task<UIImage?, Never>] = [:]

    func put(_ data: Data, at path: String) {
        guard let name = Self.name(path), let image = Self.decoded(data) else { return }
        memory.setObject(image, forKey: name as NSString)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent(name))
        }
    }

    /// The image at `path` on its Mac, from here when it's been read before.
    func image(_ path: String, read: @escaping @Sendable () async throws -> Data) async -> UIImage? {
        guard let name = Self.name(path) else { return nil }
        if let image = memory.object(forKey: name as NSString) { return image }
        if let folder, let data = try? Data(contentsOf: folder.appendingPathComponent(name)), let image = Self.decoded(data) {
            memory.setObject(image, forKey: name as NSString)
            return image
        }
        if let task = reading[name] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let data = try? await read() else { return nil }
            put(data, at: path)
            return memory.object(forKey: name as NSString) ?? Self.decoded(data)
        }
        reading[name] = task
        let image = await task.value
        reading[name] = nil
        return image
    }

    /// An image decoded at no more than `shown` pixels on its longer side.
    private static func decoded(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: shown,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// A file name for a path, only for the ones Codealong makes: `<16 hex>.<ext>`.
    private static func name(_ path: String) -> String? {
        guard path.hasPrefix("images/") else { return nil }
        let name = String(path.dropFirst("images/".count))
        let parts = name.split(separator: ".")
        guard parts.count == 2, parts[0].count == 16, parts[0].allSatisfy(\.isHexDigit), ["png", "jpg", "gif", "webp"].contains(String(parts[1])) else { return nil }
        return name
    }
}

extension EnvironmentValues {
    /// The Mac a conversation's prompts keep their images on.
    @Entry var imageMac: String?
}

/// An image a prompt refers to, read from its Mac: a thumbnail that opens it whole.
struct KeptImage: View {
    let mac: String
    let path: String
    var side: CGFloat = 120
    @Environment(Store.self) private var store
    /// What it shows: a thumbnail, so a long conversation of images holds little.
    @State private var image: UIImage?
    @State private var failed = false
    /// The image whole, read again from the cache when it's tapped.
    @State private var whole: UIImage?

    private var online: Bool { store.devices.contains { $0.key == mac && $0.online } }

    var body: some View {
        Group {
            if let image {
                Button {
                    Task { whole = await store.image(mac: mac, path: path) }
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: 10))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Image")
                .accessibilityHint("Shows it whole")
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: side, height: side)
                    .overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .accessibilityLabel(failed ? "An image its Mac couldn't send" : "An image, loading")
            }
        }
        // Again once its Mac connects: one shown before, from what the phone kept, couldn't be read.
        .task(id: "\(path) \(online)") {
            guard image == nil else { return }
            let read = await store.image(mac: mac, path: path)
            image = read?.preparingThumbnail(of: CGSize(width: side * 3, height: side * 3)) ?? read
            failed = image == nil
        }
        .fullScreenCover(isPresented: Binding(get: { whole != nil }, set: { if !$0 { whole = nil } })) {
            if let whole {
                ImageViewer(image: whole)
            }
        }
    }
}

/// An image whole, on black: pinch to zoom, tap Done to close, share it from the corner.
private struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom * pinch)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(6, max(1, zoom * value.magnification)) }
                )
                .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5 } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image)))
                    }
                }
                .toolbarBackground(.black, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

/// The images attached to a reply, over its box, or to a new session's prompt, under the input:
/// each with a way to take it off, and a spinner while it's kept on its Mac.
struct AttachedRow: View {
    let images: [AttachedImage]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(images) { image in
                    Image(uiImage: image.thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 10))
                        .accessibilityLabel(image.state == .keeping ? "Image, sending to its Mac" : "Image")
                        .overlay {
                            if image.state == .keeping {
                                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35))
                                ProgressView().tint(.white)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                remove(image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 7, y: -7)
                            .accessibilityLabel("Take this image off")
                        }
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .scrollIndicators(.hidden)
    }
}
