import UIKit
import SwiftUI
import Observation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Share → DiPo
//
// "Log with DiPo" in the share sheet, for a receipt someone sent you — a
// transfer proof on WhatsApp, a photo of a bill, a screenshot in Photos.
//
// The extension deliberately does NOT read the receipt itself. The app already
// has the whole pipeline — OCR, the parser, the review form, the Royal gate,
// the no-card check — and a share extension runs in its own process under a
// tight memory ceiling with none of that code. So it does one job: put the
// image where the app can find it, then hand over to the app.
//
// Hand-over is two-layered on purpose. It first asks the system to open
// `dipo://scan-shared`. iOS does not formally offer that to share extensions,
// so if it is ever refused, the image is still waiting in the App Group and the
// app picks it up the next time it comes to the foreground (within an hour).

/// Must stay in step with `SharedScanInbox` in the app target.
enum ShareInbox {
    static let appGroupID = "group.com.fahmiaquinas.DiPo"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("SharedScans", isDirectory: true)
            .appendingPathComponent("shared-receipt.jpg")
    }

    static func write(_ jpeg: Data) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
    }
}

// MARK: - Palette
//
// Copied from AppTheme — this target cannot import the app. Same values, so
// the sheet reads as DiPo in both light and dark mode.
private enum SharePalette {
    static let bg        = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.10, green: 0.12, blue: 0.12, alpha: 1) : UIColor(red: 0.95, green: 0.96, blue: 0.95, alpha: 1) })
    static let card      = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.13, green: 0.16, blue: 0.15, alpha: 1) : .white })
    static let primary   = Color(UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(red: 0.05, green: 0.08, blue: 0.08, alpha: 1) })
    static let secondary = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.54, green: 0.59, blue: 0.58, alpha: 1) : UIColor(red: 0.30, green: 0.42, blue: 0.38, alpha: 1) })
    /// The app's one green — systemGreen, the iPhone charging green.
    static let green     = Color(uiColor: .systemGreen)
    /// Text on the green: near-black, ≈8–9:1 in both modes. White is 2.2:1.
    static let onGreen   = Color(red: 0.05, green: 0.08, blue: 0.08)
    static let red       = Color(uiColor: .systemRed)
}

// MARK: - Strings
//
// The app mirrors its in-app language into the App Group; fall back to the
// device language for anyone who has not opened the app since that shipped.
private struct ShareStrings {
    let isID: Bool
    init() {
        let saved = UserDefaults(suiteName: ShareInbox.appGroupID)?.string(forKey: "dipo_language")
        isID = saved.map { $0 == "id" }
            ?? (Locale.preferredLanguages.first?.hasPrefix("id") ?? false)
    }
    var cancel: String     { isID ? "Batal" : "Cancel" }
    var title: String      { isID ? "Catat struk ini?" : "Log this receipt?" }
    var subtitle: String   { isID ? "DiPo membaca nominal, merchant, dan tanggalnya. Kamu tetap mengecek semuanya sebelum disimpan."
                                  : "DiPo reads the amount, merchant and date. You still check everything before it is saved." }
    var action: String     { isID ? "Catat di DiPo" : "Log in DiPo" }
    var loading: String    { isID ? "Menyiapkan gambar…" : "Preparing the image…" }
    var failed: String     { isID ? "Gambar ini tidak bisa dibaca." : "This image could not be read." }
    var failedHint: String { isID ? "Coba bagikan sebagai foto, bukan dokumen." : "Try sharing it as a photo rather than a document." }
    var sent: String       { isID ? "Membuka DiPo…" : "Opening DiPo…" }
    var sentHint: String   { isID ? "Kalau DiPo tidak terbuka sendiri, buka DiPo — struknya sudah menunggu."
                                  : "If DiPo does not open by itself, open it — the receipt is waiting there." }
}

// MARK: - Model

@MainActor
@Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready(UIImage, Data)
        case failed
        case sent
    }
    var phase: Phase = .loading

    func load(from context: NSExtensionContext?) async {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else { phase = .failed; return }

        guard let raw = await Self.loadData(provider),
              let jpeg = Self.downsampledJPEG(raw),
              let image = UIImage(data: jpeg) else { phase = .failed; return }
        phase = .ready(image, jpeg)
    }

    /// Senders hand images over in three different shapes — a file URL
    /// (Photos, Files), raw data (most chat apps) or a live `UIImage`
    /// (screenshot markup). Try the data representation first, then the rest.
    nonisolated static func loadData(_ provider: NSItemProvider) async -> Data? {
        let data: Data? = await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                cont.resume(returning: data)
            }
        }
        if let data { return data }
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL:     cont.resume(returning: try? Data(contentsOf: url))
                case let img as UIImage: cont.resume(returning: img.jpegData(compressionQuality: 0.9))
                case let data as Data:   cont.resume(returning: data)
                default:                 cont.resume(returning: nil)
                }
            }
        }
    }

    /// Decode straight to at most 2400 px on the long edge. A share extension
    /// is killed well before the app would be, and a full 48 MP photo decoded
    /// at size is enough to get it killed. OCR does not need more than this.
    nonisolated static func downsampledJPEG(_ data: Data, maxPixel: Int = 2400) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }
}

// MARK: - View

private struct ShareCardView: View {
    let model: ShareModel
    let onLog: (Data) -> Void
    let onCancel: () -> Void
    private let t = ShareStrings()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(t.cancel, action: onCancel)
                    .font(.system(size: 16))
                    .foregroundStyle(SharePalette.secondary)
                Spacer()
                Text("DiPo")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SharePalette.primary)
                Spacer()
                // Balances the Cancel button so the title stays centred.
                Text(t.cancel).font(.system(size: 16)).hidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            content
                .frame(maxHeight: .infinity)
        }
        .background(SharePalette.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(SharePalette.green)
                Text(t.loading).font(.system(size: 14)).foregroundStyle(SharePalette.secondary)
            }

        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(SharePalette.red)
                Text(t.failed).font(.system(size: 16, weight: .semibold)).foregroundStyle(SharePalette.primary)
                Text(t.failedHint).font(.system(size: 13)).foregroundStyle(SharePalette.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

        case .ready(let image, let jpeg):
            VStack(spacing: 18) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 340)
                    .padding(10)
                    .background(SharePalette.card, in: RoundedRectangle(cornerRadius: 22))

                VStack(spacing: 6) {
                    Text(t.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(SharePalette.primary)
                    Text(t.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(SharePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                Button { onLog(jpeg) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.viewfinder").font(.system(size: 17, weight: .semibold))
                        Text(t.action).font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(SharePalette.onGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(SharePalette.green, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

        case .sent:
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(SharePalette.green).frame(width: 64, height: 64)
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(SharePalette.onGreen)
                }
                Text(t.sent).font(.system(size: 17, weight: .semibold)).foregroundStyle(SharePalette.primary)
                Text(t.sentHint)
                    .font(.system(size: 13))
                    .foregroundStyle(SharePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Controller

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCardView(
            model: model,
            onLog: { [weak self] jpeg in self?.log(jpeg) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        Task { await model.load(from: extensionContext) }
    }

    private func log(_ jpeg: Data) {
        do {
            try ShareInbox.write(jpeg)
        } catch {
            model.phase = .failed
            return
        }
        model.phase = .sent
        openDiPo()
        // Long enough to read the fallback hint if the app did not come up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Asks the system to bring DiPo forward. `UIApplication.open` is marked
    /// unavailable to extensions at compile time, so it is reached through the
    /// responder chain by selector. If a future iOS refuses it, nothing breaks:
    /// the image is already in the inbox for the app to collect.
    private func openDiPo() {
        guard let url = URL(string: "dipo://scan-shared") else { return }
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication, app.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(app.method(for: selector), to: OpenURL.self)
                open(app, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
