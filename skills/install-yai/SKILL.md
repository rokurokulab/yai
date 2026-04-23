---
name: install-yai
description: Install and wire up the yai harness in a target repo so an agent can drive a PRD through execute / eval / fix / final-eval loops. Covers the installer command, prerequisites, state-dir seeding, and the first smoke run.
user-invocable: true
---

# Install yai

Use this skill when the user asks to **set up yai**, **install the yai harness**, or **integrate yai** into the current repo.

## 1. Run the installer

From the root of the target repo, run:

```sh
curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/install.sh | bash
```

This vendors `.yai/bin/` (the core `yai.sh` + adapters) and `.yai/prompts/` (shared prompt templates) into the current repo at a pinned release. It does not create `.yai/prd.json` — that is a per-project file you seed yourself (see §3).

### Installer flags

| Flag | Effect |
|---|---|
| `--version vX.Y.Z` | Install a specific tagged release. Release assets are SHA256-verified. Recommended for normal use. |
| `--branch <name>` | Install from the tip of a branch. Skips SHA256 verification and prints a warning. |
| `--commit <sha>` | Install from a specific commit SHA. Skips SHA256 verification and prints a warning. |
| `--uninstall` | Remove `.yai/bin/` and `.yai/prompts/` from the current repo. Leaves runtime state (`.yai/runs/`, `.yai/prd.json`, etc.) alone. |
| `--help` | Print usage. |

Prefer tag mode (`--version` or the default latest tag) for normal work. Branch and commit modes are for bisecting or pre-release testing.

## 2. Prerequisites

Verify the target machine has:

```sh
command -v bash    # >= 4
command -v git
command -v jq
command -v shasum || command -v sha256sum
command -v codex   # the Codex CLI
```

If `codex` is missing, stop and tell the user to install it first — https://github.com/openai/codex. yai without a codex binary (or `YAI_CODEX_BIN` override) won't run.

## 3. Seed the PRD

yai reads its PRD from `<target>/.yai/prd.json` and optional context from `.yai/prd-source.md`. The installer does not create either.

Fetch the example PRD shape from the release and copy it into place:

```sh
mkdir -p .yai
curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/examples/prd.json.example >.yai/prd.json
# Optional but recommended: a markdown PRD snapshot for the final evaluator
cat > .yai/prd-source.md <<'EOF'
# PRD (target)

<one-paragraph goal, key constraints, non-goals>
EOF
```

Ask the user for the actual stories, then replace `prd.json.userStories[]` accordingly. Each story needs: `id`, `title`, `description`, `acceptanceCriteria` (array), `priority` (int), `passes` (false), `notes`.

Decide with the user whether to commit `.yai/prd.json` (and `prd-source.md`) alongside `.yai/bin/` + `.yai/prompts/`, or to keep PRD state local and gitignore it. Runtime artifacts under `.yai/runs/`, `.yai/archive/`, `.yai/active-story.json`, `.yai/progress.txt`, `.yai/completed-stories.json`, `.yai/.last-branch`, `.yai/.last-run`, `.yai/.last-archive-key` are always gitignored by the repo template.

## 4. Pick sensible env overrides (only if needed)

Defaults are tuned for real runs (timeout 3600s, 10 execute retries, 5 fix rounds). Override only if:

- `YAI_CODEX_MODEL` — specific model for this project
- `YAI_CODEX_PROFILE` — if the user has a named codex profile
- `YAI_CODEX_SANDBOX` — default is `workspace-write`; use `read-only` for exploration runs
- `YAI_CODEX_APPROVAL` — default is `never` (non-interactive); use `on-request` if user wants prompts

Full list: `bash .yai/bin/yai.sh --help`.

## 5. Smoke run

Run a single story to confirm the wiring:

```sh
bash .yai/bin/yai.sh 1
```

Expected on success:
- `.yai/runs/<timestamp>/iteration-001.*` artifacts are written
- First story in `prd.json` has `passes: true`
- A commit is created on the current branch with the story's title

If it fails, read `.yai/runs/<timestamp>/iteration-001.status.txt` first for the adapter's failure classification (timeout / transport / terminal) before blaming the prompt.

## 6. Next steps to surface to the user

- **Full run**: drop the `1` arg to process up to `MAX_ITERATIONS` (default 10) stories.
- **Final phase**: once all stories pass, yai auto-enters `final_eval` → `final_fix` loop. No extra command needed.
- **Resuming a dirty run**: `bash .yai/bin/yai.sh --adopt-dirty-worktree <story-id-or-FINAL> --yes`.
- **Inspecting state**: point them at the `inspect-yai` skill.

## Gotchas

- **Worktree must be clean** at start (yai refuses dirty state unless `--adopt-dirty-worktree` is passed with `--yes`). Suggest the user commit or stash before starting.
- **codex approval=never** means a seemingly-stuck run is usually actually waiting on a model response — check `codex` processes and the latest `iteration-*.stderr.log` before killing.
- **.yai/bin/ + .yai/prompts/ in git**: treat these as vendored code. Commit them so CI and teammates get the same pinned version. Upgrade by re-running the installer with a new `--version`.
- **MAX_ITERATIONS caps stories per launch**, not fix rounds. Eval retries and fix subrounds don't consume the budget — a single story can trigger 5 fix rounds without counting against the 10-story cap.
- **PRD source snapshot (`.yai/prd-source.md`) is required for final eval** — don't skip it even if the initial PRD fits in `prd.json`'s `description` field.
