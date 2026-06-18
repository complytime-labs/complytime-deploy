#!/bin/bash
set -euo pipefail

OVERLAY="${1:?Usage: $0 <overlay> [namespace-override] (e.g., stage, production)}"
[[ "$OVERLAY" =~ ^[a-z-]+$ ]] || {
	echo "ERROR: Invalid overlay name: $OVERLAY"
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# --- OIDC issuer URL injection ---
# The collector OIDC extension requires a valid issuer URL. When deployed via
# GitLab CI, the OIDC_ISSUER_URL variable is set in GitLab CI/CD settings.
# The overlay patch defaults to an empty string; this patches the Deployment
# with the real value from the CI environment.
if [[ -n "${OIDC_ISSUER_URL:-}" ]]; then
	echo "Patching collector with OIDC_ISSUER_URL..."
	oc set env deployment/collector OIDC_ISSUER_URL="$OIDC_ISSUER_URL" -n "$NAMESPACE"
	echo "  OIDC_ISSUER_URL set"
else
	CURRENT_URL=$(oc get deployment/collector -n "$NAMESPACE" \
		-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OIDC_ISSUER_URL")].value}' 2>/dev/null) || :
	if [[ -z "$CURRENT_URL" ]]; then
		echo "WARNING: OIDC_ISSUER_URL is empty — the collector OIDC extension will fail to start."
		echo "  Set OIDC_ISSUER_URL in GitLab CI variables (Settings > CI/CD > Variables)."
	fi
fi

# --- Wait for rollouts ---
echo ""
echo "Waiting for deployments to be ready..."
oc rollout status deployment/collector -n "$NAMESPACE" --timeout=5m
oc rollout status deployment/loki -n "$NAMESPACE" --timeout=5m
oc rollout status deployment/grafana -n "$NAMESPACE" --timeout=5m

echo ""
echo "Deployment successful!"
echo ""
COLLECTOR_HOST=$(oc get route collector-http -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<not set>")
GRAFANA_HOST=$(oc get route grafana -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<not set>")
echo "Access your services:"
echo "  Collector: https://$COLLECTOR_HOST"
echo "  Grafana:   https://$GRAFANA_HOST"
