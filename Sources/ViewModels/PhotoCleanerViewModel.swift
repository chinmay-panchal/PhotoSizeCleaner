import Foundation
import Photos
import SwiftUI
import Combine

public enum MediaCategory: String, CaseIterable, Identifiable {
    case photos = "Photos"
    case videos = "Videos"

    public var id: String { rawValue }

    public var phType: PHAssetMediaType {
        switch self {
        case .photos: return .image
        case .videos: return .video
        }
    }

    public var systemIcon: String {
        switch self {
        case .photos: return "photo.stack"
        case .videos: return "video.fill"
        }
    }
}

public enum SortOption: String, CaseIterable, Identifiable {
    case sizeDescending = "Largest First"
    case sizeAscending = "Smallest First"
    case dateDescending = "Newest First"
    case dateAscending = "Oldest First"

    public var id: String { rawValue }
}

public enum SizeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case above5MB = "> 5 MB"
    case above20MB = "> 20 MB"
    case above50MB = "> 50 MB"
    case above100MB = "> 100 MB"

    public var id: String { rawValue }

    public var thresholdBytes: Int64 {
        switch self {
        case .all: return 0
        case .above5MB: return 5 * 1024 * 1024
        case .above20MB: return 20 * 1024 * 1024
        case .above50MB: return 50 * 1024 * 1024
        case .above100MB: return 100 * 1024 * 1024
        }
    }
}

@MainActor
public class PhotoCleanerViewModel: ObservableObject {
    @Published public var currentCategory: MediaCategory = .photos {
        didSet {
            if oldValue != currentCategory {
                selectedIds.removeAll()
                Task { await scanCurrentCategory() }
            }
        }
    }

    @Published public var sortOption: SortOption = .sizeDescending
    @Published public var sizeFilter: SizeFilter = .all
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedIds: Set<String> = []

    @Published public var isScanning: Bool = false
    @Published public var scanProgress: Double = 0.0
    @Published public var scannedCount: Int = 0
    @Published public var totalToScan: Int = 0

    @Published public var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published public var errorMessage: String? = nil

    @Published private var rawPhotoItems: [PhotoItem] = []
    @Published private var rawVideoItems: [PhotoItem] = []

    private let libraryService = PhotoLibraryService.shared
    private var scanTask: Task<Void, Never>?

    public init() {
        // Check current status without immediately blocking
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestAccessAndLoad() async {
        let status = await libraryService.requestAuthorization()
        self.authorizationStatus = status

        if status == .authorized || status == .limited {
            await scanCurrentCategory()
        }
    }

    public func scanCurrentCategory(forceRefresh: Bool = false) async {
        // Cancel any active scan from previous category to avoid blocking
        scanTask?.cancel()

        let category = currentCategory

        // If we already have items and not forced to refresh, keep displaying them
        let existingItems = (category == .photos) ? rawPhotoItems : rawVideoItems
        if existingItems.isEmpty {
            scanProgress = 0.0
            scannedCount = 0
            totalToScan = 0
        }

        isScanning = true

        let service = libraryService
        let currentTask = Task { [weak self] () -> [PhotoItem]? in
            let items = await service.fetchAndScanAssets(mediaType: category.phType) { [weak self] current, total, partialItems in
                Task { @MainActor [weak self] in
                    guard let self = self, !Task.isCancelled else { return }
                    self.scannedCount = current
                    self.totalToScan = total
                    self.scanProgress = total > 0 ? Double(current) / Double(total) : 0

                    if let partial = partialItems, self.currentCategory == category {
                        if category == .photos {
                            self.rawPhotoItems = partial
                        } else {
                            self.rawVideoItems = partial
                        }
                    }
                }
            }
            return Task.isCancelled ? nil : items
        }

        self.scanTask = Task {
            _ = await currentTask.value
        }

        if let items = await currentTask.value {
            if self.currentCategory == category {
                if category == .photos {
                    self.rawPhotoItems = items
                } else {
                    self.rawVideoItems = items
                }
                self.isScanning = false
            }
        } else {
            // Cancelled
            if self.currentCategory == category {
                self.isScanning = false
            }
        }
    }

    public func handleSingleItemDeleted(id: String) {
        if currentCategory == .photos {
            rawPhotoItems.removeAll { $0.id == id }
        } else {
            rawVideoItems.removeAll { $0.id == id }
        }
        selectedIds.remove(id)
    }

    public var currentItems: [PhotoItem] {
        let baseItems = (currentCategory == .photos) ? rawPhotoItems : rawVideoItems
        let threshold = sizeFilter.thresholdBytes

        let filtered = threshold > 0 ? baseItems.filter { $0.fileSize >= threshold } : baseItems

        switch sortOption {
        case .sizeDescending:
            return filtered.sorted { $0.fileSize > $1.fileSize }
        case .sizeAscending:
            return filtered.sorted { $0.fileSize < $1.fileSize }
        case .dateDescending:
            return filtered.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .dateAscending:
            return filtered.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
    }

    public var totalScannedSize: Int64 {
        let items = (currentCategory == .photos) ? rawPhotoItems : rawVideoItems
        return items.reduce(0) { $0 + $1.fileSize }
    }

    public var formattedTotalScannedSize: String {
        ByteCountFormatter.string(fromByteCount: totalScannedSize, countStyle: .file)
    }

    public var selectedItems: [PhotoItem] {
        let items = currentItems
        return items.filter { selectedIds.contains($0.id) }
    }

    public var selectedTotalSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.fileSize }
    }

    public var formattedSelectedSize: String {
        ByteCountFormatter.string(fromByteCount: selectedTotalSize, countStyle: .file)
    }

    public func toggleSelection(for item: PhotoItem) {
        if selectedIds.contains(item.id) {
            selectedIds.remove(item.id)
        } else {
            selectedIds.insert(item.id)
        }
    }

    public func selectAll() {
        let allIds = currentItems.map { $0.id }
        selectedIds.formUnion(allIds)
    }

    public func deselectAll() {
        selectedIds.removeAll()
    }

    public func deleteSelected() async {
        let toDelete = selectedItems
        guard !toDelete.isEmpty else { return }

        let assets = toDelete.map { $0.asset }
        do {
            try await libraryService.deleteAssets(assets: assets)

            let deletedIds = Set(toDelete.map { $0.id })
            await libraryService.invalidateCache(for: Array(deletedIds))
            if currentCategory == .photos {
                rawPhotoItems.removeAll { deletedIds.contains($0.id) }
            } else {
                rawVideoItems.removeAll { deletedIds.contains($0.id) }
            }
            selectedIds.subtract(deletedIds)
            if selectedIds.isEmpty {
                isSelectionMode = false
            }
        } catch {
            self.errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }
}
