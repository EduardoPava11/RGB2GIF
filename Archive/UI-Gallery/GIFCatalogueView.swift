//
//  GIFCatalogueView.swift
//  RGB2GIF
//
//  Gallery view for browsing saved GIFs
//

import SwiftUI
import Combine
import Photos
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct GIFCatalogueView: View {
    @StateObject private var catalogueManager = GIFCatalogueManager.shared
    @State private var selectedItem: GIFCatalogueItem?
    @State private var showingDetail = false
    @State private var sortOption: GIFCatalogueManager.SortOption = .dateNewest
    @State private var filterDimension: Int? = nil
    @State private var showingSortOptions = false

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    var filteredAndSortedItems: [GIFCatalogueItem] {
        _ = catalogueManager.filterByDimension(filterDimension)
        return catalogueManager.sortedBy(sortOption)
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if catalogueManager.catalogueItems.isEmpty {
                    // Empty state
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
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Filter chips
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    FilterChip(
                                        title: "All",
                                        isSelected: filterDimension == nil
                                    ) {
                                        filterDimension = nil
                                    }

                                    FilterChip(
                                        title: "80×80",
                                        isSelected: filterDimension == 80
                                    ) {
                                        filterDimension = 80
                                    }

                                    FilterChip(
                                        title: "128×128",
                                        isSelected: filterDimension == 128
                                    ) {
                                        filterDimension = 128
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .padding(.top, 8)

                            // Grid
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(filteredAndSortedItems) { item in
                                    GIFThumbnailCard(item: item) {
                                        selectedItem = item
                                        showingDetail = true
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("GIF Catalogue")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
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
            }
            .sheet(item: $selectedItem) { catalogueItem in
                // Convert GIFCatalogueItem to GIFItem for the existing detail view
                let gifItem = GIFItem(
                    url: catalogueItem.gifURL,
                    size: CGSize(width: catalogueItem.dimension, height: catalogueItem.dimension),
                    frameCount: catalogueItem.frameCount,
                    fileSize: Int64(catalogueItem.fileSize),
                    creationDate: catalogueItem.createdAt,
                    thumbnailData: try? Data(contentsOf: catalogueItem.thumbnailURL)
                )
                GIFDetailView(item: gifItem)
            }
        }
    }
}

@available(iOS 26.0, *)
struct GIFThumbnailCard: View {
    let item: GIFCatalogueItem
    let action: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                ZStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(1, contentMode: .fit)

                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                    }

                    // Dimension badge
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(item.dimension)×\(item.dimension)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(8)
                        }
                        Spacer()
                    }

                    // Photos badge if saved
                    if item.photosAssetID != nil {
                        VStack {
                            HStack {
                                Image(systemName: "photo.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                                    .padding(8)
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                }
                .cornerRadius(12)
                .clipped()

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.frameCount) frames")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        Text(item.formattedSize)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(item.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadThumbnail()
        }
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

@available(iOS 26.0, *)
struct FilterChip: View {
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

@available(iOS 26.0, *)
#Preview {
    GIFCatalogueView()
}