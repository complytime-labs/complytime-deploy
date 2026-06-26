#!/usr/bin/env bats
# Unit tests for scripts/lib/grafana-url.sh — auto-derive Grafana URL logic.
#
# These tests mock `oc` and `jq` to exercise the URL derivation branches
# without requiring a running cluster.

setup() {
	# Absolute path to the library under test
	LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)"

	# Create a temp bin dir for mock commands
	MOCK_BIN="$(mktemp -d)"
	export PATH="$MOCK_BIN:$PATH"

	# Provide a real jq — needed for JSON escaping and @uri encoding
	JQ_REAL="$(command -v jq 2>/dev/null)" || true
	if [[ -z "$JQ_REAL" ]]; then
		skip "jq is required but not installed"
	fi

	# Default namespace used by the function
	export NAMESPACE="test-ns"

	# Track oc patch calls for assertions
	export OC_PATCH_LOG="$MOCK_BIN/oc-patch.log"
	: >"$OC_PATCH_LOG"

	# Track oc rollout calls
	export OC_ROLLOUT_LOG="$MOCK_BIN/oc-rollout.log"
	: >"$OC_ROLLOUT_LOG"
}

teardown() {
	rm -rf "$MOCK_BIN"
}

# --- Helper: write the oc mock -------------------------------------------
# Usage: create_oc_mock <route_host> <configmap_exists> <root_url> <signout_url>
create_oc_mock() {
	local route_host="${1:-}"
	local configmap_exists="${2:-true}"
	local root_url="${3:-}"
	local signout_url="${4:-}"

	cat >"$MOCK_BIN/oc" <<MOCK
#!/bin/bash
case "\$*" in
	*"get route grafana"*)
		if [[ -n "$route_host" ]]; then
			echo "$route_host"
		else
			exit 1
		fi
		;;
	*"get configmap grafana-env"*jsonpath*GF_SERVER_ROOT_URL*)
		echo "$root_url"
		;;
	*"get configmap grafana-env"*jsonpath*GF_AUTH_SIGNOUT_REDIRECT_URL*)
		echo "$signout_url"
		;;
	*"get configmap grafana-env"*)
		if [[ "$configmap_exists" == "true" ]]; then
			exit 0
		else
			exit 1
		fi
		;;
	*"patch configmap grafana-env"*)
		echo "\$@" >> "$OC_PATCH_LOG"
		;;
	*"rollout restart"*)
		echo "\$@" >> "$OC_ROLLOUT_LOG"
		;;
	*"rollout status"*)
		echo "\$@" >> "$OC_ROLLOUT_LOG"
		;;
	*)
		echo "UNEXPECTED OC CALL: \$*" >&2
		exit 99
		;;
esac
MOCK
	chmod +x "$MOCK_BIN/oc"
}

# ==========================================================================
# GF_SERVER_ROOT_URL tests
# ==========================================================================

@test "patches GF_SERVER_ROOT_URL when empty" {
	create_oc_mock "grafana.example.com" "true" "" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'GF_SERVER_ROOT_URL' "$OC_PATCH_LOG"
	# Verify the patched value contains the derived URL
	grep -q 'https://grafana.example.com' "$OC_PATCH_LOG"
}

@test "skips GF_SERVER_ROOT_URL when already set" {
	create_oc_mock "grafana.example.com" "true" "https://existing.example.com" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	# No patch should be issued for ROOT_URL
	! grep -q 'GF_SERVER_ROOT_URL' "$OC_PATCH_LOG"
}

# ==========================================================================
# post_logout_redirect_uri tests — four branches
# ==========================================================================

@test "post_logout_redirect_uri= at end of string — appends encoded URL" {
	local signout="https://sso.example.com/logout?post_logout_redirect_uri="
	create_oc_mock "grafana.example.com" "true" "https://already-set" "$signout"
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'GF_AUTH_SIGNOUT_REDIRECT_URL' "$OC_PATCH_LOG"
	# The encoded form of https://grafana.example.com is https%3A%2F%2Fgrafana.example.com
	grep -q 'https%3A%2F%2Fgrafana.example.com' "$OC_PATCH_LOG"
}

@test "post_logout_redirect_uri=& (empty, followed by &) — inserts encoded URL" {
	local signout="https://sso.example.com/logout?post_logout_redirect_uri=&extra=1"
	create_oc_mock "grafana.example.com" "true" "https://already-set" "$signout"
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'GF_AUTH_SIGNOUT_REDIRECT_URL' "$OC_PATCH_LOG"
	# Should contain post_logout_redirect_uri=<encoded>&extra=1
	grep -q 'post_logout_redirect_uri=https%3A%2F%2Fgrafana.example.com&extra=1' "$OC_PATCH_LOG"
}

@test "no post_logout_redirect_uri param, URL has ? — appends &post_logout_redirect_uri=..." {
	local signout="https://sso.example.com/logout?client_id=grafana"
	create_oc_mock "grafana.example.com" "true" "https://already-set" "$signout"
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'GF_AUTH_SIGNOUT_REDIRECT_URL' "$OC_PATCH_LOG"
	grep -q 'client_id=grafana&post_logout_redirect_uri=https%3A%2F%2Fgrafana.example.com' "$OC_PATCH_LOG"
}

@test "no post_logout_redirect_uri param, URL has no ? — appends ?post_logout_redirect_uri=..." {
	local signout="https://sso.example.com/logout"
	create_oc_mock "grafana.example.com" "true" "https://already-set" "$signout"
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'GF_AUTH_SIGNOUT_REDIRECT_URL' "$OC_PATCH_LOG"
	grep -q 'logout?post_logout_redirect_uri=https%3A%2F%2Fgrafana.example.com' "$OC_PATCH_LOG"
}

@test "post_logout_redirect_uri already has a value — skips (CI wins)" {
	local signout="https://sso.example.com/logout?post_logout_redirect_uri=https%3A%2F%2Fci-set.example.com"
	create_oc_mock "grafana.example.com" "true" "https://already-set" "$signout"
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	# No signout URL patch should be issued
	! grep -q 'GF_AUTH_SIGNOUT_REDIRECT_URL' "$OC_PATCH_LOG"
}

# ==========================================================================
# Edge cases — skip conditions
# ==========================================================================

@test "no Route hostname — skips entirely" {
	create_oc_mock "" "true" "" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	# No patches at all
	[[ ! -s "$OC_PATCH_LOG" ]]
}

@test "no grafana-env ConfigMap — skips entirely" {
	create_oc_mock "grafana.example.com" "false" "" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	# No patches at all
	[[ ! -s "$OC_PATCH_LOG" ]]
}

@test "empty signout URL — skips post_logout_redirect_uri patching" {
	create_oc_mock "grafana.example.com" "true" "" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	# ROOT_URL should be patched (it's empty)
	grep -q 'GF_SERVER_ROOT_URL' "$OC_PATCH_LOG"
	# But no signout URL patch
	! grep -q 'GF_AUTH_SIGNOUT_REDIRECT_URL' "$OC_PATCH_LOG"
}

# ==========================================================================
# Restart behavior
# ==========================================================================

@test "triggers restart when ROOT_URL is patched" {
	create_oc_mock "grafana.example.com" "true" "" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'rollout restart' "$OC_ROLLOUT_LOG"
	grep -q 'rollout status' "$OC_ROLLOUT_LOG"
}

@test "triggers restart when signout URL is patched" {
	local signout="https://sso.example.com/logout?post_logout_redirect_uri="
	create_oc_mock "grafana.example.com" "true" "https://already-set" "$signout"
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	grep -q 'rollout restart' "$OC_ROLLOUT_LOG"
}

@test "no restart when nothing is patched" {
	create_oc_mock "grafana.example.com" "true" "https://already-set" ""
	source "$LIB_DIR/grafana-url.sh"

	grafana_auto_derive_urls

	[[ ! -s "$OC_ROLLOUT_LOG" ]]
}
