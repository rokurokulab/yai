# yai

[![CI](https://github.com/rokurokulab/yai/actions/workflows/ci.yml/badge.svg)](https://github.com/rokurokulab/yai/actions/workflows/ci.yml)
[![Smoke Test](https://github.com/rokurokulab/yai/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/rokurokulab/yai/actions/workflows/smoke-test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/rokurokulab/yai)](https://github.com/rokurokulab/yai/releases)

An agent loop harness that drives an LLM through a PRD, one story at a time, with a semantic evaluator on each round and a whole-PRD final review pass. Tool-agnostic core, swappable adapters — ships with a codex adapter.

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

Requires `bash ≥ 4`, `git`, `jq`, `shasum` (or `sha256sum`), plus the [codex CLI](https://github.com/openai/codex).

```sh
# 1. Drop yai into your repo (or clone alongside and reference via absolute path)
git clone https://github.com/rokurokulab/yai.git /path/to/yai

# 2. Inside your target repo, create PRD
mkdir -p .yai
cp /path/to/yai/examples/prd.json.example .yai/prd.json
echo "# PRD source notes (any context the evaluator should see)" >.yai/prd-source.md
# edit .yai/prd.json — fill in your user stories

# 3. Run
bash /path/to/yai/scripts/yai.sh
```

Or cap the launch at N story iterations:

```sh
bash /path/to/yai/scripts/yai.sh 5
```

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

Full list in `scripts/yai.sh --help`. Most-used:

| Variable | Default | What it does |
|---|---|---|
| `YAI_STATE_DIR` | `<repo>/.yai` | State dir (prd.json, runs/, archive/) |
| `YAI_CODEX_BIN` | `codex` | codex executable path |
| `YAI_CODEX_MODEL` | adapter default | override codex model |
| `YAI_CODEX_SANDBOX` | `workspace-write` | sandbox mode for execute phase |
| `YAI_CODEX_APPROVAL` | `never` | approval mode |
| `YAI_CODEX_TIMEOUT_SECONDS` | `1800` | per-attempt timeout |
| `YAI_CODEX_MAX_RETRIES` | `5` | runner-level retries (transport failures) |
| `YAI_SEMANTIC_MAX_FIX_ROUNDS` | `3` | story-level fix rounds after soft_fail |
| `YAI_FINAL_FIX_MAX_ROUNDS` | `3` | final-phase fix rounds after soft_fail |
| `YAI_EVAL_*` | inherits from `YAI_CODEX_*` | separate tuning for the evaluator |
| `YAI_FINAL_EVAL_*` | inherits from `YAI_EVAL_*` | separate tuning for the final evaluator |

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
├── yai.sh              # tool-agnostic core: state machine, prompt rendering,
│                       # artifact validation, retries, worktree ops
└── adapters/
    └── codex.sh        # codex-specific adapter: codex exec invocation,
                        # retry/timeout, transport-failure classification
```

The adapter contract is simple: `adapter --purpose <execute|eval|final-eval> [...]` invokes the underlying tool and writes a single JSON artifact. Future adapters (e.g., claude code) implement the same contract; the core doesn't change.

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
- **Sandbox / approval config** — codex `workspace-write` / `read-only` per purpose
- **Checkpoint / resume** — `.yai/active-story.json` + `--adopt-dirty-worktree` for recovering interrupted runs
- **Artifact validation** — every phase emits a typed JSON artifact; yai validates shape before proceeding

## License

Apache-2.0 — see [LICENSE](LICENSE).
