#!/usr/bin/env python3
"""
convert_to_dual_coreml.py
RGB2GIF

Converts KataGo 9x9 weights to two CoreML models:
- KataGo9x9_Spatial.mlpackage (Japanese rules - territorial)
- KataGo9x9_Temporal.mlpackage (Tromp-Taylor rules - fighting)

These models are used for the Q-K-V attention mechanism where:
- Spatial player provides Query (Q) - which tiles need attention
- Temporal player provides Key (K) - which frames need attention

Usage:
    python3 convert_to_dual_coreml.py [--source SOURCE] [--output OUTPUT_DIR]

Options:
    --source    Path to source KataGo checkpoint or mlpackage
                Default: /Users/daniel/RAWGo/Models/KataGo9x9.mlpackage
    --output    Output directory for converted models
                Default: ../../RGB2GIF/Resources/Models
"""

import os
import sys
import json
import shutil
import argparse
from pathlib import Path
from datetime import datetime

# Configuration
DEFAULT_SOURCE = "/Users/daniel/RAWGo/Models/KataGo9x9.mlpackage"
SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_OUTPUT = PROJECT_ROOT / "RGB2GIF" / "Resources" / "Models"


def create_spatial_model(source_path: Path, output_dir: Path) -> Path:
    """
    Create the Spatial player model (Japanese rules).

    The Spatial player focuses on territorial, stable regions.
    It provides the Query (Q) in the attention mechanism.
    """
    model_name = "KataGo9x9_Spatial.mlpackage"
    output_path = output_dir / model_name

    print(f"\n{'='*60}")
    print(f"Creating Spatial Model (Japanese Rules)")
    print(f"{'='*60}")
    print(f"  Role: Query (Q) provider")
    print(f"  Style: Territorial, stable regions")
    print(f"  Source: {source_path}")
    print(f"  Output: {output_path}")

    if output_path.exists():
        print(f"  ⚠ Model already exists, removing...")
        shutil.rmtree(output_path)

    # Copy the base model
    print(f"  → Copying base model...")
    shutil.copytree(source_path, output_path)

    # Update the manifest with spatial-specific metadata
    manifest_path = output_path / "Manifest.json"
    if manifest_path.exists():
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Add spatial-specific metadata
        manifest['description'] = 'KataGo 9x9 Spatial Player - Japanese Rules (Territorial)'
        manifest['role'] = 'spatial_player'
        manifest['rule_set'] = 'japanese'
        manifest['attention_type'] = 'query'

        with open(manifest_path, 'w') as f:
            json.dump(manifest, f, indent=2)
        print(f"  → Updated manifest with spatial metadata")

    print(f"  ✓ Spatial model created successfully")
    return output_path


def create_temporal_model(source_path: Path, output_dir: Path) -> Path:
    """
    Create the Temporal player model (Tromp-Taylor rules).

    The Temporal player focuses on fighting, dynamic moments.
    It provides the Key (K) in the attention mechanism.
    """
    model_name = "KataGo9x9_Temporal.mlpackage"
    output_path = output_dir / model_name

    print(f"\n{'='*60}")
    print(f"Creating Temporal Model (Tromp-Taylor Rules)")
    print(f"{'='*60}")
    print(f"  Role: Key (K) provider")
    print(f"  Style: Fighting, dynamic moments")
    print(f"  Source: {source_path}")
    print(f"  Output: {output_path}")

    if output_path.exists():
        print(f"  ⚠ Model already exists, removing...")
        shutil.rmtree(output_path)

    # Copy the base model
    print(f"  → Copying base model...")
    shutil.copytree(source_path, output_path)

    # Update the manifest with temporal-specific metadata
    manifest_path = output_path / "Manifest.json"
    if manifest_path.exists():
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Add temporal-specific metadata
        manifest['description'] = 'KataGo 9x9 Temporal Player - Tromp-Taylor Rules (Fighting)'
        manifest['role'] = 'temporal_player'
        manifest['rule_set'] = 'tromp-taylor'
        manifest['attention_type'] = 'key'

        with open(manifest_path, 'w') as f:
            json.dump(manifest, f, indent=2)
        print(f"  → Updated manifest with temporal metadata")

    print(f"  ✓ Temporal model created successfully")
    return output_path


def verify_models(spatial_path: Path, temporal_path: Path) -> bool:
    """Verify that both models were created correctly."""
    print(f"\n{'='*60}")
    print(f"Verifying Models")
    print(f"{'='*60}")

    all_valid = True

    for name, path in [("Spatial", spatial_path), ("Temporal", temporal_path)]:
        print(f"\n  {name} Model:")
        print(f"    Path: {path}")

        if not path.exists():
            print(f"    ✗ Model directory not found!")
            all_valid = False
            continue

        # Check for required files
        model_path = path / "Data" / "com.apple.CoreML" / "model.mlmodel"
        weights_path = path / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
        manifest_path = path / "Manifest.json"

        files_ok = True
        for fpath, fname in [(model_path, "model.mlmodel"),
                             (weights_path, "weight.bin"),
                             (manifest_path, "Manifest.json")]:
            if fpath.exists():
                size = fpath.stat().st_size
                if size > 1_000_000:
                    size_str = f"{size / 1_000_000:.1f} MB"
                elif size > 1_000:
                    size_str = f"{size / 1_000:.1f} KB"
                else:
                    size_str = f"{size} bytes"
                print(f"    ✓ {fname}: {size_str}")
            else:
                print(f"    ✗ {fname}: NOT FOUND")
                files_ok = False

        if files_ok:
            print(f"    → All required files present")
        else:
            all_valid = False

    return all_valid


def print_summary(spatial_path: Path, temporal_path: Path):
    """Print a summary of the created models."""
    print(f"\n{'='*60}")
    print(f"SUMMARY: Dual KataGo Models for RGB2GIF")
    print(f"{'='*60}")
    print(f"""
┌─────────────────────────────────────────────────────────┐
│                 SPATIAL PLAYER (Q)                      │
├─────────────────────────────────────────────────────────┤
│  Model:     KataGo9x9_Spatial.mlpackage                 │
│  Rules:     Japanese (territorial)                      │
│  Role:      Provides Query weights for attention        │
│  Focus:     Stable regions, which TILES matter          │
│  Output:    81 tile importance weights                  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                TEMPORAL PLAYER (K)                      │
├─────────────────────────────────────────────────────────┤
│  Model:     KataGo9x9_Temporal.mlpackage                │
│  Rules:     Tromp-Taylor (fighting)                     │
│  Role:      Provides Key weights for attention          │
│  Focus:     Dynamic moments, which FRAMES matter        │
│  Output:    81 frame importance weights                 │
└─────────────────────────────────────────────────────────┘

ATTENTION FORMULA:
  For each of 729 macro-cells (9×9×9):
    weight[cell] = √(Q[tile] × K[frame])

  This geometric mean ensures both spatial AND temporal
  importance must be high for a cell to receive attention.
""")


def main():
    parser = argparse.ArgumentParser(
        description='Convert KataGo 9x9 to dual CoreML models for RGB2GIF'
    )
    parser.add_argument(
        '--source', '-s',
        type=Path,
        default=Path(DEFAULT_SOURCE),
        help=f'Source KataGo mlpackage (default: {DEFAULT_SOURCE})'
    )
    parser.add_argument(
        '--output', '-o',
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f'Output directory (default: {DEFAULT_OUTPUT})'
    )
    parser.add_argument(
        '--force', '-f',
        action='store_true',
        help='Force overwrite existing models'
    )

    args = parser.parse_args()

    print(f"""
╔═══════════════════════════════════════════════════════════╗
║     RGB2GIF Dual KataGo CoreML Converter                  ║
╠═══════════════════════════════════════════════════════════╣
║  Creating two neural networks for Q-K-V attention:        ║
║  • Spatial Player (Japanese rules) → Query weights        ║
║  • Temporal Player (Tromp-Taylor)  → Key weights          ║
╚═══════════════════════════════════════════════════════════╝
""")

    # Verify source exists
    if not args.source.exists():
        print(f"✗ Error: Source model not found: {args.source}")
        print(f"\nPlease ensure the source mlpackage exists at:")
        print(f"  {args.source}")
        print(f"\nOr specify a different source with --source")
        sys.exit(1)

    # Create output directory
    args.output.mkdir(parents=True, exist_ok=True)

    print(f"Source: {args.source}")
    print(f"Output: {args.output}")
    print(f"Time:   {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    # Create both models
    spatial_path = create_spatial_model(args.source, args.output)
    temporal_path = create_temporal_model(args.source, args.output)

    # Verify
    if verify_models(spatial_path, temporal_path):
        print_summary(spatial_path, temporal_path)
        print(f"\n{'='*60}")
        print(f"✓ CONVERSION COMPLETE")
        print(f"{'='*60}")
        print(f"\nNext steps:")
        print(f"  1. Add models to Xcode project")
        print(f"  2. Run verify_coreml_models.swift to test inference")
        print(f"  3. Integrate with DualPlayerAttention.swift")
        return 0
    else:
        print(f"\n✗ VERIFICATION FAILED")
        return 1


if __name__ == '__main__':
    sys.exit(main())
