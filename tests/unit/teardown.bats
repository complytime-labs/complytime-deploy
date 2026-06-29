#!/usr/bin/env bats
# Unit tests for scripts/lib/teardown.sh — discovery-based teardown logic.
#
# These tests mock `oc` to exercise the teardown branches without requiring
# a running cluster.

bats_require_minimum_version 1.5.0

setup() {
	# Absolute path to the library under test
	LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)"

	# Create a temp bin dir for mock commands
	MOCK_BIN="$(mktemp -d)"
	export PATH="$MOCK_BIN:$PATH"

	# Default namespace used by the function
	export NAMESPACE="complytime-stage"

	# Track oc delete calls for assertions
	export OC_DELETE_LOG="$MOCK_BIN/oc-delete.log"
	: >"$OC_DELETE_LOG"
}

teardown() {
	rm -rf "$MOCK_BIN"
}

# --- Helper: write the oc mock -------------------------------------------
# Usage: create_oc_mock <managed_resources> <pvcs> <remaining_resources>
#
# managed_resources: newline-separated "kind/name" lines returned by
#   oc get ... -l app.kubernetes.io/managed-by=skaffold
# pvcs: newline-separated "persistentvolumeclaim/name" lines returned by
#   oc get pvc
# remaining_resources: newline-separated "kind/name" lines returned by
#   oc get (all remaining resources after deletion)
create_oc_mock() {
	local managed_resources="${1:-}"
	local pvcs="${2:-}"
	local remaining_resources="${3:-}"

	cat >"$MOCK_BIN/oc" <<MOCK
#!/bin/bash
case "\$*" in
	*"-l app.kubernetes.io/managed-by=skaffold"*"-o name"*)
		if [[ -n "$managed_resources" ]]; then
			printf '%s\n' $managed_resources
		fi
		;;
	*"get pvc"*"-o name"*)
		if [[ -n "$pvcs" ]]; then
			printf '%s\n' $pvcs
		fi
		;;
	*"get "*"-o name"*)
		# Remaining resources query (after deletion)
		if [[ -n "$remaining_resources" ]]; then
			printf '%s\n' $remaining_resources
		fi
		;;
	*"delete "*)
		echo "\$@" >> "$OC_DELETE_LOG"
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
# Core teardown tests
# ==========================================================================

@test "deletes resources with skaffold managed-by label" {
	create_oc_mock \
		"deployment.apps/collector deployment.apps/grafana deployment.apps/loki service/collector service/grafana service/loki" \
		"" \
		""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	# Should have called oc delete with the managed-by label
	grep -q "managed-by=skaffold" "$OC_DELETE_LOG"
}

@test "deletes PVCs separately after skaffold resources" {
	create_oc_mock \
		"deployment.apps/collector" \
		"persistentvolumeclaim/grafana-data persistentvolumeclaim/loki-data" \
		""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	# Should delete both skaffold-managed resources and PVCs
	grep -q "managed-by=skaffold" "$OC_DELETE_LOG"
	grep -q "pvc" "$OC_DELETE_LOG"
}

@test "skips PVC deletion when none exist" {
	create_oc_mock \
		"deployment.apps/collector" \
		"" \
		""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	grep -q "managed-by=skaffold" "$OC_DELETE_LOG"
	# No PVC delete call
	run ! grep -q "pvc" "$OC_DELETE_LOG"
}

@test "reports preserved resources when some remain" {
	create_oc_mock \
		"deployment.apps/collector" \
		"" \
		"secret/aws-creds secret/grafana-admin-secret configmap/collector-env configmap/grafana-env"
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	# Output should list preserved resources
	[[ "$output" == *"secret/aws-creds"* ]]
	[[ "$output" == *"configmap/grafana-env"* ]]
}

@test "reports clean namespace when nothing remains" {
	create_oc_mock \
		"deployment.apps/collector" \
		"" \
		""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	[[ "$output" == *"No resources remain"* ]] || [[ "$output" == *"clean"* ]] || [[ "$output" == *"empty"* ]]
}

@test "succeeds when no skaffold-managed resources found" {
	create_oc_mock "" "" "secret/aws-creds"
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	# Should still report preserved resources
	[[ "$output" == *"secret/aws-creds"* ]]
	# Should not call oc delete for managed resources (nothing to delete)
	run ! grep -q "managed-by=skaffold" "$OC_DELETE_LOG"
}

@test "requires NAMESPACE to be set" {
	unset NAMESPACE
	create_oc_mock "" "" ""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -ne 0 ]]
	[[ "$output" == *"NAMESPACE"* ]]
}

@test "outputs summary of torn-down resources" {
	create_oc_mock \
		"deployment.apps/collector deployment.apps/grafana deployment.apps/loki service/collector service/grafana service/loki configmap/collector-config configmap/loki-config route.route.openshift.io/collector route.route.openshift.io/grafana networkpolicy.networking.k8s.io/default-deny" \
		"persistentvolumeclaim/grafana-data persistentvolumeclaim/loki-data" \
		""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace

	[[ "$status" -eq 0 ]]
	# Should print what was torn down
	[[ "$output" == *"deployment.apps/collector"* ]]
	[[ "$output" == *"deployment.apps/grafana"* ]]
	[[ "$output" == *"persistentvolumeclaim/grafana-data"* ]]
}

@test "cleans up overlay directory when it exists" {
	local overlay_dir
	overlay_dir="$(mktemp -d)"
	touch "$overlay_dir/skaffold.yaml"

	create_oc_mock "deployment.apps/collector" "" ""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace "$overlay_dir"

	[[ "$status" -eq 0 ]]
	# Directory should be removed
	[[ ! -d "$overlay_dir" ]]
}

@test "succeeds when overlay directory does not exist" {
	create_oc_mock "deployment.apps/collector" "" ""
	source "$LIB_DIR/teardown.sh"

	run teardown_namespace "/nonexistent/overlay"

	[[ "$status" -eq 0 ]]
}
