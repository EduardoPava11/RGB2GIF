#!/bin/bash
#
# RGB2GIF LLM-Verified Test Runner
# Powered by IBM Granite 4.0 H Tiny
#
# Usage:
#   ./Scripts/run_verified_tests.sh [options]
#
# Options:
#   --strict    Exit with error code if LLM rejects (default: advisory)
#   --suite     Run specific test suite: octree, property, all
#   --dry-run   Show what would be verified without calling LLM
#   --verbose   Enable detailed logging
#
# Environment Variables:
#   GRANITE_STRICT=1     Same as --strict
#   GRANITE_ENDPOINT     Override LLM endpoint (default: http://192.168.1.73:1234)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default configuration
ENDPOINT="${GRANITE_ENDPOINT:-http://192.168.1.73:1234}"
STRICT="${GRANITE_STRICT:-0}"
SUITE="all"
DRY_RUN=0
VERBOSE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --strict)
            STRICT=1
            shift
            ;;
        --suite)
            SUITE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --endpoint)
            ENDPOINT="$2"
            shift 2
            ;;
        --help|-h)
            echo "RGB2GIF LLM-Verified Test Runner"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --strict          Exit with error code if LLM rejects"
            echo "  --suite <name>    Run specific suite: octree, property, all (default: all)"
            echo "  --dry-run         Show what would be verified without calling LLM"
            echo "  --verbose         Enable detailed logging"
            echo "  --endpoint <url>  Override LLM endpoint"
            echo "  --help, -h        Show this help"
            echo ""
            echo "Environment Variables:"
            echo "  GRANITE_STRICT=1     Same as --strict"
            echo "  GRANITE_ENDPOINT     Override LLM endpoint"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Print banner
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  RGB2GIF LLM-Verified Test Framework${NC}"
echo -e "${BLUE}  Powered by IBM Granite 4.0 H Tiny${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Check LLM connectivity
echo -e "${YELLOW}Checking LLM connectivity...${NC}"
LLM_CHECK=$(curl -s --connect-timeout 5 "$ENDPOINT/v1/models" 2>/dev/null || echo "FAILED")

if [[ "$LLM_CHECK" == "FAILED" ]]; then
    echo -e "${RED}ERROR: Cannot connect to LLM at $ENDPOINT${NC}"
    echo -e "${YELLOW}Ensure LM Studio is running with ibm/granite-4-h-tiny loaded${NC}"
    exit 1
fi

if echo "$LLM_CHECK" | grep -q "granite-4-h-tiny"; then
    echo -e "${GREEN}✓ Connected to Granite 4.0 H Tiny${NC}"
else
    echo -e "${YELLOW}⚠ Connected but model may not be granite-4-h-tiny${NC}"
    echo "  Available models: $(echo "$LLM_CHECK" | grep -o '"id":"[^"]*"' | head -3)"
fi
echo ""

# Configuration summary
echo -e "${CYAN}Configuration:${NC}"
echo "  Endpoint: $ENDPOINT"
echo "  Mode: $([ "$STRICT" = "1" ] && echo "STRICT" || echo "ADVISORY")"
echo "  Suite: $SUITE"
echo "  Dry Run: $([ "$DRY_RUN" = "1" ] && echo "YES" || echo "NO")"
echo ""

# Build Swift arguments
SWIFT_ARGS=""
[ "$STRICT" = "1" ] && SWIFT_ARGS="$SWIFT_ARGS --strict"
[ "$DRY_RUN" = "1" ] && SWIFT_ARGS="$SWIFT_ARGS --dry-run"
[ "$VERBOSE" = "1" ] && SWIFT_ARGS="$SWIFT_ARGS --verbose"
SWIFT_ARGS="$SWIFT_ARGS --suite $SUITE"
SWIFT_ARGS="$SWIFT_ARGS --endpoint $ENDPOINT"

# Run the verifier
echo -e "${BLUE}Running LLM-verified tests...${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

cd "$PROJECT_ROOT"

# Execute the Swift verifier
if swift "$SCRIPT_DIR/GraniteLLMVerifier.swift" $SWIFT_ARGS; then
    EXIT_CODE=0
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ALL TESTS VERIFIED SUCCESSFULLY${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
else
    EXIT_CODE=$?
    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  VERIFICATION FAILED${NC}"
    if [ "$STRICT" = "1" ]; then
        echo -e "${RED}  (Strict mode - build blocked)${NC}"
    else
        echo -e "${YELLOW}  (Advisory mode - continuing)${NC}"
        EXIT_CODE=0
    fi
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
fi

echo ""
exit $EXIT_CODE
