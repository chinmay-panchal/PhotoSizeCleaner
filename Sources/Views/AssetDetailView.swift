import SwiftUI
import Photos
import AVKit
import UIKit

// MARK: - Custom Centering Scroll View

private final class CenteringScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Zoomable Image via UIScrollView (focal-point pinch zoom)

private struct ZoomableScrollImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    func makeUIView(context: Context) -> CenteringScrollView {
        let scrollView = CenteringScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.frame = .zero
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let coordinator = context.coordinator
        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.currentImage = image

        scrollView.onLayout = { [weak coordinator] in
            coordinator?.handleLayout()
        }

        // Double-tap to zoom in/out at tap location
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: CenteringScrollView, context: Context) {
        if context.coordinator.currentImage !== image {
            context.coordinator.currentImage = image
            context.coordinator.imageView?.image = image
            context.coordinator.lastBoundsSize = .zero
            context.coordinator.fitImageToScreen()
        }
    }

    // MARK: Coordinator
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: CenteringScrollView?
        weak var imageView: UIImageView?
        var currentImage: UIImage?
        var lastBoundsSize: CGSize = .zero
        @Binding var isZoomed: Bool

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        // Required: tells UIScrollView which subview to zoom
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        // Keep image centered as it zooms
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImageView()
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if isZoomed != zoomed {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isZoomed = zoomed
                }
            }
        }

        func handleLayout() {
            guard let scrollView = scrollView, let imageView = imageView, let image = imageView.image else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }

            if boundsSize != lastBoundsSize {
                lastBoundsSize = boundsSize
                fitImageToScreen()
            } else {
                centerImageView()
            }
        }

        func fitImageToScreen() {
            guard let scrollView = scrollView, let imageView = imageView, let image = imageView.image else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0, image.size.width > 0, image.size.height > 0 else { return }

            scrollView.zoomScale = 1.0

            let widthRatio  = boundsSize.width  / image.size.width
            let heightRatio = boundsSize.height / image.size.height
            let scale       = min(widthRatio, heightRatio)

            let fittedSize = CGSize(
                width:  floor(image.size.width * scale),
                height: floor(image.size.height * scale)
            )

            imageView.bounds = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            centerImageView()

            if isZoomed {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isZoomed = false
                }
            }
        }

        func centerImageView() {
            guard let scrollView = scrollView, let imageView = imageView else { return }
            let boundsSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize

            let offsetX = max((boundsSize.width - contentSize.width) * 0.5, 0)
            let offsetY = max((boundsSize.height - contentSize.height) * 0.5, 0)

            imageView.center = CGPoint(
                x: contentSize.width * 0.5 + offsetX,
                y: contentSize.height * 0.5 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView, let imageView = imageView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                // Zoom out to fit
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom in centered on tap point
                let tapPoint = gesture.location(in: imageView)
                let zoomTarget: CGFloat = 2.5
                let size = CGSize(
                    width:  scrollView.bounds.width  / zoomTarget,
                    height: scrollView.bounds.height / zoomTarget
                )
                let rect = CGRect(
                    x: tapPoint.x - size.width  / 2,
                    y: tapPoint.y - size.height / 2,
                    width:  size.width,
                    height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - AssetDetailView

public struct AssetDetailView: View {
    public let item: PhotoItem
    public let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage? = nil
    @State private var player: AVPlayer? = nil
    @State private var isLoadingMedia = true
    @State private var showDeleteConfirmation = false
    @State private var isZoomed = false   // hides controls when user zooms in

    public init(item: PhotoItem, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
    }

    public var body: some View {
        ZStack {
            // Dark gallery background
            Color.black.ignoresSafeArea()

            // Media Content
            if item.isVideo {
                if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                        .onAppear  { player.play()  }
                        .onDisappear { player.pause() }
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                if let image = fullImage {
                    ZoomableScrollImageView(image: image, isZoomed: $isZoomed)
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            }

            // Overlay Controls — fade out when zoomed in
            VStack {
                // Top Bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    Text(item.formattedSize)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                // Bottom Minimal Metadata & Delete Pill
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.formattedDimensions)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))

                        if let date = item.creationDate {
                            Text(date, format: .dateTime.month().day().year())
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }

                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 12))
                            Text("Delete")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.red)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .opacity(isZoomed ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: isZoomed)
            .allowsHitTesting(!isZoomed)
        }
        .confirmationDialog(
            "Delete \(item.isVideo ? "Video" : "Photo")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete (\(item.formattedSize))", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move the file to 'Recently Deleted' in your Photos library.")
        }
        .task {
            await loadMedia()
        }
    }

    private func loadMedia() async {
        if item.isVideo {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic

            PHImageManager.default().requestPlayerItem(forVideo: item.asset, options: options) { playerItem, _ in
                DispatchQueue.main.async {
                    if let playerItem = playerItem {
                        self.player = AVPlayer(playerItem: playerItem)
                    }
                    self.isLoadingMedia = false
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestImage(
                for: item.asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                DispatchQueue.main.async {
                    self.fullImage = image
                    self.isLoadingMedia = false
                }
            }
        }
    }
}
