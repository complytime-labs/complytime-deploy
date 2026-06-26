#!/bin/bash
set -euo pipefail

OVERLAY="${1:?Usage: $0 <overlay> [namespace-override] (e.g., stage, production)}"
[[ "$OVERLAY" =~ ^[a-z-]+$ ]] || {
	echo "ERROR: Invalid overlay name: $OVERLAY"
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/grafana-url.sh
source "$SCRIPT_DIR/lib/grafana-url.sh"

TMPFILE=""
trap 'rm -f "$TMPFILE"' EXIT

if [[ -n "${2:-}" ]]; then
	NAMESPACE="$2"
else
	NAMESPACE=$(grep '^namespace:' "$REPO_ROOT/overlays/$OVERLAY/kustomization.yaml" | awk '{print $2}')
	if [[ -z "$NAMESPACE" ]]; then
		echo "ERROR: Could not extract namespace from overlays/$OVERLAY/kustomization.yaml"
		exit 1
	fi
fi

# --- Route TLS patching ---
# Patches a route with TLS certs based on its termination type:
#   reencrypt  → certificate + key + destinationCACertificate
#   edge       → certificate + key only (no destination CA)
#   passthrough → skip (router does not terminate TLS)
patch_route() {
	local route_name="$1" cert_json="$2" key_json="$3" ca_json="$4"
	local termination
	termination=$(oc get route "$route_name" -n "$NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null) || :

	case "$termination" in
	reencrypt)
		oc patch route "$route_name" -n "$NAMESPACE" --type=merge -p \
			"{\"spec\":{\"tls\":{\"certificate\":$cert_json,\"key\":$key_json,\"destinationCACertificate\":$ca_json}}}"
		echo "  $route_name route patched (reencrypt — cert + key + destinationCA)"
		;;
	edge)
		oc patch route "$route_name" -n "$NAMESPACE" --type=merge -p \
			"{\"spec\":{\"tls\":{\"certificate\":$cert_json,\"key\":$key_json}}}"
		echo "  $route_name route patched (edge — cert + key only)"
		;;
	passthrough)
		echo "  $route_name route skipped (passthrough — router does not terminate TLS)"
		;;
	*)
		echo "  WARNING: $route_name has unknown termination '$termination' — skipping TLS patch"
		;;
	esac
}

if oc get secret route-tls-certs -n "$NAMESPACE" &>/dev/null; then
	echo "Patching Routes with TLS certificates..."

	COLLECTOR_CERT=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.collector\.crt}' | base64 -d)
	COLLECTOR_KEY=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.collector\.key}' | base64 -d)
	GRAFANA_CERT=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.grafana\.crt}' | base64 -d)
	GRAFANA_KEY=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.grafana\.key}' | base64 -d)
	CA_CHAIN=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.ca-chain\.crt}' | base64 -d)

	CA_CHAIN_JSON=$(echo "$CA_CHAIN" | jq -Rs .)
	COLLECTOR_CERT_JSON=$(echo "$COLLECTOR_CERT" | jq -Rs .)
	COLLECTOR_KEY_JSON=$(echo "$COLLECTOR_KEY" | jq -Rs .)
	GRAFANA_CERT_JSON=$(echo "$GRAFANA_CERT" | jq -Rs .)
	GRAFANA_KEY_JSON=$(echo "$GRAFANA_KEY" | jq -Rs .)
	patch_route "collector-http" "$COLLECTOR_CERT_JSON" "$COLLECTOR_KEY_JSON" "$CA_CHAIN_JSON"
	patch_route "grafana" "$GRAFANA_CERT_JSON" "$GRAFANA_KEY_JSON" "$CA_CHAIN_JSON"
else
	echo "WARNING: route-tls-certs secret not found — Routes will use default OpenShift certs."
	echo "  Set ROUTE_TLS_* CI variables or create a SealedSecret (see overlays/<env>/sealed-secrets/README.md)."
fi

# --- Service CA injection into Grafana datasource ---
echo ""
echo "Waiting for Service CA bundle..."
for i in $(seq 1 30); do
	ca_bundle_output=$(oc get configmap service-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null) || :
	if echo "$ca_bundle_output" | grep -q "BEGIN CERTIFICATE"; then
		break
	fi
	[[ "$i" -eq 30 ]] && {
		echo "WARNING: Service CA bundle not populated after 60s — Grafana datasource will need manual TLS configuration."
		break
	}
	sleep 2
done

ca_bundle_check=$(oc get configmap service-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null) || :
if echo "$ca_bundle_check" | grep -q "BEGIN CERTIFICATE"; then
	echo "Injecting Service CA cert into Grafana datasource..."
	CA_CERT=$(oc get configmap service-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}')
	INDENTED_CERT="        ${CA_CERT//$'\n'/$'\n'        }"

	TMPFILE=$(mktemp)
	cat >"$TMPFILE" <<DSPATCH
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: https://loki:3100
    isDefault: true
    jsonData:
      tlsAuth: false
      tlsAuthWithCACert: true
      tlsSkipVerify: false
    secureJsonData:
      tlsCACert: |
${INDENTED_CERT}
DSPATCH

	DS_YAML_JSON=$(jq -Rs . <"$TMPFILE")
	oc patch configmap grafana-datasources -n "$NAMESPACE" --type=merge \
		-p "{\"data\":{\"ds.yaml\":$DS_YAML_JSON}}"
	rm -f "$TMPFILE"
	echo "  Grafana datasource CA cert injected"
fi

# --- Wait for rollouts ---
echo ""
echo "Waiting for deployments to be ready..."
oc rollout status deployment/collector -n "$NAMESPACE" --timeout=5m
oc rollout status deployment/loki -n "$NAMESPACE" --timeout=5m
oc rollout status deployment/grafana -n "$NAMESPACE" --timeout=5m

# --- Auto-derive Grafana URL from Route hostname ---
# See scripts/lib/grafana-url.sh for implementation details.
grafana_auto_derive_urls

# --- SSO redirect URI diagnostic ---
# Print the exact URIs that must be registered in the SSO client.
# This saves operators from reverse-engineering what Grafana sends.
_root_url=$(oc get configmap grafana-env -n "$NAMESPACE" \
	-o jsonpath='{.data.GF_SERVER_ROOT_URL}' 2>/dev/null) || :
_signout_url=$(oc get configmap grafana-env -n "$NAMESPACE" \
	-o jsonpath='{.data.GF_AUTH_SIGNOUT_REDIRECT_URL}' 2>/dev/null) || :

if [[ -n "$_root_url" ]]; then
	echo ""
	echo "SSO client redirect URIs (must be registered in your IdP):"
	echo "  Valid Redirect URI:        ${_root_url}/login/generic_oauth"
	if [[ -n "$_signout_url" ]]; then
		# Extract post_logout_redirect_uri value from the signout URL
		_post_logout=$(echo "$_signout_url" | sed -n 's/.*post_logout_redirect_uri=\([^&]*\).*/\1/p')
		if [[ -n "$_post_logout" ]]; then
			# Decode percent-encoded value for human-readable output
			_decoded=$(printf '%b' "${_post_logout//%/\\x}" 2>/dev/null || echo "$_post_logout")
			echo "  Post-Logout Redirect URI:  $_decoded"
		fi
	fi
fi

echo ""
echo "Deployment successful!"
echo ""
COLLECTOR_HOST=$(oc get route collector-http -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<not set>")
GRAFANA_HOST=$(oc get route grafana -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo '<not set>')
echo "Access your services:"
echo "  Collector: https://$COLLECTOR_HOST"
echo "  Grafana:   https://$GRAFANA_HOST"
echo "  Admin:     https://$GRAFANA_HOST/login?disableAutoLogin=true"
