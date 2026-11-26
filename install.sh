#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="${REPO_DIR}/skill"

INSTALL_AGY=0
INSTALL_CLAUDE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]
  --antigravity   Install symlink for Google Antigravity (~/.gemini/config/skills/codex-whip)
  --claude        Install symlink for Claude Code (~/.claude/skills/codex-whip)
  --all           Install for both Antigravity and Claude Code (default)
  -h, --help      Show this help
EOF
}

if [[ $# -eq 0 ]]; then
  INSTALL_AGY=1
  INSTALL_CLAUDE=1
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --antigravity) INSTALL_AGY=1; shift ;;
      --claude) INSTALL_CLAUDE=1; shift ;;
      --all) INSTALL_AGY=1; INSTALL_CLAUDE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
fi

chmod +x "${SKILL_SRC}/scripts/run_codex.sh" "${SKILL_SRC}/scripts/open_codex.sh"

link_skill() {
  local target_parent="$1"
  local label="$2"
  local dest="${target_parent}/codex-whip"
  mkdir -p "$target_parent"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "Skipping ${label}: ${dest} already exists and is not a symlink. Remove or back it up first." >&2
    return 1
  fi
  ln -sfn "$SKILL_SRC" "$dest"
  echo "Installed ${label}: ${dest} -> ${SKILL_SRC}"
}

if [[ "$INSTALL_AGY" -eq 1 ]]; then
  link_skill "$HOME/.gemini/config/skills" "Antigravity"
fi

if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
  link_skill "$HOME/.claude/skills" "Claude Code"
fi

if command -v codex >/dev/null 2>&1; then
  echo "Detected Codex CLI: $(command -v codex)"
elif [[ -x "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" ]]; then
  echo "Detected Codex CLI (ChatGPT Desktop): /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
else
  echo "Note: 'codex' CLI not detected yet. Install Codex CLI (or set CODEX_BIN) before running."
fi

echo ""
echo "Done! Tip: watch live Codex logs in a side terminal with:"
echo "  tail -F /tmp/codex-whip-latest.log"
