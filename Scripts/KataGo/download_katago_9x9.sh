#!/bin/bash
#
# download_katago_9x9.sh
# RGB2GIF
#
# Downloads the specialized KataGo 9x9 neural network weights
# from the official KataGo v1.13.2-kata9x9 release.
#
# This network is specially finetuned for 9x9 boards and is
# likely one of the strongest KataGo nets for 9x9 play.
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODELS_DIR="$PROJECT_ROOT/RGB2GIF/Resources/Models"
RAWGO_MODELS_DIR="/Users/daniel/RAWGo/Models"

# KataGo 9x9 specialized network
KATAGO_RELEASE_TAG="v1.13.2-kata9x9"
KATAGO_9X9_URL="https://github.com/lightvector/KataGo/releases/download/${KATAGO_RELEASE_TAG}/kata9x9-b18c384nbt.bin.gz"
KATAGO_WEIGHTS_FILE="kata9x9-b18c384nbt.bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     RGB2GIF KataGo 9x9 Network Downloader                 ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Create models directory if it doesn't exist
mkdir -p "$MODELS_DIR"

# Check if we already have the weights from RAWGo
if [ -f "$RAWGO_MODELS_DIR/$KATAGO_WEIGHTS_FILE" ]; then
    echo -e "${GREEN}✓ Found existing KataGo weights in RAWGo:${NC}"
    echo "  $RAWGO_MODELS_DIR/$KATAGO_WEIGHTS_FILE"
    echo ""

    # Check for existing CoreML models
    if [ -d "$RAWGO_MODELS_DIR/KataGo9x9.mlpackage" ]; then
        echo -e "${GREEN}✓ Found existing CoreML model:${NC}"
        echo "  $RAWGO_MODELS_DIR/KataGo9x9.mlpackage"
        echo ""
        echo -e "${YELLOW}Using existing RAWGo models as templates...${NC}"

        # Copy as Spatial model (Japanese rules)
        if [ ! -d "$MODELS_DIR/KataGo9x9_Spatial.mlpackage" ]; then
            echo "  → Copying as KataGo9x9_Spatial.mlpackage..."
            cp -R "$RAWGO_MODELS_DIR/KataGo9x9.mlpackage" "$MODELS_DIR/KataGo9x9_Spatial.mlpackage"
            echo -e "    ${GREEN}✓ Created Spatial model (Japanese rules)${NC}"
        else
            echo -e "    ${YELLOW}⚠ Spatial model already exists, skipping${NC}"
        fi

        # Copy as Temporal model (Tromp-Taylor rules)
        if [ ! -d "$MODELS_DIR/KataGo9x9_Temporal.mlpackage" ]; then
            echo "  → Copying as KataGo9x9_Temporal.mlpackage..."
            cp -R "$RAWGO_MODELS_DIR/KataGo9x9.mlpackage" "$MODELS_DIR/KataGo9x9_Temporal.mlpackage"
            echo -e "    ${GREEN}✓ Created Temporal model (Tromp-Taylor rules)${NC}"
        else
            echo -e "    ${YELLOW}⚠ Temporal model already exists, skipping${NC}"
        fi

        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║     Setup Complete!                                       ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Models created:"
        ls -la "$MODELS_DIR"/*.mlpackage 2>/dev/null || echo "  (no mlpackage files found)"
        echo ""
        exit 0
    fi
fi

# Download fresh weights from GitHub
echo -e "${YELLOW}Downloading KataGo 9x9 specialized network...${NC}"
echo "  URL: $KATAGO_9X9_URL"
echo "  Release: $KATAGO_RELEASE_TAG"
echo ""

cd "$MODELS_DIR"

if [ -f "${KATAGO_WEIGHTS_FILE}.gz" ]; then
    echo -e "${YELLOW}⚠ Compressed weights already exist, skipping download${NC}"
else
    echo "Downloading..."
    curl -L -o "${KATAGO_WEIGHTS_FILE}.gz" "$KATAGO_9X9_URL"
    echo -e "${GREEN}✓ Download complete${NC}"
fi

if [ -f "$KATAGO_WEIGHTS_FILE" ]; then
    echo -e "${YELLOW}⚠ Decompressed weights already exist${NC}"
else
    echo "Decompressing..."
    gunzip -k "${KATAGO_WEIGHTS_FILE}.gz"
    echo -e "${GREEN}✓ Decompression complete${NC}"
fi

echo ""
echo "Downloaded weights:"
ls -la "$MODELS_DIR/$KATAGO_WEIGHTS_FILE"*
echo ""
echo -e "${YELLOW}Note: Run convert_to_dual_coreml.py to create CoreML models${NC}"
echo ""
