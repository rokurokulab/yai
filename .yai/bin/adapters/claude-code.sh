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
  bash .yai/bin/adapters/claude-code.sh --purpose <execute|eval|final-eval> --repo-root <path> --prompt-file <path> --run-dir <path> --iteration <label>

Environment:
  Shared:
    YAI_CC_BIN                   Claude Code executable (default: claude)

  Execution:
    YAI_CC_MODEL                 Optional model override (alias like 'sonnet' / 'opus' or full id)
    YAI_CC_PERMISSION_MODE       Permission mode (default: dontAsk)
    YAI_CC_ALLOWED_TOOLS         Comma/space-separated allowed tools
                                 (default: Bash,Read,Edit,Write,Glob,Grep)
    YAI_CC_ARGS                  Extra shell-split args appended before stdin
                                 (e.g. "--bare" for strict CI isolation with ANTHROPIC_API_KEY)
    YAI_CC_TIMEOUT_SECONDS       Hard timeout for one attempt (default: 3600)
    YAI_CC_MAX_RETRIES           Retry count after the initial failed attempt (default: 10)
    YAI_CC_RETRY_WAIT_SECONDS    Base wait before retrying a retryable failure (default: 15)
    YAI_CC_TERM_GRACE_SECONDS    Grace between TERM and KILL on timeout (default: 10)

  Eval:
    YAI_CC_EVAL_MODEL            Optional evaluator model override
    YAI_CC_EVAL_PERMISSION_MODE  Evaluator permission mode (default: dontAsk)
    YAI_CC_EVAL_ALLOWED_TOOLS    Evaluator tool list (default: Read,Glob,Grep,Bash)
    YAI_CC_EVAL_ARGS             Extra shell-split evaluator args
    YAI_CC_EVAL_TIMEOUT_SECONDS  Hard timeout for one evaluator attempt (default: 3600)
    YAI_CC_EVAL_RETRY_WAIT_SECONDS
                                 Base wait before retrying a retryable evaluator failure (default: 15)
    YAI_CC_EVAL_TERM_GRACE_SECONDS
                                 Grace period between TERM and KILL on evaluator timeout (default: 10)
    YAI_CC_EVAL_RUNNER_MAX_RETRIES
                                 Runner retry count for evaluator transport failures (default: 3)

  Final eval:
    YAI_CC_FINAL_EVAL_MODEL            Optional final evaluator model override
    YAI_CC_FINAL_EVAL_PERMISSION_MODE  Final evaluator permission mode (default: dontAsk)
    YAI_CC_FINAL_EVAL_ALLOWED_TOOLS    Final evaluator tool list (default: Read,Glob,Grep,Bash)
    YAI_CC_FINAL_EVAL_ARGS             Extra shell-split final evaluator args
    YAI_CC_FINAL_EVAL_TIMEOUT_SECONDS  Hard timeout for one final evaluator attempt (default: 3600)
    YAI_CC_FINAL_EVAL_RETRY_WAIT_SECONDS
                                       Base wait before retrying a retryable final evaluator failure (default: 15)
    YAI_CC_FINAL_EVAL_TERM_GRACE_SECONDS
                                       Grace period between TERM and KILL on final evaluator timeout (default: 10)
    YAI_CC_FINAL_EVAL_RUNNER_MAX_RETRIES
                                       Runner retry count for final evaluator transport failures (default: 3)

Behavior:
  - Writes per-attempt JSONL and stderr logs under <run-dir>
  - Mirrors the last attempt to <run-dir>/<iteration>.events.jsonl and .stderr.log
  - Writes the final assistant message to <run-dir>/<iteration>.last-message.txt
  - Writes runner state to <run-dir>/<iteration>.status.txt
  - Prints only the final assistant message to stdout
EOF
}

REPO_ROOT=""
PROMPT_FILE=""
RUN_DIR=""
ITERATION=""
PURPOSE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--purpose)
		PURPOSE="$2"
		shift 2
		;;
	--purpose=*)
		PURPOSE="${1#*=}"
		shift
		;;
	--repo-root)
		REPO_ROOT="$2"
		shift 2
		;;
	--prompt-file)
		PROMPT_FILE="$2"
		shift 2
		;;
	--run-dir)
		RUN_DIR="$2"
		shift 2
		;;
	--iteration)
		ITERATION="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

if [[ -z "$PURPOSE" || -z "$REPO_ROOT" || -z "$PROMPT_FILE" || -z "$RUN_DIR" || -z "$ITERATION" ]]; then
	echo "missing required arguments" >&2
	usage >&2
	exit 1
fi

if [[ "$PURPOSE" != "execute" && "$PURPOSE" != "eval" && "$PURPOSE" != "final-eval" ]]; then
	echo "unsupported purpose: $PURPOSE" >&2
	exit 1
fi

CC_BIN="${YAI_CC_BIN:-claude}"

if [[ "$PURPOSE" == "execute" ]]; then
	CC_MODEL="${YAI_CC_MODEL:-}"
	CC_PERMISSION_MODE="${YAI_CC_PERMISSION_MODE:-dontAsk}"
	CC_ALLOWED_TOOLS="${YAI_CC_ALLOWED_TOOLS:-Bash,Read,Edit,Write,Glob,Grep}"
	CC_ARGS="${YAI_CC_ARGS:-}"
	CC_TIMEOUT_SECONDS="${YAI_CC_TIMEOUT_SECONDS:-3600}"
	CC_MAX_RETRIES="${YAI_CC_MAX_RETRIES:-10}"
	CC_RETRY_WAIT_SECONDS="${YAI_CC_RETRY_WAIT_SECONDS:-15}"
	CC_TERM_GRACE_SECONDS="${YAI_CC_TERM_GRACE_SECONDS:-10}"
elif [[ "$PURPOSE" == "eval" ]]; then
	CC_MODEL="${YAI_CC_EVAL_MODEL:-${YAI_CC_MODEL:-}}"
	CC_PERMISSION_MODE="${YAI_CC_EVAL_PERMISSION_MODE:-dontAsk}"
	CC_ALLOWED_TOOLS="${YAI_CC_EVAL_ALLOWED_TOOLS:-Read,Glob,Grep,Bash}"
	CC_ARGS="${YAI_CC_EVAL_ARGS:-}"
	CC_TIMEOUT_SECONDS="${YAI_CC_EVAL_TIMEOUT_SECONDS:-3600}"
	CC_MAX_RETRIES="${YAI_CC_EVAL_RUNNER_MAX_RETRIES:-3}"
	CC_RETRY_WAIT_SECONDS="${YAI_CC_EVAL_RETRY_WAIT_SECONDS:-15}"
	CC_TERM_GRACE_SECONDS="${YAI_CC_EVAL_TERM_GRACE_SECONDS:-10}"
else
	CC_MODEL="${YAI_CC_FINAL_EVAL_MODEL:-${YAI_CC_EVAL_MODEL:-${YAI_CC_MODEL:-}}}"
	CC_PERMISSION_MODE="${YAI_CC_FINAL_EVAL_PERMISSION_MODE:-${YAI_CC_EVAL_PERMISSION_MODE:-dontAsk}}"
	CC_ALLOWED_TOOLS="${YAI_CC_FINAL_EVAL_ALLOWED_TOOLS:-${YAI_CC_EVAL_ALLOWED_TOOLS:-Read,Glob,Grep,Bash}}"
	CC_ARGS="${YAI_CC_FINAL_EVAL_ARGS:-${YAI_CC_EVAL_ARGS:-}}"
	CC_TIMEOUT_SECONDS="${YAI_CC_FINAL_EVAL_TIMEOUT_SECONDS:-3600}"
	CC_MAX_RETRIES="${YAI_CC_FINAL_EVAL_RUNNER_MAX_RETRIES:-3}"
	CC_RETRY_WAIT_SECONDS="${YAI_CC_FINAL_EVAL_RETRY_WAIT_SECONDS:-15}"
	CC_TERM_GRACE_SECONDS="${YAI_CC_FINAL_EVAL_TERM_GRACE_SECONDS:-10}"
fi

if ! command -v "$CC_BIN" >/dev/null 2>&1; then
	echo "missing Claude Code CLI: $CC_BIN" >&2
	exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "missing required command: jq (needed to parse claude stream-json output)" >&2
	exit 127
fi

ensure_uint() {
	local label="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		echo "$label must be an unsigned integer, got: $value" >&2
		exit 2
	fi
}

ensure_uint "CC_TIMEOUT_SECONDS" "$CC_TIMEOUT_SECONDS"
ensure_uint "CC_MAX_RETRIES" "$CC_MAX_RETRIES"
ensure_uint "CC_RETRY_WAIT_SECONDS" "$CC_RETRY_WAIT_SECONDS"
ensure_uint "CC_TERM_GRACE_SECONDS" "$CC_TERM_GRACE_SECONDS"

mkdir -p "$RUN_DIR"

EVENT_LOG="$RUN_DIR/$ITERATION.events.jsonl"
STDERR_LOG="$RUN_DIR/$ITERATION.stderr.log"
LAST_MESSAGE_FILE="$RUN_DIR/$ITERATION.last-message.txt"
STATUS_FILE="$RUN_DIR/$ITERATION.status.txt"
TOTAL_ATTEMPTS=$((CC_MAX_RETRIES + 1))

rm -f "$EVENT_LOG" "$STDERR_LOG" "$LAST_MESSAGE_FILE" "$STATUS_FILE"

# claude-code has no -C flag; wrap in a shell that cds into the repo root
# before exec-ing claude. bash -c keeps the whole thing as a single argv
# for run_with_timeout.
#
# Note: --bare is NOT set by default. With --bare, claude skips OAuth/keychain
# reads and requires ANTHROPIC_API_KEY, which breaks interactive-logged-in
# workflows. Users who want strict CI isolation can set:
#   YAI_CC_ARGS="--bare" and ANTHROPIC_API_KEY=...
inner_cmd=(
	"$CC_BIN"
	-p
	--permission-mode "$CC_PERMISSION_MODE"
	--output-format stream-json
	--verbose
	--include-partial-messages
	--allowedTools "$CC_ALLOWED_TOOLS"
)

if [[ -n "$CC_MODEL" ]]; then
	inner_cmd+=(--model "$CC_MODEL")
fi

if [[ -n "$CC_ARGS" ]]; then
	read -r -a cc_extra_args <<<"$CC_ARGS"
	inner_cmd+=("${cc_extra_args[@]}")
fi

# shellcheck disable=SC2016 # single-quoted intentionally; $1/$@ expand in the invoked bash
cmd=(bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$REPO_ROOT" "${inner_cmd[@]}")

timestamp_utc() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

write_status() {
	local state="$1"
	local attempt="$2"
	local exit_code="$3"
	local classification="$4"
	local detail="$5"

	cat >"$STATUS_FILE" <<EOF
purpose=$PURPOSE
iteration=$ITERATION
state=$state
attempt=$attempt
total_attempts=$TOTAL_ATTEMPTS
timeout_seconds=$CC_TIMEOUT_SECONDS
max_retries=$CC_MAX_RETRIES
started_at=${RUNNER_STARTED_AT:-}
updated_at=$(timestamp_utc)
exit_code=$exit_code
classification=$classification
detail=$detail
event_log=$(basename "$EVENT_LOG")
stderr_log=$(basename "$STDERR_LOG")
last_message_file=$(basename "$LAST_MESSAGE_FILE")
EOF
}

terminate_pid_tree() {
	local pid="$1"
	local signal="$2"
	if command -v pkill >/dev/null 2>&1; then
		pkill "-$signal" -P "$pid" 2>/dev/null || true
	fi
	kill "-$signal" "$pid" 2>/dev/null || true
}

run_with_timeout() {
	local stdin_file="$1"
	local timeout_seconds="$2"
	local stdout_file="$3"
	local stderr_file="$4"
	shift 4

	"$@" <"$stdin_file" >"$stdout_file" 2>"$stderr_file" &
	local pid=$!
	local start_epoch now_epoch
	start_epoch="$(date +%s)"

	while kill -0 "$pid" 2>/dev/null; do
		now_epoch="$(date +%s)"
		if (( now_epoch - start_epoch >= timeout_seconds )); then
			printf 'yai runner timeout after %ss\n' "$timeout_seconds" >>"$stderr_file"
			terminate_pid_tree "$pid" TERM
			sleep "$CC_TERM_GRACE_SECONDS"
			if kill -0 "$pid" 2>/dev/null; then
				printf 'yai runner escalated to SIGKILL after %ss grace\n' "$CC_TERM_GRACE_SECONDS" >>"$stderr_file"
				terminate_pid_tree "$pid" KILL
			fi
			wait "$pid" 2>/dev/null || true
			return 124
		fi
		sleep 1
	done

	wait "$pid"
}

# Extract the final assistant message from a stream-json events file.
# Claude Code emits a terminal `{"type":"result","result":"...","subtype":"success|...",...}`
# line on successful completion. Fall back to concatenating assistant text blocks if no
# result record is present (e.g. partial stream on failure).
extract_last_message() {
	local events_file="$1"
	local output_file="$2"
	local result
	result="$(jq -r 'select(.type == "result") | .result // empty' "$events_file" 2>/dev/null | tail -n 1 || true)"
	if [[ -n "$result" && "$result" != "null" ]]; then
		printf '%s' "$result" >"$output_file"
		return 0
	fi
	# Fallback: aggregate any assistant-authored text blocks from the stream.
	jq -r '
		select(.type == "assistant") |
		.message.content[]? |
		select(.type == "text") |
		.text // empty
	' "$events_file" 2>/dev/null >"$output_file" || true
	if [[ -s "$output_file" ]]; then
		return 0
	fi
	return 1
}

failure_excerpt() {
	local stderr_file="$1"
	local event_file="$2"
	local excerpt
	excerpt="$(
		{
			tail -n 25 "$stderr_file" 2>/dev/null
			tail -n 10 "$event_file" 2>/dev/null
		} | sed '/^[[:space:]]*$/d' | tail -n 8 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g'
	)"
	if [[ -z "$excerpt" ]]; then
		excerpt="no runner detail captured"
	fi
	printf '%s\n' "$excerpt"
}

classify_failure() {
	local rc="$1"
	local stderr_file="$2"
	local event_file="$3"

	if [[ "$rc" -eq 124 ]]; then
		printf 'timeout\n'
		return
	fi

	local haystack
	haystack="$(
		{
			tail -n 60 "$stderr_file" 2>/dev/null
			tail -n 40 "$event_file" 2>/dev/null
		} | tr '[:upper:]' '[:lower:]'
	)"

	# Terminal failures we should NOT retry (auth / quota / input validation).
	if grep -Eiq 'not logged in|invalid api key|authentication failed|session limit|hit your session limit|prompt is too long|max turns reached|max budget|context window' <<<"$haystack"; then
		printf 'terminal_failure\n'
		return
	fi

	if grep -Eiq 'rate limit|request rejected \(429\)|429|overloaded|timed out|timeout|service unavailable|temporarily unavailable|502|503|504|network|connection reset|tls|stream disconnected|api error: 5' <<<"$haystack"; then
		printf 'retryable_transport\n'
		return
	fi

	printf 'terminal_failure\n'
}

sync_last_attempt_artifacts() {
	local attempt_event="$1"
	local attempt_stderr="$2"
	local attempt_last_message="$3"
	if [[ -f "$attempt_event" ]]; then
		cp "$attempt_event" "$EVENT_LOG"
	fi
	if [[ -f "$attempt_stderr" ]]; then
		cp "$attempt_stderr" "$STDERR_LOG"
	fi
	if [[ -f "$attempt_last_message" ]]; then
		cp "$attempt_last_message" "$LAST_MESSAGE_FILE"
	fi
}

echo "  claude-code runner: $CC_BIN" >&2
echo "  Purpose: $PURPOSE" >&2
echo "  claude-code event log: $EVENT_LOG" >&2
echo "  claude-code stderr log: $STDERR_LOG" >&2
echo "  claude-code last message: $LAST_MESSAGE_FILE" >&2
echo "  claude-code timeout (s): $CC_TIMEOUT_SECONDS" >&2
echo "  claude-code max retries: $CC_MAX_RETRIES" >&2
echo "  claude-code permission-mode: $CC_PERMISSION_MODE" >&2
echo "  claude-code allowed tools: $CC_ALLOWED_TOOLS" >&2

RUNNER_STARTED_AT="$(timestamp_utc)"
write_status "running" 0 0 "starting" "preparing claude-code runner"

attempt=1
while (( attempt <= TOTAL_ATTEMPTS )); do
	attempt_event="$RUN_DIR/$ITERATION.attempt-$attempt.events.jsonl"
	attempt_stderr="$RUN_DIR/$ITERATION.attempt-$attempt.stderr.log"
	attempt_last_message="$RUN_DIR/$ITERATION.attempt-$attempt.last-message.txt"
	rm -f "$attempt_event" "$attempt_stderr" "$attempt_last_message"

	echo "  claude-code attempt $attempt of $TOTAL_ATTEMPTS" >&2
	write_status "running" "$attempt" 0 "starting_attempt" "starting claude-code attempt $attempt"

	if run_with_timeout "$PROMPT_FILE" "$CC_TIMEOUT_SECONDS" "$attempt_event" "$attempt_stderr" "${cmd[@]}"; then
		rc=0
	else
		rc=$?
	fi

	# Claude Code writes the assistant message to the stream; extract it.
	if [[ "$rc" -eq 0 && -s "$attempt_event" ]]; then
		if ! extract_last_message "$attempt_event" "$attempt_last_message"; then
			echo "  claude-code attempt $attempt: stream succeeded but no final message parsed" >&2
			rc=65
		fi
	fi

	sync_last_attempt_artifacts "$attempt_event" "$attempt_stderr" "$attempt_last_message"

	if [[ "$rc" -eq 0 ]]; then
		write_status "succeeded" "$attempt" 0 "success" "claude-code attempt succeeded"
		if [[ -s "$LAST_MESSAGE_FILE" ]]; then
			cat "$LAST_MESSAGE_FILE"
		fi
		exit 0
	fi

	classification="$(classify_failure "$rc" "$attempt_stderr" "$attempt_event")"
	detail="$(failure_excerpt "$attempt_stderr" "$attempt_event")"
	write_status "failed_attempt" "$attempt" "$rc" "$classification" "$detail"
	echo "  claude-code attempt $attempt failed: rc=$rc classification=$classification" >&2
	echo "  Runner detail: $detail" >&2

	if [[ "$attempt" -lt "$TOTAL_ATTEMPTS" && ( "$classification" == "timeout" || "$classification" == "retryable_transport" ) ]]; then
		wait_seconds=$((CC_RETRY_WAIT_SECONDS * attempt))
		write_status "retrying" "$attempt" "$rc" "$classification" "retrying in ${wait_seconds}s"
		echo "  Retrying in ${wait_seconds}s..." >&2
		sleep "$wait_seconds"
		attempt=$((attempt + 1))
		continue
	fi

	write_status "failed" "$attempt" "$rc" "$classification" "$detail"
	if [[ -s "$LAST_MESSAGE_FILE" ]]; then
		cat "$LAST_MESSAGE_FILE"
	fi
	exit "$rc"
done

write_status "failed" "$TOTAL_ATTEMPTS" 1 "exhausted" "runner exited without a successful attempt"
exit 1
