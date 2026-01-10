#!/usr/bin/env bash
# Sync local main with upstream/main via rebase
# Usage: ./scripts/sync-upstream.sh [--merge]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

USE_MERGE=0
for arg in "$@"; do
  case "$arg" in
    --merge) USE_MERGE=1 ;;
    --help|-h)
      echo "Usage: $0 [--merge]"
      echo "  --merge  Use merge instead of rebase"
      exit 0
      ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# Check for clean working tree
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  warn "Working tree has uncommitted changes"
  git status --short
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

log "Fetching upstream..."
git fetch upstream

# Show divergence
COUNTS=$(git rev-list --left-right --count main...upstream/main 2>/dev/null || echo "0 0")
AHEAD=$(echo "$COUNTS" | awk '{print $1}')
BEHIND=$(echo "$COUNTS" | awk '{print $2}')

log "Current status: $AHEAD commits ahead, $BEHIND commits behind upstream/main"

if [[ "$BEHIND" == "0" ]]; then
  log "Already up to date with upstream!"
  exit 0
fi

# Show what we're about to incorporate
log "Upstream commits to incorporate:"
git log --oneline main..upstream/main | head -10
[[ "$BEHIND" -gt 10 ]] && echo "  ... and $((BEHIND - 10)) more"

if [[ "$USE_MERGE" == "1" ]]; then
  log "Merging upstream/main..."
  git merge upstream/main --no-edit
else
  log "Rebasing onto upstream/main..."
  if ! git rebase upstream/main; then
    warn "Rebase conflicts detected. Resolve and run:"
    echo "  git add <files>"
    echo "  git rebase --continue"
    echo "  # Then re-run this script or continue manually"
    exit 1
  fi
fi

log "Installing dependencies..."
pnpm install

log "Building TypeScript..."
pnpm build

log "Building UI..."
pnpm ui:build

log "Running doctor..."
pnpm clawdbot doctor || warn "Doctor reported issues (non-fatal)"

log "Rebuilding macOS app..."
if [[ -f "./scripts/restart-mac.sh" ]]; then
  ./scripts/restart-mac.sh
else
  warn "restart-mac.sh not found, skipping macOS rebuild"
fi

log "Sync complete!"
echo ""
echo "Next steps:"
if [[ "$USE_MERGE" == "1" ]]; then
  echo "  git push origin main"
else
  echo "  git push origin main --force-with-lease"
fi
echo ""
echo "Verify with:"
echo "  pnpm clawdbot health"
echo "  pnpm test"
