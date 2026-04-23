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

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_file() {
	local path="$1"
	[[ -f "$path" ]] || fail "missing file: $path"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		fail "$message (expected=$expected actual=$actual)"
	fi
}

make_mock_codex() {
	local path="$1"
	cat >"$path" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

LAST_MESSAGE_FILE=""
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-o)
		LAST_MESSAGE_FILE="$2"
		shift 2
		;;
	-C)
		REPO_ROOT="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

PROMPT="$(cat)"
PURPOSE="execute"
if grep -q "yai Semantic Eval Context" <<<"$PROMPT"; then
	PURPOSE="eval"
elif grep -q "yai Final Eval Context" <<<"$PROMPT"; then
	PURPOSE="final-eval"
elif grep -q "yai Final Fix Context" <<<"$PROMPT"; then
	PURPOSE="final-fix"
fi

mkdir -p "$REPO_ROOT/.mock-state"

extract_bullet_after() {
	local marker="$1"
	printf '%s\n' "$PROMPT" | awk -v marker="$marker" '
		$0 == marker { getline; sub(/^- /, ""); print; exit }
	'
}

extract_story_id() {
	printf '%s\n' "$PROMPT" | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4 || true
}

write_execution_artifact() {
	local path="$1"
	local status="$2"
	local summary="$3"
	local files_json="$4"
	local checks_json="$5"
	local claims_json="$6"
	local title="$7"
	local bullets_json="$8"
	local learnings_json="$9"
	jq -n \
		--arg status "$status" \
		--arg summary "$summary" \
		--arg title "$title" \
		--argjson filesChanged "$files_json" \
		--argjson mechanicalChecks "$checks_json" \
		--argjson acceptanceCriteriaClaims "$claims_json" \
		--argjson bodyBullets "$bullets_json" \
		--argjson learnings "$learnings_json" \
		'{
			status: $status,
			summary: $summary,
			filesChanged: $filesChanged,
			mechanicalChecks: $mechanicalChecks,
			acceptanceCriteriaClaims: $acceptanceCriteriaClaims,
			proposedCommit: {
				title: $title,
				bodyBullets: $bodyBullets
			},
			learnings: $learnings
		}' >"$path"
}

write_eval_message() {
	local status="$1"
	local summary="$2"
	local reviews_json="$3"
	local findings_json="$4"
	local fixes_json="$5"
	local decision="$6"
	local reason="$7"
	local fix_count="$8"
	jq -n \
		--arg status "$status" \
		--arg summary "$summary" \
		--arg decision "$decision" \
		--arg reason "$reason" \
		--argjson acceptanceCriteriaReview "$reviews_json" \
		--argjson findings "$findings_json" \
		--argjson requiredFixes "$fixes_json" \
		--argjson requiredFixesCount "$fix_count" \
		'{
			status: $status,
			summary: $summary,
			acceptanceCriteriaReview: $acceptanceCriteriaReview,
			findings: $findings,
			requiredFixes: $requiredFixes,
			verdictSummary: {
				decision: $decision,
				primaryReason: $reason,
				requiredFixesCount: $requiredFixesCount
			}
		}' >"$LAST_MESSAGE_FILE"
}

STORY_ID="$(extract_story_id)"
EXEC_ARTIFACT="$(extract_bullet_after "Write the execution artifact JSON to:")"
FINAL_FIX_ARTIFACT="$(extract_bullet_after "Write the final-fix artifact JSON to:")"
SCENARIO="${YAI_TEST_SCENARIO:-pass}"

printf '{"event":"mock","purpose":"%s","scenario":"%s"}\n' "$PURPOSE" "$SCENARIO"

case "$SCENARIO:$PURPOSE" in
pass:execute)
	echo "pass scenario" >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented pass scenario" \
		'["story.txt"]' \
		'[{"command":"echo pass","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo pass"}]' \
		'fix(scripts): pass scenario' \
		'["write story.txt"]' \
		'["keep artifacts explicit"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
pass:eval)
	write_eval_message \
		"pass" \
		"implementation satisfies the story" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo pass"}]' \
		'[]' \
		'[]' \
		"pass" \
		"criteria met" \
		0
	;;
pass:final-eval)
	jq -n '{
		status: "pass",
		summary: "whole PRD still holds",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["story.txt created"] }],
			userStories: [{ id: "US-001", text: "pass story", judgment: "met", evidence: ["story commit exists"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo pass"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["single file changed"] }]
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
			decision: "pass",
			primaryReason: "final aggregate review passed",
			requiredFixesCount: 0,
			overallDriftLevel: "low"
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
no_op_pass:execute)
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"story was already satisfied by the current repo state" \
		'[]' \
		'[{"command":"echo no-op-pass","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"existing repo state already satisfies the story"}]' \
		'chore(test): no-op pass scenario' \
		'["no source changes were needed"]' \
		'["record semantic pass without an empty commit"]'
	printf 'execution no-op done\n' >"$LAST_MESSAGE_FILE"
	;;
no_op_pass:eval)
	write_eval_message \
		"pass" \
		"current repo state already satisfies the story" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"no-op execution artifact and clean worktree"}]' \
		'[]' \
		'[]' \
		"pass" \
		"story is already satisfied without code changes" \
		0
	;;
no_op_pass:final-eval)
	jq -n '{
		status: "pass",
		summary: "whole PRD still holds after a no-op story pass",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["story was accepted without extra source changes"] }],
			userStories: [{ id: "US-001", text: "no-op pass story", judgment: "met", evidence: ["semantic pass recorded with an empty commitSha"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo no-op-pass"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["no files changed"] }]
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
			decision: "pass",
			primaryReason: "final aggregate review passed without requiring a no-op commit",
			requiredFixesCount: 0,
			overallDriftLevel: "low"
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
soft_fix:execute)
	if [[ -f "$REPO_ROOT/.mock-state/soft-fix-ready" ]]; then
		echo "good" >"$REPO_ROOT/story.txt"
	else
		echo "bad" >"$REPO_ROOT/story.txt"
	fi
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented soft-fix scenario" \
		'["story.txt"]' \
		'[{"command":"echo soft-fix","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo soft-fix"}]' \
		'fix(scripts): soft fix scenario' \
		'["update story.txt"]' \
		'["follow eval guidance"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
soft_fix:eval)
	if grep -q '^bad$' "$REPO_ROOT/story.txt"; then
		touch "$REPO_ROOT/.mock-state/soft-fix-ready"
		write_eval_message \
			"soft_fail" \
			"story still contains bad content" \
			'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo soft-fix"}]' \
			'["story.txt still says bad"]' \
			'["Replace bad with good in story.txt"]' \
			"soft_fail" \
			"story content is not yet corrected" \
			1
	else
		write_eval_message \
			"pass" \
			"fix round corrected the story" \
			'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"story.txt says good"}]' \
			'[]' \
			'[]' \
			"pass" \
			"fix applied" \
			0
	fi
	;;
soft_fix:final-eval)
	jq -n '{
		status: "pass",
		summary: "story-level fix still satisfies the whole PRD",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["story.txt says good"] }],
			userStories: [{ id: "US-001", text: "soft fix story", judgment: "met", evidence: ["story commit exists"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo soft-fix"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["single file changed"] }]
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
			decision: "pass",
			primaryReason: "aggregate drift resolved",
			requiredFixesCount: 0,
			overallDriftLevel: "low"
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
eval_infra_retry:execute)
	echo "stable" >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented eval infra retry scenario" \
		'["story.txt"]' \
		'[{"command":"echo stable","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo stable"}]' \
		'fix(scripts): eval infra retry scenario' \
		'["write stable story"]' \
		'["retry evaluator on infra fail"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
eval_infra_retry:eval)
	COUNT_FILE="$REPO_ROOT/.mock-state/eval-infra-count"
	COUNT=0
	if [[ -f "$COUNT_FILE" ]]; then
		COUNT="$(cat "$COUNT_FILE")"
	fi
	COUNT=$((COUNT + 1))
	printf '%s\n' "$COUNT" >"$COUNT_FILE"
	if [[ "$COUNT" -eq 1 ]]; then
		printf 'not-json\n' >"$LAST_MESSAGE_FILE"
	else
		write_eval_message \
			"pass" \
			"evaluator recovered after infra failure" \
			'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo stable"}]' \
			'[]' \
			'[]' \
			"pass" \
			"second evaluator attempt succeeded" \
			0
	fi
	;;
eval_infra_retry:final-eval)
	jq -n '{
		status: "pass",
		summary: "whole PRD still holds after story-level infra retry",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["story.txt says stable"] }],
			userStories: [{ id: "US-001", text: "eval infra retry story", judgment: "met", evidence: ["story commit exists"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo stable"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["single file changed"] }]
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
			decision: "pass",
			primaryReason: "aggregate review passed",
			requiredFixesCount: 0,
			overallDriftLevel: "low"
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
final_fix:execute)
	echo "story done" >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented final-fix scenario story" \
		'["story.txt"]' \
		'[{"command":"echo final-fix","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo final-fix"}]' \
		'fix(scripts): final fix scenario story' \
		'["write story.txt"]' \
		'["leave final drift for the final evaluator"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
final_fix:eval)
	write_eval_message \
		"pass" \
		"story itself is acceptable" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo final-fix"}]' \
		'[]' \
		'[]' \
		"pass" \
		"story passes" \
		0
	;;
final_fix:final-eval)
	if [[ -f "$REPO_ROOT/.mock-state/final-fixed" ]]; then
		jq -n '{
			status: "pass",
			summary: "final drift corrected",
			prdReview: {
				goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["final.txt says fixed"] }],
				userStories: [{ id: "US-001", text: "final fix story", judgment: "met", evidence: ["story commit exists"] }],
				functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo final-fix"] }],
				nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["bounded final fix only"] }]
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
				decision: "pass",
				primaryReason: "bounded final fix resolved aggregate drift",
				requiredFixesCount: 0,
				overallDriftLevel: "low"
			},
			approvedCommit: {
				title: "fix(scripts): resolve final aggregate drift",
				bodyBullets: ["apply bounded final corrective change"]
			}
		}' >"$LAST_MESSAGE_FILE"
	else
		jq -n '{
			status: "soft_fail",
			summary: "aggregate drift still exists",
			prdReview: {
				goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "unmet", evidence: ["final.txt missing"] }],
				userStories: [{ id: "US-001", text: "final fix story", judgment: "met", evidence: ["story commit exists"] }],
				functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo final-fix"] }],
				nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["still bounded"] }]
			},
			scopeDrift: {
				underfit: { present: true, summary: "missing final marker", evidence: ["final.txt missing"] },
				overreach: { present: false, summary: "", evidence: [] },
				cross_story_conflict: { present: false, summary: "", evidence: [] },
				shared_constraint_loss: { present: false, summary: "", evidence: [] }
			},
			findings: [
				{
					id: "F-1",
					kind: "implementation_fix",
					summary: "Add the final aggregate marker file",
					evidence: ["final.txt missing"]
				}
			],
			requiredFixes: [
				{
					id: "RF-1",
					kind: "implementation_fix",
					summary: "Create final.txt with corrected content",
					targets: ["final.txt"],
					evidence: ["final.txt missing"]
				}
			],
			verdictSummary: {
				decision: "soft_fail",
				primaryReason: "bounded final corrective change required",
				requiredFixesCount: 1,
				overallDriftLevel: "medium"
			}
		}' >"$LAST_MESSAGE_FILE"
	fi
	;;
final_fix:final-fix)
	printf 'fixed\n' >"$REPO_ROOT/final.txt"
	touch "$REPO_ROOT/.mock-state/final-fixed"
	jq -n '{
		status: "ok",
		summary: "applied bounded final fix",
		filesChanged: ["final.txt"],
		mechanicalChecks: [{"command":"test -f final.txt","status":"passed"}],
		addressedFindings: [
			{
				findingId: "F-1",
				kind: "implementation_fix",
				status: "addressed",
				evidence: "final.txt created"
			}
		],
		proposedCommit: {
			title: "fix(scripts): apply bounded final corrective change",
			bodyBullets: ["create final.txt for aggregate conformance"]
		},
		learnings: ["final eval should stay bounded"]
	}' >"$FINAL_FIX_ARTIFACT"
	printf 'final fix done\n' >"$LAST_MESSAGE_FILE"
	;;
final_hard_fail:execute)
	echo "story done" >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented final-hard-fail scenario story" \
		'["story.txt"]' \
		'[{"command":"echo final-hard-fail","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo final-hard-fail"}]' \
		'fix(scripts): final hard fail scenario story' \
		'["write story.txt"]' \
		'["leave slicing problem for the final evaluator"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
final_hard_fail:eval)
	write_eval_message \
		"pass" \
		"story itself is acceptable" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo final-hard-fail"}]' \
		'[]' \
		'[]' \
		"pass" \
		"story passes" \
		0
	;;
final_hard_fail:final-eval)
	jq -n '{
		status: "hard_fail",
		summary: "story slicing issue detected at final review",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "unmet", evidence: ["shared constraint missing"] }],
			userStories: [{ id: "US-001", text: "final hard fail story", judgment: "met", evidence: ["story commit exists"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo final-hard-fail"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "unclear", evidence: ["story slicing issue remains"] }]
		},
		scopeDrift: {
			underfit: { present: false, summary: "", evidence: [] },
			overreach: { present: false, summary: "", evidence: [] },
			cross_story_conflict: { present: true, summary: "story slicing lost a shared requirement", evidence: ["shared constraint missing"] },
			shared_constraint_loss: { present: true, summary: "shared constraint was dropped", evidence: ["shared constraint missing"] }
		},
		findings: [
			{
				id: "F-1",
				kind: "story_slicing_issue",
				summary: "Current slicing cannot satisfy the whole PRD",
				evidence: ["shared constraint missing"]
			}
		],
		requiredFixes: [
			{
				id: "RF-1",
				kind: "story_slicing_issue",
				summary: "Re-slice the PRD before continuing",
				targets: ["story slicing"],
				evidence: ["shared constraint missing"]
			}
		],
		verdictSummary: {
			decision: "hard_fail",
			primaryReason: "requires story re-slicing, not bounded final fix",
			requiredFixesCount: 1,
			overallDriftLevel: "high"
		},
		humanGuidance: {
			recommendedLayer: "story_slicing_issue",
			nextAction: "Return to PRD to re-slice stories."
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
final_infra_retry:execute)
	echo "story done" >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented final-infra-retry scenario story" \
		'["story.txt"]' \
		'[{"command":"echo final-infra","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo final-infra"}]' \
		'fix(scripts): final infra retry scenario story' \
		'["write story.txt"]' \
		'["retry final evaluator on infra failure"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
final_infra_retry:eval)
	write_eval_message \
		"pass" \
		"story itself is acceptable" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo final-infra"}]' \
		'[]' \
		'[]' \
		"pass" \
		"story passes" \
		0
	;;
final_infra_retry:final-eval)
	COUNT_FILE="$REPO_ROOT/.mock-state/final-infra-count"
	COUNT=0
	if [[ -f "$COUNT_FILE" ]]; then
		COUNT="$(cat "$COUNT_FILE")"
	fi
	COUNT=$((COUNT + 1))
	printf '%s\n' "$COUNT" >"$COUNT_FILE"
	if [[ "$COUNT" -eq 1 ]]; then
		printf 'not-json\n' >"$LAST_MESSAGE_FILE"
	else
		jq -n '{
			status: "pass",
			summary: "final evaluator recovered after infra failure",
			prdReview: {
				goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["story.txt exists"] }],
				userStories: [{ id: "US-001", text: "final infra retry story", judgment: "met", evidence: ["story commit exists"] }],
				functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo final-infra"] }],
				nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["single file changed"] }]
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
				decision: "pass",
				primaryReason: "final retry succeeded",
				requiredFixesCount: 0,
				overallDriftLevel: "low"
			}
		}' >"$LAST_MESSAGE_FILE"
	fi
	;;
final_pass_dirty:execute)
	echo "story done" >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"implemented final-pass-dirty scenario story" \
		'["story.txt"]' \
		'[{"command":"echo final-pass-dirty","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo final-pass-dirty"}]' \
		'fix(scripts): final pass dirty scenario story' \
		'["write story.txt"]' \
		'["allow finalization-only corrective round when needed"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
final_pass_dirty:eval)
	write_eval_message \
		"pass" \
		"story itself is acceptable" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo final-pass-dirty"}]' \
		'[]' \
		'[]' \
		"pass" \
		"story passes" \
		0
	;;
final_pass_dirty:final-eval)
	if [[ ! -f "$REPO_ROOT/.mock-state/final-pass-dirty-created" ]]; then
		printf 'final dirty\n' >"$REPO_ROOT/final-pass-dirty.txt"
		touch "$REPO_ROOT/.mock-state/final-pass-dirty-created"
	fi
	jq -n '{
		status: "pass",
		summary: "whole PRD still holds even though the worktree still needs a final corrective commit",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["story.txt exists", "final-pass-dirty.txt exists"] }],
			userStories: [{ id: "US-001", text: "final pass dirty story", judgment: "met", evidence: ["story commit exists"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo final-pass-dirty"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["bounded finalization only"] }]
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
			decision: "pass",
			primaryReason: "aggregate review passed",
			requiredFixesCount: 0,
			overallDriftLevel: "low"
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
final_pass_dirty:final-fix)
	jq -n '{
		status: "ok",
		summary: "prepared a bounded final corrective commit for the already-reviewed dirty worktree",
		filesChanged: ["final-pass-dirty.txt"],
		mechanicalChecks: [{"command":"echo finalization-only","status":"skipped"}],
		addressedFindings: [],
		proposedCommit: {
			title: "fix(scripts): finalize bounded run-level corrective changes",
			bodyBullets: ["record the dirty worktree that already passed final aggregate review"]
		},
		learnings: ["final eval pass may still require a final corrective commit when the reviewed worktree is dirty"]
	}' >"$FINAL_FIX_ARTIFACT"
	printf 'final fix done\n' >"$LAST_MESSAGE_FILE"
	;;
adopt:execute)
	if [[ ! -f "$REPO_ROOT/dirty.txt" ]]; then
		printf 'dirty\n' >"$REPO_ROOT/dirty.txt"
	fi
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"ok" \
		"adopted existing dirty worktree" \
		'["dirty.txt"]' \
		'[{"command":"echo adopt","status":"passed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"met","evidence":"echo adopt"}]' \
		'fix(scripts): adopt dirty worktree scenario' \
		'["commit adopted worktree"]' \
		'["require explicit adoption"]'
	printf 'execution done\n' >"$LAST_MESSAGE_FILE"
	;;
adopt:eval)
	write_eval_message \
		"pass" \
		"adopted worktree satisfies the story" \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","judgment":"met","evidence":"echo adopt"}]' \
		'[]' \
		'[]' \
		"pass" \
		"dirty worktree was adopted intentionally" \
		0
	;;
adopt:final-eval)
	jq -n '{
		status: "pass",
		summary: "adopted worktree still satisfies the whole PRD",
		prdReview: {
			goals: [{ id: "G-1", text: "Finish the requested workflow", judgment: "met", evidence: ["dirty.txt exists"] }],
			userStories: [{ id: "US-001", text: "adopt dirty worktree story", judgment: "met", evidence: ["story commit exists"] }],
			functionalRequirements: [{ id: "FR-1", text: "Typecheck passes", judgment: "met", evidence: ["echo adopt"] }],
			nonGoals: [{ id: "NG-1", text: "Do not widen scope", judgment: "met", evidence: ["single file changed"] }]
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
			decision: "pass",
			primaryReason: "adopted change stayed within the PRD",
			requiredFixesCount: 0,
			overallDriftLevel: "low"
		}
	}' >"$LAST_MESSAGE_FILE"
	;;
mechanical_failed:execute)
	printf 'broken\n' >"$REPO_ROOT/story.txt"
	write_execution_artifact \
		"$EXEC_ARTIFACT" \
		"mechanical_failed" \
		"mechanical checks failed" \
		'["story.txt"]' \
		'[{"command":"false","status":"failed"}]' \
		'[{"criterionId":"AC-1","criterionText":"Typecheck passes","claimedStatus":"not_met","evidence":"false"}]' \
		'' \
		'[]' \
		'["stop before semantic eval"]'
	printf 'execution failed mechanically\n' >"$LAST_MESSAGE_FILE"
	;;
mechanical_failed:eval)
	write_eval_message \
		"hard_fail" \
		"should not run" \
		'[]' \
		'[]' \
		'[]' \
		"hard_fail" \
		"semantic eval should not run after mechanical failure" \
		0
	;;
*)
	printf 'unsupported mock scenario: %s (%s)\n' "$SCENARIO" "$PURPOSE" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$path"
}

setup_temp_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir/.yai/bin/adapters" "$repo_dir/.yai/prompts"
	cp "$ROOT_DIR/.yai/bin/yai.sh" "$repo_dir/.yai/bin/yai.sh"
	cp "$ROOT_DIR/.yai/bin/adapters/codex.sh" "$repo_dir/.yai/bin/adapters/codex.sh"
	cp "$ROOT_DIR/.yai/prompts/EXECUTE.md" "$repo_dir/.yai/prompts/EXECUTE.md"
	cp "$ROOT_DIR/.yai/prompts/EVAL.md" "$repo_dir/.yai/prompts/EVAL.md"
	cp "$ROOT_DIR/.yai/prompts/FINAL_EVAL.md" "$repo_dir/.yai/prompts/FINAL_EVAL.md"
	cp "$ROOT_DIR/.yai/prompts/FINAL_FIX.md" "$repo_dir/.yai/prompts/FINAL_FIX.md"
	printf '.yai/*\n!.yai/bin/\n!.yai/prompts/\n.mock-state/\n' >"$repo_dir/.gitignore"
	printf '# temp repo\n' >"$repo_dir/README.md"
	make_mock_codex "$repo_dir/mock-codex.sh"
	(
		cd "$repo_dir"
		git init -q
		git config user.name "yai Test"
		git config user.email "yai-test@example.com"
		git add README.md .gitignore .yai/bin .yai/prompts mock-codex.sh
		git commit -q -m "chore: initialize test repo"
	)
}

write_prd() {
	local repo_dir="$1"
	local story_title="$2"
	mkdir -p "$repo_dir/.yai"
	cat >"$repo_dir/.yai/prd.json" <<EOF
{
  "project": "yai Semantic Eval Test",
  "branchName": "yai/test",
  "description": "Test harness for yai semantic eval",
  "userStories": [
    {
      "id": "US-001",
      "title": "$story_title",
      "description": "As a test, I want a single story to execute.",
      "acceptanceCriteria": [
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
EOF
	cat >"$repo_dir/.yai/prd-source.md" <<EOF
# PRD: $story_title

## Goals

- Finish the requested workflow

## User Stories

### US-001

- Typecheck passes

## Functional Requirements

- FR-1: The workflow completes without widening scope.

## Non-Goals

- Do not widen scope.
EOF
}

run_case_pass() {
	local tmp_dir="$1/pass"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "pass story"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="pass" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "pass scenario should mark story complete"
	assert_eq "2" "$(git -C "$tmp_dir" rev-list --count HEAD)" "pass scenario should create one story commit"
	assert_file "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/iteration-001.exec.story-result.json"
	assert_file "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/iteration-001.eval.semantic-eval.json"
	assert_file "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "pass scenario should finish with final pass"
	assert_file "$tmp_dir/.yai/completed-stories.json"
	assert_eq "1" "$(jq 'length' "$tmp_dir/.yai/completed-stories.json")" "pass scenario should track one completed story"
	if ! compgen -G "$tmp_dir/.yai/archive/*.prd-source.md" >/dev/null; then
		fail "pass scenario should archive prd-source snapshot"
	fi
	if ! compgen -G "$tmp_dir/.yai/archive/*.completed-stories.json" >/dev/null; then
		fail "pass scenario should archive completed stories summary"
	fi
	if ! compgen -G "$tmp_dir/.yai/archive/*.final.eval.json" >/dev/null; then
		fail "pass scenario should archive final eval artifact"
	fi
}

run_case_no_op_pass() {
	local tmp_dir="$1/no-op-pass"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "no-op pass story"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="no_op_pass" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "no-op pass scenario should mark story complete"
	assert_eq "1" "$(git -C "$tmp_dir" rev-list --count HEAD)" "no-op pass scenario should not create an empty story commit"
	assert_eq "" "$(jq -r '.[0].commitSha' "$tmp_dir/.yai/completed-stories.json")" "no-op pass scenario should record an empty commitSha"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "no-op pass scenario should finish with final pass"
}

run_case_soft_fix() {
	local tmp_dir="$1/soft-fix"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "soft fix story"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="soft_fix" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "soft-fix scenario should mark story complete"
	assert_file "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/iteration-001.fix-01.exec.story-result.json"
	assert_eq "good" "$(cat "$tmp_dir/story.txt")" "soft-fix scenario should apply evaluator guidance"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "soft-fix scenario should finish with final pass"
}

run_case_eval_infra_retry() {
	local tmp_dir="$1/eval-infra-retry"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "eval infra retry story"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="eval_infra_retry" \
		YAI_EVAL_MAX_RETRIES=2 \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	assert_eq "2" "$(cat "$tmp_dir/.mock-state/eval-infra-count")" "eval infra retry should rerun evaluator"
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "eval infra retry should eventually pass"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "eval infra retry scenario should still reach final pass"
}

run_case_adopt() {
	local tmp_dir="$1/adopt"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "adopt dirty worktree story"
	printf 'dirty\n' >"$tmp_dir/dirty.txt"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="adopt" \
		./.yai/bin/yai.sh --state-dir .yai --adopt-dirty-worktree US-001 --yes 1
	)
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "adopt scenario should mark story complete"
	assert_file "$tmp_dir/dirty.txt"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "adopt scenario should reach final pass"
}

run_case_mechanical_failed() {
	local tmp_dir="$1/mechanical-failed"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "mechanical failed story"
	set +e
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="mechanical_failed" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	local rc=$?
	set -e
	assert_eq "1" "$rc" "mechanical_failed scenario should stop"
	assert_eq "false" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "mechanical_failed scenario should not mark story complete"
	assert_eq "1" "$(git -C "$tmp_dir" rev-list --count HEAD)" "mechanical_failed scenario should not commit"
}

run_case_final_fix() {
	local tmp_dir="$1/final-fix"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "final fix story"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="final_fix" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "final-fix scenario should preserve completed story state"
	assert_file "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.fix-01.exec.fix-result.json"
	assert_eq "fixed" "$(cat "$tmp_dir/final.txt")" "final-fix scenario should apply bounded corrective change"
	assert_eq "3" "$(git -C "$tmp_dir" rev-list --count HEAD)" "final-fix scenario should create story and final corrective commits"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "final-fix scenario should end with final pass"
}

run_case_final_hard_fail() {
	local tmp_dir="$1/final-hard-fail"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "final hard fail story"
	set +e
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="final_hard_fail" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	local rc=$?
	set -e
	assert_eq "1" "$rc" "final-hard-fail scenario should stop"
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "final-hard-fail should keep the story completed"
	assert_eq "2" "$(git -C "$tmp_dir" rev-list --count HEAD)" "final-hard-fail should stop before a final corrective commit"
	assert_eq "final" "$(jq -r '.scope' "$tmp_dir/.yai/active-story.json")" "final-hard-fail should preserve a final-phase checkpoint"
}

run_case_final_infra_retry() {
	local tmp_dir="$1/final-infra-retry"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "final infra retry story"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="final_infra_retry" \
		YAI_FINAL_EVAL_MAX_RETRIES=2 \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	assert_eq "2" "$(cat "$tmp_dir/.mock-state/final-infra-count")" "final infra retry should rerun the final evaluator"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "final infra retry should eventually pass"
}

run_case_final_pass_dirty() {
	local tmp_dir="$1/final-pass-dirty"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "final pass dirty story"
	set +e
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="final_pass_dirty" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	local rc=$?
	set -e
	assert_eq "1" "$rc" "final-pass-dirty scenario should stop before implicit finalization"
	assert_eq "true" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "final-pass-dirty scenario should preserve completed story state"
	assert_eq "final" "$(jq -r '.scope' "$tmp_dir/.yai/active-story.json")" "final-pass-dirty scenario should preserve a final checkpoint"
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		YAI_TEST_SCENARIO="final_pass_dirty" \
		./.yai/bin/yai.sh --state-dir .yai --adopt-dirty-worktree FINAL --yes 1
	)
	assert_file "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.fix-01.exec.fix-result.json"
	assert_eq "3" "$(git -C "$tmp_dir" rev-list --count HEAD)" "final-pass-dirty scenario should create a final corrective commit"
	assert_eq "pass" "$(jq -r '.status' "$tmp_dir/.yai/runs/$(basename "$(cat "$tmp_dir/.yai/.last-run")")/final.eval.semantic-eval.json")" "final-pass-dirty scenario should end with final pass"
}

run_case_missing_prd_source() {
	local tmp_dir="$1/missing-prd-source"
	setup_temp_repo "$tmp_dir"
	write_prd "$tmp_dir" "missing prd source story"
	rm -f "$tmp_dir/.yai/prd-source.md"
	set +e
	(
		cd "$tmp_dir"
		YAI_CODEX_BIN="$tmp_dir/mock-codex.sh" \
		./.yai/bin/yai.sh --state-dir .yai 1
	)
	local rc=$?
	set -e
	assert_eq "1" "$rc" "missing prd source should stop early"
	assert_eq "false" "$(jq -r '.userStories[0].passes' "$tmp_dir/.yai/prd.json")" "missing prd source should not advance the story"
}

main() {
	local tmp_root
	tmp_root="$(mktemp -d)"
	# shellcheck disable=SC2064  # intentionally expand now: tmp_root is a local, out of scope at trap-fire time
	trap "rm -rf '$tmp_root'" EXIT

	run_case_pass "$tmp_root"
	run_case_no_op_pass "$tmp_root"
	run_case_soft_fix "$tmp_root"
	run_case_eval_infra_retry "$tmp_root"
	run_case_adopt "$tmp_root"
	run_case_mechanical_failed "$tmp_root"
	run_case_final_fix "$tmp_root"
	run_case_final_hard_fail "$tmp_root"
	run_case_final_infra_retry "$tmp_root"
	run_case_final_pass_dirty "$tmp_root"
	run_case_missing_prd_source "$tmp_root"

	echo "yai semantic eval harness tests passed."
}

main "$@"
