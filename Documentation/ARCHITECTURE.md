# RGB2GIF - Modular GIF Creation Architecture

## Vision
A modular iPhone app that captures camera frames and processes them into two complementary files (GIP & GIX) which can be composed into GIF89a animations. Designed for iPhone 17 Pro, iOS 26, with Apple Glass spatial UI support.

---

## Core Concept: GIP/GIX Split Architecture

### **GIP (Palette) File - "GiP2" Format**
**Purpose**: 256-color RGB palette container
**File Extension**: `.gip`
**Magic Header**: `GiP2` (4 bytes)

**Structure**:
```
- Magic: "GiP2"
- Version: u8 (currently 2)
- Palette Exponent: u8 (locked to 7 = 256 colors for RGB2GIF)
- Hash Algorithm: u8 (SHA256 for content-addressing)
- Has Global: bool (first palette = Global Color Table)
- Has Frame Set: bool (per-frame palettes included)
- Name: String (UTF-8 label)
- Palettes: Array of:
  - Entry Count: u16 (256)
  - Dimensions: u8 (1D or 2D tensor)
  - Dim A/B: u16 (e.g., 256×1 or 16×16)
  - Ordering: u8 (row/column major)
  - Transparency: bool + index
  - Label: String
  - RGB Data: 256 × 3 bytes
  - Remap: Optional 256-byte permutation
  - Hash: SHA256 digest
```

**Key Features**:
- **Content-addressed**: Identical palettes share the same hash
- **Tensor-aware**: Supports 1D (256×1) or 2D (16×16) palette layouts
- **GIF89a compliant**: Maps directly to Global/Local Color Tables
- **Reusable**: One GIP can serve multiple GIX files

---

### **GIX (Index Stream) File - "GiX2" Format**
**Purpose**: Grayscale index raster (frame sequences)
**File Extension**: `.gix`
**Magic Header**: `GiX2` (4 bytes)

**Structure**:
```
- Magic: "GiX2"
- Version: u8 (currently 2)
- Width: u16 (e.g., 1440)
- Height: u16 (e.g., 1440)
- LZW Min Code Size: u8 (2-12, typically 8 for 256 colors)
- Default Palette Ref: u32 (index into GIP palette array)
- Name: String
- Loop Count: Optional u16 (0=forever, nil=no loop)
- Frames: Array of:
  - Palette Ref: u32 (which GIP palette to use)
  - Delay: u16 (centiseconds, 1/100 sec)
  - Disposal: u8 (0=none, 1=keep, 2=restore bg, 3=restore prev)
  - Transparency: bool + index
  - Data Encoding: u8 (0=LZW+subblocks for GIF export, 1=raw for 3D visualization)
  - Payload: Data (LZW-compressed or raw indices)
  - Position: u16×2 (left, top offset)
  - Frame Size: u16×2 (width, height)
  - Interlaced: bool
```

**Key Features**:
- **Grayscale-native**: Stores indices 0-255 (no color data)
- **Per-frame palettes**: Each frame can reference different GIP palettes
- **GIF89a timing**: Direct support for delays, disposal methods
- **Compression-ready**: LZW-encoded payloads ready for GIF embedding

---

## Modular Pipeline Architecture

### **Phase 1: Capture (Camera → RGB Frames)**
```
iPhone 17 Pro Camera (48MP main, RAW support)
         ↓
   NV12 Pixel Buffer (4096×3072 native)
         ↓
   Square Crop (3072×3072 center)
         ↓
   Downsample to Target (1440×1440, 720×720, 360×360)
         ↓
   RGB Frame Buffer (ready for quantization)
```

**Components**:
- `SimpleCameraManager`: AVCaptureSession wrapper
- `SquareCropper`: Center-crop to square aspect
- `RealtimeDownsampler`: Metal-accelerated Lanczos downsampling
- `HighFidelityDownsampler`: Multi-algorithm quality preservation

---

### **Phase 2: Quantization (RGB → Palette + Indices)**
```
RGB Frame Buffer
         ↓
    ┌────────────────┐
    │ Color Analysis │
    └────────────────┘
         ↓
   Octree Quantizer / MedianCut / K-Means
         ↓
    ┌─────────────────────────┐
    │  256-Color RGB Palette  │ ──→ GIP File
    └─────────────────────────┘
         ↓
    ┌─────────────────────────┐
    │ Index Mapping (0-255)   │
    └─────────────────────────┘
         ↓
    Grayscale Index Raster (1440×1440 × u8)
         ↓
    LZW Compression
         ↓
    GIX Frame Payload
```

**Components**:
- `OctreeColorQuantizer`: Adaptive octree-based quantization
- `LumaQuantizer`: Y-plane extraction for grayscale workflows
- `PaletteLibrary`: Named palette presets (Retro, Film, Vaporwave)
- `GIPPaletteLoader`: Load/save GIP files
- `LZWEncoder_Optimized`: GIF89a-compliant LZW compression

---

### **Phase 3: Storage (Modular File System)**
```
Document Directory/
├── Palettes/               # Reusable GIP files
│   ├── Global_SHA256.gip   # Content-addressed
│   ├── Retro.gip
│   └── Film.gip
│
├── Captures/               # Per-session folders
│   ├── 2025-01-15_14-30/
│   │   ├── frames.gix      # Index stream
│   │   ├── palette.gip     # Associated palette
│   │   └── metadata.json
│   │
│   └── 2025-01-15_15-45/
│       ├── frames.gix
│       └── palette_ref.txt # Reference to shared GIP hash
│
└── Exports/                # Final GIF89a files
    ├── output_001.gif
    └── output_002.gif
```

**Storage Principles**:
- **Deduplication**: Identical palettes share one GIP (content-addressed)
- **Separation of Concerns**: Palettes (GIP) separate from frames (GIX)
- **Composition on Demand**: GIF89a files generated when needed
- **Metadata**: JSON sidecar files for session info

---

### **Phase 4: Composition (GIP + GIX → GIF89a)**
```
GIP File (palette.gip)
         +
GIX File (frames.gix)
         ↓
    ┌──────────────────┐
    │ GIPGIXComposer   │
    └──────────────────┘
         ↓
   GIF89a Header
         ↓
   Logical Screen Descriptor (width, height)
         ↓
   Global Color Table (from GIP palette[0])
         ↓
   NETSCAPE2.0 Extension (loop count from GIX)
         ↓
   For each GIX frame:
     - Graphic Control Extension (delay, disposal, transparency)
     - Image Descriptor (position, size)
     - Local Color Table (if frame uses different palette)
     - LZW Image Data (from GIX payload)
         ↓
   GIF Trailer (0x3B)
         ↓
   output.gif
```

**Components**:
- `GIPGIXComposer`: Merge GIP + GIX into GIF89a
- `GIF89aMuxer`: Write spec-compliant GIF files
- `GIF89aValidator`: Round-trip validation

---

## Voxel Visualization System

### **GIP Visualization: 3D Palette Cube**
**Concept**: Visualize 256-color palette as a 3D cube in RGB color space

```
3D Color Space (RGB Cube)
   R (Red)
    ↑
    │     Each point = one palette color
    │    ●  ●  ●
    │   ●  ●  ●
    │  ●  ●  ●
    └──────────→ G (Green)
   ↙
  B (Blue)

Rendering:
- Metal SceneKit for GPU acceleration
- Each voxel = sphere/cube at (R, G, B) coordinate
- Size: Normalized to 0.0-1.0 (0-255 → 0.0-1.0)
- Color: RGB value itself
- Interactive: Rotate, zoom, highlight
```

**16×16 Tensor Palette**:
```
Option: Organize as 16×16 grid in 2D space
  - X-axis: Hue gradient
  - Y-axis: Brightness gradient
  - Visualize as textured plane or layered cubes
```

**Implementation**:
- `VoxelCubeVisualizer`: SceneKit-based 3D renderer
- `PaletteLUTRenderer`: Metal shader for palette skinning
- `Palette3DView`: SwiftUI wrapper for spatial interaction

---

### **GIX Visualization: Temporal Grayscale Voxels**
**Concept**: Visualize index stream as 3D temporal volume

```
Spatial Dimensions:
  X × Y = Frame dimensions (e.g., 1440×1440)

Temporal Dimension:
  Z = Frame index (0 to frameCount-1)

3D Volume:
  1440 × 1440 × 32 (for 32-frame sequence)

Each voxel = (x, y, t) → index value (0-255)
  - Render as grayscale intensity
  - Temporal slicing: Scroll through frames
  - Iso-surface: Highlight regions with same index
```

**Rendering Options**:
1. **Stack View**: Frames layered in Z-depth
2. **Lenticular**: Animate through time as rotation
3. **Heatmap**: Temporal change detection (frame differencing)
4. **Ray-marching**: Volume rendering for density visualization

**Implementation**:
- `VoxelGIFProcessor`: Temporal volume construction
- `VoxelRenderer`: Metal compute shaders for ray-marching
- `GIFGalleryView`: Timeline scrubber for frame navigation

---

## Gallery System: Dual-Aspect Management

### **Palette Gallery (GIP Browser)**
```
Grid View:
┌──────────┬──────────┬──────────┐
│ [Cube]   │ [Cube]   │ [Cube]   │
│ Retro    │ Film     │ Vapor    │
│ 256 cols │ 256 cols │ 256 cols │
│ SHA256:… │ SHA256:… │ SHA256:… │
└──────────┴──────────┴──────────┘

Detail View:
- 3D Palette Cube (rotatable)
- Color distribution histogram
- Metadata: Hash, dimensions, usage count
- Actions: Duplicate, Export, Delete
- "Used By": List of GIX files referencing this palette
```

**Features**:
- **Content-addressed**: No duplicates (same palette = same hash)
- **Reference tracking**: Show which captures use each palette
- **Favorites**: Pin commonly used palettes
- **Import/Export**: Share `.gip` files between devices

---

### **Capture Gallery (GIX Browser)**
```
Timeline View:
┌─────────────────────────────────┐
│ [2025-01-15 14:30]              │
│ ▶ frames.gix (32 frames)        │
│ 🎨 Retro Palette                │
│ 1440×1440, 24fps, 1.3s          │
└─────────────────────────────────┘

Playback View:
- GIX frame player (grayscale)
- Overlay: Palette-skinned preview
- Timeline scrubber
- Export to GIF89a button
```

**Features**:
- **Live Preview**: GIP + GIX composition preview (no file write)
- **Palette Swap**: Try different GIP files with same GIX
- **Trim/Edit**: Select frame range, adjust timing
- **Batch Export**: Process multiple captures at once

---

### **Composition Gallery (GIF89a Output)**
```
Grid View:
┌──────────┬──────────┬──────────┐
│ [Anim]   │ [Anim]   │ [Anim]   │
│ out_001  │ out_002  │ out_003  │
│ 1.3s     │ 2.5s     │ 0.8s     │
│ 24fps    │ 12fps    │ 30fps    │
└──────────┴──────────┴──────────┘

Actions:
- Share (Photos, Files, AirDrop)
- Re-compose (edit GIP/GIX source)
- Validate (GIF89a spec compliance)
- Delete
```

---

## Apple Glass UI Integration (Spatial Computing)

### **Target Platform**: iPhone 17 Pro + Apple Glass (visionOS 3+)

### **Spatial Experiences**

#### **1. Floating Palette Cube (Ambient Mode)**
```
Real-world space:
  User's desk/workspace

Augmented elements:
  - 3D Palette Cube floating at eye level
  - Rotates slowly (ambient animation)
  - Pinch to zoom, drag to rotate
  - Tap color → show RGB values + usage stats
```

**Use Case**: Explore palettes in 3D while reviewing captures on iPhone

---

#### **2. Temporal GIX Volume (Immersive Mode)**
```
Full immersive space:
  - GIX frames rendered as translucent slices
  - User "walks through" temporal volume
  - Hand gestures:
    - Swipe left/right: Scroll through frames
    - Pinch: Adjust transparency
    - Two-hand grab: Rotate entire volume
```

**Use Case**: Analyze temporal patterns, detect motion artifacts

---

#### **3. Multi-Capture Comparison (Windowed Mode)**
```
Spatial windows:
  - 3 floating GIF previews side-by-side
  - Synchronized playback
  - Swap palettes in real-time
  - Visual diff overlay (highlight changes)
```

**Use Case**: A/B test different quantization settings

---

#### **4. Palette Workshop (Object Mode)**
```
Physical interaction:
  - GIP file = holographic cube object
  - Place on real surface (desk, table)
  - Two users can view/edit same palette
  - Collaborative color picking
```

**Use Case**: Team workflows, palette sharing

---

### **Apple Glass Specific Features**

**Hand Tracking**:
- **Pinch + Drag**: Rotate voxel visualizations
- **Double-Tap**: Play/pause GIF preview
- **Swipe**: Navigate gallery

**Eye Tracking**:
- **Gaze Selection**: Highlight palette colors by looking
- **Dwell Selection**: Stare at UI element for 0.8s to activate

**Spatial Audio**:
- **Palette Sonification**: Each color mapped to frequency (RGB → pitch)
- **Temporal Audio**: GIX frame rate → rhythm/tempo
- **Export Notification**: Spatial ping when GIF composition completes

**Anchoring**:
- **World Anchors**: Pin GIP cubes to real-world locations
- **Device Anchors**: GIX player follows iPhone position
- **Head Anchors**: HUD overlay for metadata (frame count, FPS)

---

## Technical Specifications

### **Performance Targets (iPhone 17 Pro)**
| Component | Target | Notes |
|-----------|--------|-------|
| Capture Rate | 30 FPS | Camera → RGB buffer |
| Quantization | < 50ms/frame | RGB → Palette + Indices |
| LZW Compression | < 20ms/frame | Indices → GIX payload |
| GIP+GIX → GIF | < 500ms | 32-frame composition |
| Voxel Rendering | 60 FPS | Metal GPU acceleration |

### **Hardware Utilization**
- **Neural Engine**: Unused (reserved for future ML quantization)
- **GPU (A18 Pro)**: Metal shaders for downsampling, voxel rendering
- **ISP**: NV12 Y-plane extraction (zero-copy when possible)
- **Storage**: Documents directory (user-accessible, iCloud backup)

### **File Size Estimates**
| Asset | Size | Example |
|-------|------|---------|
| GIP (256 colors) | ~800 bytes | One 256-color palette |
| GIX (32 frames, 1440×1440, LZW) | ~1-3 MB | Typical compression ratio |
| GIF89a (composed) | ~1-3 MB | Same as GIX (palette overhead minimal) |

---

## Modular Benefits

### **1. Palette Reuse**
- **Scenario**: Capture 10 GIX files with same "Retro" palette
- **Storage**: 1 GIP file (800 bytes) + 10 GIX files (~20 MB total)
- **vs. Traditional**: 10 full GIF files (~30 MB total, redundant palette data)

### **2. Palette Swapping**
- **Scenario**: Change aesthetic without re-capturing
- **Workflow**:
  1. Capture GIX with default palette
  2. Later: Swap to "Film" palette in gallery
  3. Re-compose GIF with new colors
- **Benefit**: Instant re-skinning, no camera access needed

### **3. Content-Addressed Deduplication**
- **Scenario**: Two users create identical palettes
- **Storage**: SHA256 hash = same → one shared GIP file
- **Benefit**: Automatic deduplication across app installs

### **4. Batch Processing**
- **Scenario**: Apply one palette to 50 GIX files
- **Workflow**:
  1. Select GIP in palette gallery
  2. "Apply to..." → select multiple GIX files
  3. Batch export 50 GIFs
- **Benefit**: Consistent aesthetic across large batches

---

## Development Roadmap

### **Phase 1: Core Pipeline (Week 1-2)**
- [x] GIP/GIX file format implementation
- [x] Basic camera capture (SimpleCameraManager)
- [ ] RGB → Palette quantization (OctreeColorQuantizer)
- [ ] Palette → Indices mapping
- [ ] LZW compression (GIX payload)
- [ ] GIP + GIX → GIF89a composer

### **Phase 2: Gallery & Storage (Week 3-4)**
- [ ] File system architecture (Palettes/, Captures/, Exports/)
- [ ] Palette gallery UI (grid + detail view)
- [ ] Capture gallery UI (timeline + playback)
- [ ] Export gallery (GIF management)
- [ ] Content-addressed GIP storage (SHA256 hashing)

### **Phase 3: Voxel Visualization (Week 5-6)**
- [ ] 3D Palette Cube (SceneKit + Metal)
- [ ] Temporal GIX Volume (ray-marching)
- [ ] Interactive controls (rotate, zoom, slice)
- [ ] SwiftUI integration

### **Phase 4: Apple Glass Integration (Week 7-8)**
- [ ] visionOS project setup
- [ ] Spatial palette cube (immersive spaces)
- [ ] Hand tracking for interaction
- [ ] Multi-window capture comparison
- [ ] Collaborative palette editing

### **Phase 5: Polish & Optimization (Week 9-10)**
- [ ] Performance tuning (Metal optimization)
- [ ] A18 Pro Neural Engine exploration
- [ ] Batch processing workflows
- [ ] iCloud sync for GIP/GIX files
- [ ] Export presets (quality profiles)

---

## Key Innovations

1. **Separation of Color & Structure**: GIP (palette) vs GIX (indices) enables modular composition
2. **Content-Addressed Palettes**: SHA256 hashing prevents duplication
3. **Tensor-Aware Palettes**: 1D/2D layouts support neural network workflows
4. **Voxel-Native Visualization**: 3D exploration of both color space (GIP) and temporal data (GIX)
5. **Apple Glass Spatial UI**: First GIF creation app designed for spatial computing
6. **GIF89a Round-Trip**: Full spec compliance with lossless decode/encode

---

## File Format Specifications

### **GIP Binary Layout**
```
Offset | Size | Field
-------|------|------
0      | 4    | Magic ("GiP2")
4      | 1    | Version (2)
5      | 1    | Palette Exponent (7 for 256 colors)
6      | 1    | Hash Algorithm (1=SHA256)
7      | 1    | Flags (hasGlobal, hasFrameSet)
8      | 2    | Name Length (u16)
10     | N    | Name (UTF-8)
...    | ...  | Palette Entries (variable)
```

### **GIX Binary Layout**
```
Offset | Size | Field
-------|------|------
0      | 4    | Magic ("GiX2")
4      | 1    | Version (2)
5      | 2    | Width (u16)
7      | 2    | Height (u16)
9      | 1    | LZW Min Code Size
10     | 4    | Default Palette Ref (u32)
14     | 2    | Name Length (u16)
16     | N    | Name (UTF-8)
...    | ...  | Frame Entries (variable)
```

---

## Conclusion

**RGB2GIF** reimagines GIF creation as a **modular, composable pipeline** where:
- **Palettes (GIP)** are first-class, reusable assets
- **Frame data (GIX)** is decoupled from color information
- **Voxel visualization** makes invisible data tangible
- **Apple Glass** brings spatial computing to creative workflows

This architecture enables workflows impossible with traditional monolithic GIF files: instant palette swapping, content-addressed deduplication, collaborative editing, and 3D temporal analysis.

**Target**: Ship 1.0 to App Store in 10 weeks, with Apple Glass support ready for visionOS 3 launch.
