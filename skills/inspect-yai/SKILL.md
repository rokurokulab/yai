---
name: inspect-yai
description: Inspect yai's runtime state — determine whether a run finished, which stories passed, which phase failed, what the final evaluator said, and where the per-round artifacts live. Read-only; does not mutate state.
user-invocable: true
---

# Inspect yai

Use this skill when the user asks things like "did yai finish?", "which story is stuck?", "show me the last run's final eval", or "what went wrong on story US-003?".

**This skill is read-only.** Never delete, move, or edit files under `.yai/` — if the user wants to recover from a bad state, use the `adopt-dirty-worktree` / rerun path instead.

## 1. Locate the state dir

```sh
# Default
STATE_DIR="${YAI_STATE_DIR:-.yai}"

# If user runs with --state-dir <path>, read from that instead
ls -la "$STATE_DIR"
```

Expected top-level files:

| Path | Role |
|---|---|
| `prd.json` | Active PRD; `.userStories[].passes` is mutated by yai |
| `prd-source.md` | Canonical PRD markdown snapshot (fed to final evaluator) |
| `progress.txt` | Human-readable progress log (story outcomes + learnings) |
| `completed-stories.json` | Array of fully-completed stories with commit SHA + artifact paths |
| `active-story.json` | Current checkpoint: `{storyId, phase, fixRound, executionArtifactPath, evalArtifactPath, scope}`. **Absent = no story in flight.** |
| `.last-branch` | git branch name at start (informational) |
| `.last-run` | Path to the most recent `runs/<timestamp>/` |
| `.last-archive-key` | Hash-based dedup key for `archive/` |
| `runs/<TS>/` | Per-run per-iteration artifacts (see §3) |
| `archive/<TS>-<HASH>.{prd.json,progress.txt,completed-stories.json}` | Snapshot of final state per completed run |

## 2. Answer common questions

### "Is the run complete?"

Three layers, check in order:

```sh
# Layer 1: active checkpoint present → run is in flight or was interrupted
if [ -f "$STATE_DIR/active-story.json" ]; then
  jq '.' "$STATE_DIR/active-story.json"  # shows storyId + phase + fixRound
  echo "→ run is mid-flight or interrupted"
  exit
fi

# Layer 2: all stories marked passes=true
total=$(jq '.userStories | length' "$STATE_DIR/prd.json")
done=$(jq '[.userStories[] | select(.passes == true)] | length' "$STATE_DIR/prd.json")
echo "stories: $done / $total"

# Layer 3: final eval present + status=pass → fully complete
latest_run=$(cat "$STATE_DIR/.last-run" 2>/dev/null)
if [ -n "$latest_run" ] && [ -f "$latest_run/final.eval.semantic-eval.json" ]; then
  jq -r '.status' "$latest_run/final.eval.semantic-eval.json"  # "pass" / "soft_fail" / "hard_fail"
fi
```

**Completeness definition**: all stories `passes=true` AND latest `final.eval.semantic-eval.json` has `.status == "pass"` AND no `active-story.json`.

### "Which story is stuck / was last attempted?"

```sh
# If checkpoint exists — that's the story
jq -r '.storyId, .phase, .fixRound' "$STATE_DIR/active-story.json" 2>/dev/null

# Else — the next pending one in priority order
jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[0] | "\(.id): \(.title)"' "$STATE_DIR/prd.json"
```

### "What was the final eval verdict?"

```sh
latest_run=$(cat "$STATE_DIR/.last-run")
final_eval="$latest_run/final.eval.semantic-eval.json"

jq '{
  status,
  summary,
  decision: .verdictSummary.decision,
  primaryReason: .verdictSummary.primaryReason,
  overallDrift: .verdictSummary.overallDriftLevel,
  requiredFixesCount: .verdictSummary.requiredFixesCount,
  scopeDrift
}' "$final_eval"
```

### "Why did story US-003 fail?"

Look at the latest eval artifact for that story within the run:

```sh
latest_run=$(cat "$STATE_DIR/.last-run")
# Iterations are numbered; each story occupies one (+ fix subrounds)
# Find the iteration where US-003 was the target — usually via prompt file:
grep -l '"id": *"US-003"' "$latest_run/"*.exec.prompt.md

# Once you find iteration-NNN for US-003, read its latest eval
ls "$latest_run/iteration-NNN"*.eval.semantic-eval.json
# The highest fix-MM suffix is the final verdict for that story attempt
jq '{status, summary, findings, requiredFixes, verdictSummary}' \
  "$latest_run/iteration-NNN.eval.semantic-eval.json"  # or the .fix-MM.eval variant
```

### "Was a fix round applied, and what did it change?"

```sh
latest_run=$(cat "$STATE_DIR/.last-run")

# Count fix rounds per iteration
ls "$latest_run/" | grep -oE 'iteration-[0-9]+\.fix-[0-9]+\.exec' | sort -u

# What each fix attempted (addressedFindings)
for f in "$latest_run/"*.fix-*.exec.story-result.json; do
  echo "--- $(basename "$f") ---"
  jq '{summary, filesChanged, addressedFindings: .addressedFindings[]?.kind}' "$f"
done
```

## 3. Per-run artifact layout

`.yai/runs/<TIMESTAMP>/` holds everything for one yai launch.

```
runs/2026-04-22T12-30-45Z/
├── iteration-001.exec.prompt.md                    # prompt sent for execute
├── iteration-001.exec.story-result.raw.json        # raw codex output
├── iteration-001.exec.story-result.json            # normalized execution artifact
├── iteration-001.exec.attempt-1.events.jsonl       # per-attempt codex events
├── iteration-001.exec.attempt-1.stderr.log
├── iteration-001.exec.attempt-1.last-message.txt
├── iteration-001.exec.events.jsonl                 # mirrors the final attempt
├── iteration-001.exec.status.txt                   # runner verdict per attempt
├── iteration-001.eval.prompt.md                    # eval prompt
├── iteration-001.eval.last-message.txt             # eval raw output
├── iteration-001.eval.semantic-eval.json           # normalized eval artifact
├── iteration-001.commit-message.txt                # commit title + body for this story
├── iteration-001.fix-01.exec.*                     # first fix round (if soft_fail)
├── iteration-001.fix-01.eval.*
├── iteration-002.exec.*                            # next story
├── ...
├── final.eval.prompt.md                            # run-level final eval prompt
├── final.eval.semantic-eval.json                   # final eval verdict
└── final.fix-01.*                                  # final fix round (if final soft_fail)
```

Naming convention:
- `iteration-NNN` = story iteration (first pass per story)
- `iteration-NNN.fix-MM` = MM-th fix round within story NNN
- `final.eval` = run-level review after all stories pass
- `final.fix-MM` = MM-th corrective round after final soft_fail

## 4. Interpreting status values

| Artifact | Field | Possible values | Meaning |
|---|---|---|---|
| `iteration-NNN.exec.story-result.json` | `.status` | `ok` / `mechanical_failed` / `infra_fail` | execute phase outcome |
| `iteration-NNN.eval.semantic-eval.json` | `.status` | `pass` / `soft_fail` / `hard_fail` / `infra_fail` | story-level semantic verdict |
| `final.eval.semantic-eval.json` | `.status` | `pass` / `soft_fail` / `hard_fail` / `infra_fail` | whole-PRD verdict |
| `final.eval.semantic-eval.json` | `.verdictSummary.overallDriftLevel` | `low` / `medium` / `high` | scope drift severity |

## 5. Archived (previous-run) state

Every completed run snapshots `prd.json`, `progress.txt`, `completed-stories.json` into `.yai/archive/<timestamp>-<hash>.{...}`. To see history:

```sh
ls -1 "$STATE_DIR/archive/" | sort -r | head -20
```

## 6. What NOT to do

- **Don't delete** `.yai/active-story.json` manually to "unstick" a run — use `bash /path/to/yai/scripts/yai.sh --adopt-dirty-worktree <story-id|FINAL> --yes` instead. The checkpoint is load-bearing for resume.
- **Don't edit** `prd.json.userStories[].passes` by hand to fake completion — the completed-stories ledger + commits won't match and subsequent runs will be confused.
- **Don't rely on `progress.txt`** alone for state — it's human-readable narrative, not the source of truth. JSON artifacts are canonical.
- **Don't assume `iteration-NNN` equals the N-th story**. If a previous launch hit `MAX_ITERATIONS` and this is a resumption, the NNN numbering restarts at 001 for the new `runs/<TS>/` dir.

## 7. One-liner summary for the user

When the user asks "is it done?", a clean text report:

```sh
echo "=== yai run summary ==="
echo "State dir: $STATE_DIR"
total=$(jq '.userStories | length' "$STATE_DIR/prd.json")
done=$(jq '[.userStories[] | select(.passes)] | length' "$STATE_DIR/prd.json")
echo "Stories: $done / $total passed"
if [ -f "$STATE_DIR/active-story.json" ]; then
  echo "In-flight: $(jq -r '"\(.storyId) @ \(.phase) fix-round=\(.fixRound)"' "$STATE_DIR/active-story.json")"
else
  echo "No active checkpoint"
fi
latest_run=$(cat "$STATE_DIR/.last-run" 2>/dev/null)
if [ -f "$latest_run/final.eval.semantic-eval.json" ]; then
  echo "Final eval: $(jq -r '.status + " — " + .verdictSummary.primaryReason' "$latest_run/final.eval.semantic-eval.json")"
else
  echo "Final eval: not run yet"
fi
```
