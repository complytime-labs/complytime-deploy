#!/bin/bash
# health-check.sh — Namespace health checks for deployed services.
#
# Sourceable library providing check_namespace_health().
# Requires: oc, jq, curl, NAMESPACE (env var).
#
# Checks three layers:
#   1. Deployment readiness (replicas vs readyReplicas)
#   2. Route reachability (direct curl to Route hostname)
#   3. Application health endpoints (via oc exec into a running pod)
#
# Prints a per-component status report and an overall verdict.
# Returns 0 for HEALTHY, 1 for DEGRADED.

# Known health endpoints keyed by app label.
# Format: "service_name:port/path"
declare -A _HEALTH_ENDPOINTS=(
	[collector]="collector:8088/eventreceiver/healthcheck"
	[grafana]="grafana:3000/api/health"
)

# shellcheck disable=SC2154  # NAMESPACE is provided by caller
check_namespace_health() {
	if [[ -z "${NAMESPACE:-}" ]]; then
		echo "ERROR: NAMESPACE must be set" >&2
		return 1
	fi

	local degraded=false

	# ------------------------------------------------------------------
	# 1. Deployment readiness
	# ------------------------------------------------------------------
	echo "=== Deployment Readiness ==="

	local deploy_json
	deploy_json=$(oc get deployments.apps -n "$NAMESPACE" -o json 2>/dev/null) || :

	local deploy_count
	deploy_count=$(echo "$deploy_json" | jq '.items | length')

	if [[ "$deploy_count" -eq 0 ]]; then
		echo "  No deployments found in $NAMESPACE"
		degraded=true
	else
		local i
		for ((i = 0; i < deploy_count; i++)); do
			local name replicas ready
			name=$(echo "$deploy_json" | jq -r ".items[$i].metadata.name")
			replicas=$(echo "$deploy_json" | jq -r ".items[$i].spec.replicas")
			ready=$(echo "$deploy_json" | jq -r ".items[$i].status.readyReplicas // 0")

			if [[ "$ready" -eq "$replicas" ]]; then
				printf '  %-15s %s/%s Ready    OK\n' "$name" "$ready" "$replicas"
			else
				printf '  %-15s %s/%s Ready    DEGRADED\n' "$name" "$ready" "$replicas"
				degraded=true
			fi
		done
	fi

	# ------------------------------------------------------------------
	# 2. Route reachability
	# ------------------------------------------------------------------
	echo ""
	echo "=== Route Reachability ==="

	local route_json
	route_json=$(oc get routes -n "$NAMESPACE" -o json 2>/dev/null) || :

	local route_count
	route_count=$(echo "$route_json" | jq '.items | length')

	if [[ "$route_count" -eq 0 ]]; then
		echo "  No routes found — skipping"
	else
		for ((i = 0; i < route_count; i++)); do
			local rname rhost
			rname=$(echo "$route_json" | jq -r ".items[$i].metadata.name")
			rhost=$(echo "$route_json" | jq -r ".items[$i].spec.host")

			local http_code
			http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -k "https://$rhost" 2>/dev/null) || http_code="000"

			if [[ "$http_code" =~ ^[23] ]]; then
				printf '  %-15s %-50s %s  OK\n' "$rname" "$rhost" "$http_code"
			else
				printf '  %-15s %-50s %s  DEGRADED\n' "$rname" "$rhost" "$http_code"
				degraded=true
			fi
		done
	fi

	# ------------------------------------------------------------------
	# 3. Application health endpoints (via oc exec)
	# ------------------------------------------------------------------
	echo ""
	echo "=== Application Health ==="

	# Find a running pod we can exec into
	local exec_pod
	exec_pod=$(oc get pods -n "$NAMESPACE" \
		--field-selector=status.phase=Running \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || :

	if [[ -z "$exec_pod" ]]; then
		echo "  No running pods — cannot check health endpoints"
		# Don't mark degraded for this alone; deployment readiness already caught it
	else
		for app_label in "${!_HEALTH_ENDPOINTS[@]}"; do
			local endpoint="${_HEALTH_ENDPOINTS[$app_label]}"
			local health_url="http://$endpoint"

			local health_code
			health_code=$(oc exec "$exec_pod" -n "$NAMESPACE" -- \
				curl -s -o /dev/null -w '%{http_code}' -m 5 "$health_url" 2>/dev/null) || health_code="000"

			local path="${endpoint#*/}"
			if [[ "$health_code" == "200" ]]; then
				printf '  %-15s /%s    %s  OK\n' "$app_label" "$path" "$health_code"
			else
				printf '  %-15s /%s    %s  DEGRADED\n' "$app_label" "$path" "$health_code"
				degraded=true
			fi
		done
	fi

	# ------------------------------------------------------------------
	# Overall verdict
	# ------------------------------------------------------------------
	echo ""
	if [[ "$degraded" == "true" ]]; then
		echo "Overall: DEGRADED"
		return 1
	else
		echo "Overall: HEALTHY"
		return 0
	fi
}
