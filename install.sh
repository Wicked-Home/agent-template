#!/usr/bin/env bash
# install.sh — Add agent-template to the current project
# Usage: curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/install.sh | bash

set -euo pipefail

REPO_URL="https://github.com/Wicked-Home/agent-template"
ARCHIVE_URL="https://github.com/Wicked-Home/agent-template/archive/refs/heads/main.tar.gz"
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log()  { echo -e "  $*"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }
header() { echo -e "\n${BOLD}$*${RESET}"; }

# ── Preflight ──────────────────────────────────────────────────────────────────

header "agent-template installer"
log "Installing into: $(pwd)"

if [ ! -d ".git" ]; then
  warn "No .git directory found. Are you in the right project folder?"
  read -r -p "  Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 1; }
fi

if ! command -v curl &>/dev/null; then
  fail "curl is required but not installed."
  exit 1
fi

# ── Download ───────────────────────────────────────────────────────────────────

header "Downloading agent-template..."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$tmpdir" --strip-components=1
ok "Downloaded from $REPO_URL"

# ── Install files ──────────────────────────────────────────────────────────────

header "Installing files..."

# Create .claude/agents/ if missing
mkdir -p .claude/agents
ok "Directory .claude/agents/ ready"

# Copy workflow.md
if [ -f "workflow.md" ]; then
  warn "workflow.md already exists — skipping (delete it first to reinstall)"
else
  cp "$tmpdir/workflow.md" workflow.md
  ok "workflow.md"
fi

# Copy each agent, skip existing files
agents_installed=0
agents_skipped=0
for src in "$tmpdir/agents/"*.md; do
  filename=$(basename "$src")
  dest=".claude/agents/$filename"
  if [ -f "$dest" ]; then
    warn ".claude/agents/$filename already exists — skipping"
    ((agents_skipped++)) || true
  else
    cp "$src" "$dest"
    ok ".claude/agents/$filename"
    ((agents_installed++)) || true
  fi
done

# Copy install.sh itself so the project has it for reference
if [ ! -f "install.sh" ]; then
  cp "$tmpdir/install.sh" install.sh
fi

# ── .gitignore ────────────────────────────────────────────────────────────────

header "Checking .gitignore..."

gitignore_updated=false
if [ ! -f ".gitignore" ]; then
  touch .gitignore
fi

for pattern in ".beads/" "__pycache__/" "*.pyc" "node_modules/" ".env" "*.key" "*.pem" ".claude/manager-session.md" ".claude/design-feedback-*.md"; do
  if ! grep -qF "$pattern" .gitignore 2>/dev/null; then
    echo "$pattern" >> .gitignore
    gitignore_updated=true
  fi
done

if $gitignore_updated; then
  ok ".gitignore updated"
else
  ok ".gitignore already covers required patterns"
fi

# ── Dependency checks ──────────────────────────────────────────────────────────

header "Checking dependencies..."

dolt_ok=false
bd_ok=false

if command -v dolt &>/dev/null; then
  ok "dolt $(dolt version --feature 2>/dev/null | head -1 || dolt version 2>/dev/null | head -1)"
  dolt_ok=true
else
  fail "dolt not found — bd requires it"
  log "  macOS:  brew install dolt"
  log "  Linux:  curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash"
fi

if command -v bd &>/dev/null; then
  ok "bd $(bd --version 2>/dev/null || echo '(version unknown)')"
  bd_ok=true
else
  if $dolt_ok; then
    fail "bd not found"
    log "  Install: curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
  else
    warn "bd not found (install dolt first, then run the beads install script)"
  fi
fi

if $bd_ok; then
  if [ -d ".beads" ]; then
    ok "bd already initialized in this project"
  else
    log "Initializing bd..."
    bd init --stealth && ok "bd initialized (--stealth)" || warn "bd init failed — run 'bd init --stealth' manually"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────

header "Done"

log "$agents_installed agent(s) installed, $agents_skipped skipped (already existed)"
echo ""
log "Next steps:"
echo ""

if ! $dolt_ok; then
  log "  1. Install dolt (see above)"
  log "  2. curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
  log "  3. Start a new Claude Code session"
  log "  4. @\"initiator (agent)\" validate this project's setup"
elif ! $bd_ok; then
  log "  1. curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash"
  log "  2. Start a new Claude Code session"
  log "  3. @\"initiator (agent)\" validate this project's setup"
else
  log "  1. Start a new Claude Code session"
  log "  2. @\"initiator (agent)\" validate this project's setup"
fi
echo ""
