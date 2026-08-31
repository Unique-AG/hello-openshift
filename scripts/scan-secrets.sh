#!/bin/bash
set -euo pipefail

#######################################
# Secret Scanning Script
#######################################
#
# This script scans the entire git history for secrets using gitleaks
# and provides comprehensive reporting of potential security issues.
#
# Usage:
#   ./scripts/scan-secrets.sh [options]
#
# Options:
#   --all         Scan entire repository history, every ref (default)
#   --staged      Scan only staged changes
#   --commit      Scan specific commit (requires --commit-hash)
#   --commit-hash HASH    Specify commit hash for --commit mode
#   --help        Show this help message
#
# Examples:
#   ./scripts/scan-secrets.sh                    # Scan all history
#   ./scripts/scan-secrets.sh --staged           # Scan staged changes
#   ./scripts/scan-secrets.sh --commit --commit-hash abc123  # Scan specific commit
#######################################

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Default values
SCAN_MODE="all"
COMMIT_HASH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --all)
      SCAN_MODE="all"
      shift
      ;;
    --staged)
      SCAN_MODE="staged"
      shift
      ;;
    --commit)
      SCAN_MODE="commit"
      shift
      ;;
    --commit-hash)
      COMMIT_HASH="$2"
      shift 2
      ;;
    --help|-h)
      echo -e "${BLUE}Secret Scanning Script${NC}"
      echo ""
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --all                    Scan entire repository history, every ref (default)"
      echo "  --staged                 Scan only staged changes"
      echo "  --commit                 Scan specific commit (requires --commit-hash)"
      echo "  --commit-hash HASH       Specify commit hash for --commit mode"
      echo "  --help, -h               Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                       # Scan all history"
      echo "  $0 --staged              # Scan staged changes"
      echo "  $0 --commit --commit-hash abc123  # Scan specific commit"
      exit 0
      ;;
    *)
      echo -e "${RED}❌ Unknown option: $1${NC}"
      echo -e "${YELLOW}Use --help for usage information${NC}"
      exit 1
      ;;
  esac
done

# Validate arguments
if [[ "$SCAN_MODE" == "commit" && -z "$COMMIT_HASH" ]]; then
  echo -e "${RED}❌ Error: --commit mode requires --commit-hash${NC}"
  exit 1
fi

echo -e "${BLUE}🔍 Starting secret scan...${NC}"
echo -e "${YELLOW}Mode: ${SCAN_MODE}${NC}"
if [[ -n "$COMMIT_HASH" ]]; then
  echo -e "${YELLOW}Commit: ${COMMIT_HASH}${NC}"
fi

# Check if gitleaks is installed
if ! command -v gitleaks &>/dev/null; then
  echo -e "${RED}❌ Error: gitleaks is not installed${NC}"
  echo -e "${YELLOW}   Install with: brew install gitleaks${NC}"
  exit 1
fi

GITLEAKS_VERSION=$(gitleaks version 2>/dev/null || echo "unknown")
echo -e "${GREEN}✅ gitleaks ${GITLEAKS_VERSION} found${NC}"

# Create temporary file for results
RESULTS_FILE=$(mktemp)
trap "rm -f $RESULTS_FILE" EXIT

# Run gitleaks based on scan mode
echo -e "${BLUE}🔐 Running gitleaks scan...${NC}"

# gitleaks exit codes: 0 = clean, 1 = leaks found, anything else = a real
# error. Conflating "leaks found" with "the tool failed" is what previously made
# a positive result print "scan completed with warnings" instead of failing.
COMMON_ARGS=(--verbose --redact --report-format json
             --report-path "$RESULTS_FILE"
             --config "$SCRIPT_DIR/gitleaks-config.toml")
RC=0

case "$SCAN_MODE" in
  "all")
    # Full history, every ref. No --log-opts: the previous
    # `--branches=$(git rev-parse --abbrev-ref HEAD)` expanded to
    # `--branches=HEAD` on a detached HEAD, which matches no branch, scans
    # nothing, and reports the repository clean.
    gitleaks git "${COMMON_ARGS[@]}" || RC=$?
    ;;

  "staged")
    # `git --staged` scans the staged blobs. The previous
    # `echo "$FILES" | gitleaks detect --no-git` did not scan staged content at
    # all: gitleaks ignores that stdin and scans the working directory instead,
    # and both branches of the `if` then set SCAN_SUCCESS=true regardless.
    if [[ -z "$(git diff --cached --name-only)" ]]; then
      echo -e "${GREEN}✅ nothing staged${NC}"
      echo "[]" > "$RESULTS_FILE"
    else
      gitleaks git --staged "${COMMON_ARGS[@]}" || RC=$?
    fi
    ;;

  "commit")
    # `-1 <sha>` rather than `<sha>^..<sha>`, which cannot resolve a root commit.
    gitleaks git --log-opts="-1 $COMMIT_HASH" "${COMMON_ARGS[@]}" || RC=$?
    ;;
esac

if [[ "$RC" -le 1 ]]; then
  SCAN_SUCCESS=true
else
  SCAN_SUCCESS=false
fi

# Process results
if [[ "$SCAN_SUCCESS" == true ]]; then
  # Check if any secrets were found
  SECRET_COUNT=$(jq 'length' "$RESULTS_FILE" 2>/dev/null || echo "0")

  if [[ "$SECRET_COUNT" -eq 0 ]]; then
    echo -e "${GREEN}✅ No secrets found!${NC}"
    echo -e "${GREEN}   Repository appears to be clean.${NC}"
  else
    echo -e "${RED}❌ Secrets detected!${NC}"
    echo -e "${RED}   Found ${SECRET_COUNT} potential secrets${NC}"
    echo ""

    # Display detailed results
    echo -e "${PURPLE}📋 Secret Details:${NC}"
    jq -r '.[] | "🔴 \(.Description) in \(.File) at line \(.StartLine)\n   Rule: \(.RuleID)\n   Commit: \(.Commit)\n"' "$RESULTS_FILE" 2>/dev/null || echo "   Unable to parse results"

    echo ""
    echo -e "${YELLOW}⚠️  Action Required:${NC}"
    echo -e "${YELLOW}   1. Review the secrets above${NC}"
    echo -e "${YELLOW}   2. Remove or replace sensitive data${NC}"
    echo -e "${YELLOW}   3. Consider rotating any exposed credentials${NC}"
    echo -e "${YELLOW}   4. Amend commits if secrets were committed${NC}"

    exit 1
  fi
else
  echo -e "${YELLOW}⚠️  Scan completed with warnings${NC}"
  echo -e "${YELLOW}   Check the output above for any issues${NC}"
  exit 1
fi

echo -e "${GREEN}🎉 Secret scan completed successfully!${NC}"
