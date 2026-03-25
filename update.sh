#!/usr/bin/env bash
# update.sh — Update agent-template agents in the current project
# Usage: curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/update.sh | bash
#        curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/update.sh | bash -s -- --include-code-agent

set -euo pipefail

REPO_URL="https://github.com/Wicked-Home/agent-template"
ARCHIVE_URL="https://github.com/Wicked-Home/agent-template/archive/refs/heads/main.tar.gz"
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log()    { echo -e "  $*"; }
ok()     { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()   { echo -e "  ${YELLOW}!${RESET} $*"; }
fail()   { echo -e "  ${RED}✗${RESET} $*"; }
header() { echo -e "\n${BOLD}$*${RESET}"; }

# ── Flags ──────────────────────────────────────────────────────────────────────

include_code_agent=false
for arg in "$@"; do
  case "$arg" in
    --include-code-agent) include_code_agent=true ;;
    *) fail "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Preflight ──────────────────────────────────────────────────────────────────

header "agent-template updater"
log "Updating agents in: $(pwd)"

if [ ! -d ".claude/agents" ]; then
  fail ".claude/agents/ not found — run install.sh first"
  exit 1
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

# ── Update agents ──────────────────────────────────────────────────────────────

header "Updating agents..."

if ! $include_code_agent; then
  warn "Skipping code-agent.md (project-specific — use --include-code-agent to overwrite)"
fi

agents_updated=0
agents_skipped=0
for src in "$tmpdir/agents/"*.md; do
  filename=$(basename "$src")
  dest=".claude/agents/$filename"

  if [ "$filename" = "code-agent.md" ] && ! $include_code_agent; then
    ((agents_skipped++)) || true
    continue
  fi

  if [ -f "$dest" ]; then
    cp "$src" "$dest"
    ok ".claude/agents/$filename (updated)"
    ((agents_updated++)) || true
  else
    cp "$src" "$dest"
    ok ".claude/agents/$filename (new)"
    ((agents_updated++)) || true
  fi
done

# Also update update.sh itself
cp "$tmpdir/update.sh" update.sh
ok "update.sh"

# ── Summary ────────────────────────────────────────────────────────────────────

header "Done"

log "$agents_updated agent(s) updated, $agents_skipped skipped"
echo ""
log "Start a new Claude Code session to pick up the changes."
echo ""
