# RGB2GIF - User Story & Flow

## First Launch Experience

### **What User Sees on App Open:**

```
┌─────────────────────────────────────┐
│  ◄─ iPhone 17 Pro Screen ──►        │
│                                     │
│   ╔═══════════════════════════╗    │ ← Status Label
│   ║  Ready to Capture         ║    │   "Camera Initializing..."
│   ╚═══════════════════════════╝    │
│                                     │
│   ┌──────────────────────────┐     │ ← Frame Counter
│   │   0 / 32 frames          │     │
│   └──────────────────────────┘     │
│                                     │
│  ┌─────────────────────────────┐   │
│  │                             │   │
│  │                             │   │
│  │    LIVE CAMERA PREVIEW      │   │ ← Full-screen camera feed
│  │    (NV12 format, 1280×1280) │   │
│  │                             │   │
│  │    ╭─────────────────╮      │   │
│  │    │                 │      │   │ ← SQUARE FRAME OVERLAY
│  │    │  Capture Area   │      │   │   (White border, 2pt stroke)
│  │    │  1280×1280      │      │   │   Shows exact crop region
│  │    │                 │      │   │
│  │    ╰─────────────────╯      │   │
│  │                             │   │
│  └─────────────────────────────┘   │
│                                     │
│   Palette: Balanced (50%)          │ ← Palette Strategy Label
│   ~16 palettes × 256 colors        │ ← Stats
│                                     │
│   [80×80] [128×128]                │ ← Size Toggle
│                                     │
│        ┌─────┐   🔄                │ ← Capture Button + Switch
│        │  ●  │                     │   (Red circle, 80pt)
│        └─────┘                     │
└─────────────────────────────────────┘
```

### **Key UI Elements:**

#### **1. Camera Preview (Full Screen)**
- **Live feed** from iPhone 17 Pro's main camera (48MP)
- **Aspect ratio**: `resizeAspectFill` (fills screen, crops to fit)
- **Format**: NV12/YUV (efficient for GPU processing)
- **Resolution**: Native sensor size, cropped to square in processing

#### **2. Square Frame Overlay (NEW - TO BE ADDED)**
- **Visual guide** showing exact capture region
- **Appearance**:
  - White rounded rectangle border (2-3pt stroke)
  - Semi-transparent background outside frame (20% black overlay)
  - Corner marks (L-shaped brackets) for precision
- **Size**: Matches target output (1280×1280 initially)
- **Position**: Centered on screen
- **Purpose**: **User sees exactly what will be captured**

#### **3. Status Label (Top)**
- **States**:
  - "Camera Initializing..." (gray)
  - "Ready to Capture" (green)
  - "Capturing... 5/32" (blue, animated)
  - "Processing GIF..." (yellow)
  - "Saved to Photos!" (green, checkmark)
  - "Error: ..." (red)

#### **4. Frame Counter**
- Shows progress: "0 / 32 frames"
- Updates in real-time during capture
- Color changes: Gray → Blue (capturing) → Green (complete)

#### **5. Capture Button**
- **Appearance**: Large red circle with "●" symbol (80pt)
- **States**:
  - Red + "●" = Ready to capture
  - Blue + "■" = Currently capturing (tap to stop)
  - Gray + spinner = Processing
- **Haptic feedback**: Strong impulse on tap

#### **6. Settings Controls**
- **Size Toggle**: 80×80 or 128×128 frame count
- **Palette Strategy Slider**: Global ←→ Per-Frame (0-100%)
- **Switch Camera**: Front/back toggle (🔄 icon)

---

## User Flow: Capture to GIF

### **Step 1: App Launch**
```
User opens RGB2GIF
         ↓
   Camera permission check
         ↓
   [If denied] → Show permission alert
         ↓
   [If granted] → Initialize camera
         ↓
   Show live preview with square frame overlay
```

**What User Sees:**
- Immediate camera preview
- Clear square frame showing capture area
- "Ready to Capture" status

---

### **Step 2: Frame Capture**
```
User taps red capture button
         ↓
   Camera starts capturing frames (30 FPS)
         ↓
   For each frame:
     - Crop to square (1280×1280)
     - Extract RGB data
     - Store in memory buffer
     - Update frame counter "1/32", "2/32"...
         ↓
   [Auto-stop at 32 frames] OR [User taps again to stop early]
```

**What User Sees:**
- Button changes: Red "●" → Blue "■"
- Frame counter animates: "1/32" → "2/32" → ... → "32/32"
- Square frame overlay pulses gently (visual feedback)
- Haptic feedback every 8 frames (subtle rhythm)
- Estimated time: ~1 second for 32 frames at 30 FPS

---

### **Step 3: Processing (Quantization + GIF Creation)**
```
Capture complete (32 RGB frames in memory)
         ↓
   Status: "Processing GIF..."
         ↓
   Background processing:
     1. Color Quantization (RGB → 256-color palette)
        ├─ Octree algorithm
        ├─ Generate GIP file (palette.gip)
        └─ Map frames to indices (0-255)

     2. LZW Compression
        ├─ Compress index data
        └─ Generate GIX file (frames.gix)

     3. GIP + GIX Composition
        ├─ Merge palette + frames
        └─ Write GIF89a file
         ↓
   Progress bar: [████████░░] 80%
         ↓
   Save to Photos library
         ↓
   Status: "Saved to Photos! ✓"
```

**What User Sees:**
- Modal overlay appears with progress
- Progress bar animates: 0% → 100%
- Processing stages labeled:
  - "Quantizing colors..." (0-40%)
  - "Compressing frames..." (40-70%)
  - "Creating GIF..." (70-90%)
  - "Saving to Photos..." (90-100%)
- Estimated time: ~500ms for 32 frames
- Success animation: Checkmark + confetti burst

---

### **Step 4: Post-Capture Options**
```
GIF saved successfully
         ↓
   User presented with options:
     [View in Gallery]  [Capture Another]  [Share]
```

**What User Sees:**
- Bottom sheet slides up with options
- Thumbnail of created GIF (animated preview)
- Metadata displayed:
  - Size: 1280×1280
  - Frames: 32
  - File size: ~1.2 MB
  - Palette: Balanced (16 colors)
- Quick actions:
  - **View in Gallery**: Navigate to GIP/GIX browser
  - **Capture Another**: Dismiss sheet, reset to Step 1
  - **Share**: System share sheet (Photos, Messages, Files)

---

## User Flow: Gallery Browsing

### **Gallery Entry (from Post-Capture or Tab Navigation)**
```
User taps "View in Gallery"
         ↓
   Navigate to Gallery Screen
```

**Gallery Screen Layout:**
```
┌─────────────────────────────────────┐
│  ╔═══════════════════════════╗     │
│  ║  My Captures              ║     │ ← Header
│  ╚═══════════════════════════╝     │
│                                     │
│  [Palettes] [Captures] [GIFs]      │ ← Tab Bar
│     ▔▔▔▔▔                           │
│                                     │
│  ┌──────────┬──────────┬──────────┐│ ← Grid View
│  │ [Anim]   │ [Anim]   │ [Anim]   ││   (3 columns)
│  │ 2025-01  │ 2025-01  │ 2025-01  ││
│  │ 32 fr    │ 32 fr    │ 32 fr    ││
│  │ 1.1s     │ 1.1s     │ 1.1s     ││
│  └──────────┴──────────┴──────────┘│
│                                     │
│  ┌──────────┬──────────┬──────────┐│
│  │ [Anim]   │ [Anim]   │ [Anim]   ││
│  │ ...      │ ...      │ ...      ││
│  └──────────┴──────────┴──────────┘│
│                                     │
│       [+ New Capture]               │ ← Floating Action
└─────────────────────────────────────┘
```

### **Palettes Tab (GIP Browser)**
```
┌─────────────────────────────────────┐
│  Palette Library                    │
│                                     │
│  ┌──────────┬──────────┬──────────┐│
│  │ [Cube]   │ [Cube]   │ [Cube]   ││ ← 3D Palette Cubes
│  │ Retro    │ Film     │ Balanced ││   (rotating preview)
│  │ 256 col  │ 256 col  │ 256 col  ││
│  │ 5 uses   │ 3 uses   │ 12 uses  ││ ← Usage count
│  └──────────┴──────────┴──────────┘│
│                                     │
│  Tap to view in 3D voxel space     │
└─────────────────────────────────────┘
```

### **Captures Tab (GIX Browser)**
```
┌─────────────────────────────────────┐
│  Capture Sessions                   │
│                                     │
│  ┌─────────────────────────────────┐│
│  │ [Timeline Preview]              ││ ← Scrubber
│  │ ▶━━━━━━━━━━━━━━━━━━━━━━━━━━━━○││   Shows frames
│  │ 2025-01-15 14:30                ││
│  │ 32 frames @ 30fps               ││
│  │ 🎨 Balanced Palette             ││ ← Associated GIP
│  │                                 ││
│  │ [Swap Palette] [Export GIF]    ││ ← Quick Actions
│  └─────────────────────────────────┘│
│                                     │
│  ┌─────────────────────────────────┐│
│  │ [Timeline Preview]              ││
│  │ ...                             ││
│  └─────────────────────────────────┘│
└─────────────────────────────────────┘
```

### **GIFs Tab (Final Exports)**
```
┌─────────────────────────────────────┐
│  Exported GIFs                      │
│                                     │
│  ┌──────────┬──────────┬──────────┐│
│  │ [Anim]   │ [Anim]   │ [Anim]   ││ ← Playing GIFs
│  │ output_1 │ output_2 │ output_3 ││
│  │ 1.1s     │ 1.1s     │ 1.1s     ││
│  │ 1.2 MB   │ 1.5 MB   │ 0.9 MB   ││
│  │                                 ││
│  │ [Share] [Re-compose] [Delete]  ││ ← Actions
│  └──────────┴──────────┴──────────┘│
└─────────────────────────────────────┘
```

---

## Detailed User Journey: First Time User

### **Scenario: Emma wants to create a GIF of her coffee cup**

**Minute 0:00 - App Launch**
- Emma taps RGB2GIF icon
- Camera permission prompt appears
- She taps "Allow"
- Camera preview loads (< 1 second)

**Minute 0:05 - Framing Shot**
- Emma sees her coffee cup in the live preview
- **Square frame overlay shows exact capture area**
- She positions the cup in the center of the square
- White corner brackets help her align precisely

**Minute 0:10 - Start Capture**
- Emma taps the large red button "●"
- Button turns blue "■"
- Frame counter starts: "1/32" → "2/32" → ...
- Square frame overlay pulses gently
- Phone vibrates subtly every 8 frames

**Minute 0:11 - Capture Complete**
- Counter reaches "32/32"
- Button turns gray with spinner
- Status: "Processing GIF..."

**Minute 0:11.5 - Processing**
- Progress bar appears:
  - "Quantizing colors..." (0.2s)
  - "Compressing frames..." (0.2s)
  - "Creating GIF..." (0.1s)
- Confetti animation plays
- Status: "Saved to Photos! ✓"

**Minute 0:12 - Review**
- Bottom sheet slides up
- Thumbnail shows animated GIF preview
- Emma sees metadata:
  - 32 frames, 1.1s duration
  - 1.2 MB file size
- She taps "Share" → Sends to friend via Messages

**Minute 0:15 - Explore Gallery**
- Emma taps "View in Gallery"
- Sees her coffee GIF in grid
- Taps on it → Full-screen playback
- Swipes to "Palettes" tab
- **Sees 3D rotating palette cube** of her coffee colors
- Browns, creams, and ceramic whites plotted in RGB space

**Minute 0:30 - Experiment**
- Emma switches to "Captures" tab
- Taps "Swap Palette" on coffee capture
- Tries "Retro" palette (warmer tones)
- Taps "Export GIF"
- **Same GIX frames, new GIP palette → new aesthetic**
- Saves alternate version to Photos

---

## Key User Experience Principles

### **1. Immediate Clarity**
- **Square frame overlay** eliminates guesswork
- User knows **exactly** what will be captured
- No surprises or unexpected crops

### **2. Visual Feedback**
- Every action has a response:
  - Button state changes (color + icon)
  - Progress indicators (frame counter, progress bar)
  - Haptic feedback (taps, milestones)
  - Animations (pulse, confetti, transitions)

### **3. Speed & Efficiency**
- **Capture**: ~1 second for 32 frames
- **Processing**: ~500ms
- **Total time**: < 2 seconds from tap to GIF
- No waiting, no interruptions

### **4. Modularity Exposed**
- Users understand GIP (palette) ≠ GIX (frames)
- **Palette swapping** is a first-class feature
- Gallery makes this clear with separate tabs

### **5. Approachability**
- Primary flow (Capture → GIF) is dead simple
- Advanced features (palette editing, voxel viz) are **discoverable** not **mandatory**
- Power users can dive deep, casual users get instant results

---

## Square Frame Overlay Specifications

### **Visual Design:**
```
┌─────────────────────────────────────┐
│                                     │
│    ┏━━━━━━━━━━━━━━━━━━━━┓          │ ← Corner brackets (L-shaped)
│    ┃                    ┃          │   15pt × 15pt, 3pt stroke
│    ┃                    ┃          │
│    ┃  CAPTURE AREA      ┃          │ ← Main border
│    ┃  1280×1280         ┃          │   2pt white stroke
│    ┃                    ┃          │   Rounded corners (8pt)
│    ┃                    ┃          │
│    ┗━━━━━━━━━━━━━━━━━━━━┛          │
│                                     │
│    Outside frame: 20% black        │ ← Dimmed area (vignette)
└─────────────────────────────────────┘
```

### **Behavior:**
- **Static** during idle (no capture)
- **Pulsing glow** during capture (0.5s cycle)
- **Green flash** on completion
- **Responsive** to size changes (80×80 vs 128×128)

### **Implementation:**
- CAShapeLayer for border
- UIView with clear cutout for dimming effect
- Core Animation for pulse effect

---

## Apple Glass Enhancement (Future)

### **When Connected to Apple Glass:**

**What User Sees:**
- **iPhone**: Standard camera preview + square frame
- **Apple Glass**:
  - Floating 3D palette cube in AR space
  - Real-time color extraction from camera feed
  - Voxels populate as capture progresses
  - "Capture" gesture: Pinch thumb + index finger

**Spatial Experience:**
```
Real World: Coffee cup on table
         +
AR Overlay:
  - Square frame projects onto table surface
  - Palette cube hovers above cup
  - Each frame adds a temporal "slice" to 3D volume
  - User can "walk around" the captured time
```

---

## Conclusion

**RGB2GIF's first-time experience prioritizes:**
1. **Visual clarity** (square frame overlay)
2. **Speed** (< 2 seconds total)
3. **Feedback** (progress indicators, animations)
4. **Modularity** (GIP/GIX split exposed in UI)
5. **Delight** (voxel visualization, palette swapping)

The **square frame overlay** is critical: it transforms uncertainty into confidence. Users see exactly what they're capturing, building trust and enabling creative framing.
