#!/bin/bash
# grafana-url.sh — Auto-derive Grafana URL from Route hostname.
#
# Sourceable library providing grafana_auto_derive_urls().
# Requires: oc, jq, NAMESPACE (env var).
#
# On first deploy, GF_SERVER_ROOT_URL may be empty because the Route hostname
# isn't known until the Route is created.  This function detects empty values
# in the grafana-env ConfigMap and fills them from the actual Route hostname.
# CI-set values always win — this only patches empty/incomplete entries.

# shellcheck disable=SC2154  # NAMESPACE is provided by caller
grafana_auto_derive_urls() {
	local grafana_route_host
	grafana_route_host=$(oc get route grafana -n "$NAMESPACE" \
		-o jsonpath='{.spec.host}' 2>/dev/null) || :

	if [[ -z "$grafana_route_host" ]]; then
		return 0
	fi

	local derived_root_url="https://$grafana_route_host"
	local needs_restart=false

	# Check if grafana-env ConfigMap exists (it won't on local overlay deploys)
	if ! oc get configmap grafana-env -n "$NAMESPACE" &>/dev/null; then
		return 0
	fi

	local current_root_url
	current_root_url=$(oc get configmap grafana-env -n "$NAMESPACE" \
		-o jsonpath='{.data.GF_SERVER_ROOT_URL}' 2>/dev/null) || :

	local current_signout_url
	current_signout_url=$(oc get configmap grafana-env -n "$NAMESPACE" \
		-o jsonpath='{.data.GF_AUTH_SIGNOUT_REDIRECT_URL}' 2>/dev/null) || :

	# Patch GF_SERVER_ROOT_URL if empty
	if [[ -z "$current_root_url" ]]; then
		echo "Auto-deriving GF_SERVER_ROOT_URL from Route hostname..."
		local root_url_json
		root_url_json=$(jq -n --arg v "$derived_root_url" '$v')
		oc patch configmap grafana-env -n "$NAMESPACE" --type=merge \
			-p "{\"data\":{\"GF_SERVER_ROOT_URL\":$root_url_json}}"
		echo "  GF_SERVER_ROOT_URL set to $derived_root_url"
		needs_restart=true
	fi

	# Patch redirect_uri in GF_AUTH_SIGNOUT_REDIRECT_URL if needed
	if [[ -n "$current_signout_url" ]]; then
		local encoded_root_url
		encoded_root_url=$(jq -rn --arg v "$derived_root_url" '$v|@uri')
		local patched_signout_url=""

		if [[ "$current_signout_url" =~ redirect_uri=$ ]]; then
			# redirect_uri= exists but value is empty (at end of string)
			patched_signout_url="${current_signout_url}${encoded_root_url}"
		elif [[ "$current_signout_url" =~ redirect_uri=\& ]]; then
			# redirect_uri= exists but value is empty (followed by &)
			patched_signout_url="${current_signout_url/redirect_uri=&/redirect_uri=${encoded_root_url}\&}"
		elif [[ "$current_signout_url" != *"redirect_uri="* ]]; then
			# No redirect_uri parameter at all — append it
			if [[ "$current_signout_url" == *"?"* ]]; then
				patched_signout_url="${current_signout_url}&redirect_uri=${encoded_root_url}"
			else
				patched_signout_url="${current_signout_url}?redirect_uri=${encoded_root_url}"
			fi
		fi
		# If redirect_uri already has a non-empty value, skip (CI variable wins)

		if [[ -n "$patched_signout_url" ]]; then
			echo "Auto-filling redirect_uri in GF_AUTH_SIGNOUT_REDIRECT_URL..."
			local signout_json
			signout_json=$(jq -n --arg v "$patched_signout_url" '$v')
			oc patch configmap grafana-env -n "$NAMESPACE" --type=merge \
				-p "{\"data\":{\"GF_AUTH_SIGNOUT_REDIRECT_URL\":$signout_json}}"
			echo "  GF_AUTH_SIGNOUT_REDIRECT_URL updated"
			needs_restart=true
		fi
	fi

	if [[ "$needs_restart" == "true" ]]; then
		echo ""
		echo "Restarting Grafana to pick up derived URL values..."
		oc rollout restart deployment/grafana -n "$NAMESPACE"
		oc rollout status deployment/grafana -n "$NAMESPACE" --timeout=5m
	fi
}
