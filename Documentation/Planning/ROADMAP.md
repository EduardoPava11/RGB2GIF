# RGB2GIF - Implementation Roadmap

**Status**: Phase 0 Complete ✅ | Phase 1 Ready to Start 🚀
**Last Updated**: 2025-10-04

---

## 📊 **Project Phases Overview**

```
Phase 0: Foundation ✅ COMPLETE
  └─ GIP-driven UI system architecture
  └─ Pipeline integration (Camera → GIP/GIX → Cartridge)
  └─ Theme extraction & unlock logic

Phase 1: UI Refactoring ⏭️ NEXT (Est: 1-2 days)
  └─ Convert to themeable components
  └─ Validate theme transitions

Phase 2: Locked State 📋 (Est: 1 day)
  └─ Camera-only B&W view
  └─ Unlock animation

Phase 3: Main Menu Gallery 📋 (Est: 3-4 days)
  └─ Tab bar controller
  └─ Three gallery views

Phase 4: Testing & Polish 📋 (Est: 2-3 days)
  └─ Edge cases
  └─ Error handling
  └─ Performance tuning
```

---

## 🎯 **Sprint Plan (2-Week Timeline)**

### **Sprint 1: Core UI (Week 1)**

#### **Day 1-2: Phase 1 - UI Refactoring**
- Effort: 8-10 hours
- Priority: 🔴 Critical
- Dependencies: None (Phase 0 complete)

#### **Day 3-4: Phase 2 - Locked State**
- Effort: 6-8 hours
- Priority: 🔴 Critical
- Dependencies: Phase 1 complete

#### **Day 5: Testing & Buffer**
- Effort: 4-6 hours
- Priority: 🟡 High
- Dependencies: Phases 1-2 complete

### **Sprint 2: Gallery & Polish (Week 2)**

#### **Day 6-8: Phase 3 - Main Menu Gallery**
- Effort: 12-16 hours
- Priority: 🟡 High
- Dependencies: Phase 2 complete

#### **Day 9-10: Phase 4 - Testing & Polish**
- Effort: 8-12 hours
- Priority: 🟡 High
- Dependencies: All phases complete

---

## 📋 **Detailed Task Breakdown**

---

### **PHASE 1: UI Refactoring** 🔴 Critical

**Goal**: Replace standard UIKit components with GIPThemeable variants

**Dependencies**: None (Phase 0 provides foundation)

**Estimated Effort**: 8-10 hours

---

#### **Task 1.1: Refactor Status Labels**
**File**: `Sources/Camera/SimpleRealCameraViewController.swift:105-154`

**Priority**: 🔴 Critical
**Effort**: 1 hour
**Assignee**: Developer

**Changes**:
```swift
// BEFORE (Line 105-114)
statusLabel = UILabel()
statusLabel.textColor = .white

// AFTER
statusLabel = GIPLabel(emphasis: .primary)
// Remove textColor assignment (theme handles it)

// BEFORE (Line 117-126)
frameCountLabel = UILabel()
frameCountLabel.textColor = .white

// AFTER
frameCountLabel = GIPLabel(emphasis: .secondary)

// BEFORE (Line 138-144)
paletteStrategyLabel = UILabel()
paletteStrategyLabel.textColor = .white

// AFTER
paletteStrategyLabel = GIPLabel(emphasis: .primary)

// BEFORE (Line 147-154)
paletteStrategyStatsLabel = UILabel()
paletteStrategyStatsLabel.textColor = UIColor.lightGray

// AFTER
paletteStrategyStatsLabel = GIPLabel(emphasis: .secondary)
```

**Validation**:
- [ ] Fresh install shows labels in white (B&W theme)
- [ ] After first capture, labels change to theme colors
- [ ] Second capture updates label colors to new theme
- [ ] Color transitions are smooth (0.3s animation)

**Test Procedure**:
```swift
// Unit test
func testStatusLabelTheming() {
    let vc = SimpleRealCameraViewController()
    _ = vc.view // Trigger viewDidLoad

    // Initial state (B&W)
    XCTAssertEqual(vc.statusLabel.textColor, UIColor.white)

    // Apply theme
    ThemeManager.shared.loadTheme(from: mockGIP)

    // Verify theme applied
    XCTAssertNotEqual(vc.statusLabel.textColor, UIColor.white)
}
```

---

#### **Task 1.2: Refactor Capture Button**
**File**: `Sources/Camera/SimpleRealCameraViewController.swift:176-184`

**Priority**: 🔴 Critical
**Effort**: 1 hour
**Assignee**: Developer

**Changes**:
```swift
// BEFORE
captureButton = UIButton(type: .system)
captureButton.backgroundColor = .systemRed
captureButton.setTitleColor(.white, for: .normal)

// AFTER
captureButton = GIPButton(style: .primary)
// Remove backgroundColor and setTitleColor (theme handles it)

// Keep existing:
captureButton.setTitle("●", for: .normal)
captureButton.titleLabel?.font = .boldSystemFont(ofSize: 50)
captureButton.layer.cornerRadius = 40
```

**Validation**:
- [ ] Button starts with B&W colors (white on black)
- [ ] After unlock, button uses primary theme color
- [ ] Button state changes work correctly (red → green during capture)
- [ ] Haptic feedback still triggers

**Edge Cases**:
- [ ] Button remains tappable during theme transition
- [ ] State persistence (if app backgrounds during capture)

---

#### **Task 1.3: Refactor Slider & Segmented Control**
**File**: `Sources/Camera/SimpleRealCameraViewController.swift:129-161`

**Priority**: 🟡 High
**Effort**: 30 minutes
**Assignee**: Developer

**Changes**:
```swift
// BEFORE (Line 129-135)
paletteStrategySlider = UISlider()

// AFTER
paletteStrategySlider = GIPSlider()

// BEFORE (Line 157-161)
dimensionSegmentedControl = UISegmentedControl(items: ["80×80", "128×128"])

// AFTER
dimensionSegmentedControl = GIPSegmentedControl(items: ["80×80", "128×128"])
```

**Validation**:
- [ ] Slider thumb color matches theme.accent
- [ ] Slider track uses theme.primary
- [ ] Segmented control selected state uses theme.primary
- [ ] Interactions work identically to before

---

#### **Task 1.4: Refactor Progress View**
**File**: `Sources/Camera/SimpleRealCameraViewController.swift:197-224`

**Priority**: 🟡 High
**Effort**: 30 minutes
**Assignee**: Developer

**Changes**:
```swift
// BEFORE (Line 217-224)
progressBar = UIProgressView(progressViewStyle: .default)
progressBar.progressTintColor = .systemBlue

// AFTER
progressBar = GIPProgressView()
// Progress property set via: progressBar.progress = 0.5
```

**Validation**:
- [ ] Progress bar animates smoothly during GIF creation
- [ ] Bar color matches theme.primary
- [ ] Track color uses theme.background with alpha

---

#### **Task 1.5: Add Gradient Background**
**File**: `Sources/Camera/SimpleRealCameraViewController.swift:101-103`

**Priority**: 🟢 Medium
**Effort**: 30 minutes
**Assignee**: Developer

**Changes**:
```swift
// In setupUI(), after line 102
let backgroundView = GIPBackgroundView(gradient: true)
backgroundView.frame = view.bounds
backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
view.insertSubview(backgroundView, at: 0)

// Remove or modify:
// view.backgroundColor = .black (no longer needed)
```

**Validation**:
- [ ] Fresh install shows black → dark gray gradient
- [ ] After unlock, gradient uses theme.gradientStart → theme.gradientEnd
- [ ] Gradient rotates correctly on device rotation

---

#### **Task 1.6: End-to-End Theme Transition Test**

**Priority**: 🔴 Critical
**Effort**: 2 hours
**Assignee**: QA / Developer

**Manual Test Procedure**:
1. **Fresh Install**:
   ```
   - Delete app from device
   - Reinstall and launch
   - Expected: All UI elements are white on black (B&W)
   - Check: statusLabel, frameCountLabel, captureButton, slider, segmented control
   ```

2. **First Capture**:
   ```
   - Tap capture button
   - Capture 32 frames
   - Wait for processing
   - Expected: "🎉 Main Menu Unlocked!" alert
   - Expected: All UI elements shift to theme colors
   - Measure: Color transition takes ~0.3s
   ```

3. **Second Capture**:
   ```
   - Capture another GIF (different scene/colors)
   - Expected: UI colors update to new palette
   - Check: Smooth transition, no flicker
   ```

4. **App Restart**:
   ```
   - Force quit app
   - Relaunch
   - Expected: UI still colored (theme persisted)
   - Check: ThemeManager.shared.currentTheme is not .blackAndWhite
   ```

**Automated Tests**:
```swift
func testThemeTransitionFlow() async throws {
    // 1. Fresh install simulation
    AppLockManager.shared.resetUnlockState()
    ThemeManager.shared.resetToBlackAndWhite()

    let vc = SimpleRealCameraViewController()
    _ = vc.view

    XCTAssertEqual(vc.statusLabel.textColor, UIColor.white)

    // 2. Simulate first capture
    let mockFrames = generateMockFrames(count: 32)
    await vc.processFrames(mockFrames)

    // 3. Verify unlock
    XCTAssertTrue(AppLockManager.shared.isUnlocked)

    // 4. Verify theme loaded
    XCTAssertNotEqual(ThemeManager.shared.currentTheme.name, "Black & White")

    // 5. Verify UI updated
    XCTAssertNotEqual(vc.statusLabel.textColor, UIColor.white)
}
```

---

### **PHASE 2: Locked State** 🔴 Critical

**Goal**: Create camera-only view for fresh installs, unlock animation

**Dependencies**: Phase 1 complete

**Estimated Effort**: 6-8 hours

---

#### **Task 2.1: Create CameraOnlyViewController**
**New File**: `Sources/Camera/CameraOnlyViewController.swift`

**Priority**: 🔴 Critical
**Effort**: 3 hours
**Assignee**: Developer

**Requirements**:
- Pure B&W UI (no colors until unlock)
- Full-screen camera preview
- Single capture button (centered, bottom)
- Overlay: "Create your first GIF to unlock the gallery"
- No settings, no sliders, minimal chrome
- Implements GIPThemeable protocol

**Implementation**:
```swift
import UIKit
import AVFoundation
import OSLog

class CameraOnlyViewController: UIViewController, GIPThemeable {

    // MARK: - Properties

    var currentTheme: UITheme?

    private var cameraManager: SimpleCameraManager!
    private var captureManager: TemporalCubeCaptureManager!
    private var previewLayer: AVCaptureVideoPreviewLayer!

    private var captureButton: GIPButton!
    private var instructionLabel: GIPLabel!
    private var frameCountLabel: GIPLabel!

    private let logger = Logger(subsystem: "com.rgb2gif", category: "CameraOnlyVC")

    private var isCapturing = false
    private let targetFrameCount = 32

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        setupUI()

        Task {
            await setupCamera()
        }

        // Register for theme updates
        ThemeManager.shared.register(self)

        // Listen for unlock
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFirstCartridge),
            name: .firstCartridgeCreated,
            object: nil
        )
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Instruction overlay
        instructionLabel = GIPLabel(emphasis: .primary)
        instructionLabel.text = "Create your first GIF\nto unlock the gallery"
        instructionLabel.font = .systemFont(ofSize: 24, weight: .bold)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 2
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)

        // Frame counter
        frameCountLabel = GIPLabel(emphasis: .secondary)
        frameCountLabel.text = "0 / \(targetFrameCount) frames"
        frameCountLabel.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        frameCountLabel.textAlignment = .center
        frameCountLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameCountLabel)

        // Capture button
        captureButton = GIPButton(style: .primary)
        captureButton.setTitle("●", for: .normal)
        captureButton.titleLabel?.font = .boldSystemFont(ofSize: 50)
        captureButton.layer.cornerRadius = 40
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureButton)

        // Layout
        NSLayoutConstraint.activate([
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),

            frameCountLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameCountLabel.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -30),

            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.widthAnchor.constraint(equalToConstant: 80),
            captureButton.heightAnchor.constraint(equalToConstant: 80)
        ])
    }

    // MARK: - Camera Setup

    private func setupCamera() async {
        // Similar to SimpleRealCameraViewController
        // ... (camera initialization code)
    }

    // MARK: - Actions

    @objc private func captureButtonTapped() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        // Start capturing frames
        // ... (capture logic)
    }

    private func stopCapture() {
        // Process frames → GIP/GIX → Cartridge
        // ... (processing logic)
    }

    // MARK: - Unlock Handler

    @objc private func handleFirstCartridge(notification: Notification) {
        guard let cartridgePath = notification.userInfo?["cartridgePath"] as? String else {
            return
        }

        logger.info("🎉 First cartridge created! Triggering unlock animation...")

        // Trigger unlock animation
        showUnlockAnimation()
    }

    private func showUnlockAnimation() {
        // B&W → color bloom animation
        // Transition to MainTabBarController
        // ... (animation logic - Task 2.3)
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        currentTheme = theme
        // Components auto-update via ThemeManager
    }
}
```

**Validation**:
- [ ] Fresh install shows only camera + instruction + button
- [ ] All text is white (B&W theme)
- [ ] Capture button works identically to main app
- [ ] Frame counter updates in real-time
- [ ] No crashes or memory leaks

---

#### **Task 2.2: Update SceneDelegate Launch Logic**
**File**: `Sources/Supporting Files/SceneDelegate.swift`

**Priority**: 🔴 Critical
**Effort**: 30 minutes
**Assignee**: Developer

**Changes**:
```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = (scene as? UIWindowScene) else { return }

    let window = UIWindow(windowScene: windowScene)

    // Check if app is unlocked
    let rootViewController: UIViewController
    if AppLockManager.shared.isUnlocked {
        // TODO: Replace with MainTabBarController when implemented
        rootViewController = SimpleRealCameraViewController()
    } else {
        // Show locked camera-only state
        rootViewController = CameraOnlyViewController()
    }

    window.rootViewController = rootViewController
    self.window = window
    window.makeKeyAndVisible()
}
```

**Validation**:
- [ ] Fresh install launches CameraOnlyViewController
- [ ] After unlock, app restart launches SimpleRealCameraViewController
- [ ] No duplicate camera sessions

---

#### **Task 2.3: Implement Unlock Animation**
**File**: `Sources/Camera/CameraOnlyViewController.swift` (new method)

**Priority**: 🟡 High
**Effort**: 2 hours
**Assignee**: Developer

**Implementation**:
```swift
private func showUnlockAnimation() {
    // 1. Freeze current view
    guard let window = view.window else { return }

    let snapshot = view.snapshotView(afterScreenUpdates: false)!
    snapshot.frame = view.bounds

    // Apply B&W filter
    let filter = CIFilter(name: "CIPhotoEffectNoir")!
    snapshot.layer.filters = [filter]

    window.addSubview(snapshot)

    // 2. Prepare next view controller (behind snapshot)
    // TODO: Replace with MainTabBarController
    let nextVC = SimpleRealCameraViewController()
    nextVC.view.frame = view.bounds

    // 3. Color bloom mask animation
    let maskLayer = CAShapeLayer()
    let initialRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    maskLayer.path = UIBezierPath(ovalIn: initialRect).cgPath
    maskLayer.fillColor = UIColor.black.cgColor

    snapshot.layer.mask = maskLayer

    // Animate bloom
    let bloomAnimation = CABasicAnimation(keyPath: "path")
    let finalRect = view.bounds.insetBy(dx: -view.bounds.width, dy: -view.bounds.height)
    bloomAnimation.toValue = UIBezierPath(ovalIn: finalRect).cgPath
    bloomAnimation.duration = 0.8
    bloomAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    bloomAnimation.fillMode = .forwards
    bloomAnimation.isRemovedOnCompletion = false

    maskLayer.add(bloomAnimation, forKey: "bloom")

    // 4. Haptic feedback
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(.success)

    // 5. Transition to next screen
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        snapshot.removeFromSuperview()

        // Show confetti
        self.showConfetti()

        // Transition
        if let sceneDelegate = window.windowScene?.delegate as? SceneDelegate {
            sceneDelegate.window?.rootViewController = nextVC
        }
    }
}

private func showConfetti() {
    // Simple confetti particle effect
    let emitter = CAEmitterLayer()
    emitter.emitterPosition = CGPoint(x: view.bounds.midX, y: -20)
    emitter.emitterShape = .line
    emitter.emitterSize = CGSize(width: view.bounds.width, height: 1)

    let cell = CAEmitterCell()
    cell.birthRate = 100
    cell.lifetime = 3.0
    cell.velocity = 200
    cell.velocityRange = 50
    cell.emissionRange = .pi
    cell.spin = 2
    cell.spinRange = 3
    cell.scale = 0.5
    cell.scaleRange = 0.25
    cell.contents = UIImage(systemName: "star.fill")?.cgImage
    cell.color = UIColor.systemYellow.cgColor

    emitter.emitterCells = [cell]
    view.layer.addSublayer(emitter)

    // Remove after 3 seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        emitter.removeFromSuperlayer()
    }
}
```

**Validation**:
- [ ] Animation is smooth (60 FPS)
- [ ] Color bloom expands from center
- [ ] Haptic feedback fires
- [ ] Confetti appears
- [ ] Transition to next screen is seamless
- [ ] No memory leaks from snapshot

---

#### **Task 2.4: Integration Test - Locked → Unlocked Flow**

**Priority**: 🔴 Critical
**Effort**: 1 hour
**Assignee**: QA / Developer

**Test Procedure**:
```
1. Delete app
2. Reinstall
3. Launch app
4. Expected: CameraOnlyViewController shown
5. Expected: Instruction text visible
6. Tap capture button
7. Capture 32 frames
8. Expected: Processing happens
9. Expected: Unlock animation plays
10. Expected: Confetti shows
11. Expected: Transition to main app
12. Force quit app
13. Relaunch
14. Expected: Goes directly to main app (not CameraOnlyViewController)
```

**Automated Test**:
```swift
func testLockedToUnlockedFlow() async throws {
    // Reset to locked state
    AppLockManager.shared.resetUnlockState()

    // Simulate fresh install
    let sceneDelegate = SceneDelegate()
    let scene = UIWindowScene() // Mock
    sceneDelegate.scene(scene, willConnectTo: UISceneSession(), options: UIScene.ConnectionOptions())

    // Verify locked state
    XCTAssertTrue(sceneDelegate.window?.rootViewController is CameraOnlyViewController)

    // Simulate capture
    let cartridgePath = try await simulateFirstCapture()

    // Trigger unlock
    AppLockManager.shared.unlockWithCartridge(at: cartridgePath)

    // Verify unlocked
    XCTAssertTrue(AppLockManager.shared.isUnlocked)
}
```

---

### **PHASE 3: Main Menu Gallery** 🟡 High

**Goal**: Build tab bar with three galleries (Palettes, Captures, GIFs)

**Dependencies**: Phase 2 complete

**Estimated Effort**: 12-16 hours

---

#### **Task 3.1: Create MainTabBarController**
**New File**: `Sources/UI/MainTabBarController.swift`

**Priority**: 🟡 High
**Effort**: 2 hours
**Assignee**: Developer

**Implementation**:
```swift
import UIKit

class MainTabBarController: UITabBarController, GIPThemeable {

    var currentTheme: UITheme?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create gallery view controllers
        let palettesVC = GIPLibraryViewController()
        palettesVC.tabBarItem = UITabBarItem(title: "Palettes", image: UIImage(systemName: "paintpalette"), tag: 0)

        let capturesVC = GIXBrowserViewController()
        capturesVC.tabBarItem = UITabBarItem(title: "Captures", image: UIImage(systemName: "film"), tag: 1)

        let gifsVC = GIFGalleryViewController()
        gifsVC.tabBarItem = UITabBarItem(title: "GIFs", image: UIImage(systemName: "photo.stack"), tag: 2)

        viewControllers = [palettesVC, capturesVC, gifsVC]

        // Register for theming
        ThemeManager.shared.register(self)
    }

    // MARK: - GIPThemeable

    func applyGIPTheme(_ theme: UITheme) {
        currentTheme = theme

        tabBar.tintColor = theme.primary
        tabBar.unselectedItemTintColor = theme.text.withAlphaComponent(0.6)
        tabBar.barTintColor = theme.background
        tabBar.backgroundColor = theme.background
    }
}
```

**Validation**:
- [ ] Tab bar shows three tabs
- [ ] Tab bar colors match current theme
- [ ] Switching tabs works
- [ ] Theme updates change tab bar colors

---

#### **Task 3.2: Create GIPLibraryViewController (Palettes Tab)**
**New File**: `Sources/Gallery/GIPLibraryViewController.swift`

**Priority**: 🟡 High
**Effort**: 4 hours
**Assignee**: Developer

**Requirements**:
- Grid layout (3 columns)
- Show all palettes from Documents/Cartridges/
- Tap palette → load theme
- Visual indicator for active palette
- 3D cube preview (optional for v1, can be placeholder)

**Implementation Sketch**:
```swift
class GIPLibraryViewController: UIViewController, GIPThemeable {

    var currentTheme: UITheme?

    private var collectionView: UICollectionView!
    private var palettes: [Cartridge] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Palettes"

        setupCollectionView()
        loadPalettes()

        ThemeManager.shared.register(self)
    }

    private func loadPalettes() {
        do {
            palettes = try CartridgeManager.shared.listCartridges()
            collectionView.reloadData()
        } catch {
            // Show error
        }
    }

    // UICollectionView delegates...

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let cartridge = palettes[indexPath.item]

        // Load GIP and apply theme
        do {
            let gip = try cartridge.loadGIP()
            ThemeManager.shared.loadTheme(from: gip)

            // Update UI to show active
            collectionView.reloadData()
        } catch {
            // Show error
        }
    }
}
```

**Validation**:
- [ ] Shows all captured palettes
- [ ] Tapping palette changes app theme
- [ ] Active palette has visual indicator
- [ ] Empty state shown if no palettes

---

#### **Task 3.3: Create GIXBrowserViewController (Captures Tab)**
**New File**: `Sources/Gallery/GIXBrowserViewController.swift`

**Priority**: 🟡 High
**Effort**: 4 hours
**Assignee**: Developer

**Requirements**:
- List all captures
- Show timestamp, frame count, dimension
- Tap capture → show details
- "Swap Palette" button
- Timeline scrubber (optional for v1)

---

#### **Task 3.4: Create GIFGalleryViewController (GIFs Tab)**
**New File**: `Sources/Gallery/GIFGalleryViewController.swift`

**Priority**: 🟡 High
**Effort**: 3 hours
**Assignee**: Developer

**Requirements**:
- Grid of playing GIF thumbnails
- Tap GIF → full-screen viewer
- Share button
- Delete button

---

#### **Task 3.5: Update SceneDelegate for MainTabBarController**
**File**: `Sources/Supporting Files/SceneDelegate.swift`

**Priority**: 🟡 High
**Effort**: 15 minutes
**Assignee**: Developer

**Changes**:
```swift
if AppLockManager.shared.isUnlocked {
    rootViewController = MainTabBarController() // Use tab bar
} else {
    rootViewController = CameraOnlyViewController()
}
```

---

### **PHASE 4: Testing & Polish** 🟡 High

**Goal**: Edge cases, error handling, performance tuning

**Dependencies**: All previous phases complete

**Estimated Effort**: 8-12 hours

---

#### **Task 4.1: Error Handling**

**Priority**: 🟡 High
**Effort**: 3 hours

**Scenarios to Handle**:
- [ ] Disk full during cartridge creation
- [ ] Camera permission denied
- [ ] Photos library permission denied
- [ ] Corrupt GIP/GIX files
- [ ] Missing cartridge files
- [ ] Theme extraction fails (malformed palette)
- [ ] App backgrounded during capture
- [ ] Low memory warning during processing

**Implementation**:
```swift
// Add to CartridgeManager
enum CartridgeManagerError: LocalizedError {
    case diskFull
    case corruptedFile(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .diskFull:
            return "Not enough storage space to save cartridge"
        case .corruptedFile(let file):
            return "File is corrupted: \(file)"
        case .missingFile(let file):
            return "Required file not found: \(file)"
        }
    }
}

// Graceful degradation
func createCartridge(...) throws -> Cartridge {
    do {
        // Attempt creation
        ...
    } catch {
        // Cleanup partial files
        cleanupFailedCartridge(at: cartridgeDir)
        throw error
    }
}
```

---

#### **Task 4.2: Memory Profiling**

**Priority**: 🟡 High
**Effort**: 2 hours

**Test Cases**:
- [ ] Capture 10 GIFs in a row (no memory leak)
- [ ] Load 100 cartridges in gallery (efficient loading)
- [ ] Rapid theme switching (no retain cycles)
- [ ] Background/foreground cycles

**Tools**:
- Instruments (Leaks, Allocations)
- Memory graph debugger

---

#### **Task 4.3: Performance Tuning**

**Priority**: 🟢 Medium
**Effort**: 3 hours

**Targets**:
- [ ] Theme extraction < 50ms
- [ ] Gallery scroll @ 60 FPS
- [ ] Unlock animation @ 60 FPS
- [ ] Cartridge creation < 100ms

---

#### **Task 4.4: Edge Case Testing**

**Priority**: 🟡 High
**Effort**: 2 hours

**Scenarios**:
- [ ] User force quits during capture
- [ ] User force quits during processing
- [ ] User deletes Photos permission mid-save
- [ ] User fills disk during capture
- [ ] User has 1000+ cartridges
- [ ] User manually deletes cartridge files
- [ ] User restores from iCloud backup

---

## 📊 **Kanban Board Structure**

```
┌─────────────────┬─────────────────┬─────────────────┬─────────────────┐
│  📋 BACKLOG     │  🏃 IN PROGRESS │  ✅ DONE        │  🚫 BLOCKED     │
├─────────────────┼─────────────────┼─────────────────┼─────────────────┤
│ Task 3.2        │ Task 1.1        │ All Phase 0     │                 │
│ Task 3.3        │ Task 1.2        │                 │                 │
│ Task 3.4        │                 │                 │                 │
│ Task 3.5        │                 │                 │                 │
│ Task 4.1        │                 │                 │                 │
│ Task 4.2        │                 │                 │                 │
│ Task 4.3        │                 │                 │                 │
│ Task 4.4        │                 │                 │                 │
└─────────────────┴─────────────────┴─────────────────┴─────────────────┘
```

---

## 📈 **Progress Tracking**

### **Sprint 1 Goals** (Week 1)
- [ ] Phase 1: UI Refactoring (Tasks 1.1-1.6)
- [ ] Phase 2: Locked State (Tasks 2.1-2.4)

### **Sprint 2 Goals** (Week 2)
- [ ] Phase 3: Main Menu Gallery (Tasks 3.1-3.5)
- [ ] Phase 4: Testing & Polish (Tasks 4.1-4.4)

### **Definition of Done**:
- [ ] All validation checkboxes passed
- [ ] Unit tests written and passing
- [ ] Manual test procedure completed
- [ ] Code reviewed
- [ ] Documentation updated

---

## 🎯 **Success Metrics**

| Metric | Target | Validation |
|--------|--------|------------|
| Theme transition time | < 300ms | Instruments Time Profiler |
| Unlock animation FPS | 60 FPS | Instruments Core Animation |
| Memory usage (10 captures) | < 200MB | Instruments Allocations |
| Gallery scroll FPS | 60 FPS | Instruments Core Animation |
| Cartridge creation time | < 100ms | Custom logging |
| App launch time (unlocked) | < 1s | Instruments App Launch |

---

## 📝 **Daily Standup Template**

```
Yesterday:
- Completed: [Task IDs]
- Blockers: [None / Issues]

Today:
- Working on: [Task IDs]
- Expected completion: [EOD / Tomorrow]

Risks:
- [Any concerns or dependencies]
```

---

## 🚀 **Release Checklist**

Before marking complete:
- [ ] All tasks marked ✅ DONE
- [ ] All validation checkboxes passed
- [ ] Performance metrics met
- [ ] Memory profiling clean
- [ ] Edge cases handled
- [ ] Error handling tested
- [ ] Documentation updated
- [ ] IMPLEMENTATION_STATUS.md updated
- [ ] NEXT_STEPS.md archived
- [ ] Build succeeds on device
- [ ] TestFlight build uploaded (if applicable)

---

## 📚 **Resources**

- **Architecture Docs**: `ARCHITECTURE.md`, `GIP_UI_CARTRIDGE_SYSTEM.md`
- **Integration Status**: `PIPELINE_INTEGRATION_STATUS.md`
- **User Story**: `USER_STORY.md`
- **Code Examples**: `Sources/UI/GIPThemeableComponents.swift`

---

## 🎉 **Completion Criteria**

**Phase 1**: User can see UI change colors after first capture
**Phase 2**: User sees B&W camera on fresh install, unlock animation on first capture
**Phase 3**: User can browse palettes/captures/GIFs in tabbed gallery
**Phase 4**: App handles edge cases gracefully, no crashes or leaks

**SHIP IT!** 🚢✨
