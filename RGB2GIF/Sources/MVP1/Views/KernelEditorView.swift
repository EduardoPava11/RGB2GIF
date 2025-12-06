//
//  KernelEditorView.swift
//  RGB2GIF
//
//  ============================================================================
//  KERNEL EDITOR VIEW (Tool 3): Configure Gaussian kernel parameters
//  ============================================================================
//
//  Allows users to adjust how 81×81×81 pixels are downsampled to 729 centroids:
//  - Spatial Kernel: Gaussian σ for 9×9 spatial averaging
//  - Temporal Kernel: Gaussian σ for 9-frame temporal averaging
//
//  ============================================================================

import SwiftUI

/// Tool 3: Kernel Editor - configure TensorCube729 Gaussian sigmas
@available(iOS 26.0, *)
public struct KernelEditorView: View {

    @ObservedObject var state: MVP1State

    public init(state: MVP1State) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Explanation
                explanationSection

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Spatial Kernel Section
                spatialKernelSection

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Temporal Kernel Section
                temporalKernelSection

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Presets Section
                kernelPresetsSection
            }
            .padding()
        }
        .background(Color.black)
    }

    // MARK: - Explanation Section

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.cyan)
                Text("Downsampling Kernels")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text("Control how 81×81×81 pixels are averaged into 729 centroids")
                .font(.subheadline)
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Spatial: Each 9×9 region becomes 1 centroid")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                HStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Temporal: Every 9 frames are averaged together")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: - Spatial Kernel Section

    private var spatialKernelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "square.grid.3x3")
                    .foregroundColor(.blue)
                Text("Spatial Kernel (9×9)")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            SliderWithLabel(
                label: "Gaussian σ",
                value: $state.spatialSigma,
                range: 0.5...5.0,
                step: 0.1,
                format: "σ = %.1f"
            )

            // Kernel visualization
            SpatialKernelPreview(sigma: state.spatialSigma)
                .frame(height: 100)

            HStack {
                VStack(alignment: .leading) {
                    Text("Low σ (0.5)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text("Sharp, center-weighted")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("High σ (5.0)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text("Smooth, uniform")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }
            }
        }
    }

    // MARK: - Temporal Kernel Section

    private var temporalKernelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                Text("Temporal Kernel (9 frames)")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            SliderWithLabel(
                label: "Gaussian σ",
                value: $state.temporalSigma,
                range: 0.5...5.0,
                step: 0.1,
                format: "σ = %.1f"
            )

            // Kernel visualization
            TemporalKernelPreview(sigma: state.temporalSigma)
                .frame(height: 80)

            HStack {
                VStack(alignment: .leading) {
                    Text("Low σ (0.5)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text("Center frame dominates")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("High σ (5.0)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text("Even frame blending")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
        }
    }

    // MARK: - Kernel Presets Section

    private var kernelPresetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kernel Presets")
                .font(.headline)
                .foregroundColor(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                KernelPresetButton(
                    title: "Gaussian",
                    description: "Default (σ=2.5, 2.0)",
                    icon: "waveform"
                ) {
                    state.spatialSigma = 2.5
                    state.temporalSigma = 2.0
                }

                KernelPresetButton(
                    title: "Uniform",
                    description: "Equal weights (σ=10)",
                    icon: "square.fill"
                ) {
                    state.spatialSigma = 10.0
                    state.temporalSigma = 10.0
                }

                KernelPresetButton(
                    title: "Sharp",
                    description: "Center-focused (σ=1.0)",
                    icon: "target"
                ) {
                    state.spatialSigma = 1.0
                    state.temporalSigma = 1.0
                }

                KernelPresetButton(
                    title: "Temporal Focus",
                    description: "Smooth time, sharp space",
                    icon: "clock"
                ) {
                    state.spatialSigma = 1.5
                    state.temporalSigma = 4.0
                }
            }
        }
    }
}

// MARK: - Spatial Kernel Preview

@available(iOS 26.0, *)
private struct SpatialKernelPreview: View {
    let sigma: Float

    var body: some View {
        GeometryReader { geometry in
            let cellSize = min(geometry.size.width, geometry.size.height) / 9

            HStack(spacing: 1) {
                ForEach(0..<9, id: \.self) { y in
                    VStack(spacing: 1) {
                        ForEach(0..<9, id: \.self) { x in
                            let weight = gaussianWeight(x: x, y: y, sigma: sigma)
                            Rectangle()
                                .fill(Color.blue.opacity(Double(weight)))
                                .frame(width: cellSize - 1, height: cellSize - 1)
                        }
                    }
                }
            }
        }
    }

    private func gaussianWeight(x: Int, y: Int, sigma: Float) -> Float {
        let cx: Float = 4.0
        let cy: Float = 4.0
        let dx = Float(x) - cx
        let dy = Float(y) - cy
        let dist2 = dx * dx + dy * dy
        let weight = exp(-dist2 / (2.0 * sigma * sigma))
        // Normalize to make center = 1
        return weight
    }
}

// MARK: - Temporal Kernel Preview

@available(iOS 26.0, *)
private struct TemporalKernelPreview: View {
    let sigma: Float

    var body: some View {
        GeometryReader { geometry in
            let barWidth = (geometry.size.width - 8 * 4) / 9

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<9, id: \.self) { t in
                    let weight = temporalWeight(t: t, sigma: sigma)
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.orange.opacity(0.3 + Double(weight) * 0.7))
                            .frame(width: barWidth, height: CGFloat(weight) * (geometry.size.height - 20))

                        Text("\(t)")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }

    private func temporalWeight(t: Int, sigma: Float) -> Float {
        let center: Float = 4.0
        let dt = Float(t) - center
        let weight = exp(-dt * dt / (2.0 * sigma * sigma))
        return weight
    }
}

// MARK: - Kernel Preset Button

@available(iOS 26.0, *)
private struct KernelPresetButton: View {
    let title: String
    let description: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption2)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    KernelEditorView(state: MVP1State())
}
