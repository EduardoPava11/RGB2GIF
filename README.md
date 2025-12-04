# RGB2GIF

**A Neural-Inspired GIF Pipeline for iOS 26**

RGB2GIF transforms live camera footage into animated GIFs using a novel 729-cell tensor architecture inspired by the game of Go. The system captures 81 frames at 30fps, processes them through a 9×9×9 spatiotemporal cube, and outputs an 81×81 pixel GIF animation.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           RGB2GIF PIPELINE                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  CAMERA (720×1280)                                                              │
│      │                                                                          │
│      ▼                                                                          │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐           │
│  │ L0_RAW  │──▶│L2_FRAMES│──▶│L3_TENSOR│──▶│L4_PALETTE│──▶│L5_INDICES│──▶ GIF  │
│  │ BGRA    │   │ RGB 81² │   │ 729 cells│   │ 256 colors│   │ 81×81×81 │        │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘   └─────────┘           │
│                                                                                 │
│  81 frames     81 frames     9×9×9 cube    Global        Per-frame              │
│  720×1280      81×81 RGB     weighted      palette       indices                │
│                              centroids                                          │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## The 729-Cell Tensor Architecture

### Why 729? The Go Board Connection

The number 729 = 9³ = 9 × 9 × 9 is not arbitrary. It reflects a **spatiotemporal cube** where:

- **X-axis (9 cells)**: Horizontal spatial position in the frame
- **Y-axis (9 cells)**: Vertical spatial position in the frame
- **T-axis (9 cells)**: Temporal position across the 81-frame sequence

```
                    T (time: frames 0-80, grouped into 9 slices)
                    │
                    │    ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐
                    │   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱│
                    │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │
                    │ ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱│ │
                    │├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │╱
                    ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱│ ├───▶ Y (spatial)
                   ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │╱
                  ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱│ ├
                 └───┴───┴───┴───┴───┴───┴───┴───┴───┘ │╱
                                                        ├───▶ X (spatial)

                 Each cell contains a WEIGHTED RGB CENTROID
                 representing all pixels in that spatiotemporal region
```

### Cell Indexing Formula

Each cell is addressed by a linear index derived from its 3D coordinates:

```
cell_index = t * 81 + y * 9 + x

where:
  t ∈ [0, 8]  (temporal slice: frames 0-8, 9-17, ..., 72-80)
  y ∈ [0, 8]  (vertical position in 81×81 frame)
  x ∈ [0, 8]  (horizontal position in 81×81 frame)
```

### What Each Cell Contains

Each of the 729 cells stores:

```swift
struct TensorCell {
    let index: Int           // 0-728
    let position: (t, y, x)  // 3D coordinates
    let centroid: RGB        // Weighted average color
    let weight: Int          // Number of contributing pixels (typically 729)
    let sourceRange: Range   // Which frames/pixels contributed
}
```

The centroid is computed as:
```
centroid = Σ(pixel_color × pixel_weight) / Σ(pixel_weight)
```

This aggregation reduces 81 frames × 81×81 pixels = **531,441 RGB values** down to **729 representative colors**.

---

## Pipeline Stages (CBOR-Based)

All intermediate data is stored in CBOR (Concise Binary Object Representation) format for efficient serialization and debugging.

### L0_RAW: Camera Capture
- **Input**: Live camera feed at 720×1280 @ 30fps
- **Output**: 81 CBOR files (`r00.cbor` - `r80.cbor`)
- **Format**: BGRA8 pixel data with timestamps

### L2_FRAMES: Crop & Resize
- **Input**: L0 raw frames
- **Output**: 81 CBOR files (`f00.cbor` - `f80.cbor`)
- **Transform**: Center-crop to square (720×720), resize to 81×81
- **Format**: RGB8 pixel data

### L3_TENSOR: Spatiotemporal Aggregation
- **Input**: L2 frames
- **Output**: 729 CBOR files (`c000.cbor` - `c728.cbor`) + `summary.cbor`
- **Transform**: Each 9×9 spatial region across 9 temporal frames → 1 weighted centroid
- **Format**: Cell metadata with RGB centroid and weight

### L4_PALETTE: Color Quantization
- **Input**: L3 tensor centroids
- **Output**: `palette.cbor` + `mapping.cbor`
- **Algorithm**: Octree color quantization
- **Result**: 256-color global palette + 729→256 mapping

### L5_INDICES: Palette Application
- **Input**: L2 frames + L4 palette
- **Output**: 81 CBOR files (`i00.cbor` - `i80.cbor`)
- **Transform**: Each RGB pixel → nearest palette index
- **Format**: 6561 bytes per frame (81×81 indices)

### L6_OUTPUT: GIF Encoding
- **Input**: L5 indices + L4 palette
- **Output**: `animation.gif`
- **Format**: GIF89a with LZW compression

---

## MVP Roadmap

### MVP0: Core Pipeline (✅ COMPLETE)

**Goal**: End-to-end GIF generation from camera capture.

**What We Built**:
1. **CBOR-based pipeline** with 6 stages (L0→L2→L3→L4→L5→L6)
2. **729-cell tensor architecture** for spatiotemporal color analysis
3. **Octree color quantizer** reducing colors to 256-palette
4. **LZW encoder** with GIF89a-compliant output
5. **Comprehensive test suite** (70+ tests)

**Critical Bug Fixed**: LZW Code Size Transition Timing

The LZW encoder had a subtle timing bug where code size transitions (9→10→11→12 bits) happened one code too early compared to standard GIF decoders. This caused:
- "Broken data stream" errors in decoders
- Wrong pixel counts (e.g., 1821 instead of 6561)
- Corrupted GIF output

**Root Cause**: Encoder and decoder add dictionary entries at different points:
```
Encoder: emit code C → add entry N (based on extended sequence)
Decoder: read code C → add entry N-1 (based on prev + current[0])
```

**Fix**: Implemented **deferred code size transition** - when `nextCode > maxCode`, set a flag but apply the transition AFTER the next emit, synchronizing with decoder timing.

---

### MVP1: Dual Neural Network Integration (🔮 PLANNED)

**Goal**: Replace static weighted centroids with neural network-derived importance weights.

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         MVP1: DUAL GO NEURAL NETWORKS                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────┐         ┌─────────────────────┐                        │
│  │   SPATIAL NN        │         │   TEMPORAL NN       │                        │
│  │   (KataGo-derived)  │         │   (KataGo-derived)  │                        │
│  ├─────────────────────┤         ├─────────────────────┤                        │
│  │ Input: 9×9 color    │         │ Input: 9-frame      │                        │
│  │        positions    │         │        sequence     │                        │
│  │                     │         │                     │                        │
│  │ Output: Per-cell    │         │ Output: Per-cell    │                        │
│  │         importance  │         │         motion      │                        │
│  │         weights     │         │         weights     │                        │
│  └──────────┬──────────┘         └──────────┬──────────┘                        │
│             │                               │                                   │
│             └───────────┬───────────────────┘                                   │
│                         │                                                       │
│                         ▼                                                       │
│              ┌─────────────────────┐                                            │
│              │   WEIGHT FUSION     │                                            │
│              │   spatial × temporal │                                            │
│              └──────────┬──────────┘                                            │
│                         │                                                       │
│                         ▼                                                       │
│              ┌─────────────────────┐                                            │
│              │   729 WEIGHTED      │                                            │
│              │   CENTROIDS         │                                            │
│              └─────────────────────┘                                            │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Why Go Neural Networks?**

The game of Go operates on a 9×9/19×19 board where:
- **Spatial patterns** determine territory and influence
- **Temporal sequences** determine strategic value (joseki, fuseki)
- **Attention** must balance local tactics vs. global strategy

These properties map directly to GIF compression:
- **Spatial importance**: Which regions deserve more color fidelity?
- **Temporal importance**: Which frames show significant motion?
- **Attention balance**: Static backgrounds vs. moving subjects

**KataGo Integration**:
- Use pre-trained KataGo 9×9 weights
- Repurpose "territory estimation" as "color importance"
- Repurpose "move prediction" as "motion saliency"

---

### MVP2: Transformer-Based Weight Balancing (🔮 PLANNED)

**Goal**: Learn optimal fusion of spatial and temporal weights via transformer attention.

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    MVP2: PREFERENCE TRANSFORMER                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐              │
│  │ Spatial Weights │    │ Temporal Weights│    │ Content Features│              │
│  │ (from MVP1)     │    │ (from MVP1)     │    │ (color, edges)  │              │
│  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘              │
│           │                      │                      │                       │
│           └──────────────────────┼──────────────────────┘                       │
│                                  │                                              │
│                                  ▼                                              │
│                    ┌─────────────────────────┐                                  │
│                    │   CROSS-ATTENTION       │                                  │
│                    │   TRANSFORMER           │                                  │
│                    │                         │                                  │
│                    │   Q: Content features   │                                  │
│                    │   K: Spatial weights    │                                  │
│                    │   V: Temporal weights   │                                  │
│                    └────────────┬────────────┘                                  │
│                                 │                                               │
│                                 ▼                                               │
│                    ┌─────────────────────────┐                                  │
│                    │   LEARNED FUSION        │                                  │
│                    │   α(content) × spatial  │                                  │
│                    │   + β(content) × temporal│                                  │
│                    └────────────┬────────────┘                                  │
│                                 │                                               │
│                                 ▼                                               │
│                    ┌─────────────────────────┐                                  │
│                    │   ADAPTIVE WEIGHTS      │                                  │
│                    │   per-cell, per-frame   │                                  │
│                    └─────────────────────────┘                                  │
│                                                                                 │
│  TRAINING:                                                                      │
│  - User preferences on generated GIFs                                           │
│  - A/B testing: "Which GIF looks better?"                                       │
│  - Reinforcement learning from human feedback                                   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Key Innovation**: The transformer learns WHEN to prioritize spatial vs. temporal information:
- **High motion scenes**: Emphasize temporal weights (capture movement)
- **Static scenes with rich color**: Emphasize spatial weights (preserve detail)
- **Mixed scenes**: Content-adaptive blending

---

## LZW Encoder/Decoder Deep Dive

### GIF LZW Compression

GIF uses LZW (Lempel-Ziv-Welch) compression with variable-width codes:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        LZW COMPRESSION FLOW                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  INPUT: [0, 1, 2, 0, 1, 2, 0, 1, 2, ...]  (palette indices)                    │
│                                                                                 │
│  DICTIONARY BUILDING:                                                           │
│  ┌────────┬─────────────┐                                                       │
│  │ Code   │ Sequence    │                                                       │
│  ├────────┼─────────────┤                                                       │
│  │ 0-255  │ Single bytes│  ← Initial (literals)                                │
│  │ 256    │ CLEAR       │  ← Reset signal                                       │
│  │ 257    │ EOI         │  ← End of image                                       │
│  │ 258    │ [0, 1]      │  ← First new entry                                    │
│  │ 259    │ [1, 2]      │                                                       │
│  │ 260    │ [2, 0]      │                                                       │
│  │ 261    │ [0, 1, 2]   │  ← Longer sequences                                   │
│  │ ...    │ ...         │                                                       │
│  │ 4095   │ (max)       │  ← 12-bit limit                                       │
│  └────────┴─────────────┘                                                       │
│                                                                                 │
│  OUTPUT: [CLEAR, 0, 1, 2, 258, 260, 261, ..., EOI]  (variable-width codes)     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Code Size Transitions

The code width increases as the dictionary grows:

| Dictionary Size | Code Width | Max Code |
|-----------------|------------|----------|
| 0-511           | 9 bits     | 511      |
| 512-1023        | 10 bits    | 1023     |
| 1024-2047       | 11 bits    | 2047     |
| 2048-4095       | 12 bits    | 4095     |

### The Timing Bug (Fixed in MVP0)

**Problem**: Encoder and decoder were out of sync on transitions.

```
ENCODER timeline:
  emit 253 (9-bit) → add entry 511 → TRANSITION → emit 254 (10-bit)

DECODER timeline:
  read 253 (9-bit) → add entry 510 → read 254 (9-bit!) → add entry 511 → TRANSITION

RESULT: Decoder reads 254 with wrong bit width → corrupted stream
```

**Solution**: Deferred transition in encoder:

```swift
// After adding entry that triggers transition
if nextCode > maxCode && codeSize < 12 {
    deferredCodeSizeIncrease = true  // Don't transition yet!
}

// In emitCode(), AFTER emitting:
if deferredCodeSizeIncrease {
    codeSize += 1
    maxCode = (1 << codeSize) - 1
    deferredCodeSizeIncrease = false
}
```

This ensures the code that triggers the transition is emitted with the OLD size, matching decoder expectations.

---

## Building & Running

### Requirements
- Xcode 26+
- iOS 26.0+ Simulator or Device
- Swift 6.2

### Build
```bash
xcodebuild -project RGB2GIF.xcodeproj \
  -scheme RGB2GIF \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  build
```

### Test Suite
The app includes a comprehensive test suite (70+ tests):
- **L0_RAW**: Camera capture validation
- **L2_FRAMES**: Crop/resize verification
- **L3_TENSOR**: 729-cell structure tests
- **L4_PALETTE**: Color quantization tests
- **L5_INDICES**: Palette mapping tests
- **CROSS-STAGE**: Data consistency
- **END-TO-END**: Full pipeline
- **LZW DIAGNOSTIC**: Encoder round-trip tests

---

## File Structure

```
RGB2GIF/
├── RGB2GIF/
│   └── Sources/
│       ├── App/              # AppDelegate, SceneDelegate
│       ├── Camera/           # CameraManager, FrameBuffer
│       ├── CBOR/             # Session management, exporters
│       ├── Core/             # Error definitions
│       ├── GIF/              # LZWEncoder, GIFWriter, PhotosSaver
│       ├── Pipeline/         # GIF81Pipeline, OctreeQuantizer, VoxelCube729
│       ├── Testing/          # Comprehensive test suite
│       └── UI/               # CaptureViewController
├── Archive/                  # Legacy/experimental code
└── README.md
```

---

## License

MIT License - See LICENSE file for details.

---

## Acknowledgments

- **KataGo**: Inspiration for neural network architecture (MVP1/MVP2)
- **GIF89a Specification**: W3C GIF format documentation
- **LZW Algorithm**: Lempel, Ziv, and Welch's compression innovation
