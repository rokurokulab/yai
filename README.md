# yai

[![CI](https://github.com/rokurokulab/yai/actions/workflows/ci.yml/badge.svg)](https://github.com/rokurokulab/yai/actions/workflows/ci.yml)
[![Smoke Test](https://github.com/rokurokulab/yai/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/rokurokulab/yai/actions/workflows/smoke-test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/rokurokulab/yai)](https://github.com/rokurokulab/yai/releases)

An agent loop harness that drives an LLM through a PRD, one story at a time, with a semantic evaluator on each round and a whole-PRD final review pass. Tool-agnostic core, swappable adapters — ships with codex and claude-code adapters.

## What yai does

Given a `prd.json` with a list of user stories, yai:

1. Picks the next pending story.
2. Calls the tool adapter to **execute** the story (code + mechanical checks + artifact JSON).
3. Calls the adapter to **evaluate** the result semantically (`pass` / `soft_fail` / `hard_fail` / `infra_fail`).
4. On `soft_fail`, loops into **fix** rounds (bounded, default 3).
5. On `pass`, commits the story and moves to the next.
6. After all stories pass, runs a **final eval** over the whole PRD. On soft-fail, loops into **final fix** rounds.
7. Archives state, exits.

State lives in `.yai/` (prd.json, progress log, completed-stories ledger, per-run artifacts, archives). Resumable via `--adopt-dirty-worktree` for interrupted runs.

## Quickstart

Requires `bash ≥ 4`, `git`, `jq`, `shasum` (or `sha256sum`), plus one of the supported CLIs:

- [codex CLI](https://github.com/openai/codex) for `--tool codex` (default)
- [claude-code CLI](https://docs.claude.com/claude-code) for `--tool claude-code`

```sh
# 1. Drop yai into your repo (or clone alongside and reference via absolute path)
git clone https://github.com/rokurokulab/yai.git /path/to/yai

# 2. Inside your target repo, create PRD
mkdir -p .yai
cp /path/to/yai/examples/prd.json.example .yai/prd.json
echo "# PRD source notes (any context the evaluator should see)" >.yai/prd-source.md
# edit .yai/prd.json — fill in your user stories

# 3. Run (codex is the default)
bash /path/to/yai/scripts/yai.sh

# or drive with claude-code
bash /path/to/yai/scripts/yai.sh --tool claude-code
```

Or cap the launch at N story iterations:

```sh
bash /path/to/yai/scripts/yai.sh 5
bash /path/to/yai/scripts/yai.sh --tool claude-code 5
```

### Auth notes for `--tool claude-code`

- By default the adapter uses your interactive `claude` login (OAuth / keychain).
- For isolated / CI-style runs without OAuth, set `YAI_CC_ARGS="--bare"` and provide `ANTHROPIC_API_KEY`. `--bare` makes `claude` ignore OAuth and keychain, so without an API key it will fail with "Not logged in".

## Loop phases

```
┌────────────────────────────────────────────────────────────────┐
│                    outer story loop (N stories)                │
│                                                                │
│   ┌──────────┐    ┌───────┐    ┌───────┐    mark as passed     │
│   │ execute  │ ─▶ │ eval  │ ─▶ │ pass? │ ─▶ commit + next      │
│   └──────────┘    └───┬───┘    └───────┘                       │
│                       │                                        │
│                       │ soft_fail                              │
│                       ▼                                        │
│                   ┌───────┐    (bounded rounds)                │
│                   │  fix  │ ─▶ back to eval                    │
│                   └───────┘                                    │
└────────────────────────────────────────────────────────────────┘
         │
         ▼  (all stories pass)
┌────────────────────────────────────────────────────────────────┐
│                        final phase                             │
│                                                                │
│   ┌────────────┐    ┌───────┐                                  │
│   │ final_eval │ ─▶ │ pass? │ ─▶ commit dirty + exit 0         │
│   └────────────┘    └───┬───┘                                  │
│                         │                                      │
│                         │ soft_fail (fixable)                  │
│                         ▼                                      │
│                    ┌──────────┐   (bounded rounds)             │
│                    │ final_fix│ ─▶ back to final_eval          │
│                    └──────────┘                                │
└────────────────────────────────────────────────────────────────┘
```

## Key environment variables

Full list in `scripts/yai.sh --help` and per-adapter help (`scripts/adapters/<tool>.sh --help`). Most-used:

Shared:

| Variable | Default | What it does |
|---|---|---|
| `YAI_STATE_DIR` | `<repo>/.yai` | State dir (prd.json, runs/, archive/) |
| `YAI_SEMANTIC_MAX_FIX_ROUNDS` | `5` | story-level fix rounds after soft_fail |
| `YAI_FINAL_FIX_MAX_ROUNDS` | `5` | final-phase fix rounds after soft_fail |

Codex adapter (`--tool codex`, default):

| Variable | Default | What it does |
|---|---|---|
| `YAI_CODEX_BIN` | `codex` | codex executable path |
| `YAI_CODEX_MODEL` | adapter default | override codex model |
| `YAI_CODEX_SANDBOX` | `workspace-write` | sandbox mode for execute phase |
| `YAI_CODEX_APPROVAL` | `never` | approval mode |
| `YAI_CODEX_TIMEOUT_SECONDS` | `3600` | per-attempt timeout |
| `YAI_CODEX_MAX_RETRIES` | `10` | runner-level retries (transport failures) |
| `YAI_EVAL_*` | inherits from `YAI_CODEX_*` | separate tuning for the evaluator |
| `YAI_FINAL_EVAL_*` | inherits from `YAI_EVAL_*` | separate tuning for the final evaluator |

claude-code adapter (`--tool claude-code`):

| Variable | Default | What it does |
|---|---|---|
| `YAI_CC_BIN` | `claude` | claude-code executable path |
| `YAI_CC_MODEL` | CLI default | override claude model (alias `sonnet` / `opus` or full id) |
| `YAI_CC_PERMISSION_MODE` | `dontAsk` | claude permission mode |
| `YAI_CC_ALLOWED_TOOLS` | `Bash,Read,Edit,Write,Glob,Grep` | allowed tools for execute phase |
| `YAI_CC_ARGS` | (empty) | extra shell-split args (e.g. `--bare` for strict CI isolation with API key) |
| `YAI_CC_TIMEOUT_SECONDS` | `3600` | per-attempt timeout |
| `YAI_CC_MAX_RETRIES` | `10` | runner-level retries (transport failures) |
| `YAI_CC_EVAL_*` | inherits from `YAI_CC_*` | separate tuning for the evaluator (defaults to read-only tool set) |
| `YAI_CC_FINAL_EVAL_*` | inherits from `YAI_CC_EVAL_*` | separate tuning for the final evaluator |

## Prompts

Tool-agnostic prompts live in `prompts/`:

- `EXECUTE.md` — story-level execution instructions + artifact JSON contract
- `EVAL.md` — story-level semantic evaluator + eval artifact JSON contract
- `FINAL_EVAL.md` — run-level PRD reviewer (scope drift, cross-story conflict, etc.)
- `FINAL_FIX.md` — bounded corrective fix (addresses specific final-eval findings only)

## Architecture

Internal day-1 core/adapter split:

```
scripts/
├── yai.sh                    # tool-agnostic core: state machine, prompt rendering,
│                             # artifact validation, retries, worktree ops
└── adapters/
    ├── codex.sh              # codex CLI adapter: codex exec invocation
    └── claude-code.sh        # claude-code CLI adapter: claude -p stream-json
```

Adapter contract: `adapter --purpose <execute|eval|final-eval> --repo-root <path> --prompt-file <path> --run-dir <path> --iteration <label>`. The adapter invokes the underlying tool and writes:

- `<run-dir>/<iteration>.last-message.txt` — final assistant message (consumed by yai as the JSON artifact)
- `<run-dir>/<iteration>.events.jsonl` — streamed events (observability)
- `<run-dir>/<iteration>.stderr.log` — stderr (observability)
- `<run-dir>/<iteration>.status.txt` — runner state / classification

New adapters implement the same contract; the core doesn't change.

## Testing

All 11 scenarios use a mock codex (embedded in `test/semantic-eval.sh`). No real tool calls, no network, no token cost:

```sh
# full suite (~60–120s)
bash test/semantic-eval.sh

# single scenario
bash test/semantic-eval.sh pass
bash test/semantic-eval.sh soft_fix
bash test/semantic-eval.sh final_fix
```

Scenarios cover: basic pass, no-op pass, soft-fail-then-fix, eval infra retry, dirty worktree adoption, mechanical failure, final fix, final hard-fail, final infra retry, dirty final pass, missing prd-source.

## Attribution

yai is inspired by [@snarktank/ralph](https://github.com/snarktank/ralph) — the same core idea (agent loop driven by a PRD) plus:

- **Semantic eval-fix loop** — every story round has an evaluator pass; `soft_fail` triggers bounded fix rounds
- **Final eval + final fix** — whole-PRD review after all stories pass, with bounded corrective rounds for aggregate drift
- **Retry / timeout policy** — per-purpose (execute / eval / final-eval) env-configurable, transport-failure classification
- **Sandbox / approval config** — per-adapter, per-purpose (codex `workspace-write` / `read-only`; claude-code `permission-mode` + allowed-tool list)
- **Checkpoint / resume** — `.yai/active-story.json` + `--adopt-dirty-worktree` for recovering interrupted runs
- **Artifact validation** — every phase emits a typed JSON artifact; yai validates shape before proceeding

## License

Apache-2.0 — see [LICENSE](LICENSE).
