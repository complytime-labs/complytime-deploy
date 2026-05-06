#!/bin/bash
set -euo pipefail

OVERLAY="${1:?Usage: $0 <overlay> (e.g., stage, production)}"
[[ "$OVERLAY" =~ ^[a-z]+$ ]] || { echo "ERROR: Invalid overlay name: $OVERLAY"; exit 1; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

TMPFILE=""
trap 'rm -f "$TMPFILE"' EXIT

NAMESPACE=$(grep '^namespace:' "$REPO_ROOT/overlays/$OVERLAY/kustomization.yaml" | awk '{print $2}')
if [ -z "$NAMESPACE" ]; then
    echo "ERROR: Could not extract namespace from overlays/$OVERLAY/kustomization.yaml"
    exit 1
fi

# --- Route TLS patching ---
if oc get secret route-tls-certs -n "$NAMESPACE" &>/dev/null; then
    echo "Patching Routes with TLS certificates..."

    COLLECTOR_CERT=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.collector\.crt}' | base64 -d)
    COLLECTOR_KEY=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.collector\.key}' | base64 -d)
    GRAFANA_CERT=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.grafana\.crt}' | base64 -d)
    GRAFANA_KEY=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.grafana\.key}' | base64 -d)
    CA_CHAIN=$(oc get secret route-tls-certs -n "$NAMESPACE" -o jsonpath='{.data.ca-chain\.crt}' | base64 -d)

    oc patch route collector-http -n "$NAMESPACE" --type=merge -p \
      "{\"spec\":{\"tls\":{\"certificate\":$(echo "$COLLECTOR_CERT" | jq -Rs .),\"key\":$(echo "$COLLECTOR_KEY" | jq -Rs .),\"destinationCACertificate\":$(echo "$CA_CHAIN" | jq -Rs .)}}}"
    echo "  collector-http route patched"

    oc patch route grafana -n "$NAMESPACE" --type=merge -p \
      "{\"spec\":{\"tls\":{\"certificate\":$(echo "$GRAFANA_CERT" | jq -Rs .),\"key\":$(echo "$GRAFANA_KEY" | jq -Rs .),\"destinationCACertificate\":$(echo "$CA_CHAIN" | jq -Rs .)}}}"
    echo "  grafana route patched"
else
    echo "WARNING: route-tls-certs secret not found — Routes will use default OpenShift certs."
    echo "  Create the SealedSecret to use custom TLS certificates (see sealed-secrets/README.md)."
fi

# --- Service CA injection into Grafana datasource ---
echo ""
echo "Waiting for Service CA bundle..."
for i in $(seq 1 30); do
    if oc get configmap service-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        break
    fi
    [ "$i" -eq 30 ] && { echo "WARNING: Service CA bundle not populated after 60s — Grafana datasource will need manual TLS configuration."; break; }
    sleep 2
done

if oc get configmap service-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
    echo "Injecting Service CA cert into Grafana datasource..."
    CA_CERT=$(oc get configmap service-ca-bundle -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}')
    INDENTED_CERT=$(echo "$CA_CERT" | sed 's/^/        /')

    TMPFILE=$(mktemp)
    cat > "$TMPFILE" <<DSPATCH
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

    oc patch configmap grafana-datasources -n "$NAMESPACE" --type=merge \
      -p "{\"data\":{\"ds.yaml\":$(jq -Rs . < "$TMPFILE")}}"
    rm -f "$TMPFILE"
    echo "  Grafana datasource CA cert injected"
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
