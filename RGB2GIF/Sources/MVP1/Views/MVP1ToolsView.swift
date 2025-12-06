//
//  MVP1ToolsView.swift
//  RGB2GIF
//
//  ============================================================================
//  MVP1 TOOLS VIEW: Tab bar navigation for all 5 MVP1 tools
//  ============================================================================
//
//  Tool 1: Slice Viewer - Visualize X/Y, X/T, Y/T slices
//  Tool 2: Importance Weight Editor - Configure analysis weights
//  Tool 3: Kernel Editor - Configure Gaussian sigmas
//  Tool 4: Results Comparison - View spatial vs temporal importance
//  Tool 5: Centroid Override - Override cells and generate GIF
//
//  ============================================================================

import SwiftUI

/// Main container view for MVP1 tools with tab navigation
@available(iOS 26.0, *)
public struct MVP1ToolsView: View {

    /// Observable state for MVP1 tools
    @ObservedObject var state: MVP1State

    /// Callback when user generates GIF
    public let onGenerate: () -> Void

    /// Callback when user cancels
    public let onCancel: () -> Void

    @State private var selectedTab: MVP1Tab = .sliceViewer

    public init(
        state: MVP1State,
        onGenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onGenerate = onGenerate
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationView {
            TabView(selection: $selectedTab) {
                SliceViewerView(state: state)
                    .tabItem {
                        Label("Slices", systemImage: "square.grid.3x3")
                    }
                    .tag(MVP1Tab.sliceViewer)

                ImportanceWeightEditorView(state: state)
                    .tabItem {
                        Label("Weights", systemImage: "slider.horizontal.3")
                    }
                    .tag(MVP1Tab.weights)

                KernelEditorView(state: state)
                    .tabItem {
                        Label("Kernel", systemImage: "waveform")
                    }
                    .tag(MVP1Tab.kernel)

                ResultsComparisonView(state: state)
                    .tabItem {
                        Label("Results", systemImage: "chart.bar")
                    }
                    .tag(MVP1Tab.results)

                CentroidOverrideView(state: state, onGenerate: onGenerate)
                    .tabItem {
                        Label("Generate", systemImage: "checkmark.circle")
                    }
                    .tag(MVP1Tab.generate)
            }
            .navigationTitle("MVP1 Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab Enum

@available(iOS 26.0, *)
private enum MVP1Tab: Hashable {
    case sliceViewer
    case weights
    case kernel
    case results
    case generate
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    MVP1ToolsView(
        state: MVP1State(),
        onGenerate: { print("Generate") },
        onCancel: { print("Cancel") }
    )
}
