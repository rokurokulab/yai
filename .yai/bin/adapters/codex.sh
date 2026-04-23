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
  bash .yai/bin/adapters/codex.sh --purpose <execute|eval|final-eval> --repo-root <path> --prompt-file <path> --run-dir <path> --iteration <label>

Environment:
  Shared:
    YAI_CODEX_BIN              Codex executable to run (default: codex)

  Execution:
    YAI_CODEX_MODEL            Optional model override
    YAI_CODEX_PROFILE          Optional Codex profile name
    YAI_CODEX_SANDBOX          Codex sandbox mode (default: workspace-write)
    YAI_CODEX_APPROVAL         Codex approval policy (default: never)
    YAI_CODEX_ARGS             Extra shell-split args appended before the prompt
    YAI_CODEX_TIMEOUT_SECONDS  Hard timeout for one Codex attempt (default: 3600)
    YAI_CODEX_MAX_RETRIES      Retry count after the initial failed attempt (default: 10)
    YAI_CODEX_RETRY_WAIT_SECONDS
                                 Base wait before retrying a retryable failure (default: 15)
    YAI_CODEX_TERM_GRACE_SECONDS
                                 Grace period between TERM and KILL on timeout (default: 10)

  Eval:
    YAI_EVAL_MODEL             Optional evaluator model override
    YAI_EVAL_PROFILE           Optional evaluator Codex profile name
    YAI_EVAL_SANDBOX           Evaluator sandbox mode (default: read-only)
    YAI_EVAL_APPROVAL          Evaluator approval policy (default: never)
    YAI_EVAL_ARGS              Extra shell-split evaluator args
    YAI_EVAL_TIMEOUT_SECONDS   Hard timeout for one evaluator attempt (default: 3600)
    YAI_EVAL_RETRY_WAIT_SECONDS
                                 Base wait before retrying a retryable evaluator failure (default: 15)
    YAI_EVAL_TERM_GRACE_SECONDS
                                 Grace period between TERM and KILL on evaluator timeout (default: 10)
    YAI_EVAL_RUNNER_MAX_RETRIES
                                 Runner retry count for evaluator transport failures (default: 3)

  Final eval:
    YAI_FINAL_EVAL_MODEL             Optional final evaluator model override
    YAI_FINAL_EVAL_PROFILE           Optional final evaluator Codex profile name
    YAI_FINAL_EVAL_SANDBOX           Final evaluator sandbox mode (default: read-only)
    YAI_FINAL_EVAL_APPROVAL          Final evaluator approval mode (default: never)
    YAI_FINAL_EVAL_ARGS              Extra shell-split final evaluator args
    YAI_FINAL_EVAL_TIMEOUT_SECONDS   Hard timeout for one final evaluator attempt (default: 3600)
    YAI_FINAL_EVAL_RETRY_WAIT_SECONDS
                                       Base wait before retrying a retryable final evaluator failure (default: 15)
    YAI_FINAL_EVAL_TERM_GRACE_SECONDS
                                       Grace period between TERM and KILL on final evaluator timeout (default: 10)
    YAI_FINAL_EVAL_RUNNER_MAX_RETRIES
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

CODEX_BIN="${YAI_CODEX_BIN:-codex}"

if [[ "$PURPOSE" == "execute" ]]; then
	CODEX_MODEL="${YAI_CODEX_MODEL:-}"
	CODEX_PROFILE="${YAI_CODEX_PROFILE:-}"
	CODEX_SANDBOX="${YAI_CODEX_SANDBOX:-workspace-write}"
	CODEX_APPROVAL="${YAI_CODEX_APPROVAL:-never}"
	CODEX_ARGS="${YAI_CODEX_ARGS:-}"
	CODEX_TIMEOUT_SECONDS="${YAI_CODEX_TIMEOUT_SECONDS:-3600}"
	CODEX_MAX_RETRIES="${YAI_CODEX_MAX_RETRIES:-10}"
	CODEX_RETRY_WAIT_SECONDS="${YAI_CODEX_RETRY_WAIT_SECONDS:-15}"
	CODEX_TERM_GRACE_SECONDS="${YAI_CODEX_TERM_GRACE_SECONDS:-10}"
elif [[ "$PURPOSE" == "eval" ]]; then
	CODEX_MODEL="${YAI_EVAL_MODEL:-${YAI_CODEX_MODEL:-}}"
	CODEX_PROFILE="${YAI_EVAL_PROFILE:-${YAI_CODEX_PROFILE:-}}"
	CODEX_SANDBOX="${YAI_EVAL_SANDBOX:-read-only}"
	CODEX_APPROVAL="${YAI_EVAL_APPROVAL:-never}"
	CODEX_ARGS="${YAI_EVAL_ARGS:-}"
	CODEX_TIMEOUT_SECONDS="${YAI_EVAL_TIMEOUT_SECONDS:-3600}"
	CODEX_MAX_RETRIES="${YAI_EVAL_RUNNER_MAX_RETRIES:-3}"
	CODEX_RETRY_WAIT_SECONDS="${YAI_EVAL_RETRY_WAIT_SECONDS:-15}"
	CODEX_TERM_GRACE_SECONDS="${YAI_EVAL_TERM_GRACE_SECONDS:-10}"
else
	CODEX_MODEL="${YAI_FINAL_EVAL_MODEL:-${YAI_EVAL_MODEL:-${YAI_CODEX_MODEL:-}}}"
	CODEX_PROFILE="${YAI_FINAL_EVAL_PROFILE:-${YAI_EVAL_PROFILE:-${YAI_CODEX_PROFILE:-}}}"
	CODEX_SANDBOX="${YAI_FINAL_EVAL_SANDBOX:-read-only}"
	CODEX_APPROVAL="${YAI_FINAL_EVAL_APPROVAL:-never}"
	CODEX_ARGS="${YAI_FINAL_EVAL_ARGS:-${YAI_EVAL_ARGS:-}}"
	CODEX_TIMEOUT_SECONDS="${YAI_FINAL_EVAL_TIMEOUT_SECONDS:-3600}"
	CODEX_MAX_RETRIES="${YAI_FINAL_EVAL_RUNNER_MAX_RETRIES:-3}"
	CODEX_RETRY_WAIT_SECONDS="${YAI_FINAL_EVAL_RETRY_WAIT_SECONDS:-15}"
	CODEX_TERM_GRACE_SECONDS="${YAI_FINAL_EVAL_TERM_GRACE_SECONDS:-10}"
fi

if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
	echo "missing Codex CLI: $CODEX_BIN" >&2
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

ensure_uint "CODEX_TIMEOUT_SECONDS" "$CODEX_TIMEOUT_SECONDS"
ensure_uint "CODEX_MAX_RETRIES" "$CODEX_MAX_RETRIES"
ensure_uint "CODEX_RETRY_WAIT_SECONDS" "$CODEX_RETRY_WAIT_SECONDS"
ensure_uint "CODEX_TERM_GRACE_SECONDS" "$CODEX_TERM_GRACE_SECONDS"

mkdir -p "$RUN_DIR"

EVENT_LOG="$RUN_DIR/$ITERATION.events.jsonl"
STDERR_LOG="$RUN_DIR/$ITERATION.stderr.log"
LAST_MESSAGE_FILE="$RUN_DIR/$ITERATION.last-message.txt"
STATUS_FILE="$RUN_DIR/$ITERATION.status.txt"
TOTAL_ATTEMPTS=$((CODEX_MAX_RETRIES + 1))

rm -f "$EVENT_LOG" "$STDERR_LOG" "$LAST_MESSAGE_FILE" "$STATUS_FILE"

cmd=("$CODEX_BIN" -a "$CODEX_APPROVAL" exec -C "$REPO_ROOT" --sandbox "$CODEX_SANDBOX" --skip-git-repo-check --color never --json -o "$LAST_MESSAGE_FILE")

if [[ -n "$CODEX_MODEL" ]]; then
	cmd+=(-m "$CODEX_MODEL")
fi

if [[ -n "$CODEX_PROFILE" ]]; then
	cmd+=(-p "$CODEX_PROFILE")
fi

if [[ -n "$CODEX_ARGS" ]]; then
	read -r -a extra_args <<<"$CODEX_ARGS"
	cmd+=("${extra_args[@]}")
fi

cmd+=(-)

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
timeout_seconds=$CODEX_TIMEOUT_SECONDS
max_retries=$CODEX_MAX_RETRIES
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
			sleep "$CODEX_TERM_GRACE_SECONDS"
			if kill -0 "$pid" 2>/dev/null; then
				printf 'yai runner escalated to SIGKILL after %ss grace\n' "$CODEX_TERM_GRACE_SECONDS" >>"$stderr_file"
				terminate_pid_tree "$pid" KILL
			fi
			wait "$pid" 2>/dev/null || true
			return 124
		fi
		sleep 1
	done

	wait "$pid"
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

	if grep -Eiq 'tls handshake eof|stream disconnected before completion|disconnect|error sending request for url|error decoding response body|connection reset|timed out|timeout|temporarily unavailable|service unavailable|502|503|504|network' <<<"$haystack"; then
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

echo "  Codex runner: $CODEX_BIN" >&2
echo "  Purpose: $PURPOSE" >&2
echo "  Codex event log: $EVENT_LOG" >&2
echo "  Codex stderr log: $STDERR_LOG" >&2
echo "  Codex last message: $LAST_MESSAGE_FILE" >&2
echo "  Codex timeout (s): $CODEX_TIMEOUT_SECONDS" >&2
echo "  Codex max retries: $CODEX_MAX_RETRIES" >&2

RUNNER_STARTED_AT="$(timestamp_utc)"
write_status "running" 0 0 "starting" "preparing codex runner"

attempt=1
while (( attempt <= TOTAL_ATTEMPTS )); do
	attempt_event="$RUN_DIR/$ITERATION.attempt-$attempt.events.jsonl"
	attempt_stderr="$RUN_DIR/$ITERATION.attempt-$attempt.stderr.log"
	attempt_last_message="$RUN_DIR/$ITERATION.attempt-$attempt.last-message.txt"
	cmd_attempt=("${cmd[@]}")
	cmd_attempt[${#cmd_attempt[@]} - 2]="$attempt_last_message"
	rm -f "$attempt_event" "$attempt_stderr" "$attempt_last_message"

	echo "  Codex attempt $attempt of $TOTAL_ATTEMPTS" >&2
	write_status "running" "$attempt" 0 "starting_attempt" "starting codex attempt $attempt"

	if run_with_timeout "$PROMPT_FILE" "$CODEX_TIMEOUT_SECONDS" "$attempt_event" "$attempt_stderr" "${cmd_attempt[@]}"; then
		rc=0
	else
		rc=$?
	fi

	sync_last_attempt_artifacts "$attempt_event" "$attempt_stderr" "$attempt_last_message"

	if [[ "$rc" -eq 0 ]]; then
		write_status "succeeded" "$attempt" 0 "success" "codex attempt succeeded"
		if [[ -s "$LAST_MESSAGE_FILE" ]]; then
			cat "$LAST_MESSAGE_FILE"
		fi
		exit 0
	fi

	classification="$(classify_failure "$rc" "$attempt_stderr" "$attempt_event")"
	detail="$(failure_excerpt "$attempt_stderr" "$attempt_event")"
	write_status "failed_attempt" "$attempt" "$rc" "$classification" "$detail"
	echo "  Codex attempt $attempt failed: rc=$rc classification=$classification" >&2
	echo "  Runner detail: $detail" >&2

	if [[ "$attempt" -lt "$TOTAL_ATTEMPTS" && ( "$classification" == "timeout" || "$classification" == "retryable_transport" ) ]]; then
		wait_seconds=$((CODEX_RETRY_WAIT_SECONDS * attempt))
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
