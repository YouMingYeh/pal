import SwiftUI
import Kingfisher

/// Private photos stay in memory and are isolated when the signed-in account changes.
@MainActor final class PalImageCache: ObservableObject {
    static let shared = PalImageCache()
    @Published private(set) var generation = UUID()
    private(set) var targetCache: ImageCache
    let downloader: ImageDownloader
    private var manager: KingfisherManager
    private var owner: UUID?
    private let validation = PalImageValidation()

    init(session: URLSession? = nil) {
        let configuration = session?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let downloader = ImageDownloader(name: "Pal-\(UUID().uuidString)")
        downloader.sessionConfiguration = configuration
        let cache = Self.makeCache()
        self.downloader = downloader
        targetCache = cache
        manager = KingfisherManager(downloader: downloader, cache: cache)
        downloader.delegate = validation
    }

    nonisolated static func key(for url: URL) -> String {
        guard url.path.hasPrefix("/storage/v1/object/sign/") else { return url.absoluteString }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil; parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }

    func setOwner(_ value: UUID?) {
        guard owner != value else { return }
        downloader.cancelAll()
        targetCache.clearMemoryCache()
        // Rotating the target prevents a late old-account callback from populating the new cache.
        let cache = Self.makeCache()
        targetCache = cache
        manager = KingfisherManager(downloader: downloader, cache: cache)
        owner = value; generation = UUID()
    }

    func cached(_ url: URL, maximumPixelSize: Int = 512) -> UIImage? {
        targetCache.retrieveImageInMemoryCache(forKey: Self.key(for: url), options: options(maximumPixelSize))
    }

    func image(_ url: URL, maximumPixelSize: Int = 512) async throws -> UIImage {
        if let image = cached(url, maximumPixelSize: maximumPixelSize) { return image }
        let expectedGeneration = generation
        let resource = KF.ImageResource(downloadURL: url, cacheKey: Self.key(for: url))
        let result = try await manager.retrieveImage(with: resource, options: options(maximumPixelSize))
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
        return result.image
    }

    private func options(_ pixels: Int) -> KingfisherOptionsInfo {
        [.cacheMemoryOnly, .scaleFactor(1), .processor(Self.processor(pixels))]
    }

    static func processor(_ pixels: Int) -> DownsamplingImageProcessor {
        DownsamplingImageProcessor(size: CGSize(width: pixels, height: pixels))
    }

    private static func makeCache() -> ImageCache {
        let cache = ImageCache(name: "Pal-private-\(UUID().uuidString)")
        cache.memoryStorage.config.totalCostLimit = 32 * 1024 * 1024
        cache.memoryStorage.config.expiration = .seconds(3600)
        return cache
    }
}

private final class PalImageValidation: ImageDownloaderDelegate {
    func imageDownloader(_ downloader: ImageDownloader, didDownload data: Data, for url: URL) -> Data? {
        !data.isEmpty && data.count <= 5 * 1024 * 1024 ? data : nil
    }
    func isValidStatusCode(_ code: Int, for downloader: ImageDownloader) -> Bool { (200..<300).contains(code) }
}

struct PalCachedAvatarImage: View {
    let url: URL
    @ObservedObject var cache: PalImageCache = .shared
    var body: some View {
        KFImage(source: .network(KF.ImageResource(downloadURL: url, cacheKey: PalImageCache.key(for: url))))
            .targetCache(cache.targetCache)
            .downloader(cache.downloader)
            .cacheMemoryOnly()
            .setProcessor(PalImageCache.processor(512))
            .scaleFactor(1)
            .placeholder {
                if let image = cache.cached(url) { Image(uiImage: image).resizable().scaledToFill() }
                else { Color.clear }
            }
            .resizable()
            .scaledToFill()
            .id(cache.generation)
    }
}
