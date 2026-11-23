import SwiftUI
import Photos
import UIKit

public struct ContentView: View {
    @StateObject private var viewModel = PhotoCleanerViewModel()
    @State private var selectedItemForDetail: PhotoItem? = nil
    @State private var showDeleteAlert = false

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Background
                Color(UIColor.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Scanning hairline progress bar
                    if viewModel.isScanning {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.blue.opacity(0.12)
                                Rectangle()
                                    .fill(Color.blue)
                                    .frame(width: geo.size.width * CGFloat(viewModel.scanProgress))
                                    .animation(.linear(duration: 0.1), value: viewModel.scanProgress)
                            }
                        }
                        .frame(height: 2)
                    }

                    // Content based on permission
                    switch viewModel.authorizationStatus {
                    case .authorized, .limited:
                        VStack(spacing: 0) {
                            subHeader
                            mediaGrid
                        }
                    case .notDetermined:
                        welcomePermissionView
                    case .denied, .restricted:
                        permissionDeniedView
                    @unknown default:
                        welcomePermissionView
                    }
                }

                // Floating Action Pill (Bottom)
                if !viewModel.selectedIds.isEmpty {
                    floatingActionPill
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Center Capsule: Photos vs Videos
                ToolbarItem(placement: .principal) {
                    if viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited {
                        categorySegmentedPill
                    } else {
                        Text("PhotoSizeCleaner")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }

                // Leading: Select / Done
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited {
                        Button(viewModel.isSelectionMode ? "Done" : "Select") {
                            triggerHaptic(.light)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.isSelectionMode.toggle()
                                if !viewModel.isSelectionMode {
                                    viewModel.deselectAll()
                                }
                            }
                        }
                        .font(.system(size: 15, weight: .medium))
                    }
                }

                // Trailing: Filter / Sort Menu
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited {
                        Menu {
                            Section("Filter Size") {
                                ForEach(SizeFilter.allCases) { filter in
                                    Button {
                                        triggerHaptic(.light)
                                        viewModel.sizeFilter = filter
                                    } label: {
                                        HStack {
                                            Text(filter.rawValue)
                                            if viewModel.sizeFilter == filter {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }

                            Section("Sort By") {
                                ForEach(SortOption.allCases) { option in
                                    Button {
                                        triggerHaptic(.light)
                                        viewModel.sortOption = option
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if viewModel.sortOption == option {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }

                            if viewModel.isSelectionMode {
                                Section {
                                    Button("Select All (\(viewModel.currentItems.count))") {
                                        triggerHaptic(.light)
                                        viewModel.selectAll()
                                    }
                                    Button("Deselect All") {
                                        triggerHaptic(.light)
                                        viewModel.deselectAll()
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 17))
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .task {
                if viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited {
                    await viewModel.scanCurrentCategory()
                } else if viewModel.authorizationStatus == .notDetermined {
                    await viewModel.requestAccessAndLoad()
                }
            }
            .sheet(item: $selectedItemForDetail) { item in
                AssetDetailView(item: item) {
                    Task {
                        try? await PhotoLibraryService.shared.deleteAssets(assets: [item.asset])
                        await PhotoLibraryService.shared.invalidateCache(for: [item.id])
                        viewModel.handleSingleItemDeleted(id: item.id)
                    }
                }
            }
            .alert("Delete \(viewModel.selectedItems.count) Items?", isPresented: $showDeleteAlert) {
                Button("Delete to Free Up \(viewModel.formattedSelectedSize)", role: .destructive) {
                    triggerHaptic(.medium)
                    Task {
                        await viewModel.deleteSelected()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will move the selected items to 'Recently Deleted' in your Photos library.")
            }
        }
    }

    // MARK: - Sub Header
    private var subHeader: some View {
        HStack {
            Text(viewModel.formattedTotalScannedSize)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)

            Text("•")
                .foregroundColor(.secondary.opacity(0.5))

            Text("\(viewModel.currentItems.count) \(viewModel.currentCategory.rawValue.lowercased())")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            if viewModel.sizeFilter != .all {
                Text("(\(viewModel.sizeFilter.rawValue))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.blue)
            }

            Spacer()

            if viewModel.isScanning {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text(viewModel.totalToScan > 0 ? "Scanning \(viewModel.scannedCount)/\(viewModel.totalToScan)" : "Scanning…")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Category Pill Switcher
    private var categorySegmentedPill: some View {
        HStack(spacing: 0) {
            ForEach(MediaCategory.allCases) { cat in
                let isSelected = viewModel.currentCategory == cat
                Button {
                    triggerHaptic(.light)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        viewModel.currentCategory = cat
                    }
                } label: {
                    Text(cat.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if isSelected {
                                    Capsule()
                                        .fill(Color(UIColor.secondarySystemBackground))
                                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(Capsule())
    }

    // MARK: - Media Grid
    private var mediaGrid: some View {
        ScrollView {
            if viewModel.currentItems.isEmpty && !viewModel.isScanning {
                VStack(spacing: 8) {
                    Text("No \(viewModel.currentCategory.rawValue)")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Nothing matches the current filter")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(viewModel.currentItems) { item in
                        AssetThumbnailView(
                            item: item,
                            isSelected: viewModel.selectedIds.contains(item.id),
                            isSelectionMode: viewModel.isSelectionMode
                        ) {
                            triggerHaptic(.selection)
                            viewModel.toggleSelection(for: item)
                        } onExpand: {
                            selectedItemForDetail = item
                        }
                        .onTapGesture {
                            if viewModel.isSelectionMode {
                                triggerHaptic(.selection)
                                viewModel.toggleSelection(for: item)
                            } else {
                                selectedItemForDetail = item
                            }
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.15)
                                .onEnded { _ in
                                    guard !viewModel.isSelectionMode else { return }
                                    triggerHaptic(.medium)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        viewModel.isSelectionMode = true
                                        viewModel.toggleSelection(for: item)
                                    }
                                }
                        )
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, viewModel.selectedIds.isEmpty ? 20 : 90)
            }
        }
        .refreshable {
            await viewModel.scanCurrentCategory(forceRefresh: true)
        }
    }

    // MARK: - Floating Minimal Action Pill
    private var floatingActionPill: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(viewModel.selectedItems.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Free \(viewModel.formattedSelectedSize)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            Spacer()

            Button(role: .destructive) {
                triggerHaptic(.medium)
                showDeleteAlert = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Delete")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.red)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .padding(.horizontal, 24)
    }

    // MARK: - Welcome / Request View
    private var welcomePermissionView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            VStack(spacing: 8) {
                Text("Sort Photos by Size")
                    .font(.title2.bold())

                Text("Find the largest photos and videos taking up space on your iPhone and delete them safely.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Button {
                Task {
                    await viewModel.requestAccessAndLoad()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                    Text("Scan My Photos")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.blue)
                .clipShape(Capsule())
            }
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Permission Denied View
    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Photos Access Needed")
                .font(.headline)
            Text("Please enable photo access in iOS Settings to let the app calculate file sizes.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}

private extension UIImpactFeedbackGenerator.FeedbackStyle {
    static let selection: UIImpactFeedbackGenerator.FeedbackStyle = .light
}
