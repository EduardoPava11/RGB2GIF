//
//  GIFCardListView.swift
//  RGB2GIF
//
//  Card List style library view for browsing saved GIFs
//  - Vertical scrolling cards with thumbnail + metadata
//  - Full Suite actions: view, share, save to Photos, delete, duplicate, re-export
//

import SwiftUI
import Photos
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct GIFCardListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalogueManager = GIFCatalogueManager.shared
    @State private var selectedItem: GIFCatalogueItem?
    @State private var sortOption: GIFCatalogueManager.SortOption = .dateNewest
    @State private var filterDimension: Int? = nil
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: GIFCatalogueItem?
    @State private var showingShareSheet = false
    @State private var itemToShare: GIFCatalogueItem?
    @State private var showingActionSheet = false
    @State private var actionSheetItem: GIFCatalogueItem?
    @State private var statusMessage: String?
    @State private var showingStatus = false

    var filteredAndSortedItems: [GIFCatalogueItem] {
        let filtered = catalogueManager.filterByDimension(filterDimension)
        return catalogueManager.sortedBy(sortOption)
    }

    var body: some View {
        NavigationView {
            mainContent
                .navigationTitle("GIF Library")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
                .sheet(item: $selectedItem) { item in
                    detailView(for: item)
                }
                .confirmationDialog("GIF Actions", isPresented: $showingActionSheet, presenting: actionSheetItem) { item in
                    actionButtons(for: item)
                } message: { item in
                    Text("\(item.dimension)×\(item.dimension) • \(item.frameCount) frames")
                }
                .alert("Delete GIF?", isPresented: $showingDeleteAlert, presenting: itemToDelete) { item in
                    deleteAlertButtons(for: item)
                } message: { _ in
                    Text("This will permanently delete the GIF and cannot be undone.")
                }
                .sheet(isPresented: $showingShareSheet) {
                    if let item = itemToShare {
                        ShareSheet(url: item.gifURL)
                    }
                }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            if catalogueManager.catalogueItems.isEmpty {
                emptyStateView
            } else {
                listContent
            }

            statusOverlay
        }
    }

    @ViewBuilder
    private var listContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                filterChipsView
                    .padding(.top, 8)

                cardListView
            }
        }
    }

    @ViewBuilder
    private var cardListView: some View {
        LazyVStack(spacing: 16) {
            ForEach(filteredAndSortedItems) { item in
                GIFCardView(item: item) {
                    selectedItem = item
                } onActionTap: {
                    actionSheetItem = item
                    showingActionSheet = true
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if showingStatus, let message = statusMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(25)
                    .padding(.bottom, 40)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done") {
                dismiss()
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(GIFCatalogueManager.SortOption.allCases, id: \.self) { option in
                Button {
                    sortOption = option
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if sortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("No GIFs Yet")
                .font(.title2)
                .fontWeight(.bold)

            Text("Capture your first temporal cube GIF to see it here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                dismiss()
            } label: {
                Label("Start Capturing", systemImage: "camera.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(25)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Filter Chips

    private var filterChipsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                FilterChipButton(title: "All", isSelected: filterDimension == nil) {
                    filterDimension = nil
                }
                FilterChipButton(title: "80×80", isSelected: filterDimension == 80) {
                    filterDimension = 80
                }
                FilterChipButton(title: "128×128", isSelected: filterDimension == 128) {
                    filterDimension = 128
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Detail View

    private func detailView(for item: GIFCatalogueItem) -> some View {
        let gifItem = GIFItem(
            url: item.gifURL,
            size: CGSize(width: item.dimension, height: item.dimension),
            frameCount: item.frameCount,
            fileSize: Int64(item.fileSize),
            creationDate: item.createdAt,
            thumbnailData: try? Data(contentsOf: item.thumbnailURL)
        )
        return GIFDetailView(item: gifItem)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for item: GIFCatalogueItem) -> some View {
        Button("Share") { shareGIF(item) }
        Button("Save to Photos") { saveToPhotos(item) }
        Button("Duplicate") { duplicateGIF(item) }
        Button("Re-export Settings") { showStatus("Re-export coming soon!") }
        Button("Delete", role: .destructive) {
            itemToDelete = item
            showingDeleteAlert = true
        }
        Button("Cancel", role: .cancel) { }
    }

    @ViewBuilder
    private func deleteAlertButtons(for item: GIFCatalogueItem) -> some View {
        Button("Delete", role: .destructive) { deleteGIF(item) }
        Button("Cancel", role: .cancel) { }
    }

    // MARK: - Actions

    private func shareGIF(_ item: GIFCatalogueItem) {
        itemToShare = item
        showingShareSheet = true
    }

    private func saveToPhotos(_ item: GIFCatalogueItem) {
        Task {
            do {
                _ = try await PhotosGIFSaver.saveGIF(at: item.gifURL, title: "GIF \(item.dimension)")
                showStatus("Saved to Photos!")
            } catch {
                showStatus("Failed to save: \(error.localizedDescription)")
            }
        }
    }

    private func duplicateGIF(_ item: GIFCatalogueItem) {
        Task {
            do {
                let gifData = try Data(contentsOf: item.gifURL)
                let tensorData = item.tensorURL != nil ? try? Data(contentsOf: item.tensorURL!) : nil
                let paletteData = item.paletteURL != nil ? try? Data(contentsOf: item.paletteURL!) : nil
                let dimension: VoxelGIFConfiguration.CubeDimension = item.dimension == 80 ? .small : .large

                _ = try await catalogueManager.saveGIF(
                    gifData: gifData,
                    dimension: dimension,
                    tensorData: tensorData,
                    paletteData: paletteData,
                    metadata: CatalogueMetadata(
                        frameCount: item.frameCount,
                        fps: item.metadata.fps,
                        colorCount: item.metadata.colorCount,
                        usedDithering: item.metadata.usedDithering,
                        conveyorEnabled: item.metadata.conveyorEnabled,
                        captureDevice: item.metadata.captureDevice
                    )
                )
                showStatus("GIF duplicated!")
            } catch {
                showStatus("Failed to duplicate: \(error.localizedDescription)")
            }
        }
    }

    private func deleteGIF(_ item: GIFCatalogueItem) {
        do {
            try catalogueManager.deleteItem(item)
            showStatus("GIF deleted")
        } catch {
            showStatus("Failed to delete: \(error.localizedDescription)")
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        withAnimation {
            showingStatus = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                showingStatus = false
            }
        }
    }
}

// MARK: - Card View

@available(iOS 26.0, *)
struct GIFCardView: View {
    let item: GIFCatalogueItem
    let onTap: () -> Void
    let onActionTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            cardContent
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear { loadThumbnail() }
    }

    private var cardContent: some View {
        HStack(spacing: 16) {
            thumbnailView
            infoView
            Spacer()
            actionButton
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var thumbnailView: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 80, height: 80)
                .cornerRadius(12)

            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .cornerRadius(12)
                    .clipped()
            } else {
                ProgressView()
            }

            dimensionBadge
        }
    }

    private var dimensionBadge: some View {
        VStack {
            HStack {
                Spacer()
                Text("\(item.dimension)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .cornerRadius(4)
                    .offset(x: -4, y: 4)
            }
            Spacer()
        }
        .frame(width: 80, height: 80)
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            metadataRow
            dateRow
        }
    }

    private var titleRow: some View {
        HStack {
            Text("\(item.frameCount) frames")
                .font(.headline)
                .fontWeight(.semibold)

            if item.photosAssetID != nil {
                Image(systemName: "photo.fill")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Spacer()
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            Label(item.formattedSize, systemImage: "doc.fill")
                .font(.caption)
                .foregroundColor(.secondary)

            Label("\(Int(item.metadata.fps)) fps", systemImage: "speedometer")
                .font(.caption)
                .foregroundColor(.secondary)

            Label("\(item.metadata.colorCount)", systemImage: "paintpalette.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var dateRow: some View {
        Text(item.formattedDate)
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var actionButton: some View {
        Button(action: onActionTap) {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .foregroundColor(.gray)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let image = UIImage(contentsOfFile: item.thumbnailURL.path) {
                DispatchQueue.main.async {
                    thumbnail = image
                }
            }
        }
    }
}

// MARK: - Filter Chip Button

@available(iOS 26.0, *)
struct FilterChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.blue : Color.gray.opacity(0.2))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
    }
}

// MARK: - Preview
// Note: ShareSheet is defined in GIFDetailView.swift and reused here

@available(iOS 26.0, *)
#Preview {
    GIFCardListView()
}
