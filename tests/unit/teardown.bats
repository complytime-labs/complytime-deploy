#!/usr/bin/env bats
# Unit tests for scripts/lib/teardown.sh

bats_require_minimum_version 1.5.0

setup() {
	LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)"

	MOCK_BIN="$(mktemp -d)"
	export PATH="$MOCK_BIN:$PATH"
	export NAMESPACE="complytime-stage"
	export OC_CALL_LOG="$MOCK_BIN/oc-calls.log"
	: >"$OC_CALL_LOG"

	create_oc_mock
}

teardown() {
	rm -rf "$MOCK_BIN"
}

# Default mock: accepts all expected oc subcommands, logs every call.
create_oc_mock() {
	cat >"$MOCK_BIN/oc" <<'MOCK'
#!/bin/bash
echo "$@" >> "$OC_CALL_LOG"
MOCK
	chmod +x "$MOCK_BIN/oc"
}

@test "requires NAMESPACE to be set" {
	unset NAMESPACE
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -ne 0 ]]
	[[ "$output" == *"NAMESPACE"* ]]
}

@test "scales deployments to zero" {
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	grep -q "scale.*--replicas=0" "$OC_CALL_LOG"
}

@test "waits for pods to terminate" {
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	grep -q "wait pod.*--for=delete" "$OC_CALL_LOG"
}

@test "deletes PVCs with --wait=true" {
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	grep -q "delete pvc --all.*--wait=true" "$OC_CALL_LOG"
}

@test "deletes skaffold-managed resources by label" {
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	grep -q "delete.*managed-by=skaffold" "$OC_CALL_LOG"
}

@test "operations run in correct order: scale, wait, pvc, delete" {
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	local scale_line wait_line pvc_line delete_line
	scale_line=$(grep -n "scale" "$OC_CALL_LOG" | head -1 | cut -d: -f1)
	wait_line=$(grep -n "wait pod" "$OC_CALL_LOG" | head -1 | cut -d: -f1)
	pvc_line=$(grep -n "delete pvc" "$OC_CALL_LOG" | head -1 | cut -d: -f1)
	delete_line=$(grep -n "delete.*managed-by" "$OC_CALL_LOG" | head -1 | cut -d: -f1)
	[[ "$scale_line" -lt "$wait_line" ]]
	[[ "$wait_line" -lt "$pvc_line" ]]
	[[ "$pvc_line" -lt "$delete_line" ]]
}

@test "cleans up overlay directory" {
	local overlay_dir
	overlay_dir="$(mktemp -d)"
	touch "$overlay_dir/skaffold.yaml"
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace "$overlay_dir"

	[[ "$status" -eq 0 ]]
	[[ ! -d "$overlay_dir" ]]
}

@test "succeeds when overlay directory does not exist" {
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace "/nonexistent/overlay"

	[[ "$status" -eq 0 ]]
}
