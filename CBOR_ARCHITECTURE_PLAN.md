# RGB2GIF CBOR Architecture Plan

## Overview

Replace opaque CGImage buffers with inspectable CBOR data files for the 81×81×81 RGB cube.
This enables offline debugging, reproducible testing, and cleaner separation of concerns.

---

## Phase 1: CBOR Data Format

### 1.1 RGBCube81 Structure

```
┌─────────────────────────────────────────────────────────────┐
│  RGBCube81.cbor                                             │
├─────────────────────────────────────────────────────────────┤
│  {                                                          │
│    "magic": "RGB81",                                        │
│    "version": 1,                                            │
│    "dimensions": {                                          │
│      "width": 81,                                           │
│      "height": 81,                                          │
│      "frames": 81                                           │
│    },                                                       │
│    "pixelFormat": "RGB8",  // 3 bytes per pixel             │
│    "totalBytes": 1594323,  // 81 × 81 × 81 × 3              │
│    "data": <binary>        // Raw RGB bytes, frame-major    │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘

Memory Layout:
  Frame 0: pixels[0..6560] = 81×81 RGB triplets
  Frame 1: pixels[6561..13121]
  ...
  Frame 80: pixels[524880..531440]

Total: 531,441 pixels × 3 bytes = 1,594,323 bytes (~1.5 MB)
```

### 1.2 TensorCube729 Structure

```
┌─────────────────────────────────────────────────────────────┐
│  TensorCube729.cbor                                         │
├─────────────────────────────────────────────────────────────┤
│  {                                                          │
│    "magic": "T729",                                         │
│    "version": 1,                                            │
│    "gridDimension": 9,                                      │
│    "cells": [                                               │
│      {                                                      │
│        "index": [t, y, x],  // 0-8 each                     │
│        "centroid": [r, g, b],                               │
│        "weight": 123.45,                                    │
│        "pixelCount": 729                                    │
│      },                                                     │
│      ... // 729 cells                                       │
│    ],                                                       │
│    "statistics": {                                          │
│      "nonZeroCells": 729,                                   │
│      "totalWeight": 12345.67,                               │
│      "uniqueColors": 512                                    │
│    }                                                        │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Palette256 Structure

```
┌─────────────────────────────────────────────────────────────┐
│  Palette256.cbor                                            │
├─────────────────────────────────────────────────────────────┤
│  {                                                          │
│    "magic": "PAL256",                                       │
│    "version": 1,                                            │
│    "colorCount": 256,                                       │
│    "colors": [                                              │
│      [r0, g0, b0],                                          │
│      [r1, g1, b1],                                          │
│      ...                                                    │
│    ],                                                       │
│    "histogram": [count0, count1, ...],  // usage per color  │
│    "quantizationMethod": "octree"                           │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Phase 2: New File Structure

```
RGB2GIF/
├── Sources/
│   ├── App/
│   ├── Camera/
│   │   ├── CameraManager.swift
│   │   └── FrameBuffer.swift
│   ├── CBOR/                          # NEW
│   │   ├── CBOREncoder.swift          # CBOR writing
│   │   ├── CBORDecoder.swift          # CBOR reading
│   │   ├── RGBCube81.swift            # 81×81×81 data model
│   │   ├── TensorCube729Export.swift  # Tensor → CBOR
│   │   └── Palette256Export.swift     # Palette → CBOR
│   ├── Pipeline/
│   │   ├── GIF81Pipeline.swift        # Refactored to use CBOR
│   │   ├── TensorCube729.swift
│   │   ├── OctreeColorQuantizer.swift
│   │   └── GIF81Debugger.swift
│   ├── GIF/
│   │   ├── GIFWriter.swift
│   │   └── LZWEncoder.swift
│   └── UI/
│       ├── CaptureViewController.swift
│       └── DebugViewController.swift  # NEW: CBOR inspector
└── Debug/                             # NEW: Sample data
    ├── test_gradient.cbor
    ├── test_solid_red.cbor
    └── captured_session_001.cbor
```

---

## Phase 3: Pipeline Refactor

### 3.1 Current Flow (Opaque)
```
Camera → CGImage → FrameBuffer → Pipeline → GIF
         (GPU?)      (memory)     (process)
```

### 3.2 New Flow (Inspectable)
```
Camera → CGImage → RGBCube81 → [Save .cbor] → TensorCube729 → Palette256 → GIF
                       ↓              ↓              ↓             ↓
                   .cbor file    .cbor file    .cbor file    .cbor file
```

### 3.3 Debug Modes

```swift
enum PipelineMode {
    case live           // Camera → GIF (production)
    case capture        // Camera → CBOR (save for debugging)
    case replay(URL)    // CBOR → GIF (reproducible testing)
    case stepThrough    // Pause at each stage, save intermediate CBOR
}
```

---

## Phase 4: Implementation Tasks

### 4.1 CBOR Foundation (Week 1)
- [ ] Add SwiftCBOR dependency or write minimal encoder
- [ ] RGBCube81 struct with CBOR serialization
- [ ] Unit tests with synthetic data (gradient, solid colors)

### 4.2 Capture Integration (Week 1)
- [ ] Modify FrameBuffer to build RGBCube81
- [ ] Add "Save Cube" button to capture UI
- [ ] File naming: `cube_YYYYMMDD_HHMMSS.cbor`

### 4.3 Pipeline Refactor (Week 2)
- [ ] GIF81Pipeline accepts RGBCube81 instead of [CGImage]
- [ ] TensorCube729 exports to CBOR
- [ ] Palette256 exports to CBOR
- [ ] Frame indices export (81 × 6561 bytes)

### 4.4 Debug Tools (Week 2)
- [ ] DebugViewController: load and inspect CBOR
- [ ] Frame scrubber (view any of 81 frames)
- [ ] Tensor cell grid visualization
- [ ] Palette color swatch display
- [ ] Side-by-side: original vs quantized

### 4.5 Quality Improvements (Week 3)
- [ ] Floyd-Steinberg dithering option
- [ ] Median-cut quantization alternative
- [ ] Temporal smoothing for animation
- [ ] Adaptive palette per-frame option

---

## Phase 5: CBOR File Debugging Workflow

### 5.1 Capture Session
```
1. Launch app
2. Tap "Capture" → records 81 frames
3. Tap "Save Debug Data" → writes cube_20241203_143022.cbor
4. Share via AirDrop or Files app
```

### 5.2 Desktop Analysis
```bash
# Convert CBOR to JSON for inspection
cbor2json cube_20241203_143022.cbor > cube.json

# Extract frame 40 as PNG
python3 extract_frame.py cube.cbor 40 frame40.png

# Analyze tensor distribution
python3 analyze_tensor.py tensor.cbor
```

### 5.3 Replay Testing
```
1. Launch app in Debug mode
2. Load cube.cbor from Files
3. Step through pipeline stages
4. Compare output GIF with expected
```

---

## Phase 6: Swift CBOR Implementation

### Minimal CBOR Encoder (No Dependencies)

```swift
/// Minimal CBOR encoder for RGB2GIF debug data
struct CBORWriter {
    private var data = Data()

    mutating func writeMap(_ count: Int) {
        if count < 24 {
            data.append(0xA0 | UInt8(count))
        } else {
            data.append(0xB9)
            data.append(UInt8((count >> 8) & 0xFF))
            data.append(UInt8(count & 0xFF))
        }
    }

    mutating func writeString(_ string: String) {
        let bytes = Array(string.utf8)
        if bytes.count < 24 {
            data.append(0x60 | UInt8(bytes.count))
        } else {
            data.append(0x79)
            data.append(UInt8((bytes.count >> 8) & 0xFF))
            data.append(UInt8(bytes.count & 0xFF))
        }
        data.append(contentsOf: bytes)
    }

    mutating func writeBytes(_ bytes: [UInt8]) {
        // CBOR byte string (major type 2)
        if bytes.count < 24 {
            data.append(0x40 | UInt8(bytes.count))
        } else if bytes.count <= 0xFFFF {
            data.append(0x59)
            data.append(UInt8((bytes.count >> 8) & 0xFF))
            data.append(UInt8(bytes.count & 0xFF))
        } else {
            data.append(0x5A)
            data.append(UInt8((bytes.count >> 24) & 0xFF))
            data.append(UInt8((bytes.count >> 16) & 0xFF))
            data.append(UInt8((bytes.count >> 8) & 0xFF))
            data.append(UInt8(bytes.count & 0xFF))
        }
        data.append(contentsOf: bytes)
    }

    mutating func writeInt(_ value: Int) {
        if value >= 0 {
            if value < 24 {
                data.append(UInt8(value))
            } else if value <= 0xFF {
                data.append(0x18)
                data.append(UInt8(value))
            } else if value <= 0xFFFF {
                data.append(0x19)
                data.append(UInt8((value >> 8) & 0xFF))
                data.append(UInt8(value & 0xFF))
            } else {
                data.append(0x1A)
                data.append(UInt8((value >> 24) & 0xFF))
                data.append(UInt8((value >> 16) & 0xFF))
                data.append(UInt8((value >> 8) & 0xFF))
                data.append(UInt8(value & 0xFF))
            }
        }
    }

    func finalize() -> Data { data }
}
```

---

## Immediate Next Steps

1. **Create RGBCube81.swift** - Data model for 81×81×81 RGB
2. **Create CBORWriter.swift** - Minimal CBOR encoder
3. **Modify FrameBuffer** - Build RGBCube81 from captured frames
4. **Add Save Button** - Export CBOR for debugging
5. **Test with known data** - Verify pipeline with gradient/solid cubes

---

## Benefits Summary

| Current | With CBOR |
|---------|-----------|
| Opaque CGImage buffers | Inspectable RGB data files |
| Debug with print() only | Full offline analysis |
| Can't reproduce bugs | Exact reproduction from .cbor |
| Pipeline is monolithic | Each stage independently testable |
| No test data | Synthetic test cubes |

---

## Questions to Resolve

1. **CBOR library**: Use SwiftCBOR package or minimal custom encoder?
2. **Storage location**: App Documents folder or share via Files?
3. **Compression**: CBOR as-is (~1.5MB) or add zlib compression?
4. **UI integration**: Separate debug view or overlay on main capture?

