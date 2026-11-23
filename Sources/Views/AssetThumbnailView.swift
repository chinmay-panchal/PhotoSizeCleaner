import SwiftUI
import Photos

public struct AssetThumbnailView: View {
    public let item: PhotoItem
    public let isSelected: Bool
    public let isSelectionMode: Bool
    public let onSelect: () -> Void
    public let onExpand: (() -> Void)?

    @State private var thumbnailImage: UIImage? = nil
    @State private var requestID: PHImageRequestID? = nil

    private let targetSize = CGSize(width: 300, height: 300)

    public init(
        item: PhotoItem,
        isSelected: Bool,
        isSelectionMode: Bool,
        onSelect: @escaping () -> Void,
        onExpand: (() -> Void)? = nil
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isSelectionMode = isSelectionMode
        self.onSelect = onSelect
        self.onExpand = onExpand
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Image canvas
            GeometryReader { geo in
                Group {
                    if let image = thumbnailImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        Color(UIColor.secondarySystemBackground)
                    }
                }
                .clipped()
            }
            .aspectRatio(1, contentMode: .fit)

            // Dim overlay when selected
            if isSelected {
                Color.black.opacity(0.35)
            }

            // Top-left: Minimal duration badge for videos or hidden indicator
            VStack {
                HStack(spacing: 4) {
                    if item.isVideo, let duration = item.formattedDuration {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text(duration)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                    }

                    if item.isHidden {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()
                }
                Spacer()
            }
            .padding(6)

            // Top-right: Selection indicator
            if isSelectionMode {
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.blue : Color.black.opacity(0.25))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                                )

                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(6)
            }

            // Bottom row: Expand icon (left, in selection mode) + Size pill (right)
            HStack {
                // Expand button — visible only in selection mode
                if isSelectionMode {
                    Button {
                        onExpand?()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                // Size pill
                Text(item.formattedSize)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.blue : Color.white.opacity(0.06), lineWidth: isSelected ? 2.5 : 1)
        )
        .scaleEffect(isSelected ? 0.94 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
        .contentShape(Rectangle())
        .onAppear { loadThumbnail() }
        .onDisappear { cancelThumbnail() }
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        requestID = PHImageManager.default().requestImage(
            for: item.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            if let img = image {
                self.thumbnailImage = img
            }
        }
    }

    private func cancelThumbnail() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
    }
}
