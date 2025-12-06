//
//  ColorGridView.swift
//  RGB2GIF
//
//  ============================================================================
//  COLOR GRID VIEW: 9×9 grid displaying centroid colors
//  ============================================================================
//
//  Reusable component that displays a 9×9 grid of colored cells.
//  Each cell shows the centroid color from the tensor slice.
//  Optional importance overlay shows brightness based on weight.
//
//  ============================================================================

import SwiftUI

/// A 9×9 grid view showing centroid colors
@available(iOS 26.0, *)
public struct ColorGridView: View {

    /// 81 colors to display (row-major order)
    public let colors: [(r: UInt8, g: UInt8, b: UInt8)]

    /// Optional importance weights (0-1) for brightness overlay
    public let importanceWeights: [Float]?

    /// Callback when a cell is tapped
    public let onCellTapped: ((Int, Int) -> Void)?

    /// Currently selected cell (y, x)
    public let selectedCell: (y: Int, x: Int)?

    public init(
        colors: [(r: UInt8, g: UInt8, b: UInt8)],
        importanceWeights: [Float]? = nil,
        selectedCell: (y: Int, x: Int)? = nil,
        onCellTapped: ((Int, Int) -> Void)? = nil
    ) {
        self.colors = colors
        self.importanceWeights = importanceWeights
        self.selectedCell = selectedCell
        self.onCellTapped = onCellTapped
    }

    public var body: some View {
        GeometryReader { geometry in
            let cellSize = min(geometry.size.width, geometry.size.height) / 9

            VStack(spacing: 1) {
                ForEach(0..<9, id: \.self) { y in
                    HStack(spacing: 1) {
                        ForEach(0..<9, id: \.self) { x in
                            let index = y * 9 + x
                            let color = index < colors.count ? colors[index] : (r: UInt8(0), g: UInt8(0), b: UInt8(0))
                            let weight = importanceWeights?[safe: index] ?? 1.0
                            let isSelected = selectedCell?.y == y && selectedCell?.x == x

                            ColorCell(
                                r: color.r,
                                g: color.g,
                                b: color.b,
                                importance: weight,
                                isSelected: isSelected,
                                size: cellSize
                            )
                            .onTapGesture {
                                onCellTapped?(y, x)
                            }
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Color Cell

@available(iOS 26.0, *)
private struct ColorCell: View {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let importance: Float
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        let baseColor = Color(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0
        )

        ZStack {
            // Base color
            Rectangle()
                .fill(baseColor)

            // Importance overlay (darker = less important)
            Rectangle()
                .fill(Color.black.opacity(Double(1.0 - importance) * 0.7))

            // Selection indicator
            if isSelected {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
            }
        }
        .frame(width: size - 1, height: size - 1)
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
    ColorGridView(
        colors: Array(repeating: (r: UInt8(128), g: UInt8(128), b: UInt8(128)), count: 81),
        importanceWeights: nil,
        selectedCell: (y: 4, x: 4),
        onCellTapped: nil
    )
    .frame(width: 300, height: 300)
    .padding()
    .background(Color.black)
}
