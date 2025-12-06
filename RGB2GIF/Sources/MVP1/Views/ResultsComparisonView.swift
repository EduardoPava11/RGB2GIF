//
//  ResultsComparisonView.swift
//  RGB2GIF
//
//  ============================================================================
//  RESULTS COMPARISON VIEW (Tool 4): Show spatial vs temporal importance
//  ============================================================================
//
//  Displays the output of SliceImportanceAnalyzer:
//  - 9 spatial importance scores (per temporal group)
//  - 9 temporal importance scores (per spatial column)
//  - Rankings and anchor slices
//
//  ============================================================================

import SwiftUI

/// Tool 4: Results Comparison - view spatial vs temporal importance
@available(iOS 26.0, *)
public struct ResultsComparisonView: View {

    @ObservedObject var state: MVP1State

    public init(state: MVP1State) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Status header
                analysisStatusHeader

                if let result = state.importanceResult {
                    // Spatial importance chart
                    spatialImportanceSection(result: result)

                    Divider()
                        .background(Color.gray.opacity(0.5))

                    // Temporal importance chart
                    temporalImportanceSection(result: result)

                    Divider()
                        .background(Color.gray.opacity(0.5))

                    // Rankings summary
                    rankingsSummary(result: result)

                    // Analysis info
                    analysisInfo(result: result)
                } else {
                    noAnalysisPlaceholder
                }
            }
            .padding()
        }
        .background(Color.black)
    }

    // MARK: - Analysis Status Header

    private var analysisStatusHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Analysis Results")
                    .font(.headline)
                    .foregroundColor(.white)

                if state.importanceResult != nil {
                    Text("Last updated: just now")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            Button(action: {
                state.runAnalysis()
            }) {
                HStack(spacing: 4) {
                    if state.isAnalyzing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .green))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.2))
                .foregroundColor(.green)
                .cornerRadius(8)
            }
            .disabled(state.isAnalyzing || state.tensor == nil)
        }
    }

    // MARK: - Spatial Importance Section

    private func spatialImportanceSection(result: SliceImportanceAnalyzer.ImportanceResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.3x3")
                    .foregroundColor(.blue)
                Text("Spatial Importance")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Text("9 temporal groups")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Text("How important each temporal slice is (X/Y view)")
                .font(.caption)
                .foregroundColor(.gray)

            BarChartView(
                values: result.spatialImportance,
                labels: (0..<9).map { "t=\($0)" },
                barColor: .blue,
                title: ""
            )
            .frame(height: 140)

            // Rankings
            HStack {
                Text("Ranking:")
                    .font(.caption)
                    .foregroundColor(.gray)

                ForEach(0..<min(3, result.spatialRanking.count), id: \.self) { i in
                    let sliceIndex = result.spatialRanking[i]
                    RankBadge(rank: i + 1, label: "t=\(sliceIndex)", color: .blue)
                }

                Text("...")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Temporal Importance Section

    private func temporalImportanceSection(result: SliceImportanceAnalyzer.ImportanceResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                Text("Temporal Importance")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Text("9 spatial columns")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Text("How important each spatial column is over time (X/T or Y/T view)")
                .font(.caption)
                .foregroundColor(.gray)

            BarChartView(
                values: result.temporalImportance,
                labels: (0..<9).map { "x=\($0)" },
                barColor: .orange,
                title: ""
            )
            .frame(height: 140)

            // Rankings
            HStack {
                Text("Ranking:")
                    .font(.caption)
                    .foregroundColor(.gray)

                ForEach(0..<min(3, result.temporalRanking.count), id: \.self) { i in
                    let sliceIndex = result.temporalRanking[i]
                    RankBadge(rank: i + 1, label: "x=\(sliceIndex)", color: .orange)
                }

                Text("...")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Rankings Summary

    private func rankingsSummary(result: SliceImportanceAnalyzer.ImportanceResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 16) {
                // Most important spatial
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Spatial")
                        .font(.caption)
                        .foregroundColor(.gray)

                    if let topSpatial = result.spatialRanking.first {
                        HStack {
                            Text("t=\(topSpatial)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)

                            Text(String(format: "(%.1f%%)", result.spatialImportance[topSpatial] * 100))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }

                Divider()
                    .frame(height: 40)

                // Most important temporal
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Temporal")
                        .font(.caption)
                        .foregroundColor(.gray)

                    if let topTemporal = result.temporalRanking.first {
                        HStack {
                            Text("x=\(topTemporal)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)

                            Text(String(format: "(%.1f%%)", result.temporalImportance[topTemporal] * 100))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            // Anchor slices note
            HStack {
                Image(systemName: "pin.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)

                Text("Anchor slices (t=0, t=4, t=8) always included")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Analysis Info

    private func analysisInfo(result: SliceImportanceAnalyzer.ImportanceResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration")
                .font(.caption)
                .foregroundColor(.gray)

            HStack {
                ConfigBadge(label: "Temp", value: String(format: "%.1f", state.importanceConfig.temperature))
                ConfigBadge(label: "Color", value: String(format: "%.2f", state.importanceConfig.colorVarianceWeight))
                ConfigBadge(label: "Edge", value: String(format: "%.2f", state.importanceConfig.edgeDensityWeight))
                ConfigBadge(label: "Motion", value: String(format: "%.2f", state.importanceConfig.motionWeight))
            }
        }
    }

    // MARK: - No Analysis Placeholder

    private var noAnalysisPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Analysis Results")
                .font(.headline)
                .foregroundColor(.white)

            Text("Configure weights in the \"Weights\" tab, then tap \"Refresh\" to run analysis")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            if state.tensor == nil {
                Text("(Tensor data not loaded)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 40)
    }
}

// MARK: - Rank Badge

@available(iOS 26.0, *)
private struct RankBadge: View {
    let rank: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text("#\(rank)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.6))
        .cornerRadius(4)
    }
}

// MARK: - Config Badge

@available(iOS 26.0, *)
private struct ConfigBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    ResultsComparisonView(state: MVP1State())
}
