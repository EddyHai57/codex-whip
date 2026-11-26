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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_PATH="${SCRIPT_DIR}/../resources/result.schema.json"
STATE_DIR="${CODEX_WHIP_HOME:-$HOME/.codex-whip}"
LEDGER_PATH="${STATE_DIR}/sessions.tsv"
LEDGER_LOCK="${STATE_DIR}/.sessions.lock"
LATEST_LOG_LINK="/tmp/codex-whip-latest.log"

WORKDIR="$(pwd)"
WORKDIR_EXPLICIT=0
MODEL="${CODEX_WHIP_DEFAULT_MODEL:-gpt-6.2-sol}"
EFFORT="${CODEX_WHIP_DEFAULT_EFFORT:-high}"
TIMEOUT_SEC="${CODEX_WHIP_TIMEOUT:-570}"
YOLO=0
WORKTREE=0
PERSIST=0
RESUME_REF=""
DELETE_REF=""
ARCHIVE_REF=""
LIST_SESSIONS=0
CLEANUP_ALL=0
LABEL="-"
PROMPT=""
PROMPT_FILE=""
OUT_FILE=""
IMAGES=()

usage() {
  cat <<'EOF'
Usage: run_codex.sh [OPTIONS]
  --cd <dir>                Working directory for Codex (default: current dir; auto-restored on named resume)
  --model <name>            sol | astra | exact model id (default: gpt-6.2-sol)
  --effort <level>          low | medium | high | xhigh (default: high)
  --timeout <sec>           Kill run after N seconds, exit 124 (default: 570, under Claude Code's 600 s Bash cap; 0 = no limit)
  --prompt <text>           Inline prompt text
  --prompt-file <path>      Read prompt from file (preferred for structured briefs)
  --image <path>            Attach an image file (repeatable)
  --out <path>              Write final JSON message to this path
  --persist                 Persist session so it can be resumed within the same milestone
  --label <name>            Human-readable name recorded in sessions.tsv for persisted sessions
  --resume <uuid|name>      Resume an existing persisted session by UUID or ledger label (exact, then unique substring)
  --delete <uuid|name>      Permanently delete a saved Codex session by UUID or exact ledger label
  --archive <uuid|name>     Archive a saved Codex session by UUID or exact ledger label
  --list-sessions           List active persisted sessions tracked in sessions.tsv
  --cleanup-all             Delete all persisted sessions tracked in sessions.tsv
  --worktree                Run in an isolated managed Git worktree (implies --persist)
  --yolo                    Use --dangerously-bypass-approvals-and-sandbox instead of workspace-write
  -h, --help                Show this help

Environment variables:
  CODEX_BIN                 Explicit path to codex executable
  CODEX_WHIP_HOME           Directory for sessions.tsv ledger (default: ~/.codex-whip)
  CODEX_WHIP_DEFAULT_MODEL  Default model id (default: gpt-6.2-sol)
  CODEX_WHIP_DEFAULT_EFFORT Default reasoning effort (default: high)
  CODEX_WHIP_TIMEOUT        Default timeout in seconds (default: 570)
EOF
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

resolve_session_ref() {
  local ref="$1"
  local require_uuid="${2:-0}"
  local exact_only="${3:-0}"

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
    matches="$(python3 - "$LEDGER_PATH" "$ref" "$exact_only" <<'PY'
import sys
ledger_path, query, exact_only = sys.argv[1], sys.argv[2].strip().lower(), sys.argv[3] == "1"
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
chosen = exact if (exact or exact_only) else [r for r in rows if query in r[4].strip().lower()]

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

  if [[ "$require_uuid" -eq 1 ]]; then
    echo "Error: no UUID or exact label '${ref}' in ${LEDGER_PATH}; delete accepts only a UUID or an exact label." >&2
    return 2
  fi

  printf '%s\t\n' "$ref"
  return 0
}

# Several Claude Code / Antigravity sessions may share one ledger, so writes take a
# mkdir lock (atomic on every POSIX filesystem; macOS ships no flock).
ledger_lock() {
  mkdir -p "$STATE_DIR"
  local i=0
  until mkdir "$LEDGER_LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -ge 100 ]]; then
      echo "Error: ledger lock busy for 10s: ${LEDGER_LOCK} (remove it if no codex-whip run is active)." >&2
      return 1
    fi
    sleep 0.1
  done
}

ledger_unlock() {
  rmdir "$LEDGER_LOCK" 2>/dev/null || true
}

ledger_remove_unlocked() {
  local target_id="$1"
  [[ -f "$LEDGER_PATH" ]] || return 0
  local tmp_file
  tmp_file="$(mktemp "${STATE_DIR}/.sessions.XXXXXX")"
  awk -F'\t' -v id="$target_id" '$2 != id' "$LEDGER_PATH" > "$tmp_file" || true
  mv "$tmp_file" "$LEDGER_PATH"
}

ledger_remove() {
  ledger_lock || return 1
  ledger_remove_unlocked "$1" || { ledger_unlock; return 1; }
  ledger_unlock
}

ledger_add() {
  local sid="$1"
  local wdir="$2"
  local mode="$3"
  local note="$4"
  [[ -n "$sid" ]] || return 0
  note="$(printf '%s' "$note" | tr '\t\r\n' '   ')"
  ledger_lock || return 1
  ledger_remove_unlocked "$sid" || { ledger_unlock; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$sid" "$wdir" "$mode" "$note" >> "$LEDGER_PATH" || { ledger_unlock; return 1; }
  ledger_unlock
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd)
      WORKDIR="$2"; WORKDIR_EXPLICIT=1; shift 2 ;;
    --model)
      case "$2" in
        sol) MODEL="gpt-6.2-sol" ;;
        astra) MODEL="gpt-6.2-astra" ;;
        *) MODEL="$2" ;;
      esac
      shift 2 ;;
    --effort)
      EFFORT="$2"; shift 2 ;;
    --timeout)
      TIMEOUT_SEC="$2"; shift 2 ;;
    --prompt)
      PROMPT="$2"; shift 2 ;;
    --prompt-file)
      PROMPT_FILE="$2"; shift 2 ;;
    --image)
      IMAGES+=("$2"); shift 2 ;;
    --out)
      OUT_FILE="$2"; shift 2 ;;
    --persist)
      PERSIST=1; shift ;;
    --label)
      LABEL="$2"; shift 2 ;;
    --resume)
      RESUME_REF="$2"; shift 2 ;;
    --delete)
      DELETE_REF="$2"; shift 2 ;;
    --archive)
      ARCHIVE_REF="$2"; shift 2 ;;
    --list-sessions)
      LIST_SESSIONS=1; shift ;;
    --cleanup-all)
      CLEANUP_ALL=1; shift ;;
    --worktree)
      WORKTREE=1; PERSIST=1; shift ;;
    --yolo)
      YOLO=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ "$LIST_SESSIONS" -eq 1 ]]; then
  if [[ ! -s "$LEDGER_PATH" ]]; then
    echo "(no active tracked sessions)"
    exit 0
  fi
  printf 'TIMESTAMP\tSESSION_ID\tWORKDIR\tMODE\tLABEL\n'
  cat "$LEDGER_PATH"
  exit 0
fi

CODEX_BIN="$(resolve_codex_bin)"

if [[ "$CLEANUP_ALL" -eq 1 ]]; then
  if [[ ! -s "$LEDGER_PATH" ]]; then
    echo "No active tracked sessions to clean up."
    exit 0
  fi
  FAILED=0
  DELETED=0
  while IFS=$'\t' read -r _ts sid _wdir _mode _note; do
    [[ -n "$sid" ]] || continue
    if "$CODEX_BIN" delete --force "$sid"; then
      ledger_remove "$sid"
      DELETED=$((DELETED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  done < <(cat "$LEDGER_PATH")
  echo "cleanup_deleted=${DELETED} cleanup_failed=${FAILED}"
  [[ "$FAILED" -eq 0 ]]
  exit $?
fi

if [[ -n "$DELETE_REF" ]]; then
  RESOLVED="$(resolve_session_ref "$DELETE_REF" 1 1)"
  DELETE_ID="${RESOLVED%%$'\t'*}"
  "$CODEX_BIN" delete --force "$DELETE_ID"
  ledger_remove "$DELETE_ID"
  exit 0
fi

if [[ -n "$ARCHIVE_REF" ]]; then
  RESOLVED="$(resolve_session_ref "$ARCHIVE_REF" 0 1)"
  ARCHIVE_ID="${RESOLVED%%$'\t'*}"
  "$CODEX_BIN" archive "$ARCHIVE_ID"
  ledger_remove "$ARCHIVE_ID"
  exit 0
fi

if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
  echo "Error: --timeout must be a non-negative integer (seconds)." >&2
  exit 2
fi

if [[ -n "$PROMPT_FILE" && -n "$PROMPT" ]]; then
  echo "Error: specify either --prompt or --prompt-file, not both." >&2
  exit 2
fi

if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 2
  fi
  PROMPT="$(cat "$PROMPT_FILE")"
fi

if [[ -z "$PROMPT" ]]; then
  echo "Error: empty prompt. Pass --prompt or --prompt-file." >&2
  exit 2
fi

for img in "${IMAGES[@]+"${IMAGES[@]}"}"; do
  if [[ ! -f "$img" ]]; then
    echo "Error: image file not found: $img" >&2
    exit 2
  fi
done

RESUME_ID=""
if [[ -n "$RESUME_REF" ]]; then
  RESOLVED="$(resolve_session_ref "$RESUME_REF" 0)"
  RESUME_ID="${RESOLVED%%$'\t'*}"
  RECORDED_DIR="${RESOLVED#*$'\t'}"
  if [[ "$WORKDIR_EXPLICIT" -eq 0 && -n "$RECORDED_DIR" && -d "$RECORDED_DIR" ]]; then
    WORKDIR="$RECORDED_DIR"
  fi
  if [[ "$WORKTREE" -eq 1 ]]; then
    # `codex exec resume --worktree` would create a NEW worktree; reuse the recorded workdir instead.
    echo "Warning: --worktree is ignored with --resume; the recorded workdir is reused." >&2
    WORKTREE=0
  fi
fi

RUN_DIR="$(mktemp -d /tmp/codex-whip.XXXXXX)"
LOG_FILE="${RUN_DIR}/raw.log"
touch "$LOG_FILE"
# Shared convenience link for `tail -F`; concurrent runs race on it, so never let it abort a run.
ln -sfn "$LOG_FILE" "$LATEST_LOG_LINK" 2>/dev/null || true

if [[ -z "$OUT_FILE" ]]; then
  OUT_FILE="${RUN_DIR}/result.json"
fi

if [[ -n "$RESUME_ID" ]]; then
  CMD=(
    "$CODEX_BIN" exec resume
    --skip-git-repo-check
    -m "$MODEL"
    -c "model_reasoning_effort=\"${EFFORT}\""
    --output-schema "$SCHEMA_PATH"
    -o "$OUT_FILE"
  )
  for img in "${IMAGES[@]+"${IMAGES[@]}"}"; do
    CMD+=(-i "$img")
  done
  if [[ "$YOLO" -eq 1 ]]; then
    CMD+=(--dangerously-bypass-approvals-and-sandbox)
  else
    # `codex exec resume` has no -s flag; pin the sandbox via config so it matches the original run.
    CMD+=(-c 'sandbox_mode="workspace-write"')
  fi
  CMD+=("$RESUME_ID" "$PROMPT")
else
  CMD=(
    "$CODEX_BIN" exec
    --skip-git-repo-check
    --color never
    -m "$MODEL"
    -c "model_reasoning_effort=\"${EFFORT}\""
    --cd "$WORKDIR"
    --output-schema "$SCHEMA_PATH"
    -o "$OUT_FILE"
  )
  for img in "${IMAGES[@]+"${IMAGES[@]}"}"; do
    CMD+=(-i "$img")
  done
  if [[ "$WORKTREE" -eq 1 ]]; then
    CMD+=(--worktree)
  fi
  if [[ "$PERSIST" -eq 0 ]]; then
    CMD+=(--ephemeral)
  fi
  if [[ "$YOLO" -eq 1 ]]; then
    CMD+=(--dangerously-bypass-approvals-and-sandbox)
  else
    CMD+=(-s workspace-write)
  fi
  CMD+=(-- "$PROMPT")
fi

START_TS="$(date +%s)"
set +e
python3 - "$WORKDIR" "$LOG_FILE" "$TIMEOUT_SEC" "${CMD[@]}" <<'PY'
import os, signal, subprocess, sys

workdir = sys.argv[1]
log_path = sys.argv[2]
timeout_sec = int(sys.argv[3])
cmd = sys.argv[4:]

with open(log_path, "wb") as log_f:
    proc = subprocess.Popen(
        cmd,
        cwd=workdir,
        stdin=subprocess.DEVNULL,
        stdout=log_f,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        rc = proc.wait(timeout=None if timeout_sec == 0 else timeout_sec)
        sys.exit(rc)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=3)
        except Exception:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                pass
        log_f.write(f"\n[codex-whip] TIMEOUT after {timeout_sec}s; process group terminated.\n".encode())
        sys.exit(124)
PY
RC=$?
set -e
END_TS="$(date +%s)"
DURATION_SEC=$((END_TS - START_TS))

SESSION_ID="$(grep -m1 '^session id:' "$LOG_FILE" | awk '{print $3}' || true)"
if [[ -z "$SESSION_ID" && -n "$RESUME_ID" ]]; then
  SESSION_ID="$RESUME_ID"
fi
CODEX_WORKDIR="$(grep -m1 '^workdir:' "$LOG_FILE" | sed 's/^workdir:[[:space:]]*//' | tr -d '\r' || true)"
TOKENS_USED="$(awk '/^tokens used$/{if (getline > 0) { gsub(/^[ \t\r]+|[ \t\r]+$/, ""); print; exit }}' "$LOG_FILE" || true)"

if [[ "$PERSIST" -eq 1 && -z "$RESUME_ID" && -z "$SESSION_ID" ]]; then
  echo "Warning: no 'session id:' line in ${LOG_FILE}; this session was NOT recorded in the ledger." >&2
fi
if [[ "$PERSIST" -eq 1 && -z "$RESUME_ID" && -n "$SESSION_ID" ]]; then
  LEDGER_MODE="persist"
  [[ "$WORKTREE" -eq 1 ]] && LEDGER_MODE="worktree"
  ledger_add "$SESSION_ID" "${CODEX_WORKDIR:-$WORKDIR}" "$LEDGER_MODE" "$LABEL"
fi

echo "codex_exit_code=${RC}"
echo "codex_model=${MODEL} (effort=${EFFORT})"
echo "codex_duration_sec=${DURATION_SEC}"
echo "codex_tokens=${TOKENS_USED:-unknown}"
if [[ "$RC" -eq 124 ]]; then
  echo "codex_timeout_sec=${TIMEOUT_SEC}"
fi
if [[ "$WORKTREE" -eq 1 ]]; then
  echo "codex_worktree=enabled"
  echo "codex_workdir=${CODEX_WORKDIR:-unknown}"
fi
if [[ -n "$RESUME_ID" ]]; then
  echo "codex_session_mode=resumed"
elif [[ "$PERSIST" -eq 1 ]]; then
  echo "codex_session_mode=persisted"
else
  echo "codex_session_mode=ephemeral"
fi
echo "codex_session_id=${SESSION_ID}"
if [[ "$PERSIST" -eq 1 && -z "$RESUME_ID" && "$LABEL" != "-" ]]; then
  echo "codex_label=${LABEL}"
fi
echo "codex_log=${LOG_FILE}"
echo "codex_result=${OUT_FILE}"
echo "--- RESULT ---"

if [[ -s "$OUT_FILE" ]]; then
  cat "$OUT_FILE"
  echo ""
else
  echo "(no structured result produced; tail of raw log follows)"
  tail -n 40 "$LOG_FILE"
fi

exit "$RC"
