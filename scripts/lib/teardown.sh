#!/bin/bash
# teardown.sh — Discovery-based namespace teardown.
#
# Sourceable library providing teardown_namespace().
# Requires: oc, NAMESPACE (env var).
#
# Scales deployments to zero, waits for pods to drain, deletes PVCs, then
# deletes all resources labelled app.kubernetes.io/managed-by=skaffold.
# Failures surface naturally — let the CI job handle retries.

# shellcheck disable=SC2154  # NAMESPACE is provided by caller
teardown_namespace() {
	local overlay_dir="${1:-}"

	if [[ -z "${NAMESPACE:-}" ]]; then
		echo "ERROR: NAMESPACE must be set" >&2
		return 1
	fi

	local label="app.kubernetes.io/managed-by=skaffold"
	local types="configmaps,deployments.apps,services,serviceaccounts"
	types+=",networkpolicies.networking.k8s.io"
	types+=",routes.route.openshift.io"
	types+=",jobs.batch"

	# Scale deployments to zero so pods release PVC mounts.
	echo "Scaling deployments to zero in $NAMESPACE"
	oc scale deployments.apps -n "$NAMESPACE" -l "$label" --replicas=0 2>/dev/null || :

	# Pods inherit template labels (app: foo), not the skaffold managed-by
	# label, so wait on all pods in the namespace.
	echo "Waiting for pods to terminate"
	oc wait pod -n "$NAMESPACE" --all --for=delete --timeout=120s 2>/dev/null || :

	# Delete PVCs first — they may not carry the skaffold label.
	echo "Deleting PVCs"
	oc delete pvc --all -n "$NAMESPACE" --wait=true 2>/dev/null || :

	# Delete everything labelled as skaffold-managed.
	echo "Deleting skaffold-managed resources"
	oc delete "$types" -n "$NAMESPACE" -l "$label" 2>/dev/null || :

	# Clean up generated overlay directory.
	if [[ -n "$overlay_dir" ]] && [[ -d "$overlay_dir" ]]; then
		rm -rf "$overlay_dir"
		echo "Removed overlay $overlay_dir"
	fi

	echo "Teardown of $NAMESPACE complete"
}
