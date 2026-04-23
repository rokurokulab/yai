# yai

[![CI](https://github.com/rokurokulab/yai/actions/workflows/ci.yml/badge.svg)](https://github.com/rokurokulab/yai/actions/workflows/ci.yml)
[![Smoke Test](https://github.com/rokurokulab/yai/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/rokurokulab/yai/actions/workflows/smoke-test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/rokurokulab/yai)](https://github.com/rokurokulab/yai/releases)

> An agent loop that turns a PRD into verified, committed work — one user story at a time.

yai calls an LLM (codex or claude-code) to execute each user story, runs a semantic evaluator over the result, commits on pass, and loops into bounded fix rounds on soft-fail. A whole-PRD review catches aggregate drift before the run ends. The core is tool-agnostic; new LLM CLIs plug in as adapters.

## Contents

- [Features](#features)
- [Install](#install)
- [Quickstart](#quickstart)
- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Adapters](#adapters)
- [Prompts](#prompts)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Inspired by](#inspired-by)
- [License](#license)

## Features

- **PRD-driven.** A single `.yai/prd.json` describes every user story for a run.
- **Semantic evaluator.** Each story round is judged `pass` / `soft_fail` / `hard_fail` / `infra_fail`; only `pass` commits.
- **Bounded fix loop.** `soft_fail` triggers up to N automated fix rounds before the harness stops.
- **Whole-PRD final review.** After every story passes, a scope-drift check catches aggregate regressions.
- **Tool-agnostic core.** Adapters for codex and claude-code; a contract for adding new CLIs.
- **Resumable.** `.yai/active-story.json` plus `--adopt-dirty-worktree` recover an interrupted run.
- **Artifact-first.** Every phase emits a validated JSON artifact; the human-readable log is advisory.

## Install

Requires `bash ≥ 4`, `git`, `jq`, `shasum` (or `sha256sum`), and one of [codex](https://github.com/openai/codex) or [claude-code](https://docs.claude.com/claude-code).

From the root of your target repo:

```sh
curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/install.sh | bash
```

The installer vendors `.yai/bin/` and `.yai/prompts/` into the current directory.

| Flag | Behaviour |
|---|---|
| _(default)_ | Install the latest release, verified against `SHA256SUMS.txt` |
| `--version vX.Y.Z` | Pin to a release tag (recommended for reproducibility) |
| `--branch <name>` | Install a branch tip; unverified, prints the resolved commit sha |
| `--commit <sha>` | Install a specific commit; unverified |
| `--uninstall` | Remove `.yai/bin/` and `.yai/prompts/`; state is preserved |
| `--help` | Usage |

## Quickstart

### 1. Install

See [Install](#install) above.

### 2. Seed the PRD

The installer does not create `prd.json`. Copy the example and edit:

```sh
mkdir -p .yai
curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/examples/prd.json.example >.yai/prd.json
echo "# PRD source notes (context for the evaluator)" >.yai/prd-source.md
$EDITOR .yai/prd.json
```

A minimal `prd.json` looks like:

```json
{
  "project": "my-project",
  "branchName": "yai/initial-features",
  "description": "Short description of the run",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add hello.sh helper",
      "description": "As a developer, I want a hello.sh script that prints 'hello world'.",
      "acceptanceCriteria": [
        "File hello.sh exists at repo root",
        "Running ./hello.sh prints 'hello world'"
      ],
      "priority": 1,
      "passes": false
    }
  ]
}
```

### 3. Run

```sh
bash .yai/bin/yai.sh                     # codex (default)
bash .yai/bin/yai.sh --tool claude-code  # claude-code
bash .yai/bin/yai.sh 5                   # cap at 5 story iterations
```

## How it works

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

State lives under `.yai/` (PRD, progress log, completed-stories ledger, per-run artifacts, archives). An interrupted run resumes via `--adopt-dirty-worktree <story-id>`.

## Configuration

All configuration is via environment variables. Defaults work out of the box.

**Shared**

| Variable | Default | Purpose |
|---|---|---|
| `YAI_STATE_DIR` | `<repo>/.yai` | State directory |
| `YAI_SEMANTIC_MAX_FIX_ROUNDS` | `5` | Story-level fix rounds after `soft_fail` |
| `YAI_FINAL_FIX_MAX_ROUNDS` | `5` | Final-phase fix rounds after `soft_fail` |

<details>
<summary><b>Codex adapter</b> (<code>--tool codex</code>, default)</summary>

| Variable | Default | Purpose |
|---|---|---|
| `YAI_CODEX_BIN` | `codex` | Executable path |
| `YAI_CODEX_MODEL` | adapter default | Model override |
| `YAI_CODEX_SANDBOX` | `workspace-write` | Sandbox mode for execute phase |
| `YAI_CODEX_APPROVAL` | `never` | Approval mode |
| `YAI_CODEX_TIMEOUT_SECONDS` | `3600` | Per-attempt timeout |
| `YAI_CODEX_MAX_RETRIES` | `10` | Runner-level retries |
| `YAI_EVAL_*` | inherits from `YAI_CODEX_*` | Evaluator tuning |
| `YAI_FINAL_EVAL_*` | inherits from `YAI_EVAL_*` | Final evaluator tuning |

Full reference: `bash .yai/bin/adapters/codex.sh --help`.
</details>

<details>
<summary><b>claude-code adapter</b> (<code>--tool claude-code</code>)</summary>

| Variable | Default | Purpose |
|---|---|---|
| `YAI_CC_BIN` | `claude` | Executable path |
| `YAI_CC_MODEL` | CLI default | Model override (`sonnet` / `opus` or full id) |
| `YAI_CC_PERMISSION_MODE` | `dontAsk` | Permission mode |
| `YAI_CC_ALLOWED_TOOLS` | `Bash,Read,Edit,Write,Glob,Grep` | Allowed tools for execute phase |
| `YAI_CC_ARGS` | _(empty)_ | Extra shell-split args |
| `YAI_CC_TIMEOUT_SECONDS` | `3600` | Per-attempt timeout |
| `YAI_CC_MAX_RETRIES` | `10` | Runner-level retries |
| `YAI_CC_EVAL_*` | inherits from `YAI_CC_*` | Evaluator tuning (defaults to read-only tool set) |
| `YAI_CC_FINAL_EVAL_*` | inherits from `YAI_CC_EVAL_*` | Final evaluator tuning |

Full reference: `bash .yai/bin/adapters/claude-code.sh --help`.
</details>

### Authentication for claude-code

By default the adapter uses your interactive `claude` login (OAuth / keychain).

For isolated or CI-style runs without OAuth, set `YAI_CC_ARGS="--bare"` and provide `ANTHROPIC_API_KEY`. With `--bare`, `claude` ignores OAuth and keychain and will fail as "Not logged in" if no API key is present.

## Adapters

```
.yai/
├── bin/
│   ├── yai.sh                  tool-agnostic core: state machine,
│   │                           prompt rendering, artifact validation,
│   │                           retries, worktree ops
│   └── adapters/
│       ├── codex.sh            codex CLI adapter
│       └── claude-code.sh      claude-code CLI adapter
└── prompts/                    shared prompt templates
```

Each adapter implements a single contract:

```
adapter --purpose <execute|eval|final-eval> \
        --repo-root <path> \
        --prompt-file <path> \
        --run-dir <path> \
        --iteration <label>
```

Outputs written under `<run-dir>`:

| File | Role |
|---|---|
| `<iteration>.last-message.txt` | Final assistant message (consumed by yai as the JSON artifact) |
| `<iteration>.events.jsonl` | Streamed events (observability) |
| `<iteration>.stderr.log` | Stderr (observability) |
| `<iteration>.status.txt` | Runner state and failure classification |

New adapters implement the contract only; `yai.sh` needs no changes. See `.yai/bin/adapters/` for reference implementations.

## Prompts

Prompts live in `.yai/prompts/` and are shared across adapters.

| File | Role |
|---|---|
| `EXECUTE.md` | Story-level execution instructions + artifact JSON contract |
| `EVAL.md` | Story-level semantic evaluator contract |
| `FINAL_EVAL.md` | Whole-PRD reviewer (scope drift, cross-story conflict) |
| `FINAL_FIX.md` | Bounded corrective fix (addresses final-eval findings only) |

## Troubleshooting

**`command not found: curl` or `jq`** — install via your package manager (e.g. `brew install jq curl` on macOS, `apt install jq curl` on Debian / Ubuntu).

**Installer exits with `not inside a git worktree`** — `cd` into the root of the repo you want to install yai into, then re-run the curl command.

**`Release vX.Y.Z does not publish SHA256SUMS`** — the release predates the SHA256SUMS publishing step. Install from a newer tag, or use `--branch main` / `--commit <sha>` (both skip verification and print a warning).

**claude-code exits with `Not logged in · Please run /login`** — either log in once interactively with `claude`, or set `YAI_CC_ARGS="--bare"` together with `ANTHROPIC_API_KEY`. See [Authentication for claude-code](#authentication-for-claude-code).

**`missing required command: codex`** — install the tool CLI you plan to use. yai warns but does not block at install time.

**Resume after a crash** — yai checkpoints in `.yai/active-story.json`. Re-run with `--adopt-dirty-worktree <story-id> --yes` to resume the interrupted story with the current worktree.

## Contributing

See [AGENTS.md](AGENTS.md) for development workflow, commit scope rules, lint and test invocation, and release process. Bug reports and feature requests are welcome via [Issues](https://github.com/rokurokulab/yai/issues).

## Inspired by

yai builds on the PRD-driven agent-loop idea from [@snarktank/ralph](https://github.com/snarktank/ralph).

## License

Apache-2.0 — see [LICENSE](LICENSE).
