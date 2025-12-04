#!/bin/bash
#
# RGB2GIF Dead Code Cleanup Script
# Generated: 2024-12-01
#
# This script safely removes verified dead code from the RGB2GIF project.
# It creates backups before deletion and updates the Xcode project file.
#
# VERIFIED DEAD CODE (never instantiated/referenced):
# - MetalYPlaneDownsampler.swift (400 lines) - declared but never used
# - UnifiedCaptureController.swift (337 lines) - deprecated, throws error
# - StructuredCapturePipeline.swift (346 lines) - experimental, never integrated
#
# NOT DELETED (have actual usage):
# - GIFStreamWriter.swift - USED by GIF89aMuxer
# - HighFidelityDownsampler.swift - USED by OptimizedProcessorFactory
# - RealtimeDownsampler.swift - USED by VoxelGIFProcessor
#

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_ROOT="/Users/daniel/RGB2GIF"
BACKUP_DIR="$PROJECT_ROOT/.cleanup_backup_$(date +%Y%m%d_%H%M%S)"
PBXPROJ="$PROJECT_ROOT/RGB2GIF.xcodeproj/project.pbxproj"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  RGB2GIF Dead Code Cleanup Script${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Files verified as dead code
DEAD_FILES=(
    "RGB2GIF/Sources/Core/Downsampling/MetalYPlaneDownsampler.swift"
    "RGB2GIF/Sources/Camera/UnifiedCaptureController.swift"
    "RGB2GIF/Sources/Camera/StructuredCapturePipeline.swift"
)

# File UUIDs in pbxproj (for removal from Xcode project)
# These are extracted from the project.pbxproj file
declare -A FILE_UUIDS
FILE_UUIDS["MetalYPlaneDownsampler.swift"]="17C0C62864CF9C8DC145AF1A"
FILE_UUIDS["UnifiedCaptureController.swift"]="1AB151CD91043D3BD0FC35FD"
FILE_UUIDS["StructuredCapturePipeline.swift"]=""  # Need to find this

echo -e "${YELLOW}Step 1: Pre-flight checks${NC}"
echo "─────────────────────────────────────────────────────────────"

# Verify project root exists
if [ ! -d "$PROJECT_ROOT" ]; then
    echo -e "${RED}ERROR: Project root not found: $PROJECT_ROOT${NC}"
    exit 1
fi

# Verify pbxproj exists
if [ ! -f "$PBXPROJ" ]; then
    echo -e "${RED}ERROR: Xcode project file not found: $PBXPROJ${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Project root exists${NC}"
echo -e "${GREEN}✓ Xcode project file exists${NC}"
echo ""

# Verify dead files exist
echo -e "${YELLOW}Step 2: Verifying files to delete${NC}"
echo "─────────────────────────────────────────────────────────────"

for file in "${DEAD_FILES[@]}"; do
    full_path="$PROJECT_ROOT/$file"
    if [ -f "$full_path" ]; then
        line_count=$(wc -l < "$full_path" | tr -d ' ')
        echo -e "${GREEN}✓ Found: $file ($line_count lines)${NC}"
    else
        echo -e "${YELLOW}⚠ Not found (already deleted?): $file${NC}"
    fi
done
echo ""

# Final verification of usage (double-check)
echo -e "${YELLOW}Step 3: Final usage verification${NC}"
echo "─────────────────────────────────────────────────────────────"

echo "Checking MetalYPlaneDownsampler usage..."
usage_metal=$(grep -rn "MetalYPlaneDownsampler()" "$PROJECT_ROOT/RGB2GIF/Sources/" --include="*.swift" 2>/dev/null | grep -v "^Binary" | wc -l | tr -d ' ')
if [ "$usage_metal" -eq "0" ]; then
    echo -e "${GREEN}✓ MetalYPlaneDownsampler: No instantiations found${NC}"
else
    echo -e "${RED}✗ MetalYPlaneDownsampler: Found $usage_metal instantiations - ABORTING${NC}"
    exit 1
fi

echo "Checking UnifiedCaptureController usage..."
usage_unified=$(grep -rn "UnifiedCaptureController()" "$PROJECT_ROOT/RGB2GIF/Sources/" --include="*.swift" 2>/dev/null | grep -v "^Binary" | grep -v "UnifiedCaptureController.swift" | wc -l | tr -d ' ')
if [ "$usage_unified" -eq "0" ]; then
    echo -e "${GREEN}✓ UnifiedCaptureController: No external instantiations found${NC}"
else
    echo -e "${RED}✗ UnifiedCaptureController: Found $usage_unified external instantiations - ABORTING${NC}"
    exit 1
fi

echo "Checking StructuredCapturePipeline usage..."
usage_structured=$(grep -rn "StructuredCapturePipeline\|CaptureCoordinator(" "$PROJECT_ROOT/RGB2GIF/Sources/" --include="*.swift" 2>/dev/null | grep -v "^Binary" | grep -v "StructuredCapturePipeline.swift" | wc -l | tr -d ' ')
if [ "$usage_structured" -eq "0" ]; then
    echo -e "${GREEN}✓ StructuredCapturePipeline: No external usage found${NC}"
else
    echo -e "${YELLOW}⚠ StructuredCapturePipeline: Found $usage_structured references - manual review recommended${NC}"
fi

echo ""

# Create backup directory
echo -e "${YELLOW}Step 4: Creating backup${NC}"
echo "─────────────────────────────────────────────────────────────"

mkdir -p "$BACKUP_DIR"
echo "Backup directory: $BACKUP_DIR"

for file in "${DEAD_FILES[@]}"; do
    full_path="$PROJECT_ROOT/$file"
    if [ -f "$full_path" ]; then
        # Preserve directory structure in backup
        backup_path="$BACKUP_DIR/$file"
        mkdir -p "$(dirname "$backup_path")"
        cp "$full_path" "$backup_path"
        echo -e "${GREEN}✓ Backed up: $file${NC}"
    fi
done

# Backup pbxproj
cp "$PBXPROJ" "$BACKUP_DIR/project.pbxproj.backup"
echo -e "${GREEN}✓ Backed up: project.pbxproj${NC}"
echo ""

# Ask for confirmation
echo -e "${YELLOW}Step 5: Confirmation${NC}"
echo "─────────────────────────────────────────────────────────────"
echo ""
echo "The following files will be DELETED:"
for file in "${DEAD_FILES[@]}"; do
    echo "  - $file"
done
echo ""
echo "Backups have been created in: $BACKUP_DIR"
echo ""

read -p "Proceed with deletion? (y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "${YELLOW}Aborted by user${NC}"
    exit 0
fi

echo ""

# Delete files
echo -e "${YELLOW}Step 6: Deleting files${NC}"
echo "─────────────────────────────────────────────────────────────"

deleted_count=0
for file in "${DEAD_FILES[@]}"; do
    full_path="$PROJECT_ROOT/$file"
    if [ -f "$full_path" ]; then
        rm "$full_path"
        echo -e "${GREEN}✓ Deleted: $file${NC}"
        ((deleted_count++))
    fi
done
echo ""

# Update pbxproj (remove file references)
echo -e "${YELLOW}Step 7: Updating Xcode project file${NC}"
echo "─────────────────────────────────────────────────────────────"

# Create a sed script to remove references
# This removes lines containing the file UUIDs from the project file

# MetalYPlaneDownsampler
sed -i '' '/17C0C62864CF9C8DC145AF1A/d' "$PBXPROJ" 2>/dev/null && \
    echo -e "${GREEN}✓ Removed MetalYPlaneDownsampler from Xcode project${NC}" || \
    echo -e "${YELLOW}⚠ Could not remove MetalYPlaneDownsampler reference${NC}"

sed -i '' '/E18DAB5B43C132A8BD39F34E/d' "$PBXPROJ" 2>/dev/null && \
    echo -e "${GREEN}✓ Removed MetalYPlaneDownsampler build phase${NC}" || \
    echo -e "${YELLOW}⚠ Could not remove MetalYPlaneDownsampler build phase${NC}"

# UnifiedCaptureController
sed -i '' '/1AB151CD91043D3BD0FC35FD/d' "$PBXPROJ" 2>/dev/null && \
    echo -e "${GREEN}✓ Removed UnifiedCaptureController from Xcode project${NC}" || \
    echo -e "${YELLOW}⚠ Could not remove UnifiedCaptureController reference${NC}"

# StructuredCapturePipeline - find and remove
sed -i '' '/StructuredCapturePipeline\.swift/d' "$PBXPROJ" 2>/dev/null && \
    echo -e "${GREEN}✓ Removed StructuredCapturePipeline from Xcode project${NC}" || \
    echo -e "${YELLOW}⚠ Could not remove StructuredCapturePipeline reference${NC}"

echo ""

# Summary
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Cleanup Complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Summary:"
echo "  - Files deleted: $deleted_count"
echo "  - Backup location: $BACKUP_DIR"
echo ""
echo "Next steps:"
echo "  1. Open RGB2GIF.xcodeproj in Xcode"
echo "  2. Build the project (Cmd+B) to verify no compile errors"
echo "  3. If errors occur, restore from backup:"
echo "     cp -r $BACKUP_DIR/* $PROJECT_ROOT/"
echo ""
echo -e "${YELLOW}IMPORTANT: Run consolidation script next to update OptimizedProcessorFactory${NC}"
