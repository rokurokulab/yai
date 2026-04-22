#!/usr/bin/env bash
# Copyright 2026 itscheems
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
  ./scripts/yai.sh [--tool codex] [--state-dir <path>] [--adopt-dirty-worktree <story-id>] [--yes] [max-iterations]

Examples:
  ./scripts/yai.sh
  ./scripts/yai.sh 20
  ./scripts/yai.sh --state-dir .yai-smoke 1
  ./scripts/yai.sh --adopt-dirty-worktree US-003 --yes

Environment:
  Shared:
    YAI_STATE_DIR                Default state dir (default: <repo>/.yai)
    YAI_CODEX_BIN                Codex executable (default: codex)

  Execution:
    YAI_CODEX_MODEL             Optional model override for codex exec
    YAI_CODEX_PROFILE           Optional Codex profile
    YAI_CODEX_SANDBOX           Sandbox mode for codex exec (default: workspace-write)
    YAI_CODEX_APPROVAL          Approval mode for codex exec (default: never)
    YAI_CODEX_ARGS              Extra shell-split Codex args, e.g. '--search'
    YAI_CODEX_TIMEOUT_SECONDS   Hard timeout for one Codex attempt (default: 1800)
    YAI_CODEX_MAX_RETRIES       Retry count after the initial failed attempt (default: 5)
    YAI_CODEX_RETRY_WAIT_SECONDS
                                  Base wait before retrying a retryable failure (default: 10)
    YAI_CODEX_TERM_GRACE_SECONDS
                                  Grace period between TERM and KILL on timeout (default: 5)

  Eval:
    YAI_EVAL_MODEL              Optional evaluator model override
    YAI_EVAL_PROFILE            Optional evaluator Codex profile
    YAI_EVAL_ARGS               Extra shell-split evaluator args
    YAI_EVAL_SANDBOX            Evaluator sandbox mode (default: read-only)
    YAI_EVAL_APPROVAL           Evaluator approval mode (default: never)
    YAI_EVAL_TIMEOUT_SECONDS    Hard timeout for one evaluator attempt (default: 1800)
    YAI_EVAL_MAX_RETRIES        Outer-loop evaluator infra retries (default: 2)
    YAI_EVAL_RETRY_WAIT_SECONDS Base wait before retrying evaluator infra failures (default: 10)
    YAI_EVAL_TERM_GRACE_SECONDS Grace period between TERM and KILL on evaluator timeout (default: 5)
    YAI_EVAL_RUNNER_MAX_RETRIES Runner retry count for evaluator transport failures (default: 0)

  Semantic loop:
    YAI_SEMANTIC_MAX_FIX_ROUNDS Fix rounds after evaluator soft-fail (default: 3)

  Final eval:
    YAI_FINAL_EVAL_MODEL        Optional final evaluator model override
    YAI_FINAL_EVAL_PROFILE      Optional final evaluator Codex profile
    YAI_FINAL_EVAL_ARGS         Extra shell-split final evaluator args
    YAI_FINAL_EVAL_SANDBOX      Final evaluator sandbox mode (default: read-only)
    YAI_FINAL_EVAL_APPROVAL     Final evaluator approval mode (default: never)
    YAI_FINAL_EVAL_TIMEOUT_SECONDS
                                  Hard timeout for one final evaluator attempt (default: 1800)
    YAI_FINAL_EVAL_MAX_RETRIES  Outer-loop final evaluator infra retries (default: 2)
    YAI_FINAL_EVAL_RETRY_WAIT_SECONDS
                                  Base wait before retrying final evaluator infra failures (default: 10)
    YAI_FINAL_EVAL_TERM_GRACE_SECONDS
                                  Grace period between TERM and KILL on final evaluator timeout (default: 5)
    YAI_FINAL_EVAL_RUNNER_MAX_RETRIES
                                  Runner retry count for final evaluator transport failures (default: 0)
    YAI_FINAL_FIX_MAX_ROUNDS    Final corrective rounds after final soft-fail (default: 3)

  Note:
    max-iterations limits one yai launch only; `.yai/prd.json` may contain more stories
    than this number. Story eval/fix and final eval/fix subrounds do not consume the story iteration budget.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUN_STARTED_EPOCH="$(date +%s)"
RUN_DURATION_PRINTED=0

TOOL="codex"
MAX_ITERATIONS=10
STATE_DIR="${YAI_STATE_DIR:-$ROOT_DIR/.yai}"
ADOPT_DIRTY_STORY_ID=""
ASSUME_YES=0
YAI_EVAL_MAX_RETRIES="${YAI_EVAL_MAX_RETRIES:-2}"
YAI_EVAL_RETRY_WAIT_SECONDS="${YAI_EVAL_RETRY_WAIT_SECONDS:-10}"
YAI_SEMANTIC_MAX_FIX_ROUNDS="${YAI_SEMANTIC_MAX_FIX_ROUNDS:-3}"
YAI_FINAL_EVAL_MAX_RETRIES="${YAI_FINAL_EVAL_MAX_RETRIES:-2}"
YAI_FINAL_EVAL_RETRY_WAIT_SECONDS="${YAI_FINAL_EVAL_RETRY_WAIT_SECONDS:-10}"
YAI_FINAL_FIX_MAX_ROUNDS="${YAI_FINAL_FIX_MAX_ROUNDS:-3}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tool)
		TOOL="$2"
		shift 2
		;;
	--tool=*)
		TOOL="${1#*=}"
		shift
		;;
	--state-dir)
		STATE_DIR="$2"
		shift 2
		;;
	--state-dir=*)
		STATE_DIR="${1#*=}"
		shift
		;;
	--adopt-dirty-worktree)
		ADOPT_DIRTY_STORY_ID="$2"
		shift 2
		;;
	--adopt-dirty-worktree=*)
		ADOPT_DIRTY_STORY_ID="${1#*=}"
		shift
		;;
	--yes)
		ASSUME_YES=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		if [[ "$1" =~ ^[0-9]+$ ]]; then
			MAX_ITERATIONS="$1"
			shift
		else
			echo "unknown argument: $1" >&2
			usage >&2
			exit 1
		fi
		;;
	esac
done

if [[ "$TOOL" != "codex" ]]; then
	echo "unsupported tool '$TOOL' in this repo-local integration; use --tool codex" >&2
	exit 1
fi

PRD_FILE="$STATE_DIR/prd.json"
PRD_SOURCE_FILE="$STATE_DIR/prd-source.md"
PROGRESS_FILE="$STATE_DIR/progress.txt"
COMPLETED_STORIES_FILE="$STATE_DIR/completed-stories.json"
ARCHIVE_DIR="$STATE_DIR/archive"
RUNS_DIR="$STATE_DIR/runs"
LAST_BRANCH_FILE="$STATE_DIR/.last-branch"
LAST_RUN_FILE="$STATE_DIR/.last-run"
LAST_ARCHIVE_KEY_FILE="$STATE_DIR/.last-archive-key"
ACTIVE_STORY_FILE="$STATE_DIR/active-story.json"

require_command() {
	local command_name="$1"
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "missing required command: $command_name" >&2
		exit 127
	fi
}

ensure_uint() {
	local label="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		echo "$label must be an unsigned integer, got: $value" >&2
		exit 2
	fi
}

ensure_prereqs() {
	require_command git
	require_command jq
	require_command shasum
	require_command "${YAI_CODEX_BIN:-codex}"
	ensure_uint "YAI_EVAL_MAX_RETRIES" "$YAI_EVAL_MAX_RETRIES"
	ensure_uint "YAI_EVAL_RETRY_WAIT_SECONDS" "$YAI_EVAL_RETRY_WAIT_SECONDS"
	ensure_uint "YAI_SEMANTIC_MAX_FIX_ROUNDS" "$YAI_SEMANTIC_MAX_FIX_ROUNDS"
	ensure_uint "YAI_FINAL_EVAL_MAX_RETRIES" "$YAI_FINAL_EVAL_MAX_RETRIES"
	ensure_uint "YAI_FINAL_EVAL_RETRY_WAIT_SECONDS" "$YAI_FINAL_EVAL_RETRY_WAIT_SECONDS"
	ensure_uint "YAI_FINAL_FIX_MAX_ROUNDS" "$YAI_FINAL_FIX_MAX_ROUNDS"
}

ensure_state_layout() {
	mkdir -p "$STATE_DIR" "$ARCHIVE_DIR" "$RUNS_DIR"
}

init_progress_file() {
	if [[ ! -f "$PROGRESS_FILE" ]]; then
		{
			echo "# yai Progress Log"
			echo "Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
			echo
			echo "## Codebase Patterns"
			echo
			echo "---"
		} >"$PROGRESS_FILE"
	fi
}

init_completed_stories_file() {
	if [[ ! -f "$COMPLETED_STORIES_FILE" ]]; then
		printf '[]\n' >"$COMPLETED_STORIES_FILE"
	fi
}

backfill_completed_stories_file() {
	local tmp_file
	tmp_file="$(mktemp)"
	jq '
		.userStories
		| map(select(.passes == true) | { storyId: .id, title: .title })
	' "$PRD_FILE" | jq --slurpfile completed "$COMPLETED_STORIES_FILE" '
		($completed[0] // []) as $completed
		| reduce .[] as $story ($completed;
			if any(.[]; .storyId == $story.storyId) then
				.
			else
				. + [{
					storyId: $story.storyId,
					title: $story.title,
					commitSha: "",
					completedAt: "",
					executionArtifactPath: "",
					evalArtifactPath: "",
					mechanicalChecks: [],
					summary: "completed before completed-stories tracking"
				}]
			end
		)
	' >"$tmp_file"
	mv "$tmp_file" "$COMPLETED_STORIES_FILE"
}

show_missing_prd_source_help() {
	cat <<EOF >&2
Missing yai PRD source snapshot: $(relative_to_root "$PRD_SOURCE_FILE")

yai final eval requires the canonical PRD markdown for this run.

To continue:
1. Copy the source PRD markdown into the state directory, for example:
   cp outputs/v0.0.8/your-prd.md "$(relative_to_root "$PRD_SOURCE_FILE")"
2. Re-run yai.

If you create prd.json through the yai PRD JSON workflow, it should write prd-source.md alongside prd.json.
EOF
}

ensure_prd_source_exists() {
	if [[ ! -f "$PRD_SOURCE_FILE" ]]; then
		show_missing_prd_source_help
		exit 1
	fi
}

timestamp_utc() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

format_elapsed_human() {
	local total_seconds="$1"
	local hours minutes seconds
	hours=$((total_seconds / 3600))
	minutes=$(((total_seconds % 3600) / 60))
	seconds=$((total_seconds % 60))

	if [[ "$hours" -gt 0 ]]; then
		printf '%dh %02dm %02ds\n' "$hours" "$minutes" "$seconds"
	elif [[ "$minutes" -gt 0 ]]; then
		printf '%dm %02ds\n' "$minutes" "$seconds"
	else
		printf '%ds\n' "$seconds"
	fi
}

print_run_elapsed_time() {
	if [[ "$RUN_DURATION_PRINTED" -eq 1 ]]; then
		return
	fi

	local ended_epoch elapsed_seconds
	ended_epoch="$(date +%s)"
	elapsed_seconds=$((ended_epoch - RUN_STARTED_EPOCH))
	RUN_DURATION_PRINTED=1
	echo "Elapsed time: $(format_elapsed_human "$elapsed_seconds")"
}

relative_to_root() {
	local path="$1"
	if [[ "$path" == "$ROOT_DIR/"* ]]; then
		printf '%s\n' "${path#"$ROOT_DIR"/}"
	else
		printf '%s\n' "$path"
	fi
}

current_branch_name() {
	local git_branch prd_branch
	git_branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
	if [[ -n "$git_branch" && "$git_branch" != "HEAD" ]]; then
		printf '%s\n' "$git_branch"
		return 0
	fi

	prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
	if [[ -n "$prd_branch" ]]; then
		printf '%s\n' "$prd_branch"
		return 0
	fi

	printf 'unlabeled\n'
}

latest_run_dir() {
	if [[ -f "$LAST_RUN_FILE" ]]; then
		cat "$LAST_RUN_FILE"
	fi
}

latest_final_eval_artifact() {
	local run_dir
	run_dir="$(latest_run_dir)"
	if [[ -n "$run_dir" && -f "$run_dir/final.eval.semantic-eval.json" ]]; then
		printf '%s\n' "$run_dir/final.eval.semantic-eval.json"
	fi
}

latest_final_eval_passed() {
	local artifact
	artifact="$(latest_final_eval_artifact || true)"
	if [[ -n "$artifact" && -f "$artifact" ]]; then
		[[ "$(jq -r '.status // empty' "$artifact")" == "pass" ]]
		return
	fi
	return 1
}

sanitize_archive_label() {
	printf '%s' "$1" | sed 's|[^A-Za-z0-9._-]|-|g; s|-\\{2,\\}|-|g; s|^-||; s|-$||'
}

archive_current_state() {
	local reason="$1"
	if [[ ! -f "$PRD_FILE" ]]; then
		return 0
	fi

	local raw_branch branch_label prd_hash archive_key timestamp archive_base
	raw_branch="$(current_branch_name)"
	branch_label="$(sanitize_archive_label "$raw_branch")"
	if [[ -z "$branch_label" ]]; then
		branch_label="unlabeled"
	fi

	prd_hash="$(shasum -a 256 "$PRD_FILE" | awk '{print substr($1, 1, 12)}')"
	archive_key="${branch_label}-${prd_hash}"

	if [[ -f "$LAST_ARCHIVE_KEY_FILE" ]] && [[ "$(cat "$LAST_ARCHIVE_KEY_FILE")" == "$archive_key" ]]; then
		return 0
	fi

	if compgen -G "$ARCHIVE_DIR/*-${archive_key}.prd.json" >/dev/null; then
		printf '%s\n' "$archive_key" >"$LAST_ARCHIVE_KEY_FILE"
		return 0
	fi

	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	archive_base="$ARCHIVE_DIR/${timestamp}-${archive_key}"

	cp "$PRD_FILE" "${archive_base}.prd.json"
	if [[ -f "$PROGRESS_FILE" ]]; then
		cp "$PROGRESS_FILE" "${archive_base}.progress.txt"
	fi
	if [[ -f "$PRD_SOURCE_FILE" ]]; then
		cp "$PRD_SOURCE_FILE" "${archive_base}.prd-source.md"
	fi
	if [[ -f "$COMPLETED_STORIES_FILE" ]]; then
		cp "$COMPLETED_STORIES_FILE" "${archive_base}.completed-stories.json"
	fi
	local final_eval_artifact
	final_eval_artifact="$(latest_final_eval_artifact || true)"
	if [[ -n "$final_eval_artifact" && -f "$final_eval_artifact" ]]; then
		cp "$final_eval_artifact" "${archive_base}.final.eval.json"
	fi

	cat >"${archive_base}.meta.txt" <<EOF
archived_at=$(timestamp_utc)
reason=$reason
source_branch=$raw_branch
prd_hash=$prd_hash
EOF

	printf '%s\n' "$archive_key" >"$LAST_ARCHIVE_KEY_FILE"
	echo "Archived yai state: $(relative_to_root "${archive_base}.prd.json")"
}

track_current_branch() {
	printf '%s\n' "$(current_branch_name)" >"$LAST_BRANCH_FILE"
}

pending_story_count() {
	jq '[.userStories[]? | select(.passes != true)] | length' "$PRD_FILE"
}

total_story_count() {
	jq '[.userStories[]?] | length' "$PRD_FILE"
}

story_exists_pending() {
	local story_id="$1"
	jq -e --arg story_id "$story_id" '.userStories[]? | select(.id == $story_id and .passes != true)' "$PRD_FILE" >/dev/null
}

next_pending_story_id() {
	jq -r '
		.userStories
		| map(select(.passes != true))
		| sort_by(.priority, .id)
		| .[0].id // empty
	' "$PRD_FILE"
}

selected_story_payload() {
	local story_id="$1"
	jq -c --arg story_id "$story_id" '
		.userStories[]
		| select(.id == $story_id)
		| {
			id,
			title,
			description,
			priority,
			acceptanceCriteria: (
				.acceptanceCriteria
				| to_entries
				| map({
					criterionId: ("AC-" + ((.key + 1) | tostring)),
					criterionText: .value
				})
			)
		}
	' "$PRD_FILE"
}

story_title() {
	local story_id="$1"
	jq -r --arg story_id "$story_id" '.userStories[] | select(.id == $story_id) | .title' "$PRD_FILE"
}

dirty_worktree_files_json() {
	local lines
	lines="$(
		{
			git -C "$ROOT_DIR" diff --name-only --relative
			git -C "$ROOT_DIR" diff --cached --name-only --relative
			git -C "$ROOT_DIR" ls-files --others --exclude-standard
		} | sed '/^[[:space:]]*$/d' | grep -v '^.yai/' | sort -u
	)"

	if [[ -z "$lines" ]]; then
		printf '[]\n'
	else
		printf '%s\n' "$lines" | jq -R . | jq -s '.'
	fi
}

dirty_worktree_count() {
	local dirty_json
	dirty_json="$(dirty_worktree_files_json)"
	jq 'length' <<<"$dirty_json"
}

show_dirty_worktree_summary() {
	local dirty_json
	dirty_json="$(dirty_worktree_files_json)"
	if [[ "$(jq 'length' <<<"$dirty_json")" -eq 0 ]]; then
		echo "  Dirty files: none"
		return
	fi

	echo "  Dirty files:"
	jq -r '.[]' <<<"$dirty_json" | sed 's/^/    - /'
}

write_active_story_checkpoint() {
	local story_id="$1"
	local story_iteration="$2"
	local phase="$3"
	local fix_round="$4"
	local run_dir="$5"
	local execution_artifact_path="$6"
	local eval_artifact_path="$7"
	local scope="${8:-story}"
	local dirty_json
	dirty_json="$(dirty_worktree_files_json)"

	jq -n \
		--arg scope "$scope" \
		--arg storyId "$story_id" \
		--argjson storyIteration "$story_iteration" \
		--arg phase "$phase" \
		--argjson fixRound "$fix_round" \
		--arg runDir "$run_dir" \
		--arg executionArtifactPath "$execution_artifact_path" \
		--arg evalArtifactPath "$eval_artifact_path" \
		--arg startedAt "$(timestamp_utc)" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'{
			scope: $scope,
			storyId: $storyId,
			storyIteration: $storyIteration,
			phase: $phase,
			fixRound: $fixRound,
			runDir: $runDir,
			executionArtifactPath: $executionArtifactPath,
			evalArtifactPath: $evalArtifactPath,
			startedAt: $startedAt,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' >"$ACTIVE_STORY_FILE"
}

clear_active_story_checkpoint() {
	rm -f "$ACTIVE_STORY_FILE"
}

adopt_dirty_worktree_confirmed() {
	if [[ "$ASSUME_YES" -eq 1 ]]; then
		return 0
	fi

	if [[ ! -t 0 ]]; then
		echo "Dirty worktree adoption requires --yes in non-interactive mode." >&2
		return 1
	fi

	local answer
	printf "Adopt dirty worktree into story %s? [y/N] " "$ADOPT_DIRTY_STORY_ID" >&2
	read -r answer
	case "$answer" in
	y | Y | yes | YES)
		return 0
		;;
	*)
		echo "Aborted dirty worktree adoption." >&2
		return 1
		;;
	esac
}

maybe_adopt_dirty_worktree() {
	if [[ -z "$ADOPT_DIRTY_STORY_ID" ]]; then
		return 1
	fi

	if [[ "$ADOPT_DIRTY_STORY_ID" == "FINAL" ]]; then
		if [[ "$(dirty_worktree_count)" -eq 0 ]]; then
			echo "Nothing to adopt: the worktree is clean." >&2
			exit 1
		fi

		local run_dir eval_artifact_path next_fix_round
		run_dir=""
		eval_artifact_path=""
		next_fix_round=1

		if [[ -f "$ACTIVE_STORY_FILE" ]]; then
			if [[ "$(jq -r '.scope // "story"' "$ACTIVE_STORY_FILE")" != "final" ]]; then
				echo "Cannot adopt dirty worktree into FINAL while a story checkpoint is active." >&2
				exit 1
			fi
			run_dir="$(jq -r '.runDir // ""' "$ACTIVE_STORY_FILE")"
			eval_artifact_path="$(jq -r '.evalArtifactPath // ""' "$ACTIVE_STORY_FILE")"
			if [[ "$(jq -r '.phase // ""' "$ACTIVE_STORY_FILE")" == "final_fix" ]]; then
				next_fix_round="$(jq -r '(.fixRound // 0) + 1' "$ACTIVE_STORY_FILE")"
			fi
		else
			run_dir="$(latest_run_dir || true)"
			eval_artifact_path="$(latest_final_eval_artifact || true)"
		fi

		if [[ -z "$run_dir" || -z "$eval_artifact_path" || ! -f "$eval_artifact_path" ]]; then
			echo "Cannot adopt dirty worktree into FINAL without an existing final eval artifact." >&2
			exit 1
		fi

		if [[ "$(jq -r '.status // empty' "$eval_artifact_path")" != "pass" ]]; then
			echo "Cannot adopt dirty worktree into FINAL unless the current final eval already passed." >&2
			exit 1
		fi

		echo "Preparing dirty worktree adoption into FINAL."
		show_dirty_worktree_summary
		if ! adopt_dirty_worktree_confirmed; then
			exit 1
		fi

		write_active_story_checkpoint "FINAL" 0 "final_fix" "$next_fix_round" "$run_dir" "" "$eval_artifact_path" "final"
		echo "Adopted dirty worktree into FINAL finalization round."
		return 0
	fi

	if [[ -f "$ACTIVE_STORY_FILE" ]]; then
		echo "Cannot adopt a dirty worktree while an active story checkpoint already exists." >&2
		exit 1
	fi

	if ! story_exists_pending "$ADOPT_DIRTY_STORY_ID"; then
		echo "Cannot adopt dirty worktree into unknown or completed story: $ADOPT_DIRTY_STORY_ID" >&2
		exit 1
	fi

	if [[ "$(dirty_worktree_count)" -eq 0 ]]; then
		echo "Nothing to adopt: the worktree is clean." >&2
		exit 1
	fi

	echo "Preparing dirty worktree adoption."
	echo "  Target story: $ADOPT_DIRTY_STORY_ID - $(story_title "$ADOPT_DIRTY_STORY_ID")"
	show_dirty_worktree_summary

	if ! adopt_dirty_worktree_confirmed; then
		exit 1
	fi

	write_active_story_checkpoint "$ADOPT_DIRTY_STORY_ID" 0 "execute" 0 "" "" ""
	echo "Adopted dirty worktree into story $ADOPT_DIRTY_STORY_ID."
	return 0
}

stop_for_dirty_worktree() {
	echo "yai found a dirty worktree without an active checkpoint." >&2
	show_dirty_worktree_summary >&2 || true
	echo "Either clean the worktree first or adopt it explicitly:" >&2
	echo "  ./scripts/yai.sh --adopt-dirty-worktree <story-id> --yes" >&2
	echo "If all stories are already complete and a passed final eval exists, you may instead adopt the current diff into FINAL:" >&2
	echo "  ./scripts/yai.sh --adopt-dirty-worktree FINAL --yes" >&2
	exit 1
}

ensure_story_context() {
	if [[ ! -f "$PRD_FILE" ]]; then
		show_missing_prd_help
		exit 1
	fi

	if [[ "$(dirty_worktree_count)" -gt 0 ]]; then
		if [[ -n "$ADOPT_DIRTY_STORY_ID" ]]; then
			maybe_adopt_dirty_worktree
			return 0
		fi
		if [[ -f "$ACTIVE_STORY_FILE" ]]; then
			return 0
		fi
		stop_for_dirty_worktree
	fi
}

render_execution_prompt() {
	local prompt_path="$1"
	local story_json="$2"
	local story_iteration="$3"
	local fix_round="$4"
	local artifact_path="$5"
	local prior_eval_path="$6"

	cat >"$prompt_path" <<EOF
# yai Execution Context

Repository root: $ROOT_DIR
yai state directory: $STATE_DIR
Current story iteration: $story_iteration of $MAX_ITERATIONS
Current fix round: $fix_round

Selected story:
$story_json

Use these files as the yai source of truth:
- PRD: $PRD_FILE
- Progress log: $PROGRESS_FILE

Write the execution artifact JSON to:
- $artifact_path

If this is a fix round, the previous semantic eval artifact is:
- $prior_eval_path

Do not modify:
- $PRD_FILE
- $PROGRESS_FILE

EOF
	cat "$ROOT_DIR/prompts/EXECUTE.md" >>"$prompt_path"
}

render_eval_prompt() {
	local prompt_path="$1"
	local story_json="$2"
	local story_iteration="$3"
	local fix_round="$4"
	local execution_artifact_path="$5"

	cat >"$prompt_path" <<EOF
# yai Semantic Eval Context

Repository root: $ROOT_DIR
yai state directory: $STATE_DIR
Current story iteration: $story_iteration of $MAX_ITERATIONS
Current fix round: $fix_round

Selected story:
$story_json

Use these files as the yai source of truth:
- PRD: $PRD_FILE
- Progress log: $PROGRESS_FILE
- Execution artifact: $execution_artifact_path

Review the current uncommitted worktree against the selected story.

EOF
	cat "$ROOT_DIR/prompts/EVAL.md" >>"$prompt_path"
}

render_final_eval_prompt() {
	local prompt_path="$1"
	local final_eval_artifact="$2"

	cat >"$prompt_path" <<EOF
# yai Final Eval Context

Repository root: $ROOT_DIR
yai state directory: $STATE_DIR

Canonical source of truth for this run:
- PRD source snapshot: $PRD_SOURCE_FILE
- Active prd.json: $PRD_FILE
- Completed stories summary: $COMPLETED_STORIES_FILE

Review the current branch state against the whole PRD, not one individual story.

Write no files except the final evaluator JSON response to the standard Codex last-message output path.
The current canonical final eval artifact path is:
- $final_eval_artifact

EOF
	cat "$ROOT_DIR/prompts/FINAL_EVAL.md" >>"$prompt_path"
}

render_final_fix_prompt() {
	local prompt_path="$1"
	local final_eval_artifact="$2"
	local fix_artifact_path="$3"
	local fix_round="$4"
	local fix_mode="$5"

	cat >"$prompt_path" <<EOF
# yai Final Fix Context

Repository root: $ROOT_DIR
yai state directory: $STATE_DIR
Current final fix round: $fix_round of $YAI_FINAL_FIX_MAX_ROUNDS
Final fix mode: $fix_mode

Canonical source of truth for this run:
- PRD source snapshot: $PRD_SOURCE_FILE
- Active prd.json: $PRD_FILE
- Completed stories summary: $COMPLETED_STORIES_FILE
- Final eval artifact: $final_eval_artifact

Write the final-fix artifact JSON to:
- $fix_artifact_path

Do not modify:
- $PRD_FILE
- $PRD_SOURCE_FILE
- $PROGRESS_FILE
- $COMPLETED_STORIES_FILE

Current dirty worktree summary:
$(show_dirty_worktree_summary)

EOF
	cat "$ROOT_DIR/prompts/FINAL_FIX.md" >>"$prompt_path"
}

final_fix_mode_for_eval_artifact() {
	local final_eval_artifact="$1"
	if [[ -f "$final_eval_artifact" ]] && jq -e '
		.status == "pass"
		and ((.requiredFixes | length) == 0)
	' "$final_eval_artifact" >/dev/null 2>&1; then
		printf '%s\n' "finalize-dirty-worktree"
	else
		printf '%s\n' "bounded-corrective-change"
	fi
}

show_missing_prd_help() {
	cat <<EOF >&2
Missing yai PRD: $(relative_to_root "$PRD_FILE")

To start:
1. Create the state directory:
   mkdir -p "$(relative_to_root "$STATE_DIR")"
2. Copy the example PRD:
   cp scripts/prd.json.example "$(relative_to_root "$PRD_FILE")"
3. Copy the source PRD markdown:
   cp /path/to/source-prd.md "$(relative_to_root "$PRD_SOURCE_FILE")"
4. Edit the PRD stories for your feature.
EOF
}

validate_execution_core() {
	local artifact_path="$1"
	jq -e '
		((.status == "ok") or (.status == "mechanical_failed") or (.status == "infra_fail"))
		and (.summary | type == "string")
		and (.filesChanged | type == "array")
		and all(.filesChanged[]?; type == "string")
		and (.mechanicalChecks | type == "array")
		and all(
			.mechanicalChecks[]?;
			(.command | type == "string")
			and ((.status == "passed") or (.status == "failed") or (.status == "skipped"))
			and ((has("outputPath") | not) or (.outputPath | type == "string"))
		)
		and (.acceptanceCriteriaClaims | type == "array")
		and all(
			.acceptanceCriteriaClaims[]?;
			(.criterionId | type == "string")
			and (.criterionText | type == "string")
			and ((.claimedStatus == "met") or (.claimedStatus == "not_met") or (.claimedStatus == "unclear"))
			and has("evidence")
		)
		and (.proposedCommit | type == "object")
		and (.proposedCommit.title | type == "string")
		and (.proposedCommit.bodyBullets | type == "array")
		and all(.proposedCommit.bodyBullets[]?; type == "string")
		and (.learnings | type == "array")
		and all(.learnings[]?; type == "string")
	' "$artifact_path" >/dev/null
}

validate_eval_core() {
	local artifact_path="$1"
	jq -e '
		((.status == "pass") or (.status == "soft_fail") or (.status == "hard_fail") or (.status == "infra_fail"))
		and (.summary | type == "string")
		and (.acceptanceCriteriaReview | type == "array")
		and all(
			.acceptanceCriteriaReview[]?;
			(.criterionId | type == "string")
			and (.criterionText | type == "string")
			and ((.judgment == "met") or (.judgment == "unmet") or (.judgment == "unclear"))
			and has("evidence")
		)
		and (.findings | type == "array")
		and all(.findings[]?; type == "string")
		and (.requiredFixes | type == "array")
		and all(.requiredFixes[]?; type == "string")
		and (.verdictSummary | type == "object")
		and (.verdictSummary.decision | type == "string")
		and (.verdictSummary.primaryReason | type == "string")
		and (.verdictSummary.requiredFixesCount | type == "number")
		and (
			(has("approvedCommit") | not)
			or (
				(.approvedCommit | type == "object")
				and (.approvedCommit.title | type == "string")
				and (.approvedCommit.bodyBullets | type == "array")
				and all(.approvedCommit.bodyBullets[]?; type == "string")
			)
		)
	' "$artifact_path" >/dev/null
}

validate_final_eval_core() {
	local artifact_path="$1"
	jq -e '
		((.status == "pass") or (.status == "soft_fail") or (.status == "hard_fail") or (.status == "infra_fail"))
		and (.summary | type == "string")
		and (.prdReview | type == "object")
		and (.prdReview.goals | type == "array")
		and (.prdReview.userStories | type == "array")
		and (.prdReview.functionalRequirements | type == "array")
		and (.prdReview.nonGoals | type == "array")
		and all(
			(.prdReview.goals + .prdReview.userStories + .prdReview.functionalRequirements + .prdReview.nonGoals)[];
			(.id | type == "string")
			and (.text | type == "string")
			and ((.judgment == "met") or (.judgment == "unmet") or (.judgment == "unclear"))
			and has("evidence")
		)
		and (.scopeDrift | type == "object")
		and (.scopeDrift.underfit | type == "object")
		and (.scopeDrift.underfit.present | type == "boolean")
		and (.scopeDrift.underfit.summary | type == "string")
		and (.scopeDrift.underfit | has("evidence"))
		and (.scopeDrift.overreach | type == "object")
		and (.scopeDrift.overreach.present | type == "boolean")
		and (.scopeDrift.overreach.summary | type == "string")
		and (.scopeDrift.overreach | has("evidence"))
		and (.scopeDrift.cross_story_conflict | type == "object")
		and (.scopeDrift.cross_story_conflict.present | type == "boolean")
		and (.scopeDrift.cross_story_conflict.summary | type == "string")
		and (.scopeDrift.cross_story_conflict | has("evidence"))
		and (.scopeDrift.shared_constraint_loss | type == "object")
		and (.scopeDrift.shared_constraint_loss.present | type == "boolean")
		and (.scopeDrift.shared_constraint_loss.summary | type == "string")
		and (.scopeDrift.shared_constraint_loss | has("evidence"))
		and (.findings | type == "array")
		and all(
			.findings[];
			(.id | type == "string")
			and ((.kind == "implementation_fix") or (.kind == "story_slicing_issue") or (.kind == "prd_scope_issue"))
			and (.summary | type == "string")
			and has("evidence")
		)
		and (.requiredFixes | type == "array")
		and all(
			.requiredFixes[];
			(.id | type == "string")
			and ((.kind == "implementation_fix") or (.kind == "story_slicing_issue") or (.kind == "prd_scope_issue"))
			and (.summary | type == "string")
			and has("targets")
			and has("evidence")
		)
		and (.verdictSummary | type == "object")
		and (.verdictSummary.decision | type == "string")
		and (.verdictSummary.primaryReason | type == "string")
		and (.verdictSummary.requiredFixesCount | type == "number")
		and ((.verdictSummary.overallDriftLevel == "low") or (.verdictSummary.overallDriftLevel == "medium") or (.verdictSummary.overallDriftLevel == "high"))
		and (
			(has("approvedCommit") | not)
			or (
				(.approvedCommit | type == "object")
				and (.approvedCommit.title | type == "string")
				and (.approvedCommit.bodyBullets | type == "array")
				and all(.approvedCommit.bodyBullets[]?; type == "string")
			)
		)
		and (
			(has("humanGuidance") | not)
			or (
				(.humanGuidance | type == "object")
				and ((.humanGuidance.recommendedLayer == "implementation_fix") or (.humanGuidance.recommendedLayer == "story_slicing_issue") or (.humanGuidance.recommendedLayer == "prd_scope_issue"))
				and (.humanGuidance.nextAction | type == "string")
			)
		)
	' "$artifact_path" >/dev/null
}

validate_final_fix_core() {
	local artifact_path="$1"
	jq -e '
		((.status == "ok") or (.status == "mechanical_failed") or (.status == "infra_fail"))
		and (.summary | type == "string")
		and (.filesChanged | type == "array")
		and all(.filesChanged[]?; type == "string")
		and (.mechanicalChecks | type == "array")
		and all(
			.mechanicalChecks[]?;
			(.command | type == "string")
			and ((.status == "passed") or (.status == "failed") or (.status == "skipped"))
			and ((has("outputPath") | not) or (.outputPath | type == "string"))
		)
		and (.addressedFindings | type == "array")
		and all(
			.addressedFindings[]?;
			(.findingId | type == "string")
			and ((.kind == "implementation_fix") or (.kind == "story_slicing_issue") or (.kind == "prd_scope_issue"))
			and ((.status == "addressed") or (.status == "not_addressed") or (.status == "unclear"))
			and has("evidence")
		)
		and (.proposedCommit | type == "object")
		and (.proposedCommit.title | type == "string")
		and (.proposedCommit.bodyBullets | type == "array")
		and all(.proposedCommit.bodyBullets[]?; type == "string")
		and (.learnings | type == "array")
		and all(.learnings[]?; type == "string")
	' "$artifact_path" >/dev/null
}

normalize_execution_artifact() {
	local raw_path="$1"
	local artifact_path="$2"
	local story_id="$3"
	local story_iteration="$4"
	local fix_round="$5"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq \
		--arg storyId "$story_id" \
		--argjson storyIteration "$story_iteration" \
		--argjson fixRound "$fix_round" \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'. + {
			storyId: $storyId,
			storyIteration: $storyIteration,
			fixRound: $fixRound,
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' "$raw_path" >"$artifact_path"
}

write_synthetic_execution_infra_artifact() {
	local artifact_path="$1"
	local story_id="$2"
	local story_iteration="$3"
	local fix_round="$4"
	local reason="$5"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq -n \
		--arg storyId "$story_id" \
		--argjson storyIteration "$story_iteration" \
		--argjson fixRound "$fix_round" \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		--arg summary "$reason" \
		'{
			storyId: $storyId,
			storyIteration: $storyIteration,
			fixRound: $fixRound,
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles,
			status: "infra_fail",
			summary: $summary,
			filesChanged: [],
			mechanicalChecks: [],
			acceptanceCriteriaClaims: [],
			proposedCommit: {
				title: "",
				bodyBullets: []
			},
			learnings: []
		}' >"$artifact_path"
}

normalize_eval_artifact() {
	local raw_message_path="$1"
	local artifact_path="$2"
	local story_id="$3"
	local story_iteration="$4"
	local fix_round="$5"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq \
		--arg storyId "$story_id" \
		--argjson storyIteration "$story_iteration" \
		--argjson fixRound "$fix_round" \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'. + {
			storyId: $storyId,
			storyIteration: $storyIteration,
			fixRound: $fixRound,
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' "$raw_message_path" >"$artifact_path"
}

write_synthetic_eval_infra_artifact() {
	local artifact_path="$1"
	local story_id="$2"
	local story_iteration="$3"
	local fix_round="$4"
	local reason="$5"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq -n \
		--arg storyId "$story_id" \
		--argjson storyIteration "$story_iteration" \
		--argjson fixRound "$fix_round" \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		--arg summary "$reason" \
		'{
			storyId: $storyId,
			storyIteration: $storyIteration,
			fixRound: $fixRound,
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles,
			status: "infra_fail",
			summary: $summary,
			acceptanceCriteriaReview: [],
			findings: [],
			requiredFixes: [],
			verdictSummary: {
				decision: "infra_fail",
				primaryReason: $summary,
				requiredFixesCount: 0
			}
	}' >"$artifact_path"
}

normalize_final_eval_artifact() {
	local raw_message_path="$1"
	local artifact_path="$2"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'. + {
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' "$raw_message_path" >"$artifact_path"
}

write_synthetic_final_eval_infra_artifact() {
	local artifact_path="$1"
	local reason="$2"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq -n \
		--arg summary "$reason" \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'{
			status: "infra_fail",
			summary: $summary,
			prdReview: {
				goals: [],
				userStories: [],
				functionalRequirements: [],
				nonGoals: []
			},
			scopeDrift: {
				underfit: { present: false, summary: "", evidence: [] },
				overreach: { present: false, summary: "", evidence: [] },
				cross_story_conflict: { present: false, summary: "", evidence: [] },
				shared_constraint_loss: { present: false, summary: "", evidence: [] }
			},
			findings: [],
			requiredFixes: [],
			verdictSummary: {
				decision: "infra_fail",
				primaryReason: $summary,
				requiredFixesCount: 0,
				overallDriftLevel: "high"
			},
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' >"$artifact_path"
}

normalize_final_fix_artifact() {
	local raw_path="$1"
	local artifact_path="$2"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'. + {
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' "$raw_path" >"$artifact_path"
}

write_synthetic_final_fix_infra_artifact() {
	local artifact_path="$1"
	local reason="$2"
	local dirty_json git_head
	dirty_json="$(dirty_worktree_files_json)"
	git_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
	if [[ -z "$git_head" ]]; then
		git_head="unborn"
	fi

	jq -n \
		--arg summary "$reason" \
		--arg generatedAt "$(timestamp_utc)" \
		--arg gitHead "$git_head" \
		--argjson worktreeDirtyFiles "$dirty_json" \
		'{
			status: "infra_fail",
			summary: $summary,
			filesChanged: [],
			mechanicalChecks: [],
			addressedFindings: [],
			proposedCommit: {
				title: "",
				bodyBullets: []
			},
			learnings: [],
			generatedAt: $generatedAt,
			gitHead: $gitHead,
			worktreeDirtyFiles: $worktreeDirtyFiles
		}' >"$artifact_path"
}

extract_commit_json_path() {
	local eval_artifact_path="$1"
	local exec_artifact_path="$2"
	local mode
	mode="$(jq -r 'if has("approvedCommit") then "approved" else "fallback" end' "$eval_artifact_path")"
	if [[ "$mode" == "approved" ]]; then
		printf '%s\n' "$eval_artifact_path"
	else
		printf '%s\n' "$exec_artifact_path"
	fi
}

write_commit_message_file() {
	local source_json="$1"
	local message_file="$2"
	local title bullets_output
	title="$(jq -r 'if has("approvedCommit") then .approvedCommit.title else .proposedCommit.title end' "$source_json")"
	if [[ -z "$title" || "$title" == "null" ]]; then
		echo "Cannot create commit without a non-empty commit title." >&2
		return 1
	fi

	bullets_output="$(jq -r 'if has("approvedCommit") then .approvedCommit.bodyBullets[]? else .proposedCommit.bodyBullets[]? end' "$source_json")"

	{
		printf '%s\n' "$title"
		if [[ -n "$bullets_output" ]]; then
			printf '\n'
			while IFS= read -r bullet; do
				printf -- "- %s\n" "$bullet"
			done <<<"$bullets_output"
		fi
	} >"$message_file"
}

mark_story_passed() {
	local story_id="$1"
	local tmp_file
	tmp_file="$(mktemp)"
	jq --arg story_id "$story_id" '
		.userStories |= map(
			if .id == $story_id then
				. + { passes: true }
			else
				.
			end
		)
	' "$PRD_FILE" >"$tmp_file"
	mv "$tmp_file" "$PRD_FILE"
}

append_completed_story_entry() {
	local story_id="$1"
	local commit_sha="$2"
	local exec_artifact_path="$3"
	local eval_artifact_path="$4"
	local tmp_file
	tmp_file="$(mktemp)"
	jq \
		--arg storyId "$story_id" \
		--arg title "$(story_title "$story_id")" \
		--arg commitSha "$commit_sha" \
		--arg completedAt "$(timestamp_utc)" \
		--arg executionArtifactPath "$exec_artifact_path" \
		--arg evalArtifactPath "$eval_artifact_path" \
		--slurpfile mechanicalChecks "$exec_artifact_path" \
		--arg summary "$(jq -r '.summary' "$exec_artifact_path")" \
		'
		map(select(.storyId != $storyId))
		+ [{
			storyId: $storyId,
			title: $title,
			commitSha: $commitSha,
			completedAt: $completedAt,
			executionArtifactPath: $executionArtifactPath,
			evalArtifactPath: $evalArtifactPath,
			mechanicalChecks: ($mechanicalChecks[0].mechanicalChecks // []),
			summary: $summary
		}]
		' "$COMPLETED_STORIES_FILE" >"$tmp_file"
	mv "$tmp_file" "$COMPLETED_STORIES_FILE"
}

append_progress_entry() {
	local story_id="$1"
	local exec_artifact_path="$2"
	local eval_artifact_path="$3"
	local story_heading decision reason fix_count files_changed checks_summary learnings
	story_heading="$story_id - $(story_title "$story_id")"
	decision="$(jq -r '.verdictSummary.decision' "$eval_artifact_path")"
	reason="$(jq -r '.verdictSummary.primaryReason' "$eval_artifact_path")"
	fix_count="$(jq -r '.verdictSummary.requiredFixesCount' "$eval_artifact_path")"
	files_changed="$(jq -r 'if (.filesChanged | length) == 0 then "(none)" else (.filesChanged | join(", ")) end' "$exec_artifact_path")"
	checks_summary="$(jq -r 'if (.mechanicalChecks | length) == 0 then "(none)" else (.mechanicalChecks | map("\(.status): \(.command)") | join("; ")) end' "$exec_artifact_path")"
	learnings="$(jq -r 'if (.learnings | length) == 0 then "(none)" else (.learnings | join("; ")) end' "$exec_artifact_path")"

	{
		echo "## [$(timestamp_utc)] - $story_heading"
		echo "- What was implemented: $(jq -r '.summary' "$exec_artifact_path")"
		echo "- Validation that was run: $checks_summary"
		echo "- Files changed: $files_changed"
		echo "- semantic_eval_status: $(jq -r '.status' "$eval_artifact_path")"
		echo "- decision: $decision"
		echo "- primary_reason: $reason"
		echo "- required_fixes_count: $fix_count"
		echo "- Learnings for future iterations: $learnings"
		echo "---"
	} >>"$PROGRESS_FILE"
}

append_final_progress_entry() {
	local final_eval_artifact="$1"
	local final_commit_sha="$2"
	{
		echo "## [$(timestamp_utc)] - FINAL EVAL SUMMARY"
		echo "- final_eval_status: $(jq -r '.status' "$final_eval_artifact")"
		echo "- decision: $(jq -r '.verdictSummary.decision' "$final_eval_artifact")"
		echo "- primary_reason: $(jq -r '.verdictSummary.primaryReason' "$final_eval_artifact")"
		echo "- overall_drift_level: $(jq -r '.verdictSummary.overallDriftLevel' "$final_eval_artifact")"
		echo "- required_fixes_count: $(jq -r '.verdictSummary.requiredFixesCount' "$final_eval_artifact")"
		if [[ -n "$final_commit_sha" ]]; then
			echo "- final_commit_sha: $final_commit_sha"
		fi
		echo "---"
	} >>"$PROGRESS_FILE"
}

run_codex_purpose() {
	local purpose="$1"
	local prompt_file="$2"
	local run_dir="$3"
	local iteration_label="$4"
	local last_message_file="$run_dir/$iteration_label.last-message.txt"
	local temp_output="$last_message_file.run"
	local rc=0

	if "$SCRIPT_DIR/adapters/codex.sh" \
		--purpose "$purpose" \
		--repo-root "$ROOT_DIR" \
		--prompt-file "$prompt_file" \
		--run-dir "$run_dir" \
		--iteration "$iteration_label" >"$temp_output"; then
		rc=0
	else
		rc=$?
	fi

	if [[ -s "$temp_output" ]]; then
		echo
		echo "  Final $purpose message:"
		cat "$temp_output"
	fi
	rm -f "$temp_output"
	return "$rc"
}

final_eval_soft_fail_is_fixable() {
	local final_eval_artifact="$1"
	jq -e '
		(.status == "soft_fail")
		and ((.requiredFixes | length) > 0)
		and all(.requiredFixes[]; .kind == "implementation_fix")
	' "$final_eval_artifact" >/dev/null
}

process_story_iteration() {
	local story_id="$1"
	local story_iteration="$2"
	local run_dir="$3"
	local initial_phase="$4"
	local initial_fix_round="$5"
	local execution_artifact_path="$6"
	local eval_artifact_path="$7"
	local story_json phase fix_round

	story_json="$(selected_story_payload "$story_id")"
	phase="$initial_phase"
	fix_round="$initial_fix_round"

	if [[ -z "$phase" ]]; then
		phase="execute"
	fi

	if [[ "$phase" == "eval" && ( -z "$execution_artifact_path" || ! -f "$execution_artifact_path" ) ]]; then
		phase="execute"
	fi

	while true; do
		if [[ "$phase" == "execute" || "$phase" == "fix" ]]; then
			local exec_prefix exec_prompt exec_raw exec_label exec_rc exec_status prior_eval_path
			if [[ "$fix_round" -gt 0 ]]; then
				exec_label="$(printf 'iteration-%03d.fix-%02d.exec' "$story_iteration" "$fix_round")"
				prior_eval_path="$eval_artifact_path"
			else
				exec_label="$(printf 'iteration-%03d.exec' "$story_iteration")"
				prior_eval_path=""
			fi
			exec_prefix="$run_dir/$exec_label"
			exec_prompt="$exec_prefix.prompt.md"
			exec_raw="$exec_prefix.story-result.raw.json"
			execution_artifact_path="$exec_prefix.story-result.json"

			render_execution_prompt "$exec_prompt" "$story_json" "$story_iteration" "$fix_round" "$exec_raw" "$prior_eval_path"
			write_active_story_checkpoint "$story_id" "$story_iteration" "$phase" "$fix_round" "$run_dir" "$execution_artifact_path" "$eval_artifact_path"

			echo "  Running execution round for $story_id (fix_round=$fix_round)"
			if run_codex_purpose "execute" "$exec_prompt" "$run_dir" "$exec_label"; then
				exec_rc=0
			else
				exec_rc=$?
			fi

			if [[ "$exec_rc" -ne 0 ]]; then
				write_synthetic_execution_infra_artifact "$execution_artifact_path" "$story_id" "$story_iteration" "$fix_round" "execution runner failed before a trustworthy story artifact was produced"
				echo "  Execution runner failed. See $(relative_to_root "$run_dir/$exec_label.status.txt")." >&2
				return 1
			fi

			if [[ ! -f "$exec_raw" ]] || ! validate_execution_core "$exec_raw"; then
				write_synthetic_execution_infra_artifact "$execution_artifact_path" "$story_id" "$story_iteration" "$fix_round" "execution artifact missing or invalid"
				echo "  Execution artifact missing or invalid: $(relative_to_root "$exec_raw")" >&2
				return 1
			fi

			normalize_execution_artifact "$exec_raw" "$execution_artifact_path" "$story_id" "$story_iteration" "$fix_round"
			exec_status="$(jq -r '.status' "$execution_artifact_path")"

			case "$exec_status" in
			ok)
				phase="eval"
				;;
			mechanical_failed)
				echo "  Mechanical checks failed for $story_id. Stopping before semantic eval." >&2
				return 1
				;;
			infra_fail)
				echo "  Execution reported infra_fail for $story_id. Preserving state for manual inspection." >&2
				return 1
				;;
			*)
				echo "  Unsupported execution status: $exec_status" >&2
				return 1
				;;
			esac
		fi

		if [[ "$phase" == "eval" ]]; then
			local eval_attempt eval_label eval_prompt eval_message eval_rc eval_status wait_seconds
			eval_attempt=0
			while true; do
				if [[ "$fix_round" -gt 0 ]]; then
					eval_label="$(printf 'iteration-%03d.fix-%02d.eval' "$story_iteration" "$fix_round")"
				else
					eval_label="$(printf 'iteration-%03d.eval' "$story_iteration")"
				fi
				eval_prompt="$run_dir/$eval_label.prompt.md"
				eval_message="$run_dir/$eval_label.last-message.txt"
				eval_artifact_path="$run_dir/$eval_label.semantic-eval.json"

				render_eval_prompt "$eval_prompt" "$story_json" "$story_iteration" "$fix_round" "$execution_artifact_path"
				write_active_story_checkpoint "$story_id" "$story_iteration" "eval" "$fix_round" "$run_dir" "$execution_artifact_path" "$eval_artifact_path"

				echo "  Running semantic eval for $story_id (fix_round=$fix_round attempt=$((eval_attempt + 1)))"
				if run_codex_purpose "eval" "$eval_prompt" "$run_dir" "$eval_label"; then
					eval_rc=0
				else
					eval_rc=$?
				fi

				if [[ "$eval_rc" -ne 0 ]]; then
					write_synthetic_eval_infra_artifact "$eval_artifact_path" "$story_id" "$story_iteration" "$fix_round" "semantic evaluator runner failed before a trustworthy verdict was produced"
				elif [[ ! -f "$eval_message" ]] || ! validate_eval_core "$eval_message"; then
					write_synthetic_eval_infra_artifact "$eval_artifact_path" "$story_id" "$story_iteration" "$fix_round" "semantic evaluator output missing or invalid"
				else
					normalize_eval_artifact "$eval_message" "$eval_artifact_path" "$story_id" "$story_iteration" "$fix_round"
				fi

				eval_status="$(jq -r '.status' "$eval_artifact_path")"
				if [[ "$eval_status" == "infra_fail" && "$eval_attempt" -lt "$YAI_EVAL_MAX_RETRIES" ]]; then
					eval_attempt=$((eval_attempt + 1))
					wait_seconds=$((YAI_EVAL_RETRY_WAIT_SECONDS * eval_attempt))
					echo "  Semantic eval infra_fail. Retrying in ${wait_seconds}s..." >&2
					sleep "$wait_seconds"
					continue
				fi
				break
			done

			case "$eval_status" in
				pass)
					local commit_source commit_message_file story_commit_sha
					story_commit_sha=""
					commit_source="$(extract_commit_json_path "$eval_artifact_path" "$execution_artifact_path")"
					commit_message_file="$run_dir/$(printf 'iteration-%03d.commit-message.txt' "$story_iteration")"
					write_commit_message_file "$commit_source" "$commit_message_file"

					if [[ "$(dirty_worktree_count)" -eq 0 ]]; then
						echo "  No worktree changes remain for $story_id; recording a no-op semantic pass without creating an empty commit."
					else
						git -C "$ROOT_DIR" add -A -- .
						git -C "$ROOT_DIR" commit -F "$commit_message_file"
						story_commit_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
					fi

					append_completed_story_entry \
						"$story_id" \
						"$story_commit_sha" \
						"$execution_artifact_path" \
						"$eval_artifact_path"
				mark_story_passed "$story_id"
				append_progress_entry "$story_id" "$execution_artifact_path" "$eval_artifact_path"
				clear_active_story_checkpoint
				return 0
				;;
			soft_fail)
				if [[ "$fix_round" -ge "$YAI_SEMANTIC_MAX_FIX_ROUNDS" ]]; then
					echo "  Semantic eval exhausted fix rounds for $story_id." >&2
					write_active_story_checkpoint "$story_id" "$story_iteration" "fix" "$fix_round" "$run_dir" "$execution_artifact_path" "$eval_artifact_path"
					return 1
				fi
				fix_round=$((fix_round + 1))
				phase="fix"
				write_active_story_checkpoint "$story_id" "$story_iteration" "$phase" "$fix_round" "$run_dir" "$execution_artifact_path" "$eval_artifact_path"
				echo "  Semantic eval soft_fail. Entering fix round $fix_round for $story_id."
				continue
				;;
			hard_fail)
				echo "  Semantic eval hard_fail for $story_id. Preserving state for manual intervention." >&2
				write_active_story_checkpoint "$story_id" "$story_iteration" "eval" "$fix_round" "$run_dir" "$execution_artifact_path" "$eval_artifact_path"
				return 1
				;;
			infra_fail)
				echo "  Semantic eval infra_fail for $story_id after retries. Preserving state." >&2
				write_active_story_checkpoint "$story_id" "$story_iteration" "eval" "$fix_round" "$run_dir" "$execution_artifact_path" "$eval_artifact_path"
				return 1
				;;
			*)
				echo "  Unsupported eval status: $eval_status" >&2
				return 1
				;;
			esac
		fi
	done
}

process_final_phase() {
	local run_dir="$1"
	local initial_phase="$2"
	local initial_fix_round="$3"
	local final_fix_artifact_path="$4"
	local final_eval_artifact_path="$5"
	local phase fix_round

	phase="${initial_phase:-final_eval}"
	fix_round="${initial_fix_round:-0}"

	if [[ "$phase" != "final_eval" && "$phase" != "final_fix" ]]; then
		phase="final_eval"
	fi

	while true; do
		if [[ "$phase" == "final_fix" ]]; then
			local fix_label fix_prefix fix_prompt fix_raw fix_rc fix_status fix_mode
			fix_label="$(printf 'final.fix-%02d.exec' "$fix_round")"
			fix_prefix="$run_dir/$fix_label"
			fix_prompt="$fix_prefix.prompt.md"
			fix_raw="$fix_prefix.fix-result.raw.json"
			final_fix_artifact_path="$fix_prefix.fix-result.json"
			fix_mode="$(final_fix_mode_for_eval_artifact "$final_eval_artifact_path")"

			render_final_fix_prompt "$fix_prompt" "$final_eval_artifact_path" "$fix_raw" "$fix_round" "$fix_mode"
			write_active_story_checkpoint "FINAL" 0 "final_fix" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"

			echo "  Running final fix round $fix_round ($fix_mode)"
			if run_codex_purpose "execute" "$fix_prompt" "$run_dir" "$fix_label"; then
				fix_rc=0
			else
				fix_rc=$?
			fi

			if [[ "$fix_rc" -ne 0 ]]; then
				write_synthetic_final_fix_infra_artifact "$final_fix_artifact_path" "final fix runner failed before a trustworthy corrective artifact was produced"
				echo "  Final fix runner failed. See $(relative_to_root "$run_dir/$fix_label.status.txt")." >&2
				return 1
			fi

			if [[ ! -f "$fix_raw" ]] || ! validate_final_fix_core "$fix_raw"; then
				write_synthetic_final_fix_infra_artifact "$final_fix_artifact_path" "final fix artifact missing or invalid"
				echo "  Final fix artifact missing or invalid: $(relative_to_root "$fix_raw")" >&2
				return 1
			fi

			normalize_final_fix_artifact "$fix_raw" "$final_fix_artifact_path"
			fix_status="$(jq -r '.status' "$final_fix_artifact_path")"

			case "$fix_status" in
			ok)
				phase="final_eval"
				;;
			mechanical_failed)
				echo "  Final fix mechanical checks failed. Preserving state for manual inspection." >&2
				return 1
				;;
			infra_fail)
				echo "  Final fix reported infra_fail. Preserving state for manual inspection." >&2
				return 1
				;;
			*)
				echo "  Unsupported final fix status: $fix_status" >&2
				return 1
				;;
			esac
		fi

		if [[ "$phase" == "final_eval" ]]; then
			local eval_attempt eval_label eval_prompt eval_message eval_rc eval_status wait_seconds eval_canonical
			eval_attempt=0
			while true; do
				if [[ "$fix_round" -gt 0 ]]; then
					eval_label="$(printf 'final.fix-%02d.eval' "$fix_round")"
				else
					eval_label="final.eval"
				fi
				eval_prompt="$run_dir/$eval_label.prompt.md"
				eval_message="$run_dir/$eval_label.last-message.txt"
				final_eval_artifact_path="$run_dir/$eval_label.semantic-eval.json"
				eval_canonical="$run_dir/final.eval.semantic-eval.json"

				render_final_eval_prompt "$eval_prompt" "$final_eval_artifact_path"
				write_active_story_checkpoint "FINAL" 0 "final_eval" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"

				echo "  Running final eval (fix_round=$fix_round attempt=$((eval_attempt + 1)))"
				if run_codex_purpose "final-eval" "$eval_prompt" "$run_dir" "$eval_label"; then
					eval_rc=0
				else
					eval_rc=$?
				fi

				if [[ "$eval_rc" -ne 0 ]]; then
					write_synthetic_final_eval_infra_artifact "$final_eval_artifact_path" "final evaluator runner failed before a trustworthy verdict was produced"
				elif [[ ! -f "$eval_message" ]] || ! validate_final_eval_core "$eval_message"; then
					write_synthetic_final_eval_infra_artifact "$final_eval_artifact_path" "final evaluator output missing or invalid"
				else
					normalize_final_eval_artifact "$eval_message" "$final_eval_artifact_path"
				fi

				if [[ "$final_eval_artifact_path" != "$eval_canonical" ]]; then
					cp "$final_eval_artifact_path" "$eval_canonical"
				fi

				eval_status="$(jq -r '.status' "$final_eval_artifact_path")"
				if [[ "$eval_status" == "infra_fail" && "$eval_attempt" -lt "$YAI_FINAL_EVAL_MAX_RETRIES" ]]; then
					eval_attempt=$((eval_attempt + 1))
					wait_seconds=$((YAI_FINAL_EVAL_RETRY_WAIT_SECONDS * eval_attempt))
					echo "  Final eval infra_fail. Retrying in ${wait_seconds}s..." >&2
					sleep "$wait_seconds"
					continue
				fi
				break
			done

			case "$eval_status" in
			pass)
				local final_commit_sha commit_source commit_message_file
				final_commit_sha=""
				if [[ "$(dirty_worktree_count)" -gt 0 ]]; then
					if [[ "$fix_round" -eq 0 ]]; then
						echo "  Final eval passed, but the worktree became dirty outside a final corrective round." >&2
						show_dirty_worktree_summary >&2 || true
						echo "  Clean or stash those files and rerun yai." >&2
						echo "  If this exact diff is intentionally part of the reviewed final state, adopt it explicitly:" >&2
						echo "    ./scripts/yai.sh --state-dir $(relative_to_root "$STATE_DIR") --adopt-dirty-worktree FINAL --yes" >&2
						write_active_story_checkpoint "FINAL" 0 "final_eval" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"
						return 1
					fi
					commit_source="$(extract_commit_json_path "$final_eval_artifact_path" "$final_fix_artifact_path")"
					commit_message_file="$run_dir/$(printf 'final.fix-%02d.commit-message.txt' "$fix_round")"
					write_commit_message_file "$commit_source" "$commit_message_file"
					git -C "$ROOT_DIR" add -A -- .
					git -C "$ROOT_DIR" commit -F "$commit_message_file"
					final_commit_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
				fi
				append_final_progress_entry "$final_eval_artifact_path" "$final_commit_sha"
				clear_active_story_checkpoint
				return 0
				;;
			soft_fail)
				if ! final_eval_soft_fail_is_fixable "$final_eval_artifact_path"; then
					echo "  Final eval soft_fail included non-implementation fixes; treating as hard stop." >&2
					write_active_story_checkpoint "FINAL" 0 "final_eval" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"
					return 1
				fi
				if [[ "$fix_round" -ge "$YAI_FINAL_FIX_MAX_ROUNDS" ]]; then
					echo "  Final eval exhausted corrective rounds." >&2
					write_active_story_checkpoint "FINAL" 0 "final_fix" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"
					return 1
				fi
				fix_round=$((fix_round + 1))
				phase="final_fix"
				write_active_story_checkpoint "FINAL" 0 "$phase" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"
				echo "  Final eval soft_fail. Entering final fix round $fix_round."
				continue
				;;
			hard_fail)
				echo "  Final eval hard_fail. Preserving state for manual intervention." >&2
				write_active_story_checkpoint "FINAL" 0 "final_eval" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"
				return 1
				;;
			infra_fail)
				echo "  Final eval infra_fail after retries. Preserving state." >&2
				write_active_story_checkpoint "FINAL" 0 "final_eval" "$fix_round" "$run_dir" "$final_fix_artifact_path" "$final_eval_artifact_path" "final"
				return 1
				;;
			*)
				echo "  Unsupported final eval status: $eval_status" >&2
				return 1
				;;
			esac
		fi
	done
}

show_run_banner() {
	local run_dir="$1"
	echo "Starting yai"
	echo "  Tool: $TOOL"
	echo "  Max iterations: $MAX_ITERATIONS"
	echo "  State dir: $(relative_to_root "$STATE_DIR")"
	echo "  Stories in PRD: $(total_story_count)"
	echo "  Pending stories: $(pending_story_count)"
	echo "  Run cap applies to this launch only; rerun yai if stories remain."
	echo "  Run dir: $(relative_to_root "$run_dir")"
}

main() {
	ensure_prereqs
	ensure_state_layout
	init_progress_file
	init_completed_stories_file

	if [[ ! -f "$PRD_FILE" ]]; then
		show_missing_prd_help
		exit 1
	fi
	ensure_prd_source_exists
	backfill_completed_stories_file

	track_current_branch
	ensure_story_context

	if [[ "$(pending_story_count)" -eq 0 ]]; then
		if [[ -f "$ACTIVE_STORY_FILE" && "$(jq -r '.scope // "story"' "$ACTIVE_STORY_FILE")" == "story" ]]; then
			clear_active_story_checkpoint
		fi
		if [[ ! -f "$ACTIVE_STORY_FILE" ]] && latest_final_eval_passed; then
			echo "yai state already complete."
			archive_current_state "already_completed"
			echo "<promise>COMPLETE</promise>"
			echo "Progress log: $(relative_to_root "$PROGRESS_FILE")"
			print_run_elapsed_time
			exit 0
		fi
	fi

	local run_id run_dir
	run_id="$(date -u +%Y%m%dT%H%M%SZ)"
	run_dir="$RUNS_DIR/$run_id"
	mkdir -p "$run_dir"
	printf '%s\n' "$run_dir" >"$LAST_RUN_FILE"

	show_run_banner "$run_dir"

	local i resumed_existing_story=0
	for i in $(seq 1 "$MAX_ITERATIONS"); do
		local story_id story_phase fix_round execution_artifact_path eval_artifact_path active_scope

		echo
		echo "==============================================================="
		echo "  yai Story Iteration $i of $MAX_ITERATIONS ($TOOL)"
		echo "==============================================================="
		echo "  Pending stories before story iteration: $(pending_story_count)"

		if [[ -f "$ACTIVE_STORY_FILE" && "$resumed_existing_story" -eq 0 ]]; then
			active_scope="$(jq -r '.scope // "story"' "$ACTIVE_STORY_FILE")"
			if [[ "$active_scope" == "final" ]]; then
				echo "  Resuming final-phase checkpoint."
				if ! process_final_phase \
					"$run_dir" \
					"$(jq -r '.phase' "$ACTIVE_STORY_FILE")" \
					"$(jq -r '.fixRound // 0' "$ACTIVE_STORY_FILE")" \
					"$(jq -r '.executionArtifactPath // ""' "$ACTIVE_STORY_FILE")" \
					"$(jq -r '.evalArtifactPath // ""' "$ACTIVE_STORY_FILE")"; then
					echo "yai stopped during final eval." >&2
					echo "Progress log: $(relative_to_root "$PROGRESS_FILE")" >&2
					echo "Run logs: $(relative_to_root "$run_dir")" >&2
					exit 1
				fi
				archive_current_state "completed"
				echo "yai completed all tasks."
				echo "<promise>COMPLETE</promise>"
				echo "Completed after final evaluation."
				echo "Progress log: $(relative_to_root "$PROGRESS_FILE")"
				echo "Run logs: $(relative_to_root "$run_dir")"
				print_run_elapsed_time
				exit 0
			fi
			story_id="$(jq -r '.storyId' "$ACTIVE_STORY_FILE")"
			story_phase="$(jq -r '.phase' "$ACTIVE_STORY_FILE")"
			fix_round="$(jq -r '.fixRound // 0' "$ACTIVE_STORY_FILE")"
			execution_artifact_path="$(jq -r '.executionArtifactPath // ""' "$ACTIVE_STORY_FILE")"
			eval_artifact_path="$(jq -r '.evalArtifactPath // ""' "$ACTIVE_STORY_FILE")"
			resumed_existing_story=1
			if ! story_exists_pending "$story_id"; then
				echo "  Active story checkpoint is stale for $story_id; clearing it."
				clear_active_story_checkpoint
				story_id=""
			else
				echo "  Resuming active story checkpoint: $story_id (phase=$story_phase fix_round=$fix_round)"
			fi
		else
			story_id="$(next_pending_story_id)"
			if [[ -z "$story_id" ]]; then
				if ! process_final_phase "$run_dir" "final_eval" 0 "" ""; then
					echo "yai stopped during final eval." >&2
					echo "Progress log: $(relative_to_root "$PROGRESS_FILE")" >&2
					echo "Run logs: $(relative_to_root "$run_dir")" >&2
					exit 1
				fi
				echo
				archive_current_state "completed"
				echo "yai completed all tasks."
				echo "<promise>COMPLETE</promise>"
				echo "Completed after final evaluation."
				echo "Progress log: $(relative_to_root "$PROGRESS_FILE")"
				echo "Run logs: $(relative_to_root "$run_dir")"
				print_run_elapsed_time
				exit 0
			fi
			story_phase="execute"
			fix_round=0
			execution_artifact_path=""
			eval_artifact_path=""
			echo "  Selected story: $story_id - $(story_title "$story_id")"
		fi

		if [[ -z "$story_id" ]]; then
			story_id="$(next_pending_story_id)"
			story_phase="execute"
			fix_round=0
			execution_artifact_path=""
			eval_artifact_path=""
			if [[ -z "$story_id" ]]; then
				continue
			fi
			echo "  Selected story: $story_id - $(story_title "$story_id")"
		fi

		if ! process_story_iteration "$story_id" "$i" "$run_dir" "$story_phase" "$fix_round" "$execution_artifact_path" "$eval_artifact_path"; then
			echo "yai stopped while processing story $story_id." >&2
			echo "Progress log: $(relative_to_root "$PROGRESS_FILE")" >&2
			echo "Run logs: $(relative_to_root "$run_dir")" >&2
			exit 1
		fi

		if [[ "$(pending_story_count)" -eq 0 ]]; then
			echo
			if ! process_final_phase "$run_dir" "final_eval" 0 "" ""; then
				echo "yai stopped during final eval." >&2
				echo "Progress log: $(relative_to_root "$PROGRESS_FILE")" >&2
				echo "Run logs: $(relative_to_root "$run_dir")" >&2
				exit 1
			fi
			archive_current_state "completed"
			echo "yai completed all tasks."
			echo "<promise>COMPLETE</promise>"
			echo "Completed after final evaluation at story iteration $i of $MAX_ITERATIONS"
			echo "Progress log: $(relative_to_root "$PROGRESS_FILE")"
			echo "Run logs: $(relative_to_root "$run_dir")"
			print_run_elapsed_time
			exit 0
		fi

		echo "Story iteration $i complete. Continuing..."
		sleep 2
	done

	echo
	echo "yai reached max iterations ($MAX_ITERATIONS) with $(pending_story_count) pending stories still in $(relative_to_root "$PRD_FILE")."
	echo "This run cap applies to stories in this launch only."
	echo "It does not limit how many stories may exist in prd.json."
	echo "Rerun \`just yai\` to continue, or pass a larger iteration cap for this launch."
	echo "Progress log: $(relative_to_root "$PROGRESS_FILE")"
	echo "Run logs: $(relative_to_root "$run_dir")"
	print_run_elapsed_time
	exit 1
}

main "$@"
