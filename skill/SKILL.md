---
name: codex-whip
description: >-
  Tame the local OpenAI Codex CLI (gpt-6.2-sol / gpt-6.2-astra) into a silent,
  schema-locked execution worker. Use when the user asks to delegate coding,
  codebase research, or independent code review to Codex / sol / astra, resume
  a named Codex milestone session, or open a Codex session in a terminal while
  keeping the main conversation clean and verified.
---

# codex-whip — Silent Execution Harness for Codex CLI

Use the local Codex CLI as an **execution worker** while you remain the **planner, verifier, and communicator**. Never dump Codex's verbose raw logs into the main conversation — consume only its structured JSON receipt plus real artifacts (`git diff`, tests, or on-disk reports).

## 1. Locate the Wrapper Scripts

Scripts live inside this skill folder under `scripts/`:
- **macOS / Linux**: `./scripts/run_codex.sh` and `./scripts/open_codex.sh`
  - Typical installed path: `~/.gemini/config/skills/codex-whip/scripts/run_codex.sh` (Antigravity) or `~/.claude/skills/codex-whip/scripts/run_codex.sh` (Claude Code)
- **Windows (PowerShell)**: `./scripts/run_codex.ps1` and `./scripts/open_codex.ps1`

Invoke the fixed script path directly (avoid `$()` or chained shell wrappers so prefix-based command approval works cleanly).

## 2. Model, Effort, Isolation & Timeout

- **Default**: `--model sol --effort high` (`gpt-6.2-sol`, `high`) — routine coding, refactoring, PR/code review, targeted research.
- **Hard tasks**: `--model astra --effort high` (or `xhigh`) (`gpt-6.2-astra`) — complex multi-file debugging, deep root-cause analysis, tricky architecture/algorithms.
- **Sandbox**: defaults to `-s workspace-write` (non-interactive, no approval prompts). Only add `--yolo` when cross-directory writes or network package installs are explicitly needed.
- **Worktree isolation (`--worktree`)**: for large/risky refactors or parallel edits inside a Git repo, pass `--worktree` (implies `--persist`). Codex edits an isolated managed Git worktree; inspect `git -C <codex_workdir> diff` before landing changes, then clean up with `--delete`.
- **Timeout (`--timeout <sec>`)**: defaults to `600` seconds (exits `124` on timeout and kills the process group cleanly). Pass `0` to disable or a higher value for long builds.

## 3. Session Lifecycle, Named Ledger & Cleanup

State is stored outside the repo in `~/.codex-whip/sessions.tsv` (shared automatically across Antigravity and Claude Code):

- **One-off tasks (default ephemeral)**: omit `--persist`. Nothing enters Codex's saved history. Always use ephemeral mode for single lookups and **independent code reviews**.
- **Milestone start (`--persist --label "<short-name>"`)**: always assign a clear, human-readable `--label` (e.g. `auth-refactor-v2`). Surface both the `--label` name and `codex_session_id=<UUID>` once briefly to the user.
- **Same-milestone follow-up (`--resume <uuid|name>`)**: pass either the UUID or the ledger label (never `--last`). Exact label match runs first, then unique substring match (failing with candidates on ambiguity), and recorded `workdir` is auto-restored if `--cd` is omitted.
- **Finding a session by name**: if the user references a prior Codex task by name or topic, run `--list-sessions` if unsure, or pass the name directly to `--resume <name>`, `open_codex.sh --session <name>`, or `--delete <name>`.
- **Milestone close / Reset**: once verified and done (or if Codex loops twice and needs a clean reset), delete the session so Codex history never bloats:
  - Delete one: `run_codex.sh --delete <uuid|name>` (or `--archive <uuid|name>`)
  - Inspect leftovers: `run_codex.sh --list-sessions`
  - Clean all tracked: `run_codex.sh --cleanup-all`

## 4. Prepare a Structured Brief (Never Send Vague One-Liners)

Write the brief to a temporary file (e.g. `/tmp/codex-brief.md` or `$env:TEMP\codex-brief.md`) containing:
1. **Mode**:
   - `READ-ONLY ANALYSIS / REVIEW`: explicitly state *"Do NOT modify, create, or delete any repository files."* (For long analysis, give a temp `.md` report path for detailed `file:line` evidence and cite it in `evidence_refs`.)
   - `IMPLEMENT`: name exact in-scope files/modules and *"Do NOT run `git commit` or `git push`."*
2. **Goal**: concrete deliverable and expected behavior.
3. **Context**: exact file paths, constraints, conventions, and what NOT to touch.
4. **Verification**: exact test/check commands Codex must execute and report in `checks`.
5. **Output rule**: concise, factual, strictly matching `resources/result.schema.json` — zero filler.

## 5. Invoking & Opening Interactively

```bash
# Start a named milestone session (images optional, repeatable)
run_codex.sh \
  --cd /path/to/repo \
  --model sol \
  --effort high \
  --persist \
  --label "feature-x" \
  --image /path/to/screenshot.png \
  --prompt-file /tmp/codex-brief.md

# Resume by name (auto-restores recorded workdir)
run_codex.sh \
  --model sol \
  --effort high \
  --resume "feature-x" \
  --prompt-file /tmp/codex-brief.md

# Open interactively in Terminal (or add --copy for clipboard)
open_codex.sh --session "feature-x"
```

Runtime notes:
- Do not run `--resume` while the user is actively typing inside that same interactive session.
- Live monitoring: users can watch raw Codex logs in a side terminal via `tail -F /tmp/codex-whip-latest.log` (macOS/Linux) or `Get-Content "$env:TEMP\codex-whip-latest.log" -Wait` (Windows).
- Forward any user-attached images directly via repeatable `--image <path>` flags.
- `run_codex.sh` prints `codex_duration_sec` and `codex_tokens` on every run for cost visibility.

## 6. Independent Verification Gate & Capped 2-Round Review

Never relay Codex's claims blindly:
- **After implementation**: inspect `git status` / `git diff` yourself and run or verify tests before reporting success.
- **After research/review**: spot-check cited `file:line` references (or read the on-disk report in `evidence_refs`).
- **Independent Review (hard cap: 2 rounds max)**:
  - Always use a **fresh ephemeral** `sol` (`high`) session on the diff — never resume the coding session.
  - Restrict findings to **Blocker / Major issues only** (logic bugs, wrong data definitions, edge-case crashes, security/data-loss risks). Explicitly forbid style/formatting nitpicks.
  - Fix valid Blocker/Major issues and re-check at most once (**max 2 rounds total**). If disagreements remain after round 2, stop looping and present concise tradeoffs to the user.
- **Speak in your own voice**: translate verified outcomes cleanly for the user — never paste raw Codex chatter.

## 7. Harness Self-Evolution (Human-in-the-Loop)

Evolve this harness deliberately instead of silently bloating rules:
- Record real friction when a run fails due to a harness gap (CLI flag change, repeated worker failure mode, missing gate).
- When the same friction recurs **>= 2 times** (or exposes a concrete bug), prefer hardening scripts/schema/verification gates over adding verbose prompt prose.
- Never silently rewrite `SKILL.md` or scripts — propose a surgical diff to the user, apply only after approval, and re-verify.
- Prune obsolete workarounds once upstream CLI or models no longer need them.
