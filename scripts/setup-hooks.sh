#!/bin/bash
set -euo pipefail

#######################################
# Setup Git Hooks Script
#######################################
#
# This script sets up git hooks for secret scanning and validation.
# Run this after cloning the repository.
#
# Usage:
#   ./scripts/setup-hooks.sh
#
#######################################

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 Setting up git hooks...${NC}"

# Check if we're in a git repository
if [[ ! -d "${PROJECT_ROOT}/.git" ]]; then
  echo -e "${RED}❌ Error: Not a git repository${NC}"
  exit 1
fi

# Create hooks directory if it doesn't exist
mkdir -p "${PROJECT_ROOT}/.git/hooks"

# Create symbolic links for hooks
echo -e "${YELLOW}📎 Creating symbolic links for hooks...${NC}"

# Pre-commit hook
if [[ -f "${PROJECT_ROOT}/scripts/hooks/pre-commit" ]]; then
  ln -sf "../../scripts/hooks/pre-commit" "${PROJECT_ROOT}/.git/hooks/pre-commit"
  chmod +x "${PROJECT_ROOT}/.git/hooks/pre-commit"
  echo -e "${GREEN}✅ pre-commit hook installed${NC}"
else
  echo -e "${RED}❌ pre-commit hook not found${NC}"
fi

# Pre-push hook
if [[ -f "${PROJECT_ROOT}/scripts/hooks/pre-push" ]]; then
  ln -sf "../../scripts/hooks/pre-push" "${PROJECT_ROOT}/.git/hooks/pre-push"
  chmod +x "${PROJECT_ROOT}/.git/hooks/pre-push"
  echo -e "${GREEN}✅ pre-push hook installed${NC}"
else
  echo -e "${RED}❌ pre-push hook not found${NC}"
fi

# Check for required tools
echo -e "${BLUE}🔍 Checking required tools...${NC}"

if command -v gitleaks &>/dev/null; then
  GITLEAKS_VERSION=$(gitleaks version 2>/dev/null || echo "unknown")
  echo -e "${GREEN}✅ gitleaks ${GITLEAKS_VERSION} found${NC}"
else
  echo -e "${YELLOW}⚠️  gitleaks not found - install with: brew install gitleaks${NC}"
fi

if command -v kustomize &>/dev/null; then
  KUSTOMIZE_VERSION=$(kustomize version 2>/dev/null | head -1 || echo "unknown")
  echo -e "${GREEN}✅ kustomize ${KUSTOMIZE_VERSION} found${NC}"
elif command -v kubectl &>/dev/null; then
  KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null || echo "unknown")
  echo -e "${GREEN}✅ kubectl ${KUBECTL_VERSION} found (using for kustomize)${NC}"
else
  echo -e "${YELLOW}⚠️  kustomize/kubectl not found - install for Kustomize validation${NC}"
fi

if command -v terraform &>/dev/null; then
  TERRAFORM_VERSION=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' || echo "unknown")
  echo -e "${GREEN}✅ terraform ${TERRAFORM_VERSION} found${NC}"
else
  echo -e "${YELLOW}⚠️  terraform not found - install for Terraform validation${NC}"
fi

echo -e "${GREEN}🎉 Git hooks setup complete!${NC}"
echo ""
echo -e "${BLUE}ℹ️  Hooks will now run automatically:${NC}"
echo -e "   • pre-commit: Secret scanning + validation on staged files"
echo -e "   • pre-push: Full repository secret scan + validation"
