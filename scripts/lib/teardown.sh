#!/bin/bash
# teardown.sh — Discovery-based namespace teardown.
#
# Sourceable library providing teardown_namespace().
# Requires: oc, NAMESPACE (env var).
#
# Deletes all resources labelled app.kubernetes.io/managed-by=skaffold in the
# target namespace, then deletes PVCs, and reports what was torn down vs. what
# remains so operators can manually clean up the rest.

# shellcheck disable=SC2154  # NAMESPACE is provided by caller
teardown_namespace() {
	local overlay_dir="${1:-}"

	if [[ -z "${NAMESPACE:-}" ]]; then
		echo "ERROR: NAMESPACE must be set" >&2
		return 1
	fi

	local label="app.kubernetes.io/managed-by=skaffold"

	# Resource types to query. These cover everything Skaffold deploys via
	# Kustomize in this project. We list them explicitly rather than using
	# "all" because "oc get all" skips NetworkPolicies, ConfigMaps, etc.
	local resource_types=(
		configmaps
		deployments.apps
		services
		serviceaccounts
		networkpolicies.networking.k8s.io
		routes.route.openshift.io
		jobs.batch
	)
	local types_csv
	types_csv=$(
		IFS=,
		echo "${resource_types[*]}"
	)

	# --- Discover managed resources ---
	local managed
	managed=$(oc get "$types_csv" \
		-n "$NAMESPACE" \
		-l "$label" \
		-o name 2>/dev/null) || :

	# --- Delete managed resources ---
	if [[ -n "$managed" ]]; then
		echo "=== Tearing down Skaffold-managed resources in $NAMESPACE ==="
		echo "$managed" | while IFS= read -r resource; do
			echo "  deleting $resource"
		done
		oc delete "$types_csv" \
			-n "$NAMESPACE" \
			-l "$label" \
			--wait=false 2>/dev/null || :
	else
		echo "=== No Skaffold-managed resources found in $NAMESPACE ==="
	fi

	# --- Delete PVCs (may not carry the skaffold label) ---
	local pvcs
	pvcs=$(oc get pvc -n "$NAMESPACE" -o name 2>/dev/null) || :

	if [[ -n "$pvcs" ]]; then
		echo ""
		echo "=== Deleting PVCs ==="
		echo "$pvcs" | while IFS= read -r pvc; do
			echo "  deleting $pvc"
		done
		oc delete pvc --all -n "$NAMESPACE" --wait=false 2>/dev/null || :
	fi

	# --- Clean up overlay directory if provided ---
	if [[ -n "$overlay_dir" ]] && [[ -d "$overlay_dir" ]]; then
		rm -rf "$overlay_dir"
		echo ""
		echo "Removed generated overlay at $overlay_dir"
	fi

	# --- Report what remains ---
	echo ""
	local remaining
	remaining=$(oc get configmaps,secrets,serviceaccounts,sealedsecrets.bitnami.com \
		-n "$NAMESPACE" \
		-o name 2>/dev/null) || :

	if [[ -n "$remaining" ]]; then
		echo "=== Preserved resources (not managed by Skaffold) ==="
		echo "$remaining" | while IFS= read -r resource; do
			echo "  $resource"
		done
		echo ""
		echo "To remove these manually:"
		echo "  oc delete configmaps,secrets --all -n $NAMESPACE"
	else
		echo "=== Namespace $NAMESPACE is clean — no resources remain ==="
	fi
}
