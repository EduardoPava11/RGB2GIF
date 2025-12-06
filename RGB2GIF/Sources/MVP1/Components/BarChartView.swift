//
//  BarChartView.swift
//  RGB2GIF
//
//  ============================================================================
//  BAR CHART VIEW: Display importance scores as vertical bars
//  ============================================================================
//
//  Reusable component that displays 9 vertical bars representing
//  importance scores. Used in Results Comparison View to show
//  spatial and temporal importance rankings.
//
//  ============================================================================

import SwiftUI

/// Bar chart view showing importance scores
@available(iOS 26.0, *)
public struct BarChartView: View {

    /// 9 importance values (0-1)
    public let values: [Float]

    /// Labels for each bar
    public let labels: [String]

    /// Bar color
    public let barColor: Color

    /// Title for the chart
    public let title: String

    public init(
        values: [Float],
        labels: [String]? = nil,
        barColor: Color = .green,
        title: String = ""
    ) {
        self.values = values
        self.labels = labels ?? (0..<values.count).map { "\($0)" }
        self.barColor = barColor
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            GeometryReader { geometry in
                let barWidth = (geometry.size.width - CGFloat(values.count - 1) * 4) / CGFloat(values.count)
                let maxHeight = geometry.size.height - 30 // Leave room for labels

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<values.count, id: \.self) { index in
                        let value = values[safe: index] ?? 0
                        let normalizedHeight = CGFloat(value) * maxHeight

                        VStack(spacing: 2) {
                            // Value label
                            Text(String(format: "%.2f", value))
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                                .frame(height: 15)

                            // Bar
                            Rectangle()
                                .fill(barColor.opacity(0.3 + Double(value) * 0.7))
                                .frame(width: barWidth, height: max(normalizedHeight, 2))

                            // Index label
                            Text(labels[safe: index] ?? "\(index)")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                                .frame(height: 15)
                        }
                    }
                }
            }
        }
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
    VStack(spacing: 20) {
        BarChartView(
            values: [0.08, 0.09, 0.11, 0.13, 0.18, 0.13, 0.11, 0.09, 0.08],
            labels: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"],
            barColor: .blue,
            title: "Spatial Importance"
        )
        .frame(height: 150)

        BarChartView(
            values: [0.12, 0.15, 0.08, 0.17, 0.10, 0.14, 0.09, 0.10, 0.05],
            labels: ["x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8"],
            barColor: .orange,
            title: "Temporal Importance"
        )
        .frame(height: 150)
    }
    .padding()
    .background(Color.black)
}
