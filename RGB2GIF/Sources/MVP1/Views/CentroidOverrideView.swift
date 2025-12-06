//
//  CentroidOverrideView.swift
//  RGB2GIF
//
//  ============================================================================
//  CENTROID OVERRIDE VIEW (Tool 5): Override cells and generate GIF
//  ============================================================================
//
//  Allows users to:
//  - Navigate the 9×9×9 tensor grid
//  - Override RGB values for specific cells
//  - Lock cells from analysis changes
//  - Generate the final GIF with applied settings
//
//  ============================================================================

import SwiftUI

/// Tool 5: Centroid Override - override cells and generate GIF
@available(iOS 26.0, *)
public struct CentroidOverrideView: View {

    @ObservedObject var state: MVP1State

    /// Callback when user generates GIF
    public let onGenerate: () -> Void

    @State private var showColorPicker = false

    public init(state: MVP1State, onGenerate: @escaping () -> Void) {
        self.state = state
        self.onGenerate = onGenerate
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Tensor navigation
                tensorNavigationSection

                // Selected cell editor
                if let cell = state.selectedCell {
                    selectedCellEditor(cell)
                } else {
                    selectCellPrompt
                }

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Override summary
                overrideSummarySection

                // Generate button
                generateButton
            }
            .padding()
        }
        .background(Color.black)
    }

    // MARK: - Tensor Navigation Section

    private var tensorNavigationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "cube.fill")
                    .foregroundColor(.purple)
                Text("9×9×9 Tensor Navigation")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            // Layer selector
            HStack {
                Button(action: {
                    if state.selectedSliceIndex > 0 {
                        state.selectedSliceIndex -= 1
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .padding(8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }
                .foregroundColor(.white)

                Spacer()

                Text("Layer t=\(state.selectedSliceIndex)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    if state.selectedSliceIndex < 8 {
                        state.selectedSliceIndex += 1
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .padding(8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }
                .foregroundColor(.white)
            }

            // Color grid for current layer
            ColorGridView(
                colors: getLayerColors(),
                importanceWeights: nil,
                selectedCell: getGridSelection(),
                onCellTapped: { y, x in
                    state.selectedCell = TensorPosition(t: state.selectedSliceIndex, y: y, x: x)
                }
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
        }
    }

    // MARK: - Select Cell Prompt

    private var selectCellPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 32))
                .foregroundColor(.gray)

            Text("Tap a cell to select it")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Selected Cell Editor

    private func selectedCellEditor(_ cell: TensorPosition) -> some View {
        let centroids = state.getCentroids()
        let index = cell.flatIndex
        let color = index < centroids.count ? centroids[index] : (r: UInt8(0), g: UInt8(0), b: UInt8(0))
        let hasOverride = state.rgbOverrides[cell] != nil
        let isLocked = state.lockedCells.contains(cell)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Selected Cell")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Text("t=\(cell.t), y=\(cell.y), x=\(cell.x)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

            // Color display
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255))
                    .frame(width: 60, height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("RGB: (\(color.r), \(color.g), \(color.b))")
                        .font(.subheadline)
                        .foregroundColor(.white)

                    Text("Hex: #\(String(format: "%02X%02X%02X", color.r, color.g, color.b))")
                        .font(.caption)
                        .foregroundColor(.gray)

                    if hasOverride {
                        HStack {
                            Image(systemName: "pencil.circle.fill")
                                .foregroundColor(.yellow)
                            Text("Overridden")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    }
                }

                Spacer()
            }

            // Action buttons
            HStack(spacing: 12) {
                Button(action: {
                    showColorPicker = true
                }) {
                    HStack {
                        Image(systemName: "paintbrush")
                        Text("Override RGB")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.3))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
                }

                Button(action: {
                    if isLocked {
                        state.lockedCells.remove(cell)
                    } else {
                        state.lockedCells.insert(cell)
                    }
                }) {
                    HStack {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                        Text(isLocked ? "Unlock" : "Lock")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isLocked ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.3))
                    .foregroundColor(isLocked ? .yellow : .white)
                    .cornerRadius(8)
                }
            }

            // Clear override button
            if hasOverride {
                Button(action: {
                    state.rgbOverrides.removeValue(forKey: cell)
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Clear Override")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.2))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .sheet(isPresented: $showColorPicker) {
            ColorPickerSheet(
                initialColor: color,
                onSave: { newColor in
                    state.rgbOverrides[cell] = newColor
                    showColorPicker = false
                },
                onCancel: {
                    showColorPicker = false
                }
            )
        }
    }

    // MARK: - Override Summary Section

    private var overrideSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Override Summary")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 16) {
                SummaryBadge(
                    icon: "pencil.circle",
                    label: "RGB Overrides",
                    count: state.rgbOverrides.count,
                    color: .blue
                )

                SummaryBadge(
                    icon: "lock.fill",
                    label: "Locked Cells",
                    count: state.lockedCells.count,
                    color: .yellow
                )

                SummaryBadge(
                    icon: "slider.horizontal.3",
                    label: "Weight Overrides",
                    count: state.weightOverrides.count,
                    color: .orange
                )
            }

            if !state.rgbOverrides.isEmpty || !state.lockedCells.isEmpty {
                Button(action: {
                    state.rgbOverrides.removeAll()
                    state.lockedCells.removeAll()
                    state.weightOverrides.removeAll()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear All Overrides")
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Generate Button

    private var generateButton: some View {
        VStack(spacing: 12) {
            Button(action: {
                onGenerate()
            }) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Generate 729 Centroids → GIF")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.black)
                .cornerRadius(12)
                .font(.headline)
            }

            Text("Applies: Kernel weights + Importance analysis + Overrides")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Text("→ Standard MVP0 pipeline: 729 → 256 → LZW → GIF")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    // MARK: - Helper Methods

    private func getLayerColors() -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let centroids = state.getCentroids()
        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = []

        let t = state.selectedSliceIndex
        for y in 0..<9 {
            for x in 0..<9 {
                let index = t * 81 + y * 9 + x
                if index < centroids.count {
                    colors.append(centroids[index])
                } else {
                    colors.append((r: 64, g: 64, b: 64))
                }
            }
        }

        return colors
    }

    private func getGridSelection() -> (y: Int, x: Int)? {
        guard let cell = state.selectedCell,
              cell.t == state.selectedSliceIndex else {
            return nil
        }
        return (y: cell.y, x: cell.x)
    }
}

// MARK: - Summary Badge

@available(iOS 26.0, *)
private struct SummaryBadge: View {
    let icon: String
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)

            Text("\(count)")
                .font(.headline)
                .foregroundColor(.white)

            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Color Picker Sheet

@available(iOS 26.0, *)
private struct ColorPickerSheet: View {
    let initialColor: (r: UInt8, g: UInt8, b: UInt8)
    let onSave: ((r: UInt8, g: UInt8, b: UInt8)) -> Void
    let onCancel: () -> Void

    @State private var red: Double
    @State private var green: Double
    @State private var blue: Double

    init(
        initialColor: (r: UInt8, g: UInt8, b: UInt8),
        onSave: @escaping ((r: UInt8, g: UInt8, b: UInt8)) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialColor = initialColor
        self.onSave = onSave
        self.onCancel = onCancel
        _red = State(initialValue: Double(initialColor.r))
        _green = State(initialValue: Double(initialColor.g))
        _blue = State(initialValue: Double(initialColor.b))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Color preview
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: red / 255, green: green / 255, blue: blue / 255))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

                // RGB sliders
                VStack(spacing: 16) {
                    ColorSlider(label: "Red", value: $red, color: .red)
                    ColorSlider(label: "Green", value: $green, color: .green)
                    ColorSlider(label: "Blue", value: $blue, color: .blue)
                }

                // Hex display
                Text("Hex: #\(String(format: "%02X%02X%02X", Int(red), Int(green), Int(blue)))")
                    .font(.caption)
                    .foregroundColor(.gray)

                Spacer()
            }
            .padding()
            .background(Color.black)
            .navigationTitle("Override RGB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.red)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave((r: UInt8(red), g: UInt8(green), b: UInt8(blue)))
                    }
                    .foregroundColor(.green)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Color Slider

@available(iOS 26.0, *)
private struct ColorSlider: View {
    let label: String
    @Binding var value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Text("\(Int(value))")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .monospacedDigit()
            }

            Slider(value: $value, in: 0...255, step: 1)
                .accentColor(color)
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    CentroidOverrideView(state: MVP1State(), onGenerate: { print("Generate") })
}
