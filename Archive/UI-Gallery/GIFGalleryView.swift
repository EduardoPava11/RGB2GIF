//
//  GIFGalleryView.swift
//  RGB2GIF
//
//  Gallery viewer for saved GIF files with thumbnails and metadata
//

import SwiftUI
import Combine
import UniformTypeIdentifiers
import os.log

private let galleryLogger = Logger(subsystem: "com.rgb2gif", category: "GIFGallery")

// MARK: - Data Models

struct GIFItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: CGSize
    let frameCount: Int
    let fileSize: Int64
    let creationDate: Date
    let thumbnailData: Data?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var dimensionText: String {
        "\(Int(size.width))×\(Int(size.height))"
    }
}

// MARK: - Gallery View

@available(iOS 26.0, *)
struct GIFGalleryView: View {
    @StateObject private var viewModel = GIFGalleryViewModel()
    @State private var selectedItem: GIFItem?
    @State private var showingDetail = false
    @State private var sortOrder: SortOrder = .dateNewest
    @State private var filterDimension: FilterDimension = .all

    enum SortOrder: String, CaseIterable {
        case dateNewest = "Newest"
        case dateOldest = "Oldest"
        case sizeSmallest = "Smallest"
        case sizeLargest = "Largest"
        case frameCount = "Frame Count"
    }

    enum FilterDimension: String, CaseIterable {
        case all = "All"
        case small = "80×80"
        case large = "128×128"
    }

    let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.items.isEmpty {
                    emptyStateView
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredItems) { item in
                            GIFThumbnailView(item: item)
                                .onTapGesture {
                                    selectedItem = item
                                    showingDetail = true
                                }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("GIF Gallery")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("Sort") {
                            Picker("Sort", selection: $sortOrder) {
                                ForEach(SortOrder.allCases, id: \.self) { order in
                                    Label(order.rawValue, systemImage: sortIcon(for: order))
                                        .tag(order)
                                }
                            }
                        }
                        Section("Filter") {
                            Picker("Dimension", selection: $filterDimension) {
                                ForEach(FilterDimension.allCases, id: \.self) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                        }
                    } label: {
                        Label("Options", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable {
                await viewModel.loadGIFs()
            }
            .task {
                await viewModel.loadGIFs()
            }
            .sheet(isPresented: $showingDetail) {
                if let item = selectedItem {
                    GIFDetailView(item: item)
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No GIFs Yet",
            systemImage: "photo.stack",
            description: Text("Capture some frames to create your first GIF")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredItems: [GIFItem] {
        let filtered = viewModel.items.filter { item in
            switch filterDimension {
            case .all:
                return true
            case .small:
                return item.size.width <= 80
            case .large:
                return item.size.width >= 128
            }
        }

        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .dateNewest:
                return lhs.creationDate > rhs.creationDate
            case .dateOldest:
                return lhs.creationDate < rhs.creationDate
            case .sizeSmallest:
                return lhs.fileSize < rhs.fileSize
            case .sizeLargest:
                return lhs.fileSize > rhs.fileSize
            case .frameCount:
                return lhs.frameCount > rhs.frameCount
            }
        }
    }

    private func sortIcon(for order: SortOrder) -> String {
        switch order {
        case .dateNewest, .dateOldest:
            return "calendar"
        case .sizeSmallest, .sizeLargest:
            return "arrow.up.arrow.down"
        case .frameCount:
            return "square.stack.3d.up"
        }
    }
}

// MARK: - Thumbnail View

@available(iOS 26.0, *)
struct GIFThumbnailView: View {
    let item: GIFItem
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .aspectRatio(1, contentMode: .fit)

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                // Frame count badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(item.frameCount)f")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(8)
                }
            }

            VStack(spacing: 2) {
                Text(item.dimensionText)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(item.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Load first frame as thumbnail
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return
        }

        await MainActor.run {
            self.thumbnail = UIImage(cgImage: cgImage)
        }
    }
}

// MARK: - View Model

@available(iOS 26.0, *)
@MainActor
class GIFGalleryViewModel: ObservableObject {
    @Published var items: [GIFItem] = []

    private let fileManager = FileManager.default
    private var gifDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GIFs", isDirectory: true)
    }

    init() {
        createGIFDirectoryIfNeeded()
    }

    private func createGIFDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: gifDirectory.path) {
            try? fileManager.createDirectory(at: gifDirectory, withIntermediateDirectories: true)
        }
    }

    func loadGIFs() async {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: gifDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "gif" }

            let loadedItems = await withTaskGroup(of: GIFItem?.self) { group in
                for url in urls {
                    group.addTask {
                        await self.loadGIFItem(from: url)
                    }
                }

                var items: [GIFItem] = []
                for await item in group {
                    if let item {
                        items.append(item)
                    }
                }
                return items
            }

            self.items = loadedItems
            galleryLogger.info("Loaded \(loadedItems.count) GIF files")

        } catch {
            galleryLogger.error("Failed to load GIFs: \(error)")
        }
    }

    private func loadGIFItem(from url: URL) async -> GIFItem? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)

        // Get first frame for dimensions
        guard frameCount > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }

        // Get file attributes
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes?[.size] as? Int64 ?? 0
        let creationDate = attributes?[.creationDate] as? Date ?? Date()

        // Get thumbnail data (first frame)
        var thumbnailData: Data?
        if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let uiImage = UIImage(cgImage: cgImage)
            if let data = uiImage.jpegData(compressionQuality: 0.7) {
                thumbnailData = data
            }
        }

        return GIFItem(
            url: url,
            size: CGSize(width: width, height: height),
            frameCount: frameCount,
            fileSize: fileSize,
            creationDate: creationDate,
            thumbnailData: thumbnailData
        )
    }
}