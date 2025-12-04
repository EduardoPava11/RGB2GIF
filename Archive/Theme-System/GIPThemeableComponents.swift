//
//  GIPThemeableComponents.swift
//  RGB2GIF
//
//  GIP-Driven Themeable UI Components
//  All UI components automatically update when GIP palette changes
//

import UIKit

// MARK: - GIPButton

/// Button that themes itself based on active GIP palette
class GIPButton: UIButton, GIPThemeable {
    var currentTheme: UITheme? {
        didSet {
            if let theme = currentTheme {
                applyGIPTheme(theme)
            }
        }
    }

    /// Button style variant
    enum Style {
        case primary    // Filled with primary color
        case secondary  // Outlined with secondary color
        case ghost      // Text-only with accent color
    }

    private let style: Style

    // MARK: - Initialization

    init(style: Style = .primary) {
        self.style = style
        super.init(frame: .zero)
        setupButton()
    }

    required init?(coder: NSCoder) {
        self.style = .primary
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        // Register with theme manager
        ThemeManager.shared.register(self)

        // Base styling
        layer.cornerRadius = 12
        titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        // Don't set currentTheme here - it's set by the caller and triggers didSet
        // which would cause infinite recursion

        switch style {
        case .primary:
            backgroundColor = theme.primary
            setTitleColor(theme.primary.autoContrastText, for: .normal)
            layer.borderWidth = 0

        case .secondary:
            backgroundColor = .clear
            setTitleColor(theme.secondary, for: .normal)
            layer.borderColor = theme.secondary.cgColor
            layer.borderWidth = 2

        case .ghost:
            backgroundColor = .clear
            setTitleColor(theme.accent, for: .normal)
            layer.borderWidth = 0
        }

        // Highlight states
        setTitleColor(theme.text.withAlphaComponent(0.6), for: .highlighted)
    }
}

// MARK: - GIPLabel

/// Label that themes its text color based on active GIP palette
class GIPLabel: UILabel, GIPThemeable {
    var currentTheme: UITheme? {
        didSet {
            if let theme = currentTheme {
                applyGIPTheme(theme)
            }
        }
    }

    /// Label emphasis level
    enum Emphasis {
        case primary    // Main text
        case secondary  // De-emphasized text
        case accent     // Highlighted text
    }

    private let emphasis: Emphasis

    // MARK: - Initialization

    init(emphasis: Emphasis = .primary) {
        self.emphasis = emphasis
        super.init(frame: .zero)
        ThemeManager.shared.register(self)
    }

    required init?(coder: NSCoder) {
        self.emphasis = .primary
        super.init(coder: coder)
        ThemeManager.shared.register(self)
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        // Don't set currentTheme here - avoids infinite recursion

        switch emphasis {
        case .primary:
            textColor = theme.text
        case .secondary:
            textColor = theme.text.withAlphaComponent(0.7)
        case .accent:
            textColor = theme.accent
        }
    }
}

// MARK: - GIPBackgroundView

/// View with GIP-themed background (solid or gradient)
class GIPBackgroundView: UIView, GIPThemeable {
    var currentTheme: UITheme? {
        didSet {
            if let theme = currentTheme {
                applyGIPTheme(theme)
            }
        }
    }

    private let gradientLayer = CAGradientLayer()
    private let useGradient: Bool

    // MARK: - Initialization

    init(gradient: Bool = false) {
        self.useGradient = gradient
        super.init(frame: .zero)

        if gradient {
            layer.addSublayer(gradientLayer)
        }

        ThemeManager.shared.register(self)
    }

    required init?(coder: NSCoder) {
        self.useGradient = false
        super.init(coder: coder)
        ThemeManager.shared.register(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        // Don't set currentTheme here - avoids infinite recursion

        if useGradient {
            gradientLayer.colors = [
                theme.gradientStart.cgColor,
                theme.gradientEnd.cgColor
            ]
            gradientLayer.locations = [0.0, 1.0]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        } else {
            backgroundColor = theme.background
        }
    }
}

// MARK: - GIPProgressView

/// Progress view with GIP-themed colors
class GIPProgressView: UIView, GIPThemeable {
    var currentTheme: UITheme? {
        didSet {
            if let theme = currentTheme {
                applyGIPTheme(theme)
            }
        }
    }

    private let progressBar = UIView()
    private let trackView = UIView()

    /// Current progress (0.0 to 1.0)
    var progress: CGFloat = 0.0 {
        didSet {
            updateProgress()
        }
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        ThemeManager.shared.register(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        ThemeManager.shared.register(self)
    }

    private func setupViews() {
        // Track background
        addSubview(trackView)
        trackView.translatesAutoresizingMaskIntoConstraints = false
        trackView.layer.cornerRadius = 4

        // Progress bar
        trackView.addSubview(progressBar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.layer.cornerRadius = 4

        NSLayoutConstraint.activate([
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.topAnchor.constraint(equalTo: topAnchor),
            trackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            trackView.heightAnchor.constraint(equalToConstant: 8),

            progressBar.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
            progressBar.topAnchor.constraint(equalTo: trackView.topAnchor),
            progressBar.bottomAnchor.constraint(equalTo: trackView.bottomAnchor)
        ])

        updateProgress()
    }

    private func updateProgress() {
        let clampedProgress = max(0.0, min(1.0, progress))
        progressBar.frame.size.width = trackView.bounds.width * clampedProgress
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateProgress()
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        // Don't set currentTheme here - avoids infinite recursion
        progressBar.backgroundColor = theme.primary
        trackView.backgroundColor = theme.text.withAlphaComponent(0.2)
    }
}

// MARK: - GIPSegmentedControl

/// Segmented control with GIP-themed colors
class GIPSegmentedControl: UISegmentedControl, GIPThemeable {
    var currentTheme: UITheme? {
        didSet {
            if let theme = currentTheme {
                applyGIPTheme(theme)
            }
        }
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        ThemeManager.shared.register(self)
    }

    override init(items: [Any]?) {
        super.init(items: items)
        ThemeManager.shared.register(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        ThemeManager.shared.register(self)
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        // Don't set currentTheme here - avoids infinite recursion

        // Selected segment
        selectedSegmentTintColor = theme.primary

        // Text colors
        setTitleTextAttributes([
            .foregroundColor: theme.text.withAlphaComponent(0.6)
        ], for: .normal)

        setTitleTextAttributes([
            .foregroundColor: theme.primary.autoContrastText
        ], for: .selected)

        // Background
        backgroundColor = theme.background.withAlphaComponent(0.3)
    }
}

// MARK: - GIPSlider

/// Slider with GIP-themed colors
class GIPSlider: UISlider, GIPThemeable {
    var currentTheme: UITheme? {
        didSet {
            if let theme = currentTheme {
                applyGIPTheme(theme)
            }
        }
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        ThemeManager.shared.register(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        ThemeManager.shared.register(self)
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        // Don't set currentTheme here - avoids infinite recursion
        minimumTrackTintColor = theme.primary
        maximumTrackTintColor = theme.text.withAlphaComponent(0.2)
        thumbTintColor = theme.accent
    }
}
