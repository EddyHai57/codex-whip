#!/usr/bin/env bash
set -euo pipefail

resolve_codex_bin() {
  if [[ -n "${CODEX_BIN:-}" && -x "${CODEX_BIN}" ]]; then
    printf '%s\n' "${CODEX_BIN}"
    return 0
  fi
  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi
  local mac_app_bin="/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  if [[ -x "$mac_app_bin" ]]; then
    printf '%s\n' "$mac_app_bin"
    return 0
  fi
  echo "Error: Codex CLI not found. Put 'codex' in PATH, install ChatGPT Desktop, or set CODEX_BIN." >&2
  return 127
}

STATE_DIR="${CODEX_WHIP_HOME:-$HOME/.codex-whip}"
LEDGER_PATH="${STATE_DIR}/sessions.tsv"

WORKDIR="$(pwd)"
WORKDIR_EXPLICIT=0
SESSION_REF=""
COPY_ONLY=0

usage() {
  cat <<'EOF'
Usage: open_codex.sh [OPTIONS]
  --cd <dir>              Working directory (default: recorded workdir for named session, else current dir)
  --session <uuid|name>   Resume a specific persisted Codex session by UUID or ledger label name
  --copy                  Copy the launch command to clipboard instead of opening Terminal
  -h, --help              Show this help
EOF
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

resolve_session_ref() {
  local ref="$1"
  if is_uuid "$ref"; then
    local rec_dir=""
    if [[ -s "$LEDGER_PATH" ]]; then
      rec_dir="$(awk -F'\t' -v id="$ref" '$2 == id { print $3; exit }' "$LEDGER_PATH" || true)"
    fi
    printf '%s\t%s\n' "$ref" "$rec_dir"
    return 0
  fi

  if [[ -s "$LEDGER_PATH" ]]; then
    local matches
    matches="$(python3 - "$LEDGER_PATH" "$ref" <<'PY'
import sys
ledger_path, query = sys.argv[1], sys.argv[2].strip().lower()
rows = []
with open(ledger_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\r\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) >= 5:
            rows.append(parts)

exact = [r for r in rows if r[4].strip().lower() == query]
chosen = exact if exact else [r for r in rows if query in r[4].strip().lower()]

if len(chosen) == 1:
    print(f"OK\t{chosen[0][1]}\t{chosen[0][2]}")
elif len(chosen) > 1:
    print("AMBIGUOUS")
    for r in chosen:
        print("\t".join(r))
else:
    print("NONE")
PY
)"
    local header
    header="$(printf '%s\n' "$matches" | head -n 1)"
    if [[ "$header" == OK$'\t'* ]]; then
      printf '%s\n' "${header#OK$'\t'}"
      return 0
    elif [[ "$header" == "AMBIGUOUS" ]]; then
      echo "Error: ambiguous session name '${ref}'. Matching sessions in ledger:" >&2
      printf '%s\n' "$matches" | tail -n +2 >&2
      echo "Pass an exact label or UUID." >&2
      return 2
    fi
  fi

  printf '%s\t\n' "$ref"
  return 0
}

copy_to_clipboard() {
  local text="$1"
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$text" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard
  else
    echo "Warning: no clipboard utility (pbcopy/wl-copy/xclip) found." >&2
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd)
      WORKDIR="$2"; WORKDIR_EXPLICIT=1; shift 2 ;;
    --session)
      SESSION_REF="$2"; shift 2 ;;
    --copy)
      COPY_ONLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

CODEX_BIN="$(resolve_codex_bin)"

SESSION_ID=""
if [[ -n "$SESSION_REF" ]]; then
  RESOLVED="$(resolve_session_ref "$SESSION_REF")"
  SESSION_ID="${RESOLVED%%$'\t'*}"
  RECORDED_DIR="${RESOLVED#*$'\t'}"
  if [[ "$WORKDIR_EXPLICIT" -eq 0 && -n "$RECORDED_DIR" && -d "$RECORDED_DIR" ]]; then
    WORKDIR="$RECORDED_DIR"
  fi
fi

QUOTED_DIR="$(printf '%q' "$WORKDIR")"
QUOTED_BIN="$(printf '%q' "$CODEX_BIN")"

if [[ -n "$SESSION_ID" ]]; then
  QUOTED_SESSION="$(printf '%q' "$SESSION_ID")"
  LAUNCH_CMD="cd ${QUOTED_DIR} && ${QUOTED_BIN} resume ${QUOTED_SESSION}"
else
  LAUNCH_CMD="cd ${QUOTED_DIR} && ${QUOTED_BIN}"
fi

if [[ "$COPY_ONLY" -eq 1 ]]; then
  copy_to_clipboard "$LAUNCH_CMD" || true
  echo "mode=clipboard"
  echo "session_id=${SESSION_ID:-new}"
  echo "command=${LAUNCH_CMD}"
  exit 0
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  osascript \
    -e 'on run argv' \
    -e 'tell application "Terminal"' \
    -e 'activate' \
    -e 'do script (item 1 of argv)' \
    -e 'end tell' \
    -e 'end run' \
    "$LAUNCH_CMD" >/dev/null
  echo "mode=terminal"
else
  copy_to_clipboard "$LAUNCH_CMD" || true
  echo "mode=command"
fi

echo "session_id=${SESSION_ID:-new}"
echo "command=${LAUNCH_CMD}"
