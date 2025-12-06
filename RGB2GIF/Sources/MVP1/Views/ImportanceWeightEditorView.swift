//
//  ImportanceWeightEditorView.swift
//  RGB2GIF
//
//  ============================================================================
//  IMPORTANCE WEIGHT EDITOR VIEW (Tool 2): Configure analysis weights
//  ============================================================================
//
//  Allows users to adjust SliceImportanceAnalyzer.Config parameters:
//  - Spatial analysis: colorVarianceWeight, edgeDensityWeight
//  - Temporal analysis: motionWeight, frameDeltaWeight
//  - Softmax temperature for normalization
//
//  ============================================================================

import SwiftUI

/// Tool 2: Importance Weight Editor - configure SliceImportanceAnalyzer.Config
@available(iOS 26.0, *)
public struct ImportanceWeightEditorView: View {

    @ObservedObject var state: MVP1State

    public init(state: MVP1State) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Spatial Analysis Section
                spatialAnalysisSection

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Temporal Analysis Section
                temporalAnalysisSection

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Normalization Section
                normalizationSection

                Divider()
                    .background(Color.gray.opacity(0.5))

                // Presets Section
                presetsSection

                // Preview Button
                previewButton
            }
            .padding()
        }
        .background(Color.black)
    }

    // MARK: - Spatial Analysis Section

    private var spatialAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "square.grid.3x3")
                    .foregroundColor(.blue)
                Text("Spatial Analysis (X/Y Slices)")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text("How spatial characteristics influence slice importance")
                .font(.caption)
                .foregroundColor(.gray)

            SliderWithLabel(
                label: "Color Variance Weight",
                value: $state.importanceConfig.colorVarianceWeight,
                range: 0...1,
                step: 0.05
            )

            Text("High variance = more important")
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(.leading, 8)

            SliderWithLabel(
                label: "Edge Density Weight",
                value: $state.importanceConfig.edgeDensityWeight,
                range: 0...1,
                step: 0.05
            )

            Text("More edges = more detail")
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(.leading, 8)
        }
    }

    // MARK: - Temporal Analysis Section

    private var temporalAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                Text("Temporal Analysis (X/T, Y/T Slices)")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text("How temporal characteristics influence slice importance")
                .font(.caption)
                .foregroundColor(.gray)

            SliderWithLabel(
                label: "Motion Weight",
                value: $state.importanceConfig.motionWeight,
                range: 0...1,
                step: 0.05
            )

            Text("High motion = important")
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(.leading, 8)

            SliderWithLabel(
                label: "Frame Delta Weight",
                value: $state.importanceConfig.frameDeltaWeight,
                range: 0...1,
                step: 0.05
            )

            Text("Rapid changes = important")
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(.leading, 8)
        }
    }

    // MARK: - Normalization Section

    private var normalizationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "function")
                    .foregroundColor(.purple)
                Text("Normalization")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text("Controls how scores are distributed across slices")
                .font(.caption)
                .foregroundColor(.gray)

            SliderWithLabel(
                label: "Softmax Temperature",
                value: $state.importanceConfig.temperature,
                range: 0.1...10.0,
                step: 0.1,
                format: "%.1f"
            )

            HStack {
                VStack(alignment: .leading) {
                    Text("Low (0.1)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text("Sharp contrast")
                        .font(.caption2)
                        .foregroundColor(.green)
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("High (10.0)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text("More uniform")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
        }
    }

    // MARK: - Presets Section

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets")
                .font(.headline)
                .foregroundColor(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                PresetButton(title: "Balanced", description: "Default weights", icon: "equal.circle") {
                    state.applyBalancedPreset()
                }

                PresetButton(title: "Edge Focus", description: "Emphasize detail", icon: "square.on.square") {
                    state.applyEdgeFocusPreset()
                }

                PresetButton(title: "Motion Focus", description: "Smooth animation", icon: "arrow.left.arrow.right") {
                    state.applyMotionFocusPreset()
                }

                PresetButton(title: "Uniform", description: "Equal importance", icon: "square.grid.3x3.fill") {
                    state.applyUniformPreset()
                }
            }
        }
    }

    // MARK: - Preview Button

    private var previewButton: some View {
        Button(action: {
            state.runAnalysis()
        }) {
            HStack {
                if state.isAnalyzing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                } else {
                    Image(systemName: "play.circle")
                }
                Text(state.isAnalyzing ? "Analyzing..." : "Preview Analysis")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .foregroundColor(.black)
            .cornerRadius(12)
            .font(.headline)
        }
        .disabled(state.isAnalyzing || state.tensor == nil)
        .opacity(state.tensor == nil ? 0.5 : 1.0)
    }
}

// MARK: - Preset Button

@available(iOS 26.0, *)
private struct PresetButton: View {
    let title: String
    let description: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption2)
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    ImportanceWeightEditorView(state: MVP1State())
}
