#!/usr/bin/env bats
# Unit tests for scripts/lib/health-check.sh — namespace health checks.
#
# These tests mock `oc` and `curl` to exercise the health-check branches
# without requiring a running cluster.

bats_require_minimum_version 1.5.0

setup() {
	# Absolute path to the library under test
	LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)"

	# Create a temp bin dir for mock commands
	MOCK_BIN="$(mktemp -d)"
	export PATH="$MOCK_BIN:$PATH"

	# Default namespace used by the function
	export NAMESPACE="complytime-stage"
}

teardown() {
	rm -rf "$MOCK_BIN"
}

# --- Helper: write the oc/curl mock --------------------------------------
# Usage: create_health_mock <deployments_json> <routes_json> <exec_results>
#
# deployments_json: JSON array of objects with name, replicas, readyReplicas
#   e.g. '[{"name":"collector","replicas":1,"readyReplicas":1}]'
# routes_json: JSON array of objects with name, host, service, port
#   e.g. '[{"name":"collector","host":"collector.apps.example.com","service":"collector","port":"8088"}]'
# exec_results: associative-style lines of "url http_code" pairs for oc exec curl calls
#   e.g. "collector:8088/eventreceiver/healthcheck 200\ngrafana:3000/api/health 200"
create_health_mock() {
	local deployments_json="${1:-[]}"
	local routes_json="${2:-[]}"
	local exec_results="${3:-}"

	# Write exec_results to a file the mock can reference
	local exec_file="$MOCK_BIN/exec-results.txt"
	if [[ -n "$exec_results" ]]; then
		printf '%s\n' "$exec_results" >"$exec_file"
	else
		: >"$exec_file"
	fi

	cat >"$MOCK_BIN/oc" <<'MOCK'
#!/bin/bash
EXEC_FILE="EXEC_FILE_PLACEHOLDER"
DEPLOYMENTS_JSON='DEPLOY_PLACEHOLDER'
ROUTES_JSON='ROUTES_PLACEHOLDER'

case "$*" in
	*"get deployments.apps"*"-o json"*)
		# Return deployment list as JSON
		echo "$DEPLOYMENTS_JSON" | jq -c '{items: [.[] | {metadata:{name:.name},spec:{replicas:.replicas},status:{readyReplicas:(.readyReplicas // 0)}}]}'
		;;
	*"get routes"*"-o json"*)
		# Return route list as JSON
		echo "$ROUTES_JSON" | jq -c '{items: [.[] | {metadata:{name:.name},spec:{host:.host,to:{name:.service},port:{targetPort:(.port // "8080")}}}]}'
		;;
	*"get pods"*"-o jsonpath"*".items[0].metadata.name"*)
		# Return a pod name for oc exec
		echo "grafana-abc123"
		;;
	*"exec"*"curl"*)
		# Extract the URL being curled from the args
		# The curl call is: oc exec <pod> -n <ns> -- curl -s -o /dev/null -w '%{http_code}' -m 5 <url>
		local url=""
		local found_timeout=false
		for arg in "$@"; do
			if [[ "$found_timeout" == "true" ]]; then
				found_timeout=false
				continue
			fi
			if [[ "$arg" == "-m" ]]; then
				found_timeout=true
				continue
			fi
			if [[ "$arg" == http* ]]; then
				url="$arg"
			fi
		done
		if [[ -z "$url" ]]; then
			echo "000"
			exit 0
		fi
		# Look up the URL in exec results
		local code
		code=$(grep -F "$url" "$EXEC_FILE" 2>/dev/null | awk '{print $2}' | head -1)
		if [[ -n "$code" ]]; then
			echo "$code"
		else
			echo "000"
		fi
		;;
	*)
		echo "UNEXPECTED OC CALL: $*" >&2
		exit 99
		;;
esac
MOCK

	# Substitute placeholders
	sed -i "s|EXEC_FILE_PLACEHOLDER|$exec_file|g" "$MOCK_BIN/oc"
	sed -i "s|DEPLOY_PLACEHOLDER|$deployments_json|g" "$MOCK_BIN/oc"
	sed -i "s|ROUTES_PLACEHOLDER|$routes_json|g" "$MOCK_BIN/oc"
	chmod +x "$MOCK_BIN/oc"

	# Also provide a mock curl for Route reachability checks (direct curl)
	cat >"$MOCK_BIN/curl" <<'CURLMOCK'
#!/bin/bash
EXEC_FILE="EXEC_FILE_PLACEHOLDER"
# Extract the URL from the args
local_url=""
for arg in "$@"; do
	if [[ "$arg" == http* ]]; then
		local_url="$arg"
	fi
done
if [[ -z "$local_url" ]]; then
	echo "000"
	exit 0
fi
code=$(grep -F "$local_url" "$EXEC_FILE" 2>/dev/null | awk '{print $2}' | head -1)
if [[ -n "$code" ]]; then
	echo "$code"
else
	echo "000"
	exit 1
fi
CURLMOCK
	sed -i "s|EXEC_FILE_PLACEHOLDER|$exec_file|g" "$MOCK_BIN/curl"
	chmod +x "$MOCK_BIN/curl"

	# Provide jq pass-through (use system jq)
	# No mock needed — real jq is fine for JSON parsing
}

# ==========================================================================
# Core health check tests
# ==========================================================================

@test "all healthy — exit 0" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":1},{"name":"loki","replicas":1,"readyReplicas":1},{"name":"grafana","replicas":1,"readyReplicas":1}]' \
		'[{"name":"collector","host":"collector.apps.example.com","service":"collector","port":"8088"},{"name":"grafana","host":"grafana.apps.example.com","service":"grafana","port":"3000"}]' \
		"http://collector:8088/eventreceiver/healthcheck 200
http://grafana:3000/api/health 200
https://collector.apps.example.com 200
https://grafana.apps.example.com 200"
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 0 ]]
	[[ "$output" == *"HEALTHY"* ]]
}

@test "deployment not ready — exit 1, reports DEGRADED" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":1},{"name":"grafana","replicas":1,"readyReplicas":0}]' \
		'[]' \
		""
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"DEGRADED"* ]]
	[[ "$output" == *"grafana"* ]]
}

@test "route unreachable — exit 1, reports DEGRADED" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":1},{"name":"grafana","replicas":1,"readyReplicas":1}]' \
		'[{"name":"grafana","host":"grafana.apps.example.com","service":"grafana","port":"3000"}]' \
		"http://grafana:3000/api/health 200
https://grafana.apps.example.com 000"
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"DEGRADED"* ]]
}

@test "health endpoint returns 500 — exit 1, reports DEGRADED" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":1},{"name":"grafana","replicas":1,"readyReplicas":1}]' \
		'[{"name":"collector","host":"collector.apps.example.com","service":"collector","port":"8088"}]' \
		"http://collector:8088/eventreceiver/healthcheck 500
https://collector.apps.example.com 200"
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"DEGRADED"* ]]
}

@test "no deployments found — exit 1" {
	create_health_mock '[]' '[]' ""
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"DEGRADED"* ]] || [[ "$output" == *"No deployments"* ]]
}

@test "no routes — skips route checks, still checks pods" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":1},{"name":"grafana","replicas":1,"readyReplicas":1}]' \
		'[]' \
		"http://collector:8088/eventreceiver/healthcheck 200
http://grafana:3000/api/health 200"
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 0 ]]
	[[ "$output" == *"HEALTHY"* ]]
}

@test "NAMESPACE not set — exit with error" {
	unset NAMESPACE
	create_health_mock '[]' '[]' ""
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -ne 0 ]]
	[[ "$output" == *"NAMESPACE"* ]]
}

@test "deployment partially ready — reports correct counts" {
	create_health_mock \
		'[{"name":"collector","replicas":2,"readyReplicas":1}]' \
		'[]' \
		""
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"1/2"* ]]
	[[ "$output" == *"DEGRADED"* ]]
}

@test "health endpoint returns 401 via oc exec — falls back, reports DEGRADED" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":1}]' \
		'[]' \
		"http://collector:8088/eventreceiver/healthcheck 401"
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"DEGRADED"* ]]
}

@test "multiple failures reported together" {
	create_health_mock \
		'[{"name":"collector","replicas":1,"readyReplicas":0},{"name":"grafana","replicas":1,"readyReplicas":0}]' \
		'[]' \
		""
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"collector"* ]]
	[[ "$output" == *"grafana"* ]]
	[[ "$output" == *"DEGRADED"* ]]
}

@test "route returns 5xx — reports DEGRADED" {
	create_health_mock \
		'[{"name":"grafana","replicas":1,"readyReplicas":1}]' \
		'[{"name":"grafana","host":"grafana.apps.example.com","service":"grafana","port":"3000"}]' \
		"http://grafana:3000/api/health 200
https://grafana.apps.example.com 503"
	source "$LIB_DIR/health-check.sh"

	run check_namespace_health

	[[ "$status" -eq 1 ]]
	[[ "$output" == *"DEGRADED"* ]]
}
