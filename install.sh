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

REPO_SLUG="rokurokulab/yai"
GITHUB_API="https://api.github.com/repos/${REPO_SLUG}"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_SLUG}"
GITHUB_ARCHIVE="https://github.com/${REPO_SLUG}/archive"
GITHUB_RELEASES="https://github.com/${REPO_SLUG}/releases/download"

MODE=""
VERSION=""
BRANCH=""
COMMIT=""
TMPDIR_PATH=""

log() {
	printf '%s\n' "$*" >&2
}

info() {
	printf '  %s\n' "$*" >&2
}

err() {
	printf 'error: %s\n' "$*" >&2
}

warn() {
	printf 'warning: %s\n' "$*" >&2
}

usage() {
	cat <<'EOF'
yai installer

Usage:
  install.sh [--version <tag> | --branch <name> | --commit <sha>]
  install.sh --uninstall
  install.sh --help

Options:
  --version <tag>   Install a specific release tag (SHA256 verified).
                    Tag must start with 'v', e.g. v0.1.2.
  --branch <name>   Install branch tip (unverified).
  --commit <sha>    Install a specific commit (unverified). 7+ hex chars.
  --uninstall       Remove .yai/bin and .yai/prompts from the current repo.
  --help, -h        Show this help.

Default (no flag): install latest release tag, SHA256 verified. Falls back
to branch 'main' with a warning if no releases exist yet.

Examples:
  curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/install.sh | bash -s -- --version v0.1.2
  curl -fsSL https://raw.githubusercontent.com/rokurokulab/yai/main/install.sh | bash -s -- --branch main
  bash .yai/bin/install.sh --uninstall

Exit codes:
  0  success
  1  runtime error (network, extraction, verification)
  2  usage error or missing prerequisite
EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--version)
				if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
					err "--version requires a tag argument"
					exit 2
				fi
				if [ -n "$MODE" ]; then
					err "--version is mutually exclusive with --branch / --commit / --uninstall"
					exit 2
				fi
				MODE="version"
				VERSION="$2"
				shift 2
				;;
			--branch)
				if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
					err "--branch requires a name argument"
					exit 2
				fi
				if [ -n "$MODE" ]; then
					err "--branch is mutually exclusive with --version / --commit / --uninstall"
					exit 2
				fi
				MODE="branch"
				BRANCH="$2"
				shift 2
				;;
			--commit)
				if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
					err "--commit requires a sha argument"
					exit 2
				fi
				if [ -n "$MODE" ]; then
					err "--commit is mutually exclusive with --version / --branch / --uninstall"
					exit 2
				fi
				MODE="commit"
				COMMIT="$2"
				shift 2
				;;
			--uninstall)
				if [ -n "$MODE" ]; then
					err "--uninstall is mutually exclusive with --version / --branch / --commit"
					exit 2
				fi
				MODE="uninstall"
				shift
				;;
			--help|-h)
				usage
				exit 0
				;;
			--)
				shift
				if [ "$#" -gt 0 ]; then
					err "positional arguments not supported: $*"
					exit 2
				fi
				;;
			-*)
				err "unknown option: $1"
				usage >&2
				exit 2
				;;
			*)
				err "positional arguments not supported: $1"
				exit 2
				;;
		esac
	done

	if [ -z "$MODE" ]; then
		MODE="latest"
	fi

	if [ "$MODE" = "version" ]; then
		case "$VERSION" in
			v*) ;;
			*)
				err "--version tag must start with 'v' (got: $VERSION)"
				exit 2
				;;
		esac
	fi

	if [ "$MODE" = "commit" ]; then
		case "$COMMIT" in
			*[!0-9a-fA-F]*)
				err "--commit must be hex characters only (got: $COMMIT)"
				exit 2
				;;
		esac
		# shellcheck disable=SC2170
		if [ "${#COMMIT}" -lt 7 ]; then
			err "--commit must be at least 7 hex characters (got: $COMMIT)"
			exit 2
		fi
	fi
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		err "required command not found on PATH: $1"
		exit 2
	fi
}

sha256_cmd() {
	if command -v sha256sum >/dev/null 2>&1; then
		echo "sha256sum"
	elif command -v shasum >/dev/null 2>&1; then
		echo "shasum -a 256"
	else
		echo ""
	fi
}

preflight_install() {
	need_cmd curl
	need_cmd tar
	need_cmd git
	need_cmd jq

	if [ -z "$(sha256_cmd)" ]; then
		err "neither sha256sum nor shasum is available"
		exit 2
	fi

	if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
		err "current directory is not inside a git worktree"
		err "run yai install from within the repo you want to install into"
		exit 2
	fi

	if ! command -v codex >/dev/null 2>&1 && ! command -v claude >/dev/null 2>&1; then
		warn "neither 'codex' nor 'claude' found on PATH — install one before running yai"
	fi
}

preflight_uninstall() {
	if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
		err "current directory is not inside a git worktree"
		exit 2
	fi
}

compute_sha256() {
	local file="$1"
	local cmd
	cmd="$(sha256_cmd)"
	# cmd may be "shasum -a 256" — intentional word-split.
	# shellcheck disable=SC2086
	$cmd "$file" | awk '{print $1}'
}

github_api_get() {
	local url="$1"
	curl -fsSL \
		-H "Accept: application/vnd.github+json" \
		-H "User-Agent: yai-installer" \
		"$url"
}

resolve_latest_tag() {
	local body tag
	if ! body="$(github_api_get "${GITHUB_API}/releases/latest" 2>/dev/null)"; then
		echo ""
		return 0
	fi
	tag="$(printf '%s' "$body" | jq -r '.tag_name // empty')"
	if [ -z "$tag" ] || [ "$tag" = "null" ]; then
		echo ""
		return 0
	fi
	echo "$tag"
}

resolve_commit_sha() {
	local ref="$1"
	local body sha
	if ! body="$(github_api_get "${GITHUB_API}/commits/${ref}" 2>/dev/null)"; then
		echo ""
		return 0
	fi
	sha="$(printf '%s' "$body" | jq -r '.sha // empty')"
	if [ "$sha" = "null" ]; then
		sha=""
	fi
	echo "$sha"
}

download_to() {
	local url="$1"
	local dest="$2"
	if ! curl -fsSL -o "$dest" "$url"; then
		err "download failed: $url"
		exit 1
	fi
}

# Read tarball's top-level directory name, e.g. "yai-0.1.2/".
detect_top_dir() {
	local tarball="$1"
	local first
	first="$(tar -tzf "$tarball" 2>/dev/null | head -1 || true)"
	if [ -z "$first" ]; then
		err "tarball is empty or unreadable"
		exit 1
	fi
	# Strip trailing slash and anything after the first slash.
	first="${first%%/*}"
	if [ -z "$first" ]; then
		err "could not detect top-level directory in tarball"
		exit 1
	fi
	echo "$first"
}

# Verify tarball sha against release SHA256SUMS.txt.
# Match by hash, not filename (filename is informational).
verify_sha256() {
	local tag="$1"
	local tarball="$2"
	local computed="$3"
	local sums_url sums_file
	sums_url="${GITHUB_RELEASES}/${tag}/SHA256SUMS.txt"
	sums_file="${TMPDIR_PATH}/SHA256SUMS.txt"

	if ! curl -fsSL -o "$sums_file" "$sums_url"; then
		err "Release ${tag} does not publish SHA256SUMS; use --branch or --commit instead"
		exit 1
	fi

	local matched="no"
	local line hash
	while IFS= read -r line; do
		# Skip blanks and comments.
		case "$line" in
			""|\#*) continue ;;
		esac
		hash="$(printf '%s' "$line" | awk '{print $1}')"
		if [ "$hash" = "$computed" ]; then
			matched="yes"
			break
		fi
	done < "$sums_file"

	if [ "$matched" != "yes" ]; then
		err "SHA256 mismatch: computed $computed not present in SHA256SUMS.txt for $tag"
		exit 1
	fi
}

copy_self_to_repo() {
	local repo_root="$1"
	local ref="$2"
	local dest="${repo_root}/.yai/bin/install.sh"
	local src="${BASH_SOURCE[0]:-}"

	if [ -n "$src" ] && [ -f "$src" ]; then
		cp "$src" "$dest"
	else
		# Invoked via stdin (curl | bash) — no local script to copy.
		# Fetch install.sh from the same ref so --uninstall works offline.
		local raw_url="${GITHUB_RAW}/${ref}/install.sh"
		if ! curl -fsSL -o "$dest" "$raw_url"; then
			warn "could not fetch install.sh for offline uninstall from $raw_url"
			return 0
		fi
	fi
	chmod +x "$dest"
}

cleanup_tmpdir() {
	if [ -n "${TMPDIR_PATH:-}" ] && [ -d "$TMPDIR_PATH" ]; then
		rm -rf "$TMPDIR_PATH"
	fi
}

do_install() {
	preflight_install

	local repo_root
	repo_root="$(git rev-parse --show-toplevel)"

	log "yai installer"

	# Resolve the ref we'll fetch, plus a human label and a download URL.
	local label=""       # printed to user
	local tarball_url="" # where to GET the tarball
	local ref_for_raw="" # ref used to fetch install.sh on stdin path
	local verify="no"    # yes -> check SHA256SUMS
	local tag=""         # set when verifying

	case "$MODE" in
		latest)
			info "resolving ref... (latest release)"
			tag="$(resolve_latest_tag)"
			if [ -z "$tag" ]; then
				warn "no published release found; falling back to branch 'main' (unverified)"
				MODE="branch"
				BRANCH="main"
			else
				label="$tag"
				tarball_url="${GITHUB_ARCHIVE}/refs/tags/${tag}.tar.gz"
				ref_for_raw="$tag"
				verify="yes"
				info "resolved: $tag"
			fi
			;;
		version)
			tag="$VERSION"
			label="$tag"
			tarball_url="${GITHUB_ARCHIVE}/refs/tags/${tag}.tar.gz"
			ref_for_raw="$tag"
			verify="yes"
			info "resolved: $tag"
			;;
	esac

	if [ "$MODE" = "branch" ]; then
		local full_sha short_sha
		full_sha="$(resolve_commit_sha "$BRANCH")"
		if [ -z "$full_sha" ]; then
			warn "could not resolve commit sha for branch '$BRANCH' (continuing)"
			short_sha="unknown"
		else
			short_sha="$(printf '%s' "$full_sha" | cut -c1-7)"
		fi
		label="branch ${BRANCH}@${short_sha}"
		tarball_url="${GITHUB_ARCHIVE}/refs/heads/${BRANCH}.tar.gz"
		ref_for_raw="$BRANCH"
		verify="no"
		warn "installing unverified branch tip ${BRANCH}@${short_sha}. No SHA256 reference is available for branch installs."
	fi

	if [ "$MODE" = "commit" ]; then
		local full_sha
		full_sha="$(resolve_commit_sha "$COMMIT")"
		if [ -z "$full_sha" ]; then
			full_sha="$COMMIT"
		fi
		label="commit ${full_sha}"
		tarball_url="${GITHUB_ARCHIVE}/${full_sha}.tar.gz"
		ref_for_raw="$full_sha"
		verify="no"
		warn "installing unverified commit ${full_sha}. No SHA256 reference is available for commit installs."
	fi

	TMPDIR_PATH="$(mktemp -d 2>/dev/null || mktemp -d -t yai-install)"
	trap cleanup_tmpdir EXIT

	local tarball="${TMPDIR_PATH}/yai.tar.gz"
	info "downloading tarball ($label)..."
	download_to "$tarball_url" "$tarball"
	info "downloaded: ok"

	local computed
	computed="$(compute_sha256 "$tarball")"
	info "sha256: $computed"

	if [ "$verify" = "yes" ]; then
		info "verifying SHA256 against SHA256SUMS.txt..."
		verify_sha256 "$tag" "$tarball" "$computed"
		info "verified: ok"
	fi

	local top
	top="$(detect_top_dir "$tarball")"
	info "extracting .yai/bin and .yai/prompts into ${repo_root}..."

	mkdir -p "${repo_root}/.yai"

	# Filter extraction to the two runtime trees. If the tag predates the
	# flat layout, tar will error — the user needs a newer tag.
	if ! tar -xzf "$tarball" \
		--strip-components=1 \
		-C "$repo_root" \
		"${top}/.yai/bin" \
		"${top}/.yai/prompts" 2>/dev/null; then
		err "tarball does not contain .yai/bin and .yai/prompts at the expected paths"
		err "this ref likely predates the flat runtime layout; try a newer tag"
		exit 1
	fi

	# Restore exec bits on shell scripts.
	if [ -d "${repo_root}/.yai/bin" ]; then
		find "${repo_root}/.yai/bin" -type f -name '*.sh' -exec chmod +x {} +
	fi

	copy_self_to_repo "$repo_root" "$ref_for_raw"
	info "extracted: ok"

	# Structured stdout summary (only stdout writes go here).
	printf 'installed: %s\n' "$label"
	printf 'sha256: %s\n' "$computed"
	printf 'repo: %s\n' "$repo_root"
	printf 'verified: %s\n' "$verify"
	printf 'key files:\n'
	if [ -f "${repo_root}/.yai/bin/yai.sh" ]; then
		printf '  .yai/bin/yai.sh\n'
	fi
	if [ -f "${repo_root}/.yai/prompts/EXECUTE.md" ]; then
		printf '  .yai/prompts/EXECUTE.md\n'
	fi
	local bin_count prompt_count
	bin_count=0
	prompt_count=0
	if [ -d "${repo_root}/.yai/bin" ]; then
		bin_count="$(find "${repo_root}/.yai/bin" -type f | wc -l | tr -d ' ')"
	fi
	if [ -d "${repo_root}/.yai/prompts" ]; then
		prompt_count="$(find "${repo_root}/.yai/prompts" -type f | wc -l | tr -d ' ')"
	fi
	printf 'file counts: bin=%s prompts=%s\n' "$bin_count" "$prompt_count"

	log ""
	log "Next steps:"
	log "  1. Ensure .yai/prd.json exists (see project README)."
	log "  2. Run: bash .yai/bin/yai.sh --help"
}

do_uninstall() {
	preflight_uninstall

	local repo_root
	repo_root="$(git rev-parse --show-toplevel)"

	log "yai uninstaller"
	info "target: ${repo_root}"

	local removed_bin="no"
	local removed_prompts="no"

	if [ -d "${repo_root}/.yai/bin" ]; then
		rm -rf "${repo_root}/.yai/bin"
		removed_bin="yes"
		info "removed: .yai/bin"
	else
		info "not present: .yai/bin"
	fi

	if [ -d "${repo_root}/.yai/prompts" ]; then
		rm -rf "${repo_root}/.yai/prompts"
		removed_prompts="yes"
		info "removed: .yai/prompts"
	else
		info "not present: .yai/prompts"
	fi

	printf 'uninstalled: %s\n' "$repo_root"
	printf 'removed_bin: %s\n' "$removed_bin"
	printf 'removed_prompts: %s\n' "$removed_prompts"

	log ""
	log "User state under .yai/ (runs/, archive/, prd.json, etc.) was preserved."
}

main() {
	parse_args "$@"

	case "$MODE" in
		uninstall)
			do_uninstall
			;;
		*)
			do_install
			;;
	esac
}

main "$@"
