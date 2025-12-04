# GIP-Driven UI & Cartridge System Architecture

## Core Concept: **Palettes as UI Themes**

### **Philosophy**
The GIP file isn't just data—it's the **visual identity** of the app experience. Each capture creates a "cartridge" (GIP + GIX + GIF89a) that **skins the entire UI** with its palette colors.

---

## State-Based UI Color System

### **State 1: Initial Launch (No Cartridge Loaded)**
```
┌─────────────────────────────────────┐
│  ███ RGB2GIF (White on Black)      │ ← App Title
│                                     │
│     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓        │ ← Grayscale UI
│     ▓                      ▓        │   NO COLOR
│     ▓  CAMERA PREVIEW      ▓        │   Black/White/Gray only
│     ▓  (Full-screen)       ▓        │
│     ▓                      ▓        │
│     ▓    ╭──────────╮      ▓        │ ← Square frame (white)
│     ▓    │          │      ▓        │
│     ▓    │  CAPTURE │      ▓        │
│     ▓    │  AREA    │      ▓        │
│     ▓    ╰──────────╯      ▓        │
│     ▓                      ▓        │
│     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓        │
│                                     │
│   No GIP loaded                     │ ← Status text (gray)
│   Tap to create first cartridge    │
│                                     │
│        ┌─────┐                      │ ← Capture button (white)
│        │  ●  │                      │
│        └─────┘                      │
└─────────────────────────────────────┘

UI Colors:
- Background: #000000 (black)
- Foreground: #FFFFFF (white)
- Accents: #808080 (gray)
- No gradients, no color
- Minimalist, high-contrast
```

### **State 2: During Capture (Still No GIP)**
```
UI remains black-and-white
Square frame pulses (white → gray → white)
Status: "Capturing... 5/32" (white text)
```

### **State 3: First GIP Created (Palette Extracted)**
```
┌─────────────────────────────────────┐
│  RGB2GIF (Now colored!)             │ ← Title now uses GIP[0] (dominant color)
│                                     │
│  Processing...                      │
│  ████████████████░░░░ 80%           │ ← Progress bar uses GIP gradient
│                                     │
│  🎨 Palette extracted: 256 colors   │
│                                     │
│  Dominant colors found:             │
│  ███ ███ ███ ███ ███                │ ← Top 5 colors from GIP
│                                     │
│  Applying palette to UI...          │
└─────────────────────────────────────┘

Transition effect:
- UI elements "bloom" from black-and-white to color
- Each UI component receives a color from GIP:
  - Buttons: GIP[0] (most prominent color)
  - Borders: GIP[1] (secondary color)
  - Backgrounds: GIP[2-5] (gradient)
  - Text: Automatically choose high-contrast color from GIP
```

### **State 4: Main Menu Unlocked (Cartridge Active)**
```
┌─────────────────────────────────────┐
│  ██ RGB2GIF █████████               │ ← Header uses GIP gradient
│  └─ Cartridge #001 loaded           │
│                                     │
│  ┌─────────┬─────────┬─────────┐   │
│  │ [GIFs]  │ [GIXs]  │ [GIPs]  │   │ ← Tabs use GIP[0-2]
│  └─────────┴─────────┴─────────┘   │
│     ▔▔▔                             │
│                                     │
│  Gallery (0 items)                  │ ← Background: GIP[255] (darkest)
│  ┌───────────────────────────────┐  │   or black if not available
│  │ Create your first GIF!        │  │
│  │                               │  │
│  │   [+ New Capture]             │  │ ← Button: GIP[0] fill
│  │                               │  │             GIP[1] border
│  └───────────────────────────────┘  │
│                                     │
│  🎨 Active Palette: "Sunset"        │ ← Palette name (auto-generated)
│  ███████████████████████████        │ ← GIP preview (all 256 colors)
│                                     │
│  [Swap Palette] [Camera]            │ ← Action buttons
└─────────────────────────────────────┘

UI Theming Rules:
1. Header gradient: GIP[0] → GIP[128] → GIP[255]
2. Tab selected: GIP[0] (solid)
3. Tab unselected: GIP[128] (50% opacity)
4. Buttons: GIP[0] background, GIP[255] text (auto-contrast)
5. Borders: GIP[1]
6. Text: Auto-select from GIP for max contrast against background
```

---

## Cartridge Architecture

### **What is a Cartridge?**
A cartridge is a **complete visual + data package**:
```
Cartridge_20250115_143052/
├── palette.gip          ← 256-color palette (800 bytes)
├── frames.gix           ← Index stream (32 frames, ~1.5 MB)
├── output.gif           ← Final GIF89a (~1.5 MB)
├── metadata.json        ← Session info
└── ui_theme.json        ← Extracted UI color scheme
```

**`ui_theme.json` Structure:**
```json
{
  "cartridge_id": "20250115_143052",
  "palette_hash": "sha256:a1b2c3...",
  "created_at": "2025-01-15T14:30:52Z",
  "ui_colors": {
    "primary": "#FF6B35",      // GIP[0] - Most dominant color
    "secondary": "#F7931E",    // GIP[1] - Secondary accent
    "tertiary": "#FDC830",     // GIP[2] - Tertiary accent
    "background": "#1A1A1A",   // GIP[255] or black
    "text": "#FFFFFF",         // Auto-contrast
    "gradient": [              // Top 8 colors for gradients
      "#FF6B35", "#F7931E", "#FDC830", "#C9D6FF",
      "#E2E2E2", "#A8DADC", "#457B9D", "#1D3557"
    ]
  },
  "palette_name": "Sunset",    // Auto-generated from color analysis
  "mood": "warm",              // warm|cool|neutral|vibrant
  "dominant_hue": 15           // 0-360 degrees (HSV)
}
```

### **Cartridge Slot System**
```
┌─────────────────────────────────────┐
│  Cartridge Slots                    │
│                                     │
│  SLOT 1: [████ Sunset    ] ← ACTIVE│ ← Currently loaded
│           32 frames, 1.2 MB         │   UI is themed with this
│           Created: 1 min ago        │
│                                     │
│  SLOT 2: [████ Ocean     ] STORED  │ ← Inactive
│           32 frames, 1.5 MB         │
│           Created: 5 min ago        │
│                                     │
│  SLOT 3: [████ Forest    ] STORED  │
│           32 frames, 1.1 MB         │
│           Created: 10 min ago       │
│                                     │
│  [Tap to swap cartridge]            │ ← Swap = instant UI re-theme
└─────────────────────────────────────┘

Swap Behavior:
1. User taps "SLOT 2: Ocean"
2. UI fade-out to black (0.3s)
3. Load palette.gip from Ocean cartridge
4. Extract ui_theme.json colors
5. Rebuild UI gradients/colors
6. Fade-in with new theme (0.5s)
7. Total swap time: < 1 second
```

---

## GIP → UI Color Extraction Algorithm

### **Step 1: Analyze Palette**
```swift
func extractUITheme(from gip: GIP) -> UITheme {
    let palette = gip.rgb  // 256 × 3 bytes (RGB)

    // 1. Convert to HSV for analysis
    let hsvPalette = palette.map { rgb in
        RGBtoHSV(r: rgb[0], g: rgb[1], b: rgb[2])
    }

    // 2. Sort by saturation * value (prominence)
    let sortedByProminence = palette.enumerated().sorted { a, b in
        let aHSV = hsvPalette[a.offset]
        let bHSV = hsvPalette[b.offset]
        return (aHSV.s * aHSV.v) > (bHSV.s * bHSV.v)
    }

    // 3. Extract dominant color (most saturated)
    let primary = sortedByProminence[0].element  // GIP[0]

    // 4. Extract secondary (different hue, high saturation)
    let secondary = sortedByProminence.first { color in
        let hsv = hsvPalette[sortedByProminence.firstIndex(of: color)!]
        let primaryHSV = hsvPalette[0]
        return abs(hsv.h - primaryHSV.h) > 30  // 30° hue difference
    } ?? sortedByProminence[1].element

    // 5. Find background (darkest or lightest)
    let background = palette.min { a, b in
        luminance(a) < luminance(b)
    } ?? [0, 0, 0]

    // 6. Auto-contrast text color
    let textColor = luminance(background) < 128 ? [255, 255, 255] : [0, 0, 0]

    // 7. Generate gradient (top 8 colors by diversity)
    let gradient = diverseSample(from: sortedByProminence, count: 8)

    // 8. Classify mood
    let avgHue = hsvPalette.reduce(0.0) { $0 + $1.h } / Float(hsvPalette.count)
    let mood = classifyMood(hue: avgHue)

    // 9. Generate name
    let paletteName = generatePaletteName(mood: mood, dominantColor: primary)

    return UITheme(
        primary: primary,
        secondary: secondary,
        background: background,
        text: textColor,
        gradient: gradient,
        mood: mood,
        name: paletteName
    )
}
```

### **Step 2: Apply Theme to UI**
```swift
func applyTheme(_ theme: UITheme) {
    // Animate color transitions
    UIView.animate(withDuration: 0.5, animations: {
        // Navigation bar
        self.navigationController?.navigationBar.barTintColor = theme.primaryUIColor
        self.navigationController?.navigationBar.tintColor = theme.textUIColor

        // Tab bar
        self.tabBarController?.tabBar.barTintColor = theme.backgroundUIColor
        self.tabBarController?.tabBar.tintColor = theme.primaryUIColor

        // Buttons
        self.captureButton.backgroundColor = theme.primaryUIColor
        self.captureButton.setTitleColor(theme.textUIColor, for: .normal)

        // Status labels
        self.statusLabel.textColor = theme.secondaryUIColor

        // Backgrounds
        self.view.backgroundColor = theme.backgroundUIColor

        // Square frame overlay
        self.squareFrameBorder.strokeColor = theme.primaryUIColor.cgColor

        // Apply gradient to header
        let gradient = CAGradientLayer()
        gradient.colors = theme.gradient.map { $0.cgColor }
        gradient.frame = self.headerView.bounds
        self.headerView.layer.insertSublayer(gradient, at: 0)
    })
}
```

---

## First-Capture Gate (Unlock Main Menu)

### **User Flow: Launch → Forced Capture → Unlock**
```
User opens app (fresh install)
         ↓
   App launches to CAMERA ONLY
         ↓
   UI is BLACK AND WHITE (no GIP loaded)
         ↓
   Large text overlay:
   "Create your first GIF to unlock the gallery"
         ↓
   [Only action: Tap capture button]
         ↓
   User captures 32 frames
         ↓
   Processing:
     1. Extract palette (GIP)
     2. Compress frames (GIX)
     3. Generate GIF (GIF89a)
     4. Extract UI theme (ui_theme.json)
         ↓
   🎉 UNLOCK ANIMATION
         ↓
   UI blooms from B&W to COLOR
         ↓
   Main menu slides in from right
         ↓
   User now sees:
     - Gallery tab (1 GIF)
     - GIX tab (1 capture)
     - GIP tab (1 palette)
         ↓
   Navigation enabled ✅
```

### **Lock State Persistence**
```swift
class AppLockManager {
    static let shared = AppLockManager()

    private let defaults = UserDefaults.standard
    private let hasCreatedFirstCartridgeKey = "hasCreatedFirstCartridge"

    var isMainMenuUnlocked: Bool {
        return defaults.bool(forKey: hasCreatedFirstCartridgeKey)
    }

    func unlockMainMenu() {
        defaults.set(true, forKey: hasCreatedFirstCartridgeKey)
        NotificationCenter.default.post(name: .mainMenuUnlocked, object: nil)
    }

    func resetForTesting() {
        defaults.set(false, forKey: hasCreatedFirstCartridgeKey)
    }
}
```

### **SceneDelegate Integration**
```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, ...) {
    guard let windowScene = (scene as? UIWindowScene) else { return }
    window = UIWindow(windowScene: windowScene)

    // Check unlock status
    let rootVC: UIViewController

    if AppLockManager.shared.isMainMenuUnlocked {
        // Show main menu with last loaded cartridge theme
        rootVC = MainMenuTabBarController()
    } else {
        // Force camera-only mode (B&W UI)
        rootVC = CameraOnlyViewController()
    }

    let navController = UINavigationController(rootViewController: rootVC)
    navController.navigationBar.isHidden = true

    window?.rootViewController = navController
    window?.makeKeyAndVisible()
}
```

---

## Cartridge-Based Modular UI

### **UI Component Theming Protocol**
```swift
protocol GIPThemeable {
    var currentTheme: UITheme? { get set }
    func applyGIPTheme(_ theme: UITheme)
}

// Example: Themeable button
class GIPButton: UIButton, GIPThemeable {
    var currentTheme: UITheme?

    func applyGIPTheme(_ theme: UITheme) {
        currentTheme = theme

        // Apply colors from GIP palette
        backgroundColor = theme.primaryUIColor
        setTitleColor(theme.textUIColor, for: .normal)
        layer.borderColor = theme.secondaryUIColor.cgColor
        layer.borderWidth = 2

        // Add subtle gradient from GIP
        let gradient = CAGradientLayer()
        gradient.colors = [
            theme.primaryUIColor.cgColor,
            theme.primaryUIColor.withAlphaComponent(0.8).cgColor
        ]
        gradient.frame = bounds
        layer.insertSublayer(gradient, at: 0)
    }
}

// Example: Themeable tab bar
class GIPTabBarController: UITabBarController, GIPThemeable {
    var currentTheme: UITheme?

    func applyGIPTheme(_ theme: UITheme) {
        currentTheme = theme

        // Tab bar styling
        tabBar.barTintColor = theme.backgroundUIColor
        tabBar.tintColor = theme.primaryUIColor
        tabBar.unselectedItemTintColor = theme.secondaryUIColor.withAlphaComponent(0.5)

        // Tab icons colored with GIP palette
        updateTabIcons(with: theme)
    }

    private func updateTabIcons(with theme: UITheme) {
        guard let items = tabBar.items else { return }

        for (index, item) in items.enumerated() {
            // Use different GIP colors for each tab
            let color = theme.gradient[min(index, theme.gradient.count - 1)]
            item.image = item.image?.withTintColor(color, renderingMode: .alwaysOriginal)
        }
    }
}
```

### **Global Theme Manager**
```swift
class ThemeManager {
    static let shared = ThemeManager()

    private(set) var activeCartridge: Cartridge?
    private(set) var activeTheme: UITheme = .blackAndWhite  // Default

    private var themeableComponents: [WeakRef<GIPThemeable>] = []

    // Load cartridge and apply theme
    func loadCartridge(_ cartridge: Cartridge) {
        activeCartridge = cartridge

        // Extract theme from GIP
        if let gip = try? GIP.decode(from: cartridge.gipURL) {
            activeTheme = extractUITheme(from: gip)
            applyThemeToAllComponents()
        }
    }

    // Switch to black-and-white (no cartridge)
    func unloadCartridge() {
        activeCartridge = nil
        activeTheme = .blackAndWhite
        applyThemeToAllComponents()
    }

    // Register UI component for automatic theming
    func register(_ component: GIPThemeable) {
        themeableComponents.append(WeakRef(component))
        component.applyGIPTheme(activeTheme)
    }

    // Apply current theme to all registered components
    private func applyThemeToAllComponents() {
        // Clean up deallocated components
        themeableComponents = themeableComponents.filter { $0.value != nil }

        // Apply theme
        themeableComponents.forEach { ref in
            ref.value?.applyGIPTheme(activeTheme)
        }
    }
}

// Weak reference wrapper
private struct WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
```

---

## Gallery Implementation with Cartridge Slots

### **Main Menu Tab Bar**
```swift
class MainMenuTabBarController: GIPTabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Three tabs: GIFs, GIXs, GIPs
        let gifGallery = GIFGalleryViewController()
        let gixBrowser = GIXBrowserViewController()
        let gipLibrary = GIPLibraryViewController()

        viewControllers = [
            UINavigationController(rootViewController: gifGallery),
            UINavigationController(rootViewController: gixBrowser),
            UINavigationController(rootViewController: gipLibrary)
        ]

        // Tab icons
        gifGallery.tabBarItem = UITabBarItem(
            title: "GIFs",
            image: UIImage(systemName: "film"),
            selectedImage: UIImage(systemName: "film.fill")
        )
        gixBrowser.tabBarItem = UITabBarItem(
            title: "Captures",
            image: UIImage(systemName: "square.stack.3d.up"),
            selectedImage: UIImage(systemName: "square.stack.3d.up.fill")
        )
        gipLibrary.tabBarItem = UITabBarItem(
            title: "Palettes",
            image: UIImage(systemName: "paintpalette"),
            selectedImage: UIImage(systemName: "paintpalette.fill")
        )

        // Register for theming
        ThemeManager.shared.register(self)

        // Load last active cartridge
        if let lastCartridge = CartridgeManager.shared.lastActiveCartridge {
            ThemeManager.shared.loadCartridge(lastCartridge)
        }
    }
}
```

### **GIP Library View (Palette Swapper)**
```swift
class GIPLibraryViewController: UIViewController, GIPThemeable {
    var currentTheme: UITheme?

    private var collectionView: UICollectionView!
    private var palettes: [GIP] = []

    func applyGIPTheme(_ theme: UITheme) {
        currentTheme = theme
        view.backgroundColor = theme.backgroundUIColor
        collectionView.reloadData()  // Refresh cells with new theme
    }

    // Collection view cell for each GIP
    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "PaletteCell",
            for: indexPath
        ) as! PaletteCell

        let gip = palettes[indexPath.item]
        cell.configure(with: gip, theme: currentTheme)

        return cell
    }
}

class PaletteCell: UICollectionViewCell {
    private let palette3DCubeView = Palette3DView()
    private let nameLabel = UILabel()
    private let colorStripView = UIView()

    func configure(with gip: GIP, theme: UITheme?) {
        // Show 3D rotating cube of palette colors
        palette3DCubeView.setPalette(gip.rgb)

        // Display palette name
        nameLabel.text = gip.name
        nameLabel.textColor = theme?.textUIColor ?? .white

        // Show color strip (all 256 colors)
        renderColorStrip(gip.rgb)

        // Border color from current theme
        layer.borderColor = theme?.primaryUIColor.cgColor ?? UIColor.white.cgColor
        layer.borderWidth = 2
    }

    private func renderColorStrip(_ rgb: [[UInt8]]) {
        // Create gradient from all 256 colors
        let gradient = CAGradientLayer()
        gradient.colors = rgb.map { UIColor(rgb: $0).cgColor }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.frame = colorStripView.bounds
        colorStripView.layer.addSublayer(gradient)
    }
}
```

---

## Rendering & Graphics Integration

### **Using Existing Metal Infrastructure**

Your codebase already has:
- `VoxelRenderer.swift` - 3D voxel rendering (Metal)
- `PaletteShaderSystem.swift` - Palette application shaders
- `PaletteLUTRenderer.swift` - Palette lookup table rendering

**Integration Strategy:**

1. **Palette 3D Cube (GIP Visualization)**
   - Use `VoxelRenderer` to plot 256 palette colors in RGB space
   - Each voxel = one color from GIP
   - Position: `(R/255, G/255, B/255)` in normalized cube
   - User can rotate/zoom to explore color distribution

2. **Temporal GIX Stack (Frame Visualization)**
   - Use `VoxelRenderer` for 3D temporal volume
   - X×Y = frame pixels, Z = time (frame index)
   - Each voxel = palette index (0-255) converted to color via GIP

3. **UI Element Rendering**
   - Extract dominant colors from GIP using existing `PaletteShaderSystem`
   - Use `PaletteLUTRenderer` for gradient generation
   - Apply to UIKit components via `CAGradientLayer`

**No Additional Libraries Needed:**
- Metal framework (already used) ✅
- MetalKit (already used) ✅
- `swift-gif` - Add for GIF encoding (recommended)
- UIKit + Core Animation - Native iOS (already available) ✅

---

## Implementation Checklist

### **Phase 1: Black-and-White Default UI** (Week 1)
- [ ] Create `UITheme` struct with `.blackAndWhite` preset
- [ ] Implement `GIPThemeable` protocol
- [ ] Refactor existing UI components to be themeable
- [ ] Test B&W state on fresh install

### **Phase 2: First-Capture Gate** (Week 1-2)
- [ ] Create `AppLockManager` for unlock state
- [ ] Build `CameraOnlyViewController` (locked state)
- [ ] Add unlock animation (B&W → color bloom)
- [ ] Test unlock flow

### **Phase 3: GIP → UI Theme Extraction** (Week 2)
- [ ] Implement `extractUITheme(from: GIP)` algorithm
- [ ] Add HSV color analysis
- [ ] Build auto-contrast text color picker
- [ ] Generate palette names (mood classification)

### **Phase 4: Theme Manager** (Week 2-3)
- [ ] Build `ThemeManager` singleton
- [ ] Add cartridge loading/unloading
- [ ] Implement component registration system
- [ ] Add theme persistence (last active cartridge)

### **Phase 5: Cartridge System** (Week 3-4)
- [ ] Create `Cartridge` data structure
- [ ] Build `CartridgeManager` for file I/O
- [ ] Implement cartridge slot UI
- [ ] Add cartridge swapping with animations

### **Phase 6: Gallery with GIP Integration** (Week 4-5)
- [ ] Build `GIPLibraryViewController`
- [ ] Add 3D palette cube rendering
- [ ] Implement color strip visualization
- [ ] Add palette swapping gesture

### **Phase 7: Polish** (Week 5-6)
- [ ] Smooth theme transition animations
- [ ] Add haptic feedback on cartridge swap
- [ ] Optimize Metal rendering for 60 FPS
- [ ] Test with diverse palette sets

---

## Summary

**Key Innovations:**
1. **GIP as UI Theme** - Palettes are visual identity, not just data
2. **Cartridge Metaphor** - Modular, swappable aesthetic experiences
3. **B&W Lock State** - No color until first capture (forces engagement)
4. **Automatic Theme Extraction** - Zero manual configuration
5. **Living UI** - Interface changes with every capture

**Technical Foundation:**
- Uses existing Metal/MetalKit infrastructure ✅
- Leverages current `VoxelRenderer` for 3D viz ✅
- Extends `PaletteShaderSystem` for UI theming ✅
- No new rendering libraries needed ✅

**User Experience:**
- Launch → B&W camera (minimalist, focused)
- First capture → UI blooms to color (delight)
- Every capture creates new theme (variety)
- Swap cartridges → instant aesthetic change (playful)

This system makes **GIP files the soul of the app**, not just a technical artifact.
