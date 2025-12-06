//
//  ModeSelectionView.swift
//  RGB2GIF
//
//  ============================================================================
//  MODE SELECTION VIEW: Choose MVP0 or MVP1 after capture
//  ============================================================================
//
//  Presented after 81 frames are captured. User chooses:
//  - MVP0: Instant GIF generation
//  - MVP1: Interactive exploration with tools
//
//  ============================================================================

import SwiftUI

/// View for selecting processing mode after capture
@available(iOS 26.0, *)
public struct ModeSelectionView: View {

    /// Callback when mode is selected
    public let onModeSelected: (ProcessingMode) -> Void

    /// Callback when user cancels (goes back to capture)
    public let onCancel: () -> Void

    /// Frame count for display
    public let frameCount: Int

    @State private var selectedMode: ProcessingMode = .mvp0

    public init(
        frameCount: Int = 81,
        onModeSelected: @escaping (ProcessingMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.frameCount = frameCount
        self.onModeSelected = onModeSelected
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // Mode options
                modeOptionsSection

                Spacer()

                // Action buttons
                actionButtonsSection
            }
            .padding()
            .background(Color.black)
            .navigationTitle("Processing Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("\(frameCount) Frames Captured")
                .font(.headline)
                .foregroundColor(.white)

            Text("Choose how to process your GIF")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .padding(.top, 20)
    }

    // MARK: - Mode Options Section

    private var modeOptionsSection: some View {
        VStack(spacing: 16) {
            ForEach(ProcessingMode.allCases, id: \.self) { mode in
                ModeOptionCard(
                    mode: mode,
                    isSelected: selectedMode == mode,
                    onSelect: { selectedMode = mode }
                )
            }
        }
    }

    // MARK: - Action Buttons Section

    private var actionButtonsSection: some View {
        VStack(spacing: 12) {
            Button(action: {
                onModeSelected(selectedMode)
            }) {
                HStack {
                    Image(systemName: selectedMode.iconName)
                    Text("Continue with \(selectedMode.rawValue)")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.black)
                .cornerRadius(12)
                .font(.headline)
            }

            if selectedMode == .mvp1 {
                Text("You can adjust settings before generating the GIF")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Mode Option Card

@available(iOS 26.0, *)
private struct ModeOptionCard: View {
    let mode: ProcessingMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Icon
                Image(systemName: mode.iconName)
                    .font(.system(size: 28))
                    .foregroundColor(isSelected ? .green : .gray)
                    .frame(width: 44)

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.rawValue)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(mode.description)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }

                Spacer()

                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .green : .gray)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.green : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    ModeSelectionView(
        frameCount: 81,
        onModeSelected: { mode in
            print("Selected: \(mode)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
