---
name: install-yai
description: Install and wire up the yai harness in a target repo so an agent can drive a PRD through execute / eval / fix / final-eval loops. Covers vendoring vs cloning, state-dir setup, prerequisites, and the first smoke run.
user-invocable: true
---

# Install yai

Use this skill when the user asks to **set up yai**, **install the yai harness**, or **integrate yai** into the current repo.

## 1. Pick an install mode

There are two ways to consume yai — pick one based on the user's preference:

### A. Reference-by-path (recommended for first-time setup)

Keep yai in a shared location and invoke it via absolute path. Minimal footprint in the target repo.

```sh
# Clone yai to a stable path (once per machine)
git clone https://github.com/rokurokulab/yai.git ~/.local/share/yai

# Then inside the target repo, just invoke:
bash ~/.local/share/yai/scripts/yai.sh [...]
```

Pros: zero repo pollution, easy upgrade (`git pull` in `~/.local/share/yai`), same yai serves many projects.
Cons: user must remember the path; CI runners need the clone too.

### B. Vendored (recommended when the repo will be driven by yai in CI)

Copy `scripts/`, `prompts/`, and `examples/prd.json.example` into the target repo.

```sh
# From inside the target repo
YAI_SRC=${YAI_SRC:-~/.local/share/yai}
mkdir -p scripts/adapters prompts
cp "$YAI_SRC/scripts/yai.sh"                scripts/yai.sh
cp "$YAI_SRC/scripts/adapters/codex.sh"     scripts/adapters/codex.sh
cp "$YAI_SRC/prompts/"*.md                  prompts/
cp "$YAI_SRC/examples/prd.json.example"     .yai/prd.json.example  # if using
```

Pros: self-contained, CI-friendly, pinned version.
Cons: need to re-vendor on upgrade.

**Default to A** unless the user explicitly says "vendor it" or "we need this in CI".

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

## 3. Create the state dir + PRD

yai reads its PRD from `<target>/.yai/prd.json` and optional context from `.yai/prd-source.md`.

```sh
mkdir -p .yai
# Seed prd.json from the example (then edit in stories)
cp "$YAI_SRC/examples/prd.json.example" .yai/prd.json
# Optional but recommended: a markdown PRD snapshot for the final evaluator
cat > .yai/prd-source.md <<'EOF'
# PRD (target)

<one-paragraph goal, key constraints, non-goals>
EOF
```

Ask the user for the actual stories, then replace `prd.json.userStories[]` accordingly. Each story needs: `id`, `title`, `description`, `acceptanceCriteria` (array), `priority` (int), `passes` (false), `notes`.

Add `.yai/` to `.gitignore` **if** the user wants state kept local; keep it committed if they want PRD + progress tracked in git.

## 4. Pick sensible env overrides (only if needed)

Defaults are tuned for real runs (timeout 3600s, 10 execute retries, 5 fix rounds). Override only if:

- `YAI_CODEX_MODEL` — specific model for this project
- `YAI_CODEX_PROFILE` — if the user has a named codex profile
- `YAI_CODEX_SANDBOX` — default is `workspace-write`; use `read-only` for exploration runs
- `YAI_CODEX_APPROVAL` — default is `never` (non-interactive); use `on-request` if user wants prompts

Full list: `bash $YAI_SRC/scripts/yai.sh --help`.

## 5. Smoke run

Run a single story to confirm the wiring:

```sh
# A — reference install
bash ~/.local/share/yai/scripts/yai.sh 1

# B — vendored install
bash scripts/yai.sh 1
```

Expected on success:
- `.yai/runs/<timestamp>/iteration-001.*` artifacts are written
- First story in `prd.json` has `passes: true`
- A commit is created on the current branch with the story's title

If it fails, read `.yai/runs/<timestamp>/iteration-001.status.txt` first for the adapter's failure classification (timeout / transport / terminal) before blaming the prompt.

## 6. Next steps to surface to the user

- **Full run**: drop the `1` arg to process up to `MAX_ITERATIONS` (default 10) stories.
- **Final phase**: once all stories pass, yai auto-enters `final_eval` → `final_fix` loop. No extra command needed.
- **Resuming a dirty run**: `bash scripts/yai.sh --adopt-dirty-worktree <story-id-or-FINAL> --yes`.
- **Inspecting state**: point them at the `inspect-yai` skill.

## Gotchas

- **Worktree must be clean** at start (yai refuses dirty state unless `--adopt-dirty-worktree` is passed with `--yes`). Suggest the user commit or stash before starting.
- **codex approval=never** means a seemingly-stuck run is usually actually waiting on a model response — check `codex` processes and the latest `iteration-*.stderr.log` before killing.
- **.yai/ in git**: if the user commits state, rebases will be noisy. Discuss before gitignoring.
- **MAX_ITERATIONS caps stories per launch**, not fix rounds. Eval retries and fix subrounds don't consume the budget — a single story can trigger 5 fix rounds without counting against the 10-story cap.
- **PRD source snapshot (`.yai/prd-source.md`) is required for final eval** — don't skip it even if the initial PRD fits in `prd.json`'s `description` field.
