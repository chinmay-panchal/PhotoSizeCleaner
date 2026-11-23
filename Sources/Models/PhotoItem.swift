import Foundation
import Photos

public struct PhotoItem: Identifiable, Hashable, @unchecked Sendable {
    public let id: String
    public let asset: PHAsset
    public let filename: String
    public let fileSize: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let isFavorite: Bool
    public let isHidden: Bool
    public let mediaType: PHAssetMediaType

    public init(asset: PHAsset, fileSize: Int64, filename: String) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.filename = filename
        self.fileSize = fileSize
        self.creationDate = asset.creationDate
        self.modificationDate = asset.modificationDate
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.duration = asset.duration
        self.isFavorite = asset.isFavorite
        self.isHidden = asset.isHidden
        self.mediaType = asset.mediaType
    }

    public var isVideo: Bool {
        mediaType == .video
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    public var formattedDuration: String? {
        guard isVideo else { return nil }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public var formattedDimensions: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    public static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
