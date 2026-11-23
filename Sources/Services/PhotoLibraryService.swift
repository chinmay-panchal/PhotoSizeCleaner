import Foundation
import Photos
import UIKit

public actor PhotoLibraryService {
    public static let shared = PhotoLibraryService()

    public let imageManager = PHCachingImageManager()

    // Fast in-memory cache: asset identifier -> (fileSize, filename, modificationDate)
    private var sizeCache: [String: CachedMetadata] = [:]

    private struct CachedMetadata: Sendable {
        let fileSize: Int64
        let filename: String
        let modificationDate: Date?
    }

    public init() {}

    public func invalidateCache(for ids: [String]) {
        for id in ids {
            sizeCache.removeValue(forKey: id)
        }
    }

    public func clearCache() {
        sizeCache.removeAll()
    }

    /// Checks or requests authorization to access photo library
    public func requestAuthorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status
    }

    /// Fetches all assets of a specified media type (including hidden) and computes file sizes in parallel
    public func fetchAndScanAssets(
        mediaType: PHAssetMediaType,
        onUpdate: @Sendable @escaping (_ current: Int, _ total: Int, _ partialItems: [PhotoItem]?) -> Void
    ) async -> [PhotoItem] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult = PHAsset.fetchAssets(with: mediaType, options: options)
        let totalCount = fetchResult.count

        guard totalCount > 0 else {
            onUpdate(0, 0, [])
            return []
        }

        var allItems: [PhotoItem] = []
        allItems.reserveCapacity(totalCount)

        var uncachedAssets: [PHAsset] = []

        // 1. Separate cached items from uncached
        for index in 0..<totalCount {
            let asset = fetchResult.object(at: index)
            if let cached = sizeCache[asset.localIdentifier],
               cached.modificationDate == asset.modificationDate {
                allItems.append(PhotoItem(asset: asset, fileSize: cached.fileSize, filename: cached.filename))
            } else {
                uncachedAssets.append(asset)
            }
        }

        // If everything was already in cache, return immediately!
        if uncachedAssets.isEmpty {
            allItems.sort { $0.fileSize > $1.fileSize }
            onUpdate(totalCount, totalCount, allItems)
            return allItems
        }

        // Send initial cached items to populate UI right away
        if !allItems.isEmpty {
            let initialSorted = allItems.sorted { $0.fileSize > $1.fileSize }
            onUpdate(allItems.count, totalCount, initialSorted)
        } else {
            onUpdate(0, totalCount, nil)
        }

        // 2. Process uncached assets in parallel batches
        let chunkSize = 50
        let chunks: [[PHAsset]] = stride(from: 0, to: uncachedAssets.count, by: chunkSize).map {
            Array(uncachedAssets[$0..<min($0 + chunkSize, uncachedAssets.count)])
        }

        let maxConcurrent = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        var scannedCount = allItems.count
        var lastUIUpdateTime = CFAbsoluteTimeGetCurrent()

        var chunkIndex = 0
        let totalChunks = chunks.count

        await withTaskGroup(of: [PhotoItem]?.self) { group in
            while chunkIndex < totalChunks && (chunkIndex < maxConcurrent || group.isEmpty) {
                if Task.isCancelled { break }
                let chunk = chunks[chunkIndex]
                chunkIndex += 1
                group.addTask(priority: .userInitiated) {
                    if Task.isCancelled { return nil }
                    return Self.processBatch(chunk)
                }
            }

            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                if let batchItems = result {
                    for item in batchItems {
                        self.sizeCache[item.id] = CachedMetadata(
                            fileSize: item.fileSize,
                            filename: item.filename,
                            modificationDate: item.modificationDate
                        )
                    }

                    allItems.append(contentsOf: batchItems)
                    scannedCount += batchItems.count

                    let now = CFAbsoluteTimeGetCurrent()
                    let isDone = scannedCount >= totalCount
                    if isDone || now - lastUIUpdateTime > 0.25 {
                        lastUIUpdateTime = now
                        let currentSorted = allItems.sorted { $0.fileSize > $1.fileSize }
                        onUpdate(scannedCount, totalCount, currentSorted)
                    } else {
                        onUpdate(scannedCount, totalCount, nil)
                    }
                }

                if chunkIndex < totalChunks && !Task.isCancelled {
                    let nextChunk = chunks[chunkIndex]
                    chunkIndex += 1
                    group.addTask(priority: .userInitiated) {
                        if Task.isCancelled { return nil }
                        return Self.processBatch(nextChunk)
                    }
                }
            }
        }

        allItems.sort { $0.fileSize > $1.fileSize }
        onUpdate(scannedCount, totalCount, allItems)
        return allItems
    }

    private static func processBatch(_ assets: [PHAsset]) -> [PhotoItem] {
        var items: [PhotoItem] = []
        items.reserveCapacity(assets.count)

        for asset in assets {
            if Task.isCancelled { break }
            let (size, filename) = getAssetSizeAndName(for: asset)
            let item = PhotoItem(asset: asset, fileSize: size, filename: filename)
            items.append(item)
        }

        return items
    }

    /// Computes file size and filename by inspecting PHAssetResource
    private static func getAssetSizeAndName(for asset: PHAsset) -> (Int64, String) {
        let resources = PHAssetResource.assetResources(for: asset)
        var totalSize: Int64 = 0
        var preferredName: String? = nil

        for resource in resources {
            if preferredName == nil && !resource.originalFilename.isEmpty {
                preferredName = resource.originalFilename
            }

            if let sizeVal = resource.value(forKey: "fileSize") as? Int64 {
                totalSize += sizeVal
            } else if let num = resource.value(forKey: "fileSize") as? NSNumber {
                totalSize += num.int64Value
            }
        }

        let filename = preferredName ?? (asset.value(forKey: "filename") as? String) ?? "Item"

        // Fallback for estimated size if metadata returns 0
        if totalSize == 0 {
            let bytesPerPixel: Int64 = asset.mediaType == .video ? 4 : 3
            let estimated = Int64(asset.pixelWidth) * Int64(asset.pixelHeight) * bytesPerPixel / 6
            totalSize = max(estimated, 50_000)
        }

        return (totalSize, filename)
    }

    /// Requests native deletion through PhotoKit (triggers iOS confirmation dialog)
    public func deleteAssets(assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}
