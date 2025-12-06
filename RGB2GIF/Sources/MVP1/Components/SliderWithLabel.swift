//
//  SliderWithLabel.swift
//  RGB2GIF
//
//  ============================================================================
//  SLIDER WITH LABEL: Reusable labeled slider component
//  ============================================================================
//
//  A slider with a label and value display. Used throughout MVP1 tools
//  for adjusting numerical parameters like weights and sigmas.
//
//  ============================================================================

import SwiftUI

/// Labeled slider component
@available(iOS 26.0, *)
public struct SliderWithLabel: View {

    /// Label text
    public let label: String

    /// Bound value
    @Binding public var value: Float

    /// Range for the slider
    public let range: ClosedRange<Float>

    /// Step increment
    public let step: Float

    /// Format string for value display
    public let format: String

    public init(
        label: String,
        value: Binding<Float>,
        range: ClosedRange<Float> = 0...1,
        step: Float = 0.1,
        format: String = "%.2f"
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Text(String(format: format, value))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .accentColor(.green)
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    struct PreviewWrapper: View {
        @State private var value1: Float = 0.6
        @State private var value2: Float = 2.5
        @State private var value3: Float = 1.0

        var body: some View {
            VStack(spacing: 20) {
                SliderWithLabel(
                    label: "Color Variance Weight",
                    value: $value1,
                    range: 0...1,
                    step: 0.05
                )

                SliderWithLabel(
                    label: "Spatial Sigma",
                    value: $value2,
                    range: 0.5...5.0,
                    step: 0.1,
                    format: "%.1f"
                )

                SliderWithLabel(
                    label: "Temperature",
                    value: $value3,
                    range: 0.1...10.0,
                    step: 0.1,
                    format: "%.1f"
                )
            }
            .padding()
            .background(Color.black)
        }
    }

    return PreviewWrapper()
}
