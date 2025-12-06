//
//  SliceViewerView.swift
//  RGB2GIF
//
//  ============================================================================
//  SLICE VIEWER VIEW (Tool 1): Visualize tensor slices
//  ============================================================================
//
//  Shows 9×9 centroid grids from different slice perspectives:
//  - X/Y (Spatial): View spatial distribution at a time slice
//  - X/T (Horizontal Motion): View horizontal changes over time
//  - Y/T (Vertical Motion): View vertical changes over time
//
//  ============================================================================

import SwiftUI

/// Tool 1: Slice Viewer - visualize tensor from different perspectives
@available(iOS 26.0, *)
public struct SliceViewerView: View {

    @ObservedObject var state: MVP1State

    public init(state: MVP1State) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Slice type selector
                sliceTypeSelector

                // Slice index slider
                sliceIndexSlider

                // Color grid display
                colorGridSection

                // Metrics display
                metricsSection
            }
            .padding()
        }
        .background(Color.black)
    }

    // MARK: - Slice Type Selector

    private var sliceTypeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View Type")
                .font(.headline)
                .foregroundColor(.white)

            Picker("View Type", selection: $state.selectedSliceType) {
                ForEach(SliceType.allCases, id: \.self) { sliceType in
                    Text(sliceType.rawValue).tag(sliceType)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Slice Index Slider

    private var sliceIndexSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slice Index")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Text("\(state.selectedSliceIndex + 1) / 9")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

            HStack {
                Button(action: {
                    if state.selectedSliceIndex > 0 {
                        state.selectedSliceIndex -= 1
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }

                Slider(
                    value: Binding(
                        get: { Double(state.selectedSliceIndex) },
                        set: { state.selectedSliceIndex = Int($0) }
                    ),
                    in: 0...8,
                    step: 1
                )
                .accentColor(.green)

                Button(action: {
                    if state.selectedSliceIndex < 8 {
                        state.selectedSliceIndex += 1
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }
            }

            Text(state.selectedSliceType.description)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    // MARK: - Color Grid Section

    private var colorGridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("9×9 Centroid Grid")
                .font(.headline)
                .foregroundColor(.white)

            ColorGridView(
                colors: getSliceColors(),
                importanceWeights: getSliceWeights(),
                selectedCell: state.selectedCell.map { ($0.y, $0.x) },
                onCellTapped: { y, x in
                    let t = state.selectedSliceType == .xy ? state.selectedSliceIndex : (state.selectedSliceType == .xt ? y : x)
                    let finalY = state.selectedSliceType == .yt ? state.selectedSliceIndex : y
                    let finalX = state.selectedSliceType == .xt ? state.selectedSliceIndex : x
                    state.selectedCell = TensorPosition(t: t, y: finalY, x: finalX)
                }
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)

            // Selected cell info
            if let cell = state.selectedCell {
                selectedCellInfo(cell)
            }
        }
    }

    // MARK: - Selected Cell Info

    private func selectedCellInfo(_ cell: TensorPosition) -> some View {
        let centroids = state.getCentroids()
        let index = cell.flatIndex
        let color = index < centroids.count ? centroids[index] : (r: UInt8(0), g: UInt8(0), b: UInt8(0))

        return HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255))
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Position: t=\(cell.t), y=\(cell.y), x=\(cell.x)")
                    .font(.caption)
                    .foregroundColor(.white)

                Text("RGB: (\(color.r), \(color.g), \(color.b))")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Slice Metrics")
                .font(.headline)
                .foregroundColor(.white)

            if let result = state.importanceResult {
                let index = state.selectedSliceIndex
                let spatialImportance = index < result.spatialImportance.count ? result.spatialImportance[index] : 0
                let temporalImportance = index < result.temporalImportance.count ? result.temporalImportance[index] : 0

                HStack {
                    MetricCard(
                        title: "Spatial Importance",
                        value: spatialImportance,
                        rank: result.spatialRanking.firstIndex(of: index).map { $0 + 1 }
                    )

                    MetricCard(
                        title: "Temporal Importance",
                        value: temporalImportance,
                        rank: result.temporalRanking.firstIndex(of: index).map { $0 + 1 }
                    )
                }
            } else {
                Text("Run analysis to see metrics")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Helper Methods

    private func getSliceColors() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        guard let tensor = state.tensor else {
            return Array(repeating: (r: UInt8(64), g: UInt8(64), b: UInt8(64)), count: 81)
        }

        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = []
        let sliceIndex = state.selectedSliceIndex

        switch state.selectedSliceType {
        case .xy:
            // Fixed t, vary y and x
            for y in 0..<9 {
                for x in 0..<9 {
                    let centroid = tensor.centroid(t: sliceIndex, y: y, x: x)
                    colors.append(centroid)
                }
            }
        case .xt:
            // Fixed y, vary t (as rows) and x (as cols)
            for t in 0..<9 {
                for x in 0..<9 {
                    let centroid = tensor.centroid(t: t, y: sliceIndex, x: x)
                    colors.append(centroid)
                }
            }
        case .yt:
            // Fixed x, vary y (as rows) and t (as cols)
            for y in 0..<9 {
                for t in 0..<9 {
                    let centroid = tensor.centroid(t: t, y: y, x: sliceIndex)
                    colors.append(centroid)
                }
            }
        }

        return colors
    }

    private func getSliceWeights() -> [Float] {
        guard let result = state.importanceResult else {
            return Array(repeating: 0.5, count: 81)
        }

        var weights: [Float] = []
        let sliceIndex = state.selectedSliceIndex

        switch state.selectedSliceType {
        case .xy:
            // Combine spatial weights
            let spatialWeight = result.spatialImportance[safe: sliceIndex] ?? 0.5
            weights = Array(repeating: spatialWeight, count: 81)
        case .xt:
            // Each row is a temporal slice
            for t in 0..<9 {
                let tWeight = result.spatialImportance[safe: t] ?? 0.5
                for _ in 0..<9 {
                    weights.append(tWeight)
                }
            }
        case .yt:
            // Each column is a temporal slice
            for _ in 0..<9 {
                for t in 0..<9 {
                    let tWeight = result.spatialImportance[safe: t] ?? 0.5
                    weights.append(tWeight)
                }
            }
        }

        return weights
    }
}

// MARK: - Metric Card

@available(iOS 26.0, *)
private struct MetricCard: View {
    let title: String
    let value: Float
    let rank: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)

            Text(String(format: "%.3f", value))
                .font(.headline)
                .foregroundColor(.white)

            if let rank = rank {
                Text("Rank #\(rank) of 9")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    SliceViewerView(state: MVP1State())
}
