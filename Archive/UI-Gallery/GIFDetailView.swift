//
//  GIFDetailView.swift
//  RGB2GIF
//
//  Detailed view for GIF playback, palette analysis, and sharing
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import Combine
import os.log

private let detailLogger = Logger(subsystem: "com.rgb2gif", category: "GIFDetail")

@available(iOS 26.0, *)
struct GIFDetailView: View {
    let item: GIFItem
    @State private var selectedTab = 0
    @State private var isPlaying = true
    @State private var showPalette3D = false
    @State private var showShareSheet = false
    @State private var saveStatus: SaveStatus?
    @State private var show3DUnderConstruction = false
    @Environment(\.dismiss) private var dismiss

    enum SaveStatus {
        case saving
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                Picker("View Mode", selection: $selectedTab) {
                    Text("Animation").tag(0)
                    Text("Palette").tag(1)
                    Text("Analysis").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                // Content area
                TabView(selection: $selectedTab) {
                    GIFPlayerView(url: item.url, isPlaying: $isPlaying)
                        .tag(0)

                    PaletteVisualizationView(
                        url: item.url,
                        show3D: $showPalette3D
                    )
                    .tag(1)

                    GIFAnalysisView(item: item)
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Action buttons
                actionButtons
            }
            .navigationTitle(item.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(url: item.url)
            }
            .overlay(alignment: .top) {
                if let status = saveStatus {
                    SaveStatusBanner(status: status)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            if selectedTab == 0 {
                // Animation controls
                Button(action: { isPlaying.toggle() }) {
                    Label(isPlaying ? "Pause" : "Play",
                          systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if selectedTab == 1 {
                // Palette controls - 3D view under construction
                Button(action: { show3DUnderConstruction = true }) {
                    Label("3D View", systemImage: "cube")
                }
                .buttonStyle(.bordered)
                .alert("Under Construction", isPresented: $show3DUnderConstruction) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("3D Palette Visualization is coming soon!")
                }
            }

            Spacer()

            Button(action: saveToPhotos) {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(saveStatus != nil)
        }
        .padding()
    }

    private func saveToPhotos() {
        Task {
            await MainActor.run {
                saveStatus = .saving
            }

            do {
                _ = try await PhotosGIFSaver.saveGIF(at: item.url)
                await MainActor.run {
                    saveStatus = .success
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        saveStatus = nil
                    }
                }
            } catch {
                await MainActor.run {
                    saveStatus = .failure(error.localizedDescription)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation {
                        saveStatus = nil
                    }
                }
            }
        }
    }
}

// MARK: - GIF Player View

@available(iOS 26.0, *)
struct GIFPlayerView: UIViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .systemBackground
        context.coordinator.setup(imageView: imageView, url: url)
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        context.coordinator.updatePlayback(isPlaying: isPlaying)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        private var displayLink: CADisplayLink?
        private var frames: [CGImage] = []
        private var delays: [TimeInterval] = []
        private var currentFrameIndex = 0
        private var elapsedTime: TimeInterval = 0
        private weak var imageView: UIImageView?

        func setup(imageView: UIImageView, url: URL) {
            self.imageView = imageView
            loadGIF(from: url)
        }

        func updatePlayback(isPlaying: Bool) {
            if isPlaying {
                startAnimation()
            } else {
                stopAnimation()
            }
        }

        private func loadGIF(from url: URL) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return
            }

            let frameCount = CGImageSourceGetCount(source)
            frames.reserveCapacity(frameCount)
            delays.reserveCapacity(frameCount)

            for i in 0..<frameCount {
                // Get frame
                if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) {
                    frames.append(cgImage)
                }

                // Get delay
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                   let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {

                    let delay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                        ?? gifProperties[kCGImagePropertyGIFDelayTime as String] as? Double
                        ?? 0.1

                    delays.append(max(0.01, delay)) // Minimum 10ms
                } else {
                    delays.append(0.1)
                }
            }

            if !frames.isEmpty {
                imageView?.image = UIImage(cgImage: frames[0])
            }
        }

        private func startAnimation() {
            guard displayLink == nil, !frames.isEmpty else { return }

            let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 10,
                maximum: 120,
                preferred: 60
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopAnimation() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
            guard !frames.isEmpty, !delays.isEmpty else { return }

            elapsedTime += displayLink.targetTimestamp - displayLink.timestamp

            if elapsedTime >= delays[currentFrameIndex] {
                elapsedTime = 0
                currentFrameIndex = (currentFrameIndex + 1) % frames.count
                imageView?.image = UIImage(cgImage: frames[currentFrameIndex])
            }
        }
    }
}

// MARK: - Palette Visualization

@available(iOS 26.0, *)
struct PaletteVisualizationView: View {
    let url: URL
    @Binding var show3D: Bool
    @State private var palettes: [[Color]] = []
    @State private var currentFrame = 0
    @State private var isAnimating = true

    var body: some View {
        VStack {
            if show3D {
                Palette3DView(palettes: palettes, currentFrame: $currentFrame)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Palette2DGridView(palette: currentPalette)
                    .aspectRatio(1, contentMode: .fit)
            }

            // Frame selector
            HStack {
                Text("Frame \(currentFrame + 1)/\(palettes.count)")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(currentFrame) },
                        set: { currentFrame = Int($0) }
                    ),
                    in: 0...Double(max(0, palettes.count - 1)),
                    step: 1
                )
                Toggle("Animate", isOn: $isAnimating)
                    .toggleStyle(.button)
            }
            .padding()
        }
        .task {
            await loadPalettes()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            if isAnimating && !palettes.isEmpty {
                currentFrame = (currentFrame + 1) % palettes.count
            }
        }
    }

    private var currentPalette: [Color] {
        guard currentFrame < palettes.count else {
            return []
        }
        return palettes[currentFrame]
    }

    private func loadPalettes() async {
        guard let analyzer = GIFPaletteAnalyzer(url: url) else { return }
        let extractedPalettes = await analyzer.extractPalettes()
        await MainActor.run {
            self.palettes = extractedPalettes
        }
    }
}

// MARK: - 2D Palette Grid

@available(iOS 26.0, *)
struct Palette2DGridView: View {
    let palette: [Color]
    let gridSize = 16

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let cellSize = min(size.width, size.height) / CGFloat(gridSize)

                for (index, color) in palette.enumerated() {
                    let row = index / gridSize
                    let col = index % gridSize

                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )

                    context.fill(Path(rect), with: .color(color))

                    // Add grid lines
                    context.stroke(
                        Path(rect),
                        with: .color(.secondary.opacity(0.2)),
                        lineWidth: 0.5
                    )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Analysis View

@available(iOS 26.0, *)
struct GIFAnalysisView: View {
    let item: GIFItem
    @State private var analysis: GIFAnalysis?

    struct GIFAnalysis {
        let totalColors: Int
        let averageDelay: TimeInterval
        let compressionRatio: Double
        let hasTransparency: Bool
        let colorDistribution: [Color: Int]
        let frameSizes: [Int]
    }

    var body: some View {
        ScrollView {
            if let analysis {
                VStack(alignment: .leading, spacing: 16) {
                    analysisSection("File Info") {
                        InfoRow(label: "Dimensions", value: item.dimensionText)
                        InfoRow(label: "Frames", value: "\(item.frameCount)")
                        InfoRow(label: "File Size", value: item.formattedSize)
                        InfoRow(label: "Compression", value: String(format: "%.1fx", analysis.compressionRatio))
                    }

                    analysisSection("Color Info") {
                        InfoRow(label: "Total Colors", value: "\(analysis.totalColors)")
                        InfoRow(label: "Transparency", value: analysis.hasTransparency ? "Yes" : "No")
                    }

                    analysisSection("Timing") {
                        InfoRow(label: "Avg Frame Delay", value: String(format: "%.2fs", analysis.averageDelay))
                        InfoRow(label: "Effective FPS", value: String(format: "%.1f", 1.0 / analysis.averageDelay))
                        InfoRow(label: "Duration", value: String(format: "%.1fs", analysis.averageDelay * Double(item.frameCount)))
                    }

                    analysisSection("Frame Sizes") {
                        FrameSizeChart(sizes: analysis.frameSizes)
                            .frame(height: 100)
                    }
                }
                .padding()
            } else {
                ProgressView("Analyzing...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await analyze()
        }
    }

    private func analysisSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func analyze() async {
        // Perform analysis
        // This would analyze the GIF structure, colors, compression, etc.
        // Placeholder implementation
        await MainActor.run {
            self.analysis = GIFAnalysis(
                totalColors: 256,
                averageDelay: 0.1,
                compressionRatio: 4.2,
                hasTransparency: false,
                colorDistribution: [:],
                frameSizes: Array(repeating: 6400, count: item.frameCount)
            )
        }
    }
}

// MARK: - Helper Views

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}

struct FrameSizeChart: View {
    let sizes: [Int]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !sizes.isEmpty else { return }

                let maxSize = sizes.max() ?? 1
                let barWidth = size.width / CGFloat(sizes.count)

                for (index, frameSize) in sizes.enumerated() {
                    let height = (CGFloat(frameSize) / CGFloat(maxSize)) * size.height
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth,
                        y: size.height - height,
                        width: barWidth - 1,
                        height: height
                    )

                    context.fill(
                        Path(rect),
                        with: .color(.blue.opacity(0.7))
                    )
                }
            }
        }
    }
}

struct SaveStatusBanner: View {
    let status: GIFDetailView.SaveStatus

    var body: some View {
        HStack {
            switch status {
            case .saving:
                ProgressView()
                    .scaleEffect(0.8)
                Text("Saving to Photos...")
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Saved Successfully!")
            case .failure(let error):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(Capsule())
        .padding()
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Use NSItemProvider with proper UTI for GIF files
        let itemProvider = NSItemProvider()
        itemProvider.registerFileRepresentation(
            forTypeIdentifier: UTType.gif.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }

        return UIActivityViewController(activityItems: [itemProvider], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}